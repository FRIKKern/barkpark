// bp-paper-editor — premium per-block rich-text editor (Barkpark papers, P1.1).
//
// Architecture (Option 2): LiveView owns the block list; EACH rich-text block
// is edited by its OWN TipTap-vanilla instance. On edit, this Web Component
// emits a `patch-block` DocPatchOp for that one block via a bubbling
// CustomEvent("bp-op"). It does NOT build one giant ProseMirror document.
// The explicit data-editor-mode="card-body" variant emits the narrower
// `patch-card-body` intent so the server can merge authored inline content into
// the authoritative Card without a stale whole-slots replacement.
//
// Engine: TipTap-vanilla (@tiptap/core, no React), bundled by esbuild into a
// single committed IIFE artifact at priv/static/assets/bp-paper-editor.bundle.js
// — the same vendoring pattern as the other bp-* components.
//
// P1 scope: premium typing + inline marks (bold/italic/strike/code via
// TipTap's built-in keyboard shortcuts) + heading/list block types + the
// patch-block round-trip. Slash menu, floating toolbar, drag-reorder, and
// new/delete-block are LATER units.

import { Editor, Extension, Mark } from "@tiptap/core";
import { Plugin } from "@tiptap/pm/state";
import StarterKit from "@tiptap/starter-kit";
import { ListItemSource } from "./list-item-source.js";
import { HeadingSource } from "./heading-source.js";
import { ParagraphSource } from "./paragraph-source.js";
import { portableTextBoundary } from "./portable-text-boundary.js";
import { PortableLink as Link } from "./link-mark.js";
import Placeholder from "@tiptap/extension-placeholder";
import Typography from "@tiptap/extension-typography";

import {
  blockToTiptap,
  cardBodyProjection,
  cardBodyTiptapDocSupported,
  cardBodyContentMatches,
  buildCardBodyOp,
  tableProjection,
} from "./convert.js";
import { BpTable, BpTableRow, BpTableCell, BpTableHeaderCell } from "./canvas/table-node.js";
import { FormatBubble } from "./format-bubble.js";
import { paperEditorRuntimeMethods } from "./paper-editor-runtime.js";
import { paperEditorAutocompleteMethods } from "./paper-editor-autocomplete.js";
// Internal-link marks (wikilink/blockref/tag) — schema registration only, so
// the editor holds these nodes through a setContent->getJSON round-trip. Defined
// in the DOM-free marks.js so the smoke harness can assert their schema.
import { Wikilink, Blockref, Tag, Valueref, InlineOpaque } from "./marks.js";
import { BUILD_SHA, CONTRACT_VERSION, DEBOUNCE_MS, EDITOR_VERSION, PLACEHOLDER } from "./contract.js";
import { OpaqueMark } from "./opaque-mark.js";
import "./canvas/index.js";

const TableUnderline = Mark.create({
  name: "underline",
  parseHTML() {
    return [{ tag: "u" }];
  },
  renderHTML() {
    return ["u", 0];
  },
});

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

// Destroys the editor of an element that has left the page (not merely
// moved: see `disconnectedCallback`). A function, not a method, so the
// element's prototype stays the pinned boundary.
function teardown(el) {
  if (el._debounceTimer) {
    clearTimeout(el._debounceTimer);
    el._debounceTimer = null;
  }
  if (el._slash) {
    el._slash.destroy();
    el._slash = null;
  }
  if (el._wikilink) {
    el._wikilink.destroy();
    el._wikilink = null;
  }
  if (el._tag) {
    el._tag.destroy();
    el._tag = null;
  }
  if (el._bubble) {
    el._bubble.destroy();
    el._bubble = null;
  }
  if (el._editor) {
    el._editor.destroy();
    el._editor = null;
  }
  if (el._mount) {
    el._mount.remove();
    el._mount = null;
  }
  if (el._tableEditStatus) {
    el._tableEditStatus.remove();
    el._tableEditStatus = null;
  }
  el._settleTableLifecycle(false);
}

class BpPaperEditor extends HTMLElement {
  static CONTRACT_VERSION = CONTRACT_VERSION;
  static EDITOR_VERSION = EDITOR_VERSION;
  static BUILD_SHA = BUILD_SHA;

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
    this._sourceBlock = null;
    this._cardBodyEditable = true;
    this._cardBodyDraftJSON = null;
    this._cardBodyAwaitingContents = [];
    this._cardBodyDirtyToken = null;
    this._cardBodySourceError = false;
    this._tableEditable = true;
    this._tableDraftJSON = null;
    this._tableDirtyToken = null;
    this._tableAwaitingCells = [];
    this._tablePendingAction = null;
    this._tableStructureAwaiting = null;
    this._tableRefocusNewRow = false;
    this._tableSettlement = null;
    this._tableSourceError = false;
    this._tableEditStatus = null;
    this._tableAcceptedUpdate = false;
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
    this._editorMode = this.getAttribute("data-editor-mode") || "block";
    if (this._editorMode === "card-body") {
      this._sourceBlock = JSON.parse(JSON.stringify(block));
      this._cardBodyEditable = cardBodyProjection(block).editable;
      this._editable = this._editable && this._cardBodyEditable;
    } else if (this._editorMode === "table") {
      this._sourceBlock = JSON.parse(JSON.stringify(block));
      this._tableEditable = tableProjection(block).editable;
      this._editable = this._editable && this._tableEditable && !this._tableStructureAwaiting;
    }
    this._blockId = block && block.id != null ? block.id : null;
    this._blockType = (block && block.type) || "paragraph";

    // The contenteditable element the WC owns. TipTap mounts onto it.
    this._mount = document.createElement("div");
    this._mount.className = "bp-paper-editor-body";
    this.appendChild(this._mount);
    if (this._editorMode === "table") {
      this._tableEditStatus = document.createElement("p");
      this._tableEditStatus.className = "bp-paper-table-edit-status";
      this._tableEditStatus.dataset.tableEditStatus = "";
      this._tableEditStatus.setAttribute("role", "status");
      this._tableEditStatus.setAttribute("aria-live", "polite");
      this._tableEditStatus.setAttribute("aria-atomic", "true");
      this._tableEditStatus.hidden = true;
      this.appendChild(this._tableEditStatus);
    }

    this._editor = new Editor({
      element: this._mount,
      // Read mode (editable:false) gives a non-editing, correctly-styled render
      // and suppresses onUpdate-driven typing, so no bp-op/slash ever fires.
      editable: this._editable,
      extensions: [
      ListItemSource,
      HeadingSource,
        ...(this._editorMode === "block" && this._blockType === "paragraph" ? [ParagraphSource] : []),
        portableTextBoundary(this, () => this._editorMode === "block" ? this._blockType : null),
        ...(this._editorMode === "card-body" ? [
          Extension.create({
            name: "bpCardBodyVeto",
            addProseMirrorPlugins: () => [
              new Plugin({
                filterTransaction: (tr) => cardBodyTiptapDocSupported(tr.doc.toJSON()),
              }),
            ],
          }),
        ] : this._editorMode === "table" ? [
          Extension.create({
            name: "bpContextualTableVeto",
            addProseMirrorPlugins: () => [
              new Plugin({
                filterTransaction: (tr) => this._filterTableTransaction(tr),
              }),
            ],
          }),
          BpTable,
          BpTableRow,
          BpTableCell,
          BpTableHeaderCell,
        ] : []),
        StarterKit.configure({
          // Single-block editing: heading levels 1–6, lists, history on.
          heading: { levels: [1, 2, 3, 4, 5, 6] },
          // PortableDoc quotes use their own inline carrier. The native nested
          // quote cannot round-trip and consumes `> ` before callout shorthand.
          blockquote: false,
          // tiptap 3 folded Link, Underline, ListKeymap and TrailingNode into
          // StarterKit. Link is configured below; underline belongs only to the
          // table mode (TableUnderline); the other two would change keyboard
          // behaviour and append an empty paragraph to every block.
          link: false,
          underline: false,
          listKeymap: false,
          trailingNode: false,
          // Marks/nodes left enabled by StarterKit: paragraph, bold, italic,
          // strike, code, bulletList, orderedList, listItem, undoRedo.
        }),
        ...(this._editorMode === "table" ? [TableUnderline] : []),
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
            const hint = PLACEHOLDER[this._blockType];
            return typeof hint === "string" ? hint : PLACEHOLDER.paragraph;
          },
        }),
        // Smart typography (— for --, “ ” for quotes, … for ...) — parity with
        // the PortableDoc editor's @tiptap/extension-typography. This WC only
        // ever hosts prose blocks (paragraph/heading/list — see convert.js), so
        // there is no code block to exclude.
        Typography,
        // A stored flat mark with no editor (smallcaps, annotations) — carried verbatim.
        OpaqueMark,
        // Internal-link marks — schema registration only (see top of file).
        Wikilink,
        Blockref,
        Tag,
        Valueref,
        InlineOpaque,
      ],
      content: this._editorMode === "card-body"
        ? cardBodyProjection(block).doc
        : this._editorMode === "table" ? tableProjection(block).doc : blockToTiptap(block),
      editorProps: {
        // While the slash menu is open it OWNS the navigation keys (↑/↓/Enter/
        // Esc/Tab) — return true so ProseMirror does not also act on them.
        // When closed, every keystroke falls through to TipTap unchanged, so
        // the existing marks/typing round-trip is untouched.
        handleKeyDown: (_view, event) => this._onKeyDown(event),
      },
      onUpdate: () => {
        if (this._editorMode === "card-body") {
          const dirty = { token: null };
          this.dispatchEvent(new CustomEvent("bp-local-change", {
            detail: dirty,
            bubbles: true,
            composed: true,
          }));
          this._cardBodyDirtyToken = dirty.token;
          this._cardBodyDraftJSON = JSON.parse(JSON.stringify(this._editor.getJSON()));
        } else if (this._editorMode === "table") {
          if (!this._tableAcceptedUpdate) {
            if (this._bubble) this._bubble.update();
            return;
          }
          this._tableAcceptedUpdate = false;
          const dirty = { token: null };
          this.dispatchEvent(new CustomEvent("bp-local-change", {
            detail: dirty,
            bubbles: true,
            composed: true,
          }));
          this._tableDirtyToken = dirty.token;
          this._tableDraftJSON = JSON.parse(JSON.stringify(this._editor.getJSON()));
        }
        this._scheduleEmit();
        if (this._editorMode === "card-body" || this._editorMode === "table") {
          if (this._bubble) this._bubble.update();
          return;
        }
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
      this._editable = val !== "false" &&
        (this._editorMode !== "card-body" || this._cardBodyEditable) &&
        (this._editorMode !== "table" ||
          (this._tableEditable && !this._tableStructureAwaiting));
      if (this._editor) {
        // Card BODY editability is server-owned chrome. TipTap emits onUpdate
        // from setEditable unless told otherwise, which would manufacture a
        // dirty body draft from a read-only toggle.
        this._editor.setEditable(
          this._editable,
          this._editorMode !== "card-body" && this._editorMode !== "table",
        );
      }
    }
  }

  // A move in the page (morphdom appends a moved node again: the narrow
  // width bucket moves the pane) disconnects and connects the element in one
  // task. Tearing the editor down then re-mounted it from `data-block`, which
  // sits frozen inside phx-update="ignore": the editor showed the block as
  // first drawn, and the next key saved that over the stored text
  // (task-fe3f7a8fbe7a7858). So the teardown waits a microtask, and an
  // element that is back in the page by then keeps its live editor and its
  // pending edit.
  disconnectedCallback() {
    queueMicrotask(() => {
      if (!this.isConnected) teardown(this);
    });
  }

  flushPendingChanges() {
    return paperEditorRuntimeMethods.flushPendingChanges.call(this);
  }

  focusSelection() {
    return paperEditorRuntimeMethods.focusSelection.call(this);
  }

  hasPendingChanges() {
    return paperEditorRuntimeMethods.hasPendingChanges.call(this);
  }

  _filterTableTransaction(transaction) {
    return paperEditorRuntimeMethods._filterTableTransaction.call(this, transaction);
  }

  _reportTableEditRefusal() {
    return paperEditorRuntimeMethods._reportTableEditRefusal.call(this);
  }

  _clearTableEditRefusal() {
    return paperEditorRuntimeMethods._clearTableEditRefusal.call(this);
  }

  _installTableProjectionDoc(doc) {
    return paperEditorRuntimeMethods._installTableProjectionDoc.call(this, doc);
  }

  resolveConflictWithServerBlock(block) {
    return paperEditorRuntimeMethods.resolveConflictWithServerBlock.call(this, block);
  }

  _readBlock() {
    return paperEditorRuntimeMethods._readBlock.call(this);
  }

  _scheduleEmit() {
    return paperEditorRuntimeMethods._scheduleEmit.call(this);
  }

  _emitOp() {
    return paperEditorRuntimeMethods._emitOp.call(this);
  }

  _requestTableStructure(action) {
    return paperEditorRuntimeMethods._requestTableStructure.call(this, action);
  }

  _emitTableStructure() {
    return paperEditorRuntimeMethods._emitTableStructure.call(this);
  }

  waitForTableSettlement() {
    return paperEditorRuntimeMethods.waitForTableSettlement.call(this);
  }

  trackTableMutation(op, requestId) {
    return paperEditorRuntimeMethods.trackTableMutation.call(this, op, requestId);
  }

  tableMutationResult(op, saved, result) {
    return paperEditorRuntimeMethods.tableMutationResult.call(this, op, saved, result);
  }

  applyTableProjection(value, metadata = {}) {
    return paperEditorRuntimeMethods.applyTableProjection.call(this, value, metadata);
  }

  _acceptTableStructureEcho() {
    return paperEditorRuntimeMethods._acceptTableStructureEcho.call(this);
  }

  _focusLastRowFirstCell() {
    return paperEditorRuntimeMethods._focusLastRowFirstCell.call(this);
  }

  _ensureTableSettlement() {
    return paperEditorRuntimeMethods._ensureTableSettlement.call(this);
  }

  _settleTableLifecycle(result) {
    return paperEditorRuntimeMethods._settleTableLifecycle.call(this, result);
  }

  _validTableAction(action) {
    return paperEditorRuntimeMethods._validTableAction.call(this, action);
  }

  _maybeSlash() {
    return paperEditorAutocompleteMethods._maybeSlash.call(this);
  }

  _maybeCalloutShorthand() {
    return paperEditorAutocompleteMethods._maybeCalloutShorthand.call(this);
  }

  _openSlash(query = "") {
    return paperEditorAutocompleteMethods._openSlash.call(this, query);
  }

  _closeSlash() {
    return paperEditorAutocompleteMethods._closeSlash.call(this);
  }

  _caretRect() {
    return paperEditorAutocompleteMethods._caretRect.call(this);
  }

  _onKeyDown(event) {
    return paperEditorAutocompleteMethods._onKeyDown.call(this, event);
  }

  _chooseSlash(item) {
    return paperEditorAutocompleteMethods._chooseSlash.call(this, item);
  }

  _emitSlashInsert(detail) {
    return paperEditorAutocompleteMethods._emitSlashInsert.call(this, detail);
  }

  _dismissSlash() {
    return paperEditorAutocompleteMethods._dismissSlash.call(this);
  }

  _maybeWikilink() {
    return paperEditorAutocompleteMethods._maybeWikilink.call(this);
  }

  _openWikilink(rect, query = "") {
    return paperEditorAutocompleteMethods._openWikilink.call(this, rect, query);
  }

  _closeWikilink() {
    return paperEditorAutocompleteMethods._closeWikilink.call(this);
  }

  _chooseWikilink(candidate) {
    return paperEditorAutocompleteMethods._chooseWikilink.call(this, candidate);
  }

  _dismissWikilink() {
    return paperEditorAutocompleteMethods._dismissWikilink.call(this);
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

  _maybeTag() {
    return paperEditorAutocompleteMethods._maybeTag.call(this);
  }

  _openTag(rect, query = "") {
    return paperEditorAutocompleteMethods._openTag.call(this, rect, query);
  }

  _closeTag() {
    return paperEditorAutocompleteMethods._closeTag.call(this);
  }

  _chooseTag(candidate) {
    return paperEditorAutocompleteMethods._chooseTag.call(this, candidate);
  }

  _dismissTag() {
    return paperEditorAutocompleteMethods._dismissTag.call(this);
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
    if (this._editor && this._editorMode === "table") {
      this.applyTableProjection(value);
      return;
    }
    this._blockProp = value;
    if (this._editor && value && typeof value === "object") {
      this._blockId = value.id != null ? value.id : this._blockId;
      this._blockType = value.type || this._blockType;
      if (this._editorMode === "card-body") {
        const projection = cardBodyProjection(value);
        this._cardBodyEditable = projection.editable;
        // TipTap 2.27 emits an update from setEditable by default. A server
        // projection changing only editability must never become a local body
        // draft, so suppress that synthetic update explicitly.
        this._editor.setEditable(
          this.getAttribute("editable") !== "false" && projection.editable,
          false,
        );
        if (!projection.editable) {
          if (!this._cardBodySourceError) {
            this._cardBodySourceError = true;
            this.dispatchEvent(new CustomEvent("bp-error", {
              detail: {
                code: "card_body_source_unsupported",
                error: "Card body changed to an unsupported shape. Your draft is retained; resolve the server version before continuing.",
              },
              bubbles: true,
              composed: true,
            }));
          }
          if (this._discardCardBodyDraft) {
            this._sourceBlock = JSON.parse(JSON.stringify(value));
            this._editor.commands.setContent(projection.doc, { emitUpdate: false });
          }
          return;
        }
        this._cardBodySourceError = false;
        this._sourceBlock = JSON.parse(JSON.stringify(value));
        // Body mutations are FIFO. Retire only the head: a concurrent chrome
        // echo can legitimately carry content equal to a later compensating
        // snapshot (A→B→A) and must not skip the still-unconfirmed B entry.
        if (this._cardBodyAwaitingContents.length > 0 &&
            cardBodyContentMatches(this._cardBodyAwaitingContents[0], value)) {
          this._cardBodyAwaitingContents.shift();
        }
        const preservesDraft = projection.editable && this._cardBodyDraftJSON &&
          (buildCardBodyOp(this._cardBodyDraftJSON, value) !== null ||
            this._cardBodyAwaitingContents.length > 0);
        if (!preservesDraft) {
          this._cardBodyDraftJSON = null;
          this._cardBodyDirtyToken = null;
          this._editor.commands.setContent(projection.doc, { emitUpdate: false });
        }
      } else {
        this._editor.commands.setContent(blockToTiptap(value), { emitUpdate: false });
      }
    }
  }

  get block() {
    return this._blockProp || this._readBlock();
  }

  _acceptTableProjection(value) {
    return paperEditorRuntimeMethods._acceptTableProjection.call(this, value);
  }

}

if (!customElements.get("bp-paper-editor")) {
  customElements.define("bp-paper-editor", BpPaperEditor);
}

export { BpPaperEditor, CONTRACT_VERSION, DEBOUNCE_MS, PLACEHOLDER };
