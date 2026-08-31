/* Barkpark Studio — tmux console terminal hook.
 *
 * Registered as the LiveView `TmuxTerminal` hook (see root.html.heex). Drives
 * an xterm.js terminal wired over the LiveView channel to a real PTY on the
 * host running `tmux`. Heavy xterm.js (~290KB) is lazy-loaded from
 * /assets/xterm.bundle.js ONLY when this hook mounts, so non-tmux Studio
 * pages never pay for it (Golden Rule #4 spirit).
 *
 * Transport: PTY bytes ride base64 in both directions so raw terminal output
 * (arbitrary bytes) survives the JSON channel intact.
 *   • input  — term.onData string → UTF-8 bytes → base64 → "term-input"
 *   • output — "term-out" base64 → Uint8Array → term.write (xterm decodes UTF-8)
 *
 * xterm.css is embedded below and injected once, honoring the repo's
 * no-CSS-files convention (all styling is inline / JS-injected).
 *
 * BUILD NOTE — xterm.bundle.js is @xterm/xterm + @xterm/addon-fit concatenated.
 * xterm's file ends with a `//# sourceMappingURL=` LINE COMMENT and no trailing
 * newline, so the two MUST be joined with a separator or the entire fit addon
 * is swallowed by that comment (→ FitAddon undefined → silent black terminal).
 * Rebuild with:  { cat xterm.core.js; printf '\n;\n'; cat addon-fit.js; } > xterm.bundle.js
 */
(function () {
  "use strict";

  // xterm.js default stylesheet (MIT, © the xterm.js authors), inlined so no
  // separate .css file ships. Only the functional rules — the container's own
  // sizing/background is set by the LiveView element's inline style.
  var XTERM_CSS =
    ".xterm{cursor:text;position:relative;user-select:none;-ms-user-select:none;-webkit-user-select:none}" +
    ".xterm.focus,.xterm:focus{outline:none}" +
    ".xterm .xterm-helpers{position:absolute;top:0;z-index:5}" +
    ".xterm .xterm-helper-textarea{padding:0;border:0;margin:0;position:absolute;opacity:0;left:-9999em;top:0;width:0;height:0;z-index:-5;white-space:nowrap;overflow:hidden;resize:none}" +
    ".xterm .composition-view{background:#000;color:#FFF;display:none;position:absolute;white-space:nowrap;z-index:1}" +
    ".xterm .composition-view.active{display:block}" +
    ".xterm .xterm-viewport{background-color:#000;overflow-y:scroll;cursor:default;position:absolute;right:0;left:0;top:0;bottom:0}" +
    ".xterm .xterm-screen{position:relative}" +
    ".xterm .xterm-screen canvas{position:absolute;left:0;top:0}" +
    ".xterm .xterm-scroll-area{visibility:hidden}" +
    ".xterm-char-measure-element{display:inline-block;visibility:hidden;position:absolute;top:0;left:-9999em;line-height:normal}" +
    ".xterm.enable-mouse-events{cursor:default}" +
    ".xterm.xterm-cursor-pointer,.xterm .xterm-cursor-pointer{cursor:pointer}" +
    ".xterm.column-select.focus{cursor:crosshair}" +
    ".xterm .xterm-accessibility:not(.debug),.xterm .xterm-message{position:absolute;left:0;top:0;bottom:0;right:0;z-index:10;color:transparent;pointer-events:none}" +
    ".xterm .xterm-accessibility-tree:not(.debug) *::selection{color:transparent}" +
    ".xterm .xterm-accessibility-tree{user-select:text;white-space:pre}" +
    ".xterm .live-region{position:absolute;left:-9999px;width:1px;height:1px;overflow:hidden}" +
    ".xterm-dim{opacity:1!important}" +
    ".xterm-underline-1{text-decoration:underline}.xterm-underline-2{text-decoration:double underline}.xterm-underline-3{text-decoration:wavy underline}.xterm-underline-4{text-decoration:dotted underline}.xterm-underline-5{text-decoration:dashed underline}" +
    ".xterm-overline{text-decoration:overline}" +
    ".xterm-strikethrough{text-decoration:line-through}" +
    ".xterm-screen .xterm-decoration-container .xterm-decoration{z-index:6;position:absolute}" +
    ".xterm-screen .xterm-decoration-container .xterm-decoration.xterm-decoration-top-layer{z-index:7}" +
    ".xterm-decoration-overview-ruler{z-index:8;position:absolute;top:0;right:0;pointer-events:none}" +
    ".xterm-decoration-top{z-index:2;position:relative}";

  var _cssInjected = false;
  var _scriptLoading = null;

  function ensureCss() {
    if (_cssInjected || document.getElementById("bp-xterm-css")) return;
    var s = document.createElement("style");
    s.id = "bp-xterm-css";
    s.textContent = XTERM_CSS;
    document.head.appendChild(s);
    _cssInjected = true;
  }

  function ensureXterm(src) {
    if (window.Terminal && window.FitAddon) return Promise.resolve();
    if (_scriptLoading) return _scriptLoading;
    _scriptLoading = new Promise(function (resolve, reject) {
      var sc = document.createElement("script");
      sc.src = src;
      sc.async = true;
      sc.onload = function () { resolve(); };
      sc.onerror = function () { reject(new Error("could not load " + src)); };
      document.head.appendChild(sc);
    });
    return _scriptLoading;
  }

  function b64ToBytes(b64) {
    var bin = atob(b64);
    var len = bin.length;
    var u8 = new Uint8Array(len);
    for (var i = 0; i < len; i++) u8[i] = bin.charCodeAt(i);
    return u8;
  }

  // JS string (already-decoded chars) → base64 of its UTF-8 bytes.
  function strToB64Utf8(str) {
    return btoa(unescape(encodeURIComponent(str)));
  }

  // Write to the browser clipboard. navigator.clipboard needs a secure
  // context (https / localhost); fall back to the execCommand textarea dance
  // for plain-http dev, restoring terminal focus after.
  function copyToClipboard(text, refocus) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).catch(function () {
        execCommandCopy(text, refocus);
      });
    } else {
      execCommandCopy(text, refocus);
    }
  }

  function execCommandCopy(text, refocus) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(ta);
    if (refocus) refocus();
  }

  // A classic dark terminal palette — terminals read best on their own dark
  // surface regardless of the Studio light/dark theme.
  function terminalTheme() {
    return {
      background: "#0a0a0a",
      foreground: "#e4e4e7",
      cursor: "#e4e4e7",
      cursorAccent: "#0a0a0a",
      selectionBackground: "#3f3f46"
    };
  }

  window.BarkparkTmuxTerminal = {
    mounted: function () {
      var hook = this;
      var el = this.el;
      ensureCss();
      ensureXterm(el.dataset.src || "/assets/xterm.bundle.js")
        .then(function () {
          // Surface init failures as text — a thrown error here would
          // otherwise leave a silent black box (which is exactly how a broken
          // bundle presented before).
          try {
            hook._init();
          } catch (e) {
            hook._fail(e && e.message ? e.message : String(e));
          }
        })
        .catch(function (e) {
          hook._fail("could not load " + (e && e.message ? e.message : String(e)));
        });
    },

    _fail: function (msg) {
      this.el.textContent = "tmux terminal failed to start: " + msg;
      this.el.style.color = "#f87171";
      this.el.style.font = "13px " + "ui-monospace, monospace";
      this.el.style.padding = "12px";
    },

    _init: function () {
      var hook = this;
      var el = this.el;

      if (typeof window.Terminal !== "function") {
        throw new Error("xterm.js did not load (window.Terminal missing)");
      }
      var FitAddonCtor = (window.FitAddon && window.FitAddon.FitAddon) || window.FitAddon;
      if (typeof FitAddonCtor !== "function") {
        throw new Error("xterm fit addon did not load (window.FitAddon missing)");
      }

      var mono = (getComputedStyle(document.documentElement)
        .getPropertyValue("--font-mono") || "").trim();

      var term = new window.Terminal({
        fontFamily: mono || "SF Mono, Menlo, Consolas, monospace",
        fontSize: 13,
        cursorBlink: true,
        scrollback: 10000,
        allowProposedApi: true,
        theme: terminalTheme()
      });

      var fit = new FitAddonCtor();
      term.loadAddon(fit);
      term.open(el);

      this._term = term;
      this._fit = fit;

      // ⌘C (mac) / Ctrl+Shift+C — copy the xterm selection to the browser
      // clipboard. xterm paints its own selection (no native DOM selection),
      // so the browser's plain copy shortcut has nothing to grab; without
      // this the only working path was right-click → Copy via the hidden
      // helper textarea. Returning false keeps xterm from also forwarding
      // the chord to the PTY.
      term.attachCustomKeyEventHandler(function (ev) {
        if (ev.type !== "keydown") return true;
        var isCopy =
          (ev.metaKey && !ev.ctrlKey && !ev.altKey && ev.key === "c") ||
          (ev.ctrlKey && ev.shiftKey && (ev.key === "C" || ev.key === "c"));
        if (isCopy && term.hasSelection()) {
          copyToClipboard(term.getSelection(), function () { term.focus(); });
          ev.preventDefault();
          return false;
        }
        return true;
      });

      // input → server
      term.onData(function (data) {
        hook.pushEvent("term-input", { d: strToB64Utf8(data) });
      });
      term.onBinary(function (data) {
        // `data` is a binary string (char codes 0–255)
        hook.pushEvent("term-input", { d: btoa(data) });
      });

      // output ← server
      this.handleEvent("term-out", function (payload) {
        if (payload && typeof payload.d === "string") term.write(b64ToBytes(payload.d));
      });

      var sendResize = function () {
        try { fit.fit(); } catch (e) { /* container not laid out yet */ }
        if (term.cols && term.rows) {
          hook.pushEvent("term-resize", { cols: term.cols, rows: term.rows });
        }
      };

      this._onResize = function () { sendResize(); };
      window.addEventListener("resize", this._onResize);
      if (window.ResizeObserver) {
        this._ro = new ResizeObserver(function () { sendResize(); });
        this._ro.observe(el);
      }

      // Fit to the real container, then ask the server to spawn tmux at that
      // exact geometry (spawn is lazy — driven by this first term-init).
      try { fit.fit(); } catch (e) {}
      this.pushEvent("term-init", { cols: term.cols || 80, rows: term.rows || 24 });
      term.focus();
    },

    destroyed: function () {
      if (this._ro) { try { this._ro.disconnect(); } catch (e) {} }
      if (this._onResize) window.removeEventListener("resize", this._onResize);
      if (this._term) { try { this._term.dispose(); } catch (e) {} }
    }
  };
})();
