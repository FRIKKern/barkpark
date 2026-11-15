import { markdownToBlocks } from "../markdown.js";
import { CANVAS_SLASH_ITEMS } from "./canvas-menu-catalog.js";
import { insertSlashTypeAtSelection } from "./command-palette.js";
import {
  commentRangesState,
  commentsInSelection as crInSelection,
  setCommentRanges as crSet,
} from "./comment-ranges.js";
import {
  findClear as frClear,
  replaceAll as frReplaceAll,
  replaceCurrent as frReplaceCurrent,
  findSet as frSet,
  findState as frState,
  findStep as frStep,
} from "./find-replace.js";
import {
  canSetBlockStyle,
  canToggleList,
  canToggleMark,
  emptyToolbarState,
  setBlockStyle as hcSetBlockStyle,
  toggleList as hcToggleList,
  toggleMark as hcToggleMark,
  toolbarState,
} from "./host-commands.js";
import { insertInlineObject } from "./inline-object.js";
import { LinkPreview } from "./link-preview.js";
import { pointsFromSelection, setRemoteSelections as rsSet } from "./remote-selections.js";
import { docToBlocks } from "./run-convert.js";
import { serverBuildsInsert } from "./slash-insert.js";
import { clampLockedPrefix, deepCloneBlocks, realignAcrossCommits } from "./source-realign.js";
import { parseVocabulary, slashItemsForVocabulary } from "./vocabulary.js";
import { isHistoryTransaction, redoDepth, undoDepth } from "@tiptap/pm/history";

  // Synchronous host seam for navigation / beforeunload guards. A debounced
  // transaction is unsaved before bp-canvas-ops exists; source-mode text and
  // edits queued behind an acknowledgement must also survive an attempted exit.
  // ── shared carets (see canvas/remote-selections.js) ──
  // Replace the host's remote selections: [{ id, name, color, anchor, head }],
  // each end a Point. Decorations only — no ops, no history entry, the local
  // caret untouched. [] clears. Before mount the list waits for the editor.
  export function setRemoteSelections(list) {
    this._remoteSelections = Array.isArray(list) ? list : [];
    if (this._editor && !this._editor.isDestroyed) rsSet(this._editor, this._remoteSelections);
  }

  // ── comment ranges (see canvas/comment-ranges.js) ──
  // Replace the host's comment ranges: [{ id, anchor, head, active? }], each end a
  // Point. Decorations only. [] clears. Before mount the list waits for the editor.
  export function setCommentRanges(list) {
    this._commentRanges = Array.isArray(list) ? list : [];
    if (this._editor && !this._editor.isDestroyed) crSet(this._editor, this._commentRanges);
  }

  // The live ranges as mapped through edits: [{ id, anchor, head, text }], in
  // document order. A range whose text is gone is absent.
  export function commentRanges() {
    const editor = this._editor;
    return editor && !editor.isDestroyed ? commentRangesState(editor) : [];
  }

  // The ids of the comment ranges the selection overlaps.
  export function commentsInSelection() {
    const editor = this._editor;
    return editor && !editor.isDestroyed ? crInSelection(editor) : [];
  }

  // bp-canvas-comment-ranges: an edit moved or dropped a range. One per frame.
  export function _scheduleCommentRangesEmit() {
    if (this._commentRangesFrame != null) return;
    this._commentRangesFrame = requestAnimationFrame(() => {
      this._commentRangesFrame = null;
      const editor = this._editor;
      if (!editor || editor.isDestroyed) return;
      this.dispatchEvent(new CustomEvent("bp-canvas-comment-ranges", { bubbles: true, composed: true, detail: commentRangesState(editor) }));
    });
  }

  // bp-canvas-selection: the local selection as { anchor, head } Points, or null
  // when the editor is blurred or has none. One per animation frame, and only
  // when it changed.
  export function _scheduleSelectionEmit() {
    if (this._selectionFrame != null) return;
    this._selectionFrame = requestAnimationFrame(() => {
      this._selectionFrame = null;
      const editor = this._editor;
      if (!editor || editor.isDestroyed) return;
      const detail = editor.isFocused ? pointsFromSelection(editor.state) : null;
      const key = JSON.stringify(detail);
      if (key === this._lastSelectionDetail) return;
      this._lastSelectionDetail = key;
      this.dispatchEvent(new CustomEvent("bp-canvas-selection", { bubbles: true, composed: true, detail }));
    });
  }

export function _wantsBubble() {
    return this.getAttribute("format-bubble") !== "off";
  }

  // With the bubble off, the host opens its own link input: a cancelable
  // bp-canvas-link-request carrying the selection's current href (or null).
  export function _requestHostLink() {
    const editor = this._editor;
    if (!editor || editor.isDestroyed) return false;
    const href = editor.isActive("link") ? editor.getAttributes("link").href || null : null;
    return this.dispatchEvent(new CustomEvent("bp-canvas-link-request", { detail: { href }, bubbles: true, composed: true, cancelable: true }));
  }

  // ── toolbar commands (EMBED-CONTRACT "Toolbar commands"; canvas/host-commands.js) ──
  //
  // Each runs the transaction the canvas's own surfaces run, on the current
  // selection, and answers whether it applied. Unmounted or read-only: false.

  // Typing and a focus change in one task leave the DOM change unread: ProseMirror's
  // blur queues it and reads it 20 ms later, and a flush or a server apply in that
  // gap would miss it (task-8c2aa053f0259a05). Read it now. Never mid-composition.
  export function _readDomTyping() {
    const view = this._editor && !this._editor.isDestroyed ? this._editor.view : null;
    const observer = view && view.domObserver;
    if (!observer || view.composing) return;
    try {
      observer.forceFlush();
      observer.flush();
    } catch (_e) {
      // A view mid-teardown has nothing left to read.
    }
  }

  // ProseMirror's keydown prevents the default of every Escape, so a host's own
  // Escape (leave the editor, close a pane) never saw a free key
  // (task-4517b978de20b741). True skips ProseMirror's keydown for a bare Escape;
  // with a canvas menu open, the key goes to _onKeyDown as before.
  export function _escapeForHost(view, event) {
    if (event.key !== "Escape" && event.key !== "Esc") return false;
    if (event.defaultPrevented || event.isComposing || view.composing) return false;
    const menuOpen = [this._palette, this._wikilink, this._emoji, this._tag, this._slash]
      .some((menu) => menu && menu.isOpen());
    return !menuOpen;
  }

  // Mod+Enter (1.17.0) is the host's, free: ProseMirror never sees it, so no hard break
  // lands, and a host that leaves it alone gets no browser newline either.
  export function _modEnterForHost(view, event) {
    if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return false;
    if (event.defaultPrevented || event.isComposing || view.composing) return false;
    this._modEnterPending = true;
    setTimeout(() => { this._modEnterPending = false; });
    return true;
  }

export function _swallowModEnter(event) {
    if (!this._modEnterPending || !/^insert(Paragraph|LineBreak)$/.test(event.inputType)) return false;
    this._modEnterPending = false;
    event.preventDefault();
    return true;
  }

  // A click on a document link: bp-canvas-wikilink-click (1.15.0), cancelable, so
  // a host follows it without reading the canvas's DOM (task-bd03e32b9851d047).
  export function _wikilinkClicked(event) {
    if (event.button !== 0) return;
    const info = LinkPreview.describe(event.target);
    if (!info || info.kind !== "wikilink" || !this.contains(info.el)) return;
    const detail = {
      docId: info.docId,
      target: info.target || null,
      alias: info.alias,
      metaKey: event.metaKey,
      ctrlKey: event.ctrlKey,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
    };
    const open = this.dispatchEvent(new CustomEvent("bp-canvas-wikilink-click", { detail, bubbles: true, composed: true, cancelable: true }));
    if (!open) event.preventDefault();
  }

  // ProseMirror takes a keyboard (or script) selection change on the browser's
  // selectionchange, a task later: a toolbar press in between would act on the old
  // selection. Read the DOM's pending selection first, so a command acts on what the
  // author sees (task-ee29b37ca1c6139d).
  export function _flushDomSelection() {
    const view = this._editor && !this._editor.isDestroyed ? this._editor.view : null;
    try {
      if (view && view.domObserver && typeof view.domObserver.flush === "function") view.domObserver.flush();
    } catch (_e) {
      // A view mid-teardown: the command reads the state it has.
    }
  }

export function run(command, args = {}) {
    if (!this.can(command, args)) return false;
    const editor = this._editor;
    const a = args && typeof args === "object" ? args : {};
    switch (command) {
      case "toggleMark": return hcToggleMark(editor, a.mark, a.href, a.docId, a.target) === true;
      case "setBlockStyle": return hcSetBlockStyle(editor, a.style, this._toolbarVocabulary()) === true;
      case "toggleList": return hcToggleList(editor, a.kind) === true;
      case "insertBlock": return this._insertToolbarBlock(a.type, a.attrs) === true;
      case "insertInline": return this._insertToolbarInline(a.type) === true;
      case "undo": return editor.commands.undo() === true;
      case "redo": return editor.commands.redo() === true;
      default: return false;
    }
  }

export function toggleMark(mark, attrs) { return this.run("toggleMark", { mark, href: attrs && attrs.href, docId: attrs && attrs.docId, target: attrs && attrs.target }); }

export function setBlockStyle(style) { return this.run("setBlockStyle", { style }); }

export function toggleList(kind) { return this.run("toggleList", { kind }); }

export function insertBlock(type, attrs) { return this.run("insertBlock", { type, attrs }); }

export function insertInline(type) { return this.run("insertInline", { type }); }

  // 1.10.0: the canvas's own history, for a host that keeps one undo across its form
  // and this canvas (Sanity's document undo). One step, as Mod+Z / Shift+Mod+Z here.
  export function undo() { return this.run("undo"); }

export function redo() { return this.run("redo"); }

export function can(command, args = {}) {
    const editor = this._editor;
    if (!editor || editor.isDestroyed || !this._editable) return false;
    this._flushDomSelection();
    const a = args && typeof args === "object" ? args : {};
    const vocab = this._toolbarVocabulary();
    switch (command) {
      case "toggleMark": return canToggleMark(editor, a.mark, a.href, vocab, a.docId);
      case "setBlockStyle": return canSetBlockStyle(editor, a.style, vocab);
      case "toggleList": return canToggleList(editor, a.kind, vocab);
      case "insertBlock": return !!this._toolbarInsertItem(a.type);
      case "insertInline": return this._canInsertInline(a.type, vocab);
      case "undo": return undoDepth(editor.state) > 0;
      case "redo": return redoDepth(editor.state) > 0;
      default: return false;
    }
  }

export function state() {
    this._flushDomSelection();
    const editor = this._editor;
    return editor && !editor.isDestroyed ? toolbarState(editor) : emptyToolbarState();
  }

export function _toolbarVocabulary() {
    return parseVocabulary(this.getAttribute("data-vocabulary"));
  }

  // The block types a toolbar may insert: the slash menu's own rows for this
  // canvas (narrowed to the field's vocabulary), one per type.
  export function _toolbarInsertItem(type) {
    if (typeof type !== "string" || type === "") return null;
    const items = slashItemsForVocabulary(CANVAS_SLASH_ITEMS, this._toolbarVocabulary());
    return items.find((item) => item.type === type && !item.compound && !item.preset && !item.inline && !item.master) || null;
  }

  // A declared inline object (the field's blocks.inline) may go at the caret: inside
  // text the field writes in, never in a code block.
  export function _canInsertInline(type, vocab) {
    if (typeof type !== "string" || type === "") return false;
    if (!((vocab && vocab.inlineObjects) || []).some((o) => o.name === type)) return false;
    const { $from } = this._editor.state.selection;
    return $from.parent.inlineContent && !$from.parent.type.spec.code;
  }

  // At the caret, exactly as the slash and palette picks do: the field editor (the
  // popover, or the host's editBlockObject) first; its answer puts the atom in.
  export function _insertToolbarInline(type) {
    this._editor.commands.focus();
    if (!insertInlineObject(this, this._editor, type)) return false;
    // TipTap's focus() takes the caret back on the next frame, after the popover
    // focused its first field: give it back (as _insertDeclaredObject does).
    const dialog = this._inlineObjectDialog();
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(() => { if (dialog.isOpen()) dialog.focusFirst(); });
    }
    return true;
  }

  // Insert after the caret's block, exactly as the palette's Insert command does
  // (a declared object block opens its fields first; a server-built type goes to
  // the server; the rest through the slash seam).
  export function _insertToolbarBlock(type, attrs) {
    const item = this._toolbarInsertItem(type);
    if (!item) return false;
    this._editor.commands.focus();
    if (item.object || this._objectOverrides().has(type)) return this._insertDeclaredObject(type);
    if (serverBuildsInsert(type, this._hostBuildsInserts())) return this._insertViaServer(type, { replaceSlashLine: false });
    const level = attrs && Number.isInteger(attrs.level) ? attrs.level : item.level;
    const done = insertSlashTypeAtSelection(this._editor, type, undefined, level ? { level } : undefined);
    if (done && type === "image") this._pickInsertedImage();
    return done;
  }

  // 1.10.0: bp-canvas-history, at once (not per frame) whenever the history's depths
  // change, saying how: a new undo step ("step", which also ends what could be redone),
  // an "undo" or "redo" here, or the history "clear"ed. Depths alone can't tell a redo from
  // a step typed right after an undo; the history's own transaction does. A host that keeps
  // one undo for its document follows these to keep the canvas's steps in order.
  export function _emitHistory(transaction) {
    const editor = this._editor;
    if (!editor || editor.isDestroyed) return;
    const last = this._lastHistory || { undo: 0, redo: 0 };
    const undo = undoDepth(editor.state);
    const redo = redoDepth(editor.state);
    if (last.undo === undo && last.redo === redo) return;
    const history = !!transaction && isHistoryTransaction(transaction);
    const kind = history ? (undo < last.undo ? "undo" : "redo") : undo > last.undo ? "step" : "clear";
    this._lastHistory = { undo, redo };
    const count = Math.abs(undo - last.undo) || 1;
    this.dispatchEvent(new CustomEvent("bp-canvas-history", { bubbles: true, composed: true, detail: { kind, count, undo, redo } }));
  }

export function _scheduleToolbarState() {
    if (this._toolbarFrame != null) return;
    this._toolbarFrame = requestAnimationFrame(() => {
      this._toolbarFrame = null;
      const editor = this._editor;
      if (!editor || editor.isDestroyed) return;
      const detail = toolbarState(editor);
      const key = JSON.stringify(detail);
      if (key === this._lastToolbarState) return;
      this._lastToolbarState = key;
      this.dispatchEvent(new CustomEvent("bp-selection-change", { bubbles: true, composed: true, detail }));
    });
  }

  // ── find and replace (the host draws the bar; see canvas/find-replace.js) ──
  export function findSet(query, opts) { return this._editor ? frSet(this._editor, query, opts) : { query: "", count: 0, index: -1 }; }

export function findNext() { return this._editor ? frStep(this._editor, 1) : { count: 0, index: -1 }; }

export function findPrev() { return this._editor ? frStep(this._editor, -1) : { count: 0, index: -1 }; }

export function findClear() { if (this._editor) frClear(this._editor); }

export function findState() { return this._editor ? frState(this._editor) : { query: "", count: 0, index: -1 }; }

export function replaceCurrent(text) { return this._editor && this._editable ? frReplaceCurrent(this._editor, text) : this.findState(); }

export function replaceAll(text) { return this._editor && this._editable ? frReplaceAll(this._editor, text) : { replaced: 0, ...this.findState() }; }

export function hasPendingChanges() {
    this._readDomTyping();
    const sourceChanged =
      this._mode === "source" && this._sourceEl &&
      this._sourceEl.value !== this._sourceOriginalMd;
    return Boolean(
      sourceChanged || this.querySelector(".bp-canvas-note[data-note-pending]") ||
      this._debounceTimer || this._inflightOps ||
      this._dirtyWhileInflight || this._compEndTimer ||
      // An open composition is text the writer sees and Barkpark does not have yet.
      (this._compStart != null && !!this._editor?.view?.composing)
    );
  }

  // Read-only recovery seam for a reconnect halt. This projects the live editor
  // instead of the acknowledged `blocks` baseline, so debounced prose is not
  // omitted. Source mode always includes the textarea verbatim; if its markdown
  // cannot be projected, the raw text and an explicit error remain exportable.
  export function recoverySnapshot() {
    if (this._mode === "source" && this._sourceEl) {
      const rawSource = this._sourceEl.value;
      try {
        const baseline = this._sourceBaselineBlocks || [];
        const blocks = clampLockedPrefix(
          baseline,
          realignAcrossCommits(baseline, this._sourceCommitBlocks, markdownToBlocks(rawSource)),
        );
        return {
          mode: "markdown",
          raw_source: rawSource,
          blocks: deepCloneBlocks(blocks),
        };
      } catch (_error) {
        return {
          mode: "markdown",
          raw_source: rawSource,
          serialization_error: "The Markdown draft could not be projected to PortableDoc blocks.",
        };
      }
    }

    let rawEditorDocument = null;
    try {
      rawEditorDocument = this._editor?.getJSON?.() || null;
      if (!rawEditorDocument) {
        return {
          mode: "rich",
          serialization_error: "The live rich-text document was unavailable.",
        };
      }
      return {
        mode: "rich",
        blocks: deepCloneBlocks(docToBlocks(this._normalizedDoc(rawEditorDocument))),
      };
    } catch (_error) {
      return {
        mode: "rich",
        ...(rawEditorDocument ? { raw_editor_document: rawEditorDocument } : {}),
        serialization_error: "The rich-text draft could not be projected to PortableDoc blocks.",
      };
    }
  }

  // Explicit conflict resolution seam. Normal echoes never erase newer local
  // edits; this path is reserved for the user's deliberate "Use latest" action.
  export function resolveConflictWithServerBlocks(blocks) {
    if (this._debounceTimer) clearTimeout(this._debounceTimer);
    this._debounceTimer = null;
    this._debounceBaselineBlocks = null;
    this._inflightOps = null;
    this._dirtyWhileInflight = false;
    this._awaitingOwnEchoes = [];
    this._clearPendingServerBlocks();
    const next = Array.isArray(blocks) ? blocks : [];
    this._blocks = deepCloneBlocks(next);
    if (!this._editor) return;
    this._programmaticApply = true;
    try {
      this._applyExternalContent(next);
    } finally {
      this._programmaticApply = false;
    }
  }
