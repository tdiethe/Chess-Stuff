// Heart rate inside Lichess Desk: the Swift version of ../hr-overlay/hr_overlay.py + chess_feed.py.
// - Reads any Bluetooth watch that broadcasts the standard Heart Rate service (e.g. a Garmin Fenix
//   with "Broadcast Heart Rate" on), or a fake heart rate in demo mode.
// - Serves the same overlay page and event stream on http://127.0.0.1:8765/, so an OBS Browser
//   Source set up for the Python bridge keeps working unchanged.
// - Follows your lichess games (username taken from the logged-in page) for the scoreboard,
//   per-game peaks and the post-game card.

import AppKit
import CoreBluetooth
import Network

let hrServiceUUID = CBUUID(string: "180D")
let hrMeasurementUUID = CBUUID(string: "2A37")
let hrHistorySeconds = 300.0     // trace length shown under the number
let hrRecentGames = 10           // tiles in the recent-games widget
let hrUserAgent = "LichessDesk/1.0 (heart-rate overlay; github.com/tdiethe/Chess-Stuff)"

private func orNull(_ v: Any?) -> Any { v ?? NSNull() }

private func jsonString(_ o: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys) else { return "{}" }
    return String(data: d, encoding: .utf8) ?? "{}"
}

func appSupportDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Lichess Desk", isDirectory: true)
}

// MARK: - zones (same zones.toml format as the Python bridge)

struct HRZones {
    struct Zone { let name: String; let from: Int; let color: String }
    var zones: [Zone]
    var spike: Int
    var cardZone: String

    static let fallback = HRZones(zones: [Zone(name: "", from: 0, color: "#ffffff")], spike: 15, cardZone: "")

    var json: [String: Any] {
        ["zones": zones.map { ["name": $0.name, "from": $0.from, "color": $0.color] },
         "spike": spike, "card_zone": cardZone]
    }

    func zone(for bpm: Int) -> Zone { zones.last(where: { bpm >= $0.from }) ?? zones[0] }

    struct ParseError: Error, CustomStringConvertible { let description: String }

    /// Reads the small subset of TOML that zones.toml uses: `key = value` lines, `[[zone]]` tables,
    /// quoted strings, integers and `#` comments.
    static func parse(_ text: String) throws -> HRZones {
        var top: [String: String] = [:]
        var tables: [[String: String]] = []
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = "", inQuote = false
            for ch in raw {
                if ch == "\"" { inQuote.toggle() }
                if ch == "#" && !inQuote { break }
                line.append(ch)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "[[zone]]" { tables.append([:]); continue }
            guard let eq = line.firstIndex(of: "=") else { throw ParseError(description: "line \(n + 1): expected key = value") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            if tables.isEmpty { top[key] = val } else { tables[tables.count - 1][key] = val }
        }
        let zones = try tables.map { t -> Zone in
            guard let name = t["name"], let from = t["from"].flatMap({ Int($0) }) else {
                throw ParseError(description: "every [[zone]] needs a name and a whole-number from")
            }
            return Zone(name: name, from: from, color: t["color"] ?? "#ffffff")
        }.sorted { $0.from < $1.from }
        if zones.isEmpty { throw ParseError(description: "no [[zone]] entries") }
        let card = top["card_zone"] ?? zones.last!.name
        if !zones.contains(where: { $0.name == card }) {
            throw ParseError(description: "card_zone \"\(card)\" isn't one of the zone names")
        }
        return HRZones(zones: zones, spike: top["spike"].flatMap { Int($0) } ?? 15, cardZone: card)
    }
}

// MARK: - games and scoreboard (port of chess_feed.Tracker)

struct HRGame {
    var id: String, site: String, perf: String
    var start: Double, end: Double
    var result: String          // win | loss | draw
    var opponent: String
    var oppRating: Int?, rating: Int?, ratingDiff: Int?

    var json: [String: Any] {
        ["id": id, "site": site, "perf": perf, "start": start, "end": end, "result": result,
         "opponent": opponent, "opp_rating": orNull(oppRating), "rating": orNull(rating),
         "rating_diff": orNull(ratingDiff)]
    }

    /// One game from lichess's games export (ndjson); nil while it's still being played.
    init?(lichess j: [String: Any], user: String) {
        let status = j["status"] as? String
        guard status != "created", status != "started", let id = j["id"] as? String,
              let players = j["players"] as? [String: Any],
              let white = players["white"] as? [String: Any], let black = players["black"] as? [String: Any],
              let created = (j["createdAt"] as? NSNumber)?.doubleValue else { return nil }
        let meWhite = ((white["user"] as? [String: Any])?["id"] as? String) == user.lowercased()
        let me = meWhite ? white : black, opp = meWhite ? black : white
        let winner = j["winner"] as? String
        self.id = id
        site = "lichess"
        perf = (j["perf"] as? String) ?? (j["speed"] as? String) ?? "?"
        start = created / 1000
        end = ((j["lastMoveAt"] as? NSNumber)?.doubleValue ?? created) / 1000
        result = winner == nil ? "draw" : ((winner == "white") == meWhite ? "win" : "loss")
        opponent = ((opp["user"] as? [String: Any])?["name"] as? String) ?? (opp["aiLevel"] != nil ? "AI" : "anon")
        oppRating = opp["rating"] as? Int
        ratingDiff = me["ratingDiff"] as? Int
        let r = me["rating"] as? Int
        rating = r.map { $0 + (ratingDiff ?? 0) }
    }

    init(id: String, site: String, perf: String, start: Double, end: Double, result: String,
         opponent: String, oppRating: Int?, rating: Int?, ratingDiff: Int?) {
        (self.id, self.site, self.perf, self.start, self.end, self.result) = (id, site, perf, start, end, result)
        (self.opponent, self.oppRating, self.rating, self.ratingDiff) = (opponent, oppRating, rating, ratingDiff)
    }
}

final class HRTracker {
    var games: [String: [HRGame]] = [:]
    var current: [String: [String: Int]] = [:]     // site -> perf -> rating now
    var baseline: [String: [String: Int]] = [:]    // site -> perf -> rating at start of day
    var lastSite: String?
    var peaks: [String: Int] = [:]                 // game id -> heart-rate peak
    let defaultPerf = "bullet"

    func setGames(_ site: String, _ list: [HRGame]) {
        games[site] = list.sorted { $0.end < $1.end }
        for g in games[site]! { if let r = g.rating { current[site, default: [:]][g.perf] = r } }
    }

    func reset() { games = [:]; current = [:]; baseline = [:]; lastSite = nil; peaks = [:] }

    func board() -> [String: Any]? {
        let everything = games.values.flatMap { $0 }
        guard let site = everything.max(by: { $0.end < $1.end })?.site ?? lastSite else { return nil }
        let gs = games[site] ?? []
        let perf = gs.last?.perf ?? defaultPerf
        let rating = current[site]?[perf], base = baseline[site]?[perf]
        var streak = ""
        if let r = gs.last?.result {
            let n = gs.reversed().prefix { $0.result == r }.count
            streak = "\(r.prefix(1).uppercased())\(n)"
        }
        var best = ["win": 0, "loss": 0]
        var runR: String? = nil, runN = 0
        for g in gs {
            runN = g.result == runR ? runN + 1 : 1
            runR = g.result
            if let b = best[g.result] { best[g.result] = max(b, runN) }
        }
        let recent: [[String: Any]] = gs.suffix(hrRecentGames).map { g in
            ["id": g.id, "r": g.result.prefix(1).uppercased(), "diff": orNull(g.ratingDiff),
             "opp": g.opponent, "opp_rating": orNull(g.oppRating), "peak": orNull(peaks[g.id])]
        }
        return [
            "site": site, "perf": perf, "rating": orNull(rating),
            "delta": orNull(rating.flatMap { r in base.map { r - $0 } }),
            "w": gs.filter { $0.result == "win" }.count,
            "l": gs.filter { $0.result == "loss" }.count,
            "d": gs.filter { $0.result == "draw" }.count,
            "streak": streak, "best_w": best["win"]!, "best_l": best["loss"]!,
            "recent": recent,
        ]
    }
}

// MARK: - lichess feed (port of chess_feed.lichess_feed)

@MainActor
final class LichessFeed {
    let user: String
    let tracker: HRTracker
    var onStart: (Double) -> Void = { _ in }
    var onEnd: (HRGame) -> Void = { _ in }
    var onChange: () -> Void = {}
    private var seen: Set<String>? = nil
    private var task: Task<Void, Never>?

    init(user: String, tracker: HRTracker) { self.user = user; self.tracker = tracker }

    func start() { task = Task { await run() } }
    func stop() { task?.cancel(); task = nil }

    private func get(_ url: String, accept: String = "application/json") async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        req.setValue(hrUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private var name: String { user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user }

    func refresh() async throws {
        let since = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let (data, code) = try await get("https://lichess.org/api/games/user/\(name)?since=\(since)&moves=false",
                                         accept: "application/x-ndjson")
        guard code == 200 else { throw URLError(.badServerResponse) }
        let games = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> HRGame? in
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return HRGame(lichess: j, user: user)
        }
        tracker.setGames("lichess", games)
        // Rating at start of day = my pre-game rating in the first game today, per perf.
        var first: [String: Int] = [:]
        for g in tracker.games["lichess"]! where first[g.perf] == nil {
            if let r = g.rating, let d = g.ratingDiff { first[g.perf] = r - d }
        }
        tracker.baseline["lichess", default: [:]].merge(first) { _, new in new }
        if games.isEmpty && tracker.current["lichess"] == nil {
            // No games yet today: show the current rating.
            let (d, c) = try await get("https://lichess.org/api/user/\(name)")
            if c == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let perfs = j["perfs"] as? [String: Any] {
                for (p, v) in perfs {
                    if let r = (v as? [String: Any])?["rating"] as? Int {
                        tracker.current["lichess", default: [:]][p] = r
                        if tracker.baseline["lichess"]?[p] == nil { tracker.baseline["lichess", default: [:]][p] = r }
                    }
                }
            }
        }
        if tracker.lastSite == nil { tracker.lastSite = "lichess" }
        let ids = tracker.games["lichess"]!.map(\.id)
        let fresh = seen == nil ? [] : tracker.games["lichess"]!.filter { !seen!.contains($0.id) }
        seen = Set(ids)
        fresh.forEach(onEnd)
        onChange()
    }

    private func waitForResult(_ id: String) {
        Task {
            // The finished game can take a moment to show up in the games list.
            for _ in 0..<15 {
                if Task.isCancelled || task == nil { return }
                try? await refresh()
                if seen?.contains(id) == true { return }
                await pause(2)
            }
        }
    }

    private func run() async {
        try? await refresh()
        var current: String? = nil
        var done = Set<String>()
        var misses = 0, first = true
        var lastFull = Date()
        // A new playingId means a game started; playing -> not playing (or a new id) means it ended.
        while !Task.isCancelled {
            do {
                let (data, code) = try await get("https://lichess.org/api/users/status?ids=\(name)&withGameIds=true")
                if code == 429 { await pause(60); continue }      // lichess asks for a minute's pause
                guard code == 200 else { await pause(10); continue }
                let st = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]])?.first ?? [:]
                let playing = (st["playing"] as? Bool) == true ? st["playingId"] as? String : nil
                if playing == current {
                    misses = 0
                } else if playing == nil, let cur = current {
                    // The status briefly says "not playing" mid-game now and then: wait for two misses.
                    misses += 1
                    if misses >= 2 {
                        done.insert(cur); waitForResult(cur)
                        current = nil; misses = 0
                    }
                } else {
                    if let cur = current, !done.contains(cur) { done.insert(cur); waitForResult(cur) }
                    if let p = playing, !done.contains(p), !first { onStart(Date().timeIntervalSince1970) }
                    current = playing; misses = 0
                }
                first = false
                if Date().timeIntervalSince(lastFull) > 60 {      // slow safety-net refresh
                    lastFull = Date()
                    try? await refresh()
                }
                await pause(3)
            } catch {
                await pause(10)
            }
        }
    }
}

// MARK: - overlay server (same routes as the Python bridge)

@MainActor
final class OverlayServer {
    let port: UInt16
    var page: () -> Data = { Data() }
    var snapshot: (Bool) -> String = { _ in "{}" }
    var onNewGame: () -> Void = {}
    var onState: (String?) -> Void = { _ in }        // nil = serving, otherwise a problem to show
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var ping: Timer?
    private var retry: Timer?
    private(set) var serving = false

    init(port: UInt16) { self.port = port }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        // No address reuse: if the Python bridge (or anything else) holds the port, fail and retry rather than share it.
        params.allowLocalEndpointReuse = false
        guard let l = try? NWListener(using: params) else { scheduleRetry("couldn't open port \(port)"); return }
        listener = l
        l.stateUpdateHandler = { [weak self] st in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch st {
                case .ready:
                    self.serving = true
                    self.onState(nil)
                case .failed(let e):
                    self.serving = false
                    self.listener?.cancel(); self.listener = nil
                    if case .posix(.EADDRINUSE) = e {
                        self.scheduleRetry("port \(self.port) is in use (is the Python bridge still running?)")
                    } else {
                        self.scheduleRetry("overlay server stopped: \(e)")
                    }
                default: break
                }
            }
        }
        l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.accept(c) } }
        l.start(queue: .main)
        ping = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(raw: ": ping\n\n") }
        }
    }

    func stop() {
        retry?.invalidate(); retry = nil
        ping?.invalidate(); ping = nil
        listener?.cancel(); listener = nil
        clients.values.forEach { $0.cancel() }
        clients = [:]
        serving = false
    }

    private func scheduleRetry(_ why: String) {
        onState(why)
        ping?.invalidate(); ping = nil
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry = nil; self?.start() }
        }
    }

    func broadcast(_ msg: String) { send(raw: "data: \(msg)\n\n") }

    private func send(raw: String) {
        let data = Data(raw.utf8)
        for (key, c) in clients {
            c.send(content: data, completion: .contentProcessed { [weak self] err in
                if err != nil { MainActor.assumeIsolated { self?.drop(key) } }
            })
        }
    }

    private func drop(_ key: ObjectIdentifier) { clients.removeValue(forKey: key)?.cancel() }

    private func accept(_ c: NWConnection) {
        let key = ObjectIdentifier(c)
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: MainActor.assumeIsolated { _ = self?.clients.removeValue(forKey: key) }
            default: break
            }
        }
        c.start(queue: .main)
        readRequest(c, so: Data())
    }

    private func readRequest(_ c: NWConnection, so far: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, err in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = far
                if let data { buf.append(data) }
                if buf.range(of: Data("\r\n\r\n".utf8)) != nil || buf.count > 16384 || complete || err != nil {
                    self.respond(c, String(decoding: buf, as: UTF8.self))
                } else {
                    self.readRequest(c, so: buf)
                }
            }
        }
    }

    private func respond(_ c: NWConnection, _ request: String) {
        let first = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = first.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "/") : "/"

        if path == "/events" {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
                + "Connection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            // First message carries the recent history so a reloaded overlay redraws the trace.
            c.send(content: Data((head + "data: \(snapshot(true))\n\n").utf8), completion: .contentProcessed { _ in })
            clients[ObjectIdentifier(c)] = c
            return
        }
        var body = Data(), type = "text/plain"
        switch path {
        case "/", "/index.html": body = page(); type = "text/html; charset=utf-8"
        case "/hr.txt": body = Data(hrText().utf8)
        case "/newgame": onNewGame(); body = Data("new game started\n".utf8)
        case "/whoami": body = Data("lichess-desk".utf8)
        default:
            c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                   completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    var hrText: () -> String = { "--" }
}

// MARK: - the heart-rate hub: Bluetooth, state, games

@MainActor
final class HeartRate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Seen { let name: String; var rssi: Int; var hasHR: Bool }

    // State sent to the overlay (same fields as the Python bridge).
    private(set) var bpm: Int?
    private(set) var ts = 0.0
    private(set) var device: String?
    private(set) var status = "off"
    private var peak: Int?
    private(set) var zones = HRZones.fallback
    private var board: [String: Any]?
    private var card: [String: Any]?
    private var history: [(Double, Int)] = []
    private var session: [(Double, Int)] = []        // ~6 h of readings, for game cards
    private var gameStarts: [Double] = []

    var onUpdate: () -> Void = {}                     // any change (menu status, in-window badge)
    var wantedName: String = ""                      // part of the watch's name; empty = first HR broadcaster
    private(set) var running = false
    private(set) var demo = false
    private(set) var seenDevices: [UUID: Seen] = [:]

    private let server: OverlayServer
    private let tracker = HRTracker()
    private var feed: LichessFeed?
    private(set) var user: String?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rejected = Set<UUID>()               // connected but had no heart-rate service
    private var demoTimer: Timer?
    private var zonesTimer: Timer?
    private var scanTimer: Timer?
    private var zonesMTime: Date?
    private(set) var serverProblem: String?

    let port: UInt16
    var overlayURL: String { "http://127.0.0.1:\(port)/" }
    static var zonesFile: URL { appSupportDir().appendingPathComponent("zones.toml") }

    init(port: UInt16) {
        self.port = port
        server = OverlayServer(port: port)
        super.init()
        server.page = {
            Bundle.main.url(forResource: "overlay", withExtension: "html").flatMap { try? Data(contentsOf: $0) }
                ?? Data("overlay.html missing from the app bundle".utf8)
        }
        server.snapshot = { [unowned self] h in self.snapshot(withHistory: h) }
        server.onNewGame = { [unowned self] in self.newGame() }
        server.hrText = { [unowned self] in self.bpm.map(String.init) ?? "--" }
        server.onState = { [unowned self] p in self.serverProblem = p; self.onUpdate() }
    }

    // MARK: on / off

    func start(demo: Bool) {
        stop()
        running = true
        self.demo = demo
        loadZones()
        zonesTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadZones() }
        }
        server.start()
        if demo { startDemo() } else { startBluetooth() }
        if let u = user { startFeed(u) }
        onUpdate()
    }

    func stop() {
        running = false
        demoTimer?.invalidate(); demoTimer = nil
        zonesTimer?.invalidate(); zonesTimer = nil
        scanTimer?.invalidate(); scanTimer = nil
        if let c = central {
            if c.isScanning { c.stopScan() }
            if let p = peripheral { c.cancelPeripheralConnection(p) }
        }
        peripheral = nil
        feed?.stop(); feed = nil
        server.stop()
        serverProblem = nil
        bpm = nil; device = nil; status = "off"
        onUpdate()
    }

    /// The logged-in lichess user, as reported by the page.
    func setUser(_ name: String?) {
        guard let name, !name.isEmpty, name.lowercased() != user?.lowercased() else { return }
        user = name
        if running { startFeed(name) }
    }

    private func startFeed(_ name: String) {
        feed?.stop()
        tracker.reset()
        let f = LichessFeed(user: name, tracker: tracker)
        f.onStart = { [unowned self] at in self.newGame(at: at) }
        f.onEnd = { [unowned self] g in self.gameEnded(g) }
        f.onChange = { [unowned self] in self.boardChanged() }
        feed = f
        f.start()
    }

    // MARK: overlay state

    func snapshot(withHistory: Bool = false) -> String {
        var m: [String: Any] = [
            "bpm": orNull(bpm), "ts": Int((ts * 1000).rounded()), "status": status, "device": orNull(device),
            "peak": orNull(peak), "zones": zones.json, "games": gameStarts.map { Int(($0 * 1000).rounded()) },
            "board": orNull(board), "card": orNull(card),
        ]
        if withHistory { m["history"] = history.map { [Int(($0.0 * 1000).rounded()), $0.1] } }
        return jsonString(m)
    }

    private func broadcast() { server.broadcast(snapshot()); onUpdate() }

    func publish(bpm b: Int? = nil, status s: String? = nil) {
        if let b {
            let now = Date().timeIntervalSince1970
            bpm = b; ts = now
            peak = max(peak ?? b, b)
            history.append((now, b)); session.append((now, b))
            history.removeAll { $0.0 < now - hrHistorySeconds }
            if session.count > 6 * 3600 { session.removeFirst(session.count - 6 * 3600) }
            gameStarts.removeAll { $0 < now - hrHistorySeconds }
        }
        if let s { status = s }
        broadcast()
    }

    func newGame(at: Double? = nil, mark: Bool = true) {
        let at = at ?? Date().timeIntervalSince1970
        peak = bpm
        if mark && gameStarts.allSatisfy({ abs(at - $0) > 10 }) {
            gameStarts.append(at); gameStarts.sort()
        }
        broadcast()
    }

    private func readings(_ g: HRGame) -> [(Double, Int)] { session.filter { $0.0 >= g.start && $0.0 <= g.end + 2 } }

    private func gameEnded(_ g: HRGame) {
        var c = g.json
        c["at"] = Int(Date().timeIntervalSince1970 * 1000)
        c["avg"] = NSNull(); c["peak"] = NSNull(); c["panic_s"] = 0
        let r = readings(g)
        if !r.isEmpty {
            let vals = r.map(\.1)
            c["avg"] = Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
            c["peak"] = vals.max()!
            tracker.peaks[g.id] = vals.max()!
            if let limit = zones.zones.first(where: { $0.name == zones.cardZone })?.from {
                c["panic_label"] = zones.cardZone
                var s = 0.0
                for (a, b) in zip(r, r.dropFirst()) where a.1 >= limit { s += min(b.0 - a.0, 5) }
                c["panic_s"] = Int(s.rounded())
            }
        }
        card = c
        // Mark where the game began, and start the next game's peak from here.
        newGame(at: g.start)
    }

    private func boardChanged() {
        // Heart-rate peaks for today's games we have readings for (the recent-games tiles).
        for g in tracker.games.values.joined() where tracker.peaks[g.id] == nil {
            if let m = readings(g).map(\.1).max() { tracker.peaks[g.id] = m }
        }
        board = tracker.board()
        broadcast()
    }

    // MARK: zones.toml

    /// Your zones file (created from the defaults the first time), for editing.
    func zonesFileForEditing() -> URL? {
        let f = HeartRate.zonesFile
        if !FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.createDirectory(at: appSupportDir(), withIntermediateDirectories: true)
            guard let def = Bundle.main.url(forResource: "zones", withExtension: "toml"),
                  (try? FileManager.default.copyItem(at: def, to: f)) != nil else { return nil }
        }
        return f
    }

    private func loadZones() {
        let user = HeartRate.zonesFile
        let file = FileManager.default.fileExists(atPath: user.path) ? user
            : Bundle.main.url(forResource: "zones", withExtension: "toml")
        guard let file else { return }
        let m = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if m != nil && m == zonesMTime { return }
        zonesMTime = m
        // A broken edit keeps the previous zones.
        if let text = try? String(contentsOf: file, encoding: .utf8), let z = try? HRZones.parse(text) {
            zones = z
            broadcast()
        }
    }

    // MARK: demo

    private func startDemo() {
        device = "demo"
        publish(status: "demo mode")
        let t0 = Date()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Calm baseline with a time-scramble spike every ~50 s.
                let t = Date().timeIntervalSince(t0).truncatingRemainder(dividingBy: 50)
                let spike = 45 * exp(-pow((t - 30) / 6, 2))
                self?.publish(bpm: Int(66 + 4 * sin(t / 5) + spike) + Int.random(in: -1...1))
            }
        }
    }

    // MARK: Bluetooth

    private func startBluetooth() {
        if let c = central { if c.state == .poweredOn { scan() } else { centralManagerDidUpdateState(c) } }
        else { central = CBCentralManager(delegate: self, queue: .main) }   // asks for permission the first time
    }

    /// Picks a different watch (or "" for the first heart-rate broadcaster) and reconnects.
    func choose(_ name: String) {
        wantedName = name
        rejected = []
        guard running, !demo, let c = central else { return }
        if let p = peripheral { c.cancelPeripheralConnection(p); peripheral = nil }
        bpm = nil; device = nil
        scan()
    }

    private func matches(_ name: String, hasHR: Bool) -> Bool {
        // Match by name alone when one is set: some watches don't list the HR service in their advertisement.
        wantedName.isEmpty ? hasHR : name.lowercased().contains(wantedName.lowercased())
    }

    private func scan() {
        guard running, !demo, let c = central, c.state == .poweredOn, peripheral == nil else { return }
        // A watch that's already connected to this Mac won't advertise.
        if let p = c.retrieveConnectedPeripherals(withServices: [hrServiceUUID])
            .first(where: { matches($0.name ?? "", hasHR: true) && !rejected.contains($0.identifier) }) {
            connect(p, name: p.name ?? "heart-rate monitor")
            return
        }
        publish(status: "scanning for heart-rate broadcasters…")
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.peripheral == nil, self.running else { return }
                self.publish(status: self.wantedName.isEmpty
                    ? "no heart-rate broadcaster found: is Broadcast Heart Rate on? Still looking"
                    : "no watch named \"\(self.wantedName)\" found: is Broadcast Heart Rate on? Still looking")
            }
        }
    }

    private func connect(_ p: CBPeripheral, name: String) {
        guard let c = central else { return }
        if c.isScanning { c.stopScan() }
        scanTimer?.invalidate(); scanTimer = nil
        peripheral = p
        p.delegate = self
        device = name
        publish(status: "connecting to \(name)…")
        c.connect(p)
    }

    private func reconnectSoon() {
        peripheral = nil
        guard running else { return }
        publish(status: "disconnected, reconnecting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            guard running, !demo else { return }
            switch c.state {
            case .poweredOn: scan()
            case .poweredOff: publish(status: "Bluetooth is off")
            case .unauthorized:
                publish(status: "no Bluetooth permission: allow Lichess Desk in System Settings › Privacy & Security › Bluetooth")
            case .unsupported: publish(status: "this Mac has no Bluetooth LE")
            default: break
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData adv: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated {
            let name = p.name ?? adv[CBAdvertisementDataLocalNameKey] as? String ?? ""
            let hasHR = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(hrServiceUUID) ?? false
            if !name.isEmpty {
                let was = seenDevices[p.identifier]
                seenDevices[p.identifier] = Seen(name: name, rssi: rssi.intValue, hasHR: hasHR || (was?.hasHR ?? false))
            }
            if peripheral == nil, running, !rejected.contains(p.identifier), matches(name, hasHR: hasHR) {
                connect(p, name: name.isEmpty ? "heart-rate monitor" : name)
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            publish(status: "connected to \(device ?? "watch")")
            p.discoverServices([hrServiceUUID])
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if p == peripheral { reconnectSoon() } }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if p == peripheral { bpm = nil; reconnectSoon() } }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == hrServiceUUID }) else {
                rejected.insert(p.identifier)
                publish(status: "\(device ?? "that device") has no heart rate: turn on Broadcast Heart Rate, or pick another watch")
                central?.cancelPeripheralConnection(p)
                return
            }
            p.discoverCharacteristics([hrMeasurementUUID], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let ch = s.characteristics?.first(where: { $0.uuid == hrMeasurementUUID }) { p.setNotifyValue(true, for: ch) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, v.count >= 2 else { return }
        // Heart Rate Measurement: flags byte, then bpm as uint8, or uint16 little-endian if bit 0 is set.
        let b = v[v.startIndex] & 1 == 1 && v.count >= 3
            ? Int(v[v.startIndex + 1]) | Int(v[v.startIndex + 2]) << 8
            : Int(v[v.startIndex + 1])
        MainActor.assumeIsolated { if b > 0 { publish(bpm: b) } }
    }
}
