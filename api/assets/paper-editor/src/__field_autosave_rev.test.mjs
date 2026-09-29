// task-e9205d55fc79976e — a PaperFieldBlock form (composite / arrayOf /
// localizedText) typed in Paper Edit must save INSIDE the editor's revision
// tracking. Before the fix LiveView's window-level phx-change sent an
// uncorrelated `inner-change` per keystroke; its canvas echo carried a revision
// no queued mutation owned, the dirty form read it as "changed elsewhere", the
// conflict banner paused every later save and View could not leave Edit.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");
const dom = new JSDOM(`<!doctype html><body><main data-paper-doc-key="production:paper:fields" data-paper-rev="1">
  <div class="bp-paper-editor">
    <div id="canvas" data-canvas-source></div>
    <form id="form" phx-change="inner-change" phx-target="3" phx-hook="BarkparkFieldBridge" phx-debounce="5" data-paper-field-flush>
      <input id="version" name="version" value="5.0.1">
      <input id="channel" name="channel" value="stable">
    </form>
  </div>
</main></body>`, { url: "http://localhost/" });
const { window } = dom;
const context = vm.createContext({ window, document: window.document, CustomEvent: window.CustomEvent,
  Event: window.Event, FormData: window.FormData, setTimeout, clearTimeout, console });
vm.runInContext(hooksSource, context);
const hooks = window.BarkparkPaperEditorHooks;
const doc = window.document;
const formEl = doc.getElementById("form");
const version = doc.getElementById("version");
const canvasEl = doc.getElementById("canvas");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// LiveView binds phx-change on window. Count what reaches it.
let liveViewChanges = 0;
window.addEventListener("input", () => { liveViewChanges += 1; });
window.addEventListener("change", () => { liveViewChanges += 1; });

const pushes = [];
let saveResultHandler;
const formBridge = {
  ...hooks.BarkparkFieldBridge,
  el: formEl,
  handleEvent: (_event, handler) => { saveResultHandler = handler; return "ref"; },
  removeHandleEvent: () => {},
  pushEventTo: (target, event, payload) => {
    pushes.push({ target, event, payload });
    return Promise.resolve([{ status: "fulfilled", value: { reply: {} } }]);
  },
};
formBridge.mounted();
const coordinator = formBridge._exitCoordinator;
assert.ok(coordinator, "the field form joins the paper's exit coordinator");

const type = (value) => {
  version.value = value;
  version.dispatchEvent(new window.Event("input", { bubbles: true }));
};

try {
  type("5.0.1 r");
  type("5.0.1 rc");
  type("5.0.1 rc1");
  assert.equal(liveViewChanges, 0,
    "field keystrokes never reach LiveView's uncorrelated phx-change binding");
  assert.equal(pushes.length, 0, "autosave is debounced, not per keystroke");
  await sleep(30);
  assert.equal(pushes.length, 1, "one correlated save after the debounce");
  assert.equal(pushes[0].event, "inner-flush");
  assert.equal(pushes[0].target, "3");
  assert.equal(pushes[0].payload.values.version, "5.0.1 rc1");
  assert.equal(pushes[0].payload.if_rev, 1);
  const requestId = pushes[0].payload.request_id;
  assert.match(requestId, /^[0-9a-f-]{36}$/i);

  // The author moves to the canvas before the field save is acknowledged.
  version.dispatchEvent(new window.Event("change", { bubbles: true }));
  await sleep(30);
  assert.equal(pushes.length, 1, "the blur change of an unchanged value sends no second save");
  coordinator.markDirty(canvasEl);

  // The canvas echo of the field save can arrive before its reply.
  const applied = [];
  coordinator.observeRevision({
    rev: 2, requestId, apply: (mode) => applied.push(mode),
    observedDocumentKey: "production:paper:fields", source: canvasEl,
  });
  saveResultHandler({ request_id: requestId, saved: true, rev: 2 });
  await sleep(0);
  await sleep(0);
  assert.deepEqual(applied, ["own"], "the field save's own echo applies as own");
  assert.equal(doc.querySelectorAll("[data-bp-paper-conflict]").length, 0,
    "the author's own field save raises no conflict");

  // The canvas edit authored alongside it rides the acknowledged revision.
  const wires = [];
  const canvasSave = coordinator.mutate(canvasEl, {
    payload: { ops: [{ op: "patch-block", id: "t-heading" }] },
    send: (wire) => { wires.push(wire); return Promise.resolve({ saved: true, request_id: wire.request_id, rev: 3 }); },
  });
  assert.equal(wires.length, 1);
  assert.equal(wires[0].if_rev, 2, "the canvas op is not sent on the superseded revision");
  assert.equal(await canvasSave.promise, true);

  // A revision nobody on this page wrote is still a conflict while the form is dirty.
  type("5.0.2");
  coordinator.observeRevision({
    rev: 9, apply: () => {}, observedDocumentKey: "production:paper:fields", source: canvasEl,
  });
  assert.equal(doc.querySelectorAll("[data-bp-paper-conflict]").length, 1,
    "a foreign revision over a dirty field still pauses for review");
  console.log("PASS field form autosave: correlated, debounced, own echo, canvas base advanced, foreign rev conflicts");
} finally {
  formBridge.destroyed();
  window.close();
}
