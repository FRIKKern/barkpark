// bp-chat-composer.js — the Studio Claude chat composer's client half.
//
// Defines `window.BarkparkChatComposer`, a LiveView hook mounted on the composer
// <form>. It does two jobs:
//
//   1. Image attachments (charter D25): captures paste + drop events, filters to
//      accepted image files, and feeds them into `allow_upload(:attachments)` via
//      the LiveView JS `this.upload(name, files)` API — the SAME upload the send
//      handler consumes. It NEVER touches /media/files (the D6 leak). Text paste
//      is left alone (only image files trigger preventDefault).
//
//   2. Slash-command combobox (charter D36b): a leading "/" opens an ARIA
//      listbox of commands (the server stamps the vocabulary on the form as
//      `data-commands`; the client filters + renders it — the bp-sheet-grid.js
//      fn-autocomplete pattern). ArrowUp/Down move the active option,
//      Enter/Tab select, Escape closes. Selecting writes the input value AND
//      dispatches a native `input` event so the server-bound composer_draft
//      (value={@composer_draft} + phx-change) stays in sync (charter D24) — the
//      builtins /plan · /default · /model then route server-side on submit;
//      advertised commands submit as plain user text.
(function () {
  const UPLOAD = "attachments";
  const ACCEPT = ["image/png", "image/jpeg", "image/gif", "image/webp"];

  function imageFiles(list) {
    const out = [];
    if (!list) return out;
    for (let i = 0; i < list.length; i++) {
      const f = list[i];
      if (f && f.type && ACCEPT.indexOf(f.type) !== -1) out.push(f);
    }
    return out;
  }

  window.BarkparkChatComposer = {
    mounted() {
      // ── image attachments ──────────────────────────────────────────────
      this._onPaste = (e) => {
        const files = imageFiles(e.clipboardData && e.clipboardData.files);
        if (files.length) {
          e.preventDefault();
          this.upload(UPLOAD, files);
        }
      };

      // preventDefault on dragover is required for a drop to fire on the element.
      this._onDragOver = (e) => {
        if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
        e.preventDefault();
      };

      this._onDrop = (e) => {
        const files = imageFiles(e.dataTransfer && e.dataTransfer.files);
        if (files.length) {
          e.preventDefault();
          this.upload(UPLOAD, files);
        }
      };

      this.el.addEventListener("paste", this._onPaste);
      this.el.addEventListener("dragover", this._onDragOver);
      this.el.addEventListener("drop", this._onDrop);

      // ── slash-command combobox ─────────────────────────────────────────
      this._input = this.el.querySelector("#chat-composer");
      this._menu = this.el.querySelector("#chat-slash-menu");
      this._active = -1; // highlighted option index, -1 = none
      this._items = []; // the currently-filtered vocabulary

      if (this._input && this._menu) {
        this._onInput = () => this._refreshMenu();
        this._onKeyDown = (e) => this._onSlashKey(e);
        this._onBlur = () => this._closeMenu();

        this._input.addEventListener("input", this._onInput);
        this._input.addEventListener("keydown", this._onKeyDown);
        this._input.addEventListener("blur", this._onBlur);
      }

      // ── global Esc interrupt (charter D42) ──────────────────────────────
      // Esc stops the running turn from ANYWHERE on the page, mirroring the
      // Claude Code terminal — not just when the composer holds focus. A
      // document-level listener in the BUBBLE phase (never capture) lets the
      // two surfaces that already own Escape claim it first: the slash combobox
      // stopPropagation()s while its menu is open (see _onSlashKey), and the
      // session-rename input is skipped by its data attribute below. The server
      // handler is a no-op unless a turn is actually running, so a stray Esc at
      // an idle composer never interrupts a quiescent session.
      this._onDocKeydown = (e) => {
        if (e.key !== "Escape") return;
        // The session-rename input owns Escape (it cancels the rename); never
        // let a global Esc also fire an interrupt while renaming.
        if (e.target && e.target.closest && e.target.closest("[data-chat-rename]")) return;
        // We never close native <details>/popovers here — pushing stop_turn is
        // the whole job; leave the rest of the page's Escape behavior intact.
        this.pushEvent("stop_turn", {});
      };
      document.addEventListener("keydown", this._onDocKeydown);
    },

    updated() {
      // The server may broadcast a richer command list after the initialize ack
      // (charter D36a) — re-filter if the menu is open so it reflects the fresh
      // vocabulary without the user retyping.
      if (this._menu && !this._menu.hidden) this._refreshMenu();
    },

    destroyed() {
      this.el.removeEventListener("paste", this._onPaste);
      this.el.removeEventListener("dragover", this._onDragOver);
      this.el.removeEventListener("drop", this._onDrop);

      if (this._input) {
        this._input.removeEventListener("input", this._onInput);
        this._input.removeEventListener("keydown", this._onKeyDown);
        this._input.removeEventListener("blur", this._onBlur);
      }

      if (this._onDocKeydown) {
        document.removeEventListener("keydown", this._onDocKeydown);
        this._onDocKeydown = null;
      }
    },

    // The server-stamped vocabulary (re-read each time — the form's
    // data-commands is patched when the advertised list changes).
    _vocab() {
      try {
        const raw = this.el.getAttribute("data-commands");
        const parsed = raw ? JSON.parse(raw) : [];
        return Array.isArray(parsed) ? parsed : [];
      } catch (_e) {
        return [];
      }
    },

    // The leading command token being typed, or null when the value is not a
    // command-in-progress (no leading "/", or the name is already complete —
    // a space means the argument is being typed, so the menu closes).
    _query() {
      const v = this._input.value || "";
      if (v[0] !== "/") return null;
      if (/\s/.test(v)) return null;
      return v;
    },

    _refreshMenu() {
      const q = this._query();
      if (q === null) return this._closeMenu();

      const ql = q.toLowerCase();
      this._items = this._vocab().filter(
        (c) => c && typeof c.name === "string" && c.name.toLowerCase().indexOf(ql) === 0
      );

      if (this._items.length === 0) return this._closeMenu();

      this._active = 0;
      this._render();
      this._openMenu();
    },

    _render() {
      const menu = this._menu;
      menu.textContent = "";

      this._items.forEach((cmd, i) => {
        const li = document.createElement("li");
        li.id = "chat-slash-opt-" + i;
        li.setAttribute("role", "option");
        li.setAttribute("aria-selected", i === this._active ? "true" : "false");
        li.style.cssText =
          "display:flex; flex-direction:column; gap:2px; padding:6px 8px; border-radius:6px; cursor:pointer; " +
          (i === this._active ? "background: var(--primary-soft);" : "background: transparent;");

        const head = document.createElement("div");
        head.style.cssText = "display:flex; align-items:baseline; gap:8px;";

        const name = document.createElement("span");
        name.textContent = cmd.name;
        name.style.cssText = "font-family: var(--font-mono); font-weight:600;";
        head.appendChild(name);

        if (cmd.argumentHint) {
          const hint = document.createElement("span");
          hint.textContent = cmd.argumentHint;
          hint.className = "text-xs text-dim";
          hint.style.cssText = "font-family: var(--font-mono);";
          head.appendChild(hint);
        }

        li.appendChild(head);

        if (cmd.description) {
          const desc = document.createElement("span");
          desc.textContent = cmd.description;
          desc.className = "text-xs text-dim";
          li.appendChild(desc);
        }

        // mousedown (not click) + preventDefault: keep focus on the input so the
        // blur handler doesn't close the menu before the selection lands.
        li.addEventListener("mousedown", (e) => {
          e.preventDefault();
          this._select(i);
        });

        menu.appendChild(li);
      });

      this._input.setAttribute(
        "aria-activedescendant",
        this._active >= 0 ? "chat-slash-opt-" + this._active : ""
      );
    },

    _openMenu() {
      this._menu.hidden = false;
      this._input.setAttribute("aria-expanded", "true");
    },

    _closeMenu() {
      if (!this._menu) return;
      this._menu.hidden = true;
      this._menu.textContent = "";
      this._items = [];
      this._active = -1;
      this._input.setAttribute("aria-expanded", "false");
      this._input.setAttribute("aria-activedescendant", "");
    },

    _onSlashKey(e) {
      if (this._menu.hidden) return;

      switch (e.key) {
        case "ArrowDown":
          e.preventDefault();
          this._active = (this._active + 1) % this._items.length;
          this._render();
          break;
        case "ArrowUp":
          e.preventDefault();
          this._active = (this._active - 1 + this._items.length) % this._items.length;
          this._render();
          break;
        case "Enter":
        case "Tab":
          if (this._active >= 0) {
            e.preventDefault();
            this._select(this._active);
          }
          break;
        case "Escape":
          // Claim Escape while the menu is open: preventDefault + stopPropagation
          // so the document-level interrupt listener (charter D42) does NOT also
          // fire — a first Esc closes the menu, a second (menu now closed) stops
          // the turn.
          e.preventDefault();
          e.stopPropagation();
          this._closeMenu();
          break;
        default:
          break;
      }
    },

    // Insert the chosen command. A command that takes an argument leaves the
    // menu ready for typing (name + trailing space); a no-argument command runs
    // immediately (requestSubmit). BOTH first write the value + dispatch a native
    // input event so the server-bound draft (charter D24) is in sync.
    _select(i) {
      const cmd = this._items[i];
      if (!cmd) return;

      const takesArg = !!cmd.argumentHint;
      this._input.value = takesArg ? cmd.name + " " : cmd.name;
      this._input.dispatchEvent(new Event("input", { bubbles: true }));
      this._closeMenu();
      this._input.focus();

      if (!takesArg && typeof this.el.requestSubmit === "function") {
        this.el.requestSubmit();
      }
    }
  };
})();
