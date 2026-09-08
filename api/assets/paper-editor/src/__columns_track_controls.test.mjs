import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const source = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-hooks.js",
  import.meta.url,
), "utf8");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const waitFor = async (predicate) => {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await tick();
  }
};

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:columns-tracks" data-paper-rev="10">
    <button id="view" data-editing="true">View</button>
    <div class="bp-paper-editor bp-paper-contextual-editor">
      <div id="column-0-canvas" phx-hook="BarkparkPaperCanvas"
           data-paper-container-kind="columns" data-paper-container-id="columns"
           data-paper-container-run="0" data-paper-canvas-lease="lease:left">
        <bp-paper-canvas id="left-canvas"></bp-paper-canvas>
      </div>
      <form id="scalar" class="bp-paper-edit-form"
            phx-change="paper-block-autosave" phx-debounce="0">
        <input type="hidden" name="block_id" value="metadata">
        <input name="label" value="Before">
      </form>
      <form id="tracks" phx-submit="paper-edit-block">
        <input type="hidden" name="block_id" value="columns">
        <input type="hidden" name="column-count" value="2">
        <input type="hidden" name="column-new-child-id" value="child:unused">
        <input type="hidden" name="column-0-child-count" value="1">
        <input type="hidden" name="column-0-child-0-id" value="left:one">
        <button type="submit" name="column-action" value="add:0">Add child to column 1</button>
        <input type="hidden" name="column-1-child-count" value="0">
        <button type="submit" name="column-action" value="add:1">Add child to column 2</button>
        <button id="add-track" type="submit" name="column-action" value="add-column">Add column</button>
      </form>
    </div>
    <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
  </main>
</body>`, { url: "http://localhost/" });
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
vm.runInContext(source, vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
}));

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
    return new Promise((resolve, reject) => replies.push({ resolve, reject, payload }));
  },
};
hook.mounted();
const settle = (reply) => replies.shift().resolve([{
  status: "fulfilled",
  value: { reply },
}]);

const wrapper = window.document.getElementById("column-0-canvas");
const canvas = window.document.getElementById("left-canvas");
const hookOwnedHistoryMarker = { undoDepth: 3 };
canvas.historyIdentity = hookOwnedHistoryMarker;
let activeCanvasSave = null;
wrapper.addEventListener("bp-flush-pending", (event) => {
  if (activeCanvasSave) event.detail.waitUntil(activeCanvasSave);
});
let childPayload;
let resolveChild;
activeCanvasSave = hook._bpPaperExitCoordinator.mutate(wrapper, {
  payload: {
    ops: [{ op: "patch-block", id: "left:one", patch: { text: "First draft" } }],
  },
  send(payload) {
    childPayload = structuredClone(payload);
    return new Promise((resolve) => { resolveChild = resolve; });
  },
}).promise;
assert.equal(childPayload.if_rev, 10);

const scalar = window.document.querySelector('#scalar [name="label"]');
scalar.value = "Queued metadata";
scalar.dispatchEvent(new window.Event("input", { bubbles: true }));
await tick();
assert.equal(calls.length, 0, "the scalar waits behind the earlier column draft");

const form = window.document.getElementById("tracks");
const addTrack = window.document.getElementById("add-track");
addTrack.focus();
form.dispatchEvent(new window.SubmitEvent("submit", {
  bubbles: true,
  cancelable: true,
  submitter: addTrack,
}));
await tick();
assert.equal(calls.length, 0, "the whole-track action waits behind both earlier sources");

resolveChild({ saved: true, request_id: childPayload.request_id, rev: 11 });
assert.equal(await activeCanvasSave, true);
activeCanvasSave = null;
await tick();
assert.equal(calls.length, 1);
assert.equal(calls[0].event, "paper-block-autosave");
assert.equal(calls[0].payload.if_rev, 11);
assert.equal(calls[0].payload.label, "Queued metadata");

settle({ saved: true, request_id: calls[0].payload.request_id, rev: 12 });
await tick();
assert.equal(calls.length, 2);
assert.equal(calls[1].event, "paper-edit-block");
assert.equal(calls[1].payload.if_rev, 12);
assert.equal(calls[1].payload["column-action"], "add-column");
assert.equal(calls[1].payload["column-count"], "2");
assert.equal(calls[1].payload["column-0-child-0-id"], "left:one");
const structuralPayload = structuredClone(calls[1].payload);

replies.shift().reject(new Error("connection dropped after send"));
await tick();
hook.el.click();
await waitFor(() => calls.length === 3);
assert.equal(calls.length, 3, "View retries the retained structural mutation");
assert.deepEqual(calls[2].payload, structuralPayload,
  "the retry keeps the exact action, vector, request id, and base revision");
assert.deepEqual(toggles, [], "View remains fenced through the structural retry");
replies.shift().reject(new Error("connection is still unavailable"));
await tick();
await tick();
assert.equal(calls.length, 3,
  "one View attempt performs only one retained structural retry");
assert.deepEqual(toggles, [], "a repeated transport failure leaves View fenced");

hook.el.click();
await waitFor(() => calls.length === 4);
assert.deepEqual(calls[3].payload, structuralPayload,
  "a later View attempt retries the same retained request again");

const newCount = window.document.createElement("input");
newCount.type = "hidden";
newCount.name = "column-2-child-count";
newCount.value = "0";
const newTrackAdd = window.document.createElement("button");
newTrackAdd.type = "submit";
newTrackAdd.name = "column-action";
newTrackAdd.value = "add:2";
newTrackAdd.textContent = "Add child to column 3";
const removeTrack = window.document.createElement("button");
removeTrack.type = "submit";
removeTrack.name = "column-action";
removeTrack.value = "remove-column:2";
removeTrack.textContent = "Remove column 3";
form.append(newCount, newTrackAdd, removeTrack);
form.elements.namedItem("column-count").value = "3";
settle({ saved: true, request_id: calls[3].payload.request_id, rev: 13 });
await tick();
await tick();

assert.equal(window.document.activeElement, newTrackAdd,
  "the acknowledged append focuses the new empty track");
assert.deepEqual(toggles, ["paper-toggle-edit"],
  "View proceeds only after every source and the structural retry settle");
assert.equal(window.document.getElementById("left-canvas"), canvas,
  "appending a track preserves the mounted canvas instance");
assert.equal(canvas.historyIdentity, hookOwnedHistoryMarker,
  "appending a track preserves hook-owned state on the surviving canvas element");
assert.equal(wrapper.dataset.paperCanvasLease, "lease:left",
  "appending a track preserves the retained lease carrier");
assert.deepEqual({
  kind: wrapper.dataset.paperContainerKind,
  id: wrapper.dataset.paperContainerId,
  run: wrapper.dataset.paperContainerRun,
}, { kind: "columns", id: "columns", run: "0" },
"appending a track preserves the surviving canvas context");

let continuedPayload;
const continuedSave = hook._bpPaperExitCoordinator.mutate(wrapper, {
  payload: {
    ops: [{ op: "patch-block", id: "left:one", patch: { text: "Continued draft" } }],
  },
  send(payload) {
    continuedPayload = structuredClone(payload);
    return Promise.resolve({ saved: true, request_id: payload.request_id, rev: 14 });
  },
}).promise;
assert.equal(continuedPayload.if_rev, 13);
assert.equal(continuedPayload.ops[0].id, "left:one",
  "continued typing still targets the original surviving column");
assert.equal(await continuedSave, true);

const cleanExit = new window.Event("beforeunload", { cancelable: true });
window.dispatchEvent(cleanExit);
assert.equal(cleanExit.defaultPrevented, false);

hook.destroyed();
dom.window.close();

const staleDom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:columns-stale" data-paper-rev="14">
    <button id="stale-view" data-editing="true">View</button>
    <div class="bp-paper-editor bp-paper-contextual-editor">
      <div id="stale-column-canvas" phx-hook="BarkparkPaperCanvas"></div>
      <form id="stale-tracks" phx-submit="paper-edit-block">
        <input type="hidden" name="block_id" value="columns">
        <input type="hidden" name="column-count" value="3">
        <input type="hidden" name="column-new-child-id" value="child:unused">
        <input type="hidden" name="column-0-child-count" value="1">
        <input type="hidden" name="column-0-child-0-id" value="left:one">
        <button type="submit" name="column-action" value="add:0">Add child to column 1</button>
        <input type="hidden" name="column-1-child-count" value="0">
        <button type="submit" name="column-action" value="add:1">Add child to column 2</button>
        <input type="hidden" name="column-2-child-count" value="0">
        <button type="submit" name="column-action" value="add:2">Add child to column 3</button>
        <button id="stale-remove-track" type="submit" name="column-action"
                value="remove-column:2">Remove column 3</button>
      </form>
    </div>
    <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
  </main>
</body>`, { url: "http://localhost/" });
const staleWindow = staleDom.window;
let staleUuid = 0;
Object.defineProperty(staleWindow, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8001-${String(++staleUuid).padStart(12, "0")}`,
} });
vm.runInContext(source, vm.createContext({
  window: staleWindow,
  document: staleWindow.document,
  CustomEvent: staleWindow.CustomEvent,
  FormData: staleWindow.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
}));

const staleCalls = [];
const staleReplies = [];
const staleHook = {
  ...staleWindow.BarkparkPaperEditorHooks.BarkparkPaperEditToggle,
  el: staleWindow.document.getElementById("stale-view"),
  pushEvent() { return Promise.resolve({}); },
  pushEventTo(_target, event, payload) {
    staleCalls.push({ event, payload: structuredClone(payload) });
    return new Promise((resolve, reject) => staleReplies.push({ resolve, reject }));
  },
};
staleHook.mounted();

let earlierPayload;
let resolveEarlier;
const staleWrapper = staleWindow.document.getElementById("stale-column-canvas");
let earlierFlush;
staleWrapper.addEventListener("bp-flush-pending", (event) => {
  if (earlierFlush) event.detail.waitUntil(earlierFlush);
});
const earlierSave = staleHook._bpPaperExitCoordinator.mutate(staleWrapper, {
  payload: {
    ops: [{ op: "patch-block", id: "left:one", patch: { text: "Earlier change" } }],
  },
  send(payload) {
    earlierPayload = structuredClone(payload);
    return new Promise((resolve) => { resolveEarlier = resolve; });
  },
}).promise;
earlierFlush = earlierSave.finally(() => { earlierFlush = null; });
assert.equal(earlierPayload.if_rev, 14);
const staleForm = staleWindow.document.getElementById("stale-tracks");
const staleRemoveTrack = staleWindow.document.getElementById("stale-remove-track");
staleRemoveTrack.focus();
staleForm.dispatchEvent(new staleWindow.SubmitEvent("submit", {
  bubbles: true,
  cancelable: true,
  submitter: staleRemoveTrack,
}));
await tick();
assert.equal(staleCalls.length, 0,
  "a captured track removal waits behind an earlier source mutation");
staleForm.elements.namedItem("column-0-child-0-id").value = "left:replacement";
resolveEarlier({ saved: true, request_id: earlierPayload.request_id, rev: 15 });
assert.equal(await earlierSave, true);
await waitFor(() => staleCalls.length === 1);
assert.equal(staleCalls.length, 1);
assert.equal(staleCalls[0].payload.if_rev, 15);
assert.equal(staleCalls[0].payload["column-0-child-0-id"], "left:one",
  "the queued positional action retains its captured pre-drain vector");
staleReplies.shift().resolve([{
  status: "fulfilled",
  value: { reply: {
    saved: false,
    request_id: staleCalls[0].payload.request_id,
    rejected: "validation",
    current_rev: 15,
  } },
}]);
await tick();
const conflict = staleWindow.document.querySelector("[data-bp-paper-conflict]");
assert.ok(conflict, "a stale captured track vector is rejected visibly");
assert.equal(conflict.querySelector('[data-action="keep"]').disabled, true,
  "a positional track conflict cannot be rebased onto changed indexes");
staleHook.destroyed();
staleDom.window.close();
console.log("PASS Columns tracks: cross-source FIFO, exact retry, focus, and surviving canvas identity");
