// __opaque_marks.test.mjs — task-6d27394284ce6cff (silent data loss). A flat mark
// the editor has no UI for ({type:"smallcaps"}, or any annotation a source system
// wrote into a text leaf's `marks`) used to be dropped on load (convert.js
// flatMarkToTiptap -> null), and the next save of its block wrote the leaf back
// without it. It is now carried verbatim as a bpOpaqueMark and put back into the
// leaf's `marks` in its original place. Pure node: the canvas run converters and
// the per-block converter, no DOM.
// Run: node src/__opaque_marks.test.mjs
import assert from "node:assert/strict";
import { blockToTiptap, tiptapToBlock } from "./convert.js";
import { runToTiptap, docToBlocks, runToOps } from "./canvas/run-convert.js";

const clone = (v) => JSON.parse(JSON.stringify(v));
// Canonical JSON (sorted keys): a heading's `level` key moves on every save
// (pre-existing; jsonb keeps no key order). Values and array order are exact.
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);
const SMALLCAPS = { type: "text", value: "Ibsen", marks: [{ type: "smallcaps" }] };
// Known marks on both sides, plus a second opaque mark stacked on the same range.
const BESIDE = {
  type: "text",
  value: "Peer Gynt",
  marks: [{ type: "strong" }, { type: "annotation", attrs: { id: "a1", by: "ocr" } }, { type: "em" }, { type: "smallcaps" }],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Read " }, clone(SMALLCAPS), { type: "text", value: " today." }] },
  { id: "p2", type: "paragraph", content: [{ type: "text", value: "See " }, clone(BESIDE), { type: "text", value: "." }] },
  { id: "h1", type: "heading", level: 2, content: [{ type: "text", value: "On " }, clone(SMALLCAPS)] },
  { id: "c1", type: "callout", tone: "info", content: [clone(SMALLCAPS), { type: "text", value: " wrote it" }] },
  { id: "q1", type: "blockquote", content: [clone(BESIDE)] },
];

let ran = 0;
let failures = 0;
function check(name, fn) {
  ran += 1;
  try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message.split("\n")[0]}`); }
}

const doc = runToTiptap(clone(BLOCKS));
const leafAt = (block, value) => block.content.find((n) => n.value === value);

check("canvas: load -> save is byte-identical for every block holding an unknown mark", () => {
  assert.equal(canonical(docToBlocks(clone(doc))), canonical(BLOCKS));
});

check("canvas: a no-op save emits no ops", () => {
  assert.deepEqual(runToOps(clone(BLOCKS), clone(doc)), []);
});

check("canvas: editing OTHER text in the paragraph keeps the marked leaf verbatim", () => {
  const edited = clone(doc);
  edited.content[1].content[0] = { ...edited.content[1].content[0], text: "Watch " };
  const out = docToBlocks(edited)[1];
  assert.deepEqual(out.content[0], { type: "text", value: "Watch " });
  assert.deepEqual(leafAt(out, "Peer Gynt"), BESIDE, JSON.stringify(out.content));
});

check("canvas: editing the marked text itself keeps every mark in its original order", () => {
  const edited = clone(doc);
  const run = edited.content[1].content.find((n) => n.text === "Peer Gynt");
  run.text = "Peer Gynt (1867)";
  const out = docToBlocks(edited)[1];
  // The kept source leaf and the new text may stay two leaves (reuseInlineSource);
  // every one of them carries the stored marks, in the stored order.
  const marked = out.content.filter((n) => n.marks);
  assert.equal(marked.map((n) => n.value).join(""), "Peer Gynt (1867)", JSON.stringify(out.content));
  for (const n of marked) assert.deepEqual(n.marks, BESIDE.marks, JSON.stringify(out.content));
  const callout = clone(doc);
  callout.content[3].content[0].text = "Henrik Ibsen";
  assert.deepEqual(docToBlocks(callout)[3].content[0], { ...SMALLCAPS, value: "Henrik Ibsen" });
});

check("per-block editor: blockToTiptap -> tiptapToBlock keeps the marks (no-op and edited)", () => {
  for (const block of [BLOCKS[0], BLOCKS[1], BLOCKS[2]]) {
    const t = blockToTiptap(clone(block));
    const out = tiptapToBlock(clone(t), block.id, block.type);
    assert.equal(canonical(out.content), canonical(block.content), block.id);
  }
  const t = blockToTiptap(clone(BLOCKS[1]));
  t.content[0].content[0].text = "Watch ";
  const run = t.content[0].content.find((n) => n.text === "Peer Gynt");
  run.text = "Peer Gynt!";
  const out = tiptapToBlock(t, "p2", "paragraph").content;
  assert.deepEqual(leafAt({ content: out }, "Peer Gynt!"), { ...BESIDE, value: "Peer Gynt!" }, JSON.stringify(out));
});

// BPML (`bp paper push`) writes marks as bare strings. A known one ("code")
// must load as the editor's own mark, and an unknown one survive verbatim.
check("bare-string marks: known ones load as editor marks; the leaf saves unchanged", () => {
  const leaf = { type: "text", value: "POST /v1", marks: ["code"] };
  const odd = { type: "text", value: "Ibsen", marks: ["smallcaps", "strong"] };
  const block = { id: "s1", type: "paragraph", content: [{ type: "text", value: "Call " }, leaf, { type: "text", value: " by " }, odd] };
  const t = blockToTiptap(clone(block));
  const run = t.content[0].content.find((n) => n.text === "POST /v1");
  assert.deepEqual((run.marks || []).map((m) => m.type), ["code"], JSON.stringify(run));
  const out = tiptapToBlock(clone(t), "s1", "paragraph");
  assert.equal(canonical(out.content), canonical(block.content), JSON.stringify(out.content));
  assert.equal(canonical(docToBlocks(runToTiptap([clone(block)]))[0].content), canonical(block.content));
});

if (ran !== 6) { failures += 1; console.log(`FAIL  ran ${ran} of 6 checks`); }
if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\nopaque marks: unknown flat marks round-trip verbatim");
