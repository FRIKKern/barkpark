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

  // ── READ-MODE ALLOWLIST (wave 43) ─────────────────────────────────────────
  //
  // This hook is now attached for EVERY Studio grid — the wrapper's phx-hook
  // keys on `chrome == :studio`, not on `@editable` — because it is the SOLE
  // PRODUCER of selection: cell-click / head-click / nav / nav-edge /
  // nav-corner / select-all have no server-rendered phx-click anywhere. Without
  // it a write-denied member (and a write-CAPABLE member in View mode: @editable
  // is `mode == :edit and write_capable`) saw a selection highlight frozen on A1
  // that nothing could move — and the clipboard copy, which reads td.sheet-sel,
  // is downstream of that.
  //
  // Such a grid stamps no `data-fns`, so the hook self-derives `this._readOnly`
  // (see mounted()) and every push routes through `_push`, which drops any event
  // outside this set.
  //
  // THIS MAP IS UX AND HONESTY, NOT THE SECURITY BOUNDARY. Every mutation event
  // terminates at `Ops.send_ops/2`, whose `write_capable: false` clause is the
  // last wall and drops them server-side regardless of what a forged client
  // sends. The map exists so a read-mode client never ASKS for a write it cannot
  // have, and — the one case with real user-visible teeth — so `edit-start`, the
  // ONE denied event with no send_ops terminus, can never broadcast "editing A1"
  // to every peer while no editor renders.
  const READ_MODE_EVENTS = [
    "cell-click", "head-click", "nav", "nav-edge", "nav-corner",
    "select-all", "find-open", "find-close", "menu-close", "presence-meta"
  ];

  // Payload keys that ride an ALLOWED event but carry a WRITE: the #813/#858
  // click-away commit ride (`commit` = the open cell draft, `bar_commit` = the
  // dirty formula bar). Stripped in read mode — the selection move survives, the
  // commit does not.
  const WRITE_RIDE_KEYS = ["commit", "bar_commit"];

  // ── SHARED CLIPBOARD KERNEL (hoisted, wave 43 reader half) ────────────────
  //
  // These two were methods on the Studio hook. They are module-scope functions
  // now so the Studio hook AND the public reader's client-only selection layer
  // (window.BarkparkSheetReaderSelect, at the bottom of this file) encode the OS
  // clipboard through ONE implementation — a fork would let the two grids drift
  // apart on the Excel/Sheets quoting rule. Both objects still expose
  // `_tsvEncode`, delegating here; the harness pins are unchanged.

  // Quote-aware TSV (RFC-4180-ish, tab-delimited). Excel/Sheets quote any field
  // containing a tab, newline, or double-quote and double the inner quotes; a
  // naive split on \n/\t shatters such a cell across rows/columns. This is the
  // round-trip twin of the hook's _tsvParse: _tsvParse(tsvEncode(x)) === x.
  function tsvEncode(rows) {
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
  }

  // Row-major grid of the SELECTED <td>s, walked ascending row then column —
  // the shape tsvEncode consumes. Reads `data-v` (the computed raw value the
  // server stamps on every td, the reader's included) and falls back to the
  // rendered text. Class-agnostic on purpose: Studio hands it `td.sheet-sel`,
  // the reader hands it its own `td.sheet-rsel`.
  function selectionGrid(tds) {
    const rows = new Map();
    Array.prototype.forEach.call(tds, (td) => {
      const r = parseInt(td.dataset.r, 10);
      const c = parseInt(td.dataset.c, 10);
      if (!rows.has(r)) rows.set(r, new Map());
      rows.get(r).set(c, td.dataset.v != null ? td.dataset.v : td.textContent.trim());
    });
    const rKeys = Array.from(rows.keys()).sort((a, b) => a - b);
    return rKeys.map((r) => {
      const cols = rows.get(r);
      const cKeys = Array.from(cols.keys()).sort((a, b) => a - b);
      return cKeys.map((c) => cols.get(c));
    });
  }

  window.BarkparkSheetGrid = {
    mounted() {
      this.scrollEl = this.el.querySelector(".sheet-scroll");
      this._refocus = false;
      // Paste preflight bound (mirrors the server cap); overridable in tests.
      this._pasteCellCap = PASTE_CELL_CAP;
      // Formula clipboard (QL-D5): {sig, origin:{col,row}, formulas:[[…]]} set by
      // _onCopy; a same-signature paste rebases these instead of pasting values.
      this._formulaClip = null;
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
            this._push("bar-commit", {
              value: this._normalize(bar.value),
              move: e.shiftKey ? "left" : "right",
            });
            // The bar edit ends here — a bar POINT session's volatile state
            // (hot span offsets into the bar's text, ghost, phantom) must die
            // with it, or the hot rule replaces arbitrary text in the NEXT
            // editor whose caret lands on the stale span's end offset.
            this._endChrome();
            return;
          }
          if (e.key === "Escape") {
            e.preventDefault();
            bar.value = bar.dataset.raw != null ? bar.dataset.raw : "";
            this.el.focus({ preventScroll: true });
            // Escape ends the bar edit WITHOUT a server round-trip (nothing is
            // pushed, so no patch will ever clean up) — drop the volatile
            // point/ghost state by hand, same as the Tab commit above.
            this._endChrome();
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
            this._push("find-close", {});
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
              this._push("edit-cancel", {});
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
          this._push("find-open", {});
          return;
        }

        // Per-user undo/redo (M4): Cmd/Ctrl+Z undoes THIS user's last op,
        // Cmd/Ctrl+Shift+Z redoes it. The server pops the per-user inverse
        // stack and the resulting delta re-renders every client.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && (e.key === "z" || e.key === "Z")) {
          e.preventDefault();
          this._push(e.shiftKey ? "redo" : "undo", {});
          return;
        }

        // Bold / italic (Cmd/Ctrl+B / Cmd/Ctrl+I): the server reads the ACTIVE
        // cell's style, inverts b/i, and stamps the result across the selection
        // (Excel toggle). v1 GRID-NAV mode only — an open cell editor returned
        // early above, so native bold/italic in the editor is untouched.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && (e.key === "b" || e.key === "B" || e.key === "i" || e.key === "I")) {
          e.preventDefault();
          this._push("toggle-style", { k: (e.key === "b" || e.key === "B") ? "b" : "i" });
          return;
        }

        // Fill down/right (Cmd/Ctrl+D / Cmd/Ctrl+R): the selection's first
        // row/column seeds every other cell in the rect, with a per-step
        // formula rebase server-side.
        if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && (e.key === "d" || e.key === "r")) {
          e.preventDefault();
          this._push("fill", { dir: e.key === "d" ? "down" : "right" });
          return;
        }

        // Select all (Cmd/Ctrl+A): the server selects the whole USED range —
        // without this branch the keydown fell through to the browser and
        // selected the page text around the grid. v1: one Ctrl+A = used range
        // (Excel's second press → whole sheet is deferred).
        if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && (e.key === "a" || e.key === "A")) {
          e.preventDefault();
          this._push("select-all", {});
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
          this._push("head-click", {
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
            this._push("rowcol-key", {
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
            this._push("nav-edge", { dir: dir, shift: e.shiftKey });
            return;
          }
          if (e.key === "Home" || e.key === "End") {
            e.preventDefault();
            this._push("nav-corner", { corner: e.key.toLowerCase(), shift: e.shiftKey });
            return;
          }
        }

        if (NAV_KEYS.indexOf(e.key) >= 0) {
          e.preventDefault();
          this._push("nav", { key: e.key, shift: e.shiftKey });
        } else if (e.key === "Tab") {
          // Tab/Shift+Tab walk the selection within the grid (Excel muscle
          // memory) rather than tabbing focus out — the nav handler clamps.
          e.preventDefault();
          this._push("nav", { key: e.shiftKey ? "ArrowLeft" : "ArrowRight", shift: false });
        } else if (e.key === "Enter" || e.key === "F2") {
          e.preventDefault();
          this._push("edit-start", {});
        } else if (e.key === "Delete" || e.key === "Backspace") {
          e.preventDefault();
          this._push("clear-selection", {});
        } else if (e.key === " ") {
          // Space toggles a checkbox-fmt active cell (the td carries the
          // "sheet-checkbox" class); on any other cell it seeds an edit with a
          // literal space, the prior behaviour.
          e.preventDefault();
          const active = this.el.querySelector("td.sheet-active");
          if (active && active.classList.contains("sheet-checkbox")) {
            this._push("cell-toggle", { ref: active.dataset.ref });
          } else {
            this._push("edit-start", { seed: " " });
          }
        } else if (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
          // Typing replaces the cell content — the seed becomes the prefill.
          e.preventDefault();
          this._push("edit-start", { seed: e.key });
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
        this._push("cell-click", { ref: ref, shift: false, commit: draft.value });
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
          this._push("head-click", this._rideCommits({
            kind: th.dataset.c != null ? "col" : "row",
            index: parseInt(th.dataset.c != null ? th.dataset.c : th.dataset.r, 10),
            shift: e.shiftKey,
          }));
          return;
        }
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        this.el.focus({ preventScroll: true });
        this._push("cell-click", { ref: td.dataset.ref, shift: e.shiftKey });
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
        this._push("cell-click", payload);
        let last = td.dataset.ref;
        const onOver = (ev) => {
          const t = ev.target.closest && ev.target.closest("td[data-ref]");
          if (!t || t.dataset.ref === last) return;
          last = t.dataset.ref;
          this._push("cell-click", { ref: t.dataset.ref, shift: true });
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
        this._push("head-click", this._rideCommits({
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
          this._push("head-click", { kind: kind, index: idx, shift: true });
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
          if (last) this._push("fill-range", { to: last });
        };
        this.el.addEventListener("mouseover", onOver);
        window.addEventListener("mouseup", onUp);
      };

      // Right-click context menu (SF context-menu). Suppresses the native
      // browser menu and opens the SERVER-rendered .sheet-context-menu (the
      // @menu {:cell,x,y} variant) at the cursor. A right-click OUTSIDE the
      // current selection first re-anchors to the clicked cell (Excel parity,
      // riding any open cell draft / dirty bar as a commit via _rideCommits so
      // the #813/#858 no-silent-loss seal holds); a right-click INSIDE a
      // multi-cell selection keeps it so "Copy" grabs the whole block. The menu
      // items reuse the EXACT ops the keyboard path already calls — clear /
      // insert / delete are phx-click server events (clear-selection, rowcol-key),
      // cut / copy / paste ride the OS clipboard client-side (_onCtxClick).
      this._onContextMenu = (e) => {
        if (e.target.matches && e.target.matches("input, textarea, select")) return;
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        e.preventDefault();
        this._tabExits = false;
        this.el.focus({ preventScroll: true });
        const selected = !!(td.classList && td.classList.contains("sheet-sel"));
        if (!selected) {
          this._push("cell-click", this._rideCommits({ ref: td.dataset.ref, shift: false }));
        }
        this._push("cell-menu-open", { x: e.clientX || 0, y: e.clientY || 0 });
        // updated() focuses the first item + viewport-clamps once the server
        // has rendered the menu.
        this._ctxWantFocus = true;
      };

      // Client-side cut/copy/paste from the context menu (the OS clipboard needs
      // an in-gesture call the server round-trip can't give). Reuses the exact
      // clipboard helpers the Cmd+C / Cmd+V path uses; clear / insert / delete
      // are phx-click server events and never reach here. Bound on root (the menu
      // is a sibling of the grid element), filtered to a menu-action button.
      this._onCtxClick = (e) => {
        const btn = e.target.closest && e.target.closest(".sheet-context-menu [data-menu-action]");
        if (!btn) return;
        const action = btn.dataset ? btn.dataset.menuAction : null;
        if (action === "copy" || action === "cut") {
          const tsv = this._selectionTsv();
          if (tsv != null && typeof navigator !== "undefined" && navigator.clipboard) {
            navigator.clipboard.writeText(tsv);
            this._captureFormulaClip(tsv);
          }
          if (action === "cut") this._push("clear-selection", {});
          this._push("menu-close", {});
        } else if (action === "paste") {
          if (typeof navigator !== "undefined" && navigator.clipboard && navigator.clipboard.readText) {
            navigator.clipboard.readText().then((text) => {
              if (text) this._ctxPaste(text);
            }).catch(() => {});
          }
          this._push("menu-close", {});
        }
      };

      // Roving keyboard nav within the open context menu (WCAG menu pattern):
      // Up/Down move focus between menuitems, Home/End jump to the ends, Escape
      // closes the menu (menu-close) and returns focus to the grid. Enter/Space
      // fall through to the button's native activation (phx-click / _onCtxClick).
      // Bound on root; a keydown whose target is not inside the menu returns.
      this._onCtxKeydown = (e) => {
        const menu = e.target.closest && e.target.closest(".sheet-context-menu");
        if (!menu) return;
        const items = menu.querySelectorAll
          ? Array.prototype.slice.call(menu.querySelectorAll("[role='menuitem']"))
          : [];
        const i = items.indexOf(e.target);
        if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          e.preventDefault();
          if (!items.length) return;
          const next = i < 0 ? 0 : (i + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length;
          if (items[next] && items[next].focus) items[next].focus();
        } else if (e.key === "Home" || e.key === "End") {
          e.preventDefault();
          const t = e.key === "Home" ? items[0] : items[items.length - 1];
          if (t && t.focus) t.focus();
        } else if (e.key === "Escape") {
          e.preventDefault();
          this._push("menu-close", {});
          this.el.focus({ preventScroll: true });
        }
      };

      this._onDblclick = (e) => {
        // Fill to the data extent: double-click the fill nub (Excel's idiom).
        // Must branch BEFORE the td lookup — the nub nests inside the corner
        // td, which would otherwise open the editor.
        if (e.target.closest && e.target.closest(".sheet-fillnub")) {
          this._push("fill-extent", {});
          return;
        }
        // Autofit: double-click a header resize handle sizes the col/row to
        // its content. Branched before the td lookup too (the handle lives in
        // a th, so closest("td") is null — the order still documents intent).
        const rsz = e.target.closest && e.target.closest(".sheet-rsz");
        if (rsz) {
          this._push("autofit", {
            kind: rsz.dataset.kind,
            index: parseInt(rsz.dataset.index, 10),
          });
          return;
        }
        const td = e.target.closest && e.target.closest("td[data-ref]");
        if (!td) return;
        this._push("edit-start", {});
      };

      // Cmd/Ctrl+C — selection as TSV of computed values, written
      // synchronously in-gesture via the clipboard event. The OS clipboard
      // always carries the COMPUTED values (Excel/Sheets interop stays intact);
      // alongside it we stash an in-app formula clipboard (QL-D5) keyed by that
      // exact TSV, so a same-app paste can carry the FORMULAS, not their frozen
      // values.
      this._onCopy = (e) => {
        if (e.target.matches && e.target.matches("input, textarea")) return;
        const tsv = this._selectionTsv();
        if (tsv == null) return;
        e.preventDefault();
        e.clipboardData.setData("text/plain", tsv);
        this._captureFormulaClip(tsv);
      };

      // Cmd/Ctrl+V — TSV block applied as batch set_cell ops from the active
      // cell. Two paths share ONE preflight+push tail (so the value path stays
      // byte-identical to pre-feature):
      //   • OUR-OWN-COPY (QL-D5): the clipboard text byte-equals the signature
      //     of our last in-app copy → rebuild the {rows} grid from the copied
      //     FORMULAS, rebased by the paste delta (a no-formula cell falls back to
      //     its TSV value). Formula strings carry a leading '=', which the
      //     server's set_cell/Ops.parse_raw already types as a formula — no
      //     server paste change.
      //   • FOREIGN/anything else (Excel, another app, a hand-typed block, OR our
      //     own copy when the anchor/kernel is unavailable): fall through to the
      //     quote-aware TSV VALUE path, parsed client-side (_tsvParse) so an Excel
      //     cell holding a newline stays ONE cell instead of shattering into
      //     phantom rows. This is the regression lock — a foreign paste behaves
      //     exactly as today.
      // Over the cell cap we push a notice instead of the payload on BOTH paths.
      this._onPaste = (e) => {
        if (e.target.matches && e.target.matches("input, textarea")) return;
        const text = e.clipboardData && e.clipboardData.getData("text/plain");
        if (!text) return;
        e.preventDefault();
        const rows =
          (this._formulaClip && text === this._formulaClip.sig &&
            this._formulaPasteGrid(this._formulaClip)) ||
          this._tsvParse(text);
        let cells = 0;
        for (let i = 0; i < rows.length; i++) cells += rows[i].length;
        if (cells > this._pasteCellCap) {
          this._push("paste-too-large", { cells: cells });
          return;
        }
        this._push("paste", { rows: rows });
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
          this._push("resize", { kind: kind, index: parseInt(h.dataset.index, 10), px: px });
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

      // Bar ENTER commits via the surrounding form (phx-submit "bar-commit")
      // — the third commit surface next to the two pushEventTo sites. Decision
      // 11's canonicalization must not depend on WHICH key committed the bar,
      // so normalize INTO the input before LiveView serializes the form: this
      // listener sits on .sheet-editor, DEEPER than LiveView's delegated
      // window-level form binding, so it runs first during bubble. Nothing is
      // prevented or stopped — the native submit flow (and the #813 bar
      // semantics) ride unchanged, and if listener order ever changed the
      // worst case is today's raw value, never a broken commit. Read-only
      // sheets fail closed (the server drops their bar-commit anyway — never
      // rewrite a value that cannot commit).
      this._onBarSubmit = (e) => {
        const form = e.target && e.target.closest && e.target.closest(".sheet-bar-form");
        if (!form || this._readOnly) return;
        const bar = form.querySelector && form.querySelector(".sheet-bar-input");
        if (bar && bar.value != null) bar.value = this._normalize(bar.value);
        // The bar edit ends here — drop the volatile point/ghost state with it
        // (same reasoning as the Tab-commit path).
        this._endChrome();
      };

      // keydown + input + submit bind on root (the bar is a sibling of this.el);
      // the rest stay on this.el (they act on grid cells inside the hook element).
      this.root.addEventListener("keydown", this._onKeydown);
      this.root.addEventListener("input", this._onInput);
      this.root.addEventListener("submit", this._onBarSubmit);
      this.root.addEventListener("mousedown", this._onToolbarMousedown);
      this.el.addEventListener("click", this._onClick);
      this.el.addEventListener("dblclick", this._onDblclick);
      this.el.addEventListener("copy", this._onCopy);
      this.el.addEventListener("paste", this._onPaste);
      this.el.addEventListener("mousedown", this._onMousedown);
      this.el.addEventListener("mousedown", this._onCellMousedown);
      this.el.addEventListener("mousedown", this._onHeadMousedown);
      this.el.addEventListener("mousedown", this._onFillMousedown);
      // contextmenu binds on the grid (cells live inside it); the menu's own
      // click/keydown bind on root — the .sheet-context-menu is a SIBLING of the
      // grid element, so a handler on this.el would never see them.
      this.el.addEventListener("contextmenu", this._onContextMenu);
      this.root.addEventListener("click", this._onCtxClick);
      this.root.addEventListener("keydown", this._onCtxKeydown);

      this._presencePing();
    },

    // THE ONE PUSH SEAM. Every `pushEventTo` in this file goes through here, so
    // the read-mode denylist is DERIVED (the complement of READ_MODE_EVENTS)
    // rather than hand-enumerated per gesture — a new push site added later is
    // denied in read mode by default, which is the only safe direction to fail.
    // Returns true if the event was sent, false if it was dropped.
    _push(name, payload) {
      var body = payload || {};
      if (this._readOnly) {
        if (READ_MODE_EVENTS.indexOf(name) < 0) return false;
        body = this._readPayload(name, body);
      }
      this.pushEventTo(this.el, name, body);
      return true;
    },

    // Read-mode payload narrowing for the events that ARE allowed.
    //   • presence-meta → active + selection ONLY. The `editing` flag is never
    //     broadcast from a read-mode socket: edit-start is denied, so an
    //     "editing" frame would name a cell editor that does not exist.
    //   • everything else → the write-ride keys are stripped (see above).
    _readPayload(name, payload) {
      if (name === "presence-meta") {
        return {
          active: payload.active != null ? payload.active : null,
          selection: payload.selection != null ? payload.selection : null,
        };
      }
      var out = {};
      for (var k in payload) {
        if (!Object.prototype.hasOwnProperty.call(payload, k)) continue;
        if (WRITE_RIDE_KEYS.indexOf(k) >= 0) continue;
        out[k] = payload[k];
      }
      return out;
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
        // Same for the volatile formula-UX state: commits that BYPASS
        // _commitEditor (the toolbar draft-commit seal, the click-away
        // _rideCommits paths) end the edit server-side without clearing it. A
        // stale _ghost.offered would splice into the NEXT editor's first
        // Enter, and a stale _hot span would let the hot rule point-replace
        // arbitrary text at matching offsets — so when the editor leaves the
        // screen the state dies with it. A focused-DIRTY bar is a LIVE edit
        // (bar point sessions never show a cell editor), so it keeps its state.
        if (!this._formulaEditor()) this._endChrome();
        if (this._refocus) {
          this._refocus = false;
          this.el.focus({ preventScroll: true });
        }
      }
      // A right-click just opened the context menu — focus its first item and
      // clamp it inside the viewport so it never spills off a screen edge.
      if (this._ctxWantFocus) {
        this._ctxWantFocus = false;
        this._focusAndClampCtxMenu();
      }
      // The server re-render reflects every cursor/selection change
      // (cell-click, nav, tab-switch) — derive the presence frame from the
      // fresh DOM; the throttle + dedupe keep remote-delta re-renders quiet.
      this._presencePing();
    },

    // Focus the first context-menu item and nudge the menu back on-screen if the
    // cursor sat near a viewport edge. Browser-only geometry — the node harness
    // has no getBoundingClientRect, so it bails after the (also-absent) focus.
    _focusAndClampCtxMenu() {
      if (!this._dom()) return;
      const menu = this.root && this.root.querySelector && this.root.querySelector(".sheet-context-menu");
      if (!menu) return;
      const first = menu.querySelector && menu.querySelector("[role='menuitem']");
      if (first && first.focus) first.focus();
      if (!menu.getBoundingClientRect || typeof window === "undefined") return;
      const rect = menu.getBoundingClientRect();
      const vw = window.innerWidth || 0;
      const vh = window.innerHeight || 0;
      if (vw && rect.right > vw) menu.style.left = Math.max(0, vw - rect.width) + "px";
      if (vh && rect.bottom > vh) menu.style.top = Math.max(0, vh - rect.height) + "px";
    },

    destroyed() {
      // Element-scoped listeners die with the node; the drag handlers
      // remove themselves on mouseup. The keydown/input listeners live on
      // root (an ANCESTOR that outlives this hook element), so remove them
      // by hand or they leak across a hook remount.
      if (this.root) {
        this.root.removeEventListener("keydown", this._onKeydown);
        this.root.removeEventListener("input", this._onInput);
        this.root.removeEventListener("submit", this._onBarSubmit);
        this.root.removeEventListener("mousedown", this._onToolbarMousedown);
        this.root.removeEventListener("click", this._onCtxClick);
        this.root.removeEventListener("keydown", this._onCtxKeydown);
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
      this._push("edit-commit", { value: this._normalize(value), move: move });
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
      // Geometry ignores $-anchoring — an F4-cycled $B$3 outlines the same
      // cell as B3 (refToPos itself fails closed on $-forms, which is right
      // for whole-col/row refs but must not strip the outline off an anchored
      // ref the user just F4'd).
      var a = this._P.refToPos(parts[0].replace(/\$/g, ""));
      var b = this._P.refToPos(parts[parts.length - 1].replace(/\$/g, ""));
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
        this._push("presence-meta", payload);
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

    // Paste text read from the OS clipboard by the context-menu "Paste" item —
    // the same parse + cell-cap preflight + push tail as the Cmd+V handler
    // (_onPaste), minus the synchronous clipboard event the menu click can't
    // carry. Our-own-copy formulas rebase; a foreign block falls back to values.
    _ctxPaste(text) {
      const rows =
        (this._formulaClip && text === this._formulaClip.sig &&
          this._formulaPasteGrid(this._formulaClip)) ||
        this._tsvParse(text);
      let cells = 0;
      for (let i = 0; i < rows.length; i++) cells += rows[i].length;
      if (cells > this._pasteCellCap) {
        this._push("paste-too-large", { cells: cells });
        return;
      }
      this._push("paste", { rows: rows });
    },

    // Selection (server marks every selected td with .sheet-sel, the active
    // cell included) -> TSV, row-major, computed values from data-v. Serialized
    // quote-aware (_tsvEncode) so a cell whose value contains a tab or newline
    // stays ONE field Excel/Sheets parses back intact, not corrupt TSV.
    _selectionTsv() {
      const tds = this.el.querySelectorAll("td.sheet-sel");
      if (!tds.length) return null;
      return tsvEncode(selectionGrid(tds));
    },

    // ── formula clipboard (QL-D5, client-owned) ───────────────────────────────
    // On copy, remember the FORMULAS behind the just-copied selection, keyed by
    // `sig` (the exact TSV also on the OS clipboard). `formulas` is a row-major
    // grid parallel to that TSV — walked with the IDENTICAL row/col sort as
    // _selectionTsv, so formulas[i][j] lines up with _tsvParse(sig)[i][j]. Each
    // cell is the stored `data-f` (the formula body, from the QL-D6 S-GRID
    // stamp) normalized to canonical sans-'=' form, or null for a literal. The
    // engine's canonical `f` drops the leading '=' but "tolerates it on read"
    // (engine.ex §"A formula cell carries…"), so a stamped value MAY still carry
    // one; we strip exactly one here so the paste's re-prefix never doubles it
    // (==A2). `origin` is the selection's top-left (min row/col) — the anchor the
    // paste delta is measured from.
    _captureFormulaClip(sig) {
      const tds = this.el.querySelectorAll("td.sheet-sel");
      if (!tds.length) {
        this._formulaClip = null;
        return;
      }
      const rows = new Map();
      let minR = Infinity;
      let minC = Infinity;
      tds.forEach((td) => {
        const r = parseInt(td.dataset.r, 10);
        const c = parseInt(td.dataset.c, 10);
        if (r < minR) minR = r;
        if (c < minC) minC = c;
        if (!rows.has(r)) rows.set(r, new Map());
        const f = td.dataset ? td.dataset.f : null;
        const body = f != null && f !== "" && f.charAt(0) === "=" ? f.slice(1) : f;
        rows.get(r).set(c, body != null && body !== "" ? body : null);
      });
      const rKeys = Array.from(rows.keys()).sort((a, b) => a - b);
      const formulas = rKeys.map((r) => {
        const cols = rows.get(r);
        const cKeys = Array.from(cols.keys()).sort((a, b) => a - b);
        return cKeys.map((c) => cols.get(c));
      });
      this._formulaClip = { sig: sig, origin: { col: minC, row: minR }, formulas: formulas };
    },

    // Build the {rows} paste grid from a matching formula clipboard: each stored
    // formula is rebased by the delta from the copy origin to the paste anchor
    // (the active cell) and re-prefixed with '='; a cell with no formula falls
    // back to its TSV value (parsed from the clip's own signature, which round-
    // trips its value grid). Returns null when the paste anchor or the kernel is
    // unavailable, so _onPaste degrades to the plain value paste (fail-safe).
    _formulaPasteGrid(clip) {
      const target = this._activePos();
      if (!target || !this._F || !this._F.rebaseFormula) return null;
      const dcol = target.c - clip.origin.col;
      const drow = target.r - clip.origin.row;
      const values = this._tsvParse(clip.sig);
      const out = [];
      for (let i = 0; i < clip.formulas.length; i++) {
        const frow = clip.formulas[i];
        const vrow = values[i] || [];
        const orow = [];
        for (let j = 0; j < frow.length; j++) {
          const f = frow[j];
          if (f != null && f !== "") {
            orow.push("=" + this._F.rebaseFormula(f, dcol, drow));
          } else {
            orow.push(vrow[j] != null ? vrow[j] : "");
          }
        }
        out.push(orow);
      }
      return out;
    },

    // ── quote-aware TSV (RFC-4180-ish, tab-delimited) ─────────────────────────
    // Pure helpers, driven directly by the node harness. The encoder now lives
    // at module scope (`tsvEncode`, top of this file) because the reader hook
    // shares it; this stays the hook's public name so every existing pin holds.
    // These are the round-trip twins: _tsvParse(_tsvEncode(x)) deep-equals x.

    _tsvEncode: tsvEncode,

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

  // ══ PUBLIC READER: client-only selection + copy (wave 43, reader half) ═════
  //
  // THE RULING (main, 2026-09-02 10:52Z), verbatim:
  //
  //   "(b): client-only selection + copy layer in bp-sheet-grid.js for :reader
  //   — paints its own class, pushes ZERO events, reads data-v already on
  //   reader tds. An anonymous principal never round-trips selection and gains
  //   no authority. Add one test that the reader socket receives no event
  //   during select/copy. (a) rejected: it widens the server surface for a
  //   purely local affordance."
  //
  // So this is a SEPARATE, smaller hook — not BarkparkSheetGrid behind a flag.
  // sheet_grid.ex mounts it as `phx-hook="SheetReaderSelect"` where
  // `chrome == :reader`; `@hookable` (chrome == :studio) still decides
  // "SheetGrid", so the Studio path is byte-identical.
  //
  // THE SERVER IS UNTOUCHED, WHICH IS THE POINT. `Geometry.grid_sel(_, _,
  // :reader)` still returns {0,0,0,0} and sheet_grid.ex still refuses
  // select-all / nav-edge / nav-corner for `chrome: :reader`. That policy is
  // wave 42's, and option (a) — reversing it — was rejected. The reader's
  // anchor/active pair therefore lives ONLY in this object.
  //
  // ZERO EVENTS BY CONSTRUCTION, NOT BY ALLOWLIST. Unlike the Studio hook's
  // READ_MODE_EVENTS filter (a list that could be edited open again), there is
  // no `pushEvent` / `pushEventTo` identifier anywhere in this object. The node
  // harness pins that twice: it stubs both push functions to THROW, and it
  // greps this section of the shipped file for the identifiers.
  //
  // IT PAINTS ITS OWN CLASS. `sheet-rsel`, deliberately NOT `sheet-sel` — the
  // Studio harness pins `td.sheet-sel` and aliasing would make those checks
  // ambiguous about which grid produced the highlight.
  const READER_SEL_CLASS = "sheet-rsel";
  const READER_PAGE_ROWS = 20;

  function clampInt(n, lo, hi) {
    return n < lo ? lo : n > hi ? hi : n;
  }

  window.BarkparkSheetReaderSelect = {
    mounted() {
      this._anchor = null; // {c, r} — where the gesture started
      this._active = null; // {c, r} — where it is now
      this._dragging = false;

      // Marks the grid as JS-selection-driven. The reader stylesheet suppresses
      // the browser's own text selection ONLY under this class, so a no-JS
      // reader keeps native select-and-copy instead of losing both.
      if (this.el.classList) this.el.classList.add("sheet-rsel-on");

      this._onMousedown = (e) => {
        if (e.button != null && e.button !== 0) return;
        const cell = this._cellOf(e.target);
        if (!cell) return;
        // Suppress the native text-drag so the painted rect is the only
        // selection the reader sees.
        if (e.preventDefault) e.preventDefault();
        this._dragging = true;
        this._select(e.shiftKey && this._anchor ? this._anchor : cell, cell);
        if (this.el.focus) this.el.focus();
      };

      this._onMouseover = (e) => {
        if (!this._dragging) return;
        const cell = this._cellOf(e.target);
        if (cell) this._select(this._anchor, cell);
      };

      // On window: a drag that ends outside the grid must still end.
      this._onMouseup = () => {
        this._dragging = false;
      };

      this._onKeydown = (e) => {
        if (e.target && e.target.matches && e.target.matches("input, textarea, select")) return;
        const key = e.key;
        const mod = !!(e.metaKey || e.ctrlKey);
        const bounds = this._bounds();
        if (!bounds) return;

        // Ctrl/Cmd+A — the whole RENDERED grid (this page of rows), never the
        // logical sheet: the reader pages its rows and the off-page cells are
        // not in the DOM to copy.
        if (mod && (key === "a" || key === "A")) {
          if (e.preventDefault) e.preventDefault();
          this._select(
            { c: bounds.minC, r: bounds.minR },
            { c: bounds.maxC, r: bounds.maxR }
          );
          return;
        }
        if (key === "Escape") {
          this._clear();
          return;
        }

        const cur = this._active || { c: bounds.minC, r: bounds.minR };
        let next;
        switch (key) {
          case "ArrowUp":
            next = { c: cur.c, r: cur.r - 1 };
            break;
          case "ArrowDown":
            next = { c: cur.c, r: cur.r + 1 };
            break;
          case "ArrowLeft":
            next = { c: cur.c - 1, r: cur.r };
            break;
          case "ArrowRight":
            next = { c: cur.c + 1, r: cur.r };
            break;
          case "Home":
            next = { c: bounds.minC, r: mod ? bounds.minR : cur.r };
            break;
          case "End":
            next = { c: bounds.maxC, r: mod ? bounds.maxR : cur.r };
            break;
          case "PageUp":
            next = { c: cur.c, r: cur.r - READER_PAGE_ROWS };
            break;
          case "PageDown":
            next = { c: cur.c, r: cur.r + READER_PAGE_ROWS };
            break;
          default:
            return;
        }
        // Ctrl/Cmd + an arrow is the browser's (word/document jump); leave it.
        if (mod && key.indexOf("Arrow") === 0) return;
        if (e.preventDefault) e.preventDefault();
        next = {
          c: clampInt(next.c, bounds.minC, bounds.maxC),
          r: clampInt(next.r, bounds.minR, bounds.maxR)
        };
        this._select(e.shiftKey && this._anchor ? this._anchor : next, next);
      };

      // Cmd/Ctrl+C arrives here as the browser's own `copy` event — the OS
      // clipboard is written synchronously in-gesture and nothing else happens.
      this._onCopy = (e) => {
        if (e.target && e.target.matches && e.target.matches("input, textarea")) return;
        const tsv = this._selectionTsv();
        if (tsv == null) return;
        if (e.preventDefault) e.preventDefault();
        if (e.clipboardData) e.clipboardData.setData("text/plain", tsv);
      };

      this.el.addEventListener("mousedown", this._onMousedown);
      this.el.addEventListener("mouseover", this._onMouseover);
      this.el.addEventListener("keydown", this._onKeydown);
      this.el.addEventListener("copy", this._onCopy);
      window.addEventListener("mouseup", this._onMouseup);
    },

    destroyed() {
      this.el.removeEventListener("mousedown", this._onMousedown);
      this.el.removeEventListener("mouseover", this._onMouseover);
      this.el.removeEventListener("keydown", this._onKeydown);
      this.el.removeEventListener("copy", this._onCopy);
      window.removeEventListener("mouseup", this._onMouseup);
    },

    // Every rendered data cell. The reader stamps data-ref/data-r/data-c/data-v
    // on each one already (Cells.data_v), which is exactly what makes a
    // client-only layer possible without a single server change.
    _cells() {
      return this.el.querySelectorAll("td[data-ref]");
    },

    _cellOf(target) {
      const td = target && target.closest && target.closest("td[data-ref]");
      if (!td || !td.dataset) return null;
      const c = parseInt(td.dataset.c, 10);
      const r = parseInt(td.dataset.r, 10);
      return Number.isNaN(c) || Number.isNaN(r) ? null : { c: c, r: r };
    },

    // Derived from the DOM, never from a server assign: the reader pages rows,
    // so the navigable box is whatever is rendered right now.
    _bounds() {
      let b = null;
      Array.prototype.forEach.call(this._cells(), (td) => {
        const c = parseInt(td.dataset.c, 10);
        const r = parseInt(td.dataset.r, 10);
        if (Number.isNaN(c) || Number.isNaN(r)) return;
        if (!b) {
          b = { minC: c, maxC: c, minR: r, maxR: r };
          return;
        }
        if (c < b.minC) b.minC = c;
        if (c > b.maxC) b.maxC = c;
        if (r < b.minR) b.minR = r;
        if (r > b.maxR) b.maxR = r;
      });
      return b;
    },

    _select(anchor, active) {
      this._anchor = anchor;
      this._active = active;
      this._paint();
    },

    _clear() {
      this._anchor = null;
      this._active = null;
      this._paint();
    },

    _rect() {
      const a = this._anchor;
      const b = this._active;
      if (!a || !b) return null;
      return {
        c1: Math.min(a.c, b.c),
        c2: Math.max(a.c, b.c),
        r1: Math.min(a.r, b.r),
        r2: Math.max(a.r, b.r)
      };
    },

    _paint() {
      const rect = this._rect();
      let activeTd = null;
      Array.prototype.forEach.call(this._cells(), (td) => {
        const c = parseInt(td.dataset.c, 10);
        const r = parseInt(td.dataset.r, 10);
        const inRect =
          !!rect && c >= rect.c1 && c <= rect.c2 && r >= rect.r1 && r <= rect.r2;
        if (td.classList) td.classList[inRect ? "add" : "remove"](READER_SEL_CLASS);
        if (this._active && c === this._active.c && r === this._active.r) activeTd = td;
      });
      // a11y: the wrapper stays role="region" on the reader (role="application"
      // is edit-only — it muted a screen reader's own table-nav commands, see
      // sheets_reader_live_test.exs "grid a11y semantics"). Pointing
      // aria-activedescendant at the moving cell still lets AT follow the
      // selection. Set from the CLIENT, so the server render is unchanged.
      if (this.el.setAttribute && this.el.removeAttribute) {
        if (activeTd && activeTd.id) this.el.setAttribute("aria-activedescendant", activeTd.id);
        else this.el.removeAttribute("aria-activedescendant");
      }
    },

    // The SAME kernel the Studio hook copies through (module-scope tsvEncode /
    // selectionGrid at the top of this file) — reused, not forked, so a reader
    // copy quotes an embedded tab/newline/quote exactly as Studio does.
    _selectionTsv() {
      const sel = [];
      Array.prototype.forEach.call(this._cells(), (td) => {
        if (td.classList && td.classList.contains(READER_SEL_CLASS)) sel.push(td);
      });
      if (!sel.length) return null;
      return tsvEncode(selectionGrid(sel));
    },

    _tsvEncode: tsvEncode
  };
})();
