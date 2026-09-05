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
import { WikilinkMenu } from "./wikilink-menu.js";
import {
  parseOpenWikilink,
  wikilinkReplaceRange,
  parseOpenTag,
  tagReplaceRange,
} from "./wikilink-trigger.js";
import { FormatBubble } from "./format-bubble.js";
import { normalizeTone } from "./tone.js";
// Internal-link marks (wikilink/blockref/tag) — schema registration only, so
// the editor holds these nodes through a setContent->getJSON round-trip. Defined
// in the DOM-free marks.js so the smoke harness can assert their schema.
import { Wikilink, Blockref, Tag, Valueref } from "./marks.js";
import { CONTRACT_VERSION, DEBOUNCE_MS, PLACEHOLDER } from "./contract.js";
import "./canvas/index.js";

// One-shot, id-guarded self-inject of the standalone stylesheet so a bare
// embedder (no Studio inline rules) renders the editor STYLED. Gated by
// window.BP_PAPER_EDITOR_NO_INJECT: Studio keeps its own inline
// .bp-paper-surface rules and sets this flag true to opt OUT — avoiding a
// double-CSS / specificity clash. Other hosts leave it unset. The <link>
// points at the esbuild-emitted bp-paper-editor.css that ships beside the
// bundle in priv/static/assets/.
function ensureStyles() {
  if (typeof window !== "undefined" && window.BP_PAPER_EDITOR_NO_INJECT) return;
  if (typeof document === "undefined") return;
  if (document.getElementById("bp-paper-editor-styles")) return;
  const link = document.createElement("link");
  link.id = "bp-paper-editor-styles";
  link.rel = "stylesheet";
  link.href = "/assets/bp-paper-editor.css";
  (document.head || document.documentElement).appendChild(link);
}

class BpPaperEditor extends HTMLElement {
  static CONTRACT_VERSION = CONTRACT_VERSION;

  // Observe `editable` so post-mount toggles route through attributeChangedCallback.
  static get observedAttributes() {
    return ["editable"];
  }

  constructor() {
    super();
    this._editor = null;
    this._mount = null;
    this._blockId = null;
    this._blockType = "paragraph";
    this._debounceTimer = null;
    this._slash = null; // SlashMenu instance (lazy, created on first trigger)
    this._bubble = null; // FormatBubble instance (selection format toolbar)
    // `[[` wikilink autocomplete (Studio-only — see set wikilinkSource below).
    this._wikilink = null; // WikilinkMenu instance (lazy, created on first trigger)
    this._wlSeq = 0; // monotonic open/query counter — stale async-result guard
    this._wikilinkSource = null; // injected async (query) => [{ title, id, type }]
    this._wlRange = null; // { from, to } PM range to replace on the current pick
    // `#` tag autocomplete (Studio-only — see set tagSource below). Mirrors the
    // wikilink popup exactly; REUSES WikilinkMenu via a { title, id, type } adapter.
    this._tag = null; // WikilinkMenu instance reused for tags (lazy)
    this._tagSeq = 0; // monotonic open/query counter — stale async-result guard
    this._tagSource = null; // injected async (query) => [ "design", "obsidian", … ]
    this._tagRange = null; // { from, to } PM range to replace on the current pick
    // Read-mode flag. Defaults TRUE (current edit behavior). Only the literal
    // attribute value editable="false" disables editing — a presence-boolean
    // can't express default-true, hence the by-value convention.
    this._editable = true;
  }

  connectedCallback() {
    if (this._editor) return; // double-mount guard

    ensureStyles();

    // Upgrade-safe property reclaim: a host may set `el.wikilinkSource = …` or
    // `el.block = …` BEFORE the custom-element definition upgrades this node. In
    // that window the assignment lands as a plain own-property that would shadow
    // the prototype accessor once it exists. Delete + re-assign each so the
    // value flows back through the real setter.
    this._upgradeProperty("wikilinkSource");
    this._upgradeProperty("tagSource");
    this._upgradeProperty("block");

    // Default true; only the literal string "false" disables. This mount-time
    // read is authoritative — attributeChangedCallback only handles later toggles.
    this._editable = this.getAttribute("editable") !== "false";

    const block = this._readBlock();
    this._blockId = block && block.id != null ? block.id : null;
    this._blockType = (block && block.type) || "paragraph";

    // The contenteditable element the WC owns. TipTap mounts onto it.
    this._mount = document.createElement("div");
    this._mount.className = "bp-paper-editor-body";
    this.appendChild(this._mount);

    this._editor = new Editor({
      element: this._mount,
      // Read mode (editable:false) gives a non-editing, correctly-styled render
      // and suppresses onUpdate-driven typing, so no bp-op/slash ever fires.
      editable: this._editable,
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
              return PLACEHOLDER.heading(node.attrs && node.attrs.level);
            }
            return PLACEHOLDER.paragraph;
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
        Valueref,
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
        if (!consumed) {
          // `[[` wikilink, `#` tag, and leading `/` slash are mutually exclusive
          // popups — AT MOST ONE opens per mutation. Chain by priority: run the
          // wikilink detector first; if it did NOT open, run the tag detector; if
          // NEITHER opened, run the slash detector. Whichever opens forces the
          // others shut so a stale popup never lingers. The triggers are already
          // disjoint by leading token ("[[" vs "#" vs "/"), but the gate makes
          // the single-popup invariant code-enforced rather than incidental.
          if (this._maybeWikilink()) {
            this._closeTag();
            this._closeSlash();
          } else if (this._maybeTag()) {
            this._closeSlash();
          } else {
            this._maybeSlash();
          }
        }
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
    // Skipped in read mode; every downstream consumer is `if (this._bubble)` guarded.
    if (this._editable) {
      this._bubble = new FormatBubble({ editor: this._editor });
    }
    // Lifecycle: one-shot bubbling/composed signal a host hook can await
    // (LiveView ignores unknown events → additive, zero regression).
    this.dispatchEvent(
      new CustomEvent("bp-ready", {
        detail: {
          blockId: this._blockId,
          blockType: this._blockType,
          contractVersion: BpPaperEditor.CONTRACT_VERSION,
        },
        bubbles: true,
        composed: true,
      }),
    );
  }

  // Live editable toggling (post-mount). Guarded against the spec'd ordering
  // quirk where this fires before connectedCallback for initial attributes —
  // in that case this._editor is null and we no-op; connectedCallback's read
  // is authoritative at mount.
  attributeChangedCallback(name, _old, val) {
    if (name === "editable") {
      this._editable = val !== "false";
      if (this._editor) this._editor.setEditable(this._editable);
    }
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
    if (this._wikilink) {
      this._wikilink.destroy();
      this._wikilink = null;
    }
    if (this._tag) {
      this._tag.destroy();
      this._tag = null;
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

  // Synchronously emit the debounced patch, if one is pending. Returns true only
  // when this call dispatched bp-op; repeated calls are therefore safe while the
  // server acknowledgement is still in flight.
  flushPendingChanges() {
    if (!this._editor || !this._editable || !this._debounceTimer) return false;
    clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    return this._emitOp();
  }

  // Synchronous host seam for navigation / beforeunload guards. The editor is
  // dirty as soon as its debounce exists, before bp-op has been dispatched.
  hasPendingChanges() {
    return Boolean(this._debounceTimer);
  }

  // Explicit conflict resolution seam. The host calls this only after the user
  // chooses "Use latest"; unlike a normal server echo it intentionally discards
  // the pending local debounce before installing the authoritative block.
  resolveConflictWithServerBlock(block) {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    this.block = block;
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
        // Surface bad inbound data to the host (additive); the silent default
        // below is preserved so a malformed data-block never blocks the editor.
        this.dispatchEvent(
          new CustomEvent("bp-error", {
            detail: { error: _e.message, raw },
            bubbles: true,
            composed: true,
          }),
        );
        // fall through to a default empty paragraph
      }
    }
    return { id: null, type: "paragraph", content: [] };
  }

  _scheduleEmit() {
    if (!this._editable) return; // read mode emits no patch-block op
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = setTimeout(() => {
      this._debounceTimer = null;
      this._emitOp();
    }, DEBOUNCE_MS);
  }

  _emitOp() {
    if (!this._editor || this._blockId == null) return false;
    const json = this._editor.getJSON();
    const op = buildPatchBlockOp(json, this._blockId, this._blockType);
    this.dispatchEvent(
      new CustomEvent("bp-op", {
        detail: op,
        bubbles: true,
        composed: true,
      }),
    );
    return true;
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
    if (!this._editable) return; // read mode: no slash menu, no bp-slash-insert
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

  // Keyboard handler installed via editorProps.handleKeyDown. Only ACTS when a
  // popup is open; otherwise returns false so TipTap handles the key. The
  // wikilink menu is checked FIRST — the two popups are mutually exclusive, so
  // at most one branch ever owns the keystroke.
  _onKeyDown(event) {
    if (this._wikilink && this._wikilink.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._wikilink.move(1);
          return true;
        case "ArrowUp":
          this._wikilink.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._wikilink.choose();
          return true;
        case "Escape":
          this._dismissWikilink();
          return true;
        default:
          return false;
      }
    }

    // `#` tag menu owns the nav keys while open — same contract as the wikilink
    // branch above. The two are mutually exclusive (only one ever open), so the
    // order here is immaterial, but tag follows wikilink for symmetry.
    if (this._tag && this._tag.isOpen()) {
      switch (event.key) {
        case "ArrowDown":
          this._tag.move(1);
          return true;
        case "ArrowUp":
          this._tag.move(-1);
          return true;
        case "Enter":
        case "Tab":
          this._tag.choose();
          return true;
        case "Escape":
          this._dismissTag();
          return true;
        default:
          return false;
      }
    }

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

  // ── `[[` wikilink autocomplete ─────────────────────────────────────────
  //
  // Obsidian-parity inline page-link picker. Studio-only by construction: it
  // is gated on `this._editable` (read-mode embeds never run onUpdate) AND on
  // an injected `this._wikilinkSource` (unset → the popup never opens). On each
  // onUpdate we re-run the PURE parseOpenWikilink seam against the block-local
  // text + caret offset; an open trigger opens/refreshes the menu at the caret
  // and fires the async source. The result list is server-scoped and rendered
  // verbatim (no local filtering). On a pick we replace the typed "[[query"
  // span with the chosen title carrying a `wikilink` mark — no literal brackets
  // remain in the document.
  //
  // Returns true iff the menu is (now) open, so onUpdate can force the slash
  // menu shut and skip _maybeSlash (mutual exclusion).
  _maybeWikilink() {
    if (!this._editable || !this._wikilinkSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame. `$from.parent`
    // is the current textblock (a paragraph — including the one nested inside a
    // list item), so its `textContent` pairs exactly with `parentOffset`. Using
    // `getText()` here would join EVERY textblock with "\n\n" and desync from the
    // block-local `parentOffset`, so a `[[` typed in the 2nd-or-later list item
    // would never open the popup. parseOpenWikilink's contract is block-local text.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = $from.parent.textContent;
    const caretOffset = $from.parentOffset;
    const hit = parseOpenWikilink(blockLocalText, caretOffset);
    if (!hit) {
      this._closeWikilink();
      return false;
    }

    // Open (or refresh, as the query grows) the popup at the live caret rect,
    // and remember the PM range to replace on pick — anchored to the DOCUMENT
    // position (selection.from), not the block-local offset hit carries.
    this._openWikilink(this._caretRect(), hit.query);
    this._wlRange = wikilinkReplaceRange(this._editor.state.selection.from, hit.query);

    // Async source with a STALE GUARD: each open/keystroke bumps _wlSeq; a
    // resolved batch is dropped unless it is still the latest request AND the
    // menu is still open — so an out-of-order or post-close response is ignored.
    const seq = ++this._wlSeq;
    Promise.resolve(this._wikilinkSource(hit.query))
      .then((list) => {
        if (seq !== this._wlSeq || !this._wikilink || !this._wikilink.isOpen()) {
          return;
        }
        this._wikilink.setResults(Array.isArray(list) ? list : []);
      })
      .catch(() => {});
    return true;
  }

  _openWikilink(rect, query = "") {
    if (!this._wikilink) {
      this._wikilink = new WikilinkMenu({
        onChoose: (c) => this._chooseWikilink(c),
        onDismiss: () => this._dismissWikilink(),
      });
    }
    this._wikilink.open(rect, query);
  }

  _closeWikilink() {
    if (this._wikilink && this._wikilink.isOpen()) this._wikilink.close();
  }

  // User picked a candidate: replace the typed "[[query" span with the chosen
  // title carrying a `wikilink` mark { target: title, docId: id }, plus a
  // trailing UNMARKED space so typing continues OUTSIDE the link (the mark is
  // inclusive:false, but the space guarantees it across browsers). The pinned
  // `docId` is the picked paper's EXACT id — render resolves to that doc, closing
  // the title-collision hole (a typed-not-picked wikilink carries no docId and
  // keeps the existing lower(title) resolution). _wlRange was captured in
  // _maybeWikilink at the moment the menu opened/refreshed.
  _chooseWikilink(candidate) {
    const range = this._wlRange;
    if (!range) {
      this._closeWikilink();
      return;
    }
    this._editor
      .chain()
      .focus()
      .insertContentAt({ from: range.from, to: range.to }, [
        {
          type: "text",
          text: candidate.title,
          marks: [{ type: "wikilink", attrs: { target: candidate.title, docId: candidate.id } }],
        },
        { type: "text", text: " " },
      ])
      .run();
    this._closeWikilink();
  }

  // Esc / outside-click: close the menu but LEAVE the typed "[[query" in place —
  // the user may want to keep editing it. Mirrors _dismissSlash.
  _dismissWikilink() {
    this._closeWikilink();
    this._editor.commands.focus();
  }

  // Writable property so the Studio LiveView hook can inject the async page
  // search: `el.wikilinkSource = (query) => Promise<[{ title, id, type }]>`.
  // Unset → _maybeWikilink early-returns, so the popup NEVER opens (graceful
  // no-op for the standalone embedder and the read-mode web embed).
  set wikilinkSource(fn) {
    this._wikilinkSource = fn;
  }

  get wikilinkSource() {
    return this._wikilinkSource;
  }

  // ── `#` tag autocomplete ───────────────────────────────────────────────
  //
  // Obsidian-parity inline tag picker — the `#` analogue of the `[[` wikilink
  // popup, sharing the WikilinkMenu DOM via a thin adapter. Studio-only by
  // construction: gated on `this._editable` AND on an injected `this._tagSource`
  // (unset → never opens). On each onUpdate we re-run the PURE parseOpenTag seam
  // (block-local text + caret offset); an open trigger opens/refreshes the menu
  // at the caret and fires the async source. The string[] of tag names is mapped
  // to WikilinkMenu's { title, id, type } row shape — "#"+name as the visible
  // title, the bare name as the id we map back on pick. On a pick we replace the
  // typed "#query" span with "#"+name carrying a `tag` mark { name }.
  //
  // Returns true iff the menu is (now) open, so onUpdate's mutual-exclusion chain
  // can force the slash menu shut and skip _maybeSlash.
  _maybeTag() {
    if (!this._editable || !this._tagSource) return false;
    if (!this._editor) return false;

    // Block-LOCAL text + offset must share one coordinate frame — identical
    // rationale to _maybeWikilink: `$from.parent.textContent` pairs exactly with
    // `parentOffset`, so a `#` typed in the 2nd-or-later list item still opens.
    const $from = this._editor.state.selection.$from;
    const blockLocalText = $from.parent.textContent;
    const caretOffset = $from.parentOffset;
    const hit = parseOpenTag(blockLocalText, caretOffset);
    if (!hit) {
      this._closeTag();
      return false;
    }

    // Open (or refresh as the query grows) the popup at the live caret rect, and
    // remember the PM range to replace on pick — anchored to the DOCUMENT
    // position (selection.from), not the block-local offset hit carries.
    this._openTag(this._caretRect(), hit.query);
    this._tagRange = tagReplaceRange(this._editor.state.selection.from, hit.query);

    // Async source with a STALE GUARD (own _tagSeq, independent of _wlSeq): each
    // open/keystroke bumps the counter; a resolved batch is dropped unless it is
    // still the latest request AND the menu is still open. The source returns a
    // string[] of tag NAMES; adapt each to WikilinkMenu's row shape here.
    const seq = ++this._tagSeq;
    Promise.resolve(this._tagSource(hit.query))
      .then((list) => {
        if (seq !== this._tagSeq || !this._tag || !this._tag.isOpen()) {
          return;
        }
        const rows = (Array.isArray(list) ? list : []).map((name) => ({
          title: "#" + name,
          id: name,
          type: "tag",
        }));
        this._tag.setResults(rows);
      })
      .catch(() => {});
    return true;
  }

  _openTag(rect, query = "") {
    if (!this._tag) {
      this._tag = new WikilinkMenu({
        onChoose: (c) => this._chooseTag(c),
        onDismiss: () => this._dismissTag(),
      });
    }
    this._tag.open(rect, query);
  }

  _closeTag() {
    if (this._tag && this._tag.isOpen()) this._tag.close();
  }

  // User picked a tag: replace the typed "#query" span with "#"+name carrying a
  // `tag` mark { name }, plus a trailing UNMARKED space so typing continues
  // OUTSIDE the tag (mark is inclusive:false; the space guarantees it across
  // browsers). The candidate is a WikilinkMenu row whose `id` is the bare tag
  // name; map it back here. _tagRange was captured in _maybeTag when the menu
  // opened/refreshed. Mirrors _chooseWikilink.
  _chooseTag(candidate) {
    const range = this._tagRange;
    if (!range) {
      this._closeTag();
      return;
    }
    const name = candidate && candidate.id != null ? candidate.id : "";
    this._editor
      .chain()
      .focus()
      .insertContentAt({ from: range.from, to: range.to }, [
        {
          type: "text",
          text: "#" + name,
          marks: [{ type: "tag", attrs: { name } }],
        },
        { type: "text", text: " " },
      ])
      .run();
    this._closeTag();
  }

  // Esc / outside-click: close the menu but LEAVE the typed "#query" in place —
  // the user may want to keep editing it. Mirrors _dismissWikilink.
  _dismissTag() {
    this._closeTag();
    this._editor.commands.focus();
  }

  // Writable property so the Studio LiveView hook can inject the async tag
  // search: `el.tagSource = (query) => Promise<string[]>`. Unset → _maybeTag
  // early-returns, so the popup NEVER opens (graceful no-op for the standalone
  // embedder and the read-mode web embed). Mirrors wikilinkSource exactly.
  set tagSource(fn) {
    this._tagSource = fn;
  }

  get tagSource() {
    return this._tagSource;
  }

  // Upgrade-safe property reclaim (called from connectedCallback). If a value
  // was assigned to `name` before this element upgraded, it sits as an own
  // property shadowing the prototype accessor; delete it and re-assign so it
  // flows through the real setter.
  _upgradeProperty(name) {
    if (Object.prototype.hasOwnProperty.call(this, name)) {
      const value = this[name];
      delete this[name];
      this[name] = value;
    }
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

export { BpPaperEditor, CONTRACT_VERSION, DEBOUNCE_MS, PLACEHOLDER };
