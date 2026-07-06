// __fleet.test.mjs — pure-Node unit test for pdd-t8 (fleet-in-canvas): the
// component-fleet blocks (task board / cards / pipeline / form / …) ride the canvas
// as SERVER-PAINTED read-only atoms (`bpFleet`), structurally identical to the
// sheet/embed read-only atom — the WHOLE block rides VERBATIM on `bpBlock`, ZERO
// value/content ops, structural-only participation.
//
// Pure by construction: imports ONLY the DOM-free projector/diff from
// run-convert.js (used verbatim by the live WC) + the DOM-free chip-label helper
// from embed-node.js (the Node.create schema loads in plain Node; its NodeView
// factory — the only `document` toucher — never runs here). No TipTap editor, no
// browser. Run: node src/__fleet.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks } from "./canvas/run-convert.js";
import { fleetChipLabel, BP_FLEET_NODE_NAME } from "./canvas/embed-node.js";

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

// The canonical fleet enumeration (kept in lockstep with run-convert.js:
// CANVAS_FLEET_TYPES and shared/paper.ex:@fleet_render_types + the reader emitters
// in render/components.ex + figures.ex asciicast + forms.ex form). Each carries a
// representative payload so the verbatim-carry round-trip is exercised with real data.
const FLEET_FIXTURES = [
  { id: "a", type: "tasks", snapshot: [{ title: "Ship", status: "ready" }] },
  { id: "b", type: "task-list", snapshot: [{ title: "Do", status: "open" }] },
  { id: "c", type: "task-detail", task: { title: "One", status: "done" } },
  { id: "d", type: "task-board", columns: [{ title: "Ready", tasks: [] }] },
  { id: "e", type: "roadmap", phases: [{ title: "M3", tasks: [] }] },
  { id: "f", type: "notes", items: ["one", "two"] },
  { id: "g", type: "cards", cards: [{ title: "Card", body: "x" }] },
  { id: "h", type: "pipeline", stages: [{ title: "Build" }] },
  { id: "i", type: "status-legend" },
  { id: "j", type: "asciicast", src: "https://example.test/c.cast", caption: "demo" },
  { id: "k", type: "form", kind: "grill", fields: [{ label: "Name", type: "text" }] },
  { id: "l", type: "questionnaire", fields: [{ label: "Q1", type: "text" }] },
];

const para = (id, text = "hi") => ({
  id,
  type: "paragraph",
  content: [{ type: "text", text }],
});

// ── projection: every fleet block → ONE bpFleet node carrying the block verbatim ─

check("runToTiptap: each fleet kind projects to a bpFleet node with the whole block on bpBlock", () => {
  for (const block of FLEET_FIXTURES) {
    const doc = runToTiptap([block]);
    assert.equal(doc.content.length, 1, `${block.type}: one node`);
    const node = doc.content[0];
    assert.equal(node.type, BP_FLEET_NODE_NAME, `${block.type}: node type is bpFleet`);
    assert.equal(node.attrs.bpId, block.id, `${block.type}: bpId stamped`);
    assert.equal(node.attrs.bpType, block.type, `${block.type}: bpType stamped`);
    assert.deepEqual(node.attrs.bpBlock, block, `${block.type}: whole block carried verbatim`);
    // Deep-cloned, not shared — mutating the node's carried block must not touch source.
    node.attrs.bpBlock.__poke = 1;
    assert.equal(block.__poke, undefined, `${block.type}: bpBlock is a deep clone`);
  }
});

check("a fleet kind is NOT the generic bpOpaque placeholder (it is canvas-eligible)", () => {
  const node = runToTiptap([FLEET_FIXTURES[6]]).content[0]; // cards
  assert.notEqual(node.type, "bpOpaque");
  // …while a genuinely-unknown non-prose kind still degrades to bpOpaque.
  const unknown = runToTiptap([{ id: "u", type: "totally-unknown" }]).content[0];
  assert.equal(unknown.type, "bpOpaque");
});

// ── load identity (D3): an UN-edited fleet doc emits ZERO ops ────────────────────

check("runToOps: an unedited run of fleet + prose blocks emits ZERO ops (D3 byte-stability)", () => {
  const blocks = [para("p0"), ...FLEET_FIXTURES, para("p1")];
  const ops = runToOps(blocks, runToTiptap(blocks));
  assert.deepEqual(ops, [], "a doc that isn't edited produces zero ops");
});

check("runToOps: a fleet block NEVER rides a patch-block, even when its carried block is poked", () => {
  const block = { id: "x", type: "cards", cards: [{ title: "orig" }] };
  const doc = runToTiptap([block]);
  // Simulate an out-of-band bpBlock difference (the live editor never edits it, but
  // prove the diff layer refuses to emit a value/content patch for a read-only atom).
  doc.content[0].attrs.bpBlock = { type: "cards", cards: [{ title: "CHANGED" }] };
  const ops = runToOps([block], doc);
  assert.ok(
    !ops.some((o) => o.op === "patch-block"),
    "no patch-block is emitted for a fleet block (read-only, never patched)"
  );
});

// ── docToBlocks: the live-doc → blocks projection round-trips verbatim ───────────

check("docToBlocks: reconstructs each fleet block byte-identically from its bpFleet node", () => {
  const round = docToBlocks(runToTiptap(FLEET_FIXTURES));
  assert.deepEqual(round, FLEET_FIXTURES, "the fleet run round-trips through the live-doc projection");
});

// ── structural ops (the ONLY ops a fleet block participates in) ──────────────────

check("runToOps: removing a fleet block emits remove-block (structural)", () => {
  const board = FLEET_FIXTURES[3]; // task-board id:d
  const prev = [para("p0"), board, para("p1")];
  const nextDoc = runToTiptap([para("p0"), para("p1")]);
  const ops = runToOps(prev, nextDoc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "d" }]
  );
});

check("runToOps: inserting a fleet block emits an insert carrying the block VERBATIM (minted id)", () => {
  const prev = [para("p0")];
  const newFleet = {
    type: BP_FLEET_NODE_NAME,
    attrs: { bpId: null, bpType: "pipeline", bpBlock: { type: "pipeline", stages: [{ title: "Ship" }] } },
  };
  const nextDoc = { type: "doc", content: [runToTiptap([para("p0")]).content[0], newFleet] };
  const ops = runToOps(prev, nextDoc);
  const insert = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(insert, "an insert op is emitted for the new fleet block");
  assert.equal(insert.block.type, "pipeline", "the inserted block keeps its kind");
  assert.deepEqual(insert.block.stages, [{ title: "Ship" }], "the whole block rides the insert verbatim");
  assert.ok(insert.block.id && insert.block.id !== "", "the inserted block carries a minted id");
});

check("runToOps: reordering a fleet block past prose emits move-block by id (structural only)", () => {
  const board = FLEET_FIXTURES[3]; // id:d
  const prev = [para("p0"), board];
  // Swap: board first, then prose.
  const p0 = runToTiptap([para("p0")]).content[0];
  const boardNode = runToTiptap([board]).content[0];
  const nextDoc = { type: "doc", content: [boardNode, p0] };
  const ops = runToOps(prev, nextDoc);
  assert.ok(ops.some((o) => o.op === "move-block"), "a move-block is emitted");
  assert.ok(!ops.some((o) => o.op === "patch-block"), "no patch-block for the read-only atom");
});

// ── the loading-chip label (the fallback shown until server HTML paints) ─────────

check("fleetChipLabel: each fleet kind has a terse human label for the loading chip", () => {
  assert.equal(fleetChipLabel({ type: "task-board" }), "Task board");
  assert.equal(fleetChipLabel({ type: "cards" }), "Cards");
  assert.equal(fleetChipLabel({ type: "pipeline" }), "Pipeline");
  assert.equal(fleetChipLabel({ type: "status-legend" }), "Status legend");
  assert.equal(fleetChipLabel({ type: "form" }), "Form");
  assert.equal(fleetChipLabel({ type: "asciicast" }), "Terminal cast");
  // Unknown / missing kind degrades to something legible, never blank.
  assert.equal(fleetChipLabel({ type: "weird" }), "Block · weird");
  assert.equal(fleetChipLabel({}), "Block");
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall fleet-in-canvas checks passed");
