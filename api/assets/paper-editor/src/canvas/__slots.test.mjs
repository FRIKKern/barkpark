// __slots.test.mjs — the callout body slot in the run pipeline (task-c6355c4cb9cb7707).
// markdown/callout-words.js holds what a callout's words are; no field is a copy of
// another. The editable callout node holds one inline run, so:
//
//   * a callout with only `content` projects to that node, and an edit patches
//     `content` alone, chrome kept;
//   * a callout that holds a body (a non-empty slots.body) is carried whole
//     (bpOpaque, bpBlock = the stored block), loads with ZERO ops, and sends nothing;
//   * an empty body list is no body: the callout stays editable.
//
// Pure-Node: imports run-convert.js directly (no browser, no TipTap mount) and
// drives the PUBLIC pipeline (runToTiptap / runToOps).
//
// Run: node src/canvas/__slots.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps } from "./run-convert.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// Inline runs with a bold mark, to prove the mark survives the projection.
const BODY = [
  { type: "text", value: "Be " },
  { type: "strong", children: [{ type: "text", value: "careful" }] },
];

// A callout with only content.
const legacy = (extra = {}) => ({
  id: "c-1",
  type: "callout",
  tone: "warning",
  content: BODY,
  ...extra,
});

// A callout with a body of one paragraph.
const slotted = (extra = {}) => ({
  id: "c-1",
  type: "callout",
  tone: "warning",
  slots: { body: [{ type: "paragraph", content: BODY }] },
  ...extra,
});

const wrap = (callout) => [
  { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
  callout,
  { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
];

// ── (a) a body is carried whole; content alone is the editable node ─────────
check("a callout with a body is carried whole; one with only content is the callout node", () => {
  const S = slotted({ content: [{ type: "text", value: "head words" }] });
  const sn = runToTiptap(wrap(S)).content[1];
  assert.equal(sn.type, "bpOpaque", "a callout with a body is carried");
  assert.deepEqual(sn.attrs, { bpId: "c-1", bpType: "callout", bpBlock: S }, "the whole stored block rides the carry");

  const ln = runToTiptap(wrap(legacy())).content[1];
  assert.equal(ln.type, "callout");
  assert.deepEqual(ln.content, [
    { type: "text", text: "Be " },
    { type: "text", text: "careful", marks: [{ type: "bold" }] },
  ]);
  assert.equal(ln.attrs.tone, "warning");
});

// ── (b) ZERO-OP-ON-LOAD for both ─────────────────────────────────────────────
check("a loaded callout with a body emits ZERO ops", () => {
  const blocks = wrap(slotted({ content: [{ type: "text", value: "head words" }] }));
  assert.equal(runToOps(blocks, runToTiptap(blocks)).length, 0);
});

check("a loaded callout with only content emits ZERO ops", () => {
  const blocks = wrap(legacy());
  assert.equal(runToOps(blocks, runToTiptap(blocks)).length, 0);
});

// ── (c) an edit elsewhere sends nothing for a callout with a body ────────────
check("an edit beside a callout with a body patches only the block edited", () => {
  const server = wrap(slotted({ content: [{ type: "text", value: "head words" }], title: "Heads up" }));
  const doc = runToTiptap(server);
  doc.content[0].content = [{ type: "text", text: "edited" }];
  const ops = runToOps(server, doc);
  assert.deepEqual(ops.map((o) => o.id), ["p-0"], "only the edited paragraph is sent");
});

// ── (d) editing a content-only callout patches content, chrome kept ──────────
check("editing a content-only callout → one patch-block of content, chrome kept", () => {
  const server = wrap(legacy({ title: "Heads up", collapsible: true, collapsed: true }));
  const doc = runToTiptap(server);
  doc.content[1].content = [{ type: "text", text: "edited" }];
  const patches = runToOps(server, doc).filter((o) => o.op === "patch-block" && o.id === "c-1");
  assert.equal(patches.length, 1, "exactly one patch-block for the edited callout");
  // A body edit patches only the body; patch-block is a shallow merge, so the
  // stored chrome survives untouched (task-56bafb69a8a1f250).
  assert.deepEqual(patches[0].patch, { content: [{ type: "text", value: "edited" }] });
});

// ── (e) an empty body list is no body ─────────────────────────────────────────
check("a callout whose body list is empty stays the editable node and loads clean", () => {
  const block = { id: "c-1", type: "callout", tone: "info", content: [], slots: { body: [] } };
  const node = runToTiptap(wrap(block)).content[1];
  assert.equal(node.type, "callout");
  assert.ok(!("content" in node), "an empty content omits node.content (precedent)");
  assert.equal(runToOps(wrap(block), runToTiptap(wrap(block))).length, 0);
});

if (failures) {
  console.log(`\n${failures} FAILED`);
  process.exit(1);
}
console.log("\nall slot-model checks passed");
