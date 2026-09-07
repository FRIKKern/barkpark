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

textarea.classList.add("bp-paper-inline-text");
textarea.style.cssText = "line-height:25.92px;padding:0;border:0";
measuredHeight = 26;
sizing.updated();
assert.equal(textarea.style.height, "25.92px", "one citation line retains the reader's fractional line height");
measuredHeight = 52;
sizing.updated();
assert.equal(textarea.style.height, "51.84px", "wrapped inline text retains exact line-box multiples");
assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [2, 5], "fractional fitting preserves selection");
textarea.style.padding = "2px";
measuredHeight = 30;
sizing.updated();
assert.equal(textarea.style.height, "30px", "padded fields retain their measured-height fallback");
textarea.style.padding = "0";
sizing.updated();
assert.equal(textarea.style.height, "30px", "unexpected content overflow is not clipped to a line multiple");
textarea.style.lineHeight = "normal";
sizing.updated();
assert.equal(textarea.style.height, "30px", "normal line height retains the measured fallback");
textarea.style.cssText = "";
textarea.classList.remove("bp-paper-inline-text");
measuredHeight = 20;
sizing.updated();

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
// A disclosure label is phrasing content inside <summary>; its form lives
// outside the disclosure so nested child forms remain valid HTML.
const summary = window.document.createElement("textarea");
summary.name = "summary";
summary.setAttribute("form", "disclosure-settings");
const settings = window.document.createElement("form");
settings.id = "disclosure-settings";
settings.className = "bp-paper-edit-form";
settings.setAttribute("phx-change", "paper-block-autosave");
settings.setAttribute("phx-debounce", "500");
settings.innerHTML = '<input name="block_id" value="disclosure">';
window.document.querySelector("main").append(summary, settings);
calls.length = 0;
toggles.length = 0;
summary.value = "Direct disclosure title";
summary.dispatchEvent(new window.Event("input", { bubbles: true }));
toggle.el.click();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(calls.length, 1, "View must flush form-associated text outside the form");
assert.equal(calls[0].payload.summary, "Direct disclosure title");
assert.equal(calls[0].payload.open, undefined, "summary edits never send default-open settings");
assert.deepEqual(toggles, [], "external text retains the same acknowledged exit barrier");
reply([{ status: "fulfilled", value: { reply: {
  saved: true, request_id: calls[0].payload.request_id, rev: 9,
} } }]);
await new Promise(resolve => setTimeout(resolve, 0));
assert.deepEqual(toggles, ["paper-toggle-edit"]);
// LiveView preserves a focused native field's value during a remote repaint.
// A later keystroke must still be authored against the revision the user saw.
summary.focus();
const coordinator = toggle._bpPaperExitCoordinator;
assert.equal(coordinator.hasUnsaved(), false, "focus alone is not an unsaved edit");
coordinator.observeRevision({ rev: 10, apply: () => {
  window.document.querySelector("main").dataset.paperRev = "10";
} });
summary.blur();
summary.focus();
calls.length = 0;
toggles.length = 0;
summary.value = "Competing focused title";
summary.dispatchEvent(new window.Event("input", { bubbles: true }));
toggle.el.click();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(calls[0].payload.if_rev, 9, "blur/refocus cannot silently adopt a revision skipped while focused");
reply([{ status: "fulfilled", value: { reply: {
  saved: false, conflict: true, request_id: calls[0].payload.request_id, current_rev: 10,
} } }]);
await new Promise(resolve => setTimeout(resolve, 0));
assert.deepEqual(toggles, [], "the native conflict retains the editor");
const keep = window.document.querySelector('[data-bp-paper-conflict] [data-action="keep"]');
assert.ok(keep && !keep.disabled, "explicit native text conflict can be reviewed and kept");
keep.click();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(calls[1].payload.if_rev, 10);
assert.notEqual(calls[1].payload.request_id, calls[0].payload.request_id);
reply([{ status: "fulfilled", value: { reply: {
  saved: true, request_id: calls[1].payload.request_id, rev: 11,
} } }]);
await new Promise(resolve => setTimeout(resolve, 0));
coordinator.observeRevision({ rev: 12, apply: () => {
  window.document.querySelector("main").dataset.paperRev = "12";
} });
summary.value = "Continuing focused title";
summary.dispatchEvent(new window.Event("input", { bubbles: true }));
toggle.el.click();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(calls[2].payload.if_rev, 11, "own acknowledgement refreshes the still-focused baseline only to its own revision");
toggle.destroyed();
dom.window.close();
console.log("PASS inline text: native selection, grow/shrink, cleanup and acknowledged immediate View");
