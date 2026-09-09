import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-hooks.js",
  import.meta.url,
), "utf8");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const waitFor = async (predicate) => {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    if (predicate()) return;
    await tick();
  }
  assert.fail("condition did not settle");
};

const blockId = "card: foo/[title]#?";
const titleId = `card-title-${Buffer.from(blockId).toString("base64url")}`;
const originalTitle = "A reader-shaped Card title";
const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:card-title" data-paper-rev="7">
    <button id="view" data-editing="true">View</button>
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:card-title" data-paper-rev="7">
      <article class="bp-card bp-card--info" data-card-id="${blockId}">
        <form id="${titleId}-form"
              class="bp-paper-edit-form bp-paper-card-title-form"
              phx-submit="paper-edit-block" phx-change="paper-block-autosave"
              phx-debounce="500" data-test-id="paper-card-title-form">
          <input type="hidden" name="block_id" value="${blockId}">
          <h2 class="bp-paper-card-title-heading bp-paper-card-title-owner"
              data-paper-card-title-owner>
            <button type="button" data-paper-card-title-paint
                    aria-controls="${titleId}"
                    aria-label="Edit Card title: ${originalTitle}">${originalTitle}</button>
            <textarea id="${titleId}" name="card-title" rows="1"
                      class="bp-paper-inline-text bp-paper-card-title-input"
                      aria-label="Card title" phx-hook="BarkparkPaperAutoSize">${originalTitle}</textarea>
          </h2>
        </form>
        <div id="card-body" phx-hook="BarkparkPaperCanvas">Body remains independent.</div>
      </article>
      <details id="card-controls">
        <summary>Configure card</summary>
        <button type="button" data-test-id="paper-card-title-focus"
                aria-controls="${titleId}">Edit title</button>
        <input name="card-tone" value="info">
        <input name="card-media-alt" value="Unrelated media description">
      </details>
    </div>
    <footer>
      <div aria-label="Content change history">
        <button type="button" data-paper-history-action="undo" disabled>Undo</button>
        <button type="button" data-paper-history-action="redo" disabled>Redo</button>
        <span data-paper-history-status role="status" aria-live="polite"></span>
      </div>
      <span role="status" data-test-id="bp-paper-footer-save"></span>
    </footer>
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

const input = window.document.getElementById(titleId);
const form = window.document.getElementById(`${titleId}-form`);
const paint = window.document.querySelector("[data-paper-card-title-paint]");
const fallback = window.document.querySelector("[data-test-id='paper-card-title-focus']");
const body = window.document.getElementById("card-body");
assert.equal(window.document.querySelector(`#${titleId}`), input,
  "the base64url id is safe for the actual focus selector despite hostile source identity");
assert.equal(input.tagName, "TEXTAREA");
assert.equal(input.rows, 1);
assert.equal(input.getAttribute("phx-hook"), "BarkparkPaperAutoSize");
assert.equal(form.classList.contains("bp-paper-card-title-form"), true);
assert.equal(form.querySelector("[data-paper-card-title-owner]")?.contains(input), true,
  "the canonical field remains in the authored Card heading level");
assert.deepEqual([...form.elements].map((control) => control.name).filter(Boolean),
  ["block_id", "card-title"],
  "the scalar form owns only Card identity and title");
assert.equal(form.contains(body), false, "the title form never owns Card body content");
assert.equal(window.document.querySelectorAll("[name='card-title']").length, 1,
  "reader paint and Configure share one canonical title field");

let measuredHeight = 58;
Object.defineProperty(input, "scrollHeight", { get: () => measuredHeight });
const sizing = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperAutoSize,
  el: input,
};
sizing.mounted();
assert.equal(input.style.height, "58px", "the shared autosize hook sizes the canonical title");
for (const trigger of [paint, fallback]) {
  assert.equal(trigger.type, "button");
  assert.equal(trigger.getAttribute("aria-controls"), input.id);
  trigger.addEventListener("click", () => window.document
    .getElementById(trigger.getAttribute("aria-controls"))?.focus());
  trigger.click();
  assert.equal(window.document.activeElement, input,
    "visible paint and Configure focus the same native title textarea");
  assert.notEqual(window.document.activeElement, body);
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
const settle = (reply) => replies.shift().resolve([{ status: "fulfilled", value: { reply } }]);

input.focus();
input.setSelectionRange(2, 9);
input.blur();
hook.el.click();
await tick();
assert.equal(calls.length, 0, "focus alone never authors the existing title");
assert.deepEqual(toggles, ["paper-toggle-edit"]);
toggles.length = 0;

let bodyPayload;
let settleBody;
let activeBodySave = hook._bpPaperExitCoordinator.mutate(body, {
  payload: { ops: [{ op: "patch-block", id: "body-child", patch: { text: "Body first" } }] },
  send(payload) {
    bodyPayload = structuredClone(payload);
    return new Promise((resolve) => { settleBody = resolve; });
  },
}).promise;
body.addEventListener("bp-flush-pending", (event) => {
  if (activeBodySave) event.detail.waitUntil(activeBodySave);
});

input.focus();
input.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
input.value = "  Composed Card title  ";
measuredHeight = 29;
input.setSelectionRange(2, 15);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "insertCompositionText", data: "Composed", isComposing: true,
}));
input.dispatchEvent(new window.CompositionEvent("compositionend", {
  bubbles: true, data: "Composed",
}));
hook.el.click();
await tick();
assert.equal(calls.length, 0, "the immediate View drain queues title behind Card body work");
assert.deepEqual(toggles, []);

window.document.querySelector(".bp-paper-editor").dataset.paperRev = "8";
settleBody({ saved: true, request_id: bodyPayload.request_id, rev: 8 });
assert.equal(await activeBodySave, true);
activeBodySave = null;
await waitFor(() => calls.length === 1);
assert.equal(calls[0].event, "paper-block-autosave");
assert.deepEqual(Object.keys(calls[0].payload).sort(),
  ["block_id", "card-title", "if_rev", "request_id"].sort());
assert.equal(calls[0].payload.block_id, blockId);
assert.equal(calls[0].payload["card-title"], "  Composed Card title  ");
assert.equal(calls[0].payload.if_rev, 8);
for (const unrelated of ["card-tone", "card-media-alt", "card-action-label", "content"]) {
  assert.equal(calls[0].payload[unrelated], undefined,
    `${unrelated} never leaks into the title mutation`);
}

window.document.querySelector(".bp-paper-editor").dataset.paperRev = "9";
// This mounted harness supplies the validated receipt shape so it can verify
// client stack behavior; host/server tests own proof that Card-title saves emit it.
settle({
  saved: true,
  changed: true,
  request_id: calls[0].payload.request_id,
  rev: 9,
  history_step: { version: 1, ref: calls[0].payload.request_id, action: "undo" },
});
await tick();
assert.equal(input.value, "  Composed Card title  ",
  "the title ACK retains the exact native draft value");
assert.equal(window.document.activeElement, input);
assert.deepEqual([input.selectionStart, input.selectionEnd], [2, 15]);
assert.equal(input.style.height, "29px", "the same autosize owner remains mounted after ACK");
assert.equal(window.document.querySelector("[data-paper-history-action='undo']").disabled, false,
  "a validated title ACK exposes its contextual history step");
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "the initial View proceeds only after body and title settle");
toggles.length = 0;

// Empty is an intentional clear owned by that same canonical textarea.
input.value = "";
input.setSelectionRange(0, 0);
input.dispatchEvent(new window.InputEvent("input", {
  bubbles: true, inputType: "deleteContentBackward", data: null,
}));
assert.equal(hook._bpPaperExitCoordinator.hasUnsaved(), true,
  "the empty title remains a real pending scalar draft");
hook.el.click();
await waitFor(() => calls.length === 2);
assert.equal(calls[1].payload["card-title"], "");
assert.equal(calls[1].payload.if_rev, 9,
  "the queued clear uses the acknowledged title revision");
const uncertain = structuredClone(calls[1].payload);
replies.shift().reject(new Error("connection dropped after send"));
await tick();
await tick();
assert.equal(hook._saving, false, "the failed View attempt releases its click fence");
hook.el.click();
await waitFor(() => calls.length === 3);
assert.deepEqual(calls[2].payload, uncertain,
  "an uncertain empty-title save replays the exact request id, revision and value");
window.document.querySelector(".bp-paper-editor").dataset.paperRev = "10";
settle({
  saved: true,
  changed: true,
  replayed: true,
  request_id: uncertain.request_id,
  rev: 10,
  history_step: { version: 1, ref: uncertain.request_id, action: "undo" },
});
await tick();
await tick();
assert.equal(hook._bpPaperExitCoordinator.hasUnsaved(), false);
assert.equal(window.document.querySelector("[data-paper-history-action='undo']").disabled, false,
  "validated title history becomes available after the newer draft settles");
assert.deepEqual(toggles, [], "a late retry ACK never revives the failed View attempt");
hook.el.click();
await tick();
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "clean View proceeds after the exact replay settles the empty title");

hook.destroyed();
sizing.destroyed();
dom.window.close();
console.log("PASS Card title: canonical focus, exact IME/FIFO, ACK retention, replay and View drain");
