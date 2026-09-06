import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const source = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");
const dom = new JSDOM(`<main data-paper-doc-key="production:paper:stage" data-paper-rev="7">
  <button id="view" data-editing="true">View</button>
  <form id="stage" class="bp-paper-edit-form" phx-change="paper-block-autosave" phx-debounce="500">
    <input name="block_id" type="hidden" value="stage">
    <textarea name="stage-title">Original title</textarea>
    <textarea name="stage-detail">Preserve detail</textarea>
    <input name="stage-source-mode" value="provenance">
    <input name="stage-source-text" value="queue.ex:42">
  </form>
</main>`, { url: "http://localhost/" });
const { window } = dom;
let resizeCallback;
let disconnected = false;
window.ResizeObserver = class {
  constructor(callback) { resizeCallback = callback; }
  observe() {}
  disconnect() { disconnected = true; }
};
vm.runInContext(source, vm.createContext({
  window, document: window.document, CustomEvent: window.CustomEvent,
  FormData: window.FormData, Date, setTimeout, clearTimeout, console,
  customElements: { whenDefined: () => Promise.resolve() },
}));
const textarea = window.document.querySelector("textarea");
let measuredHeight = 20;
Object.defineProperty(textarea, "scrollHeight", { get: () => measuredHeight });
const sizing = { ...window.BarkparkPaperEditorHooks.BarkparkPaperAutoSize, el: textarea };
sizing.mounted();
assert.equal(textarea.style.height, "20px");
textarea.focus();
textarea.setSelectionRange(2, 5);
measuredHeight = 60;
sizing.updated();
assert.equal(textarea.style.height, "60px");
assert.equal(textarea.value, "Original title");
assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [2, 5]);
measuredHeight = 20;
resizeCallback([{ contentRect: { width: 320 } }]);
assert.equal(textarea.style.height, "20px", "shrinks after a wider viewport");

const calls = [];
const toggles = [];
let reply;
const toggle = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
  el: window.document.querySelector("button"),
  pushEvent(event) { toggles.push(event); return Promise.resolve({}); },
  pushEventTo(_target, event, payload) {
    calls.push({ event, payload });
    return new Promise(resolve => { reply = resolve; });
  },
};
toggle.mounted();
textarea.value = "Typed directly on the paper";
textarea.dispatchEvent(new window.Event("input", { bubbles: true }));
toggle.el.click();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(calls.length, 1, "View flushes the textarea before its debounce");
assert.equal(calls[0].payload["stage-title"], textarea.value);
assert.equal(calls[0].payload["stage-detail"], "Preserve detail");
assert.equal(calls[0].payload["stage-source-text"], "queue.ex:42");
assert.equal(calls[0].payload.if_rev, 7);
assert.deepEqual(toggles, [], "View waits for the save acknowledgement");
reply([{ status: "fulfilled", value: { reply: {
  saved: true, request_id: calls[0].payload.request_id, rev: 8,
} } }]);
await new Promise(resolve => setTimeout(resolve, 0));
assert.deepEqual(toggles, ["paper-toggle-edit"]);
sizing.destroyed();
measuredHeight = 100;
resizeCallback([{ contentRect: { width: 200 } }]);
assert.equal(textarea.style.height, "20px", "late observer callbacks do not touch disposed fields");
assert.equal(disconnected, true);
toggle.destroyed();
dom.window.close();
console.log("PASS inline text: native selection, grow/shrink, cleanup and acknowledged immediate View");
