// slash-menu.js — Notion-style "/" insert menu for <bp-paper-editor> (P3.3).
//
// A custom caret-anchored popup (NOT a TipTap suggestion plugin) so it stays
// fully decoupled from StarterKit and never touches the marks/patch-block
// round-trip. The Web Component decides WHEN to open it (a "/" at the start of
// an empty block); this module owns the popup DOM, grouped item list, keyboard
// navigation, and outside-click dismissal. On a pick it calls back with the
// chosen block type — the WC erases the "/" and dispatches `bp-slash-insert`.
//
// Item list + grouping mirror the add-block dropdown in studio_live.ex verbatim
// (Text / Basic fields / Media & reference / Structured). Every `type` here
// resolves to a default_block/2 clause on the server.

export const SLASH_ITEMS = [
  // group: the optgroup label shown as a section header in the popup.
  // type:  the block type passed to default_block/2 on the server.
  // label: the human label shown (bold) in the row.
  // hint:  a 16px icon glyph at the row's left (recolors to accent when active).
  // desc:  a short right-aligned muted description (Portable-Doc slash style).
  { group: "Text", type: "paragraph", label: "Paragraph", hint: "¶", desc: "plain body text" },
  { group: "Text", type: "heading", label: "Heading", hint: "H", desc: "h1 — section title" },
  { group: "Text", type: "list", label: "List", hint: "•", desc: "bulleted or ordered" },
  { group: "Text", type: "callout", label: "Callout", hint: "!", desc: "warn or info card" },
  { group: "Text", type: "code", label: "Code", hint: "</>", desc: "monospace block" },
  { group: "Text", type: "divider", label: "Divider", hint: "—", desc: "horizontal rule" },
  { group: "Text", type: "section", label: "Section", hint: "§", desc: "ruled group" },

  { group: "Article chrome", type: "eyebrow", label: "Eyebrow", hint: "▔", desc: "kicker over the title" },
  { group: "Article chrome", type: "byline", label: "Byline", hint: "✎", desc: "author / credit line" },
  { group: "Article chrome", type: "ingress", label: "Ingress", hint: "¶", desc: "lead paragraph" },
  { group: "Article chrome", type: "pullquote", label: "Pullquote", hint: "❝", desc: "highlighted quote" },

  { group: "Visual", type: "diagram", label: "Diagram", hint: "⬡", desc: "Mermaid diagram" },

  { group: "Basic fields", type: "field-string", label: "String", hint: "T", desc: "single-line value" },
  { group: "Basic fields", type: "field-slug", label: "Slug", hint: "/", desc: "url-safe key" },
  { group: "Basic fields", type: "field-text", label: "Long text", hint: "¶", desc: "multi-line value" },
  { group: "Basic fields", type: "field-boolean", label: "Boolean", hint: "✓", desc: "true / false toggle" },
  { group: "Basic fields", type: "field-select", label: "Select", hint: "▾", desc: "pick one option" },
  { group: "Basic fields", type: "field-datetime", label: "Date & time", hint: "◷", desc: "timestamp value" },
  { group: "Basic fields", type: "field-color", label: "Color", hint: "●", desc: "hex swatch value" },

  { group: "Media & reference", type: "field-image", label: "Image", hint: "▣", desc: "upload or url" },
  { group: "Media & reference", type: "field-reference", label: "Reference", hint: "↗", desc: "link another document" },

  { group: "Structured", type: "composite", label: "Composite", hint: "{}", desc: "object of subfields" },
  { group: "Structured", type: "arrayOf", label: "Array of", hint: "[]", desc: "repeating list" },
  { group: "Structured", type: "codelist", label: "Code list", hint: "#", desc: "registry-backed enum" },
  { group: "Structured", type: "localizedText", label: "Localized text", hint: "🌐", desc: "multi-language string" },
];

// EX2 — expectation-aware top group. The Beta document editor renders the doc's
// STILL-recommendable expected fields as JSON on `[data-expected-fields]` (a
// stable LiveView-driven element, re-rendered on every block-list change —
// capped fields are dropped server-side, so a field hides once full). On open,
// the menu reads that JSON and prepends an "EXPECTED" group whose items insert
// a BOUND field block (they carry a `fieldName`). Returns [] when the element
// is absent or empty (the paper pane, or a doc with no Expectation) — the group
// then never renders and the menu behaves exactly as before.
const EXPECTED_GROUP = "EXPECTED";

// Count the BOUND field blocks currently rendered in the editor for `name`.
// Bound blocks render as `.bp-paper-edit-field[data-field-name="<name>"]`; the
// hidden `[data-expected-fields]` config element carries no `data-field-name`,
// so it is never miscounted. This is the LIVE source of truth for hide-at-cap —
// the server-rendered `data-expected-fields` list can lag the editor (lazy
// block synthesis + client-side inserts), which is why the cap is enforced here
// against what is actually on screen, not against the server's count hint.
function countBoundFieldBlocks(name) {
  if (!name) return 0;
  const esc = name.replace(/["\\]/g, "\\$&");
  try {
    return document.querySelectorAll(
      `.bp-paper-edit-field[data-field-name="${esc}"]`,
    ).length;
  } catch (_e) {
    return 0;
  }
}

// True when this expected field has an integer `max` and its LIVE bound-block
// count has reached it — so the slash menu must hide it (1/1 used). A nil/absent
// or non-integer max is unlimited and never at cap.
function fieldAtCapLive(f) {
  const max = typeof f.max === "number" ? f.max : parseInt(f.max, 10);
  if (!Number.isInteger(max)) return false;
  return countBoundFieldBlocks(f.name) >= max;
}

export function readExpectedItems(doc = document) {
  const el = doc.querySelector("[data-expected-fields]");
  if (!el) return [];
  let parsed;
  try {
    parsed = JSON.parse(el.getAttribute("data-expected-fields") || "[]");
  } catch (_e) {
    return [];
  }
  if (!Array.isArray(parsed)) return [];

  return parsed
    .filter((f) => f && typeof f.name === "string" && f.name !== "")
    // EX2 hide-at-cap, computed against the LIVE editor (see fieldAtCapLive).
    .filter((f) => !fieldAtCapLive(f))
    .map((f) => ({
      group: EXPECTED_GROUP,
      type: f.type || "field-string",
      // carry the field name so the WC can dispatch a BOUND insert.
      fieldName: f.name,
      label: f.label || f.name,
      hint: "✦",
      desc: "expected",
    }));
}

export class SlashMenu {
  // `eyebrow`, `extraClass`, `footHtml`, and `filter` are OPTIONAL parameterization
  // seams (added for the Phase-5 command palette, which subclasses this popup). When
  // they are omitted the menu behaves byte-identically to the original slash menu:
  //   * eyebrow    — the uppercase header text (default "Insert block").
  //   * extraClass — an extra class on the popup root (default none) so a subclass can
  //                  hang its own positioning/width CSS off the shared DOM.
  //   * footHtml   — the footer hint-bar innerHTML (default the slash contract chips).
  //   * filter     — (allItems, query) => filteredItems. Default: the slash menu's
  //                  case-insensitive substring over label/type/desc/group. A subclass
  //                  passes a fuzzy matcher to filter the WHOLE registry by label+group.
  //   * readExtraItems — () => prepended items (default readExpectedItems; the palette
  //                  passes a no-op so its static registry is never EXPECTED-augmented).
  constructor({
    items,
    onChoose,
    onDismiss,
    eyebrow,
    extraClass,
    footHtml,
    filter,
    readExtraItems,
    emptyText,
  }) {
    // The base (generic) groups — Text / Basic fields / Media & reference /
    // Structured. The EXPECTED group is read fresh on every open() and
    // prepended, so it always reflects current usage.
    this._baseItems = items || SLASH_ITEMS;
    // _allItems = EXPECTED group + base groups (recomputed each open). _items =
    // the filtered view shown for the current query. _query = live filter text.
    this._allItems = this._baseItems;
    this._items = this._baseItems;
    this._query = "";
    this._onChoose = onChoose || (() => {});
    this._onDismiss = onDismiss || (() => {});
    // Parameterization seams — see the constructor doc above. Each defaults to the
    // original slash-menu behavior so the slash path is byte-unchanged.
    this._eyebrow = eyebrow || "Insert block";
    this._extraClass = extraClass || "";
    this._footHtml = footHtml || null;
    this._emptyText = emptyText || null;
    this._filterFn = typeof filter === "function" ? filter : null;
    this._readExtraItems =
      typeof readExtraItems === "function" ? readExtraItems : readExpectedItems;
    this._open = false;
    this._active = 0; // index into the FLAT selectable (filtered) item list
    this._el = null; // popup root
    this._rowEls = []; // parallel to selectable items, for active styling

    // Bound once so add/removeEventListener match.
    this._onDocPointer = (e) => this._handlePointer(e);
    this._onDocKeydown = (e) => this._handleKeydown(e);
  }

  isOpen() {
    return this._open;
  }

  // Show the popup anchored to a caret rect { left, top, bottom }, filtered by
  // `query` (the text after "/"). Called on first open AND on every keystroke
  // while the menu stays open, so the rows narrow live as the user types.
  open(rect, query = "") {
    if (!this._el) this._build();
    // Recompute the candidate list on every open: any prepended extra items (the
    // EXPECTED group, read fresh from the DOM so it reflects current usage / hide-
    // at-cap — or, for the command palette, a no-op) on top, then the base items
    // below.
    this._allItems = [...this._readExtraItems(), ...this._baseItems];
    this._query = query || "";
    this._applyFilter(); // → this._items (filtered view)
    if (!this._open) {
      this._open = true;
      document.addEventListener("mousedown", this._onDocPointer, true);
      // Capture-phase Escape so the menu reliably closes even when the
      // keydown does not route through TipTap's editorProps.handleKeyDown
      // (e.g. a JS-dispatched Escape in a verify run, or focus that has
      // momentarily left the ProseMirror DOM). Capture + stopImmediatePropagation
      // prevents the same Escape from leaking to other handlers.
      document.addEventListener("keydown", this._onDocKeydown, true);
    }
    // Re-render every call so the filtered rows update and the active row
    // resets to the first match as the query changes.
    this._active = 0;
    this._render();
    this._position(rect);
    this._syncActive();
  }

  // Narrow _allItems by the live query — case-insensitive substring over the
  // label / type / description / group. An empty query passes everything
  // through. Group headers are emitted by _render only when an item of that
  // group survives, so groups with no matches disappear automatically.
  _applyFilter() {
    // A subclass may inject a fuzzy matcher over the whole list (the command
    // palette). Default: the slash menu's case-insensitive substring.
    if (this._filterFn) {
      this._items = this._filterFn(this._allItems, this._query || "");
      return;
    }
    const q = (this._query || "").trim().toLowerCase();
    if (!q) {
      this._items = this._allItems;
      return;
    }
    this._items = this._allItems.filter((it) => {
      const hay = `${it.label || ""} ${it.type || ""} ${it.desc || ""} ${
        it.group || ""
      }`.toLowerCase();
      return hay.includes(q);
    });
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

  // Move the active selection by `delta`, wrapping at both ends.
  move(delta) {
    const n = this._items.length;
    if (n === 0) return;
    this._active = (this._active + delta + n) % n;
    this._syncActive();
  }

  // Commit the currently-active item. Passes the WHOLE item so the caller can
  // read both `type` and (for an EXPECTED pick) `fieldName`.
  choose() {
    const item = this._items[this._active];
    if (item) this._onChoose(item);
  }

  // ── internals ────────────────────────────────────────────────────────────

  // Subclass hook — render an optional query <input> under the eyebrow. No-op for
  // the slash menu (its query is the typed "/…" doc text). The command palette
  // overrides it. `parentEl` is the popup root.
  _renderQueryInput(_parentEl) {}

  _build() {
    const el = document.createElement("div");
    // Always carries `bp-slash-menu` so it inherits the shared popup CSS; a
    // subclass adds its own modifier class (e.g. `bp-cmd-palette`) for centered
    // positioning, WITHOUT restyling the rows.
    el.className = this._extraClass
      ? `bp-slash-menu ${this._extraClass}`
      : "bp-slash-menu";
    el.setAttribute("role", "listbox");
    el.style.display = "none";
    document.body.appendChild(el);
    this._el = el;
  }

  _render() {
    this._el.innerHTML = "";
    this._rowEls = [];

    // Eyebrow — uppercase, letter-spaced "Insert block" header (Portable-Doc
    // `.paper-slash-popover__head`). Sits above the scrollable row list.
    const eyebrow = document.createElement("div");
    eyebrow.className = "bp-slash-eyebrow";
    eyebrow.textContent = this._eyebrow;
    this._el.appendChild(eyebrow);

    // Optional query-input hook — a no-op for the slash menu (its query is the typed
    // "/…" doc text, re-opened on each keystroke). The command palette (keyboard-
    // triggered, no doc text) overrides this to render its own <input> so the user can
    // type the fuzzy filter. Called once per render, right under the eyebrow.
    this._renderQueryInput(this._el);

    // Scrollable list region so the eyebrow + footer stay pinned.
    const list = document.createElement("div");
    list.className = "bp-slash-list";
    this._el.appendChild(list);

    // Empty state — a non-selectable row when the query matches nothing.
    if (this._items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "bp-slash-empty";
      empty.textContent = this._emptyText || "No blocks match";
      list.appendChild(empty);
    }

    let lastGroup = null;
    this._items.forEach((item, idx) => {
      const isExpected = item.group === EXPECTED_GROUP;
      if (item.group !== lastGroup) {
        lastGroup = item.group;
        const header = document.createElement("div");
        header.className = "bp-slash-group";
        header.textContent = item.group;
        // Stamp the EXPECTED group header so its CSS picks up the accent.
        if (isExpected) header.dataset.expected = "";
        list.appendChild(header);
      }

      const row = document.createElement("button");
      row.type = "button";
      row.className = "bp-slash-item";
      row.setAttribute("role", "option");
      row.dataset.type = item.type;
      // EXPECTED-group rows carry the field name (for the bound insert) and a
      // data-expected marker so the ✦ hint + "expected" tag recolor to accent.
      if (isExpected) {
        row.dataset.expected = "";
        if (item.fieldName) row.dataset.fieldName = item.fieldName;
      }

      // 16px icon glyph — recolors to --paper-accent on the active/selected row.
      const hint = document.createElement("span");
      hint.className = "bp-slash-hint";
      hint.textContent = item.hint || "";

      const label = document.createElement("span");
      label.className = "bp-slash-label";
      label.textContent = item.label;

      // Right-aligned muted description.
      const desc = document.createElement("span");
      desc.className = "bp-slash-desc";
      desc.textContent = item.desc || "";

      row.appendChild(hint);
      row.appendChild(label);
      row.appendChild(desc);

      // mousedown (not click) so we fire before the editor's blur closes us.
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

    // Footer hint bar — <kbd> chips for the keyboard contract. A subclass may
    // override the chips (the palette says "run" instead of "insert").
    const foot = document.createElement("div");
    foot.className = "bp-slash-foot";
    foot.innerHTML =
      this._footHtml ||
      "<kbd>↵</kbd> insert <span class=\"bp-slash-foot-sep\">·</span> " +
        "<kbd>↑</kbd><kbd>↓</kbd> navigate " +
        "<span class=\"bp-slash-foot-sep\">·</span> <kbd>esc</kbd> dismiss";
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

  // A pointer-down outside the popup dismisses it (keeps the typed "/").
  _handlePointer(e) {
    if (!this._el) return;
    if (this._el.contains(e.target)) return;
    this._onDismiss();
  }

  // Escape dismisses the open menu (keeps the typed "/"). Caught in the capture
  // phase so it fires before — and instead of — any editor/global handler, and
  // is swallowed so the Escape never leaks. This is the authoritative Esc path;
  // index.js's editorProps.handleKeyDown remains as a same-behaviour fallback
  // for the case where ProseMirror sees the key first.
  _handleKeydown(e) {
    if (!this._open) return;
    if (e.key === "Escape" || e.key === "Esc") {
      e.preventDefault();
      e.stopImmediatePropagation();
      this._onDismiss();
    }
  }
}
