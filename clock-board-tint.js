// ==UserScript==
// @name         Clock board tint (lichess + chess.com)
// @namespace    hr_streamer
// @version      1.2
// @description  Tints the board squares as YOUR clock runs down (bottom clock): yellow, amber, red, then a pulse.
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
  // Keep START equal to the first stage's `at`.
  const START = 60;
  const STAGES = [
    { at: 60, color: [255, 200, 66] },   // yellow
    { at: 30, color: [255, 176, 32] },   // amber
    { at: 15, color: [255, 106, 0] },    // orange
    { at: 8,  color: [255, 31, 61] },    // red
  ];
  const MAX_STRENGTH = 0.8;   // 0..1, how strongly the squares take the colour at 0 s
  const CURVE = 1.6;          // >1 keeps it subtle early and ramps up late
  const PULSE_BELOW = 5;      // seconds: pulse the tint when your clock is running and below this
  const GLOW = true;          // coloured glow around the board as well
  const CLEAR_AFTER = 3;      // seconds after the game ends (no clock running) before the tint fades
  // -----------------------------------------------------------------------

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

  function colourAt(secs) {
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
    const c = myClock();
    if (anyClockRunning()) lastRunning = Date.now();
    // Game over (or not started): no clock has run for a few seconds -> no tint.
    const live = Date.now() - lastRunning < CLEAR_AFTER * 1000;
    let strength = 0, colour = STAGES[0].color, pulse = false;
    if (c && live && c.secs < START) {
      strength = MAX_STRENGTH * Math.pow(1 - c.secs / START, CURVE);
      colour = colourAt(c.secs);
      pulse = c.running && c.secs < PULSE_BELOW && c.secs > 0;
    }
    const key = `${strength.toFixed(3)}|${colour}|${pulse}`;
    if (key === lastKey) return;
    lastKey = key;
    root.style.setProperty('--ct-strength', strength.toFixed(3));
    root.style.setProperty('--ct-color', `rgb(${colour.join(',')})`);
    root.style.setProperty('--ct-glow', GLOW ? `${Math.round(strength * 40)}px` : '0px');
    root.classList.toggle('ct-pulse', pulse);
    root.classList.toggle('ct-fade', !live);
  }

  setInterval(update, 100);
})();
