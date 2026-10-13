// task-fcbf22671c0c82df — the Studio field canvas hook (Hooks.BarkparkFieldCanvas,
// inline in root.html.heex) must send each batch at a known revision with a
// request id, and let the server's answer settle it. It sent {field, ops} only,
// so FieldBlocks.field_block_ops refused every batch from a browser session while
// the canvas counted it saved.
// Run: node src/__field_canvas_hook.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const root = readFileSync(new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url), "utf8");
const start = root.indexOf("    Hooks.BarkparkFieldCanvas = {");
assert.ok(start > 0, "root.html.heex defines Hooks.BarkparkFieldCanvas");
const end = root.indexOf("\n    };\n", start) + "\n    };\n".length;
const source = root.slice(start, end);

function mount() {
  const dom = new JSDOM(`<div id="wrap" data-field="body" data-doc-key="doc-1" data-document-rev="rev-0"
    data-canvas-blocks='[]' data-canvas-vocabulary='{}' data-save-strings='{"Save paused":"Lagring satt på pause","Keep mine":"Behold mine","Not saved":"Ikke lagret"}'><bp-paper-canvas></bp-paper-canvas></div>`, { runScripts: "outside-only" });
  const { window } = dom;
  const wrap = window.document.getElementById("wrap");
  const wc = wrap.querySelector("bp-paper-canvas");
  const settled = [];
  wc.acknowledgeOps = (seq, saved) => settled.push(["ack", seq, saved]);
  wc.discardInflightOps = (seq, refusal) => settled.push(refusal === undefined ? ["discard", seq] : ["discard", seq, refusal]);
  wc.applyServerBlocks = () => {};
  const pushes = [];
  const handlers = {};
  window.customElements = { whenDefined: () => new Promise(() => {}) };
  window.eval("var Hooks = {};\n" + source + "\nwindow.__hook = Hooks.BarkparkFieldCanvas;");
  const hook = Object.assign(Object.create(window.__hook), {
    el: wrap,
    pushEvent: (event, payload, reply) => pushes.push({ event, payload, reply }),
    handleEvent: (event, fn) => (handlers[event] = fn),
  });
  hook.mounted();
  const emit = (ops, seq) => wc.dispatchEvent(new window.CustomEvent("bp-canvas-ops", { detail: { ops, seq }, bubbles: true }));
  const banner = () => wrap.querySelector("[data-field-save-state]");
  return { wc, hook, pushes, settled, handlers, emit, banner };
}

const OPS = [{ op: "append-block", block: { id: "p", type: "paragraph", content: [{ type: "text", value: "x" }] } }];
let passed = 0;
function test(name, run) { run(); console.log("PASS " + name); passed++; }

test("the canvas holds each batch until the server answers it", () => {
  const { wc } = mount();
  assert.equal(wc.acknowledgedSaves, true);
});

test("a batch carries the revision the field last saw and a request id; saved advances both", () => {
  const { pushes, settled, emit } = mount();
  emit(OPS, 1);
  assert.equal(pushes.length, 1);
  const { event, payload, reply } = pushes[0];
  assert.equal(event, "field-block-ops");
  assert.equal(payload.field, "body");
  assert.equal(payload.if_rev, "rev-0");
  assert.match(payload.request_id, /^field-body-/);
  reply({ saved: true, request_id: payload.request_id, rev: "rev-1" });
  assert.deepEqual(settled, [["ack", 1, true]]);
  emit(OPS, 2);
  assert.equal(pushes[1].payload.if_rev, "rev-1", "the next batch is sent at the saved revision");
  assert.notEqual(pushes[1].payload.request_id, payload.request_id);
});

test("a conflict (another save first) is held unsaved, said so, and never resent on its own", () => {
  const { pushes, settled, emit, banner } = mount();
  emit(OPS, 1);
  pushes[0].reply({ saved: false, conflict: true, current_rev: "rev-9", request_id: pushes[0].payload.request_id });
  assert.equal(pushes.length, 1, "no blind retry over the other save");
  assert.deepEqual(settled, [], "the batch stays held: neither saved nor dropped");
  assert.equal(banner().dataset.fieldSaveState, "conflict");
  assert.equal(banner().getAttribute("role"), "alert");
  assert.match(banner().textContent, /Lagring satt på pause/);
  emit(OPS, 2);
  assert.equal(pushes[1].payload.if_rev, "rev-0", "a later edit still carries the OLD revision, so it cannot land over the other save");
});

test("\"Keep mine\" is the only resend: at the current revision, and a save clears the banner", () => {
  const { pushes, settled, emit, banner } = mount();
  emit(OPS, 1);
  pushes[0].reply({ saved: false, conflict: true, current_rev: "rev-9", request_id: pushes[0].payload.request_id });
  const keep = banner().querySelector('button[data-action="keep"]');
  assert.equal(keep.textContent, "Behold mine");
  keep.click();
  assert.equal(pushes.length, 2);
  assert.equal(pushes[1].payload.if_rev, "rev-9");
  assert.deepEqual(pushes[1].payload.ops, OPS);
  pushes[1].reply({ saved: true, request_id: pushes[1].payload.request_id, rev: "rev-10" });
  assert.deepEqual(settled, [["ack", 1, true]]);
  assert.equal(banner(), null);
});

test("a refusal is shown as not saved, and the batch is dropped so later edits still flow", () => {
  const { pushes, settled, emit, banner } = mount();
  emit(OPS, 1);
  pushes[0].reply({ saved: false, request_id: pushes[0].payload.request_id });
  assert.deepEqual(settled, [["discard", 1]]);
  assert.equal(banner().dataset.fieldSaveState, "refused");
  assert.match(banner().textContent, /Ikke lagret/);
  emit(OPS, 2);
  pushes[1].reply({ saved: true, request_id: pushes[1].payload.request_id, rev: "rev-1" });
  assert.equal(banner(), null, "the next save that lands clears it");
});

test("a refused reply's validation reason reaches discardInflightOps", () => {
  const { pushes, settled, emit, banner } = mount();
  emit(OPS, 1);
  const reason = "paragraph/content/1/tone: must be one of positive, caution";
  pushes[0].reply({ saved: false, request_id: pushes[0].payload.request_id, reason });
  // The refusal object is built in the hook's realm (jsdom), so compare its JSON.
  assert.equal(JSON.stringify(settled), JSON.stringify([["discard", 1, { reason }]]));
  assert.equal(banner().dataset.fieldSaveState, "refused", "the generic notice still shows");
});

test("an answer to another request settles nothing", () => {
  const { pushes, settled, emit } = mount();
  emit(OPS, 1);
  pushes[0].reply({ saved: true, request_id: "someone-else", rev: "rev-x" });
  assert.deepEqual(settled, []);
});

test("the server echo's revision becomes the next if_rev", () => {
  const { pushes, handlers, emit } = mount();
  handlers["bp:field-canvas-update"]({ field: "body", doc_key: "doc-1", blocks: [], rev: "rev-echo" });
  emit(OPS, 1);
  assert.equal(pushes[0].payload.if_rev, "rev-echo");
});

console.log(`\n${passed} passed`);
