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
  // label: the human label shown in the row.
  // hint:  a tiny glyph for premium feel (purely decorative).
  { group: "Text", type: "paragraph", label: "Paragraph", hint: "¶" },
  { group: "Text", type: "heading", label: "Heading", hint: "H" },
  { group: "Text", type: "list", label: "List", hint: "•" },
  { group: "Text", type: "callout", label: "Callout", hint: "!" },
  { group: "Text", type: "code", label: "Code", hint: "</>" },
  { group: "Text", type: "divider", label: "Divider", hint: "—" },
  { group: "Text", type: "section", label: "Section", hint: "§" },

  { group: "Basic fields", type: "field-string", label: "String", hint: "T" },
  { group: "Basic fields", type: "field-slug", label: "Slug", hint: "/" },
  { group: "Basic fields", type: "field-text", label: "Long text", hint: "¶" },
  { group: "Basic fields", type: "field-boolean", label: "Boolean", hint: "✓" },
  { group: "Basic fields", type: "field-select", label: "Select", hint: "▾" },
  { group: "Basic fields", type: "field-datetime", label: "Date & time", hint: "◷" },
  { group: "Basic fields", type: "field-color", label: "Color", hint: "●" },

  { group: "Media & reference", type: "field-image", label: "Image", hint: "▣" },
  { group: "Media & reference", type: "field-reference", label: "Reference", hint: "↗" },

  { group: "Structured", type: "composite", label: "Composite", hint: "{}" },
  { group: "Structured", type: "arrayOf", label: "Array of", hint: "[]" },
  { group: "Structured", type: "codelist", label: "Code list", hint: "#" },
  { group: "Structured", type: "localizedText", label: "Localized text", hint: "🌐" },
];

export class SlashMenu {
  constructor({ items, onChoose, onDismiss }) {
    this._items = items || SLASH_ITEMS;
    this._onChoose = onChoose || (() => {});
    this._onDismiss = onDismiss || (() => {});
    this._open = false;
    this._active = 0; // index into the FLAT selectable item list
    this._el = null; // popup root
    this._rowEls = []; // parallel to selectable items, for active styling

    // Bound once so add/removeEventListener match.
    this._onDocPointer = (e) => this._handlePointer(e);
    this._onDocKeydown = (e) => this._handleKeydown(e);
  }

  isOpen() {
    return this._open;
  }

  // Show the popup anchored to a caret rect { left, top, bottom }.
  open(rect) {
    if (!this._el) this._build();
    if (!this._open) {
      this._active = 0;
      this._render();
      this._open = true;
      document.addEventListener("mousedown", this._onDocPointer, true);
      // Capture-phase Escape so the menu reliably closes even when the
      // keydown does not route through TipTap's editorProps.handleKeyDown
      // (e.g. a JS-dispatched Escape in a verify run, or focus that has
      // momentarily left the ProseMirror DOM). Capture + stopImmediatePropagation
      // prevents the same Escape from leaking to other handlers.
      document.addEventListener("keydown", this._onDocKeydown, true);
    }
    this._position(rect);
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

  // Move the active selection by `delta`, wrapping at both ends.
  move(delta) {
    const n = this._items.length;
    if (n === 0) return;
    this._active = (this._active + delta + n) % n;
    this._syncActive();
  }

  // Commit the currently-active item.
  choose() {
    const item = this._items[this._active];
    if (item) this._onChoose(item.type);
  }

  // ── internals ────────────────────────────────────────────────────────────

  _build() {
    const el = document.createElement("div");
    el.className = "bp-slash-menu";
    el.setAttribute("role", "listbox");
    el.style.display = "none";
    document.body.appendChild(el);
    this._el = el;
  }

  _render() {
    this._el.innerHTML = "";
    this._rowEls = [];

    let lastGroup = null;
    this._items.forEach((item, idx) => {
      if (item.group !== lastGroup) {
        lastGroup = item.group;
        const header = document.createElement("div");
        header.className = "bp-slash-group";
        header.textContent = item.group;
        this._el.appendChild(header);
      }

      const row = document.createElement("button");
      row.type = "button";
      row.className = "bp-slash-item";
      row.setAttribute("role", "option");
      row.dataset.type = item.type;

      const hint = document.createElement("span");
      hint.className = "bp-slash-hint";
      hint.textContent = item.hint || "";

      const label = document.createElement("span");
      label.className = "bp-slash-label";
      label.textContent = item.label;

      row.appendChild(hint);
      row.appendChild(label);

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

      this._el.appendChild(row);
      this._rowEls.push(row);
    });
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
