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

      this._onKeydown = (e) => {
        const inp = e.target.closest && e.target.closest(".sheet-cell-input");
        if (inp) {
          // In-cell editing: Enter/Tab commit + move (Excel muscle memory),
          // Escape cancels. Everything else is plain typing.
          if (e.key === "Enter") {
            e.preventDefault();
            this._refocus = true;
            this.pushEventTo(this.el, "edit-commit", { value: inp.value, move: "down" });
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

        if (NAV_KEYS.indexOf(e.key) >= 0) {
          e.preventDefault();
          this.pushEventTo(this.el, "nav", { key: e.key, shift: e.shiftKey });
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
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        this.el.focus({ preventScroll: true });
        this.pushEventTo(this.el, "cell-click", { ref: td.dataset.ref, shift: e.shiftKey });
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

      this.el.addEventListener("keydown", this._onKeydown);
      this.el.addEventListener("click", this._onClick);
      this.el.addEventListener("dblclick", this._onDblclick);
      this.el.addEventListener("copy", this._onCopy);
      this.el.addEventListener("paste", this._onPaste);
      this.el.addEventListener("mousedown", this._onMousedown);
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
    },

    destroyed() {
      // Element-scoped listeners die with the node; the drag handlers
      // remove themselves on mouseup.
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
