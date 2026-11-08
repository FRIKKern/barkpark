import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

const encode = (owner, name) => {
  const descriptor = Object.getOwnPropertyDescriptor(owner, name);
  const flags = `${Number(descriptor.enumerable)}${Number(descriptor.configurable)}`;
  if (Object.hasOwn(descriptor, "value")) {
    const writable = Number(descriptor.writable);
    if (typeof descriptor.value === "function") {
      return `${name}|value|${flags}${writable}|function|${descriptor.value.name}|${descriptor.value.length}`;
    }
    if (name === "prototype") return `${name}|value|${flags}${writable}|prototype`;
    return `${name}|value|${flags}${writable}|${typeof descriptor.value}|${JSON.stringify(descriptor.value)}`;
  }
  const getter = descriptor.get ? `${descriptor.get.name}:${descriptor.get.length}` : "-";
  const setter = descriptor.set ? `${descriptor.set.name}:${descriptor.set.length}` : "-";
  return `${name}|accessor|${flags}|${getter}|${setter}`;
};

const expected = {
  "exports": [
    "BpPaperCanvas",
    "ReaderTextAlign"
  ],
  "prototype": [
    "_afterComposition|value|011|function|_afterComposition|0",
    "_applyExternalContent|value|011|function|_applyExternalContent|1",
    "_applyWholeSnapshot|value|011|function|_applyWholeSnapshot|1",
    "_armComposeEndEmit|value|011|function|_armComposeEndEmit|0",
    "_canInsertInline|value|011|function|_canInsertInline|2",
    "_canMergeRemote|value|011|function|_canMergeRemote|0",
    "_canSaveMaster|value|011|function|_canSaveMaster|1",
    "_cancelResumeFocus|value|011|function|_cancelResumeFocus|0",
    "_captureCaret|value|011|function|_captureCaret|0",
    "_caretBlockIndexes|value|011|function|_caretBlockIndexes|0",
    "_caretRect|value|011|function|_caretRect|0",
    "_chooseEmoji|value|011|function|_chooseEmoji|1",
    "_choosePaletteCommand|value|011|function|_choosePaletteCommand|1",
    "_chooseSlash|value|011|function|_chooseSlash|1",
    "_chooseTag|value|011|function|_chooseTag|1",
    "_chooseWikilink|value|011|function|_chooseWikilink|1",
    "_clearFigureConstraint|value|011|function|_clearFigureConstraint|0",
    "_clearHTMLPasteNotice|value|011|function|_clearHTMLPasteNotice|0",
    "_clearPendingServerBlocks|value|011|function|_clearPendingServerBlocks|0",
    "_clearResumeFocusIntent|value|011|function|_clearResumeFocusIntent|0",
    "_closeEmoji|value|011|function|_closeEmoji|0",
    "_closePalette|value|011|function|_closePalette|0",
    "_closeSlash|value|011|function|_closeSlash|0",
    "_closeTag|value|011|function|_closeTag|0",
    "_closeWikilink|value|011|function|_closeWikilink|0",
    "_commitSource|value|011|function|_commitSource|1",
    "_committedDoc|value|011|function|_committedDoc|0",
    "_consumePendingFocus|value|011|function|_consumePendingFocus|0",
    "_createEditorSafely|value|011|function|_createEditorSafely|1",
    "_dismissEmoji|value|011|function|_dismissEmoji|0",
    "_dismissPalette|value|011|function|_dismissPalette|0",
    "_dismissSlash|value|011|function|_dismissSlash|0",
    "_dismissTag|value|011|function|_dismissTag|0",
    "_dismissWikilink|value|011|function|_dismissWikilink|0",
    "_dispatchOps|value|011|function|_dispatchOps|1",
    "_emitHistory|value|011|function|_emitHistory|1",
    "_emitOps|value|011|function|_emitOps|0",
    "_emitReuse|value|011|function|_emitReuse|1",
    "_enterFromLockedTitle|value|011|function|_enterFromLockedTitle|0",
    "_enterSourceMode|value|011|function|_enterSourceMode|0",
    "_escapeForHost|value|011|function|_escapeForHost|2",
    "_exitSourceMode|value|011|function|_exitSourceMode|0",
    "_failMount|value|011|function|_failMount|2",
    "_findUploadNode|value|011|function|_findUploadNode|1",
    "_fitPastedNodes|value|011|function|_fitPastedNodes|1",
    "_fitPastedSlice|value|011|function|_fitPastedSlice|1",
    "_flushDomSelection|value|011|function|_flushDomSelection|0",
    "_flushPendingServerBlocks|value|011|function|_flushPendingServerBlocks|0",
    "_focusBodyAfterRun|value|011|function|_focusBodyAfterRun|0",
    "_focusBodyFrom|value|011|function|_focusBodyFrom|0",
    "_hostBuildsInserts|value|011|function|_hostBuildsInserts|0",
    "_inlineObjectDialog|value|011|function|_inlineObjectDialog|0",
    "_inlineObjectVocabulary|value|011|function|_inlineObjectVocabulary|0",
    "_insertDeclaredObject|value|011|function|_insertDeclaredObject|1",
    "_insertImageFiles|value|011|function|_insertImageFiles|3",
    "_insertMaster|value|011|function|_insertMaster|1",
    "_insertObjectBlock|value|011|function|_insertObjectBlock|2",
    "_insertToolbarBlock|value|011|function|_insertToolbarBlock|2",
    "_insertToolbarInline|value|011|function|_insertToolbarInline|1",
    "_insertViaServer|value|011|function|_insertViaServer|1",
    "_isEditingNow|value|011|function|_isEditingNow|0",
    "_mastersRoot|value|011|function|_mastersRoot|0",
    "_maybeBlockShorthand|value|011|function|_maybeBlockShorthand|0",
    "_maybeCalloutShorthand|value|011|function|_maybeCalloutShorthand|0",
    "_maybeEmoji|value|011|function|_maybeEmoji|0",
    "_maybeSlash|value|011|function|_maybeSlash|0",
    "_maybeTag|value|011|function|_maybeTag|0",
    "_maybeWikilink|value|011|function|_maybeWikilink|0",
    "_mergePendingServerBlocks|value|011|function|_mergePendingServerBlocks|0",
    "_mergeRemote|value|011|function|_mergeRemote|1",
    "_modEnterForHost|value|011|function|_modEnterForHost|2",
    "_normalizedDoc|value|011|function|_normalizedDoc|1",
    "_noteDropMoves|value|011|function|_noteDropMoves|2",
    "_noteInlineObjectSave|value|011|function|_noteInlineObjectSave|1",
    "_noticeLeftOut|value|011|function|_noticeLeftOut|1",
    "_objectEditorOpen|value|011|function|_objectEditorOpen|0",
    "_objectOverrides|value|011|function|_objectOverrides|0",
    "_onDrop|value|011|function|_onDrop|3",
    "_onKeyDown|value|011|function|_onKeyDown|1",
    "_onPaste|value|011|function|_onPaste|3",
    "_openEmoji|value|011|function|_openEmoji|1",
    "_openPalette|value|011|function|_openPalette|0",
    "_openSlash|value|011|function|_openSlash|0",
    "_openTag|value|011|function|_openTag|1",
    "_openWikilink|value|011|function|_openWikilink|1",
    "_pasteHTMLTables|value|011|function|_pasteHTMLTables|2",
    "_pasteImageFiles|value|011|function|_pasteImageFiles|2",
    "_pasteMarkdown|value|011|function|_pasteMarkdown|2",
    "_pastePlainText|value|011|function|_pastePlainText|2",
    "_patchUploadNode|value|011|function|_patchUploadNode|2",
    "_pickImageAt|value|011|function|_pickImageAt|1",
    "_pickInsertedImage|value|011|function|_pickInsertedImage|0",
    "_queueServerBlocks|value|011|function|_queueServerBlocks|1",
    "_re|value|011|function|_re|0",
    "_readDomTyping|value|011|function|_readDomTyping|0",
    "_rememberEmit|value|011|function|_rememberEmit|4",
    "_reopenRefusedInlineObject|value|011|function|_reopenRefusedInlineObject|1",
    "_replaceTopBlockWithQuote|value|011|function|_replaceTopBlockWithQuote|1",
    "_reportHeld|value|011|function|_reportHeld|1",
    "_requestHostLink|value|011|function|_requestHostLink|0",
    "_restSelectionOffAtom|value|011|function|_restSelectionOffAtom|0",
    "_restoreCaret|value|011|function|_restoreCaret|1",
    "_restoreUploadResults|value|011|function|_restoreUploadResults|0",
    "_ro|value|011|function|_ro|0",
    "_rt|value|011|function|_rt|1",
    "_saveMaster|value|011|function|_saveMaster|1",
    "_scheduleCommentRangesEmit|value|011|function|_scheduleCommentRangesEmit|0",
    "_scheduleEmit|value|011|function|_scheduleEmit|0",
    "_scheduleSelectionEmit|value|011|function|_scheduleSelectionEmit|0",
    "_scheduleToolbarState|value|011|function|_scheduleToolbarState|0",
    "_showFigureConstraint|value|011|function|_showFigureConstraint|0",
    "_showHTMLPasteNotice|value|011|function|_showHTMLPasteNotice|1",
    "_sizeSourceTextarea|value|011|function|_sizeSourceTextarea|0",
    "_slashInListItem|value|011|function|_slashInListItem|1",
    "_stampMaterializedIds|value|011|function|_stampMaterializedIds|2",
    "_stampOwnEchoIds|value|011|function|_stampOwnEchoIds|2",
    "_swallowModEnter|value|011|function|_swallowModEnter|1",
    "_syncSourceText|value|011|function|_syncSourceText|0",
    "_takeServerBlocks|value|011|function|_takeServerBlocks|1",
    "_teardownDisconnected|value|011|function|_teardownDisconnected|0",
    "_teardownSourceEl|value|011|function|_teardownSourceEl|0",
    "_toolbarInsertItem|value|011|function|_toolbarInsertItem|1",
    "_toolbarVocabulary|value|011|function|_toolbarVocabulary|0",
    "_topLevelPos|value|011|function|_topLevelPos|1",
    "_upgradeProperty|value|011|function|_upgradeProperty|1",
    "_uploadImage|value|011|function|_uploadImage|3",
    "_verifyPainted|value|011|function|_verifyPainted|1",
    "_wantsBubble|value|011|function|_wantsBubble|0",
    "_wikilinkClicked|value|011|function|_wikilinkClicked|1",
    "acknowledgeOps|value|011|function|acknowledgeOps|2",
    "acknowledgedSaves|accessor|01|get acknowledgedSaves:0|set acknowledgedSaves:1",
    "applyServerBlocks|value|011|function|applyServerBlocks|1",
    "applyServerBlocksIfIdle|value|011|function|applyServerBlocksIfIdle|1",
    "attributeChangedCallback|value|011|function|attributeChangedCallback|3",
    "blocks|accessor|01|get blocks:0|set blocks:1",
    "can|value|011|function|can|1",
    "captureResumeFocus|value|011|function|captureResumeFocus|0",
    "commentRanges|value|011|function|commentRanges|0",
    "commentsInSelection|value|011|function|commentsInSelection|0",
    "connectedCallback|value|011|function|connectedCallback|0",
    "constructor|value|011|function|BpPaperCanvas|0",
    "discardInflightOps|value|011|function|discardInflightOps|2",
    "disconnectedCallback|value|011|function|disconnectedCallback|0",
    "editBlockObject|accessor|01|get editBlockObject:0|set editBlockObject:1",
    "findClear|value|011|function|findClear|0",
    "findNext|value|011|function|findNext|0",
    "findPrev|value|011|function|findPrev|0",
    "findSet|value|011|function|findSet|2",
    "findState|value|011|function|findState|0",
    "flushKeepsSource|accessor|01|get flushKeepsSource:0|set flushKeepsSource:1",
    "flushPendingChanges|value|011|function|flushPendingChanges|0",
    "focusBlock|value|011|function|focusBlock|1",
    "focusFirstBodyBlock|value|011|function|focusFirstBodyBlock|0",
    "focusSelection|value|011|function|focusSelection|0",
    "hasPendingChanges|value|011|function|hasPendingChanges|0",
    "identifyOpsRequest|value|011|function|identifyOpsRequest|2",
    "insertBlock|value|011|function|insertBlock|2",
    "insertInline|value|011|function|insertInline|1",
    "linkPreviewSource|accessor|01|get linkPreviewSource:0|set linkPreviewSource:1",
    "liveRemote|accessor|01|get liveRemote:0|set liveRemote:1",
    "localEditsRebaseSafe|value|011|function|localEditsRebaseSafe|1",
    "mediaPicker|accessor|01|get mediaPicker:0|set mediaPicker:1",
    "mediaUploader|accessor|01|get mediaUploader:0|set mediaUploader:1",
    "rebaseSafe|value|011|function|rebaseSafe|2",
    "recoverySnapshot|value|011|function|recoverySnapshot|0",
    "redo|value|011|function|redo|0",
    "refreshWikilinks|value|011|function|refreshWikilinks|0",
    "replaceAll|value|011|function|replaceAll|1",
    "replaceCurrent|value|011|function|replaceCurrent|1",
    "resendPendingOps|value|011|function|resendPendingOps|0",
    "resolveConflictWithServerBlocks|value|011|function|resolveConflictWithServerBlocks|1",
    "restoreResumeFocus|value|011|function|restoreResumeFocus|0",
    "run|value|011|function|run|1",
    "selectBlock|value|011|function|selectBlock|1",
    "setBlockStyle|value|011|function|setBlockStyle|1",
    "setCommentRanges|value|011|function|setCommentRanges|1",
    "setRemoteSelections|value|011|function|setRemoteSelections|1",
    "sourceMode|accessor|01|get sourceMode:0|-",
    "state|value|011|function|state|0",
    "tagSource|accessor|01|get tagSource:0|set tagSource:1",
    "toggleList|value|011|function|toggleList|1",
    "toggleMark|value|011|function|toggleMark|2",
    "toggleSourceMode|value|011|function|toggleSourceMode|0",
    "undo|value|011|function|undo|0",
    "wikilinkResolve|accessor|01|get wikilinkResolve:0|set wikilinkResolve:1",
    "wikilinkSource|accessor|01|get wikilinkSource:0|set wikilinkSource:1"
  ],
  "static": [
    "BUILD_SHA|value|111|object|null",
    "CONTRACT_VERSION|value|111|string|\"1.22.0\"",
    "EDITOR_VERSION|value|111|string|\"0.1.0-alpha.1\"",
    "_imageFiles|value|011|function|_imageFiles|1",
    "length|value|010|number|0",
    "name|value|010|string|\"BpPaperCanvas\"",
    "observedAttributes|accessor|01|get observedAttributes:0|-",
    "prototype|value|000|prototype"
  ],
  "observedAttributes": [
    "editable",
    "format-bubble"
  ]
};

assert.equal(customElements.get("bp-paper-canvas"), undefined, "registration happens only when the canvas module loads");
const definitions = [];
const define = customElements.define.bind(customElements);
customElements.define = (name, constructor, options) => {
  definitions.push({ name, constructor, options });
  return define(name, constructor, options);
};

const module = await import("./index.js");
const { BpPaperCanvas } = module;
const actual = {
  exports: Object.keys(module).sort(),
  prototype: Object.getOwnPropertyNames(BpPaperCanvas.prototype).sort()
    .map((name) => encode(BpPaperCanvas.prototype, name)),
  static: Object.getOwnPropertyNames(BpPaperCanvas).sort()
    .map((name) => encode(BpPaperCanvas, name)),
  observedAttributes: BpPaperCanvas.observedAttributes,
};

assert.deepEqual(actual, expected, "the complete canvas export, prototype, static and attribute manifest stays fixed");
assert.equal(BpPaperCanvas.prototype.constructor, BpPaperCanvas, "the prototype keeps the exported constructor");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas, "the registered constructor is the named export");
assert.equal(definitions.length, 1, "module load registers the canvas exactly once");
assert.deepEqual(definitions[0], {
  name: "bp-paper-canvas",
  constructor: BpPaperCanvas,
  options: undefined,
});
const element = document.createElement("bp-paper-canvas");
assert.equal(element.constructor, BpPaperCanvas);
assert.equal(element.localName, "bp-paper-canvas");
assert.equal(BpPaperCanvas.CONTRACT_VERSION, "1.22.0");
assert.equal(BpPaperCanvas.EDITOR_VERSION, "0.1.0-alpha.1");
assert.equal(BpPaperCanvas.BUILD_SHA, null, "unbuilt source keeps BUILD_SHA null");

const guarded = await import(`./index.js?registration-guard=${Date.now()}`);
assert.notEqual(guarded.BpPaperCanvas, BpPaperCanvas, "the guard probe evaluates a fresh module class");
assert.equal(definitions.length, 1, "a second module evaluation does not redefine an existing element");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas, "the first registered constructor remains authoritative");

const focused = new Map([
  ["toggleSourceMode", ["value", 0]],
  ["_enterSourceMode", ["value", 0]],
  ["_exitSourceMode", ["value", 0]],
  ["_commitSource", ["value", 1]],
  ["_syncSourceText", ["value", 0]],
  ["sourceMode", ["accessor", 0]],
  ["_sizeSourceTextarea", ["value", 0]],
  ["_teardownSourceEl", ["value", 0]],
]);
for (const [name, [kind, length]] of focused) {
  const descriptor = Object.getOwnPropertyDescriptor(BpPaperCanvas.prototype, name);
  assert.ok(descriptor, `${name} remains an own prototype member`);
  assert.equal(Object.hasOwn(descriptor, "value") ? "value" : "accessor", kind, `${name} descriptor kind`);
  if (kind === "value") assert.equal(descriptor.value.length, length, `${name} arity`);
  else {
    assert.equal(descriptor.get.length, length, `${name} getter arity`);
    assert.equal(descriptor.set, undefined, `${name} stays readonly`);
  }
}

const here = dirname(fileURLToPath(import.meta.url));
const canvasSource = readFileSync(join(here, "index.js"), "utf8");
const sourceModeSource = readFileSync(join(here, "source-mode.js"), "utf8");
const figureSource = readFileSync(join(here, "figure-context.js"), "utf8");
const wrappers = [
  ["toggleSourceMode", "sourceModeToggle", ""],
  ["_enterSourceMode", "sourceModeEnter", ""],
  ["_exitSourceMode", "sourceModeExit", ""],
  ["_commitSource", "sourceModeCommit", "md"],
  ["_syncSourceText", "sourceModeSyncText", ""],
  ["sourceMode", "sourceModeActive", "getter"],
  ["_sizeSourceTextarea", "sourceModeSizeTextarea", ""],
  ["_teardownSourceEl", "sourceModeTeardown", ""],
];
for (const [member, implementation, argument] of wrappers) {
  const expected = argument === "getter"
    ? `get ${member}() { return ${implementation}.call(this); }`
    : `${member}(${argument}) { return ${implementation}.call(this${argument ? `, ${argument}` : ""}); }`;
  assert.equal(canvasSource.split(expected).length - 1, 1, `${member} has one exact synchronous facade`);
  assert.equal(sourceModeSource.split(`export function ${implementation}(`).length - 1, 1,
    `${implementation} has one named implementation`);
}

const sentinel = new Error("synchronous source-mode sentinel");
const receiver = {
  _editor: {},
  _editable: true,
  _blocks: [],
  _mode: "rich",
  closest: () => null,
  _enterSourceMode() { throw sentinel; },
};
assert.throws(
  () => BpPaperCanvas.prototype.toggleSourceMode.call(receiver),
  (error) => error === sentinel,
  "the facade keeps the receiver and throws synchronously without a fallback",
);
assert.equal(
  Object.getOwnPropertyDescriptor(BpPaperCanvas.prototype, "sourceMode").get.call({ _mode: "source" }),
  true,
  "the getter returns the child implementation result for the same receiver",
);

const importSources = (source) => [...source.matchAll(/\bfrom\s+["']([^"']+)["']/g)].map((match) => match[1]);
assert.deepEqual(importSources(sourceModeSource).sort(), [
  "../i18n.js",
  "../markdown.js",
  "./figure-context.js",
  "./run-convert.js",
  "./source-realign.js",
]);
assert.deepEqual(importSources(figureSource), [], "the Figure predicate stays dependency-free");
for (const [name, source] of [["source-mode.js", sourceModeSource], ["figure-context.js", figureSource]]) {
  assert.ok(source.split("\n").length < 800, `${name} stays below 800 lines`);
  assert.doesNotMatch(source, /\b(?:from\s+|import\s*)["']\.\/index\.js["']/,
    `${name} never imports the facade`);
  assert.doesNotMatch(source, /customElements\s*\.\s*define/, `${name} has no registration side effect`);
}
assert.equal(canvasSource.split('from "./source-mode.js"').length - 1, 1);
assert.equal(canvasSource.split('from "./figure-context.js"').length - 1, 1);
assert.equal(sourceModeSource.split('from "./figure-context.js"').length - 1, 1);

const productionFiles = [];
const walk = (directory) => {
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (name.endsWith(".js")) productionFiles.push(path);
  }
};
walk(join(here, ".."));
const figureDefinitions = productionFiles.flatMap((path) => {
  const source = readFileSync(path, "utf8");
  return [...source.matchAll(/\bfunction\s+isFigureSingletonCanvas\s*\(/g)].map(() => path);
});
assert.deepEqual(figureDefinitions, [join(here, "figure-context.js")],
  "the Figure predicate has one production definition");
assert.match(canvasSource, /isFigureSingletonCanvas\(this\)/, "the facade veto and paste paths use the predicate");
assert.match(sourceModeSource, /isFigureSingletonCanvas\(this\)/, "source mode uses the shared predicate");

const lifecycle = document.createElement("bp-paper-canvas");
lifecycle.acknowledgedSaves = true;
lifecycle.flushKeepsSource = true;
lifecycle.blocks = [{
  id: "source-boundary",
  type: "paragraph",
  content: [{ type: "text", value: "Boundary" }],
}];
lifecycle.addEventListener("bp-canvas-ops", (event) => lifecycle.acknowledgeOps(event.detail.seq, true));
document.body.appendChild(lifecycle);
await new Promise((resolve) => setTimeout(resolve, 350));
lifecycle._editor.commands.setTextSelection(2);
const noEditDoc = lifecycle._editor.state.doc;
const noEditSelection = lifecycle._editor.state.selection.toJSON();
lifecycle.toggleSourceMode();
lifecycle.toggleSourceMode();
assert.equal(lifecycle._editor.state.doc, noEditDoc, "an unchanged source toggle keeps the exact rich document");
assert.deepEqual(lifecycle._editor.state.selection.toJSON(), noEditSelection,
  "an unchanged source toggle keeps the rich selection");
lifecycle.toggleSourceMode();
const sourceTextarea = lifecycle._sourceEl;
const valueDescriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(sourceTextarea), "value");
let sourceValueWrites = 0;
Object.defineProperty(sourceTextarea, "value", {
  configurable: true,
  get() { return valueDescriptor.get.call(this); },
  set(value) { sourceValueWrites++; valueDescriptor.set.call(this, value); },
});
lifecycle.liveRemote = true;
const liveRemote = [{
  id: "source-boundary",
  type: "paragraph",
  content: [{ type: "text", value: "Live remote boundary" }],
}];
lifecycle.applyServerBlocks(liveRemote);
assert.equal(lifecycle._sourceEl, sourceTextarea, "a live remote sync keeps the same textarea node");
assert.equal(sourceValueWrites, 0, "a live remote sync uses a range edit, preserving native textarea undo");
assert.equal(sourceTextarea.value, "Live remote boundary");
lifecycle.liveRemote = false;
let pendingFlushCalls = 0;
const flushPendingServerBlocks = lifecycle._flushPendingServerBlocks;
lifecycle._flushPendingServerBlocks = function () {
  pendingFlushCalls++;
  return flushPendingServerBlocks.call(this);
};
lifecycle.toggleSourceMode();
assert.equal(pendingFlushCalls, 1, "leaving source mode always releases queued server authority last");
lifecycle.toggleSourceMode();
const detachedTextarea = lifecycle._sourceEl;
assert.ok(detachedTextarea, "the lifecycle probe entered source mode");
lifecycle.remove();
await Promise.resolve();
let detachedToggles = 0;
lifecycle.toggleSourceMode = () => detachedToggles++;
detachedTextarea.dispatchEvent(new window.KeyboardEvent("keydown", {
  key: "m",
  ctrlKey: true,
  shiftKey: true,
  bubbles: true,
  cancelable: true,
}));
assert.equal(detachedToggles, 0, "disconnect removes the exact source keydown listener");

console.log("source mode boundary: baseline public surface passed");
window.close();
