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
      // Row-paging window index — updated() resets the scroll to the top when
      // this flips so a page-flip lands at the new window's first row, not the
      // stale scroll offset the beforeUpdate hook would otherwise restore.
      this._rowOffset = this.el.dataset ? this.el.dataset.rowOffset : undefined;
      // ROOT REWIRE (#813 un-deadening): the formula bar lives in .sheet-toolbar,
      // a SIBLING of this hook element (.sheet-grid-wrap) inside .sheet-editor —
      // NOT a descendant. Listening on this.el (the old wiring) meant bar
      // keystrokes never reached the handler in a real browser, so #813's
      // bar-Escape restore and the cell→bar mirror were dead. Bind keydown +
      // input on the common ancestor so both the grid (inside el) and the bar
      // (a sibling) are covered; cell/td lookups still go through this.el.
      this.root = (this.el.closest && this.el.closest(".sheet-editor")) || this.el;
      // Function autocomplete: the server stamps the whole function vocabulary
      // on this element (data-fns), space-joined. _fn holds the live dropdown
      // state ({token,start,items,idx,navigated}); _menuEl is its rendered node.
      this._fns = (this.el.dataset && this.el.dataset.fns
        ? this.el.dataset.fns.split(/\s+/).filter(Boolean)
        : []);
      this._fn = null;
      this._menuEl = null;
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
          // Function-autocomplete dropdown intercepts FIRST (before commit/
          // cancel): ArrowUp/Down navigate, Tab ALWAYS accepts, Enter accepts
          // only if the user arrowed (else "=SU"+Enter commits raw), Escape is
          // two-stage (open → close only; closed → cancel the edit).
          const menuOpen = this._fn && this._fn.items && this._fn.items.length > 0;
          if (menuOpen && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
            e.preventDefault();
            this._fnNav(e.key === "ArrowDown" ? 1 : -1);
            this._fnRender(inp);
            return;
          }
          if (menuOpen && e.key === "Tab") {
            e.preventDefault();
            this._fnInsert(inp, this._fn.items[this._fn.idx < 0 ? 0 : this._fn.idx]);
            return;
          }
          if (menuOpen && e.key === "Enter" && this._fn.navigated) {
            e.preventDefault();
            this._fnInsert(inp, this._fn.items[this._fn.idx]);
            return;
          }
          if (menuOpen && e.key === "Escape") {
            e.preventDefault();
            this._fnClose(inp);
            return;
          }
          // In-cell editing: Enter/Tab commit + move (Excel muscle memory),
          // Escape cancels. Everything else is plain typing.
          if (e.key === "Enter") {
            e.preventDefault();
            this._refocus = true;
            this._fnClose(inp);
            this.pushEventTo(this.el, "edit-commit", { value: inp.value, move: e.shiftKey ? "up" : "down" });
          } else if (e.key === "Tab") {
            e.preventDefault();
            this._refocus = true;
            this._fnClose(inp);
            this.pushEventTo(this.el, "edit-commit", { value: inp.value, move: e.shiftKey ? "left" : "right" });
          } else if (e.key === "Escape") {
            e.preventDefault();
            this._refocus = true;
            this._fnClose(inp);
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
        // Header click selects the whole row/col (shift-extends from the
        // active cell). The menu button, resize handle, and open menu all
        // nest INSIDE the th, so a naive closest("th") would steal their
        // clicks — the three guards keep them working.
        const th = e.target.closest && e.target.closest("th.sheet-colhead, th.sheet-rowhead");
        if (th && !(e.target.closest(".sheet-head-menu-btn") || e.target.closest(".sheet-rsz") || e.target.closest(".sheet-menu"))) {
          this.el.focus({ preventScroll: true });
          this.pushEventTo(this.el, "head-click", {
            kind: th.dataset.c != null ? "col" : "row",
            index: parseInt(th.dataset.c != null ? th.dataset.c : th.dataset.r, 10),
            shift: e.shiftKey,
          });
          return;
        }
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
        // Bar lives OUTSIDE this.el (see root rewire) — look it up on root.
        const bar = this.root.querySelector(".sheet-bar-input");
        if (bar && document.activeElement !== bar) bar.value = inp.value;
        this._fnUpdate(inp);
      };

      // keydown + input bind on root (the bar is a sibling of this.el); the
      // rest stay on this.el (they act on grid cells inside the hook element).
      this.root.addEventListener("keydown", this._onKeydown);
      this.root.addEventListener("input", this._onInput);
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
      // A row-page flip: reset the vertical scroll to the top (the new window's
      // first row) instead of restoring the pre-patch offset. Columns are
      // unchanged, so the horizontal scroll is preserved.
      const off = this.el.dataset ? this.el.dataset.rowOffset : undefined;
      const paged = off !== this._rowOffset;
      this._rowOffset = off;
      if (this.scrollEl && this._scrollTop != null) {
        this.scrollEl.scrollTop = paged ? 0 : this._scrollTop;
        this.scrollEl.scrollLeft = this._scrollLeft;
      }
      const inp = this.el.querySelector(".sheet-cell-input");
      if (inp) {
        if (document.activeElement !== inp) {
          inp.focus();
          const n = inp.value.length;
          try { inp.setSelectionRange(n, n); } catch (_e) { /* number inputs */ }
        }
        // morphdom replaced the cell input node; re-render the dropdown from
        // the surviving state so an open menu isn't orphaned on the old node.
        if (this._fn && this._fn.items && this._fn.items.length) this._fnRender(inp);
      } else {
        // No editor on screen (commit/cancel/nav) — the menu can't belong to
        // anything; drop it.
        if (this._fn) this._fnClose();
        if (this._refocus) {
          this._refocus = false;
          this.el.focus({ preventScroll: true });
        }
      }
      // The server re-render reflects every cursor/selection change
      // (cell-click, nav, tab-switch) — derive the presence frame from the
      // fresh DOM; the throttle + dedupe keep remote-delta re-renders quiet.
      this._presencePing();
    },

    destroyed() {
      // Element-scoped listeners die with the node; the drag handlers
      // remove themselves on mouseup. The keydown/input listeners live on
      // root (an ANCESTOR that outlives this hook element), so remove them
      // by hand or they leak across a hook remount.
      if (this.root) {
        this.root.removeEventListener("keydown", this._onKeydown);
        this.root.removeEventListener("input", this._onInput);
      }
      if (this._menuEl && this._menuEl.remove) this._menuEl.remove();
      if (this._presTimer) clearTimeout(this._presTimer);
    },

    // ── function autocomplete ──────────────────────────────────────────────

    // The function token under the caret, or null. A token is autocompletable
    // ONLY inside a formula (value starts "=") and when it sits at the formula
    // start or right after an operator/paren/comma — never a cell reference
    // (A1, AB12), which is shaped like a name but is not one.
    _fnToken(value, caret) {
      if (!value || value[0] !== "=") return null;
      const end = caret == null ? value.length : caret;
      const head = value.slice(0, end);
      const m = head.match(/[A-Za-z][A-Za-z0-9.]*$/);
      if (!m) return null;
      const token = m[0];
      const start = head.length - token.length;
      if (/^[A-Za-z]{1,3}[0-9]+$/.test(token)) return null; // cell ref, not a fn
      if (start === 1) return { token: token, start: start }; // right after "="
      const before = start > 0 ? value[start - 1] : "";
      if (before && "=+-*/^&(,<>% ".indexOf(before) >= 0) return { token: token, start: start };
      return null;
    },

    // Prefix matches (case-insensitive), capped at 8. Empty token → no menu.
    _fnMatches(token) {
      if (!token) return [];
      const t = token.toUpperCase();
      const out = [];
      for (let i = 0; i < this._fns.length; i++) {
        if (this._fns[i].toUpperCase().indexOf(t) === 0) {
          out.push(this._fns[i]);
          if (out.length >= 8) break;
        }
      }
      return out;
    },

    // Move the highlight; the first arrow from the un-navigated state lands on
    // the first (down) or last (up) item.
    _fnNav(dir) {
      const n = this._fn.items.length;
      if (this._fn.idx < 0) this._fn.idx = dir > 0 ? 0 : n - 1;
      else this._fn.idx = (this._fn.idx + dir + n) % n;
      this._fn.navigated = true;
    },

    // Recompute the dropdown from the cell input's current value+caret. No
    // matching token → close.
    _fnUpdate(inp) {
      const caret = inp.selectionStart != null ? inp.selectionStart : inp.value.length;
      const tok = this._fnToken(inp.value, caret);
      if (!tok) return void this._fnClose(inp);
      const items = this._fnMatches(tok.token);
      if (!items.length) return void this._fnClose(inp);
      this._fn = { token: tok.token, start: tok.start, items: items, idx: -1, navigated: false };
      this._fnRender(inp);
    },

    // Replace the token [start, caret) with "NAME(", drop the caret past the
    // paren, mirror into the formula bar, and close the menu.
    _fnInsert(inp, name) {
      if (!name) return void this._fnClose(inp);
      const caret = inp.selectionStart != null ? inp.selectionStart : inp.value.length;
      const start = this._fn ? this._fn.start : caret;
      const insert = name + "(";
      inp.value = inp.value.slice(0, start) + insert + inp.value.slice(caret);
      const pos = start + insert.length;
      try { inp.setSelectionRange(pos, pos); } catch (_e) { /* number inputs */ }
      const bar = this.root.querySelector(".sheet-bar-input");
      if (bar && document.activeElement !== bar) bar.value = inp.value;
      this._fnClose(inp);
    },

    // Tear down the menu + reset the combobox ARIA. Safe with no input node.
    _fnClose(inp) {
      const wasOpen = !!this._fn;
      this._fn = null;
      if (this._menuEl && this._menuEl.remove) this._menuEl.remove();
      this._menuEl = null;
      const el = inp || (this.el.querySelector && this.el.querySelector(".sheet-cell-input"));
      if (el && el.setAttribute) {
        el.setAttribute("aria-expanded", "false");
        if (el.removeAttribute) {
          el.removeAttribute("aria-activedescendant");
          el.removeAttribute("aria-controls");
        }
      }
      return wasOpen;
    },

    // Paint the floating listbox (browser-only geometry) + sync the combobox
    // ARIA. The node harness has no document.createElement / scrollEl, so we
    // bail after the ARIA update — the harness pins the pure token/match/insert
    // + keydown logic, not pixel placement (that's the live-Studio carve-out).
    _fnRender(inp) {
      if (inp && inp.setAttribute) {
        inp.setAttribute("aria-expanded", "true");
        inp.setAttribute("aria-controls", "sheet-fn-menu");
        if (this._fn.idx >= 0) inp.setAttribute("aria-activedescendant", "sheet-fn-opt-" + this._fn.idx);
        else if (inp.removeAttribute) inp.removeAttribute("aria-activedescendant");
      }
      if (typeof document === "undefined" || !document.createElement || !this.scrollEl) return;
      if (!this._menuEl) {
        this._menuEl = document.createElement("div");
        this._menuEl.id = "sheet-fn-menu";
        this._menuEl.className = "sheet-fn-menu";
        this._menuEl.setAttribute("role", "listbox");
        this.scrollEl.appendChild(this._menuEl);
      }
      this._menuEl.innerHTML = "";
      const td = inp && inp.closest ? inp.closest("td") : null;
      if (td) {
        this._menuEl.style.position = "absolute";
        this._menuEl.style.left = td.offsetLeft + "px";
        this._menuEl.style.top = td.offsetTop + td.offsetHeight + "px";
      }
      this._fn.items.forEach((name, i) => {
        const opt = document.createElement("div");
        opt.id = "sheet-fn-opt-" + i;
        opt.className = "sheet-fn-opt" + (i === this._fn.idx ? " is-active" : "");
        opt.setAttribute("role", "option");
        opt.setAttribute("aria-selected", i === this._fn.idx ? "true" : "false");
        opt.textContent = name;
        // MOUSEDOWN, not click: a click first blurs the input (closing the
        // editor) before the handler runs; mousedown fires with the input
        // still focused, so preventDefault keeps it and the insert lands.
        opt.addEventListener("mousedown", (ev) => {
          ev.preventDefault();
          this._fnInsert(inp, name);
        });
        this._menuEl.appendChild(opt);
      });
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
