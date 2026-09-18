// bp-chat-palette.js — the Studio Claude chat's keyboard navigation, client half.
//
// Two hooks, no build step (prebuilt like bp-chat-composer.js /
// bp-chat-turn-clock.js), registered in root.html.heex and loaded non-defer at
// the BOTTOM of <body> (Golden Rule 4 — never a blocking <script> in <head>).
//
//   1. `window.BarkparkChatKeys` (Hooks.ChatKeys) — the key FILTER. One
//      document-level keydown listener translates a chord into ONE server
//      event and nothing else:
//
//        Cmd/Ctrl+1 … Cmd/Ctrl+9 → pushEvent("chat-jump", {n})
//        Cmd/Ctrl+K              → pushEvent("chat-palette-open")
//
//      THE FOCUS-IN-INPUT GUARD (the criterion's named mutation): a key typed
//      while focus sits in an <input>, a <textarea>, or a contenteditable
//      belongs to THAT surface — the composer, the slash combobox, the inline
//      session-rename field all keep their own keys. `_classify` returns null
//      before it looks at any modifier, so no chord can ever be stolen from a
//      field the user is typing in. Delete that guard and
//      `__palette.test.mjs`'s "the focus-in-input guard" test reds.
//
//      The server does the navigating: this hook NEVER touches location or
//      pushes its own patch, so the keyboard and the sidebar click share one
//      navigation path (`session_link_path/2` in chat_live.ex).
//
//   2. `window.BarkparkChatPalette` (Hooks.ChatPalette) — the palette's client
//      half. The LIST is server-rendered (one <li> per visible sidebar
//      session, already tenant-clamped by refresh_sessions/1); the FILTERING is
//      client-side subsequence-fuzzy over the stamped titles, so typing costs
//      zero round trips and the list can never disagree with the sidebar it was
//      rendered from. Arrow keys move the highlight, Enter activates,
//      Escape closes.
//
//      ESCAPE OWNERSHIP. The chat already has two Escape owners: the global
//      interrupt (a document-level BUBBLE listener in bp-chat-composer.js,
//      charter D42) and the inline session-rename input. The palette claims
//      Escape the way the slash combobox already does — `preventDefault()` +
//      `stopPropagation()` — so the event never reaches `document` and the
//      interrupt never fires. A first Escape closes the palette; a second
//      (palette gone) reaches the interrupt exactly as before. The keydown
//      listener sits on the palette CONTAINER, not on its input, so it also
//      claims Escape when focus has moved to some other element inside the
//      palette — a listener bound to the input alone would leak those.
(function () {
  // ── the key filter ────────────────────────────────────────────────────────

  window.BarkparkChatKeys = {
    // A key typed into an editable surface belongs to that surface. Exposed
    // (with _classify) for the node harness — the shipped filter is the tested
    // filter.
    _inEditable(target) {
      if (!target) return false;
      if (target.isContentEditable === true) return true;
      var tag = (target.tagName || "").toUpperCase();
      return tag === "INPUT" || tag === "TEXTAREA";
    },

    // The chord → intent map. null = "not ours, leave the event alone".
    _classify(e) {
      if (!e) return null;
      // THE FOCUS-IN-INPUT GUARD — first, before any modifier is read.
      if (this._inEditable(e.target)) return null;
      // Cmd (mac) or Ctrl (everywhere else). Alt/Shift variants belong to the
      // browser and the OS, never to us.
      if (!(e.metaKey || e.ctrlKey)) return null;
      if (e.altKey || e.shiftKey) return null;

      var k = e.key;
      if (typeof k !== "string") return null;
      if (k === "k" || k === "K") return { kind: "palette" };
      if (k.length === 1 && k >= "1" && k <= "9") {
        return { kind: "jump", n: parseInt(k, 10) };
      }
      return null;
    },

    mounted() {
      this._onKeyDown = function (e) {
        var hit = this._classify(e);
        if (!hit) return;
        if (typeof e.preventDefault === "function") e.preventDefault();
        if (hit.kind === "jump") this.pushEvent("chat-jump", { n: hit.n });
        else this.pushEvent("chat-palette-open", {});
      }.bind(this);

      document.addEventListener("keydown", this._onKeyDown);
    },

    destroyed() {
      if (this._onKeyDown) {
        document.removeEventListener("keydown", this._onKeyDown);
        this._onKeyDown = null;
      }
    }
  };

  // ── the palette ───────────────────────────────────────────────────────────

  window.BarkparkChatPalette = {
    // Subsequence fuzzy match, case-insensitive, whitespace in the query
    // ignored — "sw" finds "Studio wiring", "chatp" finds "chat palette".
    // An empty query matches everything (the palette opens showing the whole
    // sidebar, in sidebar order).
    _match(query, title) {
      var q = String(query == null ? "" : query)
        .toLowerCase()
        .replace(/\s+/g, "");
      if (q === "") return true;
      var t = String(title == null ? "" : title).toLowerCase();
      var i = 0;
      for (var j = 0; j < t.length && i < q.length; j++) {
        if (t[j] === q[i]) i++;
      }
      return i === q.length;
    },

    mounted() {
      this._input = this.el.querySelector("#chat-palette-input");
      this._active = 0;

      this._onKeyDown = function (e) {
        this._onPaletteKey(e);
      }.bind(this);

      // On the CONTAINER (bubble): every key pressed anywhere inside the open
      // palette passes through here before it can reach `document`.
      this.el.addEventListener("keydown", this._onKeyDown);

      if (this._input) {
        this._onInput = function () {
          this._filter();
        }.bind(this);

        this._input.addEventListener("input", this._onInput);
        if (typeof this._input.focus === "function") this._input.focus();
      }

      this._filter();
    },

    updated() {
      this._filter();
    },

    destroyed() {
      this.el.removeEventListener("keydown", this._onKeyDown);
      if (this._input) this._input.removeEventListener("input", this._onInput);
    },

    _rows() {
      var list = this.el.querySelectorAll("[data-palette-row]");
      return Array.prototype.slice.call(list);
    },

    _visible() {
      return this._rows().filter(function (r) {
        return r.hidden !== true;
      });
    },

    _filter() {
      var q = this._input ? this._input.value : "";
      var self = this;
      this._rows().forEach(function (row) {
        row.hidden = !self._match(q, row.getAttribute("data-palette-title"));
      });
      this._active = 0;
      this._paint();
    },

    _paint() {
      var vis = this._visible();
      var self = this;
      if (this._active >= vis.length) this._active = vis.length ? vis.length - 1 : 0;

      this._rows().forEach(function (row) {
        row.setAttribute("aria-selected", "false");
        row.removeAttribute("data-palette-active");
      });

      var row = vis[this._active];
      if (row) {
        row.setAttribute("aria-selected", "true");
        row.setAttribute("data-palette-active", "");
        if (self._input) self._input.setAttribute("aria-activedescendant", row.id || "");
      } else if (self._input) {
        self._input.setAttribute("aria-activedescendant", "");
      }
    },

    _onPaletteKey(e) {
      var vis = this._visible();

      switch (e.key) {
        case "ArrowDown":
          if (typeof e.preventDefault === "function") e.preventDefault();
          if (vis.length) this._active = (this._active + 1) % vis.length;
          this._paint();
          break;

        case "ArrowUp":
          if (typeof e.preventDefault === "function") e.preventDefault();
          if (vis.length) this._active = (this._active - 1 + vis.length) % vis.length;
          this._paint();
          break;

        case "Enter": {
          if (typeof e.preventDefault === "function") e.preventDefault();
          var row = vis[this._active];
          if (row) {
            this.pushEvent("chat-palette-activate", {
              id: row.getAttribute("data-palette-id")
            });
          }
          break;
        }

        case "Escape":
          // Claim Escape here, on the palette's own input: stopPropagation
          // keeps it off `document`, where the global interrupt listener
          // (bp-chat-composer.js, charter D42) lives. Closing the palette must
          // never stop a running turn.
          if (typeof e.preventDefault === "function") e.preventDefault();
          if (typeof e.stopPropagation === "function") e.stopPropagation();
          this.pushEvent("chat-palette-close", {});
          break;

        default:
          break;
      }
    }
  };
})();
