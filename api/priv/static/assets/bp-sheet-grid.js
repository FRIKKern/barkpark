// bp-sheet-grid.js — thin client half of the Studio sheet grid (Sheets M2).
//
// Keyboard map, clipboard TSV read/write, header resize drag and
// scroll-position keep. ALL grid state lives server-side in the
// BarkparkWeb.Studio.SheetGrid LiveComponent; every edit becomes a
// Barkpark.Sheets.Session op. No grid/spreadsheet JS dependency.
//
// Loaded (non-defer, after phoenix_live_view.js) so the inline Hooks
// registration in root.html.heex can pick it up before the LiveSocket
// connects: `Hooks.SheetGrid = window.BarkparkSheetGrid`.
(function () {
  const NAV_KEYS = [
    "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
    "Home", "End", "PageUp", "PageDown"
  ];

  window.BarkparkSheetGrid = {
    mounted() {
      this.scrollEl = this.el.querySelector(".sheet-scroll");
      this._refocus = false;
      // Collaborator presence (M4): cursor/selection frames are throttled
      // client-side to ~10/s and deduped — see _presencePing below.
      this._presLast = 0;
      this._presTimer = null;
      this._presSent = "";

      this._onKeydown = (e) => {
        const bar = e.target.closest && e.target.closest(".sheet-bar-input");
        if (bar) {
          // Formula bar: Tab commits the draft + moves right (Shift → left),
          // reusing the edit-commit move machinery — without this Tab blurs
          // natively and the typed draft reverts on the next patch (the
          // silent-loss class #813 fixed for the cell editor). _refocus hands
          // focus back to the grid, same as edit-commit.
          // Escape restores the committed value (the server stamps it as
          // data-raw) and hands focus back to the grid — a stale draft can no
          // longer sit in the bar looking committed. Enter already commits via
          // the surrounding form.
          if (e.key === "Tab") {
            e.preventDefault();
            this._refocus = true;
            this.pushEventTo(this.el, "bar-commit", { value: bar.value, move: e.shiftKey ? "left" : "right" });
            return;
          }
          if (e.key === "Escape") {
            e.preventDefault();
            bar.value = bar.dataset.raw != null ? bar.dataset.raw : "";
            this.el.focus({ preventScroll: true });
          }
          return;
        }
        const inp = e.target.closest && e.target.closest(".sheet-cell-input");
        if (inp) {
          // In-cell editing: Enter/Tab commit + move (Excel muscle memory),
          // Escape cancels. Everything else is plain typing.
          if (e.key === "Enter") {
            e.preventDefault();
            this._refocus = true;
            this.pushEventTo(this.el, "edit-commit", { value: inp.value, move: e.shiftKey ? "up" : "down" });
          } else if (e.key === "Tab") {
            e.preventDefault();
            this._refocus = true;
            this.pushEventTo(this.el, "edit-commit", { value: inp.value, move: e.shiftKey ? "left" : "right" });
          } else if (e.key === "Escape") {
            e.preventDefault();
            this._refocus = true;
            this.pushEventTo(this.el, "edit-cancel", {});
          }
          return;
        }
        // Name box / formula bar / tab-rename inputs keep native behaviour.
        if (e.target.matches && e.target.matches("input, textarea, select")) return;

        // Per-user undo/redo (M4): Cmd/Ctrl+Z undoes THIS user's last op,
        // Cmd/Ctrl+Shift+Z redoes it. The server pops the per-user inverse
        // stack and the resulting delta re-renders every client.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && (e.key === "z" || e.key === "Z")) {
          e.preventDefault();
          this.pushEventTo(this.el, e.shiftKey ? "redo" : "undo", {});
          return;
        }

        // Fill down/right (Cmd/Ctrl+D / Cmd/Ctrl+R): the selection's first
        // row/column seeds every other cell in the rect, with a per-step
        // formula rebase server-side.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && (e.key === "d" || e.key === "r")) {
          e.preventDefault();
          this.pushEventTo(this.el, "fill", { dir: e.key === "d" ? "down" : "right" });
          return;
        }

        // Structural insert/delete (Cmd/Ctrl+Alt+= inserts, Cmd/Ctrl+Alt+-
        // deletes; Shift targets columns instead of rows) — Google Sheets'
        // idiom that sidesteps raw Ctrl+- browser zoom. Match e.code, not
        // e.key: Shift turns "=" into "+" so e.key is layout-dependent.
        if ((e.metaKey || e.ctrlKey) && e.altKey) {
          const ins = e.code === "Equal" || e.code === "NumpadAdd";
          const del = e.code === "Minus" || e.code === "NumpadSubtract";
          if (ins || del) {
            e.preventDefault();
            this.pushEventTo(this.el, "rowcol-key", {
              kind: e.shiftKey ? "col" : "row",
              action: ins ? "insert" : "delete",
            });
            return;
          }
        }

        if (NAV_KEYS.indexOf(e.key) >= 0) {
          e.preventDefault();
          this.pushEventTo(this.el, "nav", { key: e.key, shift: e.shiftKey });
        } else if (e.key === "Tab") {
          // Tab/Shift+Tab walk the selection within the grid (Excel muscle
          // memory) rather than tabbing focus out — the nav handler clamps.
          e.preventDefault();
          this.pushEventTo(this.el, "nav", { key: e.shiftKey ? "ArrowLeft" : "ArrowRight", shift: false });
        } else if (e.key === "Enter" || e.key === "F2") {
          e.preventDefault();
          this.pushEventTo(this.el, "edit-start", {});
        } else if (e.key === "Delete" || e.key === "Backspace") {
          e.preventDefault();
          this.pushEventTo(this.el, "clear-selection", {});
        } else if (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
          // Typing replaces the cell content — the seed becomes the prefill.
          e.preventDefault();
          this.pushEventTo(this.el, "edit-start", { seed: e.key });
        }
      };

      this._onClick = (e) => {
        // A mouse drag already anchored + extended the selection via
        // _onCellMousedown; the trailing synthetic click would re-anchor and
        // collapse it, so swallow exactly one click after a drag/mousedown.
        if (this._suppressClick) { this._suppressClick = false; return; }
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        this.el.focus({ preventScroll: true });
        this.pushEventTo(this.el, "cell-click", { ref: td.dataset.ref, shift: e.shiftKey });
      };

      // Mouse drag-to-select — Excel's core gesture. Mousedown anchors
      // (shift:false clears the anchor server-side), each newly-entered cell
      // extends the rectangle (shift:true → Geometry.grid_sel). Reuses the
      // existing cell-click shift-anchor protocol, so the server needs no
      // change. Resize-handle mousedowns and input targets are left alone.
      this._onCellMousedown = (e) => {
        if (e.button !== 0) return;
        if (e.target.closest && e.target.closest(".sheet-rsz")) return;
        if (e.target.matches && e.target.matches("input, textarea, select")) return;
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        e.preventDefault();
        this.el.focus({ preventScroll: true });
        this._suppressClick = true;
        // Excel semantics: clicking away from an open editor COMMITS the
        // draft (never silently discards it). The draft rides the same
        // cell-click push; the server commits it to the still-active cell
        // before moving the cursor.
        const draft = this.el.querySelector(".sheet-cell-input");
        const payload = { ref: td.dataset.ref, shift: e.shiftKey };
        if (draft) payload.commit = draft.value;
        this.pushEventTo(this.el, "cell-click", payload);
        let last = td.dataset.ref;
        const onOver = (ev) => {
          const t = ev.target.closest && ev.target.closest("td[data-ref]");
          if (!t || t.dataset.ref === last) return;
          last = t.dataset.ref;
          this.pushEventTo(this.el, "cell-click", { ref: t.dataset.ref, shift: true });
        };
        const onUp = () => {
          this.el.removeEventListener("mouseover", onOver);
          window.removeEventListener("mouseup", onUp);
        };
        this.el.addEventListener("mouseover", onOver);
        window.addEventListener("mouseup", onUp);
      };

      this._onDblclick = (e) => {
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        this.pushEventTo(this.el, "edit-start", {});
      };

      // Cmd/Ctrl+C — selection as TSV of computed values, written
      // synchronously in-gesture via the clipboard event.
      this._onCopy = (e) => {
        if (e.target.matches && e.target.matches("input, textarea")) return;
        const tsv = this._selectionTsv();
        if (tsv == null) return;
        e.preventDefault();
        e.clipboardData.setData("text/plain", tsv);
      };

      // Cmd/Ctrl+V — TSV block applied as batch set_cell ops from the
      // active cell (values only; the server replies cap-aware errors).
      this._onPaste = (e) => {
        if (e.target.matches && e.target.matches("input, textarea")) return;
        const text = e.clipboardData && e.clipboardData.getData("text/plain");
        if (!text) return;
        e.preventDefault();
        this.pushEventTo(this.el, "paste", { tsv: text });
      };

      // Header resize drag -> ONE set_col_width / set_row_height op on release.
      this._onMousedown = (e) => {
        const h = e.target.closest && e.target.closest(".sheet-rsz");
        if (!h) return;
        e.preventDefault();
        e.stopPropagation();
        const kind = h.dataset.kind;
        const start = kind === "col" ? e.pageX : e.pageY;
        const base = parseInt(h.dataset.px, 10) || (kind === "col" ? 88 : 24);
        const onMove = (ev) => ev.preventDefault();
        const onUp = (ev) => {
          window.removeEventListener("mousemove", onMove);
          window.removeEventListener("mouseup", onUp);
          const delta = (kind === "col" ? ev.pageX : ev.pageY) - start;
          const px = Math.max(kind === "col" ? 24 : 14, Math.round(base + delta));
          this.pushEventTo(this.el, "resize", { kind: kind, index: parseInt(h.dataset.index, 10), px: px });
        };
        window.addEventListener("mousemove", onMove);
        window.addEventListener("mouseup", onUp);
      };

      // One-way live mirror: typing in the cell editor previews in the
      // formula bar. The reverse direction (bar keystrokes previewing in
      // the cell) is deliberately deferred to the formula-editing design
      // task — do not half-build it here.
      this._onInput = (e) => {
        const inp = e.target.closest && e.target.closest(".sheet-cell-input");
        if (!inp) return;
        const bar = this.el.querySelector(".sheet-bar-input");
        if (bar && document.activeElement !== bar) bar.value = inp.value;
      };

      this.el.addEventListener("keydown", this._onKeydown);
      this.el.addEventListener("input", this._onInput);
      this.el.addEventListener("click", this._onClick);
      this.el.addEventListener("dblclick", this._onDblclick);
      this.el.addEventListener("copy", this._onCopy);
      this.el.addEventListener("paste", this._onPaste);
      this.el.addEventListener("mousedown", this._onMousedown);
      this.el.addEventListener("mousedown", this._onCellMousedown);

      this._presencePing();
    },

    beforeUpdate() {
      if (this.scrollEl) {
        this._scrollTop = this.scrollEl.scrollTop;
        this._scrollLeft = this.scrollEl.scrollLeft;
      }
    },

    updated() {
      this.scrollEl = this.el.querySelector(".sheet-scroll");
      if (this.scrollEl && this._scrollTop != null) {
        this.scrollEl.scrollTop = this._scrollTop;
        this.scrollEl.scrollLeft = this._scrollLeft;
      }
      const inp = this.el.querySelector(".sheet-cell-input");
      if (inp) {
        if (document.activeElement !== inp) {
          inp.focus();
          const n = inp.value.length;
          try { inp.setSelectionRange(n, n); } catch (_e) { /* number inputs */ }
        }
      } else if (this._refocus) {
        this._refocus = false;
        this.el.focus({ preventScroll: true });
      }
      // The server re-render reflects every cursor/selection change
      // (cell-click, nav, tab-switch) — derive the presence frame from the
      // fresh DOM; the throttle + dedupe keep remote-delta re-renders quiet.
      this._presencePing();
    },

    destroyed() {
      // Element-scoped listeners die with the node; the drag handlers
      // remove themselves on mouseup.
      if (this._presTimer) clearTimeout(this._presTimer);
    },

    // Trailing-edge throttle at 100ms (~10/s): grid interactions re-render
    // far faster than collaborators need cursor frames. Identical payloads
    // are deduped so remote-delta re-renders never echo.
    _presencePing() {
      if (this._presTimer) return;
      const wait = Math.max(0, 100 - (Date.now() - this._presLast));
      this._presTimer = setTimeout(() => {
        this._presTimer = null;
        this._presLast = Date.now();
        const payload = this._presencePayload();
        const key = JSON.stringify(payload);
        if (key === this._presSent) return;
        this._presSent = key;
        this.pushEventTo(this.el, "presence-meta", payload);
      }, wait);
    },

    // Active ref + selection range read off the rendered grid (the server
    // marks .sheet-active / .sheet-sel). A single-cell rect is no selection.
    _presencePayload() {
      const active = this.el.querySelector("td.sheet-active");
      const sel = this.el.querySelectorAll("td.sheet-sel");
      let selection = null;
      if (sel.length > 1) {
        let c1 = Infinity, r1 = Infinity, c2 = 0, r2 = 0;
        sel.forEach((td) => {
          const c = parseInt(td.dataset.c, 10);
          const r = parseInt(td.dataset.r, 10);
          if (c < c1) c1 = c;
          if (c > c2) c2 = c;
          if (r < r1) r1 = r;
          if (r > r2) r2 = r;
        });
        selection = this._colLetters(c1) + r1 + ":" + this._colLetters(c2) + r2;
      }
      return { active: active ? active.dataset.ref : null, selection: selection };
    },

    _colLetters(c) {
      let s = "";
      while (c > 0) {
        s = String.fromCharCode(65 + ((c - 1) % 26)) + s;
        c = Math.floor((c - 1) / 26);
      }
      return s;
    },

    // Selection (server marks every selected td with .sheet-sel, the active
    // cell included) -> TSV, row-major, computed values from data-v.
    _selectionTsv() {
      const tds = this.el.querySelectorAll("td.sheet-sel");
      if (!tds.length) return null;
      const rows = new Map();
      tds.forEach((td) => {
        const r = parseInt(td.dataset.r, 10);
        const c = parseInt(td.dataset.c, 10);
        if (!rows.has(r)) rows.set(r, new Map());
        rows.get(r).set(c, td.dataset.v != null ? td.dataset.v : td.textContent.trim());
      });
      const rKeys = Array.from(rows.keys()).sort((a, b) => a - b);
      return rKeys.map((r) => {
        const cols = rows.get(r);
        const cKeys = Array.from(cols.keys()).sort((a, b) => a - b);
        return cKeys.map((c) => cols.get(c)).join("\t");
      }).join("\n");
    }
  };
})();
