// __role.test.mjs — pure-Node unit test for the article-chrome ROLE canvas nodes
// (eyebrow / byline / ingress / pullquote). Proves the block ⇄ node ⇄ ops round-trip
// in run-convert.js: an unedited role emits ZERO ops, a body edit emits exactly one
// patch-block carrying the right field, the byline items↔"·" mapping is idempotent,
// a legacy text-only byline migrates lazily to items, and an empty eyebrow round-trips
// contentless. DOM-free — imports only run-convert.js (which imports the pure
// convert.js), never TipTap.
//
// Run: node src/__role.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks, reconcileServerEcho } from "./canvas/run-convert.js";

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

// Deep clone via JSON so a test mutation of a projected doc never bleeds into a
// fixture (runToTiptap deep-clones opaque blocks but role nodes share no ref with
// the source block — still, clone the DOC we mutate to be safe).
const clone = (v) => JSON.parse(JSON.stringify(v));

// The five role fixtures. eyebrow/byline are plain-string surfaces; ingress/pullquote
// carry inline `content` (portable-doc inline shape: {type:"text",value:"…"}).
const EYEBROW = { id: "e1", type: "eyebrow", text: "BREAKING" };
const BYLINE = { id: "b1", type: "byline", items: ["By Knut", "2026"] };
const BYLINE_LEGACY = { id: "b2", type: "byline", text: "By Knut" };
const INGRESS = { id: "i1", type: "ingress", content: [{ type: "text", value: "Lead paragraph" }] };
const PULLQUOTE = { id: "q1", type: "pullquote", content: [{ type: "text", value: "A memorable quote" }] };

// ── 1. round-trip: an UNEDITED role doc emits ZERO ops ──────────────────────

check("unedited eyebrow/byline/ingress/pullquote each emit ZERO ops", () => {
  for (const block of [EYEBROW, BYLINE, INGRESS, PULLQUOTE]) {
    const doc = runToTiptap([block]);
    const ops = runToOps([block], doc);
    assert.deepEqual(ops, [], `${block.type} should emit no ops when unedited`);
  }
});

check("docToBlocks reconstructs each role block byte-identically", () => {
  // eyebrow/byline(items)/ingress/pullquote reconstruct to their canonical stored
  // form (byline already in items form → unchanged).
  assert.deepEqual(docToBlocks(runToTiptap([EYEBROW]))[0], { id: "e1", type: "eyebrow", text: "BREAKING" });
  assert.deepEqual(docToBlocks(runToTiptap([BYLINE]))[0], { id: "b1", type: "byline", items: ["By Knut", "2026"] });
  assert.deepEqual(docToBlocks(runToTiptap([INGRESS]))[0], {
    id: "i1",
    type: "ingress",
    content: [{ type: "text", value: "Lead paragraph" }],
  });
  assert.deepEqual(docToBlocks(runToTiptap([PULLQUOTE]))[0], {
    id: "q1",
    type: "pullquote",
    content: [{ type: "text", value: "A memorable quote" }],
  });
});

check("each role node carries bpId/bpType and its bp-role class type", () => {
  for (const block of [EYEBROW, BYLINE, INGRESS, PULLQUOTE]) {
    const node = runToTiptap([block]).content[0];
    assert.equal(node.type, block.type, "node.type === bpType (no NODE_NAME map)");
    assert.equal(node.attrs.bpId, block.id);
    assert.equal(node.attrs.bpType, block.type);
  }
});

// ── 2. a BODY edit emits exactly one patch-block with the right field ───────

check("eyebrow body edit → one patch { text }", () => {
  const doc = clone(runToTiptap([EYEBROW]));
  doc.content[0].content = [{ type: "text", text: "UPDATED" }];
  const ops = runToOps([EYEBROW], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "e1");
  assert.deepEqual(ops[0].patch, { text: "UPDATED" });
});

check("byline body edit → one patch { items } (split on ·)", () => {
  const doc = clone(runToTiptap([BYLINE]));
  doc.content[0].content = [{ type: "text", text: "By Ola · 2027" }];
  const ops = runToOps([BYLINE], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "b1");
  assert.deepEqual(ops[0].patch, { items: ["By Ola", "2027"] });
});

check("ingress body edit → one patch { content } (inline)", () => {
  const doc = clone(runToTiptap([INGRESS]));
  doc.content[0].content = [{ type: "text", text: "New lead" }];
  const ops = runToOps([INGRESS], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "i1");
  assert.deepEqual(ops[0].patch, { content: [{ type: "text", value: "New lead" }] });
});

check("pullquote body edit → one patch { content } (inline)", () => {
  const doc = clone(runToTiptap([PULLQUOTE]));
  doc.content[0].content = [{ type: "text", text: "Reworded quote" }];
  const ops = runToOps([PULLQUOTE], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "q1");
  assert.deepEqual(ops[0].patch, { content: [{ type: "text", value: "Reworded quote" }] });
});

// ── 3. byline items ↔ " · " display is idempotent ───────────────────────────

check("byline items → ' · '-joined node text → split back to items (zero ops)", () => {
  const node = runToTiptap([BYLINE]).content[0];
  // The node's body is the display string, joined with ' · '.
  const text = (node.content || []).map((n) => n.text || "").join("");
  assert.equal(text, "By Knut · 2026");
  // Reconstructed items match the source → an unedited byline emits zero ops.
  assert.deepEqual(docToBlocks(runToTiptap([BYLINE]))[0].items, ["By Knut", "2026"]);
  assert.deepEqual(runToOps([BYLINE], runToTiptap([BYLINE])), []);
});

// ── 4. legacy text-only byline: lazy migration to items, then idempotent ────

check("legacy text-only byline: unedited emits ZERO ops (no spurious migration)", () => {
  // build_block_patch/compose treat a text-only byline as valid; the canvas does NOT
  // fire an unprompted op for it (the module-wide zero-spurious-op invariant). The
  // migration is LAZY — it lands only when the byline is itself edited (below).
  const ops = runToOps([BYLINE_LEGACY], runToTiptap([BYLINE_LEGACY]));
  assert.deepEqual(ops, []);
});

check("legacy text-only byline reconstructs to items form (docToBlocks migration)", () => {
  assert.deepEqual(docToBlocks(runToTiptap([BYLINE_LEGACY]))[0], {
    id: "b2",
    type: "byline",
    items: ["By Knut"],
  });
});

check("editing a legacy byline emits a single { items } patch; reload then zero ops", () => {
  const doc = clone(runToTiptap([BYLINE_LEGACY]));
  doc.content[0].content = [{ type: "text", text: "By Ola" }];
  const ops = runToOps([BYLINE_LEGACY], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "b2");
  assert.deepEqual(ops[0].patch, { items: ["By Ola"] });

  // Re-loading the migrated result emits zero ops (idempotent post-migration).
  const migrated = [{ id: "b2", type: "byline", items: ["By Ola"] }];
  assert.deepEqual(runToOps(migrated, runToTiptap(migrated)), []);
});

// ── 5. empty eyebrow ↔ contentless node round-trips (zero ops) ──────────────

check("empty eyebrow projects to a contentless node and emits ZERO ops", () => {
  const empty = { id: "e0", type: "eyebrow", text: "" };
  const doc = runToTiptap([empty]);
  assert.equal(doc.content[0].content, undefined, "empty text → no content key");
  assert.deepEqual(runToOps([empty], doc), []);
  assert.deepEqual(docToBlocks(doc)[0], { id: "e0", type: "eyebrow", text: "" });
});

// ── 6. reconcileServerEcho recognizes a role own-echo ───────────────────────

check("reconcileServerEcho treats an unchanged role run as an own echo", () => {
  const server = [EYEBROW, BYLINE, INGRESS, PULLQUOTE];
  const live = runToTiptap(server).content;
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.deepEqual(idWrites, []);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall role-node checks PASS");
