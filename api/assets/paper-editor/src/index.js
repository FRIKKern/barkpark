// bp-paper-editor — premium per-block rich-text editor (Barkpark papers, P1.1).
//
// Architecture (Option 2): LiveView owns the block list; EACH rich-text block
// is edited by its OWN TipTap-vanilla instance. On edit, this Web Component
// emits a `patch-block` DocPatchOp for that one block via a bubbling
// CustomEvent("bp-op"). It does NOT build one giant ProseMirror document.
//
// Engine: TipTap-vanilla (@tiptap/core, no React), bundled by esbuild into a
// single committed IIFE artifact at priv/static/assets/bp-paper-editor.bundle.js
// — the same vendoring pattern as the other bp-* components.
//
// P1 scope: premium typing + inline marks (bold/italic/strike/code via
// TipTap's built-in keyboard shortcuts) + heading/list block types + the
// patch-block round-trip. Slash menu, floating toolbar, drag-reorder, and
// new/delete-block are LATER units.

import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import Link from "@tiptap/extension-link";

import { blockToTiptap, buildPatchBlockOp } from "./convert.js";
import { SlashMenu, SLASH_ITEMS } from "./slash-menu.js";
import { FormatBubble } from "./format-bubble.js";

const DEBOUNCE_MS = 300;

class BpPaperEditor extends HTMLElement {
  constructor() {
    super();
    this._editor = null;
    this._mount = null;
    this._blockId = null;
    this._blockType = "paragraph";
    this._debounceTimer = null;
    this._slash = null; // SlashMenu instance (lazy, created on first trigger)
    this._bubble = null; // FormatBubble instance (selection format toolbar)
  }

  connectedCallback() {
    if (this._editor) return; // double-mount guard

    const block = this._readBlock();
    this._blockId = block && block.id != null ? block.id : null;
    this._blockType = (block && block.type) || "paragraph";

    // The contenteditable element the WC owns. TipTap mounts onto it.
    this._mount = document.createElement("div");
    this._mount.className = "bp-paper-editor-body";
    this.appendChild(this._mount);

    this._editor = new Editor({
      element: this._mount,
      extensions: [
        StarterKit.configure({
          // Single-block editing: heading levels 1–3, lists, history on.
          heading: { levels: [1, 2, 3] },
          // Marks/nodes left enabled by StarterKit: paragraph, bold, italic,
          // strike, code, bulletList, orderedList, listItem, history.
        }),
        // Link mark — required for the format bubble's link button and so
        // existing `link` inline nodes (convert.js already round-trips them)
        // render + edit. openOnClick:false keeps clicks editing, not
        // navigating; autolink off so typing a URL is not silently linkified.
        Link.configure({ openOnClick: false, autolink: false }),
      ],
      content: blockToTiptap(block),
      editorProps: {
        // While the slash menu is open it OWNS the navigation keys (↑/↓/Enter/
        // Esc/Tab) — return true so ProseMirror does not also act on them.
        // When closed, every keystroke falls through to TipTap unchanged, so
        // the existing marks/typing round-trip is untouched.
        handleKeyDown: (_view, event) => this._onKeyDown(event),
      },
      onUpdate: () => {
        this._scheduleEmit();
        this._maybeSlash();
        if (this._bubble) this._bubble.update();
      },
      // Selection-only changes (drag-select, shift-arrow, click-place) don't
      // fire onUpdate — drive the format bubble from selectionUpdate too.
      onSelectionUpdate: () => {
        if (this._bubble) this._bubble.update();
      },
      // Focus leaving the editor (clicking another block / outside) must hide
      // the bubble; refocusing re-evaluates the live selection.
      onBlur: () => { if (this._bubble) this._bubble.update(); },
      onFocus: () => { if (this._bubble) this._bubble.update(); },
    });

    // Selection format toolbar (B6) — B / I / </> / link, shown on a non-empty
    // text selection. Hand-rolled (no tippy) and fully decoupled from the
    // patch-block round-trip and the slash menu.
    this._bubble = new FormatBubble({ editor: this._editor });
  }

  disconnectedCallback() {
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }
    if (this._slash) {
      this._slash.destroy();
      this._slash = null;
    }
    if (this._bubble) {
      this._bubble.destroy();
      this._bubble = null;
    }
    if (this._editor) {
      this._editor.destroy();
      this._editor = null;
    }
  }

  // Read the initial block from the `block` JS property (object) first, then
  // fall back to a `data-block` attribute holding a JSON string.
  _readBlock() {
    if (this._blockProp && typeof this._blockProp === "object") {
      return this._blockProp;
    }
    const raw = this.getAttribute("data-block") || this.dataset.block;
    if (raw) {
      try {
        return JSON.parse(raw);
      } catch (_e) {
        // fall through to a default empty paragraph
      }
    }
    return { id: null, type: "paragraph", content: [] };
  }

  _scheduleEmit() {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => {
      this._debounceTimer = null;
      this._emitOp();
    }, DEBOUNCE_MS);
  }

  _emitOp() {
    if (!this._editor || this._blockId == null) return;
    const json = this._editor.getJSON();
    const op = buildPatchBlockOp(json, this._blockId, this._blockType);
    this.dispatchEvent(
      new CustomEvent("bp-op", {
        detail: op,
        bubbles: true,
        composed: true,
      }),
    );
  }

  // ── slash menu ─────────────────────────────────────────────────────────
  //
  // Trigger rule (deliberately conservative so a "/" inside prose never opens
  // the menu): the menu opens ONLY when the editor holds a single empty block
  // whose ENTIRE text is exactly "/" and the caret sits right after it — i.e.
  // the user typed "/" at the start of an otherwise-empty line. Any other
  // content (text before the slash, a second paragraph, a non-collapsed
  // selection) keeps the menu closed.
  _maybeSlash() {
    if (!this._editor) return;

    const { state } = this._editor;
    const { selection, doc } = state;

    // Caret only — never on a range selection.
    if (!selection.empty) {
      this._closeSlash();
      return;
    }

    const text = this._editor.getText(); // plain text across the single block
    const triggered =
      text === "/" && selection.$from.parentOffset === 1 && doc.childCount <= 2;

    if (triggered) {
      this._openSlash();
    } else {
      this._closeSlash();
    }
  }

  _openSlash() {
    if (!this._slash) {
      this._slash = new SlashMenu({
        items: SLASH_ITEMS,
        onChoose: (item) => this._chooseSlash(item),
        onDismiss: () => this._dismissSlash(),
      });
    }
    // Anchor the popup to the live caret rectangle.
    const rect = this._caretRect();
    this._slash.open(rect);
  }

  _closeSlash() {
    if (this._slash) this._slash.close();
  }

  // The DOMRect of the current caret, used to position the popup at the cursor.
  _caretRect() {
    try {
      const { from } = this._editor.state.selection;
      const coords = this._editor.view.coordsAtPos(from);
      return {
        left: coords.left,
        top: coords.top,
        bottom: coords.bottom,
      };
    } catch (_e) {
      const r = this._mount.getBoundingClientRect();
      return { left: r.left, top: r.top, bottom: r.bottom };
    }
  }

  // Keyboard handler installed via editorProps.handleKeyDown. Only ACTS when
  // the menu is open; otherwise returns false so TipTap handles the key.
  _onKeyDown(event) {
    if (!this._slash || !this._slash.isOpen()) return false;

    switch (event.key) {
      case "ArrowDown":
        this._slash.move(1);
        return true;
      case "ArrowUp":
        this._slash.move(-1);
        return true;
      case "Enter":
      case "Tab":
        this._slash.choose();
        return true;
      case "Escape":
        this._dismissSlash();
        return true;
      default:
        return false;
    }
  }

  // User picked an item: erase the typed "/" from this block, close the menu,
  // and emit the bubbling/composed `bp-slash-insert` event. The server creates
  // the new block (default_block + insert-after) — this WC does NOT build it.
  //
  // An EXPECTED-group item carries a `fieldName`; we forward it so the server
  // builds a BOUND block (default_block + fieldName). A generic item has no
  // fieldName, so the detail omits it and the server takes the unchanged path.
  _chooseSlash(item) {
    this._closeSlash();
    // Remove the leading "/" so the trigger char never persists.
    this._editor.chain().focus().setTextSelection({ from: 1, to: 2 }).deleteSelection().run();

    const detail = { type: item.type, afterId: this._blockId };
    if (item.fieldName) detail.fieldName = item.fieldName;

    this.dispatchEvent(
      new CustomEvent("bp-slash-insert", {
        detail,
        bubbles: true,
        composed: true,
      }),
    );
  }

  // Esc / outside-click: close the menu but LEAVE the typed "/" in place — the
  // user may want to keep typing a real slash.
  _dismissSlash() {
    this._closeSlash();
    this._editor.commands.focus();
  }

  // Property setter so LiveView / a parent can assign `el.block = {...}` before
  // or after mount. Re-loads content into a live editor.
  set block(value) {
    this._blockProp = value;
    if (this._editor && value && typeof value === "object") {
      this._blockId = value.id != null ? value.id : this._blockId;
      this._blockType = value.type || this._blockType;
      this._editor.commands.setContent(blockToTiptap(value), false);
    }
  }

  get block() {
    return this._blockProp || this._readBlock();
  }
}

if (!customElements.get("bp-paper-editor")) {
  customElements.define("bp-paper-editor", BpPaperEditor);
}

export { BpPaperEditor };
