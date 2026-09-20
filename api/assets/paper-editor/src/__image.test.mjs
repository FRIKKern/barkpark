// __image.test.mjs — pure-Node unit test for editable-image: the `image` block rides the
// canvas as a self-painting ATOM (`bpImage`). src + alt are the editable data (one
// patch-block{src, alt}); width/height/unknown keys ride verbatim on bpRest; locked/role
// ride the doctrine template attrs; nothing is ever bpOpaque.
//
// Pure by construction: imports the DOM-free projector/diff from run-convert.js and the
// node NAME from image-node.js (its NodeView never runs here). No TipTap editor.
// Run: node src/__image.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks, reconcileServerEcho } from "./canvas/run-convert.js";
import { BP_IMAGE_NODE_NAME } from "./canvas/image-node.js";
import { blocksToMarkdown, markdownToBlocks } from "./markdown.js";

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

const PLAIN = { id: "i1", type: "image", src: "https://example.com/x.png", alt: "An image" };
const SIZED = { id: "i2", type: "image", src: "/a.png", alt: "sized", width: 640, height: 320 };
const FEATURED = { id: "i3", type: "image", locked: true, role: "featured" };
const NOALT = { id: "i4", type: "image", src: "/b.png" };
const para = (id, text = "hi") => ({ id, type: "paragraph", content: [{ type: "text", text }] });

check("runToTiptap: an image projects to a bpImage node with src/alt as attrs, never bpOpaque", () => {
  for (const b of [PLAIN, SIZED, FEATURED, NOALT]) {
    const node = runToTiptap([b]).content[0];
    assert.equal(node.type, BP_IMAGE_NODE_NAME, `${b.id}: node type`);
    assert.notEqual(node.type, "bpOpaque");
    assert.equal(node.attrs.bpId, b.id);
    assert.equal(node.attrs.bpType, "image");
    assert.equal(node.attrs.src, b.src == null ? null : b.src, `${b.id}: src`);
    assert.equal(node.attrs.alt, b.alt == null ? null : b.alt, `${b.id}: alt`);
  }
  const sized = runToTiptap([SIZED]).content[0];
  assert.equal(sized.attrs.width, 640, "width is an editable attr");
  assert.deepEqual(sized.attrs.bpRest, { height: 320 }, "height rides bpRest");
  const featured = runToTiptap([FEATURED]).content[0];
  assert.equal(featured.attrs.locked, true, "locked stamped");
  assert.equal(featured.attrs.role, "featured", "role stamped");
  assert.equal(featured.attrs.bpRest, null, "no rest when nothing else");
});

check("docToBlocks: every image reconstructs byte-identically (absent alt stays absent, rest and template attrs carried)", () => {
  const blocks = [PLAIN, SIZED, FEATURED, NOALT];
  assert.deepEqual(docToBlocks(runToTiptap(blocks)), blocks);
  assert.equal("alt" in docToBlocks(runToTiptap([NOALT]))[0], false);
});

check("runToOps: an unedited run of images + prose emits ZERO ops", () => {
  const blocks = [para("p0"), PLAIN, SIZED, FEATURED, para("p1")];
  assert.deepEqual(runToOps(blocks, runToTiptap(blocks)), []);
});

check("runToOps: editing alt emits EXACTLY one patch-block{src, alt}", () => {
  const doc = runToTiptap([PLAIN]);
  doc.content[0].attrs.alt = "A better description";
  assert.deepEqual(runToOps([PLAIN], doc), [
    { op: "patch-block", id: "i1", patch: { src: PLAIN.src, alt: "A better description", width: null } },
  ]);
});

check("runToOps: setting a url on the featured template image patches src only (locked/role never ride a patch)", () => {
  const doc = runToTiptap([FEATURED]);
  doc.content[0].attrs.src = "/hero.png";
  const ops = runToOps([FEATURED], doc);
  assert.deepEqual(ops, [{ op: "patch-block", id: "i3", patch: { src: "/hero.png", alt: "", width: null } }]);
  assert.ok(!("locked" in ops[0].patch) && !("role" in ops[0].patch));
});

check("runToOps: a reorder of an unedited image is a move, not a patch", () => {
  const blocks = [para("p0"), PLAIN];
  const doc = runToTiptap(blocks);
  doc.content.reverse();
  const ops = runToOps(blocks, doc);
  assert.ok(!ops.some((o) => o.op === "patch-block"), "no patch on a pure reorder: " + JSON.stringify(ops));
});

check("runToOps: a freshly inserted image reconstructs with src/alt and a minted id", () => {
  const prev = [para("p0")];
  const doc = runToTiptap(prev);
  doc.content.push({ type: BP_IMAGE_NODE_NAME, attrs: { bpId: null, bpType: "image", src: "/new.png", alt: null, bpRest: null } });
  const ops = runToOps(prev, doc);
  const ins = ops.find((o) => o.op === "insert-after" || o.op === "insert-block" || o.op === "insert");
  assert.ok(ins, "an insert op: " + JSON.stringify(ops));
  const block = ins.block;
  assert.equal(block.type, "image");
  assert.equal(block.src, "/new.png");
  assert.equal("alt" in block, false, "empty alt is absent on insert");
  assert.ok(typeof block.id === "string" && block.id.length > 0, "minted id");
});

check("reconcileServerEcho: the echo of an alt edit is recognized as our own (no re-emit)", () => {
  const doc = runToTiptap([PLAIN]);
  doc.content[0].attrs.alt = "echoed";
  const echoed = { ...PLAIN, alt: "echoed" };
  const r = reconcileServerEcho([echoed], doc);
  const after = r && r.doc ? r.doc : doc;
  assert.deepEqual(runToOps([echoed], after), [], "no ops after the echo");
});

check("markdown: ![alt](src) ⇄ a plain image block; a sized image rides the sentinel", () => {
  assert.equal(blocksToMarkdown([PLAIN]).trim(), "![An image](https://example.com/x.png)");
  const back = markdownToBlocks("![An image](https://example.com/x.png)");
  assert.equal(back.length, 1);
  assert.equal(back[0].type, "image");
  assert.equal(back[0].src, PLAIN.src);
  assert.equal(back[0].alt, PLAIN.alt);
  assert.ok(blocksToMarkdown([SIZED]).includes("<!--bp:block"), "sized image → sentinel");
  const roundSized = markdownToBlocks(blocksToMarkdown([SIZED]));
  assert.deepEqual(roundSized, [SIZED]);
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\nOK");
