import { SlashMenu, readExpectedItems, readMasterItems } from "../slash-menu.js";
import { normalizeTone } from "../tone.js";
import { topLevelIndexAtSelection } from "./block-handle.js";
import { CANVAS_SLASH_CHORDS, CANVAS_SLASH_ITEMS } from "./canvas-menu-catalog.js";
import {
  CommandPalette,
  buildCommandRegistry,
  insertCompoundAtSelection,
  insertSectionPresetAtSelection,
  insertSlashTypeAtSelection,
} from "./command-palette.js";
import { insertInlineObject, openObjectBlockInsert } from "./inline-object.js";
import {
  CANVAS_SLASH_TYPES,
  canvasDefaultBlock,
  masterInsertAnchor,
  serverBuildsInsert,
  slashTriggerAllowsParent,
} from "./slash-insert.js";
import { parseVocabulary, quoteTypeFor, slashItemsForVocabulary } from "./vocabulary.js";
import { TextSelection } from "@tiptap/pm/state";

  // ── P4 `/` slash menu (canvas DIRECT-INSERT variant) ───────────────────────
  //
  // The per-block editor's _maybeSlash (../index.js ~327), adapted for the canvas.
  // SAME trigger rule — the menu opens when the CURRENT run block's text STARTS
  // with "/" and the caret sits at the end of it (the user typed "/" at the start
  // of an otherwise-empty line and may keep typing a query like "/head"). The
  // substring after "/" is the live filter query.
  //
  // KEY DIFFERENCE from the per-block editor: the trigger is BLOCK-LOCAL, not
  // whole-editor. The per-block editor hosts ONE block so getText() == that block's
  // text; the canvas hosts MANY, so getText() would join every run block with
  // "\n\n" and a "/" typed in the 2nd-or-later block would never open the menu.
  // We read `$from.parent.textContent` + `parentOffset` (the same block-local frame
  // _maybeWikilink / _maybeTag use), so a "/" opens the menu against THAT block.
  //
  // On a pick the canvas inserts the default NODE directly (see _chooseSlash) — it
  // does NOT dispatch bp-slash-insert (that is the per-block path, where the SERVER
  // builds the block). Text that does NOT start with "/" (a slash mid-prose), a
  // multi-block selection, or a non-collapsed selection all keep the menu closed.
  export function _maybeSlash() {
    if (!this._editable) return; // read mode: no slash menu
    if (!this._editor) return;

    const { selection } = this._editor.state;

    // Caret only — never on a range selection.
    if (!selection.empty) {
      this._closeSlash();
      return;
    }

    // Block-LOCAL text + offset (multi-block-doc-correct — see header). The block
    // is the current run block's textblock; a "/" only triggers when it is the
    // ENTIRE block text (text[0] === "/") and the caret is at its end.
    const $from = selection.$from;
    // TOP-LEVEL-PROSE-only guard: the caret must sit in a paragraph/heading that is a
    // DIRECT child of the doc — the only place a slash insert can replace the block
    // with a top-level node. depth === 1 alone is NOT enough: a CALLOUT BODY
    // (callout-node.js group:"block", content:"inline*") is ALSO a depth-1 top-level
    // node, so a "/head"+Enter typed INSIDE a callout body would pass a depth-only
    // guard and _chooseSlash's start=$pos.before(depth)/end=$pos.after(depth) would
    // span the WHOLE callout → replaceWith destroys the enclosing callout (chrome +
    // body). Requiring parent.type.name ∈ {paragraph, heading} excludes the callout
    // body (and any future inline-content node-view), and also keeps rejecting a
    // paragraph nested in a list item (depth 3). See slashTriggerAllowsParent.
    // Notion parity: "/" also works inside an otherwise-empty list item; the item is lifted
    // out of the list when a block is chosen (see _chooseSlash).
    if (!slashTriggerAllowsParent($from.depth, $from.parent.type.name) && !this._slashInListItem($from)) {
      this._closeSlash();
      return;
    }
    const blockText = $from.parent.textContent;
    const startsSlash = blockText.length > 0 && blockText[0] === "/";
    const atEnd = $from.parentOffset === blockText.length;
    const triggered = startsSlash && atEnd && !blockText.includes("\n");

    if (triggered) {
      this._openSlash(blockText.slice(1)); // query = everything after the leading "/"
    } else {
      this._closeSlash();
    }
  }

  // ── callout authoring shorthand (`> [!type]`) ──────────────────────────────
  //
  // Ported from ../index.js:_maybeCalloutShorthand (~358). Obsidian-style gesture:
  // when the user types `> [!note] `, `> [!warn]- `, or `> [!info]+ ` at the start
  // of an otherwise-empty run block, REPLACE that paragraph with a bpCallout node of
  // the matched tone (collapsed when the modifier is "-"). UNLIKE the per-block
  // editor (which wipes the origin block + dispatches bp-slash-insert for the SERVER
  // to build the callout), the canvas REPLACES the paragraph node in place with the
  // callout node — so runToOps emits ONE insert-after (the new callout) + the remove
  // of the origin para, and the S4a echo stamps the server id.
  //
  // Mutually exclusive with _maybeSlash by leading token ('>' vs '/') AND by the
  // explicit `consumed` gate in onUpdate. Returns true iff it consumed the update.
  //
  // Predicate parity with _maybeSlash: caret collapsed, caret at end, single line —
  // all evaluated BLOCK-LOCALLY (the multi-block canvas frame), so it never fires
  // mid-prose or across blocks. The trailing space in the regex commits the gesture.
  // Replace the caret's top-level block with an empty quote of `type` (blockquote, or
  // pullquote in a field that admits only that), keeping its id so the save is a
  // same-id replace-block, not remove + insert. The caret lands inside the quote.
  export function _replaceTopBlockWithQuote(type) {
    const { state, view } = this._editor;
    const $from = state.selection.$from;
    if ($from.depth < 1) return false;
    const start = $from.before(1);
    const end = $from.after(1);
    const nodeType = state.schema.nodes[type];
    if (!nodeType) return false;
    const quoteNode = nodeType.create({ bpId: $from.node(1).attrs.bpId || null, bpType: type });
    let tr = state.tr.replaceWith(start, end, quoteNode);
    try { tr = tr.setSelection(TextSelection.near(tr.doc.resolve(start + 1))); } catch (_e) {}
    view.dispatch(tr);
    this._editor.commands.focus();
    return true;
  }

export function _maybeBlockShorthand() {
    if (!this._editable || !this._editor) return false;
    const { selection } = this._editor.state;
    if (!selection.empty) return false;
    const $from = selection.$from;
    if ($from.parent.type.name !== "paragraph" || $from.depth !== 1) return false;
    const blockText = $from.parent.textContent;
    if ($from.parentOffset !== blockText.length) return false;
    // Typography turns the first two dashes into an en/em dash before the third arrives; accept both spellings.
    const divider = /^(---|—-|–-)$/.test(blockText);
    const code = /^```$/.test(blockText);
    const quote = /^>\s$/.test(blockText);
    if (quote) {
      // `> ` → the plain quote block (`blockquote`, what Notion and Tiptap authors mean by a
      // quote; the pullquote stays article chrome, reached from the slash menu). The callout
      // gesture `> [!note] ` still works: _maybeCalloutShorthand accepts `[!note] ` typed inside.
      // In a field whose vocabulary has the blockquote STYLE that block is a pullquote.
      return this._replaceTopBlockWithQuote(quoteTypeFor(parseVocabulary(this.getAttribute("data-vocabulary"))));
    }
    if (!divider && !code) return false;
    if (code) {
      // Clear the fence text, then reuse the slash-insert seam so the code atom takes the
      // caret exactly as it does from the menu (its own editing surface, not a PM text hole).
      const { state, view } = this._editor;
      view.dispatch(state.tr.delete($from.start(1), $from.end(1)));
      insertSlashTypeAtSelection(this._editor, "code");
      // The code atom edits in its own textarea island; hand it the caret at once so the very
      // next keystroke lands inside the block (a deferred focus would swallow fast typing).
      const focusArea = () => {
        if (!this._editor || this._editor.isDestroyed) return false;
        const dom = this._editor.view.nodeDOM(this._editor.state.selection.from);
        const area = dom && dom.querySelector ? dom.querySelector(".bp-canvas-code-area") : null;
        if (!area) return false;
        area.focus();
        return true;
      };
      if (!focusArea()) requestAnimationFrame(focusArea);
      return true;
    }
    const block = canvasDefaultBlock("divider");
    const node = this._rt([block]).content[0];
    const { state, view } = this._editor;
    const start = $from.before(1);
    const end = $from.after(1);
    const pmNode = state.schema.nodeFromJSON(node);
    let tr = state.tr.replaceWith(start, end, pmNode);
    const after = start + pmNode.nodeSize;
    tr = tr.insert(after, state.schema.nodes.paragraph.create());
    try { tr = tr.setSelection(TextSelection.near(tr.doc.resolve(after + 1))); } catch (_e) {}
    view.dispatch(tr);
    this._editor.commands.focus();
    return true;
  }

export function _maybeCalloutShorthand() {
    if (!this._editable) return false; // read mode: no shorthand
    if (!this._editor) return false;

    const { selection } = this._editor.state;

    // Caret only — never on a range selection.
    if (!selection.empty) return false;

    // Block-LOCAL text + offset (multi-block-doc-correct). The gesture only fires
    // when `> [!type] ` is the ENTIRE block text and the caret is at its end.
    const $from = selection.$from;
    // TOP-LEVEL-PROSE-only guard (same rationale as _maybeSlash): the `> [!type]`
    // gesture REPLACES the whole enclosing textblock (start=$pos.before(depth)/
    // end=$pos.after(depth)) with a top-level callout node, so it must only fire in a
    // paragraph/heading that is a DIRECT child of the doc. depth === 1 alone is NOT
    // enough — a CALLOUT BODY is also a depth-1 top-level node, so a `> [!warning] `
    // typed INSIDE a callout body would otherwise span + destroy the enclosing
    // callout. Requiring parent.type.name ∈ {paragraph, heading} excludes the callout
    // body, and still rejects a paragraph nested in a list item. See
    // slashTriggerAllowsParent.
    // `> ` has already become a quote block (the plain blockquote now; a pullquote when one
    // was authored from the menu), so the `[!note] ` that follows arrives inside it.
    const inQuote = $from.depth === 1 && ($from.parent.type.name === "blockquote" || $from.parent.type.name === "pullquote");
    if (!inQuote && !slashTriggerAllowsParent($from.depth, $from.parent.type.name)) return false;
    const blockText = $from.parent.textContent;
    const atEnd = $from.parentOffset === blockText.length;
    if (!atEnd || blockText.includes("\n")) return false;

    // ^>\s*\[!(\w+)\]([+-]?)\s$ — identical to the per-block editor. The trailing \s
    // (the committing space) + the no-newline guard above mean \s only matches that
    // space here. Inside a quote block (`> ` already consumed) the leading `>` is absent.
    const m = (inQuote ? /^\[!(\w+)\]([+-]?)\s$/ : /^>\s*\[!(\w+)\]([+-]?)\s$/).exec(blockText);
    if (!m) return false;

    const tone = normalizeTone(m[1]);
    const collapsed = m[2] === "-";

    // Build the default callout BLOCK (default_block("callout") shape) + the matched
    // tone, then carry collapsible/collapsed so the foldable gesture round-trips.
    // (calloutBlockToNode threads collapsible/collapsed only when === true, mirroring
    // the per-block bp-slash-insert which sends collapsible:true + collapsed.)
    const block = canvasDefaultBlock("callout");
    block.tone = tone;
    block.collapsible = true;
    block.collapsed = collapsed;
    const node = this._rt([block]).content[0];

    // REPLACE the whole current block (the just-typed `> [!type] ` paragraph) with
    // the callout node. selectParentNode targets the textblock; replaceSelectionWith
    // swaps the node. The new callout carries bpId:null → runToOps mints an id and
    // emits the structural ops; the origin para is gone (no stray trigger text).
    const { state, view } = this._editor;
    const $pos = state.selection.$from;
    const start = $pos.before($pos.depth);
    const end = $pos.after($pos.depth);
    const calloutNode = state.schema.nodeFromJSON(node);
    let tr = state.tr.replaceWith(start, end, calloutNode);
    // Place the caret INTO the new callout body (it is a textable content node),
    // mirroring the slash path so the user keeps typing the callout text — not left
    // stranded before the swapped node. Best-effort: the swap already landed.
    try {
      tr = tr.setSelection(TextSelection.near(tr.doc.resolve(start + 1)));
    } catch (_e) {
      // Selection placement is best-effort; the replace itself already landed.
    }
    view.dispatch(tr);
    this._editor.commands.focus();
    return true;
  }

export function _openSlash(query = "") {
    if (!this._slash) {
      this._slash = new SlashMenu({
        // CANVAS_SLASH_ITEMS = SLASH_ITEMS filtered to the insertable set (the
        // per-block menu's SLASH_ITEMS is imported INTACT; the allowlist narrows
        // here, never edits it). SlashMenu still prepends EXPECTED-group items it
        // reads fresh from the DOM on each open.
        // Gyldendal parity E1: a FIELD canvas offers only its declared
        // vocabulary (data-vocabulary); a paper canvas (no attribute) keeps the
        // full insertable set.
        items: slashItemsForVocabulary(
          CANVAS_SLASH_ITEMS.map((it) => (CANVAS_SLASH_CHORDS[it.type] ? { ...it, keys: CANVAS_SLASH_CHORDS[it.type] } : it)),
          parseVocabulary(this.getAttribute("data-vocabulary")),
        ),
        onChoose: (item) => this._chooseSlash(item),
        onDismiss: () => this._dismissSlash(),
        // EXPECTED fields (the default extra group) plus the paper's MASTERS,
        // read fresh on every open from this editor's own carrier.
        readExtraItems: () => {
          const root = this._mastersRoot();
          return [...readExpectedItems(), ...(root ? readMasterItems(root) : [])];
        },
      });
    }
    // Anchor the popup to the live caret rectangle. open() handles both the first
    // open and a re-open with a new filter query (as the user types).
    this._slash.open(this._caretRect(), query);
  }

export function _closeSlash() {
    if (this._slash && this._slash.isOpen()) this._slash.close();
  }

  // User picked an item: REPLACE the just-typed "/query" block with the default
  // NODE for the picked type, inserted DIRECTLY into the doc (the canvas direct-
  // insert path — it does NOT dispatch bp-slash-insert). The replaced block was an
  // empty "/query" paragraph; we swap it for slashTypeToNode(item.type), which
  // carries bpId:null so runToOps mints a fresh id and emits ONE insert-after (the
  // new block) + the remove of the origin para. The S4a echo then stamps the server
  // id back. After the swap the caret lands inside the new block's body (prose /
  // callout) or selects the atom (divider/code/diagram/field), mirroring a natural
  // authoring flow.
  //
  // DEFENSIVE: an EXPECTED-group pick (or any item) whose type is NOT canvas-
  // insertable is a no-op — CANVAS_SLASH_TYPES is the same allowlist that built the
  // base menu, so a non-insertable EXPECTED field never produces a bad insert.
  // True when the caret sits in a list item's only paragraph and that paragraph holds nothing but the slash query.
  export function _slashInListItem($from) {
    if ($from.parent.type.name !== "paragraph" || $from.depth < 2) return false;
    const item = $from.node($from.depth - 1);
    if (!item || (item.type.name !== "listItem" && item.type.name !== "taskItem") || item.childCount !== 1) return false;
    return /^\/[^\s]*$/.test($from.parent.textContent) || $from.parent.textContent === "";
  }

export function _chooseSlash(item) {
    this._closeSlash();
    // An INLINE row (a declared blocks.inline kind): the object goes inside this
    // paragraph, in place of the "/query" text, once its dialog is saved.
    if (item && item.inline) {
      const { $from } = this._editor.state.selection;
      insertInlineObject(this, this._editor, item.inline, { replaceRange: { from: $from.start(), to: $from.end() } });
      return;
    }
    // A slash pick inside a list item first lifts the item out of the list, so the chosen block
    // lands at the top level where insertSlashTypeAtSelection replaces the paragraph.
    let guard = 0;
    while (this._editor.state.selection.$from.depth > 1 && guard++ < 6) {
      if (!this._editor.commands.liftListItem("listItem")) break;
    }
    // A COMPOUND starter row (the Starters group): insert the whole pre-composed
    // subtree through the shared landing seam — same guard, same caret rules as a
    // single-node pick, but the carried node is a container + seeded children.
    if (item && item.compound) {
      insertCompoundAtSelection(this._editor, item.compound, { replaceText: true });
      return;
    }
    // A MASTER row (the Masters group): the SERVER inserts the detached copy.
    // A linked row (`item.linked`) asks for a LINKED instance instead.
    if (item && item.master) {
      this._insertMaster(item.master, item.linked === true ? "linked" : null);
      return;
    }
    // A SECTION PRESET row (the Presets group): insert the whole ORDERED SEQUENCE of
    // top-level blocks through the same landing seam — same guard, same degrade, and
    // the preset's declared placeholder is selected so the next keystroke overtypes it.
    if (item && item.preset) {
      insertSectionPresetAtSelection(this._editor, item.preset, { replaceText: true });
      return;
    }
    // Terminal / Stage: the SERVER builds the block, like "+ Add block" (the canvas
    // fence refuses a canvas batch that introduces one — task-f3c8acd1e09a0eda).
    if (item && item.object) {
      // A declared object block with fields asks for them first (inline-object.js);
      // one with none inserts at once.
      if (!openObjectBlockInsert(this, this._editor, item.type, (values) => this._insertObjectBlock(item.type, values))) {
        this._insertObjectBlock(item.type);
      }
      return;
    }
    // A field's Quote row makes the block the field admits (vocabulary.js quoteTypeFor).
    if (item && item.quoteAs === "pullquote") {
      this._replaceTopBlockWithQuote("pullquote");
      return;
    }
    if (item && !item.fieldName && serverBuildsInsert(item.type, this._hostBuildsInserts())) {
      this._insertViaServer(item.type, { replaceSlashLine: true });
      return;
    }
    if (!item || !CANVAS_SLASH_TYPES.has(item.type)) {
      // Non-insertable (e.g. an EXPECTED field-image/field-reference): leave the
      // "/query" text in place and refocus, exactly like a dismiss.
      this._editor.commands.focus();
      return;
    }

    // REPLACE the just-typed "/query" block with the default node for the picked
    // type, via the SHARED slash-insert seam (insertSlashTypeAtSelection in command-
    // palette.js) — the SAME code path the P5 command palette's Insert commands use,
    // so a slash pick and an Insert command produce byte-identical blocks. By
    // construction the caret here ALWAYS sits in a top-level-prose block (_maybeSlash
    // gates open on slashTriggerAllowsParent), so the seam's replace branch fires —
    // identical behavior to the pre-refactor in-place replaceWith. EXPECTED-group
    // items carry a `fieldName` binding (threaded through so a bound-field insert
    // round-trips). Caret placement (into-body vs atom-select) is handled by the seam.
    // `replaceText`: the block's text is the slash's own "/query", so it is replaced.
    insertSlashTypeAtSelection(this._editor, item.type, item.fieldName, { level: item.level, replaceText: true });
    if (item.type === "image") this._pickInsertedImage();
  }

  // A declared custom object block (task-96fce87b7b71c288): REPLACE the "/query"
  // line with a verbatim bpOpaque carry of `{type}`. runToOps inserts it as a new
  // block (the opaque insert path), the server checks its declared fields.
  // `opts.keepLine`: insert AFTER the caret's block instead of replacing it (the
  // command palette's insert, where the caret's block holds real content); an
  // empty paragraph is still replaced, as the slash pick replaces its "/query".
  export function _insertObjectBlock(type, bpBlock, opts = {}) {
    const editor = this._editor;
    if (!editor || !this._editable || typeof type !== "string" || type === "") return false;
    const { state } = editor;
    const nodeType = state.schema.nodes.bpOpaque;
    if (!nodeType) return false;
    const index = topLevelIndexAtSelection(editor);
    let offset = 0;
    for (let i = 0; i < index; i++) offset += state.doc.child(i).nodeSize;
    const line = state.doc.child(index);
    const node = nodeType.create({ bpId: null, bpType: type, bpBlock: bpBlock || { type } });
    const keep = opts.keepLine && !(line.type.name === "paragraph" && line.content.size === 0);
    editor.view.dispatch(
      keep
        ? state.tr.insert(offset + line.nodeSize, node)
        : state.tr.replaceWith(offset, offset + line.nodeSize, node),
    );
    return true;
  }

  // The palette's Insert command for a type the field DECLARES as an object
  // block (task-441e0c1cc08acc5e): the same declared insert the slash pick
  // makes (field dialog first), never the canvas built-in of that name.
  export function _insertDeclaredObject(type) {
    const insert = (values) => this._insertObjectBlock(type, values, { keepLine: true });
    if (!openObjectBlockInsert(this, this._editor, type, insert)) {
      insert(undefined);
      return true;
    }
    // The palette refocused the editor before running this command, and TipTap's
    // focus() takes the caret back on the next animation frame — after the dialog
    // focused its first field. Take it back to the dialog (task-040407b85629d22b).
    const dialog = this._inlineObjectDialog();
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(() => { if (dialog.isOpen()) dialog.focusFirst(); });
    }
    return true;
  }

  // ── paper masters (task-3b6e562e916c8ce4) ──────────────────────────────────
  //
  // The masters affordances exist only inside a Studio paper editor that rendered
  // the `[data-paper-masters]` carrier (the pane may write). A field canvas
  // (data-vocabulary) and the public reader never get them.
  export function _mastersRoot() {
    if (this.hasAttribute("data-vocabulary")) return null;
    const editor = this.closest(".bp-paper-editor");
    return editor && editor.querySelector("[data-paper-masters]") ? editor : null;
  }

export function _canSaveMaster(node) {
    if (!this._editable || !node || !this._mastersRoot()) return false;
    const id = node.attrs && node.attrs.bpId;
    if (typeof id !== "string" || id === "" || node.attrs.locked === true) return false;
    return (this._blocks || []).some((block) => block && block.id === id);
  }

  // Ask the host to save a confirmed block as a master (the hook forwards it as
  // `paper-save-master`); the server re-validates masterability.
  export function _saveMaster(node) {
    if (!this._canSaveMaster(node)) return false;
    this.dispatchEvent(
      new CustomEvent("bp-save-master", {
        detail: { block_id: node.attrs.bpId },
        bubbles: true,
        composed: true,
      }),
    );
    return true;
  }

  // A Masters pick: remove the "/query" paragraph, flush that removal so it is
  // queued BEFORE the insert, then ask the host to insert the detached copy after
  // a block the server already holds (masterInsertAnchor). The editor is blurred
  // so the server echo carrying the copy renders as soon as it lands instead of
  // waiting for the author to leave the editor.
  // `mode` "linked" (task-59be65118320fa0e) asks for a `master-ref` instance;
  // null keeps the detached copy (no mode on the wire).
  export function _insertMaster(masterId, mode = null) {
    const editor = this._editor;
    if (!editor || typeof masterId !== "string" || masterId === "") return false;
    const slashIndex = topLevelIndexAtSelection(editor);
    const liveIds = [];
    editor.state.doc.forEach((node) => liveIds.push(node.attrs.bpId));
    const confirmed = new Set((this._blocks || []).map((block) => block && block.id));
    const afterId = masterInsertAnchor(liveIds, slashIndex, confirmed);

    // Drop the "/query" block (an only child is replaced by an empty paragraph).
    const { state } = editor;
    let offset = 0;
    for (let i = 0; i < slashIndex; i++) offset += state.doc.child(i).nodeSize;
    const slashNode = state.doc.child(slashIndex);
    let tr = state.tr.delete(offset, offset + slashNode.nodeSize);
    if (tr.doc.childCount === 0) tr = tr.insert(0, state.schema.nodes.paragraph.create());
    editor.view.dispatch(tr);
    this.flushPendingChanges();
    editor.commands.blur();

    this.dispatchEvent(
      new CustomEvent("bp-master-insert", {
        detail: mode === "linked"
          ? { master_id: masterId, after_id: afterId, mode: "linked" }
          : { master_id: masterId, after_id: afterId },
        bubbles: true,
        composed: true,
      }),
    );
    return true;
  }

  // Terminal / Stage (CANVAS_SERVER_INSERT_TYPES, owner ruling 2026-10-03 #56): ask
  // the host to insert the block through the server (`paper-slash-insert`, the same
  // default_block/2 + insert-after "+ Add block" uses) instead of inserting a node the
  // server's canvas fence refuses. The anchor is a block the server already holds
  // (masterInsertAnchor). A slash pick removes its "/query" line first and flushes
  // that removal so the hook queues it BEFORE the insert; a palette pick keeps the
  // caret's block and anchors on it when it is confirmed. The editor is blurred so
  // the server echo carrying the new block renders at once.
  // Does the host build blocks on the server? Barkpark's LiveView hook marks the editor
  // (or an ancestor) `data-server-insert`; a plain embedder does not (see slash-insert.js).
  export function _hostBuildsInserts() {
    return Boolean(this.closest && this.closest("[data-server-insert]"));
  }

export function _insertViaServer(type, replaceSlashLine = false) {
    const editor = this._editor;
    if (!editor || !this._editable || !serverBuildsInsert(type, this._hostBuildsInserts())) return false;
    const index = topLevelIndexAtSelection(editor);
    const liveIds = [];
    editor.state.doc.forEach((node) => liveIds.push(node.attrs.bpId));
    const confirmed = new Set((this._blocks || []).map((block) => block && block.id));
    // A palette pick may anchor ON the caret's block (search from index + 1 down);
    // a slash pick never anchors on the line it removes.
    const afterId = masterInsertAnchor(liveIds, replaceSlashLine ? index : index + 1, confirmed);

    if (replaceSlashLine) {
      const { state } = editor;
      let offset = 0;
      for (let i = 0; i < index; i++) offset += state.doc.child(i).nodeSize;
      const slashNode = state.doc.child(index);
      let tr = state.tr.delete(offset, offset + slashNode.nodeSize);
      if (tr.doc.childCount === 0) tr = tr.insert(0, state.schema.nodes.paragraph.create());
      editor.view.dispatch(tr);
    }
    this.flushPendingChanges();
    editor.commands.blur();

    this.dispatchEvent(
      new CustomEvent("bp-server-insert", {
        detail: { type, after_id: afterId },
        bubbles: true,
        composed: true,
      }),
    );
    return true;
  }

  // Esc / outside-click: close the menu but LEAVE the typed "/" in place — the user
  // may want to keep typing a real slash. Mirrors ../index.js:_dismissSlash.
  export function _dismissSlash() {
    this._closeSlash();
    this._editor.commands.focus();
  }

  // ── P5 command palette (Cmd-P) ─────────────────────────────────────────────
  //
  // The Obsidian Cmd-P analog. Opened on Mod-p (see _onKeyDown), it floats a
  // centered modal over the editor listing the WHOLE command registry, fuzzy-
  // filtered by what the user types into its query input. UNLIKE the slash/[[ /#
  // popups it consumes NO doc text — it is keyboard-triggered. On a pick it runs the
  // command's run(editor), closes, and refocuses; the command then emits the normal
  // bp-canvas-ops via the onUpdate path (insert → insert-after; format → patch-block).
  export function _openPalette() {
    if (!this._editable || !this._editor) return;
    // The View-group "Toggle Markdown source" command calls back into the WC's
    // toggle (the canvas owns the rich⇄source swap, not the editor) — the SAME method
    // Mod-Shift-m calls, so both triggers are identical.
    const registryOpts = {
      onToggleSource: () => this.toggleSourceMode(),
      // Insert Terminal / Insert Stage: the server builds these (see _insertViaServer).
      onServerInsert: (type) => this._insertViaServer(type, { replaceSlashLine: false }),
      serverBuilds: (type) => serverBuildsInsert(type, this._hostBuildsInserts()),
      // Declared inline objects: inserted at the caret, anywhere in prose.
      inlineObjects: this._inlineObjectVocabulary()?.inlineObjects || [],
      onInlineInsert: (name) => insertInlineObject(this, this._editor, name),
      // A declared object block wins over the same-named built-in insert
      // (task-441e0c1cc08acc5e, the palette twin of the slash rule).
      declaredObjects: this._objectOverrides(),
      onObjectInsert: (type) => this._insertDeclaredObject(type),
      // Insert Image opens the host's picker for the new block (mediaPicker).
      onImageInserted: () => this._pickInsertedImage(),
    };
    if (!this._palette) {
      this._palette = new CommandPalette({
        commands: buildCommandRegistry(this._editor, registryOpts),
        onChoose: (cmd) => this._choosePaletteCommand(cmd),
        onDismiss: () => this._dismissPalette(),
      });
    } else {
      // Rebuild the registry against the LIVE editor on each open so command
      // availability (e.g. underline only if registered) reflects the current state.
      this._palette.setCommands(buildCommandRegistry(this._editor, registryOpts));
    }
    // The rect is ignored by CommandPalette._position (centered modal); pass the
    // caret rect anyway for API symmetry with the slash popup. Empty initial query.
    this._palette.open(this._caretRect(), "");
  }

export function _closePalette() {
    if (this._palette && this._palette.isOpen()) this._palette.close();
  }

  // User picked a command: close the palette, refocus the editor, then run the
  // command. run() acts on the current selection/block via the editor chain (format/
  // turn-into) or inserts a default node (Insert, via the shared slash seam), each of
  // which mutates the doc → onUpdate → debounced bp-canvas-ops. Refocus BEFORE run so
  // chain().focus() lands on the editor selection the user left (the palette input
  // never held a ProseMirror selection).
  export function _choosePaletteCommand(cmd) {
    this._closePalette();
    this._editor.commands.focus();
    if (cmd && typeof cmd.run === "function") {
      try {
        cmd.run(this._editor);
      } catch (_e) {
        // A command failure must not wedge the palette/editor — it is already closed
        // and refocused; swallow so a bad command is a no-op, not a crash.
      }
    }
  }

  // Esc / outside-click / Mod-p-toggle: close the palette and refocus the editor. No
  // doc text to preserve (the palette consumed none).
  export function _dismissPalette() {
    this._closePalette();
    this._editor.commands.focus();
  }
