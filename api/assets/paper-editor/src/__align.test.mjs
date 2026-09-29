// __align.test.mjs — text alignment on paragraphs and headings: the `align` block attribute
// ("center" | "right"; absent = left) ⇄ the canvas node's textAlign; a change is one patch, back
// to left drops the key (align:null on the patch), an inserted left block carries no key.
// Run: node src/__align.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import { blocksToMarkdown, markdownToBlocks } from "./markdown.js";

let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

const P = { id: "p1", type: "paragraph", content: [{ type: "text", value: "Plain." }] };
const C = { id: "p2", type: "paragraph", align: "center", content: [{ type: "text", value: "Centred." }] };
const H = { id: "h1", type: "heading", level: 2, align: "right", text: "Right" };
const HP = { id: "h2", type: "heading", level: 2, text: "Plain heading" };

check("align projects to textAlign; a plain block has none; everything round-trips byte-identically", () => {
  const doc = runToTiptap([P, C, H, HP]);
  assert.equal(doc.content[0].attrs.textAlign ?? "left", "left");
  assert.equal(doc.content[1].attrs.textAlign, "center");
  assert.equal(doc.content[2].attrs.textAlign, "right");
  assert.deepEqual(docToBlocks(doc), [P, C, H, HP]);
  assert.deepEqual(runToOps([P, C, H, HP], doc), []);
});

check("centring a plain paragraph is ONE patch carrying align:center", () => {
  const doc = runToTiptap([P]);
  doc.content[0].attrs = { ...(doc.content[0].attrs || {}), textAlign: "center" };
  const ops = runToOps([P], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].patch.align, "center");
});

check("back to left on a centred paragraph patches align:null (the key is dropped, not stored as left)", () => {
  const doc = runToTiptap([C]);
  doc.content[0].attrs = { ...(doc.content[0].attrs || {}), textAlign: "left" };
  const ops = runToOps([C], doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].patch.align, null);
});

check("back to left when only the BASELINE holds align:center (aligned earlier this session) still patches align:null", () => {
  // The node mounted from the plain block P (source without `align`); the server has since
  // acknowledged a centring, so the baseline carries align:center while the source does not.
  const doc = runToTiptap([P]);
  doc.content[0].attrs = { ...(doc.content[0].attrs || {}), textAlign: "left" };
  const baseline = [{ ...P, align: "center" }];
  const ops = runToOps(baseline, doc);
  assert.equal(ops.length, 1, JSON.stringify(ops));
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].patch.align, null);
  assert.equal("align" in ops[0].patch, true);
});

check("a heading flushed right patches align:right and keeps its level", () => {
  const doc = runToTiptap([HP]);
  doc.content[0].attrs = { ...(doc.content[0].attrs || {}), textAlign: "right" };
  const ops = runToOps([HP], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.align, "right");
  assert.equal(ops[0].patch.level, 2);
});

check("an inserted left-aligned block carries no align key; an inserted centred one does", () => {
  const prev = [P];
  const doc = runToTiptap(prev);
  doc.content.push({ type: "paragraph", attrs: { textAlign: "left" }, content: [{ type: "text", text: "New" }] });
  doc.content.push({ type: "paragraph", attrs: { textAlign: "center" }, content: [{ type: "text", text: "New centred" }] });
  const ops = runToOps(prev, doc);
  const inserted = ops.filter((o) => o.block).map((o) => o.block);
  assert.equal(inserted.length, 2, JSON.stringify(ops));
  assert.equal("align" in inserted[0], false);
  assert.equal(inserted[1].align, "center");
});

check("markdown: an aligned block rides the sentinel and comes back byte-identical", () => {
  const md = blocksToMarkdown([P, C]);
  assert.ok(!md.split("\n")[0].includes("<!--bp:block"), "a plain paragraph is natural markdown");
  assert.ok(md.includes("<!--bp:block"), "the centred one is a sentinel");
  assert.deepEqual(markdownToBlocks(md).map((b) => ({ ...b, id: undefined })), [P, C].map((b) => ({ ...b, id: undefined })));
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
