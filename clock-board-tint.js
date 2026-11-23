// ==UserScript==
// @name         Clock board tint (lichess + chess.com)
// @namespace    hr_streamer
// @version      1.5
// @description  Tints the board squares as YOUR clock runs down (bottom clock): yellow, amber, red, then a pulse. Optional auto-queen.
// @match        https://lichess.org/*
// @match        https://www.chess.com/*
// @run-at       document-idle
// @grant        none
// ==/UserScript==

(() => {
  'use strict';

  // ---- Settings ---------------------------------------------------------
  // Tint starts at START seconds left and gets stronger towards 0.
  // Colours blend through the list as time drops (seconds -> colour).
  // The Mac app overrides these live via window.CT_SETTINGS (Tint menu).
  const DEFAULTS = {
    ENABLED: true,
    START: 60,
    STAGES: [
      { at: 60, color: [255, 200, 66] },   // yellow
      { at: 30, color: [255, 176, 32] },   // amber
      { at: 15, color: [255, 106, 0] },    // orange
      { at: 8,  color: [255, 31, 61] },    // red
    ],
    MAX_STRENGTH: 0.8,   // 0..1, how strongly the squares take the colour at 0 s
    CURVE: 1.6,          // >1 keeps it subtle early and ramps up late
    PULSE_BELOW: 5,      // seconds: pulse the tint when your clock is running and below this
    GLOW: true,          // coloured glow around the board as well
    CLEAR_AFTER: 3,      // seconds after the game ends (no clock running) before the tint fades
    PREVIEW: null,       // seconds: show the tint as if your clock read this (for setting up OBS)
    AUTO_QUEEN: false,   // pick the queen as soon as the promotion menu opens (hold Option to choose)
  };
  // -----------------------------------------------------------------------
  const S = () => Object.assign({}, DEFAULTS, window.CT_SETTINGS || {});

  const site = location.hostname.includes('lichess') ? 'lichess' : 'chesscom';

  // multiply (not colour) blend: gives a true red on the light squares instead of pink.
  const css = `
    :root { --ct-color: rgb(255,176,32); --ct-strength: 0; --ct-glow: 0px; }
    /* lichess: board image is cg-board::before, pieces are z-index 2 */
    .main-board cg-board::after {
      content: ''; position: absolute; inset: 0; z-index: 1; pointer-events: none;
      background: var(--ct-color); opacity: var(--ct-strength); mix-blend-mode: multiply;
      transition: opacity .25s linear, background-color .25s linear;
    }
    html.ct-fade .main-board cg-board::after, html.ct-fade wc-chess-board.board::before { transition: opacity 1.5s ease-out; }
    .main-board cg-container { box-shadow: 0 0 var(--ct-glow) calc(var(--ct-glow) / 6) var(--ct-color); }
    /* chess.com: board image is on wc-chess-board itself, pieces come after this layer */
    wc-chess-board.board::before {
      content: ''; position: absolute; inset: 0; pointer-events: none;
      background: var(--ct-color); opacity: var(--ct-strength); mix-blend-mode: multiply;
      transition: opacity .25s linear, background-color .25s linear;
    }
    wc-chess-board.board { box-shadow: 0 0 var(--ct-glow) calc(var(--ct-glow) / 6) var(--ct-color); }
    html.ct-pulse .main-board cg-board::after,
    html.ct-pulse wc-chess-board.board::before { animation: ct-pulse .6s ease-in-out infinite alternate; }
    @keyframes ct-pulse { from { opacity: calc(var(--ct-strength) * .45); } to { opacity: var(--ct-strength); } }
  `;
  const style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  // "1:02:03", "00:20", "0:09.3", "9.3" -> seconds
  function parseClock(text) {
    const t = (text || '').replace(/[^\d:.]/g, '');
    if (!t) return null;
    return t.split(':').reduce((acc, part) => acc * 60 + parseFloat(part || 0), 0);
  }

  function myClock() {
    // The bottom clock is yours when you're playing (the board faces you).
    const el = site === 'lichess'
      ? document.querySelector('.rclock-bottom')
      : document.querySelector('.clock-component.clock-bottom');
    if (!el) return null;
    const timeEl = site === 'lichess' ? el.querySelector('.time') : el.querySelector('.clock-time-monospace') || el;
    const running = site === 'lichess' ? el.classList.contains('running') : el.classList.contains('clock-player-turn');
    const secs = parseClock(timeEl && timeEl.textContent);
    return secs == null ? null : { secs, running };
  }

  function colourAt(secs, STAGES) {
    if (secs >= STAGES[0].at) return STAGES[0].color;
    for (let i = 0; i < STAGES.length - 1; i++) {
      const a = STAGES[i], b = STAGES[i + 1];
      if (secs <= a.at && secs >= b.at) {
        const f = (a.at - secs) / (a.at - b.at);
        return a.color.map((c, k) => Math.round(c + (b.color[k] - c) * f));
      }
    }
    return STAGES[STAGES.length - 1].color;
  }

  function anyClockRunning() {
    return !!document.querySelector(site === 'lichess'
      ? '.rclock.running'
      : '.clock-component.clock-player-turn');
  }

  const root = document.documentElement;
  let lastKey = '';
  let lastRunning = 0;
  function update() {
    const o = S();
    let c = myClock();
    if (anyClockRunning()) lastRunning = Date.now();
    // Game over (or not started): no clock has run for a few seconds -> no tint.
    let live = Date.now() - lastRunning < o.CLEAR_AFTER * 1000;
    if (o.PREVIEW != null) { c = { secs: o.PREVIEW, running: true }; live = true; }
    let strength = 0, colour = o.STAGES[0].color, pulse = false;
    if (o.ENABLED && c && live && c.secs < o.START) {
      strength = o.MAX_STRENGTH * Math.pow(1 - c.secs / o.START, o.CURVE);
      colour = colourAt(c.secs, o.STAGES);
      pulse = c.running && c.secs < o.PULSE_BELOW && c.secs > 0;
    }
    const key = `${strength.toFixed(3)}|${colour}|${pulse}|${o.GLOW}|${live}`;
    if (key === lastKey) return;
    lastKey = key;
    root.style.setProperty('--ct-strength', strength.toFixed(3));
    root.style.setProperty('--ct-color', `rgb(${colour.join(',')})`);
    root.style.setProperty('--ct-glow', o.GLOW ? `${Math.round(strength * 40)}px` : '0px');
    root.classList.toggle('ct-pulse', pulse);
    root.classList.toggle('ct-fade', !live);
  }

  setInterval(update, 100);

  // ---- Auto-queen -------------------------------------------------------
  // Clicks the queen the moment the promotion menu appears. Hold Option (Alt)
  // while making the move to get the normal menu and underpromote.
  let altHeld = false;
  addEventListener('keydown', e => { if (e.key === 'Alt') altHeld = true; }, true);
  addEventListener('keyup', e => { if (e.key === 'Alt') altHeld = false; }, true);
  addEventListener('blur', () => { altHeld = false; });

  function press(el) {
    const r = el.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, button: 0 };
    for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup'])
      el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, at));
    el.click();
  }

  function autoQueen() {
    if (!S().AUTO_QUEEN || altHeld) return;
    if (site === 'lichess') {
      const q = document.querySelector('#promotion-choice piece.queen');
      if (q) (q.closest('square') || q).click();
    } else {
      const q = document.querySelector('.promotion-window .promotion-piece.wq, .promotion-window .promotion-piece.bq');
      if (q) press(q);
    }
  }
  new MutationObserver(autoQueen).observe(document.documentElement, { childList: true, subtree: true });

  // ---- Auto-queen button (under your clock, only during games) ---------
  // In the Mac app the button flips the app setting (same as Play > Auto-Queen);
  // in Tampermonkey it's remembered in this browser.
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ctToggle;
  if (!bridge) {
    try {
      const saved = localStorage.getItem('ct-autoqueen');
      if (saved != null) window.CT_SETTINGS = Object.assign({}, window.CT_SETTINGS, { AUTO_QUEEN: saved === '1' });
    } catch (e) {}
  }
  const aqStyle = document.createElement('style');
  aqStyle.textContent = `
    #ct-aq { position: fixed; z-index: 100; display: none; box-sizing: border-box; height: 30px; padding: 0 12px;
      border-radius: 4px; border: 1px solid rgba(255,255,255,.14); background: rgba(38,36,33,.95); color: #999;
      font: 600 13px/28px 'Noto Sans', system-ui, sans-serif; letter-spacing: .02em; cursor: pointer; text-align: left;
      white-space: nowrap; transition: background .15s, color .15s, border-color .15s; }
    #ct-aq:hover { border-color: rgba(255,255,255,.3); }
    #ct-aq .q { font-size: 17px; margin-right: 6px; vertical-align: -1px; }
    #ct-aq .st { float: right; font-weight: 800; }
    #ct-aq.on { background: #3d5a1c; border-color: #629924; color: #fff; }
  `;
  document.head.appendChild(aqStyle);
  const aq = document.createElement('button');
  aq.id = 'ct-aq';
  aq.tabIndex = -1;
  aq.title = 'Auto-queen. Hold Option while promoting to pick another piece.';
  aq.addEventListener('mousedown', e => e.preventDefault());   // don't steal keyboard focus
  aq.addEventListener('click', e => {
    e.preventDefault();
    if (bridge) { bridge.postMessage('autoQueen'); return; }
    const v = !S().AUTO_QUEEN;
    window.CT_SETTINGS = Object.assign({}, window.CT_SETTINGS, { AUTO_QUEEN: v });
    try { localStorage.setItem('ct-autoqueen', v ? '1' : '0'); } catch (e) {}
    placeButton();
  });
  document.body.appendChild(aq);

  let aqKey = '';
  function placeButton() {
    const clock = document.querySelector(site === 'lichess' ? '.rclock-bottom' : '.clock-component.clock-bottom');
    const r = clock && clock.getBoundingClientRect();
    const show = !!(r && r.width && r.bottom + 40 < innerHeight);
    const on = !!S().AUTO_QUEEN;
    const key = show ? `${Math.round(r.left)}|${Math.round(r.bottom)}|${Math.round(r.width)}|${on}` : 'hidden';
    if (key === aqKey) return;
    aqKey = key;
    aq.style.display = show ? 'block' : 'none';
    if (!show) return;
    aq.style.left = `${r.left}px`;
    aq.style.top = `${r.bottom + 8}px`;
    aq.style.width = `${Math.max(150, r.width)}px`;
    aq.classList.toggle('on', on);
    aq.innerHTML = `<span class="q">♛</span>Auto-queen<span class="st">${on ? 'ON' : 'OFF'}</span>`;
  }
  setInterval(placeButton, 100);
  addEventListener('resize', placeButton);
})();
