// bp-chat-turn-clock.js — the Studio Claude chat's turn clock, client half.
//
// Re-render hygiene (T3 #10): a running turn used to cost the server a
// `Process.send_after(self(), :turn_tick, 1_000)` loop — one LiveView
// diff + patch PER SECOND PER VIEWER — for two labels the browser can move on
// its own. Both moved here:
//
//   1. `window.BarkparkChatElapsed` (Hooks.ChatElapsed) — the "12s" / "1m 05s"
//      elapsed counter. The server stamps `data-started-at` ONCE per turn
//      (epoch milliseconds, taken at the user-message boundary); this hook
//      mutates textContent on its own 1 s interval and clears it on destroy.
//      It ALWAYS re-seeds from the server attribute — never from a counter it
//      kept — so a remount (the busy row hides behind every streaming frame),
//      a patch, and a LiveView reconnect all land on the server's boundary.
//
//   2. `window.BarkparkChatSpinWord` (Hooks.ChatSpinWord) — the park-voice
//      busy word ("Joymaxxing…"). The server stamps the vocabulary as
//      `data-words` and the dwell as `data-rotate-ms`, both STATIC markup, and
//      this hook picks the next word (never the current one, so the change is
//      always visible). Same liveness floor as the old server rotation, at
//      zero LiveView diffs.
//
// Both spans carry `phx-update="ignore"`: the transcript around them is
// patched constantly (tool results, rail frames), and without it morphdom
// would revert the hook's text to the value the server rendered at mount.
// Attributes are still patched on an ignored element, so `updated()` re-seeds.
//
// Clock source: `Date.now()` against the server's epoch stamp, exactly like
// the ExpiryCountdown hook in root.html.heex. A badly-skewed browser clock
// shows a skewed elapsed; the value is clamped at 0 so it can never run
// backwards.
(function () {
  function pad(n) {
    return n < 10 ? "0" + n : "" + n;
  }

  // Under a second reads as nothing at all — the old server label was hidden
  // until `turn_elapsed_s > 0`, and a turn that flashes past should not leave
  // a "0s" behind.
  function fmt(ms) {
    if (typeof ms !== "number" || !isFinite(ms) || ms < 1000) return "";
    var s = Math.floor(ms / 1000);
    var h = Math.floor(s / 3600);
    s -= h * 3600;
    var m = Math.floor(s / 60);
    s -= m * 60;
    if (h > 0) return h + "h " + pad(m) + "m";
    if (m > 0) return m + "m " + pad(s) + "s";
    return s + "s";
  }

  window.BarkparkChatElapsed = {
    // Exposed for the node harness (api/assets/chat-turn-clock) — the shipped
    // arithmetic is the tested arithmetic.
    _fmt: fmt,

    mounted() {
      this._seed();
    },

    // A patch may hand us a NEW turn's boundary on the same element.
    updated() {
      this._seed();
    },

    // The socket came back: whatever the server now says is the truth.
    reconnected() {
      this._seed();
    },

    destroyed() {
      this._stop();
    },

    _seed() {
      this._stop();
      var raw = this.el.getAttribute("data-started-at");
      var started = raw ? parseInt(raw, 10) : NaN;
      this._started = isFinite(started) ? started : null;
      this._tick();
      if (this._started !== null) {
        this._timer = setInterval(
          function () {
            this._tick();
          }.bind(this),
          1000
        );
      }
    },

    _tick() {
      if (this._started === null) {
        this.el.textContent = "";
        return;
      }
      var ms = Date.now() - this._started;
      this.el.textContent = fmt(ms < 0 ? 0 : ms);
    },

    _stop() {
      if (this._timer) {
        clearInterval(this._timer);
        this._timer = null;
      }
    }
  };

  window.BarkparkChatSpinWord = {
    mounted() {
      this._start();
    },

    updated() {
      this._start();
    },

    reconnected() {
      this._start();
    },

    destroyed() {
      this._stop();
    },

    _start() {
      this._stop();
      var words = this._words();
      var every = parseInt(this.el.getAttribute("data-rotate-ms"), 10);
      // One word (or none) cannot rotate to a DIFFERENT word, so we never arm
      // a timer that would only rewrite the same text.
      if (words.length < 2 || !isFinite(every) || every <= 0) return;
      this._timer = setInterval(
        function () {
          this._rotate(words);
        }.bind(this),
        every
      );
    },

    // The server-stamped vocabulary. A malformed attribute rotates nothing
    // rather than throwing inside a timer.
    _words() {
      try {
        var raw = this.el.getAttribute("data-words");
        var parsed = raw ? JSON.parse(raw) : [];
        return Array.isArray(parsed) ? parsed.filter(function (w) {
          return typeof w === "string" && w !== "";
        }) : [];
      } catch (_e) {
        return [];
      }
    },

    _rotate(words) {
      var current = (this.el.textContent || "").replace(/…\s*$/, "").trim();
      var pool = words.filter(function (w) {
        return w !== current;
      });
      if (!pool.length) return;
      this.el.textContent = pool[Math.floor(Math.random() * pool.length)] + "…";
    },

    _stop() {
      if (this._timer) {
        clearInterval(this._timer);
        this._timer = null;
      }
    }
  };
})();
