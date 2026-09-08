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

assert.match(shell, /\.bp-paper-section-title-editor--stack\s*\{\s*width:\s*100%/s,
  "the title owner retains reader width when its paint is hidden, rather than shrinking to textarea columns");

assert.match(shell, /\.bp-paper-section-title-form:not\(:focus-within\)\s*\{[^}]*position:\s*absolute[^}]*clip-path:\s*inset\(50%\)/s,
  "the mounted scalar form adds no resting title geometry");
assert.match(shell, /\.bp-paper-section-title-form > label\.sr-only\s*\{[^}]*position:\s*absolute[^}]*width:\s*1px[^}]*height:\s*1px[^}]*clip-path:\s*inset\(50%\)/s,
  "the accessible label stays visually hidden when the canonical form is focused");
assert.match(shell, /\[data-paper-section-title-empty="true"\]:not\(:focus-within\)\s*\{[^}]*height:\s*0[^}]*margin-block:\s*0/s,
  "an absent or empty title stays zero-flow until focused");
assert.match(shell, /\.bp-paper-section-title-editor:has\(\.bp-paper-section-title-form:focus-within\)[^{]*> \.bp-paper-section-title-paint\s*\{[^}]*display:\s*none/s,
  "the reader paint gives way to the same canonical input on focus");
assert.match(shell, /textarea\.bp-paper-inline-text\.bp-paper-section-title-input\s*\{[^}]*width:\s*100%[^}]*font:\s*inherit[^}]*resize:\s*none[^}]*overflow:\s*hidden[^}]*overflow-wrap:\s*anywhere/s,
  "the autosized title wraps at the reader width without native textarea chrome");

const sectionId = "section: foo/[title]#?";
const titleDomId = `section-title-${Buffer.from(sectionId).toString("base64url")}`;
const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:section-title" data-paper-rev="7">
    <button id="view" data-editing="true">View</button>
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:section-title" data-paper-rev="7">
      <div data-paper-section-editor-frame>
        <div class="bp-paper-section-title-editor bp-paper-section-title-editor--stack"
             data-paper-section-title-editor style="font-weight:bold">
          <button type="button" class="bp-paper-section-title-paint"
                  data-paper-section-title-paint aria-controls="${titleDomId}"
                  aria-label="Edit section title: A long Section title keeps every line in the same place while I edit the words directly beside the nested content">A long Section title keeps every line in the same place while I edit the words directly beside the nested content</button>
          <form id="section-form-section" name="section-config"
                class="bp-paper-edit-form bp-paper-section-title-form"
                phx-submit="paper-edit-block" phx-change="paper-block-autosave"
                phx-debounce="500" data-test-id="paper-section-config-editor">
            <input type="hidden" name="block_id" value="${sectionId}">
            <label class="sr-only" for="${titleDomId}">Section title</label>
            <textarea id="${titleDomId}" name="title" rows="1"
                      class="bp-paper-inline-text bp-paper-section-title-input"
                      aria-label="Section title" placeholder="Section title"
                      phx-hook="BarkparkPaperAutoSize"
                      data-test-id="paper-field-title">A long Section title keeps every line in the same place while I edit the words directly beside the nested content</textarea>
          </form>
        </div>
        <div id="nested-child" phx-hook="BarkparkPaperCanvas" tabindex="-1">Nested draft</div>
      </div>
      <details id="section-controls-section">
        <summary>Configure section</summary>
        <button type="button" data-paper-section-title-panel-trigger
                aria-controls="${titleDomId}">Edit title</button>
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

const input = window.document.getElementById(titleDomId);
assert.equal(window.document.querySelector(`#${titleDomId}`), input,
  "the actual JS.focus CSS selector resolves even when the authored ID has punctuation and spaces");
const form = window.document.getElementById("section-form-section");
const paint = window.document.querySelector("[data-paper-section-title-paint]");
const fallback = window.document.querySelector("[data-paper-section-title-panel-trigger]");
const nested = window.document.getElementById("nested-child");
assert.equal(input.tagName, "TEXTAREA");
assert.equal(input.rows, 1);
assert.equal(input.getAttribute("phx-hook"), "BarkparkPaperAutoSize");
let measuredTitleHeight = 86;
Object.defineProperty(input, "scrollHeight", { get: () => measuredTitleHeight });
input.style.cssText = "line-height:28.789px;padding:0;border:0";
const sizing = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperAutoSize,
  el: input,
};
sizing.mounted();
assert.equal(input.style.height, "86.367px",
  "the canonical field opens at the wrapped reader title's three-line height");
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
  "focus-only entry preserves the wrapped authored title without a save");
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
measuredTitleHeight = 29;
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
assert.equal(calls[0].payload.block_id, sectionId,
  "focus-safe DOM identity never rewrites the authored mutation target");
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

input.value = "A long Section title keeps every line in the same place while I edit the words directly beside the nested content";
measuredTitleHeight = 58;
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
assert.equal(calls[1].payload.title,
  "A long Section title keeps every line in the same place while I edit the words directly beside the nested content",
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

// A remote revision must not silently replace this focused native title's
// authored baseline or permit View to discard its exact rejected draft.
toggles.length = 0;
input.focus();
hook._bpPaperExitCoordinator.observeRevision({ rev: 12, apply: () => {
  window.document.querySelector("main").dataset.paperRev = "12";
} });
input.value = "  Local Section draft  ";
input.setSelectionRange(2, 15);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Local",
}));
hook.el.click();
await tick();
const rejectedTitle = calls.at(-1).payload;
assert.equal(rejectedTitle.if_rev, 11);
assert.equal(rejectedTitle.title, "  Local Section draft  ");
settleForm({ saved: false, conflict: true,
  request_id: rejectedTitle.request_id, current_rev: 12 });
await tick();
assert.equal(input.value, "  Local Section draft  ");
assert.equal(window.document.activeElement, input);
assert.deepEqual([input.selectionStart, input.selectionEnd], [2, 15]);
assert.deepEqual(toggles, [], "a rejected Section title keeps View fenced");
const guardedExit = new window.Event("beforeunload", { cancelable: true });
window.dispatchEvent(guardedExit);
assert.equal(guardedExit.defaultPrevented, true);
const keepTitle = window.document.querySelector(
  '[data-bp-paper-conflict] [data-action="keep"]');
assert.ok(keepTitle && !keepTitle.disabled);
keepTitle.click();
await tick();
const retriedTitle = calls.at(-1).payload;
assert.equal(retriedTitle.if_rev, 12);
assert.notEqual(retriedTitle.request_id, rejectedTitle.request_id);
assert.equal(retriedTitle.title, "  Local Section draft  ");
settleForm({ saved: true, request_id: retriedTitle.request_id, rev: 13 });
await tick();
assert.equal(input.value, "  Local Section draft  ");
assert.equal(hook._bpPaperExitCoordinator.hasUnsaved(), false);
hook.el.click();
await tick();
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "View resumes only after explicit conflict recovery saves the title");

hook.destroyed();
sizing.destroyed();
dom.window.close();
console.log("PASS Section title: one scalar field, exact FIFO, native undo, and clean View drain");
