// __figure.test.mjs — pure-Node unit test for editable-figure: the `figure` block
// rides the canvas as a SERVER-PAINTED read-only-CHILD + editable-CAPTION ATOM
// (`bpFigure`). The CHILD rides VERBATIM/immutable on `bpChild` (server-painted); the
// CAPTION is the SOLE editable datum and emits ONE patch-block{caption}.
//
// Pure by construction: imports ONLY the DOM-free projector/diff from run-convert.js
// (used verbatim by the live WC) + the node NAME from figure-node.js (the Node.create
// schema loads in plain Node; its NodeView factory — the only `document` toucher —
// never runs here). No TipTap editor, no browser.
// Run: node src/__figure.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import {
  runToTiptap,
  runToOps,
  docToBlocks,
  reconcileServerEcho,
} from "./canvas/run-convert.js";
import { BP_FIGURE_NODE_NAME } from "./canvas/figure-node.js";

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

const clone = (v) => JSON.parse(JSON.stringify(v));

// Fixtures: an image-child figure (the common case — image has no editable canvas
// node, so it MUST server-paint), a code-child figure, and a caption-less figure.
const IMG_FIG = {
  id: "f1",
  type: "figure",
  caption: "Figure 1. A map",
  child: { id: "c1", type: "image", src: "/a.png", alt: "map" },
};
const CODE_FIG = {
  id: "f2",
  type: "figure",
  caption: "Figure 2. The snippet",
  child: { id: "c2", type: "code", value: "x = 1", lang: "python" },
};
const NOCAP_FIG = {
  id: "f3",
  type: "figure",
  child: { id: "c3", type: "image", src: "/b.png", alt: "chart" },
};

const para = (id, text = "hi") => ({
  id,
  type: "paragraph",
  content: [{ type: "text", text }],
});

// ── a) PROJECTION ────────────────────────────────────────────────────────────

check("runToTiptap: each figure projects to a bpFigure node (child verbatim, caption+id stamped)", () => {
  for (const fig of [IMG_FIG, CODE_FIG, NOCAP_FIG]) {
    const doc = runToTiptap([fig]);
    assert.equal(doc.content.length, 1, `${fig.id}: one node`);
    const node = doc.content[0];
    assert.equal(node.type, BP_FIGURE_NODE_NAME, `${fig.id}: node type is bpFigure`);
    assert.equal(node.attrs.bpId, fig.id, `${fig.id}: bpId stamped`);
    assert.equal(node.attrs.bpType, "figure", `${fig.id}: bpType stamped`);
    assert.deepEqual(node.attrs.bpChild, fig.child, `${fig.id}: child carried verbatim`);
    // caption attr set when present; null when absent.
    assert.equal(
      node.attrs.caption,
      fig.caption == null ? null : fig.caption,
      `${fig.id}: caption attr matches (null when absent)`,
    );
    // Deep-cloned child — mutating the node's carried child must not touch source.
    node.attrs.bpChild.__poke = 1;
    assert.equal(fig.child.__poke, undefined, `${fig.id}: bpChild is a deep clone`);
  }
});

check("a figure is NOT the generic bpOpaque placeholder (it is canvas-eligible)", () => {
  const node = runToTiptap([IMG_FIG]).content[0];
  assert.notEqual(node.type, "bpOpaque");
});

// ── b) IDENTITY ROUND-TRIP ─────────────────────────────────────────────────────

check("docToBlocks: reconstructs each figure byte-identically (child verbatim, empty caption absent)", () => {
  const round = docToBlocks(runToTiptap([IMG_FIG, CODE_FIG, NOCAP_FIG]));
  assert.deepEqual(round, [IMG_FIG, CODE_FIG, NOCAP_FIG]);
  // The caption-less figure must NOT gain a stray caption key.
  assert.equal("caption" in round[2], false, "caption-less figure has no caption key");
});

// ── c) NO-OP ────────────────────────────────────────────────────────────────────

check("runToOps: an unedited run of figures + prose emits ZERO ops (D3 byte-stability)", () => {
  const blocks = [para("p0"), IMG_FIG, CODE_FIG, NOCAP_FIG, para("p1")];
  const ops = runToOps(blocks, runToTiptap(blocks));
  assert.deepEqual(ops, []);
});

// ── d) CAPTION EDIT ─────────────────────────────────────────────────────────────

check("runToOps: editing the caption emits EXACTLY one patch-block{caption} and nothing else", () => {
  const prev = [IMG_FIG];
  const doc = runToTiptap([IMG_FIG]);
  doc.content[0].attrs.caption = "new";
  const ops = runToOps(prev, doc);
  assert.deepEqual(ops, [{ op: "patch-block", id: "f1", patch: { caption: "new" } }]);
  // No child op of ANY kind rode along.
  assert.ok(!ops.some((o) => "value" in o || "content" in o), "no child value/content op");
});

// ── e) CAPTION CLEAR ────────────────────────────────────────────────────────────

check("runToOps: clearing the caption emits patch{caption:null}; a cleared figure re-projects to zero ops", () => {
  const prev = [IMG_FIG];
  const doc = runToTiptap([IMG_FIG]);
  doc.content[0].attrs.caption = null; // the node-view maps "" → null
  const ops = runToOps(prev, doc);
  assert.deepEqual(ops, [{ op: "patch-block", id: "f1", patch: { caption: null } }]);

  // "" round-trips as ABSENT: a figure carrying caption:"" reconstructs with no key…
  const emptyCap = { ...IMG_FIG, caption: "" };
  const round = docToBlocks(runToTiptap([emptyCap]));
  assert.equal("caption" in round[0], false, 'caption:"" round-trips as absent');
  // …and re-projecting the cleared (caption-less) block emits zero ops (""/null/absent
  // all compare EQUAL — a no-op edit emits nothing).
  assert.deepEqual(runToOps([NOCAP_FIG], runToTiptap([NOCAP_FIG])), []);
});

// ── f) CHILD IMMUTABLE ──────────────────────────────────────────────────────────

check("the child never appears as a value/content op on a caption edit OR a reorder", () => {
  // caption edit
  const doc = runToTiptap([IMG_FIG]);
  doc.content[0].attrs.caption = "changed";
  const editOps = runToOps([IMG_FIG], doc);
  assert.ok(editOps.every((o) => o.op === "patch-block"), "only a patch-block on edit");
  assert.deepEqual(editOps[0].patch, { caption: "changed" }, "patch is caption-only");

  // reorder (figure past prose): move-block only, never a child op.
  const p0 = runToTiptap([para("p0")]).content[0];
  const figNode = runToTiptap([IMG_FIG]).content[0];
  const reordered = { type: "doc", content: [figNode, p0] };
  const moveOps = runToOps([para("p0"), IMG_FIG], reordered);
  assert.ok(moveOps.some((o) => o.op === "move-block"), "a move-block is emitted");
  assert.ok(!moveOps.some((o) => o.op === "patch-block"), "no patch on a pure reorder");
});

check("docToBlocks child is a deep clone — mutating the returned block's child never touches the node attr", () => {
  const doc = runToTiptap([IMG_FIG]);
  const block = docToBlocks(doc)[0];
  block.child.src = "/MUTATED";
  assert.equal(doc.content[0].attrs.bpChild.src, "/a.png", "node attr child untouched");
});

// ── g) STRUCTURAL ───────────────────────────────────────────────────────────────

check("runToOps: removing a figure emits remove-block (structural, id-keyed)", () => {
  const prev = [para("p0"), IMG_FIG, para("p1")];
  const nextDoc = runToTiptap([para("p0"), para("p1")]);
  const ops = runToOps(prev, nextDoc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "f1" }],
  );
});

check("runToOps: inserting a figure carries the child VERBATIM under a minted id", () => {
  const prev = [para("p0")];
  const newFig = {
    type: BP_FIGURE_NODE_NAME,
    attrs: {
      bpId: null,
      bpType: "figure",
      caption: null,
      bpChild: { id: "cN", type: "image", src: "/new.png", alt: "new" },
    },
  };
  const nextDoc = { type: "doc", content: [runToTiptap([para("p0")]).content[0], newFig] };
  const ops = runToOps(prev, nextDoc);
  const insert = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(insert, "an insert op is emitted");
  assert.equal(insert.block.type, "figure", "the inserted block is a figure");
  assert.deepEqual(
    insert.block.child,
    { id: "cN", type: "image", src: "/new.png", alt: "new" },
    "the child rides the insert verbatim",
  );
  assert.ok(insert.block.id && insert.block.id !== "", "the inserted figure carries a minted id");
  // A caption-less insert omits the caption key.
  assert.equal("caption" in insert.block, false, "no stray caption on a caption-less insert");
});

check("runToOps: a colliding figure id is minted fresh (taken seeded from the whole prev tree)", () => {
  // prev has a figure id "f1"; a NEW (bpId:null) figure is inserted. Its minted id
  // must NOT collide with the existing "f1".
  const prev = [IMG_FIG];
  const dupFig = {
    type: BP_FIGURE_NODE_NAME,
    attrs: { bpId: null, bpType: "figure", caption: null, bpChild: clone(IMG_FIG.child) },
  };
  const nextDoc = { type: "doc", content: [runToTiptap([IMG_FIG]).content[0], dupFig] };
  const ops = runToOps(prev, nextDoc);
  const insert = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(insert, "an insert op is emitted for the new figure");
  assert.notEqual(insert.block.id, "f1", "the minted id does not collide with the existing figure id");
});

// ── h) ECHO ──────────────────────────────────────────────────────────────────────

check("reconcileServerEcho: an unchanged figure run is an own echo", () => {
  const server = [IMG_FIG, CODE_FIG];
  const live = runToTiptap(server).content;
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.deepEqual(idWrites, []);
});

check("reconcileServerEcho: a just-minted figure (bpId:null) own-echoes with an id write", () => {
  const server = [IMG_FIG];
  const live = runToTiptap(server).content;
  live[0].attrs.bpId = null; // the just-minted, not-yet-confirmed node
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.equal(idWrites.length, 1);
  assert.equal(idWrites[0].index, 0);
  assert.equal(idWrites[0].id, "f1");
});

check("reconcileServerEcho: a REAL caption change is NOT an own echo (falls to the external path)", () => {
  const server = [IMG_FIG];
  const live = clone(runToTiptap(server).content);
  live[0].attrs.caption = "an external edit";
  const { ownEcho } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, false);
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall editable-figure checks passed");
