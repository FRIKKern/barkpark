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

import { blockToTiptap, buildPatchBlockOp } from "./convert.js";

const DEBOUNCE_MS = 300;

class BpPaperEditor extends HTMLElement {
  constructor() {
    super();
    this._editor = null;
    this._mount = null;
    this._blockId = null;
    this._blockType = "paragraph";
    this._debounceTimer = null;
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
      ],
      content: blockToTiptap(block),
      onUpdate: () => this._scheduleEmit(),
    });
  }

  disconnectedCallback() {
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
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
