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
const waitFor = async (predicate) => {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await tick();
  }
};

assert.match(shell,
  /\.bp-paper-card-action-label-owner\s*\{[^}]*display:\s*inline-grid[^}]*position:\s*relative/s,
  "the inline owner retains the reader button's resting geometry");
assert.match(shell,
  /\.bp-paper-card-action-label-form:not\(:focus-within\)\s*\{[^}]*opacity:\s*0[^}]*pointer-events:\s*none[^}]*clip-path:\s*inset\(50%\)/s,
  "the canonical label form adds no resting duplicate paint");
assert.match(shell,
  /textarea\.bp-paper-inline-text\.bp-paper-card-action-label-input\s*\{[^}]*width:\s*100%[^}]*font:\s*inherit[^}]*resize:\s*none[^}]*overflow:\s*hidden/s,
  "the native textarea inherits the reader action typography without textarea chrome");

const blockId = "card: foo/[action]#?";
const labelId = `card-action-label-${Buffer.from(blockId).toString("base64url")}`;
const originalLabel = "Open exact source";
const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:card-action" data-paper-rev="7">
    <button id="view" data-editing="true">View</button>
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:card-action" data-paper-rev="7">
      <article class="bp-card bp-card--info" data-card-id="${blockId}">
        <h2>Authored Card title</h2>
        <div id="card-body" phx-hook="BarkparkPaperCanvas">Authored body stays separate.</div>
        <div class="bp-paper-card-action-label-owner" data-paper-card-action-label-owner>
          <button type="button" class="bp-button bp-button--primary"
                  data-paper-card-action-paint aria-controls="${labelId}"
                  aria-label="Edit card action label: ${originalLabel}">${originalLabel}</button>
          <form id="${labelId}-form"
                class="bp-paper-edit-form bp-paper-card-action-label-form bp-button bp-button--primary"
                phx-submit="paper-edit-block" phx-change="paper-block-autosave"
                phx-debounce="500" data-test-id="paper-card-action-label-form">
            <input type="hidden" name="block_id" value="${blockId}">
            <label class="sr-only" for="${labelId}">Card action label</label>
            <textarea id="${labelId}" name="card-action-label" rows="1"
                      class="bp-paper-inline-text bp-paper-card-action-label-input"
                      aria-label="Card action label" phx-hook="BarkparkPaperAutoSize">${originalLabel}</textarea>
          </form>
        </div>
      </article>
      <details id="card-controls">
        <summary>Configure card</summary>
        <button type="button" data-test-id="paper-card-action-label-focus"
                aria-controls="${labelId}">Edit action label</button>
        <input name="card-action-href" value="/kept-destination">
        <input name="card-action-priority" value="primary">
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

const input = window.document.getElementById(labelId);
assert.equal(window.document.querySelector(`#${labelId}`), input,
  "the base64url DOM id remains safe for the actual JS.focus selector");
const form = window.document.getElementById(`${labelId}-form`);
const paint = window.document.querySelector("[data-paper-card-action-paint]");
const fallback = window.document.querySelector("[data-test-id='paper-card-action-label-focus']");
const body = window.document.getElementById("card-body");
assert.equal(input.tagName, "TEXTAREA");
assert.equal(input.rows, 1);
assert.equal(input.getAttribute("phx-hook"), "BarkparkPaperAutoSize");
assert.equal(window.document.querySelectorAll("[name='card-action-label']").length, 1,
  "reader paint and Configure share one canonical label field");
assert.deepEqual([...form.elements].map((control) => control.name).filter(Boolean),
  ["block_id", "card-action-label"],
  "the scalar form owns only the Card id and action label");
assert.equal(form.contains(body), false, "the action-label form never owns Card body content");

let measuredHeight = 28;
Object.defineProperty(input, "scrollHeight", { get: () => measuredHeight });
const sizing = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperAutoSize,
  el: input,
};
sizing.mounted();
for (const trigger of [paint, fallback]) {
  assert.equal(trigger.tagName, "BUTTON");
  assert.equal(trigger.type, "button");
  assert.equal(trigger.getAttribute("aria-controls"), input.id);
  trigger.addEventListener("click", () => window.document
    .getElementById(trigger.getAttribute("aria-controls"))?.focus());
  trigger.click();
  assert.equal(window.document.activeElement, input,
    "paint and Configure focus the same native action-label textarea");
  assert.notEqual(window.document.activeElement, body,
    "action-label activation cannot transfer focus into the Card body editor");
}

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
    calls.push({ event, payload: structuredClone(payload) });
    return new Promise((resolve, reject) => replies.push({ resolve, reject }));
  },
};
hook.mounted();
const settle = (reply) => replies.shift().resolve([{
  status: "fulfilled",
  value: { reply },
}]);

input.focus();
input.setSelectionRange(2, 8);
input.blur();
hook.el.click();
await tick();
assert.equal(calls.length, 0, "native focus and blur do not materialize a label save");
assert.deepEqual(toggles, ["paper-toggle-edit"]);
toggles.length = 0;

let unrelatedPayload;
let settleUnrelated;
let activeUnrelated = hook._bpPaperExitCoordinator.mutate(body, {
  payload: {
    ops: [{ op: "patch-block", id: "body-child", patch: { text: "Body first" } }],
  },
  send(payload) {
    unrelatedPayload = structuredClone(payload);
    return new Promise((resolve) => { settleUnrelated = resolve; });
  },
}).promise;
body.addEventListener("bp-flush-pending", (event) => {
  if (activeUnrelated) event.detail.waitUntil(activeUnrelated);
});

input.focus();
input.value = "  Revised action label  ";
input.setSelectionRange(3, 10);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Revised",
}));
hook.el.click();
await tick();
assert.equal(calls.length, 0, "the label serializes behind the active Card body source");
assert.deepEqual(toggles, [], "View remains fenced while either source is pending");

settleUnrelated({ saved: true, request_id: unrelatedPayload.request_id, rev: 8 });
assert.equal(await activeUnrelated, true);
activeUnrelated = null;
await waitFor(() => calls.length === 1);
assert.equal(calls[0].event, "paper-block-autosave");
assert.deepEqual(Object.keys(calls[0].payload).sort(),
  ["block_id", "card-action-label", "if_rev", "request_id"].sort(),
  "the wire contains only the label mutation envelope");
assert.equal(calls[0].payload.block_id, blockId);
assert.equal(calls[0].payload["card-action-label"], "  Revised action label  ");
assert.equal(calls[0].payload.if_rev, 8);
assert.equal(calls[0].payload["card-action-href"], undefined);
assert.equal(calls[0].payload["card-action-priority"], undefined);
assert.equal(calls[0].payload.title, undefined);
assert.equal(calls[0].payload.content, undefined);

window.document.querySelector(".bp-paper-editor").dataset.paperRev = "9";
settle({ saved: true, changed: true, request_id: calls[0].payload.request_id, rev: 9 });
await tick();
await tick();
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "View proceeds only after the unrelated source and exact label save settle");

toggles.length = 0;
input.value = "  Saving label baseline  ";
input.setSelectionRange(2, 14);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Saving",
}));
hook.el.click();
await waitFor(() => calls.length === 2);
assert.equal(calls[1].payload["card-action-label"], "  Saving label baseline  ");
assert.equal(calls[1].payload.if_rev, 9);

input.value = "  Newer local label  ";
input.setSelectionRange(2, 13);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Newer",
}));
hook.el.click();
await tick();
assert.deepEqual(toggles, [], "newer typing keeps the active View drain fenced");
window.document.querySelector(".bp-paper-editor").dataset.paperRev = "10";
settle({ saved: true, changed: true, request_id: calls[1].payload.request_id, rev: 10 });
await new Promise((resolve) => setTimeout(resolve, 510));
await waitFor(() => calls.length === 3);
assert.equal(calls.length, 3, "newer typing sends after the acknowledged label revision");
assert.equal(input.value, "  Newer local label  ",
  "the first acknowledgement cannot overwrite newer native typing");
assert.equal(window.document.activeElement, input);
assert.deepEqual([input.selectionStart, input.selectionEnd], [2, 13]);
assert.equal(calls[2].payload["card-action-label"], "  Newer local label  ");
assert.equal(calls[2].payload.if_rev, 10);

const uncertainPayload = structuredClone(calls[2].payload);
replies.shift().reject(new Error("connection dropped after send"));
await tick();
await tick();
assert.equal(hook._saving, false, "the failed View attempt releases its click fence");
hook.el.click();
await waitFor(() => calls.length === 4);
assert.deepEqual(calls[3].payload, uncertainPayload,
  "an uncertain label save retries the exact request id, revision and whitespace");
assert.deepEqual(toggles, [], "View stays fenced through the exact retry");
window.document.querySelector(".bp-paper-editor").dataset.paperRev = "11";
settle({ saved: true, changed: true, request_id: uncertainPayload.request_id, rev: 11 });
await tick();
await tick();
assert.deepEqual(toggles, [], "the failed View attempt never toggles from a late retry ACK");
assert.equal(hook._bpPaperExitCoordinator.hasUnsaved(), false);
hook.el.click();
await tick();
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "a clean View proceeds after the exact retained retry settles");

toggles.length = 0;
input.focus();
hook._bpPaperExitCoordinator.observeRevision({ rev: 12, apply: () => {
  window.document.querySelector(".bp-paper-editor").dataset.paperRev = "12";
} });
input.value = "  Conflict-retained label  ";
input.setSelectionRange(2, 18);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertText", data: "Conflict",
}));
hook.el.click();
await waitFor(() => calls.length === 5);
const rejected = calls[4].payload;
assert.equal(rejected.if_rev, 11);
assert.equal(rejected["card-action-label"], "  Conflict-retained label  ");
settle({ saved: false, conflict: true,
  request_id: rejected.request_id, current_rev: 12 });
await tick();
assert.equal(input.value, "  Conflict-retained label  ");
assert.equal(window.document.activeElement, input);
assert.deepEqual([input.selectionStart, input.selectionEnd], [2, 18]);
assert.deepEqual(toggles, [], "a stale conflict retains the label draft and fences View");
const guardedExit = new window.Event("beforeunload", { cancelable: true });
window.dispatchEvent(guardedExit);
assert.equal(guardedExit.defaultPrevented, true);

const keep = window.document.querySelector('[data-bp-paper-conflict] [data-action="keep"]');
assert.ok(keep && !keep.disabled);
keep.click();
await waitFor(() => calls.length === 6);
const recovered = calls[5].payload;
assert.notEqual(recovered.request_id, rejected.request_id);
assert.equal(recovered.if_rev, 12);
assert.equal(recovered["card-action-label"], "  Conflict-retained label  ");
settle({ saved: true, changed: true, request_id: recovered.request_id, rev: 13 });
await tick();
assert.equal(hook._bpPaperExitCoordinator.hasUnsaved(), false);
hook.el.click();
await tick();
assert.deepEqual(toggles, ["paper-toggle-edit"]);

hook.destroyed();
sizing.destroyed();
dom.window.close();
console.log("PASS Card action label: canonical focus, exact FIFO, retry, ACK safety, conflict recovery");
