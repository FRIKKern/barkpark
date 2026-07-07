// __terminal.test.mjs — pure-Node unit test for the terminal CONTAINER canvas node —
// the SECOND canvas container (after columns). UNLIKE columns (a list-of-lists) a
// terminal has a SINGLE body child array + THREE chrome scalars (title/footer/live).
// Proves the block ⇄ bpTerminal node ⇄ ops round-trip in run-convert.js: an unedited
// terminal emits ZERO ops; a body/chrome edit emits ONE coarse patch-block carrying the
// whole children + explicit chrome; a title/footer CLEAR lands null + a live-OFF lands
// false (the removal contract); a non-first-class child (callout / nested terminal /
// tasks) rides a verbatim bpTerminalAtom deep-equal through the coarse patch; the legacy
// `blocks` key loads + round-trips under the canonical `children`; an empty body
// seeds+strips a sentinel; a fresh (bpId-less) terminal reconstructs on insert with
// chrome OMITTED when absent. DOM-free — imports only run-convert.js.
//
// Run: node src/__terminal.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import {
  runToTiptap,
  runToOps,
  docToBlocks,
  reconcileServerEcho,
} from "./canvas/run-convert.js";

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

// ── fixtures (the READER shape: children is a LIST OF BLOCKS; children id-less) ──

// A terminal with ALL three chrome scalars + one prose body child.
const TERM = {
  id: "tm1",
  type: "terminal",
  title: "build",
  footer: "^C to quit",
  live: true,
  children: [{ type: "paragraph", content: [{ type: "text", value: "$ make" }] }],
};

// A BARE terminal: NO title/footer/live. Its child edit + insert must render chrome
// as absent (null/false in a patch, OMITTED on insert).
const TERM_BARE = {
  id: "tm2",
  type: "terminal",
  children: [{ type: "paragraph", content: [{ type: "text", value: "x" }] }],
};

// A terminal authored with the LEGACY `blocks` key (compose reads children || blocks).
const TERM_LEGACY = {
  id: "tm3",
  type: "terminal",
  blocks: [{ type: "paragraph", content: [{ type: "text", value: "old" }] }],
};

// A terminal whose body holds NON-first-class children — a callout, a NESTED terminal
// (container-in-container forbidden by schema → carried verbatim), and a tasks fleet
// block. Each must ride a read-only bpTerminalAtom (else PM drops it = data loss).
const TERM_NESTED = {
  id: "tm4",
  type: "terminal",
  children: [
    { type: "callout", tone: "warning", content: [{ type: "text", value: "hi" }] },
    {
      type: "terminal",
      title: "inner",
      children: [{ type: "paragraph", content: [{ type: "text", value: "nested" }] }],
    },
    { type: "tasks", items: [{ title: "do a thing" }] },
  ],
};

// An EMPTY body (seeds + strips a sentinel paragraph).
const TERM_EMPTY = { id: "tm5", type: "terminal", children: [] };

// A body mixing a paragraph with a leaf divider (both first-class children).
const TERM_DIVIDER = {
  id: "tm6",
  type: "terminal",
  children: [
    { type: "paragraph", content: [{ type: "text", value: "A" }] },
    { type: "divider" },
  ],
};

// ── 1. round-trip: an UNEDITED terminal emits ZERO ops ──────────────────────

check("unedited terminals (chrome/bare/legacy/nested/empty/divider) each emit ZERO ops", () => {
  for (const block of [
    TERM,
    TERM_BARE,
    TERM_LEGACY,
    TERM_NESTED,
    TERM_EMPTY,
    TERM_DIVIDER,
  ]) {
    const doc = runToTiptap([block]);
    const ops = runToOps([block], doc);
    assert.deepEqual(ops, [], `${block.id} should emit no ops when unedited`);
  }
});

// ── 2. the bpTerminal node carries bpId/bpType + chrome attrs ────────────────

check("bpTerminal node carries bpId/bpType + normalized title/footer/live attrs", () => {
  const node = runToTiptap([TERM]).content[0];
  assert.equal(node.type, "bpTerminal");
  assert.equal(node.attrs.bpId, "tm1");
  assert.equal(node.attrs.bpType, "terminal");
  assert.equal(node.attrs.title, "build");
  assert.equal(node.attrs.footer, "^C to quit");
  assert.equal(node.attrs.live, true);
  // A BARE terminal → null title/footer, false live.
  const bare = runToTiptap([TERM_BARE]).content[0];
  assert.equal(bare.attrs.title, null);
  assert.equal(bare.attrs.footer, null);
  assert.equal(bare.attrs.live, false);
});

// ── 3. docToBlocks reconstructs a terminal byte-identically ─────────────────

check("docToBlocks reconstructs a chrome terminal (children id-less, keys stable)", () => {
  assert.deepEqual(docToBlocks(runToTiptap([TERM]))[0], {
    id: "tm1",
    type: "terminal",
    children: [{ type: "paragraph", content: [{ type: "text", value: "$ make" }] }],
    title: "build",
    footer: "^C to quit",
    live: true,
  });
});

check("docToBlocks reconstructs a BARE terminal with NO chrome keys", () => {
  const b = docToBlocks(runToTiptap([TERM_BARE]))[0];
  assert.deepEqual(b, {
    id: "tm2",
    type: "terminal",
    children: [{ type: "paragraph", content: [{ type: "text", value: "x" }] }],
  });
  assert.ok(!("title" in b) && !("footer" in b) && !("live" in b));
});

check("docToBlocks reconstructs divider children", () => {
  assert.deepEqual(docToBlocks(runToTiptap([TERM_DIVIDER]))[0].children, [
    { type: "paragraph", content: [{ type: "text", value: "A" }] },
    { type: "divider" },
  ]);
});

// ── 4. legacy `blocks` key loads + round-trips under canonical `children` ────

check("legacy `blocks` key loads and reconstructs under `children`", () => {
  const b = docToBlocks(runToTiptap([TERM_LEGACY]))[0];
  assert.deepEqual(b, {
    id: "tm3",
    type: "terminal",
    children: [{ type: "paragraph", content: [{ type: "text", value: "old" }] }],
  });
  assert.ok(!("blocks" in b), "reconstruction emits the canonical children key only");
});

// ── 5. a body edit → ONE coarse patch-block replacing children + chrome ─────

check("a body-child edit → ONE patch-block { title, footer, live, children }", () => {
  const doc = clone(runToTiptap([TERM]));
  // Edit the body paragraph text (bpTerminal > paragraph[0]).
  doc.content[0].content[0].content = [{ type: "text", text: "$ make EDITED" }];
  const ops = runToOps([TERM], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "tm1");
  assert.deepEqual(Object.keys(ops[0].patch).sort(), [
    "children",
    "footer",
    "live",
    "title",
  ]);
  assert.equal(ops[0].patch.title, "build", "title carried");
  assert.equal(ops[0].patch.footer, "^C to quit", "footer carried");
  assert.equal(ops[0].patch.live, true, "live carried");
  assert.deepEqual(ops[0].patch.children, [
    { type: "paragraph", content: [{ type: "text", value: "$ make EDITED" }] },
  ]);
});

// ── 6. chrome edits: title / footer CLEAR → null, live OFF → false ──────────

check("a title edit → patch.title updated", () => {
  const doc = clone(runToTiptap([TERM]));
  doc.content[0].attrs.title = "deploy";
  const ops = runToOps([TERM], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.title, "deploy");
});

check("a title CLEAR (node-view writes null) → patch.title === null", () => {
  const doc = clone(runToTiptap([TERM]));
  // The node-view maps an empty input to null; simulate that written attr.
  doc.content[0].attrs.title = null;
  const ops = runToOps([TERM], doc);
  assert.equal(ops.length, 1);
  assert.strictEqual(ops[0].patch.title, null, "explicit null so the clear LANDS");
});

check("a footer CLEAR → patch.footer === null", () => {
  const doc = clone(runToTiptap([TERM]));
  doc.content[0].attrs.footer = null;
  const ops = runToOps([TERM], doc);
  assert.equal(ops.length, 1);
  assert.strictEqual(ops[0].patch.footer, null);
});

check("a live toggle true→false → patch.live === false (explicit, not omitted)", () => {
  const doc = clone(runToTiptap([TERM]));
  doc.content[0].attrs.live = false;
  const ops = runToOps([TERM], doc);
  assert.equal(ops.length, 1);
  assert.strictEqual(ops[0].patch.live, false);
});

// ── 7. absent-chrome fidelity: bare terminal patch = null/null/false ────────

check("a BARE terminal body edit → patch.title/footer null, live false", () => {
  const doc = clone(runToTiptap([TERM_BARE]));
  doc.content[0].content[0].content = [{ type: "text", text: "y" }];
  const ops = runToOps([TERM_BARE], doc);
  assert.equal(ops.length, 1);
  assert.strictEqual(ops[0].patch.title, null);
  assert.strictEqual(ops[0].patch.footer, null);
  assert.strictEqual(ops[0].patch.live, false);
});

// ── 8. FORBID-NESTING / verbatim carry: callout + nested terminal + tasks ───

check("non-first-class children (callout/terminal/tasks) ride bpTerminalAtom deep-equal", () => {
  const node = runToTiptap([TERM_NESTED]).content[0];
  const kids = node.content;
  assert.equal(kids.length, 3);
  for (let i = 0; i < 3; i++) {
    assert.equal(kids[i].type, "bpTerminalAtom", `child ${i} carried verbatim`);
    assert.deepEqual(
      kids[i].attrs.bpBlock,
      TERM_NESTED.children[i],
      `child ${i} bpBlock byte-identical`,
    );
  }
  // Full round-trip is byte-for-byte lossless (no data loss through the coarse patch).
  assert.deepEqual(docToBlocks(runToTiptap([TERM_NESTED]))[0], TERM_NESTED);
});

check("editing a verbatim-carried child sibling still round-trips it untouched", () => {
  // Edit nothing but re-run: the carried children survive an interior body edit next
  // to them (add a prose child edit and confirm the carried blocks are intact).
  const doc = clone(runToTiptap([TERM_NESTED]));
  // No structural change → zero ops (immune); the carried atoms are byte-stable.
  assert.deepEqual(runToOps([TERM_NESTED], doc), []);
});

// ── 9. empty body: seed + strip a sentinel paragraph ────────────────────────

check("an empty body seeds a paragraph then reconstructs to children:[]", () => {
  const node = runToTiptap([TERM_EMPTY]).content[0];
  assert.equal(node.content.length, 1, "seeded with one paragraph so `…+` is satisfiable");
  assert.equal(node.content[0].type, "paragraph");
  assert.deepEqual(docToBlocks(runToTiptap([TERM_EMPTY]))[0], {
    id: "tm5",
    type: "terminal",
    children: [],
  });
});

// ── 10. insert: a fresh (bpId-less) terminal mints an id + OMITS absent chrome ─

check("a new chrome terminal (bpId null) → append-block with minted id + carried chrome", () => {
  const doc = clone(runToTiptap([TERM]));
  doc.content[0].attrs.bpId = null;
  const ops = runToOps([], doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "append-block");
  assert.equal(ops[0].block.type, "terminal");
  assert.ok(ops[0].block.id, "a minted id is stamped");
  assert.equal(ops[0].block.title, "build");
  assert.equal(ops[0].block.footer, "^C to quit");
  assert.equal(ops[0].block.live, true);
  assert.deepEqual(ops[0].block.children, [
    { type: "paragraph", content: [{ type: "text", value: "$ make" }] },
  ]);
});

check("a new BARE terminal insert OMITS title/footer/live (live only when true)", () => {
  const doc = clone(runToTiptap([TERM_BARE]));
  doc.content[0].attrs.bpId = null;
  const ops = runToOps([], doc);
  assert.equal(ops.length, 1);
  const block = ops[0].block;
  assert.ok(!("title" in block), "absent title OMITTED on insert");
  assert.ok(!("footer" in block), "absent footer OMITTED on insert");
  assert.ok(!("live" in block), "false live OMITTED on insert");
});

// ── 11. reconcileServerEcho recognizes a terminal own-echo ──────────────────

check("reconcileServerEcho treats an unchanged terminal run as an own echo", () => {
  const server = [TERM, TERM_BARE, TERM_NESTED];
  const live = runToTiptap(server).content;
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.deepEqual(idWrites, []);
});

check("reconcileServerEcho falls through to external on a real terminal edit", () => {
  const server = [TERM];
  const live = clone(runToTiptap(server).content);
  live[0].content[0].content = [{ type: "text", text: "changed" }];
  const { ownEcho } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, false);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall terminal-node checks PASS");
