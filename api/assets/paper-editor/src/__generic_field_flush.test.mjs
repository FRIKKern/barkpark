import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");
const dom = new JSDOM(`<!doctype html><body><main>
  <form id="form" phx-change="inner-change" phx-target="17" phx-hook="BarkparkFieldBridge" data-paper-field-flush>
    <input id="native" name="title" value="Before">
    <input name="request_id" value="real-field-value">
    <button id="add" type="button" phx-click="inner-array-op" phx-target="17" phx-value-action="add_row">Add</button>
    <div id="bridge" phx-hook="BarkparkFieldBridge">
      <input id="hidden" type="hidden" name="value" value="Before">
      <bp-rich-text-editor data-bridge-target="hidden"></bp-rich-text-editor>
    </div>
  </form>
</main></body>`, { url: "http://localhost/" });
const { window } = dom;
const context = vm.createContext({ window, document: window.document, CustomEvent: window.CustomEvent,
  Event: window.Event, FormData: window.FormData, setTimeout, clearTimeout });
vm.runInContext(hooksSource, context);
const hooks = window.BarkparkPaperEditorHooks;

const formEl = window.document.getElementById("form");
const bridgeEl = window.document.getElementById("bridge");
const picker = bridgeEl.querySelector("bp-rich-text-editor");
const hidden = window.document.getElementById("hidden");
const native = window.document.getElementById("native");
const pushes = [];
const replies = [];
let saveResultHandler;
let removedHandler;
const formBridge = {
  ...hooks.BarkparkFieldBridge,
  el: formEl,
  handleEvent: (event, handler) => {
    assert.equal(event, "bp:paper-field-save-result");
    saveResultHandler = handler;
    return "save-result-ref";
  },
  removeHandleEvent: (ref) => { removedHandler = ref; },
  pushEventTo: (target, event, payload) => {
    pushes.push({ target, event, payload });
    return new Promise((resolve, reject) => replies.push({ resolve, reject }));
  },
};
const pickerBridge = { ...hooks.BarkparkFieldBridge, el: bridgeEl };
formBridge.mounted();
pickerBridge.mounted();
let delegatedReaderClicks = 0;
formEl.closest("main").addEventListener("click", () => { delegatedReaderClicks += 1; });

const flush = (el) => {
  const pending = [];
  el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
    detail: { waitUntil: (promise) => pending.push(promise) },
  }));
  return pending;
};

try {
  let mirroredInputs = 0;
  hidden.addEventListener("input", () => { mirroredInputs += 1; });
  picker.dispatchEvent(new window.CustomEvent("bp-change", { bubbles: true, detail: { value: "Final value" } }));
  assert.equal(hidden.value, "Final value", "bp-change mirrors the final picker value");
  assert.equal(mirroredInputs, 1, "the form sees the mirrored native input event");

  assert.equal(flush(bridgeEl).length, 0, "the nested picker does not send a duplicate save");
  const firstWait = flush(formEl);
  assert.equal(pushes.length, 1, "the form hook pushes immediately at the View boundary");
  assert.equal(pushes[0].target, "17", "numeric LiveComponent CID is preserved");
  assert.equal(pushes[0].event, "inner-flush");
  assert.equal(pushes[0].payload.values.title, "Before");
  assert.equal(pushes[0].payload.values.value, "Final value");
  assert.equal(pushes[0].payload.values.request_id, "real-field-value", "field names cannot collide with the envelope");
  assert.match(pushes[0].payload.request_id, /^bp-field-/);
  assert.equal(firstWait.length, 1, "flush contributes the correlated parent result");

  const firstRequest = pushes[0].payload.request_id;
  let firstSettled = false;
  Promise.all(firstWait).then(() => { firstSettled = true; });
  replies.shift().resolve([{ status: "fulfilled", value: { reply: {} } }]);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(firstSettled, false, "the empty component reply is not persistence");
  saveResultHandler({ request_id: "unrelated-save", saved: true });
  await Promise.resolve();
  assert.equal(firstSettled, false, "an unrelated successful save cannot release View");
  saveResultHandler({ request_id: firstRequest, saved: false });
  assert.deepEqual(await Promise.all(firstWait), [false], "the matching failed persistence blocks View");

  const retryWait = flush(formEl);
  assert.equal(pushes.length, 2, "the next View retries the still-dirty form");
  assert.notEqual(pushes[1].payload.request_id, firstRequest, "each attempt has a fresh correlation id");
  replies.shift().resolve([{ status: "fulfilled", value: { reply: {} } }]);
  saveResultHandler({ request_id: pushes[1].payload.request_id, saved: true });
  assert.deepEqual(await Promise.all(retryWait), [true]);
  assert.equal(flush(formEl).length, 0, "a confirmed form is a no-op on repeat flush");

  native.value = "Native final";
  native.dispatchEvent(new window.Event("input", { bubbles: true }));
  const nativeWait = flush(formEl);
  assert.equal(pushes[2].payload.values.title, "Native final", "native controls share the barrier");
  replies.shift().reject(new Error("disconnected"));
  assert.deepEqual(await Promise.all(nativeWait), [false], "a rejected send settles and restores dirty state");
  const finalWait = flush(formEl);
  assert.equal(finalWait.length, 1, "a later View retries after transport failure");
  replies.shift().resolve([{ status: "fulfilled", value: { reply: {} } }]);
  saveResultHandler({ request_id: pushes[3].payload.request_id, saved: true });
  assert.deepEqual(await Promise.all(finalWait), [true]);

  const add = window.document.getElementById("add");
  native.value = "Before array operation";
  native.dispatchEvent(new window.Event("input", { bubbles: true }));
  const clickAllowed = add.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(clickAllowed, false, "the reader bridge owns structural clicks before LiveView delegation");
  assert.equal(delegatedReaderClicks, 0, "the ordinary delegated click cannot duplicate the correlated operation");
  assert.equal(pushes[4].event, "inner-flush", "Studio saves the current field before array structure changes");
  assert.equal(pushes.length, 5, "the array operation waits for the field acknowledgement");
  replies.shift().resolve([{ status: "fulfilled", value: { reply: {} } }]);
  saveResultHandler({ request_id: pushes[4].payload.request_id, saved: true });
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(pushes[5].event, "inner-array-op");
  assert.equal(pushes[5].payload.action, "add_row");
  const structuralWait = flush(formEl);
  assert.equal(structuralWait.length, 1, "View waits for an in-flight structural write");
  replies.shift().resolve([{ status: "fulfilled", value: { reply: {} } }]);
  saveResultHandler({ request_id: pushes[5].payload.request_id, saved: false });
  assert.deepEqual(await Promise.all(structuralWait), [false]);

  // The failed component retains its local value and re-renders that state in
  // the form. A later View sends the complete current value, avoiding a second
  // add/remove/move mutation.
  native.value = "After structural edit";
  const structuralRetry = flush(formEl);
  assert.equal(pushes[6].event, "inner-flush");
  assert.equal(pushes[6].payload.values.title, "After structural edit");
  replies.shift().resolve([{ status: "fulfilled", value: { reply: {} } }]);
  saveResultHandler({ request_id: pushes[6].payload.request_id, saved: true });
  assert.deepEqual(await Promise.all(structuralRetry), [true]);

  formBridge.destroyed();
  pickerBridge.destroyed();
  assert.equal(removedHandler, "save-result-ref", "destroy removes the server event handler");
  assert.equal(flush(formEl).length, 0, "destroy removes the flush listener");
  console.log("PASS generic field bridge: correlated persistence, retry, native input, teardown");
} finally {
  formBridge.destroyed();
  pickerBridge.destroyed();
  window.close();
}
