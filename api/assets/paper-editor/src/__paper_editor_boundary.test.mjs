// Contract for the <bp-paper-editor> facade boundary and its mounted async
// autocomplete guards. Child-module assertions are added only after extraction;
// this first stage must pass against the untouched monolith.

import assert from "node:assert/strict";
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
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Element.prototype.scrollIntoView ||= () => {};
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({
  top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0,
});

const definitions = [];
const define = customElements.define.bind(customElements);
customElements.define = (name, constructor, options) => {
  definitions.push({ name, constructor });
  return define(name, constructor, options);
};

const editorModule = await import("./index.js");
const { BpPaperEditor, CONTRACT_VERSION, DEBOUNCE_MS, PLACEHOLDER } = editorModule;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

const runtimeMethods = Object.freeze({
  flushPendingChanges: 0,
  focusSelection: 0,
  hasPendingChanges: 0,
  _filterTableTransaction: 1,
  _reportTableEditRefusal: 0,
  _clearTableEditRefusal: 0,
  _installTableProjectionDoc: 1,
  resolveConflictWithServerBlock: 1,
  _readBlock: 0,
  _scheduleEmit: 0,
  _emitOp: 0,
  _requestTableStructure: 1,
  _emitTableStructure: 0,
  waitForTableSettlement: 0,
  trackTableMutation: 2,
  tableMutationResult: 3,
  applyTableProjection: 1,
  _acceptTableStructureEcho: 0,
  _focusLastRowFirstCell: 0,
  _ensureTableSettlement: 0,
  _settleTableLifecycle: 1,
  _validTableAction: 1,
  _acceptTableProjection: 1,
});

const autocompleteMethods = Object.freeze({
  _maybeSlash: 0,
  _maybeCalloutShorthand: 0,
  _openSlash: 0,
  _closeSlash: 0,
  _caretRect: 0,
  _onKeyDown: 1,
  _chooseSlash: 1,
  _emitSlashInsert: 1,
  _dismissSlash: 0,
  _maybeWikilink: 0,
  _openWikilink: 1,
  _closeWikilink: 0,
  _chooseWikilink: 1,
  _dismissWikilink: 0,
  _maybeTag: 0,
  _openTag: 1,
  _closeTag: 0,
  _chooseTag: 1,
  _dismissTag: 0,
});

const prototypeNames = [
  "constructor", "connectedCallback", "attributeChangedCallback", "disconnectedCallback",
  ...Object.keys(runtimeMethods).slice(0, -1),
  ...Object.keys(autocompleteMethods).slice(0, 14),
  "wikilinkSource",
  ...Object.keys(autocompleteMethods).slice(14),
  "tagSource", "_upgradeProperty", "block", "_acceptTableProjection",
];

assert.deepEqual(Object.keys(editorModule).sort(), [
  "BpPaperEditor", "CONTRACT_VERSION", "DEBOUNCE_MS", "PLACEHOLDER",
]);
assert.deepEqual(Object.getOwnPropertyNames(BpPaperEditor.prototype), prototypeNames);
assert.equal(BpPaperEditor.CONTRACT_VERSION, CONTRACT_VERSION);
assert.equal(BpPaperEditor.EDITOR_VERSION, "0.1.0-alpha.1");
assert.equal(BpPaperEditor.BUILD_SHA, null);
assert.equal(CONTRACT_VERSION, "1.22.0");
assert.equal(DEBOUNCE_MS, 300);
assert.equal(PLACEHOLDER.paragraph, "Start typing, or press / for blocks…");
assert.deepEqual(BpPaperEditor.observedAttributes, ["editable"]);

for (const [name, length] of Object.entries({ ...runtimeMethods, ...autocompleteMethods })) {
  const descriptor = Object.getOwnPropertyDescriptor(BpPaperEditor.prototype, name);
  assert.deepEqual(
    { name: descriptor.value.name, length: descriptor.value.length, writable: descriptor.writable,
      enumerable: descriptor.enumerable, configurable: descriptor.configurable },
    { name, length, writable: true, enumerable: false, configurable: true },
    `${name} method descriptor`,
  );
}
for (const name of ["wikilinkSource", "tagSource", "block"]) {
  const descriptor = Object.getOwnPropertyDescriptor(BpPaperEditor.prototype, name);
  assert.equal(descriptor.get.name, `get ${name}`);
  assert.equal(descriptor.set.name, `set ${name}`);
  assert.equal(descriptor.enumerable, false);
  assert.equal(descriptor.configurable, true);
}
assert.deepEqual(definitions.map(({ name }) => name), ["bp-paper-canvas", "bp-paper-editor"]);
assert.equal(definitions.filter(({ name }) => name === "bp-paper-canvas").length, 1);
assert.equal(definitions.filter(({ name }) => name === "bp-paper-editor").length, 1);
assert.equal(customElements.get("bp-paper-canvas"), definitions[0].constructor);
assert.equal(customElements.get("bp-paper-editor"), BpPaperEditor);

const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};

function replaceText(editor, text) {
  editor.commands.selectAll();
  assert.equal(editor.commands.insertContent(text), true);
}

function escape(editor) {
  editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", {
    key: "Escape", bubbles: true, cancelable: true,
  }));
}

async function proveAsyncGuard(family) {
  const trigger = family === "wikilink" ? "[[" : "#";
  const expectedTitle = family === "wikilink" ? "Wiki newer" : "#tag-newer";
  const lateTitle = family === "wikilink" ? "Wiki late" : "#tag-late";
  const requests = new Map();
  const queryOrder = [];
  const host = document.createElement("bp-paper-editor");
  host.block = { id: `${family}-block`, type: "paragraph", content: [] };
  host[`${family}Source`] = (query) => {
    const request = deferred();
    requests.set(query, request);
    queryOrder.push(query);
    return request.promise;
  };
  document.body.appendChild(host);
  const editor = host._editor;
  assert.ok(editor?.view?.dom?.isConnected, `${family}: real mounted editor`);

  replaceText(editor, `${trigger}old`);
  await tick();
  replaceText(editor, `${trigger}new`);
  await tick();
  assert.deepEqual(queryOrder, ["old", "new"], `${family}: request order`);

  requests.get("new").resolve(family === "wikilink"
    ? [{ title: expectedTitle, id: "wiki-new", type: "paper" }]
    : ["tag-newer"]);
  await tick();
  const menu = [...document.querySelectorAll(".bp-wikilink-menu")]
    .find((candidate) => candidate.style.display === "block");
  assert.equal(menu?.querySelector(".bp-wikilink-title")?.textContent, expectedTitle);

  requests.get("old").resolve(family === "wikilink"
    ? [{ title: "Wiki older", id: "wiki-old", type: "paper" }]
    : ["tag-older"]);
  await tick();
  assert.equal(menu.querySelector(".bp-wikilink-title")?.textContent, expectedTitle,
    `${family}: older response cannot replace newer results`);

  replaceText(editor, `${trigger}late`);
  await tick();
  assert.deepEqual(queryOrder, ["old", "new", "late"], `${family}: late request recorded`);
  escape(editor);
  assert.equal(menu.style.display, "none", `${family}: keyboard close hides menu`);
  requests.get("late").resolve(family === "wikilink"
    ? [{ title: lateTitle, id: "wiki-late", type: "paper" }]
    : ["tag-late"]);
  await tick();
  assert.equal(menu.style.display, "none", `${family}: late response cannot reopen menu`);
  assert.equal(menu.querySelector(".bp-wikilink-title")?.textContent, expectedTitle,
    `${family}: post-close response cannot install results`);

  host.remove();
  await tick();
  assert.equal(menu.isConnected, false, `${family}: disconnected editor destroys menu DOM`);
}

try {
  await proveAsyncGuard("wikilink");
  await proveAsyncGuard("tag");
  console.log("paper editor facade and mounted async boundaries passed");
} finally {
  window.close();
}
