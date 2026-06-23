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
import Placeholder from "@tiptap/extension-placeholder";
import Typography from "@tiptap/extension-typography";

import { blockToTiptap, buildPatchBlockOp } from "./convert.js";
import { SlashMenu, SLASH_ITEMS } from "./slash-menu.js";
import { FormatBubble } from "./format-bubble.js";
import { normalizeTone } from "./tone.js";
// Internal-link marks (wikilink/blockref/tag) — schema registration only, so
// the editor holds these nodes through a setContent->getJSON round-trip. Defined
// in the DOM-free marks.js so the smoke harness can assert their schema.
import { Wikilink, Blockref, Tag } from "./marks.js";

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
        // Empty-block ghost text — parity with the PortableDoc editor's
        // @tiptap/extension-placeholder. Each WC owns ONE block, so the hint
        // reflects this block's role; the focused empty block shows it. Paragraph
        // surfaces the "/" affordance; headings name their level.
        // includeChildren:false so a single placeholder shows on the top-level
        // textblock only (never doubled across a list-item's inner paragraph).
        Placeholder.configure({
          includeChildren: false,
          showOnlyWhenEditable: true,
          placeholder: ({ node }) => {
            if (node.type.name === "heading") {
              return `Heading ${(node.attrs && node.attrs.level) || 1}`;
            }
            return "Start typing, or press / for blocks…";
          },
        }),
        // Smart typography (— for --, “ ” for quotes, … for ...) — parity with
        // the PortableDoc editor's @tiptap/extension-typography. This WC only
        // ever hosts prose blocks (paragraph/heading/list — see convert.js), so
        // there is no code block to exclude.
        Typography,
        // Internal-link marks — schema registration only (see top of file).
        Wikilink,
        Blockref,
        Tag,
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
        // Callout shorthand is mutually exclusive with the slash menu: it runs
        // FIRST and short-circuits _maybeSlash when it consumes the update, so
        // the two detectors can never both fire on one mutation. Their leading
        // tokens are already disjoint ('>' vs '/'), but the explicit `consumed`
        // gate makes the contract code-enforced, not incidental.
        const consumed = this._maybeCalloutShorthand();
        if (!consumed) this._maybeSlash();
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
  // the menu): the menu opens when the editor holds a single block whose text
  // STARTS with "/" and the caret sits at the end of that text — i.e. the user
  // typed "/" at the start of an otherwise-empty line and may keep typing a
  // query ("/head"). The substring after "/" is the live filter query, passed
  // to the menu so it narrows as you type — PortableDoc-editor parity. Text
  // that does NOT start with "/" (a slash mid-prose), a multi-line block, or a
  // non-collapsed selection all keep the menu closed.
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
    const startsSlash = text.length > 0 && text[0] === "/";
    const atEnd = selection.$from.parentOffset === text.length;
    const triggered =
      startsSlash && atEnd && !text.includes("\n") && doc.childCount <= 2;

    if (triggered) {
      this._openSlash(text.slice(1)); // query = everything after the leading "/"
    } else {
      this._closeSlash();
    }
  }

  // ── callout authoring shorthand ────────────────────────────────────────
  //
  // Obsidian-style `> [!type]` gesture: when the user types `> [!note] `,
  // `> [!warn]- `, or `> [!info]+ ` at the start of an otherwise-empty block,
  // turn it into a foldable callout (collapsed when the modifier is "-").
  // Mutually exclusive with _maybeSlash by leading token ('>' vs '/') AND by
  // the explicit `consumed` gate in onUpdate. Returns true iff it consumed the
  // update (origin block wiped + bp-slash-insert dispatched), false otherwise.
  //
  // Predicate parity with _maybeSlash: caret collapsed, caret at end, single
  // line, doc.childCount <= 2 — so it never fires mid-prose or across
  // multi-line / multi-block content. The trailing space in the regex is what
  // commits the gesture (so `> [!note]` alone keeps typing freely).
  _maybeCalloutShorthand() {
    if (!this._editor) return false;

    const { state } = this._editor;
    const { selection, doc } = state;

    // Caret only — never on a range selection.
    if (!selection.empty) return false;

    const text = this._editor.getText();
    const atEnd = selection.$from.parentOffset === text.length;
    if (!atEnd || text.includes("\n") || doc.childCount > 2) return false;

    // ^>\s*\[!(\w+)\]([+-]?)\s$ — the trailing \s (the committing space) plus the
    // no-newline guard above means \s only ever matches that space here.
    const m = /^>\s*\[!(\w+)\]([+-]?)\s$/.exec(text);
    if (!m) return false;

    const tone = normalizeTone(m[1]);
    const collapsed = m[2] === "-";
    this._emitSlashInsert({
      type: "callout",
      afterId: this._blockId,
      tone,
      collapsible: true,
      collapsed,
    });
    return true;
  }

  _openSlash(query = "") {
    if (!this._slash) {
      this._slash = new SlashMenu({
        items: SLASH_ITEMS,
        onChoose: (item) => this._chooseSlash(item),
        onDismiss: () => this._dismissSlash(),
      });
    }
    // Anchor the popup to the live caret rectangle. open() handles both the
    // first open and a re-open with a new filter query (as the user types).
    const rect = this._caretRect();
    this._slash.open(rect, query);
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
    const detail = { type: item.type, afterId: this._blockId };
    if (item.fieldName) detail.fieldName = item.fieldName;
    this._emitSlashInsert(detail);
  }

  // Shared teardown + dispatch for every slash-style insertion (menu pick AND
  // callout shorthand). Wipes the origin block so the trigger text never
  // persists into the now-empty origin paragraph, then emits the bubbling/
  // composed `bp-slash-insert` the LiveView hook forwards as `paper-slash-insert`.
  _emitSlashInsert(detail) {
    // Remove the ENTIRE typed trigger (not just its first char) so the trigger
    // text never persists in the now-empty origin block.
    this._editor.chain().focus().selectAll().deleteSelection().run();

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
