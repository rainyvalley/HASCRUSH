/* HASSCrush touch bar - injected into ttyd's custom index page (ttyd --index).
 * A fixed bar at the bottom of the web terminal for touch devices:
 *   sticky: Ctrl / Alt / Tab (latch; the next input event composes them,
 *           then they auto-disarm; tapping a latched key again disarms early)
 *   momentary: Esc / Del (synthetic keydowns, so xterm.js computes the same
 *           mode-aware sequences a physical key would) / Paste (clipboard.
 *           Falls back to a paste-into-box dialog when the Clipboard API is
 *           unavailable, e.g. plain-http ingress).
 * Always on (touch or desktop, bar or not): the clipboard helpers. ttyd 1.7.x
 * ships no OSC 52 handler, so a copy from tmux or from Crush itself (both emit
 * OSC 52) was silently discarded; here OSC 52 becomes a real clipboard write,
 * a mouse selection (Shift+drag) is copied on release, and when the browser
 * refuses a clipboard write (plain-http origin, no user gesture) a small
 * tap-to-copy toast / selectable text box is shown instead.
 * Composition happens at the WebSocket send layer (the ttyd pty wire format is
 * one 0x30 input frame followed by raw bytes), so soft-keyboard, external
 * keyboard and composition input are all intercepted at once. Everything here
 * is additive: any failure removes (never blocks) the terminal.
 * This file must never contain the page-closing script tag string: it is
 * inlined into an HTML page, where such a literal would end the block early.
 */
(function () {
  'use strict';
  if (window.__hassbar) return;
  window.__hassbar = { v: 1 };

  var cfg = window.__HASSBAR || {};
  var THEME = cfg.theme === 'light' ? 'light' : 'dark';
  /* Keyboard-inset trim. 0 = platform default: iOS/iPadOS over-reports the
   * keyboard height by about 40px, Android/desktop do not. Any non-zero
   * option value overrides the platform default outright (Android users on
   * quirky devices set their own; iOS users who want no trim set +40). */
  function platformOffset() {
    try {
      var nav = window.navigator || {};
      var ua = String(nav.userAgent || '');
      var iOS = /iPad|iPhone|iPod/.test(ua) ||
        (nav.platform === 'MacIntel' && (nav.maxTouchPoints || 0) > 1); /* iPadOS 13+ */
      return iOS ? -40 : 0;
    } catch (e) { return 0; }
  }
  var USER_OFFSET = parseInt(cfg.offset, 10);
  if (!isFinite(USER_OFFSET)) USER_OFFSET = 0;
  USER_OFFSET = Math.max(-400, Math.min(400, USER_OFFSET));
  var OFFSET = USER_OFFSET !== 0 ? USER_OFFSET : platformOffset();
  /* Diagnostic overlay (touch_bar_debug): prints the raw viewport numbers
   * above the bar so a phone/browser that misreports its keyboard inset can
   * be diagnosed from a screenshot instead of guesswork. */
  var DEBUG = !!cfg.debug;
  var diagEl = null;
  var BAR_H = 44;

  /* Floating pill styling: no full-width backdrop strip - the bar element is
   * transparent and click-through outside the buttons, so nothing dark sits
   * between the terminal and the keyboard; each key is a compact translucent
   * pill that stays legible over terminal text. */
  var COLORS = THEME === 'light'
    ? { pill: 'rgba(239,241,245,0.88)', fg: '#4c4f69', fgDim: 'rgba(76,79,105,0.70)',
        press: 'rgba(76,79,105,0.14)', hair: 'rgba(76,79,105,0.14)',
        accent: '#8839ef', onAccent: '#eff1f5', shadow: '0 1px 3px rgba(76,79,105,0.28)',
        card: 'rgba(239,241,245,0.96)' }
    : { pill: 'rgba(30,30,46,0.78)', fg: 'rgba(205,214,244,0.94)', fgDim: 'rgba(205,214,244,0.64)',
        press: 'rgba(205,214,244,0.18)', hair: 'rgba(205,214,244,0.16)',
        accent: '#cba6f7', onAccent: '#1e1e2e', shadow: '0 1px 3px rgba(0,0,0,0.45)',
        card: 'rgba(30,30,46,0.96)' };

  /* ── latch state ───────────────────────────────────────────────────── */
  var sticky = { ctrl: false, alt: false, tab: false };
  function latchAny() { return sticky.ctrl || sticky.alt || sticky.tab; }
  function latchClear() { sticky.ctrl = sticky.alt = sticky.tab = false; }

  /* The next frame is expected through compose() untouched (paste bursts,
   * self-firing tab) - latches survive it. */
  var skipNext = false;
  var paintBar = null; /* set once the bar is in the DOM */

  /* ── input-frame composition (ttyd wire: [0x30, raw pty bytes]) ─────── */
  function isTtydSock(ws) {
    try {
      var u = String(ws && ws.url || '');
      var i = u.indexOf('?');
      var p = i < 0 ? u : u.slice(0, i);
      return p.length >= 3 && p.slice(-3) === '/ws';
    } catch (e) { return false; }
  }

  /* Re-encode a CSI sequence (ESC [ params final) with the xterm.js modifier
   * parameter: shift=1 alt=2 ctrl=4, sent as "1;<code>" in letter finals and
   * "<n>;<code>" in tilde finals. Returns the new bytes or null on any doubt. */
  function csiMod(p) {
    if (p.length < 3 || p[0] !== 0x1b || p[1] !== 0x5b) return null;
    var last = p[p.length - 1];
    if (last < 0x40 || last > 0x7e) return null;
    var code = 1 + (sticky.alt ? 2 : 0) + (sticky.ctrl ? 4 : 0);
    var mid = [];
    for (var i = 2; i < p.length - 1; i++) {
      var c = p[i];
      if (!((c >= 0x30 && c <= 0x3a) || c === 0x3b)) return null;
      mid.push(c);
    }
    var params = '';
    for (var j = 0; j < mid.length; j++) params += String.fromCharCode(mid[j]);
    if (params !== '' && params !== '1' && !/^[0-9]+$/.test(params)) return null;
    if (last === 0x7e) {
      if (params === '' || params === '1' || /^[0-9]+$/.test(params)) {
        return escCsi((params === '' ? '1' : params) + ';' + code + String.fromCharCode(0x7e));
      }
      return null;
    }
    if (params !== '' && params !== '1') return null;
    var fin = String.fromCharCode(last);
    if ('ABCD'.indexOf(fin) < 0 && 'FH'.indexOf(fin) < 0) return null;
    return escCsi('1;' + code + fin);
  }
  function escCsi(s) {
    var out = [0x1b, 0x5b];
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 0xff);
    return out;
  }

  /* Apply latched modifiers to one input payload (bytes WITHOUT the 0x30). */
  function compose(p) {
    var out = [];
    var i;
    if (sticky.tab) out.push(0x09);
    var isPlain = p.length === 1 && p[0] >= 0x20 && p[0] <= 0x7e;
    var isCsi = p.length >= 3 && p[0] === 0x1b && p[1] === 0x5b;
    if (isCsi) {
      var enc = csiMod(p);
      if (enc) {
        for (i = 0; i < enc.length; i++) out.push(enc[i]);
        return new Uint8Array(out);
      }
    }
    if (sticky.alt) out.push(0x1b);
    if (sticky.ctrl && isPlain) {
      out.push(p[0] === 0x3f ? 0x7f : (p[0] & 0x1f));
      return new Uint8Array(out);
    }
    for (i = 0; i < p.length; i++) out.push(p[i]);
    return new Uint8Array(out);
  }

  function frameBytes(a) {
    var f = new Uint8Array(a.length + 1);
    f[0] = 0x30;
    f.set(a, 1);
    return f;
  }

  /* One choke point: patch WebSocket.prototype.send so every outgoing ttyd
   * input frame (keyboard, soft keyboard, IME composition, everything) can be
   * composed with latched modifiers. Other frames/sockets pass through. */
  if (typeof WebSocket !== 'undefined' && !WebSocket.prototype.__hassbarSend) {
    WebSocket.prototype.__hassbarSend = WebSocket.prototype.send;
    WebSocket.prototype.send = function (data) {
      var wsSend = WebSocket.prototype.__hassbarSend;
      var skip = skipNext;
      skipNext = false;
      try {
        if (!skip && data instanceof Uint8Array && data.length > 0 &&
            data[0] === 0x30 && isTtydSock(this)) {
          if (latchAny()) {
            wsSend.call(this, frameBytes(compose(data.subarray(1))));
            latchClear();
            paint();
            return;
          }
        }
      } catch (e) { /* never break typing */ }
      wsSend.call(this, data);
    };
  }

  /* ── xterm bridge ──────────────────────────────────────────────────── */
  function term() { return window.term || null; }
  function textareaEl() {
    return document.querySelector('.xterm-helper-textarea');
  }
  /* Dispatch a real keydown at xterm's hidden textarea; xterm.js evaluates
   * the event exactly like a physical key (keymap + keypad mode + modifiers). */
  function dispatchKey(key, code) {
    var el = textareaEl();
    if (!el) return false;
    try {
      if (document.activeElement !== el) el.focus();
    } catch (e) { /* ignore */ }
    el.dispatchEvent(new KeyboardEvent('keydown', {
      bubbles: true, cancelable: true, key: key, code: code
    }));
    return true;
  }

  function pasteText(text) {
    var t = term();
    if (!t) return false;
    try {
      if (typeof t.paste === 'function') { skipNext = true; t.paste(text); return true; }
      skipNext = true; t.input(text); return true;
    } catch (e) { return false; }
  }

  /* ── paste fallback (plain-http origins: no Clipboard API) ─────────── */
  function pasteModal() {
    if (document.getElementById('hassbar-paste')) return;
    var wrap = document.createElement('div');
    wrap.id = 'hassbar-paste';
    var ta = document.createElement('textarea');
    ta.placeholder = 'Long-press here, Paste, then Send';
    var send = document.createElement('button');
    send.type = 'button'; send.textContent = 'Send';
    var close = document.createElement('button');
    close.type = 'button'; close.textContent = '\u00d7';
    send.onpointerdown = function (e) {
      e.preventDefault();
      var v = ta.value;
      if (v) pasteText(v);
      if (wrap.parentNode) wrap.parentNode.removeChild(wrap);
    };
    close.onpointerdown = function (e) {
      e.preventDefault();
      if (wrap.parentNode) wrap.parentNode.removeChild(wrap);
    };
    wrap.appendChild(ta); wrap.appendChild(send); wrap.appendChild(close);
    document.body.appendChild(wrap);
    ta.focus();
  }

  function doPaste() {
    var cb = navigator.clipboard;
    if (cb && typeof cb.readText === 'function') {
      try {
        var req = cb.readText();
        if (req && typeof req.then === 'function') {
          req.then(function (text) {
            if (!text) pasteModal();
            else if (!pasteText(text)) pasteModal();
          }, function () { pasteModal(); });
        } else pasteModal();
      } catch (e) { pasteModal(); }
    } else pasteModal();
  }

  /* ── clipboard (always on) ─────────────────────────────────────────── */
  var MAX_CLIP = 1048576;

  /* Synchronous copy through a throwaway textarea; needs a user gesture. */
  function execCopy(text) {
    var ok = false;
    var ta = null;
    try {
      ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0;';
      document.body.appendChild(ta);
      var prev = document.activeElement;
      ta.select();
      ta.setSelectionRange(0, text.length);
      ok = !!document.execCommand('copy');
      document.body.removeChild(ta);
      ta = null;
      if (prev && typeof prev.focus === 'function') prev.focus();
    } catch (e) {
      ok = false;
      try { if (ta && ta.parentNode) ta.parentNode.removeChild(ta); } catch (e2) { /* ignore */ }
    }
    return ok;
  }

  /* Write text to the clipboard: async API first (secure context), then
   * execCommand, then call onFail so the caller can offer a manual path. */
  function writeClip(text, onFail) {
    function fallback() {
      if (execCopy(text)) return;
      if (onFail) onFail();
    }
    try {
      var cb = navigator.clipboard;
      if (cb && typeof cb.writeText === 'function') {
        var req = cb.writeText(text);
        if (req && typeof req.then === 'function') { req.then(function () {}, fallback); return; }
      }
    } catch (e) { /* fall through */ }
    fallback();
  }

  function removeEl(id) {
    var el = document.getElementById(id);
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  /* Browser refused a hands-off write: keep the text behind a tap, because a
   * tap is a user gesture and may copy where the OSC 52 arrival could not. */
  function clipToast(text) {
    removeEl('hassbar-toast');
    var c = COLORS;
    var wrap = document.createElement('div');
    wrap.id = 'hassbar-toast';
    wrap.style.cssText = 'position:fixed;right:10px;top:10px;z-index:9999;display:flex;' +
      'gap:8px;align-items:center;padding:8px 10px;border-radius:12px;' +
      'background:' + c.card + ';color:' + c.fg + ';border:1px solid ' + c.hair + ';' +
      'box-shadow:' + c.shadow + ';font:600 13px/1.2 system-ui,sans-serif;';
    var label = document.createElement('span');
    label.textContent = 'Terminal copied ' + text.length + ' chars';
    var btn = document.createElement('button');
    btn.type = 'button'; btn.textContent = 'Copy';
    var x = document.createElement('button');
    x.type = 'button'; x.textContent = '×';
    var bs = 'border:0;border-radius:9px;padding:6px 12px;background:' + c.press +
      ';color:' + c.fg + ';font:600 13px/1 system-ui,sans-serif;cursor:pointer;';
    btn.style.cssText = bs; x.style.cssText = bs;
    btn.onclick = function () {
      if (execCopy(text)) removeEl('hassbar-toast');
      else { removeEl('hassbar-toast'); copyBox(text); }
    };
    x.onclick = function () { removeEl('hassbar-toast'); };
    wrap.appendChild(label); wrap.appendChild(btn); wrap.appendChild(x);
    document.body.appendChild(wrap);
    setTimeout(function () { removeEl('hassbar-toast'); }, 20000);
  }

  /* Last resort and the Copy button's no-selection view: the text in a
   * selectable box the person can copy with the OS's own gesture. */
  function copyBox(text) {
    removeEl('hassbar-copy');
    var c = COLORS;
    var wrap = document.createElement('div');
    wrap.id = 'hassbar-copy';
    wrap.style.cssText = 'position:fixed;left:50%;top:10px;transform:translateX(-50%);' +
      'z-index:9999;display:flex;flex-direction:column;gap:8px;width:min(94vw,640px);' +
      'max-height:80vh;padding:10px;border-radius:14px;background:' + c.card + ';' +
      'border:1px solid ' + c.hair + ';box-shadow:' + c.shadow + ';';
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.readOnly = true;
    ta.style.cssText = 'height:50vh;min-height:6em;border-radius:9px;padding:7px;' +
      'border:1px solid ' + c.hair + ';background:transparent;color:' + c.fg + ';' +
      'font:12px/1.35 Monaco,Consolas,monospace;white-space:pre;resize:none;';
    var row = document.createElement('div');
    row.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;';
    var bs = 'border:0;border-radius:9px;padding:8px 14px;background:' + c.press +
      ';color:' + c.fg + ';font:600 13px/1 system-ui,sans-serif;cursor:pointer;';
    var all = document.createElement('button');
    all.type = 'button'; all.textContent = 'Copy all'; all.style.cssText = bs;
    var close = document.createElement('button');
    close.type = 'button'; close.textContent = 'Close'; close.style.cssText = bs;
    all.onclick = function () {
      ta.focus(); ta.select();
      try { ta.setSelectionRange(0, text.length); } catch (e) { /* ignore */ }
      var ok = false;
      try { ok = !!document.execCommand('copy'); } catch (e) { ok = false; }
      all.textContent = ok ? 'Copied' : 'Press Ctrl/Cmd+C';
    };
    close.onclick = function () { removeEl('hassbar-copy'); };
    row.appendChild(all); row.appendChild(close);
    wrap.appendChild(ta); wrap.appendChild(row);
    document.body.appendChild(wrap);
    ta.focus(); ta.select();
  }

  /* Visible terminal text (tmux redraws one screen; its scrollback lives in
   * tmux copy-mode, not in xterm's buffer), trailing blank rows trimmed. */
  function screenText() {
    var t = term();
    if (!t || !t.buffer || !t.buffer.active) return '';
    var buf = t.buffer.active;
    var lines = [];
    for (var i = 0; i < buf.length; i++) {
      var ln = buf.getLine(i);
      lines.push(ln ? ln.translateToString(true) : '');
    }
    while (lines.length && lines[lines.length - 1] === '') lines.pop();
    return lines.join('\n');
  }

  /* The bar's Copy: the xterm selection if there is one, else the screen in a
   * selectable box. */
  function doCopy() {
    var t = term();
    var sel = '';
    try { if (t && t.hasSelection()) sel = t.getSelection(); } catch (e) { sel = ''; }
    if (sel) {
      if (execCopy(sel)) return;
      writeClip(sel, function () { copyBox(sel); });
      return;
    }
    copyBox(screenText());
  }

  /* OSC 52 ("52;<targets>;<base64>"): decode and copy. Query ("?") is never
   * answered - a page must not be able to read the clipboard through the pty. */
  function b64Utf8(b64) {
    var bin = atob(b64.replace(/\s+/g, ''));
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    if (typeof TextDecoder === 'function') return new TextDecoder('utf-8').decode(bytes);
    return decodeURIComponent(escape(bin));
  }
  function onOsc52(data) {
    try {
      var i = String(data).indexOf(';');
      var payload = i < 0 ? '' : String(data).slice(i + 1);
      if (!payload || payload === '?' || payload.length > MAX_CLIP * 1.4) return true;
      var text = b64Utf8(payload);
      if (!text) return true;
      writeClip(text, function () { clipToast(text); });
    } catch (e) { /* malformed payload: ignore */ }
    return true;
  }

  var clipReady = false;
  function setupClipboard() {
    if (clipReady) return;
    var t = term();
    if (!t) return;
    clipReady = true;
    try {
      if (t.parser && typeof t.parser.registerOscHandler === 'function') {
        t.parser.registerOscHandler(52, onOsc52);
      }
    } catch (e) { /* older client: selection copy below still works */ }
    /* Native selection (Shift+drag while a TUI/tmux owns the mouse, or any
     * drag with terminal_mouse off): copy on release; mouseup is a gesture. */
    document.addEventListener('mouseup', function () {
      try {
        if (t.hasSelection()) {
          var sel = t.getSelection();
          if (sel && sel.length <= MAX_CLIP) execCopy(sel);
        }
      } catch (e) { /* ignore */ }
    }, true);
  }

  /* ── the bar ───────────────────────────────────────────────────────── */
  function injectCss() {
    var c = COLORS;
    /* --hassbar-shift tracks how much of the LAYOUT viewport the on-screen
     * keyboard (or any other browser chrome) covers; the floating keys ride
     * above it and the terminal shrinks so no row hides. */
    var css = [
      '#hassbar{position:fixed;left:0;right:0;bottom:var(--hassbar-shift, 0px);z-index:9998;',
      'display:flex;align-items:center;justify-content:center;gap:6px;',
      /* No safe-area reservation: the bar is transparent, so a device inset
       * (env(safe-area-inset-bottom)) showed up as a dark strip between the
       * keys and the keyboard instead of protecting anything. 6px padding
       * only; BAR_H matches this box exactly so the terminal ends at the
       * keys. */
      'padding:6px 10px 6px;',
      'background:transparent;border:0;box-shadow:none;pointer-events:none;',
      'font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;',
      '-webkit-tap-highlight-color:transparent;}',
      '#hassbar button{pointer-events:auto;flex:0 0 auto;min-width:40px;min-height:32px;',
      'margin:0;padding:0 10px;border:0;border-radius:999px;',
      'background:' + c.pill + ';color:' + c.fg + ';box-shadow:' + c.shadow + ';',
      '-webkit-backdrop-filter:blur(10px) saturate(140%);backdrop-filter:blur(10px) saturate(140%);',
      "font:600 12px/1 system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;",
      'letter-spacing:0.01em;',
      'transition:background 0.12s ease,color 0.12s ease,box-shadow 0.12s ease,transform 0.06s ease;',
      'touch-action:manipulation;user-select:none;-webkit-user-select:none;}',
      '#hassbar button:active{transform:scale(0.94);background:' + c.press + ';}',
      '#hassbar button.hb-sticky{color:' + c.fgDim + ';}',
      '#hassbar button.hb-sticky.on{background:' + c.accent + ';color:' + c.onAccent + ';',
      'box-shadow:0 0 0 1px ' + c.hair + ';}',
      '#terminal-container{height:calc(100% - ' + BAR_H + 'px - var(--hassbar-shift, 0px));}',
      '#hassbar-paste{position:fixed;left:50%;transform:translateX(-50%);',
      'bottom:calc(' + (BAR_H + 8) + 'px + var(--hassbar-shift, 0px));',
      'z-index:9999;display:flex;gap:8px;width:min(92vw,480px);padding:10px;',
      'background:' + c.card + ';border:1px solid ' + c.hair + ';border-radius:14px;',
      '-webkit-backdrop-filter:blur(16px) saturate(140%);backdrop-filter:blur(16px) saturate(140%);',
      'box-shadow:' + c.shadow + ';}',
      '#hassbar-paste textarea{flex:1 1 auto;min-height:2.4em;border-radius:9px;',
      'border:1px solid ' + c.hair + ';background:transparent;color:' + c.fg + ';padding:7px;',
      'font:inherit;}',
      '#hassbar-paste textarea:focus{outline:none;box-shadow:inset 0 0 0 1px ' + c.hair + ';}',
      '#hassbar-paste button{flex:0 0 auto;border:0;border-radius:9px;background:' + c.press + ';',
      'color:' + c.fg + ';padding:0 14px;font:600 13px/1 system-ui,sans-serif;}',
      '#hassbar-paste button:active{transform:scale(0.96);}'
    ].join('\n');
    var st = document.createElement('style');
    st.id = 'hassbar-css';
    st.appendChild(document.createTextNode(css));
    document.head.appendChild(st);
  }

  var BUTTONS = [
    { id: 'ctrl',  label: 'Ctrl',  sticky: true,  key: null, code: null },
    { id: 'alt',   label: 'Alt',   sticky: true,  key: null, code: null },
    { id: 'tab',   label: 'Tab',   sticky: true,  key: 'Tab', code: 'Tab' },
    { id: 'esc',   label: 'Esc',   sticky: false, key: 'Escape', code: 'Escape' },
    { id: 'del',   label: 'Del',   sticky: false, key: 'Delete', code: 'Delete' },
    { id: 'copy',  label: 'Copy',  sticky: false, key: null, code: null, action: 'copy' },
    { id: 'paste', label: 'Paste', sticky: false, key: null, code: null, action: 'paste' }
  ];

  function paint() {
    if (!paintBar) return;
    paintBar();
  }

  /* The bar is a touch affordance: on a desktop (fine primary pointer) the
   * keyboard already has every key, so nothing is rendered at all - no bar,
   * no reserved rows, the terminal keeps its full height. Unknown/old
   * browsers keep the bar (fail open, it is harmless with a mouse). */
  function isTouchView() {
    try {
      if (window.matchMedia) {
        return window.matchMedia('(pointer: coarse)').matches;
      }
      return (window.navigator && (window.navigator.maxTouchPoints || 0)) > 0;
    } catch (e) { return true; }
  }

  function mountBar() {
    if (document.getElementById('hassbar')) return;
    if (!isTouchView()) return;
    injectCss();
    document.documentElement.style.setProperty('--hassbar-h', BAR_H + 'px');
    var bar = document.createElement('div');
    bar.id = 'hassbar';
    var els = {};
    BUTTONS.forEach(function (b) {
      var el = document.createElement('button');
      el.type = 'button';
      el.textContent = b.label;
      el.setAttribute('aria-label', b.sticky ? b.label + ' (latches until used)' : b.label);
      el.className = b.sticky ? 'hb-sticky' : '';
      if (b.sticky) el.setAttribute('aria-pressed', 'false');
      el.onpointerdown = function (e) {
        e.preventDefault();
        if (b.action === 'paste') { doPaste(); return; }
        if (b.action === 'copy') { doCopy(); return; }
        if (b.id === 'ctrl') {
          sticky.ctrl = !sticky.ctrl; paint(); return;
        }
        if (b.id === 'alt') {
          sticky.alt = !sticky.alt; paint(); return;
        }
        if (b.id === 'tab') {
          if (sticky.tab) {
            /* Tab is its own key: a tap while it is latched fires it once. */
            skipNext = true;
            dispatchKey('Tab', 'Tab');
            latchClear();
            paint();
          } else {
            sticky.tab = true; paint();
          }
          return;
        }
        /* Esc / Del: one-shot synthetic keydown; any latches compose at the
         * socket layer with the sequence xterm produces. */
        dispatchKey(b.key, b.code);
        paint();
      };
      /* Block focus stealing (clicks must not close the soft keyboard). */
      el.onmousedown = function (e) { e.preventDefault(); };
      els[b.id] = el;
      bar.appendChild(el);
    });
    paintBar = function () {
      'ctrl,alt,tab'.split(',').forEach(function (id) {
        var el = els[id];
        if (!el) return;
        var on = !!sticky[id];
        el.classList[on ? 'add' : 'remove']('on');
        el.setAttribute('aria-pressed', on ? 'true' : 'false');
      });
    };
    document.body.appendChild(bar);
    paintBar();
    watchViewport();
    var t = term();
    if (t && typeof t.fit === 'function') { try { t.fit(); } catch (e) { /* ignore */ } }
  }

  /* Keep the bar where the user can actually see it. Two keyboard models:
   *  - top-level page: the keyboard shrinks the VISUAL viewport while the
   *    layout viewport (what position:fixed uses) stays put;
   *  - HA ingress panel: our page runs in a same-origin IFRAME, and the
   *    keyboard may shrink the PARENT's visual viewport instead of ours.
   * Own-window and ancestor-frame coverage describe the SAME keyboard, so
   * they are combined with max() - summing them double-counts (1.0.38 lifted
   * the bar far above the keys, leaving a dead band below it). Whatever is
   * already covered at rest (browser/app chrome, bottom bars, an iframe that
   * does not end at the page bottom) is subtracted as a baseline, so only the
   * keyboard's OWN height lifts the bar. */
  var lastShift = -1;
  var fitTimer = null;
  var restOwn = null;
  var restAnc = null;
  function coveredBy(win) {
    try {
      var vp = win.visualViewport;
      if (!vp || typeof vp.height !== 'number') return 0;
      var s = win.innerHeight - vp.height - (vp.offsetTop || 0);
      if (!isFinite(s) || s < 0) return 0;
      return Math.round(s);
    } catch (e) { return 0; }
  }
  /* How far the bottom edge of each ancestor frame sits below the visible
   * area of its parent - that is the part of OUR page hidden from view,
   * because our document's bottom edge is that frame's bottom edge. */
  function ancestorShift() {
    var most = 0;
    var w = window;
    try {
      for (var i = 0; i < 5; i++) {
        var fe = w.frameElement;
        if (!fe || typeof fe.getBoundingClientRect !== 'function') break;
        var p = w.parent;
        if (!p || p === w) break;
        var pv = p.visualViewport;
        if (pv && typeof pv.height === 'number') {
          var r = fe.getBoundingClientRect();
          var hidden = r.bottom - ((pv.offsetTop || 0) + pv.height);
          if (isFinite(hidden) && hidden > most) most = Math.round(hidden);
        }
        w = p;
      }
    } catch (e) { /* cross-origin ancestor: nothing measurable */ }
    return most;
  }
  function syncViewport() {
    var own = coveredBy(window);
    var anc = ancestorShift();
    /* Lowest coverage ever seen per source = that source's resting
     * (keyboard-closed) value: browser/app chrome, bottom bars, an iframe
     * that does not end at the page bottom. Only the increase over the
     * baseline is the keyboard. */
    if (restOwn === null || own < restOwn) restOwn = own;
    if (restAnc === null || anc < restAnc) restAnc = anc;
    var base = Math.max(own - restOwn, anc - restAnc);
    if (!isFinite(base) || base < 16) base = 0; /* ignore jitter */
    var shift = base + OFFSET;
    if (shift < 0) shift = 0;
    shift = Math.round(shift);
    if (DEBUG) updateDiag(own, anc, base, shift);
    if (shift === lastShift) return;
    lastShift = shift;
    document.documentElement.style.setProperty('--hassbar-shift', shift + 'px');
    if (fitTimer) clearTimeout(fitTimer);
    fitTimer = setTimeout(function () {
      var t = term();
      if (t && typeof t.fit === 'function') { try { t.fit(); } catch (e) { /* ignore */ } }
    }, 120);
  }
  function updateDiag(own, anc, base, shift) {
    var vp = window.visualViewport || {};
    var line = 'H' + window.innerHeight +
      ' vv' + (vp.height === undefined ? '-' : Math.round(vp.height)) +
      ' top' + Math.round(vp.offsetTop || 0) +
      ' own' + own + ' anc' + anc +
      ' rest' + restOwn + '/' + restAnc +
      ' base' + base + ' off' + OFFSET + ' shift' + shift;
    window.__hassbar.diag = line;
    if (!diagEl) {
      diagEl = document.createElement('div');
      diagEl.id = 'hassbar-diag';
      diagEl.style.cssText = 'position:fixed;left:0;right:0;z-index:9999;' +
        'padding:3px 6px;font:10px/1.35 monospace;color:#f2cdcd;' +
        'background:rgba(0,0,0,0.72);white-space:nowrap;overflow:hidden;' +
        'text-overflow:ellipsis;pointer-events:none;';
      document.body.appendChild(diagEl);
    }
    diagEl.style.bottom = 'calc(' + BAR_H + 'px + var(--hassbar-shift, 0px))';
    diagEl.textContent = 'hassbar ' + line;
  }
  /* Watch the viewport events of our window AND every same-origin ancestor:
   * inside the ingress iframe it is the parent's visual viewport that moves. */
  function watchWindow(win, depth) {
    try {
      var vp = win.visualViewport;
      if (vp && typeof vp.addEventListener === 'function') {
        vp.addEventListener('resize', syncViewport);
        vp.addEventListener('scroll', syncViewport);
      }
      if (typeof win.addEventListener === 'function') {
        win.addEventListener('resize', syncViewport);
      }
    } catch (e) { /* ignore */ }
    if (depth > 0) {
      try {
        if (win.parent && win.parent !== win) watchWindow(win.parent, depth - 1);
      } catch (e) { /* ignore */ }
    }
  }
  function watchViewport() {
    watchWindow(window, 4);
    window.addEventListener('orientationchange', syncViewport);
    /* Keyboard animations can land without a resize event on some embedded
     * browsers; a cheap poll plus focus re-checks cover those. */
    window.addEventListener('focusin', nudgeViewport);
    window.addEventListener('focusout', nudgeViewport);
    setInterval(syncViewport, 500);
    syncViewport();
  }
  function nudgeViewport() {
    setTimeout(syncViewport, 150);
    setTimeout(syncViewport, 450);
    setTimeout(syncViewport, 900);
  }

  /* Wait for the ttyd client to expose window.term (async token fetch), then
   * set up the clipboard helpers and (touch devices, unless touch_bar is off)
   * mount the bar. Give up quietly after 30s - a changed client must never
   * break the terminal. */
  var wantBar = cfg.bar !== 0 && isTouchView();
  var waited = 0;
  (function wait() {
    if (term() && term().paste !== undefined && textareaEl()) {
      try { setupClipboard(); } catch (e) { /* never block the terminal */ }
      if (wantBar) mountBar();
      return;
    }
    waited += 100;
    if (waited > 30000) return;
    setTimeout(wait, 100);
  })();
})();
