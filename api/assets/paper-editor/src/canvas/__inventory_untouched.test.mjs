import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { JSDOM } from "jsdom";

// Whole-inventory no-data-loss round trip at the canvas seam (the click-to-edit
// census property, pinned in-repo): mount ONE canvas holding every pd-parity
// golden input block, type into a paragraph, flush — the only op emitted must
// be a patch of that paragraph, and its patch must carry the typed text; no
// other block of the inventory is rewritten by the edit.
const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
const fetchMock = async () => ({ ok: true, json: async () => ({ documents: [] }) });
globalThis.fetch = fetchMock;
window.fetch = fetchMock;
await import("../index.js");

const GOLD = new URL("../../../../test/support/fixtures/pd-parity/", import.meta.url);
const blocks = [];
for (const f of readdirSync(GOLD).sort()) {
  const g = JSON.parse(readFileSync(new URL(f, GOLD), "utf8"));
  const input = Array.isArray(g.input) ? g.input[0] : g.input;
  if (!input || !input.type) continue;
  blocks.push({ ...structuredClone(input), id: `inv-${input.type}`, qa_meta: "sentinel" });
}
const target = { id: "inv-target", type: "paragraph", content: [{ type: "text", value: "Target paragraph." }] };
blocks.splice(Math.floor(blocks.length / 2), 0, target);
assert.ok(blocks.length > 60, `the inventory holds ${blocks.length} blocks`);

let host = document.createElement("bp-paper-canvas");
host.setAttribute("data-dataset", "production");
const batches = [];
host.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail));
document.body.appendChild(host);
host.blocks = blocks;
try {
  const editor = host._editor;
  assert.ok(editor, "the whole inventory mounts in one canvas");
  host.flushPendingChanges();
  // Mounting may materialize ids for nested children that had none (the same ids
  // the server stamps on any write) — and nothing else: every mount op, with ids
  // removed, equals the stored block (unknown keys and body shapes kept).
  const canon = (v) => Array.isArray(v) ? v.map(canon) : v && typeof v === "object"
    ? Object.fromEntries(Object.keys(v).sort().filter((k) => k !== "id").map((k) => [k, canon(v[k])])) : v;
  for (const o of batches.flatMap((b) => b.ops)) {
    const src = blocks.find((b) => b.id === o.id);
    const after = o.op === "replace-block" ? o.block : { ...src, ...o.patch };
    assert.equal(o.op === "replace-block" || o.op === "patch-block", true, `mount op ${o.op}`);
    assert.deepEqual(canon(after), canon(src), `mounting ${o.id} may only add ids`);
  }
  // Apply the materialized ids the way the server's echo does, then edit on a
  // freshly mounted canvas over the id-complete inventory.
  const stored = blocks.map((b) => {
    const ops = batches.flatMap((x) => x.ops).filter((o) => o.id === b.id);
    return ops.reduce((acc, o) => (o.op === "replace-block" ? { ...o.block } : { ...acc, ...o.patch }), b);
  });
  host.remove();
  batches.length = 0;
  host = document.createElement("bp-paper-canvas");
  host.setAttribute("data-dataset", "production");
  host.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail));
  document.body.appendChild(host);
  host.blocks = stored;
  const editor2 = host._editor;
  host.flushPendingChanges();
  assert.deepEqual(batches.flatMap((b) => b.ops), [], "an id-complete inventory mounts without a write");

  let pos = null;
  editor2.state.doc.descendants((node, p) => {
    if (pos == null && node.isText && node.text === "Target paragraph.") pos = p;
  });
  assert.ok(pos != null, "the target paragraph paints in the canvas");
  editor2.commands.setTextSelection(pos + "Target".length);
  editor2.commands.insertContent(" QZMRK");
  host.flushPendingChanges();

  const ops = batches.flatMap((b) => b.ops);
  assert.equal(ops.length, 1, `one op for one edit, got ${JSON.stringify(ops.map((o) => [o.op, o.id]))}`);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "inv-target");
  assert.deepEqual(ops[0].patch, { content: [{ type: "text", value: "Target QZMRK paragraph." }] });
} finally {
  host.remove();
  window.close();
}
console.log("inventory round trip: one edit writes one patch; no other golden block is rewritten");
