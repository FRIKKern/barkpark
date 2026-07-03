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

  // Fat-finger guard: a whole-column Excel copy (up to 1M rows) must not ship a
  // multi-MB frame that stalls the LiveView. Mirrors the session's 50k cell cap
  // (Barkpark.Plugins.Sheets.Session cell_cap); the server clause re-checks so
  // an old client can't bypass it. Overridable per-instance for the harness.
  const PASTE_CELL_CAP = 50000;

  window.BarkparkSheetGrid = {
    mounted() {
      this.scrollEl = this.el.querySelector(".sheet-scroll");
      this._refocus = false;
      // Paste preflight bound (mirrors the server cap); overridable in tests.
      this._pasteCellCap = PASTE_CELL_CAP;
      // One-shot: Ctrl+F sets this so updated() focuses the find input once the
      // server has rendered the find bar.
      this._focusFind = false;
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
      // One-shot Tab-exit flag (WCAG 2.1.2): Escape sets it, the next Tab reads
      // + clears it to fall through natively; any other grid key re-arms.
      this._tabExits = false;

      // ── Sheets formula-UX wiring (wave 2, S6+S7). ALL grammar decisions route
      // through the two pure kernels (window.BarkparkSheetFormula /
      // window.BarkparkSheetPointing) — this hook adds NO tokenizer/grammar of
      // its own, only DOM wiring (Decision 1: 100% client-owned, no new server
      // events; the server sees only the final edit-commit/bar-commit payload).
      this._F = (typeof window !== "undefined" && window.BarkparkSheetFormula) || null;
      this._P = (typeof window !== "undefined" && window.BarkparkSheetPointing) || null;
      // Read-only sheets stamp no data-fns and never render a cell editor —
      // fail closed, never enter point-mode (Decision 12).
      this._readOnly = !(this.el.dataset && this.el.dataset.fns);
      // Signature index: NAME-keyed {args, doc}, parsed ONCE at mount (Decision 9).
      this._fnSigs = {};
      try {
        if (this.el.dataset && this.el.dataset.fnSigs) this._fnSigs = JSON.parse(this.el.dataset.fnSigs);
      } catch (_e) { this._fnSigs = {}; }
      // Volatile "hot ref" span {start,end}: the range being actively pointed/
      // dragged this session (Decision 4). null between sessions; any typed
      // character locks it (cleared in _onInput).
      this._hot = null;
      // Enter-mode phantom-cursor state {anchor,head}|null (Decision 5).
      this._phantom = null;
      // Excel Enter-mode vs Edit-mode: 'enter' (arrows drive the phantom ref
      // cursor in ref-context) | 'edit' (arrows move the text caret). Edits
      // begun by typing/'=' start in Enter-mode; F2/double-click toggles.
      this._editMode = "enter";
      // Ghost predictor state {offered:text|null} — reduced ONLY by the kernel
      // ghostReduce (never steals a keystroke, Decision 7).
      this._ghost = { offered: null };
      // Point-session bookkeeping for the Escape ladder (Decision 12): the
      // pre-point value/caret snapshot to revert to.
      this._pointSession = false;
      this._pointBase = null;
      // Client-injected chrome nodes (created lazily in a real browser; the
      // node harness has no document.createElement, so every render bails).
      this._refLayerEl = null;
      this._barMirrorEl = null;
      this._sigEl = null;
      this._ghostEl = null;
      this._modeChipEl = null;
      this._srEl = null;

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
            // Canonicalize at the commit push only (Decision 11): uppercase known
            // fns + refs and balance trailing parens. Server write paths untouched.
            this.pushEventTo(this.el, "bar-commit", {
              value: this._normalize(bar.value),
              move: e.shiftKey ? "left" : "right",
            });
            return;
          }
          if (e.key === "Escape") {
            e.preventDefault();
            bar.value = bar.dataset.raw != null ? bar.dataset.raw : "";
            this.el.focus({ preventScroll: true });
          }
          return;
        }
        // Find-in-sheet input: Escape closes the bar and hands focus back to
        // the grid. Enter submits via the surrounding form (find-next); every
        // other key types normally, so we return without touching the grid map.
        const find = e.target.closest && e.target.closest(".sheet-find-input");
        if (find) {
          if (e.key === "Escape") {
            e.preventDefault();
            this.pushEventTo(this.el, "find-close", {});
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
          // F2 toggles Enter-mode ⇄ Edit-mode (Decision 5): in Edit-mode arrows
          // move the text caret, in Enter-mode they drive the phantom ref cursor.
          if (e.key === "F2") {
            e.preventDefault();
            this._editMode = this._editMode === "edit" ? "enter" : "edit";
            this._phantom = null;
            this._updateModeChip();
            return;
          }
          // F4 cycles the $-anchoring of the ref at/left-of the caret (Decision
          // 10): A1 → $A$1 → A$1 → $A1 → A1; ranges cycle both endpoints.
          // Read-only sheets fail closed on EVERY point entry (Decision 12): F4
          // is a point-mutation, so a read-only editor lets it fall through native.
          if (e.key === "F4" && this._F && !this._readOnly) {
            e.preventDefault();
            var cyc = this._F.cycleDollar(inp.value, this._caretOf(inp));
            if (cyc) {
              inp.value = cyc.value;
              try { inp.setSelectionRange(cyc.caret, cyc.caret); } catch (_e) { /* noop */ }
              this._afterPointChange(inp);
            }
            return;
          }
          // Enter-mode phantom-cursor arrows (Decision 5): only when the caret
          // expects a reference and the menu is closed. Shift extends; Ctrl/Cmd
          // edge-jumps. Edit-mode arrows fall through to native caret movement.
          // Read-only fails closed here too (Decision 12) — arrows stay native.
          if (!menuOpen && this._editMode !== "edit" && this._F && this._P && !this._readOnly &&
              (e.key === "ArrowUp" || e.key === "ArrowDown" || e.key === "ArrowLeft" || e.key === "ArrowRight")) {
            const actx = this._ctx(inp);
            if (actx.action === "point-insert" || actx.action === "point-replace") {
              e.preventDefault();
              this._ghostDismiss(inp);
              const dir = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" }[e.key];
              const opts = {
                active: this._activePos() || { c: 1, r: 1 },
                shift: e.shiftKey,
                edge: !!(e.ctrlKey || e.metaKey),
              };
              this._startPoint(inp);
              const r = this._P.phantomStep(this._phantom, dir, opts, this._getCell(), this._bounds());
              this._phantom = r.state;
              this._pointInsertRef(inp, r.refText);
              return;
            }
          }
          // In-cell editing: Enter/Tab commit + move (Excel muscle memory),
          // Escape cancels. Everything else is plain typing. On Enter/Tab the
          // ghost predictor accepts-and-commits in ONE keystroke IF it is
          // showing (Decision 7); precedence is dropdown-navigated completion
          // (handled above) > ghost accept-and-commit > plain commit.
          if (e.key === "Enter") {
            e.preventDefault();
            this._commitEditor(inp, e.shiftKey ? "up" : "down");
          } else if (e.key === "Tab") {
            e.preventDefault();
            this._commitEditor(inp, e.shiftKey ? "left" : "right");
          } else if (e.key === "Escape") {
            e.preventDefault();
            // Escape ladder, strictly ordered (Decision 12): dropdown/ghost →
            // pending point session → cancel edit.
            if (menuOpen) {
              this._fnClose(inp);
            } else if (this._ghost && this._ghost.offered) {
              this._ghostDismiss(inp);
            } else if (this._pointSession) {
              this._endPointSession(inp);
            } else {
              this._refocus = true;
              this._fnClose(inp);
              this._endChrome();
              this.pushEventTo(this.el, "edit-cancel", {});
            }
          }
          return;
        }
        // GRID SCOPE GUARD (#843 keyboard-trap regression seal): keydown binds on
        // .sheet-editor (root) so the formula/find/cell inputs above — which live
        // OUTSIDE the grid element — are reachable. But that same ancestor also
        // contains the ~15 toolbar buttons, the undo/redo buttons, and the tab
        // strip. Without this guard EVERY focused button fed the grid key map:
        // Enter/Space opened the cell editor (a surprise mutation) and Tab was
        // preventDefaulted into grid nav — re-trapping the keyboard (WCAG 2.1.2)
        // across the whole toolbar. The input branches above already handled the
        // only non-grid targets the grid key map should touch; anything else
        // outside the grid element falls through to native browser behaviour.
        if (!(e.target === this.el || (this.el.contains && this.el.contains(e.target)))) return;
        // Name box / formula bar / tab-rename inputs keep native behaviour.
        if (e.target.matches && e.target.matches("input, textarea, select")) return;

        // WCAG 2.1.2 escape hatch: Tab normally walks the selection (a keyboard
        // trap — focus can never leave the grid). Escape arms a one-shot so the
        // NEXT Tab/Shift+Tab falls through to the browser and moves focus out;
        // any other key clears the flag and re-arms the trap. No cell editor or
        // menu is open here (those return above), so Escape is free to mean this.
        if (e.key === "Escape") {
          this._tabExits = true;
          return;
        }
        if (e.key === "Tab" && this._tabExits) {
          this._tabExits = false;
          return; // native Tab — focus leaves the grid
        }
        // Any real key re-arms the trap, but a BARE modifier keydown must not:
        // Shift+Tab fires a "Shift" keydown first, and clearing here would trap
        // the backward exit before the Tab arrives.
        if (e.key !== "Shift" && e.key !== "Control" && e.key !== "Alt" && e.key !== "Meta") {
          this._tabExits = false;
        }

        // Find-in-sheet (Cmd/Ctrl+F): open the server-rendered find bar instead
        // of the browser's native page find — a DOM find would only see the
        // 500-row window, so the server scans the whole sparse cells map. The
        // _focusFind flag makes updated() focus the input once it renders.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && (e.key === "f" || e.key === "F")) {
          e.preventDefault();
          this._focusFind = true;
          this.pushEventTo(this.el, "find-open", {});
          return;
        }

        // Per-user undo/redo (M4): Cmd/Ctrl+Z undoes THIS user's last op,
        // Cmd/Ctrl+Shift+Z redoes it. The server pops the per-user inverse
        // stack and the resulting delta re-renders every client.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && (e.key === "z" || e.key === "Z")) {
          e.preventDefault();
          this.pushEventTo(this.el, e.shiftKey ? "redo" : "undo", {});
          return;
        }

        // Bold / italic (Cmd/Ctrl+B / Cmd/Ctrl+I): the server reads the ACTIVE
        // cell's style, inverts b/i, and stamps the result across the selection
        // (Excel toggle). v1 GRID-NAV mode only — an open cell editor returned
        // early above, so native bold/italic in the editor is untouched.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && (e.key === "b" || e.key === "B" || e.key === "i" || e.key === "I")) {
          e.preventDefault();
          this.pushEventTo(this.el, "toggle-style", { k: (e.key === "b" || e.key === "B") ? "b" : "i" });
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

        // Select all (Cmd/Ctrl+A): the server selects the whole USED range —
        // without this branch the keydown fell through to the browser and
        // selected the page text around the grid. v1: one Ctrl+A = used range
        // (Excel's second press → whole sheet is deferred).
        if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && (e.key === "a" || e.key === "A")) {
          e.preventDefault();
          this.pushEventTo(this.el, "select-all", {});
          return;
        }

        // Whole row/col select (Shift+Space → row, Ctrl/Cmd+Space → col),
        // riding the EXISTING head-click server path with the active cell's
        // own index. MUST branch before the bare-Space branch below, which
        // would otherwise open an editor seeded with a literal space.
        if (e.key === " " && (e.shiftKey || e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          const active = this.el.querySelector("td.sheet-active");
          if (!active) return;
          const kind = e.shiftKey ? "row" : "col";
          this.pushEventTo(this.el, "head-click", {
            kind: kind,
            index: parseInt(kind === "row" ? active.dataset.r : active.dataset.c, 10),
            shift: false,
          });
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

        // Ctrl/Cmd+Arrow — Excel's data-edge jump (Shift extends the selection
        // to the edge target); Ctrl/Cmd+Home/End jump to A1 / the used range's
        // last cell. MUST branch before the plain NAV_KEYS map below, which
        // would otherwise single-step the same keys.
        if ((e.metaKey || e.ctrlKey) && !e.altKey) {
          const dir = {
            ArrowUp: "up",
            ArrowDown: "down",
            ArrowLeft: "left",
            ArrowRight: "right",
          }[e.key];
          if (dir) {
            e.preventDefault();
            this.pushEventTo(this.el, "nav-edge", { dir: dir, shift: e.shiftKey });
            return;
          }
          if (e.key === "Home" || e.key === "End") {
            e.preventDefault();
            this.pushEventTo(this.el, "nav-corner", { corner: e.key.toLowerCase(), shift: e.shiftKey });
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
        } else if (e.key === " ") {
          // Space toggles a checkbox-fmt active cell (the td carries the
          // "sheet-checkbox" class); on any other cell it seeds an edit with a
          // literal space, the prior behaviour.
          e.preventDefault();
          const active = this.el.querySelector("td.sheet-active");
          if (active && active.classList.contains("sheet-checkbox")) {
            this.pushEventTo(this.el, "cell-toggle", { ref: active.dataset.ref });
          } else {
            this.pushEventTo(this.el, "edit-start", { seed: " " });
          }
        } else if (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
          // Typing replaces the cell content — the seed becomes the prefill.
          e.preventDefault();
          this.pushEventTo(this.el, "edit-start", { seed: e.key });
        }
      };

      // Click-away commit rides (Excel/Sheets parity). A click that moves the
      // selection while an editor is open must COMMIT the draft, never silently
      // drop it: an open cell editor rides `commit`; a dirty, focused formula
      // bar rides `bar_commit`. The bar dirty-check (value !== the server-
      // stamped data-raw) is essential — an unconditional commit would rewrite
      // every cell on every click. The server commits both to the still-active
      // cell BEFORE it moves the cursor / changes the selection.
      this._rideCommits = (payload) => {
        const draft = this.el.querySelector(".sheet-cell-input");
        if (draft) payload.commit = draft.value;
        const bar = this.root && this.root.querySelector(".sheet-bar-input");
        if (bar && document.activeElement === bar && bar.value !== bar.dataset.raw) {
          payload.bar_commit = bar.value;
        }
        return payload;
      };

      // Toolbar draft-commit seal (#858/#862 silent-revert regression). The
      // number-format / style / align / bg / undo / redo buttons live in
      // .sheet-toolbar and fire phx-click handlers that route through
      // apply_meta_to_selection WITHOUT committing an open cell draft — so
      // clicking B/I/$/%/align/bg/undo while a cell editor held a typed draft
      // silently reverted it (the LiveView patch restored the pre-edit prefill
      // into the now-blurred input). mousedown fires BEFORE the button's click,
      // so ride the exact click-away protocol here first: re-select the STILL
      // active cell carrying the draft as `commit`, which commit_clickaway lands
      // on that cell before the format op applies to the same selection. Bound on
      // root (the toolbar is a sibling of the grid), filtered to the toolbar.
      this._onToolbarMousedown = (e) => {
        if (!(e.target.closest && e.target.closest(".sheet-toolbar"))) return;
        // Mousedown into a toolbar TEXT INPUT (formula bar / name box) is that
        // input's own focus/takeover flow (#813) — never commit-and-close here.
        if (e.target.matches && e.target.matches("input, textarea, select")) return;
        const draft = this.el.querySelector(".sheet-cell-input");
        if (!draft) return;
        const active = this.el.querySelector("td.sheet-active");
        const ref = active && active.dataset ? active.dataset.ref : null;
        if (!ref) return;
        this.pushEventTo(this.el, "cell-click", { ref: ref, shift: false, commit: draft.value });
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
          // A header click is a click-away: commit any open cell editor / dirty
          // bar to the still-active cell before the whole-row/col selection.
          this.pushEventTo(this.el, "head-click", this._rideCommits({
            kind: th.dataset.c != null ? "col" : "row",
            index: parseInt(th.dataset.c != null ? th.dataset.c : th.dataset.r, 10),
            shift: e.shiftKey,
          }));
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
        // Any mouse interaction re-arms the keyboard trap: an Escape then a
        // click (instead of Tab) must NOT leave a stale exit-arm that makes
        // the next Tab escape the grid unexpectedly (WCAG trap one-shot).
        this._tabExits = false;
        if (e.target.closest && e.target.closest(".sheet-rsz")) return;
        // The fill nub nests INSIDE the selection-corner td — its mousedown is
        // the fill gesture (_onFillMousedown), never a cell re-anchor (which
        // would collapse the very selection the fill extends from).
        if (e.target.closest && e.target.closest(".sheet-fillnub")) return;
        if (e.target.matches && e.target.matches("input, textarea, select")) return;
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        // POINT ROUTING (Decision 4 + Amendment A1): if an editor / focused-dirty
        // bar is active AND the caret expects a reference, a click POINTS — it
        // inserts the target's ref at the caret and preventDefaults so focus
        // never leaves the editor. Otherwise it falls through to today's
        // commit path BYTE-IDENTICAL (the #813/#858 seal, untouched).
        if (this._pointCellMousedown(e, td)) return;
        e.preventDefault();
        this.el.focus({ preventScroll: true });
        this._suppressClick = true;
        // Excel semantics: clicking away from an open editor COMMITS the draft
        // (never silently discards it). An open cell editor rides `commit`, a
        // dirty formula bar rides `bar_commit`; the server commits both to the
        // still-active cell before moving the cursor.
        const payload = this._rideCommits({ ref: td.dataset.ref, shift: e.shiftKey });
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

      // Click-drag across column/row headers — select multiple whole
      // columns/rows with the mouse (Excel parity, the header twin of
      // _onCellMousedown). Mousedown on a th anchors via the EXISTING
      // head-click server op (riding any open draft/dirty bar exactly like
      // _onClick's header branch — same _rideCommits seal, same three nested-
      // control guards); each newly-entered header of the SAME kind extends
      // with shift:true. The same-kind guard is mandatory: a col drag crossing
      // the corner into the row headers must NOT flip the selection to rows.
      // window mouseup tears down (mirrors the cell drag's onOver/onUp).
      this._onHeadMousedown = (e) => {
        if (e.button !== 0) return;
        if (e.target.matches && e.target.matches("input, textarea, select")) return;
        const th = e.target.closest && e.target.closest("th.sheet-colhead, th.sheet-rowhead");
        if (!th) return;
        // Menu button, resize handle, and open menu nest INSIDE the th — the
        // same guards _onClick uses keep their mousedowns out of the drag.
        if (e.target.closest(".sheet-head-menu-btn") || e.target.closest(".sheet-rsz") || e.target.closest(".sheet-menu")) return;
        // POINT ROUTING for headers (Decision 4): a header click while the caret
        // expects a reference inserts a whole-column (B:B) / whole-row (3:3) ref
        // and drag-extends it; otherwise falls through to the whole-row/col
        // selection path below, byte-identical.
        if (this._pointHeadMousedown(e, th)) return;
        e.preventDefault();
        // Mouse interaction re-arms the keyboard trap (same one-shot rule as
        // the cell drag).
        this._tabExits = false;
        this.el.focus({ preventScroll: true });
        this._suppressClick = true;
        const kind = th.dataset.c != null ? "col" : "row";
        let last = parseInt(kind === "col" ? th.dataset.c : th.dataset.r, 10);
        this.pushEventTo(this.el, "head-click", this._rideCommits({
          kind: kind,
          index: last,
          shift: e.shiftKey,
        }));
        const onOver = (ev) => {
          const t = ev.target.closest && ev.target.closest("th.sheet-colhead, th.sheet-rowhead");
          if (!t) return;
          if ((t.dataset.c != null ? "col" : "row") !== kind) return; // same-kind guard
          const idx = parseInt(kind === "col" ? t.dataset.c : t.dataset.r, 10);
          if (idx === last) return;
          last = idx;
          this.pushEventTo(this.el, "head-click", { kind: kind, index: idx, shift: true });
        };
        const onUp = () => {
          this.el.removeEventListener("mouseover", onOver);
          window.removeEventListener("mouseup", onUp);
        };
        this.el.addEventListener("mouseover", onOver);
        window.addEventListener("mouseup", onUp);
      };

      // Fill-handle drag (mousedown on the .sheet-fillnub at the selection
      // corner) — the mouse twin of Ctrl+D/R. Mirrors the cell drag's
      // onOver/onUp pattern but pushes NOTHING until mouseup: the server then
      // extends its own selection rect to the last hovered cell in ONE
      // fill-range op (so a formula rebase applies per step, exactly like the
      // keyboard fill). A drag that never leaves the corner (the first half of
      // the nub's double-click) resolves to the rect's own corner, which the
      // server treats as a no-op — the dblclick composes cleanly.
      this._onFillMousedown = (e) => {
        if (e.button !== 0) return;
        if (!(e.target.closest && e.target.closest(".sheet-fillnub"))) return;
        e.preventDefault();
        this._tabExits = false;
        this._suppressClick = true;
        let last = null;
        const onOver = (ev) => {
          const t = ev.target.closest && ev.target.closest("td[data-ref]");
          if (!t) return;
          last = t.dataset.ref;
        };
        const onUp = () => {
          this.el.removeEventListener("mouseover", onOver);
          window.removeEventListener("mouseup", onUp);
          if (last) this.pushEventTo(this.el, "fill-range", { to: last });
        };
        this.el.addEventListener("mouseover", onOver);
        window.addEventListener("mouseup", onUp);
      };

      this._onDblclick = (e) => {
        // Fill to the data extent: double-click the fill nub (Excel's idiom).
        // Must branch BEFORE the td lookup — the nub nests inside the corner
        // td, which would otherwise open the editor.
        if (e.target.closest && e.target.closest(".sheet-fillnub")) {
          this.pushEventTo(this.el, "fill-extent", {});
          return;
        }
        // Autofit: double-click a header resize handle sizes the col/row to
        // its content. Branched before the td lookup too (the handle lives in
        // a th, so closest("td") is null — the order still documents intent).
        const rsz = e.target.closest && e.target.closest(".sheet-rsz");
        if (rsz) {
          this.pushEventTo(this.el, "autofit", {
            kind: rsz.dataset.kind,
            index: parseInt(rsz.dataset.index, 10),
          });
          return;
        }
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

      // Cmd/Ctrl+V — TSV block applied as batch set_cell ops from the active
      // cell (values only; the server replies cap-aware errors). Parsed
      // quote-aware CLIENT-side (_tsvParse) so an Excel cell holding a newline
      // (a double-quoted field) stays ONE cell instead of shattering into
      // phantom rows, then pushed as a structured {rows:[[…]]} grid. Over the
      // cell cap we push a notice instead of the payload — never ship the frame.
      this._onPaste = (e) => {
        if (e.target.matches && e.target.matches("input, textarea")) return;
        const text = e.clipboardData && e.clipboardData.getData("text/plain");
        if (!text) return;
        e.preventDefault();
        const rows = this._tsvParse(text);
        let cells = 0;
        for (let i = 0; i < rows.length; i++) cells += rows[i].length;
        if (cells > this._pasteCellCap) {
          this.pushEventTo(this.el, "paste-too-large", { cells: cells });
          return;
        }
        this.pushEventTo(this.el, "paste", { rows: rows });
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
        // Any typed character LOCKS the volatile hot ref + ends the point
        // session (Decision 4): the just-pointed reference becomes ordinary
        // formula text the user is steering by hand.
        this._hot = null;
        this._pointSession = false;
        this._pointBase = null;
        this._phantom = null;
        this._fnUpdate(inp);
        this._ghostUpdate(inp);
        this._paintRainbow(inp);
        this._sigRender(inp);
      };

      // keydown + input bind on root (the bar is a sibling of this.el); the
      // rest stay on this.el (they act on grid cells inside the hook element).
      this.root.addEventListener("keydown", this._onKeydown);
      this.root.addEventListener("input", this._onInput);
      this.root.addEventListener("mousedown", this._onToolbarMousedown);
      this.el.addEventListener("click", this._onClick);
      this.el.addEventListener("dblclick", this._onDblclick);
      this.el.addEventListener("copy", this._onCopy);
      this.el.addEventListener("paste", this._onPaste);
      this.el.addEventListener("mousedown", this._onMousedown);
      this.el.addEventListener("mousedown", this._onCellMousedown);
      this.el.addEventListener("mousedown", this._onHeadMousedown);
      this.el.addEventListener("mousedown", this._onFillMousedown);

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
      // Ctrl+F just opened the find bar — focus + select its input once it has
      // rendered (mirrors the _refocus one-shot pattern below).
      if (this._focusFind) {
        const f = this.root && this.root.querySelector(".sheet-find-input");
        if (f) {
          f.focus();
          try { f.select(); } catch (_e) { /* noop */ }
          this._focusFind = false;
        }
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
        this.root.removeEventListener("mousedown", this._onToolbarMousedown);
      }
      if (this._menuEl && this._menuEl.remove) this._menuEl.remove();
      // Client-injected formula-UX chrome outlives morphdom on the ancestor
      // overlay nodes — remove by hand so a hook remount does not leak them.
      var chrome = ["_refLayerEl", "_barMirrorEl", "_sigEl", "_ghostEl", "_modeChipEl", "_srEl"];
      for (var i = 0; i < chrome.length; i++) {
        var n = this[chrome[i]];
        if (n && n.remove) n.remove();
        this[chrome[i]] = null;
      }
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

    // Dropdown v2 (Decision 9): the kernel's fuzzy matcher — prefix hits first
    // (vocabulary order preserved), then substring hits, capped at 8. Falls back
    // to a prefix scan if the pointing kernel is somehow absent (fail-safe).
    _fnMatches(token) {
      if (!token) return [];
      if (this._P && this._P.fuzzyFns) return this._P.fuzzyFns(token, this._fns);
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
      // Completing to "NAME(" drops the caret in an empty first arg — the exact
      // seat the ghost predictor + signature strip want (the Vision: Tab to
      // =SUM( and a B3:B5 ghost appears alongside the signature help).
      this._ghostUpdate(inp);
      this._sigRender(inp);
      this._paintRainbow(inp);
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
      if (!this._dom() || !this.scrollEl) return;
      if (!this._menuEl) {
        this._menuEl = document.createElement("div");
        this._menuEl.id = "sheet-fn-menu";
        // S4 popover family (Decision 9), not the ad-hoc v1 .sheet-fn-menu.
        this._menuEl.className = "sheet-popover sheet-popover--fns";
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
        opt.className = "sheet-popover-fn";
        opt.setAttribute("role", "option");
        opt.setAttribute("aria-selected", i === this._fn.idx ? "true" : "false");
        const nm = document.createElement("span");
        nm.className = "sheet-popover-fn-name";
        nm.textContent = name;
        opt.appendChild(nm);
        // The one-line doc from data-fn-sigs (Decision 9): a NAME-keyed lookup,
        // parsed once at mount. Kernels return no spec for LOG10-class names —
        // degrade to just the name, silently (S6c owns the fix, add no workaround).
        const spec = this._fnSigs[name];
        if (spec && spec.doc) {
          const doc = document.createElement("span");
          doc.className = "sheet-popover-doc";
          doc.textContent = spec.doc;
          opt.appendChild(doc);
        }
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

    // ── formula point-mode + intellisense wiring (S6+S7) ────────────────────
    //
    // Every grammar decision below routes through the two pure kernels; this
    // half is DOM wiring only. `_F` = window.BarkparkSheetFormula (tokenize /
    // caretContext / insertRef / extendRef / cycleDollar / refColorIndex /
    // normalizeFormula), `_P` = window.BarkparkSheetPointing (refToPos /
    // rangeText / colRefText / rowRefText / phantomStep / predictRange /
    // shouldOfferGhost / fuzzyFns / ghostReduce). If either is missing the
    // hook degrades to its pre-wave behaviour (fail-safe).

    // True only in a real browser with a live DOM — the node harness fakes just
    // `window`/`document`/`setTimeout`, so every pixel-painting method bails on
    // this and the harness pins the pure routing/commit logic instead.
    _dom() { return typeof document !== "undefined" && !!document.createElement; },

    // Commit-time canonicalization (Decision 11) — uppercase known fns + refs
    // and balance trailing parens; non-formulas returned verbatim.
    _normalize(value) {
      return this._F ? this._F.normalizeFormula(value, this._fns) : value;
    },

    _caretOf(el) {
      return el && el.selectionStart != null ? el.selectionStart : (el ? String(el.value).length : 0);
    },

    // The caret-context classifier over the given editor (Decision 4 + A1).
    _ctx(el) {
      return this._F.caretContext(el.value, this._caretOf(el), this._hot);
    },

    // The formula editor a point gesture should write into: an open cell editor
    // wins; else a FOCUSED, DIRTY formula bar (its own edit in progress). A
    // pristine or unfocused bar is not an active edit — clicks there commit/nav.
    _formulaEditor() {
      const inp = this.el.querySelector(".sheet-cell-input");
      if (inp) return inp;
      const bar = this.root && this.root.querySelector(".sheet-bar-input");
      if (bar && typeof document !== "undefined" && document.activeElement === bar &&
          bar.dataset && bar.value !== bar.dataset.raw) {
        return bar;
      }
      return null;
    },

    // The active cell as a {c,r} pos (phantomStep's opts.active seed), or null.
    _activePos() {
      const a = this.el.querySelector("td.sheet-active");
      if (!a || !a.dataset || a.dataset.ref == null) return null;
      return this._P ? this._P.refToPos(a.dataset.ref) : null;
    },

    // A getCell(c,r) closure over the RENDERED window (server-stamped data-t is
    // the numeric truth — Decision 8, never parse display strings). Cells beyond
    // the window read as null (empty), which is the honest windowing cap.
    _getCell() {
      const el = this.el;
      return function (c, r) {
        if (!el.querySelector) return null;
        var cell = el.querySelector('td[data-c="' + c + '"][data-r="' + r + '"]');
        if (!cell) return null;
        var t = cell.dataset ? cell.dataset.t : null;
        return { t: t == null ? null : t };
      };
    },

    // Grid bounds for phantom clamping. No server attr is stamped for the totals
    // (Decision 1: prefer client-owned), so fall back to Excel's max extent — the
    // phantom edge-walk stops at the last rendered filled cell anyway.
    _bounds() {
      var d = this.el.dataset || {};
      var cols = parseInt(d.colsTotal, 10);
      var rows = parseInt(d.rowsTotal, 10);
      return { cols: cols > 0 ? cols : 16384, rows: rows > 0 ? rows : 1048576 };
    },

    // Snapshot the pre-point value/caret ONCE per session so the Escape ladder
    // can revert a pending point session (Decision 12).
    _startPoint(el) {
      if (!this._pointSession) {
        this._pointSession = true;
        this._pointBase = { value: el.value, caret: this._caretOf(el) };
      }
    },

    // Escape stage 2: revert the pending point session to its pre-point text and
    // clear all volatile state (self-heals to a normal edit).
    _endPointSession(el) {
      if (this._pointBase) {
        el.value = this._pointBase.value;
        try { el.setSelectionRange(this._pointBase.caret, this._pointBase.caret); } catch (_e) { /* noop */ }
      }
      this._pointSession = false;
      this._pointBase = null;
      this._hot = null;
      this._phantom = null;
      this._afterPointChange(el);
    },

    // Insert/replace a reference at the caret (kernel decides insert-vs-replace
    // from the hotSpan) and track the returned span as the new volatile hot ref.
    _pointInsertRef(el, refText) {
      var r = this._F.insertRef(el.value, this._caretOf(el), refText, this._hot);
      el.value = r.value;
      try { el.setSelectionRange(r.caret, r.caret); } catch (_e) { /* noop */ }
      this._hot = r.span;
      this._afterPointChange(el);
    },

    // Drag-extend the hot ref to a new end cell (kernel normalizes top-left:
    // bottom-right + keeps each side's $), tracking the grown span.
    _pointExtendRef(el, endRef) {
      if (!this._hot) return;
      var r = this._F.extendRef(el.value, this._hot, endRef);
      el.value = r.value;
      try { el.setSelectionRange(r.caret, r.caret); } catch (_e) { /* noop */ }
      this._hot = r.span;
      this._afterPointChange(el);
    },

    // Overwrite the hot span with a fully-formed ref (whole-col/row header drag).
    _pointReplaceHot(el, refText) {
      if (!this._hot) return this._pointInsertRef(el, refText);
      var r = this._F.insertRef(el.value, this._hot.end, refText, this._hot);
      el.value = r.value;
      try { el.setSelectionRange(r.caret, r.caret); } catch (_e) { /* noop */ }
      this._hot = r.span;
      this._afterPointChange(el);
    },

    // After any point/phantom write: mirror the cell editor into the bar, repaint
    // the rainbow, refresh the signature strip, announce the insert.
    _afterPointChange(el) {
      var bar = this.root && this.root.querySelector(".sheet-bar-input");
      if (bar && el !== bar && (typeof document === "undefined" || document.activeElement !== bar)) {
        bar.value = el.value;
      }
      this._paintRainbow(el);
      this._sigRender(el);
      this._announceHot();
    },

    // Cell-click point routing — returns true if it POINTED (caller stops), false
    // to fall through to the byte-identical commit path. Decision 4 + Amendment A1.
    _pointCellMousedown(e, td) {
      if (this._readOnly || !this._F || !this._P) return false;
      var ed = this._formulaEditor();
      if (!ed) return false;
      var ctx = this._ctx(ed);
      if (ctx.action !== "point-insert" && ctx.action !== "point-replace") return false;
      var pos = this._P.refToPos(td.dataset.ref);
      if (!pos) return false;
      e.preventDefault(); // focus never leaves the editor
      this._tabExits = false;
      this._suppressClick = true;
      this._startPoint(ed);
      this._ghostDismiss(ed);
      this._pointInsertRef(ed, this._P.rangeText(pos, pos));
      var self = this;
      var lastRef = td.dataset.ref;
      var onOver = function (ev) {
        var t = ev.target.closest && ev.target.closest("td[data-ref]");
        if (!t || t.dataset.ref === lastRef) return;
        var hp = self._P.refToPos(t.dataset.ref);
        if (!hp) return;
        lastRef = t.dataset.ref;
        self._pointExtendRef(ed, t.dataset.ref);
      };
      var onUp = function () {
        self.el.removeEventListener("mouseover", onOver);
        window.removeEventListener("mouseup", onUp);
      };
      this.el.addEventListener("mouseover", onOver);
      window.addEventListener("mouseup", onUp);
      return true;
    },

    // Header-click point routing — inserts a whole-column (B:B) / whole-row (3:3)
    // ref and drag-extends it. Returns true if it POINTED.
    _pointHeadMousedown(e, th) {
      if (this._readOnly || !this._F || !this._P) return false;
      var ed = this._formulaEditor();
      if (!ed) return false;
      var ctx = this._ctx(ed);
      if (ctx.action !== "point-insert" && ctx.action !== "point-replace") return false;
      var kind = th.dataset.c != null ? "col" : "row";
      var anchorIdx = parseInt(kind === "col" ? th.dataset.c : th.dataset.r, 10);
      if (!(anchorIdx >= 1)) return false;
      e.preventDefault();
      this._tabExits = false;
      this._suppressClick = true;
      this._startPoint(ed);
      this._ghostDismiss(ed);
      var refText = kind === "col" ? this._P.colRefText(anchorIdx, anchorIdx) : this._P.rowRefText(anchorIdx, anchorIdx);
      this._pointInsertRef(ed, refText);
      var self = this;
      var lastIdx = anchorIdx;
      var onOver = function (ev) {
        var t = ev.target.closest && ev.target.closest("th.sheet-colhead, th.sheet-rowhead");
        if (!t) return;
        if ((t.dataset.c != null ? "col" : "row") !== kind) return; // same-kind guard
        var idx = parseInt(kind === "col" ? t.dataset.c : t.dataset.r, 10);
        if (idx === lastIdx) return;
        lastIdx = idx;
        var rt = kind === "col" ? self._P.colRefText(anchorIdx, idx) : self._P.rowRefText(anchorIdx, idx);
        self._pointReplaceHot(ed, rt);
      };
      var onUp = function () {
        self.el.removeEventListener("mouseover", onOver);
        window.removeEventListener("mouseup", onUp);
      };
      this.el.addEventListener("mouseover", onOver);
      window.addEventListener("mouseup", onUp);
      return true;
    },

    // Enter/Tab commit from the cell editor: ghost accept-and-commit in ONE
    // keystroke if the ghost is showing (dropdown-navigated completion, higher
    // precedence, already returned before this is reached), else a plain commit.
    // The pushed value is canonicalized (Decision 11); server write paths untouched.
    _commitEditor(inp, move) {
      this._refocus = true;
      var value = inp.value;
      if (this._ghost && this._ghost.offered) {
        value = this._acceptGhostValue(inp, this._ghost.offered);
        this._ghost = { offered: null };
      }
      this._fnClose(inp);
      this._endChrome();
      this.pushEventTo(this.el, "edit-commit", { value: this._normalize(value), move: move });
    },

    // ── ghost range predictor (render-only, never steals a keystroke) ────────

    // Is the argument the caret sits in empty? (text after the enclosing '(' or
    // ',' up to the caret is blank). Powers shouldOfferGhost's argEmpty flag.
    _currentArgEmpty(value, caret) {
      var head = String(value).slice(0, caret);
      var i = Math.max(head.lastIndexOf("("), head.lastIndexOf(","));
      if (i < 0) return false;
      return head.slice(i + 1).trim() === "";
    },

    // Recompute the ghost from the editor's value+caret+active cell. Offers a
    // predicted range only for a whitelisted aggregate's empty first arg
    // (Decision 7). Render-only — NEVER written into input.value.
    _ghostUpdate(inp) {
      this._ghost = this._P ? this._P.ghostReduce(this._ghost, { type: "dismiss" }) : { offered: null };
      // Read-only sheets never enter point-mode — the ghost is a point entry
      // (Enter accepts-and-commits it), so fail closed: never offer (Decision 12).
      if (this._readOnly || !this._F || !this._P) return void this._ghostRender(inp);
      var caret = this._caretOf(inp);
      var ctx = this._F.caretContext(inp.value, caret, this._hot);
      var argEmpty = this._currentArgEmpty(inp.value, caret);
      if (!this._P.shouldOfferGhost(ctx.fnName, ctx.argIndex, argEmpty)) return void this._ghostRender(inp);
      var active = this._activePos();
      if (!active) return void this._ghostRender(inp);
      var pred = this._P.predictRange(this._getCell(), active);
      if (!pred) return void this._ghostRender(inp);
      this._ghost = this._P.ghostReduce(this._ghost, { type: "offer", text: pred });
      this._ghostRender(inp);
    },

    // Splice the accepted ghost text in at the caret (a point-insert) and return
    // the new value — the caller commits it. The ghost only ever reaches
    // input.value HERE, on an explicit accept.
    _acceptGhostValue(inp, ghostText) {
      var r = this._F.insertRef(inp.value, this._caretOf(inp), ghostText, this._hot);
      return r.value;
    },

    // Any printable key / click / arrow silently dismisses the offer (ghostReduce
    // is the law) — the keystroke still does its normal thing.
    _ghostDismiss(inp) {
      this._ghost = this._P ? this._P.ghostReduce(this._ghost, { type: "dismiss" }) : { offered: null };
      this._ghostRender(inp);
    },

    // Paint the ghost text after the caret (browser-only; the harness bails).
    _ghostRender(inp) {
      if (!this._dom() || !this.scrollEl) return;
      var text = this._ghost && this._ghost.offered;
      if (!text) {
        if (this._ghostEl && this._ghostEl.remove) this._ghostEl.remove();
        this._ghostEl = null;
        return;
      }
      if (!this._ghostEl) {
        this._ghostEl = document.createElement("span");
        this._ghostEl.className = "sheet-ghost";
        this._ghostEl.setAttribute("aria-hidden", "true");
        this.scrollEl.appendChild(this._ghostEl);
      }
      this._ghostEl.textContent = text;
      var td = inp && inp.closest ? inp.closest("td") : null;
      if (td) {
        this._ghostEl.style.position = "absolute";
        this._ghostEl.style.left = td.offsetLeft + "px";
        this._ghostEl.style.top = td.offsetTop + "px";
      }
    },

    // ── rainbow ref outlines + colored formula-bar mirror (Decision 6) ───────

    // Repaint the .sheet-ref-layer outline boxes + rebuild the colored bar mirror
    // from refColorIndex(value). Index classes only (.sheet-refc-N) — never hex.
    // Browser-only geometry; the harness bails after the pure index computation.
    _paintRainbow(el) {
      if (!this._F) return;
      var colors = this._F.refColorIndex(el.value); // pure: {NORMREF: slot}
      this._buildBarMirror(el, colors);
      if (!this._dom() || !this.scrollEl) return;
      if (!this._refLayerEl) {
        this._refLayerEl = document.createElement("div");
        this._refLayerEl.className = "sheet-ref-layer";
        this._refLayerEl.setAttribute("aria-hidden", "true");
        this.scrollEl.appendChild(this._refLayerEl);
      }
      this._refLayerEl.innerHTML = "";
      if (!this._P) return;
      var toks = this._F.tokenize(el.value);
      var hot = this._hot;
      for (var i = 0; i < toks.length; i++) {
        var t = toks[i];
        if (t.type !== "ref") continue;
        var box = this._refBoxFor(t.text, colors);
        if (!box) continue;
        if (hot && t.start === hot.start && t.end === hot.end) box.className += " sheet-refbox--active";
        this._refLayerEl.appendChild(box);
      }
    },

    // One absolutely-positioned outline rect for a ref, hued by its color slot.
    // Spans the bounding box of its first→last rendered cell; refs off the
    // window contribute no box (honest windowing).
    _refBoxFor(refText, colors) {
      if (!this._dom() || !this._P) return null;
      var norm = String(refText).toUpperCase();
      var parts = norm.split(":");
      var a = this._P.refToPos(parts[0]);
      var b = this._P.refToPos(parts[parts.length - 1]);
      if (!a || !b) return null; // whole-col/row refs have no single-cell box in v1
      var slot = this._refSlot(refText, colors);
      var c1 = Math.min(a.c, b.c), c2 = Math.max(a.c, b.c);
      var r1 = Math.min(a.r, b.r), r2 = Math.max(a.r, b.r);
      var tl = this.el.querySelector('td[data-c="' + c1 + '"][data-r="' + r1 + '"]');
      var br = this.el.querySelector('td[data-c="' + c2 + '"][data-r="' + r2 + '"]');
      if (!tl || !br) return null;
      var box = document.createElement("div");
      box.className = "sheet-refbox sheet-refc-" + slot;
      box.style.position = "absolute";
      box.style.left = tl.offsetLeft + "px";
      box.style.top = tl.offsetTop + "px";
      box.style.width = (br.offsetLeft + br.offsetWidth - tl.offsetLeft) + "px";
      box.style.height = (br.offsetTop + br.offsetHeight - tl.offsetTop) + "px";
      return box;
    },

    _refSlot(refText, colors) {
      var norm = this._normRefKey(refText);
      return norm in colors ? colors[norm] : 0;
    },

    // refColorIndex keys are normalized (uppercased, range-reordered) — match it.
    _normRefKey(refText) {
      var up = String(refText).toUpperCase();
      var parts = up.split(":");
      if (parts.length === 2 && this._P) {
        var a = this._P.refToPos(parts[0]);
        var b = this._P.refToPos(parts[1]);
        if (a && b) {
          return this._P.rangeText({ c: a.c, r: a.r }, { c: b.c, r: b.r }).toUpperCase();
        }
      }
      return up;
    },

    // The colored bar mirror: a positioned overlay over the formula bar whose ref
    // tokens wear the SAME .sheet-refc-N hue as their outlines. Never a
    // contenteditable rewrite (explicit non-goal) — a read-only mirror element.
    _buildBarMirror(el, colors) {
      if (!this._dom()) return;
      var bar = this.root && this.root.querySelector(".sheet-bar-input");
      if (!bar || !bar.parentNode) return;
      // Mirror the CELL editor's value when it drives; else the bar's own text.
      var value = el && el.value != null ? el.value : bar.value;
      if (!this._barMirrorEl) {
        this._barMirrorEl = document.createElement("div");
        this._barMirrorEl.className = "sheet-bar-mirror";
        this._barMirrorEl.setAttribute("aria-hidden", "true");
        bar.parentNode.appendChild(this._barMirrorEl);
      }
      this._barMirrorEl.innerHTML = "";
      var toks = this._F.tokenize(value);
      for (var i = 0; i < toks.length; i++) {
        var t = toks[i];
        var node;
        if (t.type === "ref") {
          node = document.createElement("span");
          node.className = "sheet-refc-" + this._refSlot(t.text, colors);
          node.textContent = t.text;
        } else {
          node = document.createTextNode(t.text);
        }
        this._barMirrorEl.appendChild(node);
      }
    },

    // ── signature strip (Decision 9) ─────────────────────────────────────────

    // Show NAME(arg1, [arg2, …]) with the caret's current argument emphasized.
    // Kernels return fnName=null for LOG10-class names — degrade silently.
    _sigRender(el) {
      if (!this._dom() || !this.scrollEl) return;
      var doClear = function (self) {
        if (self._sigEl && self._sigEl.remove) self._sigEl.remove();
        self._sigEl = null;
      };
      if (!this._F) return doClear(this);
      var caret = this._caretOf(el);
      var ctx = this._F.caretContext(el.value, caret, this._hot);
      var name = ctx.fnName && ctx.fnName.toUpperCase();
      var spec = name && this._fnSigs[name];
      if (!spec) return doClear(this);
      if (!this._sigEl) {
        this._sigEl = document.createElement("div");
        this._sigEl.className = "sheet-popover sheet-popover--sig";
        this._sigEl.setAttribute("aria-hidden", "true");
        this.scrollEl.appendChild(this._sigEl);
      }
      this._sigEl.innerHTML = "";
      var fn = document.createElement("span");
      fn.className = "sheet-sig-fn";
      fn.textContent = name + "(";
      this._sigEl.appendChild(fn);
      var args = spec.args || [];
      for (var i = 0; i < args.length; i++) {
        if (i > 0) this._sigEl.appendChild(document.createTextNode(", "));
        var arg = document.createElement("span");
        var current = i === ctx.argIndex || (i === args.length - 1 && args[i].variadic && ctx.argIndex >= i);
        arg.className = "sheet-sig-arg" + (current ? " sheet-sig-arg--current" : "");
        var label = args[i].name + (args[i].variadic ? ", …" : "");
        arg.textContent = args[i].optional ? "[" + label + "]" : label;
        this._sigEl.appendChild(arg);
      }
      this._sigEl.appendChild(document.createTextNode(")"));
    },

    // ── mode chip + SR announcements (Decision 12) ───────────────────────────

    // POINT/EDIT chip in the .sheet-statsbar region, reflecting _editMode.
    _updateModeChip() {
      if (!this._dom()) return;
      var host = this.root && this.root.querySelector(".sheet-statsbar");
      if (!host) return;
      if (!this._modeChipEl) {
        this._modeChipEl = document.createElement("span");
        this._modeChipEl.className = "sheet-mode-chip";
        host.insertBefore(this._modeChipEl, host.firstChild);
      }
      var pointing = this._editMode !== "edit";
      this._modeChipEl.className = "sheet-mode-chip" + (pointing ? " sheet-mode-chip--point" : "");
      this._modeChipEl.textContent = pointing ? "Point" : "Edit";
    },

    // "B3 to B5 inserted" into an aria-live=polite region (SR only).
    _announceHot() {
      if (!this._dom() || !this._hot || !this._F) return;
      var text = String(this._formulaEditor() ? this._formulaEditor().value : "").slice(this._hot.start, this._hot.end);
      if (!text) return;
      var parts = text.split(":");
      var msg = parts.length === 2 ? parts[0] + " to " + parts[1] + " inserted" : text + " inserted";
      this._announce(msg);
    },

    _announce(msg) {
      if (!this._dom()) return;
      if (!this._srEl) {
        this._srEl = document.createElement("div");
        this._srEl.className = "sheet-sr-status sr-only";
        this._srEl.setAttribute("aria-live", "polite");
        this._srEl.setAttribute("role", "status");
        (this.root || this.el).appendChild(this._srEl);
      }
      this._srEl.textContent = msg;
    },

    // Tear down transient formula chrome (ghost/signature/mirror/ref boxes) on
    // commit/cancel; the mode chip + SR region persist for the next edit.
    _endChrome() {
      this._ghost = { offered: null };
      this._hot = null;
      this._phantom = null;
      this._pointSession = false;
      this._pointBase = null;
      // A fresh cell edit always begins in Enter-mode (Decision 5) — an F2
      // Edit-mode toggle must not leak into the next edit.
      this._editMode = "enter";
      var kill = ["_ghostEl", "_sigEl", "_barMirrorEl"];
      for (var i = 0; i < kill.length; i++) {
        var n = this[kill[i]];
        if (n && n.remove) n.remove();
        this[kill[i]] = null;
      }
      if (this._refLayerEl) this._refLayerEl.innerHTML = "";
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
    // cell included) -> TSV, row-major, computed values from data-v. Serialized
    // quote-aware (_tsvEncode) so a cell whose value contains a tab or newline
    // stays ONE field Excel/Sheets parses back intact, not corrupt TSV.
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
      const grid = rKeys.map((r) => {
        const cols = rows.get(r);
        const cKeys = Array.from(cols.keys()).sort((a, b) => a - b);
        return cKeys.map((c) => cols.get(c));
      });
      return this._tsvEncode(grid);
    },

    // ── quote-aware TSV (RFC-4180-ish, tab-delimited) ─────────────────────────
    // Pure helpers, driven directly by the node harness. Excel/Sheets quote any
    // field containing a tab, newline, or double-quote and double the inner
    // quotes; a naive split on \n/\t shatters such a cell across rows/columns.
    // These are the round-trip twins: _tsvParse(_tsvEncode(x)) deep-equals x.

    _tsvEncode(rows) {
      return rows
        .map((cols) =>
          cols
            .map((v) => {
              const s = v == null ? "" : String(v);
              return /[\t\n\r"]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
            })
            .join("\t")
        )
        .join("\n");
    },

    _tsvParse(text) {
      const rows = [];
      let row = [];
      let field = "";
      let quoted = false; // inside a quoted field
      const n = text.length;
      let i = 0;
      while (i < n) {
        const ch = text[i];
        if (quoted) {
          if (ch === '"') {
            if (text[i + 1] === '"') {
              field += '"';
              i += 2;
              continue;
            }
            quoted = false;
            i++;
            continue;
          }
          field += ch;
          i++;
          continue;
        }
        // A double-quote only opens a quoted field at the field's start; a bare
        // quote mid-field is a literal (Excel never emits that, but stay safe).
        if (ch === '"' && field === "") {
          quoted = true;
          i++;
          continue;
        }
        if (ch === "\t") {
          row.push(field);
          field = "";
          i++;
          continue;
        }
        if (ch === "\r" || ch === "\n") {
          row.push(field);
          field = "";
          rows.push(row);
          row = [];
          i += ch === "\r" && text[i + 1] === "\n" ? 2 : 1;
          continue;
        }
        field += ch;
        i++;
      }
      row.push(field);
      rows.push(row);
      // Drop a trailing empty single-cell row from Excel/Sheets' terminal
      // newline (a genuine one-empty-cell paste is length-1 but the ONLY row).
      const last = rows[rows.length - 1];
      if (rows.length > 1 && last.length === 1 && last[0] === "") rows.pop();
      return rows;
    }
  };
})();
