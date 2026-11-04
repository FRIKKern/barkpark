// canvas/index.js — Phase-4 Stage S1: <bp-paper-canvas>, the CONTINUOUS-CANVAS
// engine over ONE prose run.
//
// Where <bp-paper-editor> (../index.js) mounts ONE TipTap instance PER BLOCK and
// emits a patch-block op for that one block, <bp-paper-canvas> mounts ONE TipTap
// instance over a CONTIGUOUS run of PROSE blocks (paragraph | heading | list —
// non-prose blocks are run boundaries handled in S2/S3, so a run never contains
// them). This is what proves the Obsidian continuous feel: cross-block caret,
// multi-block selection, Enter-split, Backspace-merge — ALL in ONE ProseMirror
// document, which StarterKit's keymaps give us FOR FREE (doc content is block+,
// so paragraph/heading/list as siblings is native and Enter/Backspace at block
// edges split/merge without any custom code).
//
// PROJECTOR + OP-MAPPER are S0's PURE, TESTED functions, used VERBATIM:
//   runToTiptap(blocks) -> { type:"doc", content:[node…] }   (mount content)
//   runToOps(prevBlocks, editor.getJSON()) -> ordered op array (the diff)
// We do NOT reinvent the diff. The ONE thing the canvas must add on top of S0 is
// the BpAttrs extension (./bp-attrs.js): runToTiptap stamps attrs:{bpId,bpType}
// on each top-level node, but ProseMirror DROPS unknown node attrs on the
// setContent->getJSON round-trip unless the node type declares them. BpAttrs
// declares bpId/bpType on the block nodes so editor.getJSON() preserves the ids
// runToOps keys by. Without it, runToOps mis-diffs everything as new.
//
// S1 SCOPE (tight): cross-block editing + split/merge + op-emission +
// FormatBubble. EXPLICITLY OUT (later stages, clean seams left below): the slash
// menu, the [[ wikilink + # tag autocompletes, and non-prose node-views.
//
// ADDITIVE: this is the SECOND custom element in the same bundle. ../index.js
// gains exactly one line — `import "./canvas/index.js";` — so this registers.
// The shipped <bp-paper-editor> behavior is byte-unchanged.

import { BUILD_SHA, CONTRACT_VERSION, EDITOR_VERSION } from "../contract.js";
import { safeUrl } from "../safe-url.js";
import * as documentMethods from "./canvas-document.js";
import * as focusMethods from "./canvas-focus.js";
import * as lifecycleMethods from "./canvas-lifecycle.js";
import * as hostApiMethods from "./canvas-methods-host-api.js";
import * as keyboardMethods from "./canvas-methods-keyboard.js";
import * as pasteMediaMethods from "./canvas-methods-paste-media.js";
import * as pickerMethods from "./canvas-methods-pickers.js";
import * as slashPaletteMethods from "./canvas-methods-slash-palette.js";
import * as mountMethods from "./canvas-mount.js";
import * as opsMethods from "./canvas-ops.js";
import * as serverMethods from "./canvas-server.js";
import { isFigureSingletonCanvas } from "./figure-context.js";
import {
  sourceModeActive, sourceModeCommit, sourceModeEnter, sourceModeExit, sourceModeSizeTextarea,
  sourceModeSyncText, sourceModeTeardown, sourceModeToggle,
} from "./source-mode.js";


// A textblock's text with one char per inline leaf, so offsets are positions: a
// hard break reads as a newline (it ends a trigger), any other atom as U+FFFC.


class BpPaperCanvas extends HTMLElement {
  static CONTRACT_VERSION = CONTRACT_VERSION;
  static EDITOR_VERSION = EDITOR_VERSION;
  static BUILD_SHA = BUILD_SHA;

  static get observedAttributes() { return lifecycleMethods.getObservedAttributes.call(this, ...arguments); }
  constructor() { super(); lifecycleMethods.initialize.call(this); }

  connectedCallback() { return mountMethods.connectedCallback.call(this, ...arguments); }

  attributeChangedCallback(name, _old, val) {
    return lifecycleMethods.attributeChangedCallback.call(this, ...arguments);
  }
  disconnectedCallback() { return lifecycleMethods.disconnectedCallback.call(this, ...arguments); }

  captureResumeFocus() { return focusMethods.captureResumeFocus.call(this, ...arguments); }
  restoreResumeFocus() { return focusMethods.restoreResumeFocus.call(this, ...arguments); }
  _cancelResumeFocus() { return focusMethods._cancelResumeFocus.call(this, ...arguments); }
  _clearResumeFocusIntent() { return focusMethods._clearResumeFocusIntent.call(this, ...arguments); }

  _teardownDisconnected() { return lifecycleMethods._teardownDisconnected.call(this, ...arguments); }

  flushPendingChanges() { return opsMethods.flushPendingChanges.call(this, ...arguments); }

  setRemoteSelections(list) {
    return hostApiMethods.setRemoteSelections.call(this, list);
  }

  setCommentRanges(list) {
    return hostApiMethods.setCommentRanges.call(this, list);
  }

  commentRanges() {
    return hostApiMethods.commentRanges.call(this);
  }

  commentsInSelection() {
    return hostApiMethods.commentsInSelection.call(this);
  }

  _scheduleCommentRangesEmit() {
    return hostApiMethods._scheduleCommentRangesEmit.call(this);
  }

  _scheduleSelectionEmit() {
    return hostApiMethods._scheduleSelectionEmit.call(this);
  }

  _wantsBubble() {
    return hostApiMethods._wantsBubble.call(this);
  }

  _requestHostLink() {
    return hostApiMethods._requestHostLink.call(this);
  }

  _readDomTyping() {
    return hostApiMethods._readDomTyping.call(this);
  }

  _escapeForHost(view, event) {
    return hostApiMethods._escapeForHost.call(this, view, event);
  }

  _modEnterForHost(view, event) {
    return hostApiMethods._modEnterForHost.call(this, view, event);
  }

  _swallowModEnter(event) {
    return hostApiMethods._swallowModEnter.call(this, event);
  }

  _wikilinkClicked(event) {
    return hostApiMethods._wikilinkClicked.call(this, event);
  }

  _flushDomSelection() {
    return hostApiMethods._flushDomSelection.call(this);
  }

  run(command, args = {}) {
    return hostApiMethods.run.call(this, command, args);
  }

  toggleMark(mark, attrs) {
    return hostApiMethods.toggleMark.call(this, mark, attrs);
  }
  setBlockStyle(style) {
    return hostApiMethods.setBlockStyle.call(this, style);
  }
  toggleList(kind) {
    return hostApiMethods.toggleList.call(this, kind);
  }
  insertBlock(type, attrs) {
    return hostApiMethods.insertBlock.call(this, type, attrs);
  }
  insertInline(type) {
    return hostApiMethods.insertInline.call(this, type);
  }
  undo() {
    return hostApiMethods.undo.call(this);
  }
  redo() {
    return hostApiMethods.redo.call(this);
  }

  can(command, args = {}) {
    return hostApiMethods.can.call(this, command, args);
  }

  state() {
    return hostApiMethods.state.call(this);
  }

  _toolbarVocabulary() {
    return hostApiMethods._toolbarVocabulary.call(this);
  }

  _toolbarInsertItem(type) {
    return hostApiMethods._toolbarInsertItem.call(this, type);
  }

  _canInsertInline(type, vocab) {
    return hostApiMethods._canInsertInline.call(this, type, vocab);
  }

  _insertToolbarInline(type) {
    return hostApiMethods._insertToolbarInline.call(this, type);
  }

  _insertToolbarBlock(type, attrs) {
    return hostApiMethods._insertToolbarBlock.call(this, type, attrs);
  }

  _emitHistory(transaction) {
    return hostApiMethods._emitHistory.call(this, transaction);
  }

  _scheduleToolbarState() {
    return hostApiMethods._scheduleToolbarState.call(this);
  }

  findSet(query, opts) {
    return hostApiMethods.findSet.call(this, query, opts);
  }
  findNext() {
    return hostApiMethods.findNext.call(this);
  }
  findPrev() {
    return hostApiMethods.findPrev.call(this);
  }
  findClear() {
    return hostApiMethods.findClear.call(this);
  }
  findState() {
    return hostApiMethods.findState.call(this);
  }
  replaceCurrent(text) {
    return hostApiMethods.replaceCurrent.call(this, text);
  }
  replaceAll(text) {
    return hostApiMethods.replaceAll.call(this, text);
  }

  hasPendingChanges() {
    return hostApiMethods.hasPendingChanges.call(this);
  }

  recoverySnapshot() {
    return hostApiMethods.recoverySnapshot.call(this);
  }

  resolveConflictWithServerBlocks(blocks) {
    return hostApiMethods.resolveConflictWithServerBlocks.call(this, blocks);
  }

  _scheduleEmit() { return opsMethods._scheduleEmit.call(this, ...arguments); }
  _armComposeEndEmit() { return opsMethods._armComposeEndEmit.call(this, ...arguments); }

  _normalizedDoc(doc) { return documentMethods._normalizedDoc.call(this, ...arguments); }

  _emitOps() { return opsMethods._emitOps.call(this, ...arguments); }
  _committedDoc() { return opsMethods._committedDoc.call(this, ...arguments); }
  _afterComposition() { return opsMethods._afterComposition.call(this, ...arguments); }
  _rememberEmit(liveTop, nextDoc, nextBlocks, stableDoc) { return opsMethods._rememberEmit.call(this, ...arguments); }
  _emitReuse(diffBaseline) { return opsMethods._emitReuse.call(this, ...arguments); }
  _dispatchOps(ops, nextBlocks = null, diffBaseline = this._blocks) {
    return opsMethods._dispatchOps.call(this, ...arguments);
  }
  identifyOpsRequest(seq, requestId, previousRequestId = null) {
    return opsMethods.identifyOpsRequest.call(this, ...arguments);
  }
  rebaseSafe(seq, serverBlocks) { return opsMethods.rebaseSafe.call(this, ...arguments); }
  localEditsRebaseSafe(serverBlocks) { return opsMethods.localEditsRebaseSafe.call(this, ...arguments); }
  acknowledgeOps(seq, saved) { return opsMethods.acknowledgeOps.call(this, ...arguments); }
  discardInflightOps(seq, refusal) { return opsMethods.discardInflightOps.call(this, ...arguments); }

  _objectOverrides() { return documentMethods._objectOverrides.call(this, ...arguments); }
  _rt(blocks) { return documentMethods._rt.call(this, ...arguments); }
  _ro(...args) { return documentMethods._ro.call(this, ...arguments); }
  _re(...args) { return documentMethods._re.call(this, ...arguments); }
  _inlineObjectVocabulary() { return documentMethods._inlineObjectVocabulary.call(this, ...arguments); }
  _inlineObjectDialog() { return documentMethods._inlineObjectDialog.call(this, ...arguments); }
  set editBlockObject(fn) { return documentMethods.setEditBlockObject.call(this, ...arguments); }
  get editBlockObject() { return documentMethods.getEditBlockObject.call(this, ...arguments); }
  _objectEditorOpen() { return documentMethods._objectEditorOpen.call(this, ...arguments); }
  _noteInlineObjectSave(values) { return documentMethods._noteInlineObjectSave.call(this, ...arguments); }
  _reopenRefusedInlineObject(refusal) { return documentMethods._reopenRefusedInlineObject.call(this, ...arguments); }

  resendPendingOps() { return opsMethods.resendPendingOps.call(this, ...arguments); }

  _onKeyDown(event) {
    return keyboardMethods._onKeyDown.call(this, event);
  }

  _onPaste(view, _event, slice) {
    return pasteMediaMethods._onPaste.call(this, view, _event, slice);
  }

  // Plain-text paste that carries markdown block syntax (headings, lists, quotes, fences, rules)
  // lands as the corresponding blocks instead of literal `## ` and `- ` paragraphs. HTML on the
  // clipboard keeps the native path (the browser already structured it); a single plain line too.
  // ── pasted / dropped pictures ────────────────────────────────────────────────
  //
  // A picture on the clipboard or dropped on the canvas becomes a bpImage node at
  // once (its alt is the file name, its src is empty, a local object URL previews
  // it), then uploads through the host-injected mediaUploader; when the upload
  // lands the node's src is set (one patch-block), a failure stays on the node.
  // Without an uploader the node says so instead of storing a data: URL.
  static _imageFiles(list) {
    return [...(list || [])].filter((f) => f && typeof f.type === "string" && f.type.startsWith("image/"));
  }

  _pasteImageFiles(view, event, imageAlt = null) {
    const files = BpPaperCanvas._imageFiles(event && event.clipboardData && event.clipboardData.files);
    if (!files.length) return false;
    this._insertImageFiles(view, files, null, imageAlt);
    return true;
  }

  _onDrop(view, event, moved) {
    if (!this._editable || moved || isFigureSingletonCanvas(this)) return false;
    const files = BpPaperCanvas._imageFiles(event && event.dataTransfer && event.dataTransfer.files);
    if (!files.length) return false;
    const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
    this._insertImageFiles(view, files, at ? at.pos : null);
    event.preventDefault();
    return true;
  }

  _insertImageFiles(view, files, atPos, imageAlt = null) {
    return pasteMediaMethods._insertImageFiles.call(this, view, files, atPos, imageAlt);
  }

  _findUploadNode(key) {
    return pasteMediaMethods._findUploadNode.call(this, key);
  }

  _patchUploadNode(key, receipt) {
    return pasteMediaMethods._patchUploadNode.call(this, key, receipt);
  }

  _restoreUploadResults() {
    return pasteMediaMethods._restoreUploadResults.call(this);
  }

  async _uploadImage(key, file, previewUrl) {
    const uploader = this._mediaUploader;
    const editor = this._editor;
    const initialAlt = this._findUploadNode(key)?.node.attrs.alt;
    const release = () => { if (previewUrl) { try { URL.revokeObjectURL(previewUrl); } catch (_) {} } };
    const settle = patch => {
      // A disconnected/remounted canvas must never consume an old callback.
      if (this._editor !== editor || editor.isDestroyed) return;
      const receipt = { editor, initialAlt, patch: { ...patch, uploadKey: null } };
      this._uploadResults.set(key, receipt);
      this._patchUploadNode(key, receipt);
    };
    if (typeof uploader !== "function") {
      settle({ uploading: null, uploadError: "no media uploader is connected" });
      return;
    }
    try {
      const result = await uploader(file);
      const src = result && typeof result === "object" ? result.src || result.url || "" : String(result || "");
      if (!src) throw new Error("the uploader returned no url");
      const patch = { src, uploading: null, uploadError: null, previewUrl: null };
      if (result && result.alt) patch.alt = String(result.alt);
      settle(patch);
      // Let the <img> switch to the uploaded source before the object URL goes.
      setTimeout(release, 2000);
    } catch (e) {
      settle({ uploading: null, uploadError: (e && e.message) || String(e) });
      setTimeout(release, 60000);
    }
  }

  set mediaUploader(fn) {
    return pasteMediaMethods.setMediaUploader.call(this, fn);
  }

  set mediaPicker(fn) {
    return pasteMediaMethods.setMediaPicker.call(this, fn);
  }

  get mediaPicker() {
    return pasteMediaMethods.getMediaPicker.call(this);
  }

  // Run the host's picker for the image at `pos`; its answer becomes the image's src
  // (and alt / width when given) in one undo step. null, a throw or a refused src
  // leaves it as it was.
  async _pickImageAt(pos) {
    const picker = this._mediaPicker;
    const editor = this._editor;
    if (typeof picker !== "function" || !editor || editor.isDestroyed || !this._editable) return false;
    const node = editor.state.doc.nodeAt(pos);
    if (!node || node.type.name !== "bpImage") return false;
    const id = node.attrs.bpId;
    let picked = null;
    try {
      picked = await picker({ kind: node.attrs.src ? "replace" : "insert", current: node.attrs.src ? { src: node.attrs.src, alt: node.attrs.alt || null } : null });
    } catch (_e) {
      return false;
    }
    if (this._editor !== editor || editor.isDestroyed || !picked || typeof picked.src !== "string") return false;
    // The image node paints src through the reader's allowlist (safeUrl): a src it would
    // refuse (javascript:, data:, protocol-relative) is not stored at all.
    const src = safeUrl(picked.src.trim());
    if (src === "#" || src.trim() === "") return false;
    // The image may have moved meanwhile: find it again, by id when it has one.
    let at = null;
    editor.state.doc.descendants((n, p) => {
      if (at != null) return false;
      if (n.type.name === "bpImage" && (id ? n.attrs.bpId === id : p === pos)) at = p;
      return true;
    });
    const cur = at != null ? editor.state.doc.nodeAt(at) : null;
    if (!cur) return false;
    const attrs = { ...cur.attrs, src, uploadError: null };
    if (typeof picked.alt === "string") attrs.alt = picked.alt;
    if (Number.isFinite(picked.width) && picked.width >= 16) attrs.width = Math.round(picked.width);
    editor.view.dispatch(editor.state.tr.setNodeMarkup(at, undefined, attrs));
    return true;
  }

  _pickInsertedImage() {
    return pasteMediaMethods._pickInsertedImage.call(this);
  }

  get mediaUploader() {
    return pasteMediaMethods.getMediaUploader.call(this);
  }

  _pasteHTMLTables(view, event) {
    return pasteMediaMethods._pasteHTMLTables.call(this, view, event);
  }

  _pasteMarkdown(view, event) {
    return pasteMediaMethods._pasteMarkdown.call(this, view, event);
  }

  _pastePlainText(view, event, force = false) {
    return pasteMediaMethods._pastePlainText.call(this, view, event, force);
  }

  _noteDropMoves(view, event) {
    return pasteMediaMethods._noteDropMoves.call(this, view, event);
  }

  _fitPastedSlice(slice) {
    return pasteMediaMethods._fitPastedSlice.call(this, slice);
  }

  _fitPastedNodes(fragment, imagesLeftOut = 0) {
    return pasteMediaMethods._fitPastedNodes.call(this, fragment, imagesLeftOut);
  }

  _noticeLeftOut(dropped) {
    return pasteMediaMethods._noticeLeftOut.call(this, dropped);
  }

  _showHTMLPasteNotice(message) {
    return pasteMediaMethods._showHTMLPasteNotice.call(this, message);
  }

  _clearHTMLPasteNotice() {
    return pasteMediaMethods._clearHTMLPasteNotice.call(this);
  }

  _showFigureConstraint(message = "A Figure keeps one content block. Enter cannot split or remove it.") {
    return pasteMediaMethods._showFigureConstraint.call(this, message);
  }

  _clearFigureConstraint(transaction = null) {
    return pasteMediaMethods._clearFigureConstraint.call(this, transaction);
  }

  _caretRect() {
    return pickerMethods._caretRect.call(this);
  }

  _maybeWikilink() {
    return pickerMethods._maybeWikilink.call(this);
  }

  _openWikilink(rect, query = "") {
    return pickerMethods._openWikilink.call(this, rect, query);
  }

  _closeWikilink() {
    return pickerMethods._closeWikilink.call(this);
  }

  _chooseWikilink(candidate) {
    return pickerMethods._chooseWikilink.call(this, candidate);
  }

  _dismissWikilink() {
    return pickerMethods._dismissWikilink.call(this);
  }

  set wikilinkSource(fn) {
    return pickerMethods.setWikilinkSource.call(this, fn);
  }

  get wikilinkSource() {
    return pickerMethods.getWikilinkSource.call(this);
  }

  set linkPreviewSource(fn) {
    return pickerMethods.setLinkPreviewSource.call(this, fn);
  }

  get linkPreviewSource() {
    return pickerMethods.getLinkPreviewSource.call(this);
  }

  set wikilinkResolve(fn) {
    return pickerMethods.setWikilinkResolve.call(this, fn);
  }

  get wikilinkResolve() {
    return pickerMethods.getWikilinkResolve.call(this);
  }

  refreshWikilinks() {
    return pickerMethods.refreshWikilinks.call(this);
  }

  _maybeTag() {
    return pickerMethods._maybeTag.call(this);
  }

  _maybeEmoji() {
    return pickerMethods._maybeEmoji.call(this);
  }

  _openEmoji(rect, query = "") {
    return pickerMethods._openEmoji.call(this, rect, query);
  }

  _closeEmoji() {
    return pickerMethods._closeEmoji.call(this);
  }

  _chooseEmoji(candidate) {
    return pickerMethods._chooseEmoji.call(this, candidate);
  }

  _dismissEmoji() {
    return pickerMethods._dismissEmoji.call(this);
  }

  _openTag(rect, query = "") {
    return pickerMethods._openTag.call(this, rect, query);
  }

  _closeTag() {
    return pickerMethods._closeTag.call(this);
  }

  _chooseTag(candidate) {
    return pickerMethods._chooseTag.call(this, candidate);
  }

  _dismissTag() {
    return pickerMethods._dismissTag.call(this);
  }

  set tagSource(fn) {
    return pickerMethods.setTagSource.call(this, fn);
  }

  get tagSource() {
    return pickerMethods.getTagSource.call(this);
  }

  _maybeSlash() {
    return slashPaletteMethods._maybeSlash.call(this);
  }

  _replaceTopBlockWithQuote(type) {
    return slashPaletteMethods._replaceTopBlockWithQuote.call(this, type);
  }

  _maybeBlockShorthand() {
    return slashPaletteMethods._maybeBlockShorthand.call(this);
  }

  _maybeCalloutShorthand() {
    return slashPaletteMethods._maybeCalloutShorthand.call(this);
  }

  _openSlash(query = "") {
    return slashPaletteMethods._openSlash.call(this, query);
  }

  _closeSlash() {
    return slashPaletteMethods._closeSlash.call(this);
  }

  _slashInListItem($from) {
    return slashPaletteMethods._slashInListItem.call(this, $from);
  }

  _chooseSlash(item) {
    return slashPaletteMethods._chooseSlash.call(this, item);
  }

  _insertObjectBlock(type, bpBlock, opts = {}) {
    return slashPaletteMethods._insertObjectBlock.call(this, type, bpBlock, opts);
  }

  _insertDeclaredObject(type) {
    return slashPaletteMethods._insertDeclaredObject.call(this, type);
  }

  _mastersRoot() {
    return slashPaletteMethods._mastersRoot.call(this);
  }

  _canSaveMaster(node) {
    return slashPaletteMethods._canSaveMaster.call(this, node);
  }

  _saveMaster(node) {
    return slashPaletteMethods._saveMaster.call(this, node);
  }

  _insertMaster(masterId, mode = null) {
    return slashPaletteMethods._insertMaster.call(this, masterId, mode);
  }

  _hostBuildsInserts() {
    return slashPaletteMethods._hostBuildsInserts.call(this);
  }

  _insertViaServer(type, { replaceSlashLine = false } = {}) {
    return slashPaletteMethods._insertViaServer.call(this, type, replaceSlashLine);
  }

  _dismissSlash() {
    return slashPaletteMethods._dismissSlash.call(this);
  }

  _openPalette() {
    return slashPaletteMethods._openPalette.call(this);
  }

  _closePalette() {
    return slashPaletteMethods._closePalette.call(this);
  }

  _choosePaletteCommand(cmd) {
    return slashPaletteMethods._choosePaletteCommand.call(this, cmd);
  }

  _dismissPalette() {
    return slashPaletteMethods._dismissPalette.call(this);
  }

  // ── P5 MARKDOWN SOURCE-MODE (Mod-Shift-m / palette "Toggle Markdown source") ──
  //
  // The Obsidian "source mode" analog: swap the rich ProseMirror editor for a plain
  // Markdown <textarea> and back. The SAME toggle method is bound to both triggers
  // (the keyboard shortcut in _onKeyDown and the palette command in
  // buildCommandRegistry → run()), so they are guaranteed identical.
  //
  //   rich → source : serialize the live run to markdown, including unsaved edits, stash
  //                   the original md + a deep clone of those baseline blocks, hide
  //                   the rich editor, close any open popup, show a focused textarea.
  //   source → rich : read the textarea. If the markdown is UNCHANGED (=== the stashed
  //                   original) restore the rich editor UNTOUCHED — NO re-parse, NO
  //                   setContent, ZERO ops (a no-op toggle never perturbs the doc or
  //                   the diff baseline). If EDITED, parse it back (markdownToBlocks),
  //                   REALIGN the parsed blocks' ids against the baseline (so a
  //                   surviving block keeps its id and a single in-place edit emits ONE
  //                   patch-block, not remove+insert), then setContent → onUpdate →
  //                   the existing _emitOps path diffs this._blocks → the new doc and
  //                   emits the bp-canvas-ops for exactly the user's source-mode edits.
  toggleSourceMode() { return sourceModeToggle.call(this); }
  _enterSourceMode() { return sourceModeEnter.call(this); }
  _exitSourceMode() { return sourceModeExit.call(this); }
  _commitSource(md) { return sourceModeCommit.call(this, md); }
  _syncSourceText() { return sourceModeSyncText.call(this); }
  get sourceMode() { return sourceModeActive.call(this); }
  _sizeSourceTextarea() { return sourceModeSizeTextarea.call(this); }
  _teardownSourceEl() { return sourceModeTeardown.call(this); }

  applyServerBlocksIfIdle(blocks) { return serverMethods.applyServerBlocksIfIdle.call(this, ...arguments); }
  applyServerBlocks(blocks, echoMeta = null) { return serverMethods.applyServerBlocks.call(this, ...arguments); }
  _stampOwnEchoIds(idWrites, serverBlocks) { return serverMethods._stampOwnEchoIds.call(this, ...arguments); }
  _stampMaterializedIds(stableDoc, nextDoc, { dryRun = false } = {}) {
    return serverMethods._stampMaterializedIds.call(this, ...arguments);
  }
  _isEditingNow() { return serverMethods._isEditingNow.call(this, ...arguments); }
  _applyExternalContent(blocks) { return serverMethods._applyExternalContent.call(this, ...arguments); }

  _captureCaret() { return focusMethods._captureCaret.call(this, ...arguments); }
  _restoreCaret(caret) { return focusMethods._restoreCaret.call(this, ...arguments); }
  _restSelectionOffAtom() { return focusMethods._restSelectionOffAtom.call(this, ...arguments); }
  focusBlock(id) { return focusMethods.focusBlock.call(this, ...arguments); }
  selectBlock(id) { return focusMethods.selectBlock.call(this, ...arguments); }
  _enterFromLockedTitle() { return focusMethods._enterFromLockedTitle.call(this, ...arguments); }
  _focusBodyFrom(startIndex = 0) { return focusMethods._focusBodyFrom.call(this, ...arguments); }
  focusSelection() { return focusMethods.focusSelection.call(this, ...arguments); }
  focusFirstBodyBlock() { return focusMethods.focusFirstBodyBlock.call(this, ...arguments); }
  _focusBodyAfterRun() { return focusMethods._focusBodyAfterRun.call(this, ...arguments); }
  _topLevelPos(id) { return focusMethods._topLevelPos.call(this, ...arguments); }
  _consumePendingFocus() { return focusMethods._consumePendingFocus.call(this, ...arguments); }

  _takeServerBlocks(remote) { return serverMethods._takeServerBlocks.call(this, ...arguments); }
  _mergePendingServerBlocks() { return serverMethods._mergePendingServerBlocks.call(this, ...arguments); }
  _canMergeRemote() { return serverMethods._canMergeRemote.call(this, ...arguments); }
  _mergeRemote(remote) { return serverMethods._mergeRemote.call(this, ...arguments); }
  _applyWholeSnapshot(remote) { return serverMethods._applyWholeSnapshot.call(this, ...arguments); }
  _caretBlockIndexes() { return serverMethods._caretBlockIndexes.call(this, ...arguments); }
  _reportHeld(held) { return serverMethods._reportHeld.call(this, ...arguments); }
  _queueServerBlocks(blocks) { return serverMethods._queueServerBlocks.call(this, ...arguments); }
  _flushPendingServerBlocks() { return serverMethods._flushPendingServerBlocks.call(this, ...arguments); }
  _clearPendingServerBlocks() { return serverMethods._clearPendingServerBlocks.call(this, ...arguments); }

  _upgradeProperty(name) { return lifecycleMethods._upgradeProperty.call(this, ...arguments); }
  set blocks(value) { return lifecycleMethods.setBlocks.call(this, ...arguments); }
  _createEditorSafely(factory) { return lifecycleMethods._createEditorSafely.call(this, ...arguments); }
  _verifyPainted(stage) { return lifecycleMethods._verifyPainted.call(this, ...arguments); }
  _failMount(stage, error) { return lifecycleMethods._failMount.call(this, ...arguments); }
  get blocks() { return lifecycleMethods.getBlocks.call(this, ...arguments); }
  set acknowledgedSaves(value) { return lifecycleMethods.setAcknowledgedSaves.call(this, ...arguments); }
  set liveRemote(value) { return lifecycleMethods.setLiveRemote.call(this, ...arguments); }
  get liveRemote() { return lifecycleMethods.getLiveRemote.call(this, ...arguments); }
  set flushKeepsSource(value) { return lifecycleMethods.setFlushKeepsSource.call(this, ...arguments); }
  get flushKeepsSource() { return lifecycleMethods.getFlushKeepsSource.call(this, ...arguments); }
  get acknowledgedSaves() { return lifecycleMethods.getAcknowledgedSaves.call(this, ...arguments); }
}

if (!customElements.get("bp-paper-canvas")) {
  customElements.define("bp-paper-canvas", BpPaperCanvas);
}

export { BpPaperCanvas };
export { ReaderTextAlign } from "./canvas-editor-policy.js";
