// ==UserScript==
// @name         Auto-Queen Toggle (Lichess + Chess.com)
// @namespace    https://local/auto-queen-toggle
// @version      1.0.0
// @description  Toggle automatic queen promotion on lichess.org and chess.com. Alt+Q toggles, hold Shift while promoting to pick a piece manually.
// @match        https://lichess.org/*
// @match        https://*.lichess.org/*
// @match        https://www.chess.com/*
// @match        https://chess.com/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  const STORAGE_KEY = 'autoQueenEnabled';
  const HOTKEY = { key: 'q', altKey: true }; // Alt+Q (Option+Q on macOS)
  const BYPASS_KEY = 'Shift'; // hold while making the move to choose manually

  const host = location.hostname;
  const SITE = host.endsWith('lichess.org') ? 'lichess' : host.endsWith('chess.com') ? 'chesscom' : null;
  if (!SITE) return;

  // Selectors for the queen button inside each site's promotion picker.
  const QUEEN_SELECTORS = {
    lichess: [
      '#promotion-choice square:has(piece.queen)',
      '#promotion-choice piece.queen',
    ],
    chesscom: [
      '.promotion-window .promotion-piece.wq',
      '.promotion-window .promotion-piece.bq',
      '.promotion-piece.wq',
      '.promotion-piece.bq',
    ],
  }[SITE];

  let enabled = GM_getValue(STORAGE_KEY, true);
  let bypassHeld = false;

  // ---------- UI ----------
  const badge = document.createElement('button');
  badge.type = 'button';
  badge.title = 'Toggle auto-queen (Alt+Q). Hold Shift while promoting to choose manually.';
  Object.assign(badge.style, {
    position: 'fixed',
    bottom: '12px',
    left: '12px',
    zIndex: '2147483647',
    padding: '6px 10px',
    border: 'none',
    borderRadius: '6px',
    font: '600 13px/1.2 system-ui, sans-serif',
    color: '#fff',
    cursor: 'pointer',
    boxShadow: '0 2px 6px rgba(0,0,0,.35)',
    opacity: '0.85',
  });
  badge.addEventListener('mouseenter', () => (badge.style.opacity = '1'));
  badge.addEventListener('mouseleave', () => (badge.style.opacity = '0.85'));
  badge.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    toggle();
  });

  function render() {
    badge.textContent = `♛ Auto-queen: ${enabled ? 'ON' : 'OFF'}`;
    badge.style.background = enabled ? '#3a8a3a' : '#7a7a7a';
  }

  function mountBadge() {
    if (!document.body) return;
    if (!badge.isConnected) document.body.appendChild(badge);
  }

  function toggle() {
    enabled = !enabled;
    GM_setValue(STORAGE_KEY, enabled);
    render();
    if (enabled) tryAutoQueen();
  }

  GM_registerMenuCommand('Toggle auto-queen', toggle);

  // ---------- Keyboard ----------
  function isTyping(target) {
    if (!target) return false;
    const tag = target.tagName;
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable;
  }

  window.addEventListener(
    'keydown',
    (e) => {
      if (e.key === BYPASS_KEY) bypassHeld = true;
      if (
        e.code === 'KeyQ' &&
        e.altKey === HOTKEY.altKey &&
        !e.ctrlKey &&
        !e.metaKey &&
        !isTyping(e.target)
      ) {
        e.preventDefault();
        e.stopPropagation();
        toggle();
      }
    },
    true
  );
  window.addEventListener('keyup', (e) => {
    if (e.key === BYPASS_KEY) bypassHeld = false;
  }, true);
  window.addEventListener('blur', () => (bypassHeld = false));

  // ---------- Auto-click ----------
  function findQueen() {
    for (const sel of QUEEN_SELECTORS) {
      let el;
      try {
        el = document.querySelector(sel);
      } catch (_) {
        continue; // e.g. :has() unsupported
      }
      if (el && el.getClientRects().length) return el;
    }
    return null;
  }

  function fire(el, type, Ctor) {
    const r = el.getBoundingClientRect();
    const opts = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      button: 0,
      buttons: type.endsWith('down') ? 1 : 0,
      clientX: r.left + r.width / 2,
      clientY: r.top + r.height / 2,
    };
    if (Ctor === PointerEvent) Object.assign(opts, { pointerId: 1, pointerType: 'mouse', isPrimary: true });
    el.dispatchEvent(new Ctor(type, opts));
  }

  function clickLikeUser(el) {
    if (SITE === 'lichess') {
      // Lichess listens for a click on the promotion square.
      el.click();
      return;
    }
    // Chess.com reacts to pointer/mouse events; send the full sequence.
    fire(el, 'pointerdown', PointerEvent);
    fire(el, 'mousedown', MouseEvent);
    fire(el, 'pointerup', PointerEvent);
    fire(el, 'mouseup', MouseEvent);
    fire(el, 'click', MouseEvent);
  }

  let pending = false;
  function tryAutoQueen() {
    if (!enabled || bypassHeld || pending) return;
    const queen = findQueen();
    if (!queen) return;
    pending = true;
    // Let the site finish wiring up its handlers before we click.
    requestAnimationFrame(() => {
      pending = false;
      if (!enabled || bypassHeld) return;
      const q = findQueen();
      if (!q) return;
      clickLikeUser(q);
      // Fallback for lichess if a plain click didn't close the picker.
      if (SITE === 'lichess') {
        setTimeout(() => {
          const still = findQueen();
          if (still && enabled && !bypassHeld) {
            fire(still, 'mousedown', MouseEvent);
            fire(still, 'mouseup', MouseEvent);
          }
        }, 60);
      }
    });
  }

  const observer = new MutationObserver(() => {
    mountBadge();
    tryAutoQueen();
  });

  function start() {
    render();
    mountBadge();
    observer.observe(document.documentElement, { childList: true, subtree: true });
    tryAutoQueen();
  }

  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start, { once: true });
})();
