// __rows.test.mjs — pure-Node unit test for steps / tabs as canvas containers of titled
// rows (bpSteps > bpStep+, bpTabs > bpTab+; rows-node.js + run-convert.js).
// Run: node src/__rows.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import { BP_STEPS_NODE_NAME, BP_STEP_NODE_NAME, BP_TABS_NODE_NAME, BP_TAB_NODE_NAME } from "./canvas/rows-node.js";

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
const STEPS = { id: "s1", type: "steps", steps: [{ id: "r1", title: "First", blocks: [p("c1", "Do this.")] }, { id: "r2", title: "Second", children: [p("c2", "Then that.")] }] };
const TABS = { id: "t1", type: "tabs", tabs: [{ id: "u1", label: "One", blocks: [p("c3", "Tab one.")] }, { id: "u2", blocks: [] }] };
const NESTED = { id: "s2", type: "steps", steps: [{ id: "r3", title: "Outer", blocks: [{ id: "x1", type: "section", title: "In", blocks: [p("c4", "deep")] }] }] };

check("runToTiptap: steps and tabs project to row containers with titles and nested content", () => {
  const steps = runToTiptap([STEPS]).content[0];
  assert.equal(steps.type, BP_STEPS_NODE_NAME);
  assert.equal(steps.attrs.bpId, "s1");
  assert.equal(steps.content.length, 2);
  assert.equal(steps.content[0].type, BP_STEP_NODE_NAME);
  assert.equal(steps.content[0].attrs.bpId, "r1");
  assert.equal(steps.content[0].attrs.title, "First");
  assert.equal(steps.content[1].attrs.bodyKey, "children", "a children body is remembered");
  assert.equal(steps.content[0].content[0].attrs.bpId, "c1");
  const tabs = runToTiptap([TABS]).content[0];
  assert.equal(tabs.type, BP_TABS_NODE_NAME);
  assert.equal(tabs.content[0].type, BP_TAB_NODE_NAME);
  assert.equal(tabs.content[0].attrs.title, "One", "a tab's label rides the row title");
  assert.equal(tabs.content[1].content[0].type, "paragraph", "an empty row seeds a paragraph");
  assert.notEqual(steps.type, "bpOpaque");
});

check("a container child inside a row is bpOpaque (V1 forbid-nesting)", () => {
  const n = runToTiptap([NESTED]).content[0];
  assert.equal(n.content[0].content[0].type, "bpOpaque");
});

check("docToBlocks: rows reconstruct byte-identically (ids, titles, body keys; an empty row stays empty)", () => {
  assert.deepEqual(docToBlocks(runToTiptap([STEPS, TABS, NESTED])), [STEPS, TABS, NESTED]);
});

check("runToOps: unedited steps + tabs emit ZERO ops", () => {
  const blocks = [p("p0", "hi"), STEPS, TABS];
  assert.deepEqual(runToOps(blocks, runToTiptap(blocks)), []);
});

check("runToOps: a step title edit is ONE patch-block{steps} carrying the whole rows array with ids kept", () => {
  const doc = runToTiptap([STEPS]);
  doc.content[0].content[0].attrs.title = "First, renamed";
  const ops = runToOps([STEPS], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "s1");
  assert.deepEqual(Object.keys(ops[0].patch), ["steps"]);
  assert.equal(ops[0].patch.steps[0].id, "r1");
  assert.equal(ops[0].patch.steps[0].title, "First, renamed");
  assert.deepEqual(ops[0].patch.steps[1], STEPS.steps[1], "the untouched row is byte-identical");
});

check("runToOps: a tab body edit patches {tabs} with the label kept under `label`", () => {
  const doc = runToTiptap([TABS]);
  doc.content[0].content[0].content[0].content = [{ type: "text", text: "Tab one, edited." }];
  const ops = runToOps([TABS], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.deepEqual(Object.keys(ops[0].patch), ["tabs"]);
  assert.equal(ops[0].patch.tabs[0].label, "One");
  assert.equal(ops[0].patch.tabs[0].blocks[0].content[0].value, "Tab one, edited.");
});

check("runToOps: a new row and a new child get minted ids", () => {
  const doc = runToTiptap([STEPS]);
  doc.content[0].content.push({ type: BP_STEP_NODE_NAME, attrs: { bpId: null, title: "Third" }, content: [{ type: "paragraph", content: [{ type: "text", text: "New." }] }] });
  const ops = runToOps([STEPS], doc);
  assert.equal(ops.length, 1);
  const rows = ops[0].patch.steps;
  assert.equal(rows.length, 3);
  assert.ok(rows[2].id && rows[2].id !== "r1" && rows[2].id !== "r2", "row id minted");
  assert.ok(rows[2].blocks[0].id, "child id minted");
  assert.equal(rows[2].title, "Third");
});

check("runToOps: a freshly inserted steps block reconstructs with its row", () => {
  const prev = [p("p0", "hi")];
  const doc = runToTiptap(prev);
  doc.content.push({ type: BP_STEPS_NODE_NAME, attrs: { bpId: null, bpType: "steps" }, content: [{ type: BP_STEP_NODE_NAME, attrs: { bpId: null, title: "Step 1" }, content: [{ type: "paragraph", content: [{ type: "text", text: "" }] }] }] });
  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.block && o.block.type === "steps");
  assert.ok(ins, JSON.stringify(ops));
  assert.equal(ins.block.steps.length, 1);
  assert.equal(ins.block.steps[0].title, "Step 1");
  assert.ok(ins.block.steps[0].id);
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\nOK");
