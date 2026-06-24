// wikilink-menu.js — caret-anchored `[[` autocomplete popup for <bp-paper-editor>.
//
// A custom caret-anchored popup (NOT a TipTap suggestion plugin) mirroring the
// exact shape of slash-menu.js: fixed-position, keyboard nav with wrap, mousedown-
// to-pick BEFORE blur, outside-pointer + capture-phase Escape dismissal, viewport
// flip in _position. The Web Component decides WHEN to open it (parseOpenWikilink
// returns a live query); this module owns the popup DOM, async result list,
// keyboard navigation, and outside-click dismissal. On a pick it calls back with
// the chosen candidate — the WC replaces the typed "[[query" span with a wikilink
// mark { target: title } and calls onChoose({ title, id, type }).
//
// Key differences from SlashMenu:
//   • NO groups — flat candidate list (the server already scoped the results).
//   • NO local filtering — results arrive ASYNC via setResults(); rendered verbatim.
//   • Candidate shape: { title: string, id: string, type: string }
//   • Rows: bold title on the left + muted right-aligned type badge (no hint glyph).
//   • open() shows a "Searching…" state until setResults() fires for the first time.
//   • Eyebrow reads "Link to page" (vs slash menu's "Insert block").

export class WikilinkMenu {
  constructor({ onChoose, onDismiss }) {
    this._onChoose = onChoose || (() => {});
    this._onDismiss = onDismiss || (() => {});
    this._open = false;
    this._active = 0;       // index into the flat selectable results list
    this._results = [];     // current candidate list ({ title, id, type }[])
    this._resultsSet = false; // false → still "Searching…"; true → render results
    this._query = "";       // live query (display only in the eyebrow)
    this._el = null;        // popup root element
    this._rowEls = [];      // parallel to this._results, for active styling

    // Bound once so add/removeEventListener match on teardown.
    this._onDocPointer = (e) => this._handlePointer(e);
    this._onDocKeydown = (e) => this._handleKeydown(e);
  }

  isOpen() {
    return this._open;
  }

  // Show the popup anchored to a caret rect { left, top, bottom }. `query` is
  // the live text after "[[" (stored for the eyebrow header; NOT used for local
  // filtering — the server already filtered). If results are not yet set a
  // "Searching…" placeholder row is shown; call setResults() to replace it.
  open(rect, query = "") {
    if (!this._el) this._build();
    this._query = query || "";
    if (!this._open) {
      // FIRST open: start in the "Searching…" state until setResults() fires.
      // On a refresh-while-open (the query growing keystroke-by-keystroke) we
      // deliberately do NOT reset — the previously-rendered candidates stay
      // visible so the list never flickers back to "Searching…" on every key;
      // the next setResults() swaps in the fresh batch in place once it lands.
      this._resultsSet = false;
      this._results = [];
      this._active = 0;
      this._open = true;
      document.addEventListener("mousedown", this._onDocPointer, true);
      // Capture-phase Escape so the menu reliably closes even when keydown does
      // not route through TipTap's editorProps.handleKeyDown (e.g. a JS-
      // dispatched Escape in a verify run, or focus that has momentarily left
      // the ProseMirror DOM). stopImmediatePropagation prevents the Escape from
      // leaking to other handlers.
      document.addEventListener("keydown", this._onDocKeydown, true);
    }
    this._render();
    this._position(rect);
    this._syncActive();
  }

  // Replace the candidate list with a fresh batch from the async wikilinkSource.
  // Resets the active row to index 0 and re-renders in place. The WC calls this
  // once its wikilinkSource promise resolves (zero or more times per open session).
  setResults(list) {
    this._resultsSet = true;
    this._results = Array.isArray(list) ? list : [];
    this._active = 0;
    this._render();
    this._syncActive();
  }

  close() {
    if (!this._open) return;
    this._open = false;
    if (this._el) this._el.style.display = "none";
    document.removeEventListener("mousedown", this._onDocPointer, true);
    document.removeEventListener("keydown", this._onDocKeydown, true);
  }

  destroy() {
    this.close();
    if (this._el && this._el.parentNode) this._el.parentNode.removeChild(this._el);
    this._el = null;
    this._rowEls = [];
  }

  // Move the active selection by `delta`, wrapping at both ends. No-op when
  // there are no selectable rows (Searching…/No matching pages state).
  move(delta) {
    const n = this._results.length;
    if (n === 0) return;
    this._active = (this._active + delta + n) % n;
    this._syncActive();
  }

  // Commit the currently-active candidate. Passes the whole { title, id, type }
  // object to onChoose. No-op when the results list is empty.
  choose() {
    const candidate = this._results[this._active];
    if (candidate) this._onChoose(candidate);
  }

  // ── internals ────────────────────────────────────────────────────────────

  _build() {
    const el = document.createElement("div");
    el.className = "bp-wikilink-menu";
    el.setAttribute("role", "listbox");
    el.style.display = "none";
    document.body.appendChild(el);
    this._el = el;
  }

  _render() {
    this._el.innerHTML = "";
    this._rowEls = [];

    // Eyebrow — uppercase, letter-spaced "Link to page" header, sitting above
    // the scrollable row list. Mirrors the slash menu's "Insert block" eyebrow.
    const eyebrow = document.createElement("div");
    eyebrow.className = "bp-wikilink-menu__eyebrow";
    eyebrow.textContent = "Link to page";
    this._el.appendChild(eyebrow);

    // Scrollable list region so the eyebrow + footer stay pinned at top/bottom.
    const list = document.createElement("div");
    list.className = "bp-wikilink-list";
    this._el.appendChild(list);

    if (!this._resultsSet) {
      // Async loading state — setResults() has not yet been called for this open.
      const searching = document.createElement("div");
      searching.className = "bp-wikilink-empty";
      searching.textContent = "Searching…";
      list.appendChild(searching);
    } else if (this._results.length === 0) {
      // Empty results — non-selectable. Note-creation is out of scope.
      const empty = document.createElement("div");
      empty.className = "bp-wikilink-empty";
      empty.textContent = "No matching pages";
      list.appendChild(empty);
    } else {
      // Flat candidate list — no groups (the server already scoped the results).
      this._results.forEach((candidate, idx) => {
        const row = document.createElement("button");
        row.type = "button";
        row.className = "bp-wikilink-item";
        row.setAttribute("role", "option");
        row.dataset.id = candidate.id || "";

        // Bold page title — the primary label (left-aligned).
        const title = document.createElement("span");
        title.className = "bp-wikilink-title";
        title.textContent = candidate.title || "";

        // Muted right-aligned type badge, mirroring `.bp-slash-desc`.
        const badge = document.createElement("span");
        badge.className = "bp-wikilink-type-badge";
        badge.textContent = candidate.type || "";

        row.appendChild(title);
        row.appendChild(badge);

        // mousedown (not click) so we fire BEFORE the editor blur closes us —
        // same pattern as SlashMenu. e.preventDefault() keeps the editor focused.
        row.addEventListener("mousedown", (e) => {
          e.preventDefault();
          this._active = idx;
          this.choose();
        });
        row.addEventListener("mouseenter", () => {
          this._active = idx;
          this._syncActive();
        });

        list.appendChild(row);
        this._rowEls.push(row);
      });
    }

    // Footer hint bar — <kbd> chips for the keyboard contract. Mirrors the slash
    // menu footer, substituting "insert link" for "insert".
    const foot = document.createElement("div");
    foot.className = "bp-wikilink-foot";
    foot.innerHTML =
      "<kbd>↵</kbd> insert link <span class=\"bp-wikilink-foot-sep\">·</span> " +
      "<kbd>↑</kbd><kbd>↓</kbd> navigate " +
      "<span class=\"bp-wikilink-foot-sep\">·</span> <kbd>esc</kbd> dismiss";
    this._el.appendChild(foot);
  }

  _syncActive() {
    this._rowEls.forEach((row, idx) => {
      if (idx === this._active) {
        row.classList.add("is-active");
        row.scrollIntoView({ block: "nearest" });
      } else {
        row.classList.remove("is-active");
      }
    });
  }

  // Place the popup just below the caret; flip above if it would overflow the
  // viewport bottom. Fixed positioning so it floats over the editor scroll.
  // Algorithm mirrors SlashMenu._position (6px margin, constrained on all sides).
  _position(rect) {
    if (!this._el) return;
    this._el.style.display = "block";
    this._el.style.position = "fixed";

    const menuRect = this._el.getBoundingClientRect();
    const margin = 6;
    let top = rect.bottom + margin;
    if (top + menuRect.height > window.innerHeight) {
      top = rect.top - menuRect.height - margin;
      if (top < margin) top = margin;
    }
    let left = rect.left;
    if (left + menuRect.width > window.innerWidth) {
      left = window.innerWidth - menuRect.width - margin;
    }
    if (left < margin) left = margin;

    this._el.style.top = `${Math.round(top)}px`;
    this._el.style.left = `${Math.round(left)}px`;
  }

  // A pointer-down outside the popup dismisses it. Leaves the typed "[[query"
  // in place — same contract as SlashMenu's outside-click for the typed "/".
  _handlePointer(e) {
    if (!this._el) return;
    if (this._el.contains(e.target)) return;
    this._onDismiss();
  }

  // Escape dismisses the open menu. Caught in capture phase so it fires before
  // — and instead of — any editor/global handler; swallowed so it never leaks.
  // Mirrors SlashMenu._handleKeydown exactly.
  _handleKeydown(e) {
    if (!this._open) return;
    if (e.key === "Escape" || e.key === "Esc") {
      e.preventDefault();
      e.stopImmediatePropagation();
      this._onDismiss();
    }
  }
}
