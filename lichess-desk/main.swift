// Lichess Desk: a small Mac window around lichess.org for streaming.
// - Full desktop site (right-drag arrows, premoves, keyboard input).
// - Stays logged in between launches.
// - Clock tint built in (../userscripts/clock-board-tint.user.js), with settings in the Tint menu.
// - Fixed window title and size presets so OBS Window Capture never needs touching.
// - Optional heart rate from a Bluetooth watch, with the OBS overlay served by the app (hr.swift).
// Build with ./build.sh (--install copies it to ~/Applications)

import AppKit
import WebKit

let home = URL(string: "https://lichess.org/")!

func isLichess(_ url: URL) -> Bool {
    guard let h = url.host?.lowercased() else { return false }
    return h == "lichess.org" || h.hasSuffix(".lichess.org")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
                         WKDownloadDelegate, NSMenuItemValidation, NSWindowDelegate,
                         WKScriptMessageHandler, NSMenuDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var tintSource = ""
    var preview: Int? = nil              // seconds; not saved, it's only for setting up OBS
    var downloads: [ObjectIdentifier: URL] = [:]
    let d = UserDefaults.standard
    var hr: HeartRate!
    var hrStatusItem: NSMenuItem!
    var hrWatchMenu: NSMenu!

    // MARK: launch

    func applicationDidFinishLaunching(_ n: Notification) {
        d.register(defaults: [
            "tintEnabled": true, "tintStart": 60, "tintStrength": 0.5,
            "tintPulse": true, "tintGlow": true, "autoQueen": true, "oppAge": true, "zoom": 1.0, "floatOnTop": false,
            "hrEnabled": false, "hrDemo": false, "hrBadge": true, "hrDevice": "", "hrPort": 8765,
        ])
        if let url = Bundle.main.url(forResource: "clock-board-tint", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8) { tintSource = s }

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // cookies persist: stay logged in
        cfg.mediaTypesRequiringUserActionForPlayback = [] // move sounds play straight away
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15" // full desktop site

        cfg.userContentController.add(self, name: "ctToggle")   // on-page buttons -> settings
        cfg.userContentController.add(self, name: "ctHR")       // the logged-in lichess user, for game tracking
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        web.pageZoom = d.double(forKey: "zoom")
        installScripts()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Lichess"          // fixed, so OBS always finds the same window
        window.contentView = web
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("LichessDeskMain")
        window.level = d.bool(forKey: "floatOnTop") ? .floating : .normal
        window.makeKeyAndOrderFront(nil)

        let port = d.integer(forKey: "hrPort")
        hr = HeartRate(port: UInt16(clamping: (1024...65535).contains(port) ? port : 8765))
        hr.wantedName = d.string(forKey: "hrDevice") ?? ""
        hr.onUpdate = { [weak self] in self?.hrChanged() }
        NSApp.mainMenu = buildMenu()
        if d.bool(forKey: "hrEnabled") { hr.start(demo: d.bool(forKey: "hrDemo")) }

        var start = home
        if let s = d.string(forKey: "lastURL"), let u = URL(string: s), isLichess(u) { start = u }
        web.load(URLRequest(url: start))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        if let u = web.url, isLichess(u) { d.set(u.absoluteString, forKey: "lastURL") }
    }

    // MARK: tint settings -> page

    func settingsJSON() -> String {
        let o: [String: Any] = [
            "ENABLED": d.bool(forKey: "tintEnabled"),
            "START": d.integer(forKey: "tintStart"),
            "MAX_STRENGTH": d.double(forKey: "tintStrength"),
            "PULSE_BELOW": d.bool(forKey: "tintPulse") ? 5 : 0,
            "GLOW": d.bool(forKey: "tintGlow"),
            "AUTO_QUEEN": d.bool(forKey: "autoQueen"),
            "OPP_AGE": d.bool(forKey: "oppAge"),
            "PREVIEW": preview.map { $0 as Any } ?? NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: o)
        return String(data: data, encoding: .utf8)!
    }

    func installScripts() {
        let uc = web.configuration.userContentController
        uc.removeAllUserScripts()
        uc.addUserScript(WKUserScript(source: "window.CT_SETTINGS = \(settingsJSON());",
                                      injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if !tintSource.isEmpty {
            uc.addUserScript(WKUserScript(source: tintSource, injectionTime: .atDocumentEnd,
                                          forMainFrameOnly: true))
        }
        uc.addUserScript(WKUserScript(source: hrPageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    // Applies to the open page immediately and to every later page load.
    func applySettings() {
        installScripts()
        web.evaluateJavaScript("window.CT_SETTINGS = \(settingsJSON());")
    }

    // MARK: menu

    func item(_ title: String, _ action: Selector?, _ key: String = "",
              _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        return i
    }

    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        top.submenu = m
        return top
    }

    func buildMenu() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Lichess Desk", [
            item("About Lichess Desk", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Lichess Desk", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Lichess Desk", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Page Link", #selector(copyLink), "c", [.command, .shift]),
        ]))

        let sizes = [(1280, 720), (1600, 900), (1920, 1080)].map { (w, h) -> NSMenuItem in
            let i = item("Window \(w) × \(h)", #selector(setWindowSize(_:)))
            i.representedObject = NSValue(size: NSSize(width: w, height: h))
            return i
        }
        main.addItem(submenu("View", [
            item("Home", #selector(goHome), "h", [.command, .shift]),
            item("Back", #selector(goBack), "["),
            item("Forward", #selector(goForward), "]"),
            item("Reload", #selector(reload), "r"),
            .separator(),
            item("Zoom In", #selector(zoomIn), "="),
            item("Zoom Out", #selector(zoomOut), "-"),
            item("Actual Size", #selector(zoomReset), "0"),
            .separator(),
        ] + sizes + [
            item("Float on Top", #selector(toggleFloat), "t", [.command, .shift]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        let hint = item("Hold ⌥ while promoting to choose a piece", nil)
        hint.isEnabled = false
        main.addItem(submenu("Play", [
            item("Auto-Queen", #selector(toggleAutoQueen), "a", [.command, .shift]),
            hint,
            .separator(),
            item("Show Opponent Account Age", #selector(toggleOppAge)),
        ]))

        main.addItem(submenu("Tint", [
            item("Board Tint On", #selector(toggleTint), "k", [.command, .shift]),
            .separator(),
            item("Start at 2:00", #selector(setStart(_:)), tag: 120),
            item("Start at 1:00", #selector(setStart(_:)), tag: 60),
            item("Start at 0:30", #selector(setStart(_:)), tag: 30),
            .separator(),
            item("Subtle", #selector(setStrength(_:)), tag: 35),
            item("Normal", #selector(setStrength(_:)), tag: 50),
            item("Strong", #selector(setStrength(_:)), tag: 80),
            .separator(),
            item("Pulse in Last 5 Seconds", #selector(togglePulse)),
            item("Glow Around Board", #selector(toggleGlow)),
            .separator(),
            item("Preview: Off", #selector(setPreview(_:)), tag: -1),
            item("Preview: 0:45 Left", #selector(setPreview(_:)), tag: 45),
            item("Preview: 0:20 Left", #selector(setPreview(_:)), tag: 20),
            item("Preview: 0:04 Left", #selector(setPreview(_:)), tag: 4),
        ]))

        hrStatusItem = item("Heart rate is off", nil)
        hrStatusItem.isEnabled = false
        let watch = submenu("Watch", [])
        hrWatchMenu = watch.submenu
        hrWatchMenu.delegate = self
        let hrMenu = submenu("Heart Rate", [
            item("Heart Rate On", #selector(toggleHR), "b", [.command, .shift]),
            hrStatusItem,
            .separator(),
            watch,
            item("Demo Heart Rate (No Watch)", #selector(toggleHRDemo)),
            item("Show BPM Next to My Clock", #selector(toggleHRBadge)),
            .separator(),
            item("New Game (Reset Peak)", #selector(hrNewGame)),
            item("Copy OBS Overlay URL", #selector(copyOverlayURL)),
            item("Open Overlay in Browser", #selector(openOverlay)),
            item("Edit Heart-Rate Zones…", #selector(editZones)),
        ])
        hrMenu.submenu?.delegate = self
        main.addItem(hrMenu)

        let win = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = win.submenu
        main.addItem(win)
        return main
    }

    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        let on = { (b: Bool) in m.state = b ? .on : .off }
        switch m.action {
        case #selector(toggleTint): on(d.bool(forKey: "tintEnabled"))
        case #selector(setStart(_:)): on(d.integer(forKey: "tintStart") == m.tag)
        case #selector(setStrength(_:)): on(Int((d.double(forKey: "tintStrength") * 100).rounded()) == m.tag)
        case #selector(togglePulse): on(d.bool(forKey: "tintPulse"))
        case #selector(toggleGlow): on(d.bool(forKey: "tintGlow"))
        case #selector(setPreview(_:)): on((preview ?? -1) == m.tag)
        case #selector(toggleAutoQueen): on(d.bool(forKey: "autoQueen"))
        case #selector(toggleOppAge): on(d.bool(forKey: "oppAge"))
        case #selector(toggleFloat): on(d.bool(forKey: "floatOnTop"))
        case #selector(toggleHR): on(d.bool(forKey: "hrEnabled"))
        case #selector(toggleHRDemo): on(d.bool(forKey: "hrDemo"))
        case #selector(toggleHRBadge): on(d.bool(forKey: "hrBadge"))
        case #selector(chooseWatch(_:)): on((m.representedObject as? String ?? "") == hr.wantedName)
        case #selector(hrNewGame), #selector(openOverlay): return hr.running
        case #selector(goBack): return web.canGoBack
        case #selector(goForward): return web.canGoForward
        default: break
        }
        return true
    }

    // MARK: actions

    @objc func goHome() { web.load(URLRequest(url: home)) }
    @objc func goBack() { web.goBack() }
    @objc func goForward() { web.goForward() }
    @objc func reload() { web.reload() }
    @objc func copyLink() {
        guard let u = web.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }

    func setZoom(_ z: Double) {
        let z = min(3, max(0.5, (z * 100).rounded() / 100))
        web.pageZoom = z
        d.set(z, forKey: "zoom")
    }
    @objc func zoomIn() { setZoom(web.pageZoom + 0.1) }
    @objc func zoomOut() { setZoom(web.pageZoom - 0.1) }
    @objc func zoomReset() { setZoom(1.0) }

    @objc func setWindowSize(_ sender: NSMenuItem) {
        guard let s = (sender.representedObject as? NSValue)?.sizeValue else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.setContentSize(s)
    }
    @objc func toggleFloat() {
        d.set(!d.bool(forKey: "floatOnTop"), forKey: "floatOnTop")
        window.level = d.bool(forKey: "floatOnTop") ? .floating : .normal
    }

    @objc func toggleAutoQueen() { d.set(!d.bool(forKey: "autoQueen"), forKey: "autoQueen"); applySettings() }
    @objc func toggleOppAge() { d.set(!d.bool(forKey: "oppAge"), forKey: "oppAge"); applySettings() }
    @objc func toggleTint() { d.set(!d.bool(forKey: "tintEnabled"), forKey: "tintEnabled"); applySettings() }
    @objc func setStart(_ s: NSMenuItem) { d.set(s.tag, forKey: "tintStart"); applySettings() }
    @objc func setStrength(_ s: NSMenuItem) { d.set(Double(s.tag) / 100, forKey: "tintStrength"); applySettings() }
    @objc func togglePulse() { d.set(!d.bool(forKey: "tintPulse"), forKey: "tintPulse"); applySettings() }
    @objc func toggleGlow() { d.set(!d.bool(forKey: "tintGlow"), forKey: "tintGlow"); applySettings() }
    @objc func setPreview(_ s: NSMenuItem) { preview = s.tag < 0 ? nil : s.tag; applySettings() }

    // MARK: heart rate

    @objc func toggleHR() {
        d.set(!d.bool(forKey: "hrEnabled"), forKey: "hrEnabled")
        if d.bool(forKey: "hrEnabled") { hr.start(demo: d.bool(forKey: "hrDemo")) } else { hr.stop() }
    }
    @objc func toggleHRDemo() {
        d.set(!d.bool(forKey: "hrDemo"), forKey: "hrDemo")
        if d.bool(forKey: "hrDemo") { d.set(true, forKey: "hrEnabled") }
        if d.bool(forKey: "hrEnabled") { hr.start(demo: d.bool(forKey: "hrDemo")) }
    }
    @objc func toggleHRBadge() { d.set(!d.bool(forKey: "hrBadge"), forKey: "hrBadge"); hrChanged() }
    @objc func chooseWatch(_ s: NSMenuItem) {
        let name = s.representedObject as? String ?? ""
        d.set(name, forKey: "hrDevice")
        hr.choose(name)
    }
    @objc func hrNewGame() { hr.newGame() }
    @objc func copyOverlayURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hr.overlayURL, forType: .string)
    }
    @objc func openOverlay() { NSWorkspace.shared.open(URL(string: hr.overlayURL)!) }
    @objc func editZones() {
        guard let f = hr.zonesFileForEditing() else { return }
        if !NSWorkspace.shared.open(f) {     // no app claims .toml: use TextEdit
            NSWorkspace.shared.open([f], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    var hrStatusText: String {
        guard hr.running else { return "Heart rate is off" }
        if let p = hr.serverProblem { return "Overlay: \(p)" }
        let live = hr.bpm != nil && Date().timeIntervalSince1970 - hr.ts < 5
        let who = hr.user.map { " · following \($0)" } ?? ""
        return (live ? "\(hr.bpm!) bpm · \(hr.device ?? "watch")" : hr.status.prefix(1).uppercased() + hr.status.dropFirst()) + who
    }

    // Keeps the status line fresh and feeds the BPM badge on the page.
    func hrChanged() {
        hrStatusItem?.title = hrStatusText
        var o: [String: Any] = ["show": hr.running && d.bool(forKey: "hrBadge")]
        if let b = hr.bpm, Date().timeIntervalSince1970 - hr.ts < 5 {
            let z = hr.zones.zone(for: b)
            o["bpm"] = b; o["color"] = z.color; o["zone"] = z.name
        }
        if let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) {
            web?.evaluateJavaScript("window.ctHR && window.ctHR(\(s))")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        hrStatusItem.title = hrStatusText
        guard menu === hrWatchMenu else { return }
        menu.removeAllItems()
        let any = item("Any Heart-Rate Watch", #selector(chooseWatch(_:)))
        any.representedObject = ""
        menu.addItem(any)
        let saved = hr.wantedName
        var names: [String] = []
        for s in hr.seenDevices.values.sorted(by: { ($0.hasHR ? 1 : 0, $0.rssi) > ($1.hasHR ? 1 : 0, $1.rssi) })
            where !names.contains(s.name) && names.count < 15 { names.append(s.name) }
        if !saved.isEmpty && !names.contains(where: { $0.lowercased().contains(saved.lowercased()) }) { names.insert(saved, at: 0) }
        if !names.isEmpty { menu.addItem(.separator()) }
        for n in names {
            let hasHR = hr.seenDevices.values.contains { $0.name == n && $0.hasHR }
            let i = item(hasHR ? "\(n)  ♥" : n, #selector(chooseWatch(_:)))
            i.representedObject = n
            menu.addItem(i)
        }
        let note = item(hr.running && !hr.demo ? "Nearby devices appear here as they're found"
                                               : "Turn heart rate on to look for watches", nil)
        note.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(note)
    }

    // Messages from the page (only from lichess pages).
    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.frameInfo.isMainFrame, let u = m.frameInfo.request.url, isLichess(u) else { return }
        if m.name == "ctHR" {
            if let o = m.body as? [String: Any], let user = o["user"] as? String { hr.setUser(user) }
            hrChanged()
            return
        }
        if m.body as? String == "autoQueen" { toggleAutoQueen() }
    }

    // MARK: navigation: lichess stays here, everything else opens in your browser

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
        if a.shouldPerformDownload { return .download }
        if let u = a.request.url, a.navigationType == .linkActivated, a.targetFrame?.isMainFrame ?? true,
           ["http", "https"].contains(u.scheme ?? ""), !isLichess(u) {
            NSWorkspace.shared.open(u)
            return .cancel
        }
        return .allow
    }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        r.canShowMIMEType ? .allow : .download
    }

    // target=_blank / window.open
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url {
            if isLichess(u) { w.load(a.request) } else { NSWorkspace.shared.open(u) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo) async {
        let a = NSAlert()
        a.messageText = m
        a.runModal()
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo) async -> Bool {
        let a = NSAlert()
        a.messageText = m
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters,
                 initiatedByFrame f: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = p.allowsMultipleSelection
        return panel.runModal() == .OK ? panel.urls : nil
    }

    // MARK: downloads (PGN exports etc.) -> ~/Downloads

    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome dl: WKDownload) { dl.delegate = self }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome dl: WKDownload) { dl.delegate = self }

    func download(_ dl: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        downloads[ObjectIdentifier(dl)] = url
        return url
    }

    func downloadDidFinish(_ dl: WKDownload) {
        if let u = downloads.removeValue(forKey: ObjectIdentifier(dl)) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        }
    }

    func download(_ dl: WKDownload, didFailWithError e: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(dl))
    }
}

// Reports the logged-in user (for game tracking) and draws your heart rate next to your clock.
let hrPageScript = #"""
(() => {
  if (window.ctHR) return;
  const post = o => { try { webkit.messageHandlers.ctHR.postMessage(o); } catch (e) {} };
  post({ user: (document.body && document.body.dataset.user) || null });
  let data = null, at = 0, el = null;
  const css = document.createElement('style');
  css.textContent = `#ct-hr{position:fixed;z-index:60;display:none;align-items:center;gap:5px;padding:0 9px;
    height:30px;border-radius:15px;background:rgba(0,0,0,.6);color:#fff;font:800 17px/1 system-ui,sans-serif;
    font-variant-numeric:tabular-nums;pointer-events:none;box-shadow:0 0 0 1px rgba(255,255,255,.12)}
    #ct-hr i{font-style:normal;color:var(--ct-hr,#ff3b5c);font-size:15px;animation:ct-hr-beat 1s infinite}
    #ct-hr b{color:var(--ct-hr,#fff)}
    @keyframes ct-hr-beat{0%,60%,100%{transform:scale(1)}20%{transform:scale(1.25)}}`;
  document.head.appendChild(css);
  function place() {
    const clock = document.querySelector('.rclock-bottom');
    const live = data && data.show && data.bpm && Date.now() - at < 5000;
    if (!clock || !live) { if (el) el.style.display = 'none'; return; }
    if (!el) { el = document.createElement('div'); el.id = 'ct-hr'; document.body.appendChild(el); }
    el.innerHTML = `<i>♥</i><b>${data.bpm}</b>`;
    el.style.setProperty('--ct-hr', data.color || '#fff');
    el.title = data.zone || '';
    el.style.display = 'flex';
    const r = clock.getBoundingClientRect();
    el.style.left = `${Math.round(r.right - el.offsetWidth - 8)}px`;
    el.style.top = `${Math.round(r.top + (r.height - el.offsetHeight) / 2)}px`;
  }
  window.ctHR = d => { data = d; at = Date.now(); place(); };
  setInterval(place, 500);
  addEventListener('resize', place);
})();
"""#

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
