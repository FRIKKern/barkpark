import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-hooks.js",
  import.meta.url,
), "utf8");
const shell = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-shell.css",
  import.meta.url,
), "utf8");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

assert.match(shell, /\.bp-paper-section-title-form:not\(:focus-within\)\s*\{[^}]*position:\s*absolute[^}]*clip-path:\s*inset\(50%\)/s,
  "the mounted scalar form adds no resting title geometry");
assert.match(shell, /\[data-paper-section-title-empty="true"\]:not\(:focus-within\)\s*\{[^}]*height:\s*0[^}]*margin-block:\s*0/s,
  "an absent or empty title stays zero-flow until focused");
assert.match(shell, /\.bp-paper-section-title-editor:has\(\.bp-paper-section-title-form:focus-within\)[^{]*> \.bp-paper-section-title-paint\s*\{[^}]*display:\s*none/s,
  "the reader paint gives way to the same canonical input on focus");
assert.match(shell, /input\.bp-paper-edit-text\.bp-paper-section-title-input\s*\{[^}]*field-sizing:\s*content[^}]*font:\s*inherit/s,
  "the focused input inherits reader typography without a fixed control width");
assert.match(shell, /\.bp-paper-edit-block\[data-block-type="section"\][^{]*input\.bp-paper-edit-text\.bp-paper-section-title-input\s*\{[^}]*font-weight:\s*inherit[^}]*text-align:\s*inherit/s,
  "the canonical input overrides the legacy centered configuration-field styling");

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:section-title" data-paper-rev="7">
    <button id="view" data-editing="true">View</button>
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:section-title" data-paper-rev="7">
      <div data-paper-section-editor-frame>
        <div class="bp-paper-section-title-editor bp-paper-section-title-editor--stack"
             data-paper-section-title-editor style="font-weight:bold">
          <button type="button" class="bp-paper-section-title-paint"
                  data-paper-section-title-paint aria-controls="section-title-section"
                  aria-label="Edit section title:   Existing title  ">  Existing title  </button>
          <form id="section-form-section" name="section-config"
                class="bp-paper-edit-form bp-paper-section-title-form"
                phx-submit="paper-edit-block" phx-change="paper-block-autosave"
                phx-debounce="500" data-test-id="paper-section-config-editor">
            <input type="hidden" name="block_id" value="section">
            <label class="sr-only" for="section-title-section">Section title</label>
            <input id="section-title-section" type="text" name="title"
                   class="bp-paper-edit-text bp-paper-section-title-input"
                   aria-label="Section title" placeholder="Section title"
                   value="  Existing title  " data-test-id="paper-field-title">
          </form>
        </div>
        <div id="nested-child" phx-hook="BarkparkPaperCanvas" tabindex="-1">Nested draft</div>
      </div>
      <details id="section-controls-section">
        <summary>Configure section</summary>
        <button type="button" data-paper-section-title-panel-trigger
                aria-controls="section-title-section">Edit title</button>
      </details>
    </div>
    <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
  </main>
</body>`, { url: "http://localhost/" });
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
vm.runInContext(hooksSource, vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
}));

const input = window.document.getElementById("section-title-section");
const form = window.document.getElementById("section-form-section");
const paint = window.document.querySelector("[data-paper-section-title-paint]");
const fallback = window.document.querySelector("[data-paper-section-title-panel-trigger]");
const nested = window.document.getElementById("nested-child");
for (const trigger of [paint, fallback]) {
  assert.equal(trigger.tagName, "BUTTON");
  assert.equal(trigger.type, "button");
  assert.equal(trigger.getAttribute("aria-controls"), input.id);
  trigger.addEventListener("click", () => window.document
    .getElementById(trigger.getAttribute("aria-controls"))?.focus());
  trigger.click();
  assert.equal(window.document.activeElement, input,
    "pointer or native button activation focuses the one Section title input");
  assert.notEqual(window.document.activeElement, nested,
    "title activation never selects the nested child editor");
}
assert.equal(window.document.querySelectorAll("form[name='section-config']").length, 1);
assert.equal(form.contains(nested), false, "the scalar form never owns nested child fields");

const calls = [];
const replies = [];
const toggles = [];
const hook = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
  el: window.document.getElementById("view"),
  pushEvent(event) {
    toggles.push(event);
    return Promise.resolve({});
  },
  pushEventTo(_target, event, payload) {
    calls.push({ event, payload: JSON.parse(JSON.stringify(payload)) });
    return new Promise((resolve) => replies.push({ resolve, payload }));
  },
};
hook.mounted();
const settleForm = (reply) => replies.shift().resolve([{
  status: "fulfilled", value: { reply },
}]);

input.focus();
input.setSelectionRange(2, 10);
input.blur();
hook.el.click();
await tick();
assert.equal(calls.length, 0,
  "focus-only entry preserves an authored whitespace title without a save");
assert.deepEqual(toggles, ["paper-toggle-edit"]);
toggles.length = 0;

let firstChildPayload;
let settleFirstChild;
let activeChildSave = null;
nested.addEventListener("bp-flush-pending", (event) => {
  if (activeChildSave) event.detail.waitUntil(activeChildSave);
});
const firstChildSave = hook._bpPaperExitCoordinator.mutate(nested, {
  payload: { ops: [{ op: "patch-block", id: "nested-child", patch: { text: "Nested first" } }] },
  send(payload) {
    firstChildPayload = payload;
    return new Promise((resolve) => { settleFirstChild = resolve; });
  },
}).promise;
activeChildSave = firstChildSave;
input.focus();
input.value = "  Revised title  ";
input.setSelectionRange(4, 11);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Revised",
}));
hook.el.click();
await tick();
assert.equal(calls.length, 0, "the title serializes behind an active nested child save");
assert.deepEqual(toggles, [], "View remains fenced while either source is pending");
settleFirstChild({ saved: true, request_id: firstChildPayload.request_id, rev: 8 });
assert.equal(await firstChildSave, true);
activeChildSave = null;
await tick();
await tick();
assert.equal(calls.length, 1);
assert.equal(calls[0].event, "paper-block-autosave");
assert.equal(calls[0].payload.if_rev, 8);
assert.equal(calls[0].payload.block_id, "section");
assert.equal(calls[0].payload.title, "  Revised title  ",
  "the scalar bridge preserves authored leading and trailing whitespace exactly");
assert.equal(calls[0].payload.text, undefined,
  "the title form never serializes a nested child field");

let secondChildPayload;
let settleSecondChild;
const secondChildSave = hook._bpPaperExitCoordinator.mutate(nested, {
  payload: { ops: [{ op: "patch-block", id: "nested-child", patch: { text: "Nested second" } }] },
  send(payload) {
    secondChildPayload = payload;
    return new Promise((resolve) => { settleSecondChild = resolve; });
  },
}).promise;
activeChildSave = secondChildSave;
assert.equal(secondChildPayload, undefined, "later nested typing waits behind the title save");
settleForm({ saved: true, request_id: calls[0].payload.request_id, rev: 9 });
await tick();
assert.equal(window.document.activeElement, input,
  "the title acknowledgement preserves native focus");
assert.deepEqual([input.selectionStart, input.selectionEnd], [4, 11],
  "the title acknowledgement preserves the native selection and undo owner");
assert.equal(secondChildPayload.if_rev, 9,
  "the next nested mutation uses the acknowledged title revision");

input.value = "  Existing title  ";
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "historyUndo", data: null,
}));
assert.equal(calls.length, 1,
  "native undo remains queued behind the active nested child mutation");
settleSecondChild({ saved: true, request_id: secondChildPayload.request_id, rev: 10 });
assert.equal(await secondChildSave, true);
activeChildSave = null;
await new Promise((resolve) => setTimeout(resolve, 510));
assert.equal(calls.length, 2);
assert.equal(calls[1].payload.if_rev, 10);
assert.equal(calls[1].payload.title, "  Existing title  ",
  "a native historyUndo input remains a normal exact scalar save after acknowledgement");
assert.deepEqual(toggles, [], "View remains fenced through the queued native undo");
settleForm({ saved: true, request_id: calls[1].payload.request_id, rev: 11 });
await new Promise((resolve) => setTimeout(resolve, 20));
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "View proceeds only after title and nested child saves settle cleanly");
const cleanExit = new window.Event("beforeunload", { cancelable: true });
window.dispatchEvent(cleanExit);
assert.equal(cleanExit.defaultPrevented, false);
assert.equal(hook._bpPaperExitCoordinator.hasUnsaved(), false);

hook.destroyed();
dom.window.close();
console.log("PASS Section title: one scalar field, exact FIFO, native undo, and clean View drain");
