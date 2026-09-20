// __island.test.mjs — pure-Node unit test for the "data + island" atoms: equation,
// footnote, toc, video (island-node.js + run-convert.js), and their field codecs.
// Run: node src/__island.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import { ISLAND_SPECS, notesToText, textToNotes, outlineToText, textToOutline } from "./canvas/island-node.js";

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
const EQ = { id: "e1", type: "equation", tex: "E = mc^2", display: true };
const FN = { id: "f1", type: "footnote", notes: [{ id: "a", text: "First note." }, { text: "Second." }] };
const TOC = { id: "t1", type: "toc", items: [{ text: "Intro", level: 1, anchor: "intro" }, { text: "Deeper", level: 2 }], numbered: true, sticky: true };
const BARE_TOC = { id: "t2", type: "toc" };
const VID = { id: "v1", type: "video", src: "https://example.com/v.mp4", captions: [{ lang: "en", src: "/c.vtt" }] };
const ALL = [EQ, FN, TOC, BARE_TOC, VID];

check("runToTiptap: each island block projects to its node, never bpOpaque, with fields on attrs and the rest carried", () => {
  const doc = runToTiptap(ALL);
  const [eq, fn, toc, bare, vid] = doc.content;
  assert.equal(eq.type, ISLAND_SPECS.equation.nodeName);
  assert.equal(eq.attrs.tex, "E = mc^2");
  assert.equal(eq.attrs.display, true);
  assert.equal(fn.type, ISLAND_SPECS.footnote.nodeName);
  assert.deepEqual(fn.attrs.notes, FN.notes);
  assert.equal(toc.type, ISLAND_SPECS.toc.nodeName);
  assert.deepEqual(toc.attrs.bpRest, { sticky: true }, "sticky is not editable here; it rides the rest");
  assert.equal(bare.attrs.items, null);
  assert.equal(vid.type, ISLAND_SPECS.video.nodeName);
  assert.deepEqual(vid.attrs.bpRest, { captions: VID.captions });
  for (const n of doc.content) assert.notEqual(n.type, "bpOpaque");
});

check("docToBlocks: every island reconstructs byte-identically (a bare toc stays bare)", () => {
  assert.deepEqual(docToBlocks(runToTiptap(ALL)), ALL);
});

check("runToOps: an unedited run emits ZERO ops", () => {
  const blocks = [p("p0", "hi"), ...ALL];
  assert.deepEqual(runToOps(blocks, runToTiptap(blocks)), []);
});

check("runToOps: a tex edit is ONE patch-block{tex, display}; the rest never rides a patch", () => {
  const doc = runToTiptap([EQ, TOC]);
  doc.content[0].attrs.tex = "a^2 + b^2 = c^2";
  assert.deepEqual(runToOps([EQ, TOC], doc), [{ op: "patch-block", id: "e1", patch: { tex: "a^2 + b^2 = c^2", display: true } }]);
  const doc2 = runToTiptap([TOC]);
  doc2.content[0].attrs.numbered = false;
  const ops = runToOps([TOC], doc2);
  assert.equal(ops.length, 1);
  assert.deepEqual(Object.keys(ops[0].patch).sort(), ["items", "numbered"]);
  assert.equal("sticky" in ops[0].patch, false);
});

check("runToOps: clearing the notes patches notes:[]; a video src edit patches src/poster/loop", () => {
  const doc = runToTiptap([FN]);
  doc.content[0].attrs.notes = [];
  assert.deepEqual(runToOps([FN], doc), [{ op: "patch-block", id: "f1", patch: { notes: [] } }]);
  const d2 = runToTiptap([VID]);
  d2.content[0].attrs.src = "/new.mp4";
  assert.deepEqual(runToOps([VID], d2), [{ op: "patch-block", id: "v1", patch: { src: "/new.mp4", poster: "", loop: false } }]);
});

check("runToOps: a freshly inserted equation reconstructs with its tex and a minted id", () => {
  const prev = [p("p0", "hi")];
  const doc = runToTiptap(prev);
  doc.content.push({ type: ISLAND_SPECS.equation.nodeName, attrs: { bpId: null, bpType: "equation", tex: "x", display: null, bpRest: null } });
  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.block && o.block.type === "equation");
  assert.ok(ins, JSON.stringify(ops));
  assert.equal(ins.block.tex, "x");
  assert.equal("display" in ins.block, false);
  assert.ok(ins.block.id);
});

check("codecs: notes ⇄ lines keep ids by position; outline ⇄ lines keep level and anchor", () => {
  assert.equal(notesToText(FN.notes), "First note.\nSecond.");
  assert.deepEqual(textToNotes("First note, edited.\nSecond.\nThird.", FN.notes), [{ id: "a", text: "First note, edited." }, { text: "Second." }, { text: "Third." }]);
  assert.equal(outlineToText(TOC.items), "Intro | intro\n  Deeper");
  assert.deepEqual(textToOutline("Intro | intro\n  Deeper\n    Deepest"), [{ text: "Intro", level: 1, anchor: "intro" }, { text: "Deeper", level: 2 }, { text: "Deepest", level: 3 }]);
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\nOK");
