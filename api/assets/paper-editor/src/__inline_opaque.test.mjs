// __inline_opaque.test.mjs — task-a110126ce9111388 (P1 data loss). An inline node
// the editor has no UI for (a `chip`; any type a newer writer stored) used to be
// DROPPED on load when childless (convert.js inlineToTiptapNodes default), and
// the first save of its paragraph deleted it: "Status [chip], written with
// [[Ada]]" became "Status , written with [[Ada]]". It is now carried verbatim as
// an inert atom, so load -> save is byte-identical and an edit elsewhere in the
// paragraph keeps it in place. Pure node: the canvas run converters and the
// per-block converter, no DOM.
// Run: node src/__inline_opaque.test.mjs
import assert from "node:assert/strict";
import { blockToTiptap, tiptapToBlock } from "./convert.js";
import { runToTiptap, docToBlocks, runToOps } from "./canvas/run-convert.js";

const clone = (v) => JSON.parse(JSON.stringify(v));
// Canonical JSON (sorted keys): a heading's `level` key moves after `content` on
// every save, chip or not (pre-existing; jsonb keeps no key order). Values and
// array order are compared exactly.
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);
const CHIP = { type: "chip", text: "Reviewed", tone: "positive" };
const FUTURE = { type: "futurething", foo: 1 };
const FUTURE_KIDS = { type: "smallcaps", children: [{ type: "text", value: "Note" }] };
const para = (id, wikilink) => ({
  id,
  type: "paragraph",
  content: [
    { type: "text", value: "Status " },
    clone(CHIP),
    { type: "text", value: ", written with " },
    wikilink,
  ],
});
const BLOCKS = [
  para("p1", { type: "wikilink", target: "Ada", children: [{ type: "text", value: "Ada" }] }),
  para("p2", { type: "wikilink", target: "Ada", docId: "author-ada", children: [{ type: "text", value: "Ada" }] }),
  { id: "h1", type: "heading", level: 2, content: [{ type: "text", value: "Chapter " }, clone(CHIP)] },
  { id: "l1", type: "list", ordered: false, items: [[{ type: "text", value: "Item " }, clone(CHIP)]] },
  { id: "c1", type: "callout", tone: "info", content: [{ type: "text", value: "Heads up " }, clone(CHIP)] },
  { id: "p3", type: "paragraph", content: [{ type: "text", value: "A " }, clone(FUTURE), { type: "text", value: " and " }, clone(FUTURE_KIDS)] },
  { id: "p4", type: "paragraph", content: [{ type: "strong", children: [clone(CHIP)] }, { type: "text", value: " bold chip" }] },
];

let ran = 0;
let failures = 0;
function check(name, fn) {
  ran += 1;
  try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message.split("\n")[0]}`); }
}

const doc = runToTiptap(clone(BLOCKS));

check("canvas: load -> save is byte-identical for every block holding an unknown inline node", () => {
  assert.equal(canonical(docToBlocks(clone(doc))), canonical(BLOCKS));
});

check("canvas: a no-op save emits no ops", () => {
  assert.deepEqual(runToOps(clone(BLOCKS), clone(doc)), []);
});

check("canvas: the unknown node loads as an inert bpInlineOpaque atom holding the node verbatim", () => {
  const p1 = doc.content[0];
  const atom = (p1.content || []).find((n) => n.type === "bpInlineOpaque");
  assert.ok(atom, JSON.stringify(p1.content));
  assert.deepEqual(atom.attrs.node, CHIP);
});

check("canvas: editing OTHER text in the paragraph keeps the chip verbatim in place", () => {
  const edited = clone(doc);
  const p1 = edited.content[0];
  p1.content[0] = { ...p1.content[0], text: "State " };
  const p1Out = docToBlocks(edited)[0];
  assert.deepEqual(p1Out.content[0], { type: "text", value: "State " });
  assert.deepEqual(p1Out.content[1], CHIP);
  assert.deepEqual(p1Out.content.slice(2), BLOCKS[0].content.slice(2));
});

check("per-block editor: blockToTiptap -> tiptapToBlock keeps the chip (no-op and edited)", () => {
  const t = blockToTiptap(clone(BLOCKS[1]));
  assert.equal(JSON.stringify(tiptapToBlock(clone(t), "p2", "paragraph").content), JSON.stringify(BLOCKS[1].content));
  const e = clone(t);
  e.content[0].content[0].text = "State ";
  const out = tiptapToBlock(e, "p2", "paragraph").content;
  assert.deepEqual(out[1], CHIP, JSON.stringify(out));
});

check("an unknown node inside a wrapper mark is rebuilt inside the same wrapper", () => {
  assert.deepEqual(docToBlocks(clone(doc))[6].content[0], { type: "strong", children: [CHIP] });
});

if (ran !== 6) { failures += 1; console.log(`FAIL  ran ${ran} of 6 checks`); }
if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\ninline opaque: unknown inline nodes round-trip verbatim");
