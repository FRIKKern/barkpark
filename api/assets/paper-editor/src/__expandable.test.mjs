// __expandable.test.mjs — pure-Node unit test for the expandable (toggle) container:
// `{ summary?, open?, blocks|children }` ⇄ bpExpandable, the section container's shape.
// Run: node src/__expandable.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import { BP_EXPANDABLE_NODE_NAME } from "./canvas/expandable-node.js";

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

const p = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const TOGGLE = { id: "x1", type: "expandable", summary: "Details", blocks: [p("c1", "Hidden."), p("c2", "More.")] };
const LEGACY = { id: "x2", type: "expandable", summary: "Old", open: true, children: [p("c3", "Under children.")] };
const BARE = { id: "x3", type: "expandable", blocks: [p("c4", "No summary.")] };
const NESTED = { id: "x4", type: "expandable", summary: "Outer", blocks: [{ id: "s1", type: "section", title: "In", blocks: [p("c5", "deep")] }] };

check("runToTiptap: an expandable projects to a bpExpandable container with its children as content", () => {
  const node = runToTiptap([TOGGLE]).content[0];
  assert.equal(node.type, BP_EXPANDABLE_NODE_NAME);
  assert.equal(node.attrs.bpId, "x1");
  assert.equal(node.attrs.bpType, "expandable");
  assert.equal(node.attrs.summary, "Details");
  assert.equal(node.attrs.bodyKey, undefined, "a blocks body adds no bodyKey");
  assert.equal(node.content.length, 2);
  assert.equal(node.content[0].type, "paragraph");
  assert.equal(node.content[0].attrs.bpId, "c1");
});

check("a legacy `children` body and `open` ride the attrs; a nested container child is bpOpaque", () => {
  const legacy = runToTiptap([LEGACY]).content[0];
  assert.equal(legacy.attrs.bodyKey, "children");
  assert.equal(legacy.attrs.open, true);
  const nested = runToTiptap([NESTED]).content[0];
  assert.equal(nested.content[0].type, "bpOpaque", "a section inside a toggle is carried verbatim");
});

check("docToBlocks: every shape reconstructs byte-identically (summary absent stays absent, children key kept)", () => {
  const blocks = [TOGGLE, LEGACY, BARE, NESTED];
  assert.deepEqual(docToBlocks(runToTiptap(blocks)), blocks);
});

check("runToOps: an unedited run emits ZERO ops", () => {
  const blocks = [p("p0", "hi"), TOGGLE, LEGACY, BARE];
  assert.deepEqual(runToOps(blocks, runToTiptap(blocks)), []);
});

check("runToOps: a summary edit is ONE patch-block{summary} on the toggle", () => {
  const doc = runToTiptap([TOGGLE]);
  doc.content[0].attrs.summary = "Show me";
  assert.deepEqual(runToOps([TOGGLE], doc), [{ op: "patch-block", id: "x1", patch: { summary: "Show me" } }]);
});

check("runToOps: a child paragraph edit is a nested patch-block on the child's id (no replace of the toggle)", () => {
  const doc = runToTiptap([TOGGLE]);
  doc.content[0].content[1].content = [{ type: "text", text: "Changed." }];
  const ops = runToOps([TOGGLE], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "c2");
});

check("runToOps: a child edit under a legacy `children` body still patches the child", () => {
  const doc = runToTiptap([LEGACY]);
  doc.content[0].content[0].content = [{ type: "text", text: "Changed too." }];
  const ops = runToOps([LEGACY], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].id, "c3");
});

check("runToOps: adding a child replaces the whole toggle with minted child ids, under the persisted key", () => {
  const doc = runToTiptap([LEGACY]);
  doc.content[0].content.push({ type: "paragraph", content: [{ type: "text", text: "New." }] });
  const ops = runToOps([LEGACY], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].op, "replace-block");
  assert.equal(ops[0].id, "x2");
  assert.equal(ops[0].block.type, "expandable");
  assert.ok(Array.isArray(ops[0].block.children) && !("blocks" in ops[0].block), "the children key is kept");
  assert.equal(ops[0].block.children.length, 2);
  assert.ok(ops[0].block.children[1].id, "the new child got an id");
  assert.equal(ops[0].block.open, true);
});

check("runToOps: a freshly inserted toggle reconstructs with summary and its child", () => {
  const prev = [p("p0", "hi")];
  const doc = runToTiptap(prev);
  doc.content.push({ type: BP_EXPANDABLE_NODE_NAME, attrs: { bpId: null, bpType: "expandable", summary: "Details" }, content: [{ type: "paragraph", content: [{ type: "text", text: "" }] }] });
  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.block && o.block.type === "expandable");
  assert.ok(ins, "an insert carrying the toggle: " + JSON.stringify(ops));
  assert.equal(ins.block.summary, "Details");
  assert.equal(ins.block.blocks.length, 1);
  assert.ok(ins.block.blocks[0].id);
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\nOK");
