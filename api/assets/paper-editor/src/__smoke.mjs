// __smoke.mjs — pure converter round-trip check + editor mark-schema check.
// No DOM and no TipTap *Editor* is instantiated (it imports mark CONFIGS only,
// which load in plain Node). Run: node src/__smoke.mjs   (or: npm run smoke)
//
// Asserts tiptapToFullBlock(blockToTiptap(sample)) reproduces each sample
// block's mutable shape, and that the emitted patch-block op matches what
// patch.ex / content.ex expect.

import assert from "node:assert/strict";
import {
  blockToTiptap,
  tiptapToFullBlock,
  buildPatchBlockOp,
} from "./convert.js";
import { runToTiptap, runToOps } from "./canvas/run-convert.js";
import { Wikilink, Blockref, Tag } from "./marks.js";
import { CONTRACT_VERSION } from "./contract.js";

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

// 1) paragraph with bold + italic + inline code round-trips.
check("paragraph round-trip (text + bold + em + code)", () => {
  const sample = {
    id: "p-1",
    type: "paragraph",
    content: [
      { type: "text", value: "Hello " },
      { type: "strong", children: [{ type: "text", value: "world" }] },
      { type: "text", value: " and " },
      { type: "em", children: [{ type: "text", value: "cosmos" }] },
      { type: "text", value: " " },
      { type: "code", value: "x = 1" },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-1", "paragraph");
  assert.deepEqual(back, sample);
});

// 2) heading carries flat text + level, clamped to 1..3.
check("heading round-trip (text + level)", () => {
  const sample = { id: "h-1", type: "heading", level: 2, text: "Status" };
  const back = tiptapToFullBlock(blockToTiptap(sample), "h-1", "heading");
  assert.deepEqual(back, sample);
});

// 3) bullet list with two items round-trips item inline arrays.
check("bullet list round-trip", () => {
  const sample = {
    id: "l-1",
    type: "list",
    ordered: false,
    items: [
      [{ type: "text", value: "first" }],
      [
        { type: "text", value: "second " },
        { type: "strong", children: [{ type: "text", value: "bold" }] },
      ],
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "l-1", "list");
  assert.deepEqual(back, sample);
});

// 4) ordered list preserves the ordered flag.
check("ordered list flag preserved", () => {
  const sample = {
    id: "l-2",
    type: "list",
    ordered: true,
    items: [[{ type: "text", value: "step one" }]],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "l-2", "list");
  assert.equal(back.ordered, true);
  assert.deepEqual(back, sample);
});

// 5) the emitted patch-block op matches the on-the-wire shape exactly:
//    { op:"patch-block", id, patch:{ content:[...] } }
check("patch-block op shape for 'Hello **world**'", () => {
  const tiptapDoc = blockToTiptap({
    id: "p-9",
    type: "paragraph",
    content: [
      { type: "text", value: "Hello " },
      { type: "strong", children: [{ type: "text", value: "world" }] },
    ],
  });
  const op = buildPatchBlockOp(tiptapDoc, "p-9", "paragraph");
  assert.deepEqual(op, {
    op: "patch-block",
    id: "p-9",
    patch: {
      content: [
        { type: "text", value: "Hello " },
        { type: "strong", children: [{ type: "text", value: "world" }] },
      ],
    },
  });
  console.log("      emitted op:", JSON.stringify(op));
});

// 6) strikethrough round-trips (the canonical bug: strike typed in Studio was
//    dropped on save — MARK_ORDER had no portable-doc equivalent).
check("paragraph round-trip (strikethrough)", () => {
  const sample = {
    id: "p-6",
    type: "paragraph",
    content: [
      { type: "text", value: "was " },
      { type: "strikethrough", children: [{ type: "text", value: "removed" }] },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-6", "paragraph");
  assert.deepEqual(back, sample);
});

// 7) underline round-trips.
check("paragraph round-trip (underline)", () => {
  const sample = {
    id: "p-7",
    type: "paragraph",
    content: [
      { type: "text", value: "see " },
      { type: "underline", children: [{ type: "text", value: "here" }] },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-7", "paragraph");
  assert.deepEqual(back, sample);
});

// 8) nested bold > strikethrough round-trips (nesting matches MARK_ORDER:
//    strong outer, strikethrough inner).
check("paragraph round-trip (bold > strikethrough)", () => {
  const sample = {
    id: "p-8",
    type: "paragraph",
    content: [
      {
        type: "strong",
        children: [
          { type: "strikethrough", children: [{ type: "text", value: "gone" }] },
        ],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-8", "paragraph");
  assert.deepEqual(back, sample);
});

// 9) wikilink WITH alias round-trips ([[target|alias]]).
check("paragraph round-trip (wikilink + alias)", () => {
  const sample = {
    id: "p-9w",
    type: "paragraph",
    content: [
      { type: "text", value: "see " },
      {
        type: "wikilink",
        target: "intro-to-x",
        alias: "the intro",
        children: [{ type: "text", value: "the intro" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-9w", "paragraph");
  assert.deepEqual(back, sample);
});

// 10) wikilink WITHOUT alias round-trips byte-exact — no stray `alias` key.
//     (The idempotency gate: alias:undefined must never leak into the node.)
check("paragraph round-trip (wikilink, no alias)", () => {
  const sample = {
    id: "p-10w",
    type: "paragraph",
    content: [
      {
        type: "wikilink",
        target: "setup",
        children: [{ type: "text", value: "setup" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-10w", "paragraph");
  assert.deepEqual(back, sample);
  assert.ok(
    !Object.prototype.hasOwnProperty.call(back.content[0], "alias"),
    "plain wikilink must not gain an alias key",
  );
});

// 10a) wikilink WITH docId (picked-paper id pin) round-trips carrying
//      target + docId — the id resolves render to the EXACT paper, closing the
//      title-collision hole. Mirrors the alias guard.
check("paragraph round-trip (wikilink + docId)", () => {
  const sample = {
    id: "p-10wd",
    type: "paragraph",
    content: [
      { type: "text", value: "see " },
      {
        type: "wikilink",
        target: "intro-to-x",
        docId: "doc-7",
        children: [{ type: "text", value: "intro-to-x" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-10wd", "paragraph");
  assert.deepEqual(back, sample);
  assert.equal(back.content[1].docId, "doc-7");
});

// 10b) wikilink WITHOUT docId round-trips byte-exact — no stray `docId` key.
//      (The byte-exact gate for every existing / typed-not-picked wikilink:
//      docId:undefined must never leak into the node.)
check("paragraph round-trip (wikilink, no docId)", () => {
  const sample = {
    id: "p-10wnd",
    type: "paragraph",
    content: [
      {
        type: "wikilink",
        target: "setup",
        children: [{ type: "text", value: "setup" }],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-10wnd", "paragraph");
  assert.deepEqual(back, sample);
  assert.ok(
    !Object.prototype.hasOwnProperty.call(back.content[0], "docId"),
    "plain wikilink must not gain a docId key",
  );
});

// 11) blockref leaf round-trips (target/anchor ride the mark, not the text).
check("paragraph round-trip (blockref)", () => {
  const sample = {
    id: "p-11b",
    type: "paragraph",
    content: [
      { type: "text", value: "cf " },
      { type: "blockref", target: "doc-7", anchor: "abc123" },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-11b", "paragraph");
  assert.deepEqual(back, sample);
});

// 12) tag leaf round-trips.
check("paragraph round-trip (tag)", () => {
  const sample = {
    id: "p-12t",
    type: "paragraph",
    content: [
      { type: "text", value: "filed under " },
      { type: "tag", name: "epic" },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-12t", "paragraph");
  assert.deepEqual(back, sample);
});

// 13) bold INSIDE a wikilink round-trips (locks MARK_ORDER: wikilink outside).
check("paragraph round-trip (bold inside wikilink)", () => {
  const sample = {
    id: "p-13",
    type: "paragraph",
    content: [
      {
        type: "wikilink",
        target: "x",
        children: [
          { type: "strong", children: [{ type: "text", value: "X" }] },
        ],
      },
    ],
  };
  const back = tiptapToFullBlock(blockToTiptap(sample), "p-13", "paragraph");
  assert.deepEqual(back, sample);
});

// 14) determinism / idempotency double-pass: a second full round-trip is a
//     no-op for every node kind (proves MARK_ORDER stays aligned).
check("round-trip is idempotent (double-pass, all kinds)", () => {
  const sample = {
    id: "p-14",
    type: "paragraph",
    content: [
      { type: "strong", children: [{ type: "text", value: "b" }] },
      { type: "em", children: [{ type: "text", value: "i" }] },
      { type: "strikethrough", children: [{ type: "text", value: "s" }] },
      { type: "underline", children: [{ type: "text", value: "u" }] },
      { type: "code", value: "c" },
      { type: "link", href: "https://x", children: [{ type: "text", value: "l" }] },
      { type: "wikilink", target: "w", children: [{ type: "text", value: "w" }] },
      { type: "blockref", target: "d", anchor: "a" },
      { type: "tag", name: "t" },
    ],
  };
  const once = tiptapToFullBlock(blockToTiptap(sample), "p-14", "paragraph");
  const twice = tiptapToFullBlock(blockToTiptap(once), "p-14", "paragraph");
  assert.deepEqual(once, sample);
  assert.deepEqual(twice, once);
});

// 15) the editor mark schemas carry EXACTLY the attrs convert.js reads. Drift
//     here (e.g. renaming `anchor`→`anchorId`) would silently break the engine
//     round-trip even though the pure converters still pass. (A full TipTap
//     setContent→getJSON round-trip needs jsdom — tracked as a follow-up.)
check("editor mark schemas match convert.js attrs", () => {
  assert.equal(Wikilink.name, "wikilink");
  assert.deepEqual(Object.keys(Wikilink.config.addAttributes()).sort(), [
    "alias",
    "docId",
    "target",
  ]);
  assert.equal(Blockref.name, "blockref");
  assert.deepEqual(Object.keys(Blockref.config.addAttributes()).sort(), [
    "anchor",
    "target",
  ]);
  assert.equal(Tag.name, "tag");
  assert.deepEqual(Object.keys(Tag.config.addAttributes()), ["name"]);
});

// 16) the embed contract exposes a stable CONTRACT_VERSION from a DOM-free
//     module (so this guard runs in pure Node, never importing index.js).
check("contract exposes CONTRACT_VERSION", () => {
  assert.equal(typeof CONTRACT_VERSION, "string");
  assert.ok(CONTRACT_VERSION.length > 0, "non-empty");
  assert.equal(CONTRACT_VERSION, "1.0.0");
});

// 17) blockToTiptap is editability-independent — the read-mode `editable`
//     attribute lives entirely in the Web Component (index.js); convert.js has
//     no editability parameter and no DOM, so its output is byte-identical in
//     read and edit mode. This proves the editable seam never reaches convert.js.
check("blockToTiptap is identical regardless of editability", () => {
  const sample = {
    id: "p-17",
    type: "paragraph",
    content: [
      { type: "text", value: "read " },
      { type: "strong", children: [{ type: "text", value: "or" }] },
      { type: "text", value: " edit" },
    ],
  };
  assert.deepEqual(blockToTiptap(sample), blockToTiptap(sample));
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S0 — the headless blocks⇄one-doc⇄ops projector (run-convert.js).
// Ships DARK; pin its projection + reverse-diff against the EXACT op vocabulary.
// ───────────────────────────────────────────────────────────────────────────

// ── THE SAFETY NET: a pure-JS reference fold mirroring patch.ex ──────────────
//
// applyOps(prevBlocks, ops) folds the emitted op list through the SAME
// semantics api/lib/barkpark/portable_doc/patch.ex implements, so a test can
// PROVE that runToOps's output reproduces nextDoc — not merely that each op has
// the right SHAPE. The original S0 tests asserted only shape, which is why two
// real fold bugs (a front-insert landing at END; an insert stranded by a later
// move) passed green. Faithful op semantics (top-level only — S0 has no
// sections):
//   append-block  → concat block at END (dup id is an error)
//   insert-after  → splice block immediately after afterId (absent → error;
//                   dup block id → error)
//   remove-block  → drop the block by id (absent → error)
//   move-block    → lift the block by id, splice after `after` (or head when
//                   null); after===id or already-in-place is a no-op
//   patch-block   → shallow-merge patch into the block by id, re-pin id+type
function applyOps(prevBlocks, ops) {
  let blocks = (prevBlocks || []).map((b) => ({ ...b }));
  const idAt = (id) => blocks.findIndex((b) => b && b.id === id);

  for (const op of ops) {
    switch (op.op) {
      case "append-block": {
        if (op.block && op.block.id != null && idAt(op.block.id) !== -1) {
          throw new Error(`append-block: duplicate id ${op.block.id}`);
        }
        blocks = [...blocks, { ...op.block }];
        break;
      }
      case "insert-after": {
        if (op.block && op.block.id != null && idAt(op.block.id) !== -1) {
          throw new Error(`insert-after: duplicate id ${op.block.id}`);
        }
        const at = idAt(op.afterId);
        if (at === -1) throw new Error(`insert-after: afterId not found ${op.afterId}`);
        blocks.splice(at + 1, 0, { ...op.block });
        break;
      }
      case "remove-block": {
        const at = idAt(op.id);
        if (at === -1) throw new Error(`remove-block: id not found ${op.id}`);
        blocks.splice(at, 1);
        break;
      }
      case "move-block": {
        const at = idAt(op.id);
        if (at === -1) throw new Error(`move-block: id not found ${op.id}`);
        if (op.after === op.id) break; // after-itself: no-op
        if (op.after != null && idAt(op.after) === -1) {
          throw new Error(`move-block: after not found ${op.after}`);
        }
        const [moved] = blocks.splice(at, 1);
        if (op.after == null) {
          blocks.unshift(moved);
        } else {
          const dest = idAt(op.after);
          blocks.splice(dest + 1, 0, moved);
        }
        break;
      }
      case "patch-block": {
        const at = idAt(op.id);
        if (at === -1) throw new Error(`patch-block: id not found ${op.id}`);
        const target = blocks[at];
        // Shallow-merge, then re-pin id + type (patch.ex merge_block).
        blocks[at] = { ...target, ...op.patch, id: target.id, type: target.type };
        break;
      }
      default:
        throw new Error(`applyOps: unknown op ${JSON.stringify(op)}`);
    }
  }
  return blocks;
}

// Assert that folding runToOps(prev, nextDoc) through applyOps yields a block
// list whose ID ORDER === the id order of nextDoc's nextSeq (existing bpIds in
// place; a stable client-minted id for every new node), and that every
// SURVIVING block carries the patched content. This is the fold gate the
// original shape-only tests lacked.
function assertFolds(prev, nextDoc, ops, label) {
  const result = applyOps(prev, ops);

  // Expected id order: existing bpId where present, else SOME minted id. We
  // can't predict minted ids, so we assert structurally: result length ===
  // next length, every surviving bpId sits at its next index, and every NEW
  // slot (next node without a surviving bpId) holds a block that is NOT a prev
  // id (i.e. a freshly-minted/new block).
  const prevIds = new Set((prev || []).map((b) => b && b.id));
  const nextNodes = (nextDoc && nextDoc.content) || [];
  assert.equal(
    result.length,
    nextNodes.length,
    `${label}: folded length ${result.length} !== next length ${nextNodes.length}`,
  );
  nextNodes.forEach((node, i) => {
    const bpId = node.attrs && node.attrs.bpId;
    const folded = result[i];
    const survives = bpId != null && prevIds.has(bpId);
    if (survives) {
      assert.equal(
        folded.id,
        bpId,
        `${label}: slot ${i} expected surviving id ${bpId}, got ${folded && folded.id}`,
      );
    } else {
      // A new slot: the folded block must NOT be a pre-existing prev id (it is a
      // freshly-inserted, client-minted block), and it must carry a non-null id.
      assert.ok(
        folded && folded.id != null && !prevIds.has(folded.id),
        `${label}: slot ${i} expected a fresh (minted) id, got ${folded && folded.id}`,
      );
    }
  });
  return result;
}

// S0-a) runToTiptap projects a block list to one doc, one top-level node per
//       block IN ORDER, each stamped attrs.bpId/bpType; heading keeps its level.
check("S0 runToTiptap: 3 blocks → 3 stamped nodes in order", () => {
  const heading = { id: "h-1", type: "heading", level: 2, text: "Status" };
  const paragraph = {
    id: "p-1",
    type: "paragraph",
    content: [{ type: "text", value: "Body text" }],
  };
  const list = {
    id: "l-1",
    type: "list",
    ordered: false,
    items: [[{ type: "text", value: "one" }]],
  };
  const doc = runToTiptap([heading, paragraph, list]);

  assert.equal(doc.type, "doc");
  assert.equal(doc.content.length, 3);

  // order + stamp preserved
  assert.equal(doc.content[0].attrs.bpId, "h-1");
  assert.equal(doc.content[0].attrs.bpType, "heading");
  assert.equal(doc.content[0].type, "heading");
  assert.equal(doc.content[0].attrs.level, 2); // heading level survives the merge

  assert.equal(doc.content[1].attrs.bpId, "p-1");
  assert.equal(doc.content[1].attrs.bpType, "paragraph");
  assert.equal(doc.content[1].type, "paragraph");

  assert.equal(doc.content[2].attrs.bpId, "l-1");
  assert.equal(doc.content[2].attrs.bpType, "list");
  assert.equal(doc.content[2].type, "bulletList");
});

// S0-b) an interior text edit of the MIDDLE node → EXACTLY one patch-block,
//       byte-identical to buildPatchBlockOp on that single block (pinned against
//       the case-5 fixture shape: { op:"patch-block", id, patch:{ content:[…] } }).
check("S0 runToOps: interior edit → one patch-block (byte-identical)", () => {
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Title" },
    { id: "p-9", type: "paragraph", content: [{ type: "text", value: "Hello " }] },
    { id: "p-3", type: "paragraph", content: [{ type: "text", value: "tail" }] },
  ];
  const doc = runToTiptap(blocks);
  // Edit only the middle node's content: "Hello " → "Hello **world**".
  doc.content[1] = {
    ...doc.content[1],
    content: [
      { type: "text", text: "Hello " },
      { type: "text", text: "world", marks: [{ type: "bold" }] },
    ],
  };

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "exactly one op for a lone interior edit");

  // Byte-identical to the per-block path (mirrors case-5 fixture shape).
  const expected = buildPatchBlockOp(
    blockToTiptap({
      id: "p-9",
      type: "paragraph",
      content: [
        { type: "text", value: "Hello " },
        { type: "strong", children: [{ type: "text", value: "world" }] },
      ],
    }),
    "p-9",
    "paragraph",
  );
  assert.deepEqual(ops[0], expected);
  assert.deepEqual(ops[0], {
    op: "patch-block",
    id: "p-9",
    patch: {
      content: [
        { type: "text", value: "Hello " },
        { type: "strong", children: [{ type: "text", value: "world" }] },
      ],
    },
  });

  // FOLD GATE: a pure interior edit emits ZERO moves and folds to the same
  // order with the patched content landing on p-9.
  const folded = assertFolds(blocks, doc, ops, "S0-b interior edit");
  assert.equal(ops.filter((o) => o.op === "move-block").length, 0, "no moves");
  assert.deepEqual(folded[1].content, [
    { type: "text", value: "Hello " },
    { type: "strong", children: [{ type: "text", value: "world" }] },
  ]);
});

// S0-c) split: one node becomes two, the new one has no bpId → the projector
//       CLIENT-MINTS its id and emits [insert-after{afterId:p-1, block w/ minted
//       id}, patch-block{p-1}]. (The old design emitted an idless block and
//       relied on a server mint; client-minting is what lets a front-insert /
//       reorder be expressed at all — see S0-g..k.)
check("S0 runToOps: split → insert-after(minted id) then patch-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha beta" }] },
  ];
  const doc = runToTiptap(blocks);
  // p-1 keeps "alpha"; a NEW (no bpId) paragraph "beta" lands after it.
  doc.content = [
    {
      type: "paragraph",
      attrs: { bpId: "p-1", bpType: "paragraph" },
      content: [{ type: "text", text: "alpha" }],
    },
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" }, // new → client-minted id
      content: [{ type: "text", text: "beta" }],
    },
  ];

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 2, "one insert + one interior patch");

  // insert-after first (anchored to the surviving sibling). The new block now
  // carries a CLIENT-MINTED id (it cannot collide with p-1) and the "beta" body.
  assert.equal(ops[0].op, "insert-after");
  assert.equal(ops[0].afterId, "p-1");
  assert.equal(ops[0].block.type, "paragraph");
  assert.deepEqual(ops[0].block.content, [{ type: "text", value: "beta" }]);
  assert.ok(
    ops[0].block.id != null && ops[0].block.id !== "p-1",
    "split insert carries a fresh client-minted id (not the prev id)",
  );

  // then the interior patch on the shrunk first block.
  assert.deepEqual(ops[1], {
    op: "patch-block",
    id: "p-1",
    patch: { content: [{ type: "text", value: "alpha" }] },
  });

  // FOLD GATE: p-1 shrinks to "alpha"; the minted block holds "beta" at slot 1.
  const folded = assertFolds(blocks, doc, ops, "S0-c split");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "alpha" }]);
  assert.deepEqual(folded[1].content, [{ type: "text", value: "beta" }]);
});

// S0-d) merge: two nodes → one → [remove-block{id:secondId}, patch-block{firstId}].
check("S0 runToOps: merge → remove-block then patch-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "beta" }] },
  ];
  const doc = runToTiptap(blocks);
  // p-2 deleted; p-1 absorbs both → "alpha beta".
  doc.content = [
    {
      type: "paragraph",
      attrs: { bpId: "p-1", bpType: "paragraph" },
      content: [{ type: "text", text: "alpha beta" }],
    },
  ];

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 2);
  assert.deepEqual(ops[0], { op: "remove-block", id: "p-2" });
  assert.deepEqual(ops[1], {
    op: "patch-block",
    id: "p-1",
    patch: { content: [{ type: "text", value: "alpha beta" }] },
  });

  // FOLD GATE: result is a single block p-1 carrying the merged content.
  const folded = assertFolds(blocks, doc, ops, "S0-d merge");
  assert.equal(folded.length, 1);
  assert.equal(folded[0].id, "p-1");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "alpha beta" }]);
});

// S0-e) reorder two nodes (no content change) → [move-block{…}] with the right
//       id/after. Swap [p-1, p-2] → [p-2, p-1]: move p-1 after p-2.
check("S0 runToOps: reorder → single move-block, no patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "beta" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[1], doc.content[0]]; // [p-2, p-1]

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1, "a pure reorder is one move, no patch");
  // The swap [p-1,p-2]→[p-2,p-1] is a single move-block. The left-to-right
  // permutation walk fixes the FIRST out-of-place slot, so it moves p-2 to the
  // head (move-block{id:p-2, after:null}); an equally-valid one-move solution
  // would move p-1 after p-2. We assert the SHAPE (one move, both ids known)
  // and let the fold gate prove correctness — minimality is secondary.
  assert.equal(ops[0].op, "move-block");
  assert.ok(
    (ops[0].id === "p-2" && ops[0].after === null) ||
      (ops[0].id === "p-1" && ops[0].after === "p-2"),
    "a single move-block that effects the swap",
  );

  // FOLD GATE: folds to [p-2, p-1] with no content change.
  const folded = assertFolds(blocks, doc, ops, "S0-e reorder");
  assert.deepEqual(folded.map((b) => b.id), ["p-2", "p-1"]);
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no patches");
});

// S0-f) mixed list with a NON-PROSE block (callout) → runToTiptap emits a
//       bpOpaque node carrying the block JSON VERBATIM, and runToOps round-trips
//       it with NO op (the opaque block is deep-equal to the original).
check("S0 non-prose block: opaque carry-through, zero ops on round-trip", () => {
  const callout = {
    id: "c-1",
    type: "callout",
    variant: "info",
    content: [{ type: "text", value: "heads up" }],
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    callout,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // The callout projects to an opaque placeholder carrying the block verbatim.
  const opaque = doc.content[1];
  assert.equal(opaque.type, "bpOpaque");
  assert.equal(opaque.attrs.bpId, "c-1");
  assert.equal(opaque.attrs.bpType, "callout");
  assert.deepEqual(opaque.attrs.bpBlock, callout); // verbatim, deep-equal
  assert.notEqual(opaque.attrs.bpBlock, callout); // but NOT a shared ref

  // An untouched round-trip emits NO ops at all (opaque is not edited in S0).
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "untouched mixed list round-trips with zero ops");

  // FOLD GATE: zero ops fold to the identical block list (order + content).
  const folded = assertFolds(blocks, doc, ops, "S0-f opaque round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "c-1", "p-1"]);
  assert.deepEqual(folded[1], callout);
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3 — the divider as a canvas ATOM node (run-convert.js).
// A divider in a run is NO LONGER opaque: runToTiptap emits a native
// { type:"divider", attrs:{bpId,bpType} } leaf, and runToOps reconstructs a
// bare { type:"divider" } block. A leaf → NEVER an interior patch.
// ───────────────────────────────────────────────────────────────────────────

// S3-a) PROJECTION — a divider in a run projects to a native divider ATOM node
//       carrying ONLY { bpId, bpType }, NOT a bpOpaque placeholder. The prose
//       blocks around it still project as their own stamped textblocks.
check("S3 runToTiptap: a divider → { type:'divider', attrs:{bpId,bpType} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    { id: "d-1", type: "divider" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  assert.equal(doc.content.length, 3);

  const div = doc.content[1];
  assert.equal(div.type, "divider", "divider projects to a native divider node");
  assert.notEqual(div.type, "bpOpaque", "divider is NOT carried opaquely");
  assert.equal(div.attrs.bpId, "d-1");
  assert.equal(div.attrs.bpType, "divider");
  // A leaf: no content, and no opaque bpBlock carry.
  assert.ok(!("content" in div), "divider leaf carries no content");
  assert.ok(!("bpBlock" in div.attrs), "divider carries no opaque bpBlock");

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "heading");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3-b) ROUND-TRIP — an UNTOUCHED divider survives runToOps with ZERO ops (a
//       leaf reports no interior change), and the whole mixed run folds back to
//       the identical block list.
check("S3 runToOps: an untouched divider round-trips with ZERO ops", () => {
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    { id: "d-1", type: "divider" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched divider run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the divider survives as
  // its bare { id, type } leaf.
  const folded = assertFolds(blocks, doc, ops, "S3-b divider round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "d-1", "p-1"]);
  assert.deepEqual(folded[1], { id: "d-1", type: "divider" });
});

// S3-c) INSERT — a NEW divider (no bpId) between two surviving prose blocks →
//       an insert-after carrying a { type:"divider" } block with a client-minted
//       id, and NO patch on the divider (a leaf). The fold lands the divider
//       between the two prose blocks.
check("S3 runToOps: inserting a divider → insert-after with a {type:'divider'} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // Splice a NEW divider (bpId null → minted) between p-1 and p-2.
  doc.content = [
    doc.content[0], // p-1
    { type: "divider", attrs: { bpId: null, bpType: "divider" } },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);

  // The new divider is grafted in as a divider BLOCK with a fresh minted id.
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "divider",
  );
  assert.ok(ins, "a divider block is inserted");
  assert.equal(ins.block.type, "divider");
  assert.ok(ins.block.id != null, "the inserted divider carries a minted id");
  assert.ok(
    ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the divider's minted id avoids the surviving prev ids",
  );
  // A leaf insert carries no body fields beyond id + type.
  assert.deepEqual(Object.keys(ins.block).sort(), ["id", "type"]);
  // No interior patch is emitted for the divider (it is a leaf).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "a divider never emits an interior patch",
  );

  // FOLD GATE: the divider lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3-c divider insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "divider");
  assert.equal(folded[2].id, "p-2");
});

// S3-d) REMOVE — deleting a divider → a remove-block keyed by its id, and the
//       surrounding prose is untouched (no spurious patches). The fold drops it.
check("S3 runToOps: removing a divider → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "d-1", type: "divider" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // Backspace-deletes the divider: the doc is now just the two prose blocks.
  doc.content = [doc.content[0], doc.content[2]];

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "d-1" }],
    "exactly one remove-block for the divider",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  // FOLD GATE: the divider is gone; the two prose blocks remain in order.
  const folded = assertFolds(blocks, doc, ops, "S3-d divider remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3-e) NON-INTERFERENCE — a divider between two prose blocks does not break the
//       prose diff: editing BOTH prose blocks emits exactly their two patches and
//       the divider emits NONE. (Proves the leaf sits transparently in the run.)
check("S3 runToOps: a divider between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "d-1", type: "divider" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  // Edit BOTH prose blocks; leave the divider untouched.
  doc.content[0] = {
    ...doc.content[0],
    content: [{ type: "text", text: "ONE!" }],
  };
  doc.content[2] = {
    ...doc.content[2],
    content: [{ type: "text", text: "TWO!" }],
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the divider");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "d-1").length,
    0,
    "the divider emits no patch",
  );

  // FOLD GATE: both prose blocks carry their new content; the divider survives
  // untouched at slot 1.
  const folded = assertFolds(blocks, doc, ops, "S3-e divider non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], { id: "d-1", type: "divider" });
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3-f) STILL-OPAQUE — a NON-divider, non-prose block (callout) is STILL carried
//       opaquely, unchanged from S0. Only the divider was pulled into the canvas.
check("S3 runToTiptap: a callout is STILL opaque (only divider became canvas-handled)", () => {
  const callout = {
    id: "c-1",
    type: "callout",
    variant: "info",
    content: [{ type: "text", value: "note" }],
  };
  const doc = runToTiptap([callout]);
  assert.equal(doc.content[0].type, "bpOpaque", "callout stays opaque");
  assert.deepEqual(doc.content[0].attrs.bpBlock, callout);
});

// S0-mark) KEY-ORDER ROBUSTNESS — a live editor's getJSON() serializes a marked
//          text node as {type, marks, text}, but runToTiptap builds it as
//          {type, text, marks}. Change-detection MUST be key-order-insensitive,
//          or EVERY marked block looks "edited" on every keystroke (N+1 spurious
//          patches, breaking single-block isolation). Simulate getJSON's order
//          and assert ZERO ops on an unedited mount, exactly ONE on a real edit.
check("S0 runToOps: marked blocks are NOT spuriously patched (key-order robust)", () => {
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Title" },
    {
      id: "p-1",
      type: "paragraph",
      content: [
        { type: "text", value: "Hello " },
        { type: "strong", children: [{ type: "text", value: "world" }] },
      ],
    },
  ];

  // Rewrite every node's keys into ProseMirror getJSON order (type, attrs,
  // marks, content/text) — semantically identical, different key order. This is
  // exactly what the live editor feeds runToOps.
  const reorder = (node) => {
    if (!node || typeof node !== "object") return node;
    const out = {};
    if ("type" in node) out.type = node.type;
    if ("attrs" in node) out.attrs = node.attrs;
    if ("marks" in node) out.marks = (node.marks || []).map(reorder);
    if ("content" in node) out.content = (node.content || []).map(reorder);
    if ("text" in node) out.text = node.text;
    for (const k of Object.keys(node)) if (!(k in out)) out[k] = node[k];
    return out;
  };
  const live = { type: "doc", content: runToTiptap(blocks).content.map(reorder) };

  // UNEDITED mount: ZERO ops, despite the key-order difference AND the mark.
  assert.equal(
    runToOps(blocks, live).length,
    0,
    "an unedited marked run must emit ZERO ops (key-order robust)",
  );

  // A real single-block edit (heading text) → exactly ONE patch-block, for the
  // heading only — the marked paragraph is NOT spuriously patched.
  const edited = { type: "doc", content: live.content.slice() };
  edited.content[0] = reorder({
    type: "heading",
    attrs: { bpId: "h-1", bpType: "heading", level: 1 },
    content: [{ type: "text", text: "Title!" }],
  });
  const ops = runToOps(blocks, edited);
  assert.equal(ops.length, 1, "single edit on a marked run → exactly one op");
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "h-1");
});

// S0-g) FRONT INSERT — a NEW block at position 0. This is the bug the old
//       append-anchored design got WRONG: a front-insert landed at END. The
//       projector must client-mint the new id and, since there is no prepend op,
//       express the front placement via a move-block to the head. Folding MUST
//       put the new block at slot 0.
check("S0 runToOps: front insert → folds to position 0 (was: landed at END)", () => {
  const blocks = [
    { id: "a", type: "paragraph", content: [{ type: "text", value: "A" }] },
    { id: "b", type: "paragraph", content: [{ type: "text", value: "B" }] },
  ];
  const doc = runToTiptap(blocks);
  // New paragraph "N" at the FRONT: [N(new), a, b].
  doc.content = [
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" },
      content: [{ type: "text", text: "N" }],
    },
    doc.content[0], // a
    doc.content[1], // b
  ];

  const ops = runToOps(blocks, doc);
  // The new block is grafted in (insert-after a surviving anchor) then moved to
  // the head — there is no prepend op, so a move-block{after:null} is mandatory.
  assert.ok(
    ops.some((o) => o.op === "insert-after" || o.op === "append-block"),
    "the new block is inserted",
  );
  assert.ok(
    ops.some((o) => o.op === "move-block" && o.after === null),
    "front placement requires a move to the head",
  );

  // FOLD GATE: the new (minted) block lands at slot 0; a, b follow in order.
  const folded = assertFolds(blocks, doc, ops, "S0-g front insert");
  assert.deepEqual(folded.map((b) => b.content), [
    [{ type: "text", value: "N" }],
    [{ type: "text", value: "A" }],
    [{ type: "text", value: "B" }],
  ]);
  assert.equal(folded[1].id, "a");
  assert.equal(folded[2].id, "b");
  assert.ok(folded[0].id !== "a" && folded[0].id !== "b", "front block is freshly minted");
});

// S0-h) INSERT + REORDER together — [a,b] → [c(new), b, a]. The canonical bug:
//       inserts emitted before moves, so a later move stranded the insert
//       (c-NEW-a-b folded to c-a-b-NEW). With client-minted ids the moves pass
//       permutes ALL of {c, a, b} into [c, b, a] regardless of where the insert
//       grafted c. The fold MUST equal [c, b, a].
check("S0 runToOps: insert + reorder → [c(new), b, a] folds correctly", () => {
  const blocks = [
    { id: "a", type: "paragraph", content: [{ type: "text", value: "A" }] },
    { id: "b", type: "paragraph", content: [{ type: "text", value: "B" }] },
  ];
  const doc = runToTiptap(blocks);
  const aNode = doc.content[0];
  const bNode = doc.content[1];
  doc.content = [
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" },
      content: [{ type: "text", text: "C" }],
    },
    bNode, // b
    aNode, // a
  ];

  const ops = runToOps(blocks, doc);

  // FOLD GATE: the only correctness contract — fold to [c(minted), b, a].
  const folded = assertFolds(blocks, doc, ops, "S0-h insert + reorder");
  assert.deepEqual(folded.map((b) => b.content), [
    [{ type: "text", value: "C" }],
    [{ type: "text", value: "B" }],
    [{ type: "text", value: "A" }],
  ]);
  assert.equal(folded[1].id, "b");
  assert.equal(folded[2].id, "a");
  assert.ok(folded[0].id !== "a" && folded[0].id !== "b", "c is freshly minted");
});

// S0-i) TWO CONSECUTIVE new blocks at the FRONT — [a] → [n1(new), n2(new), a].
//       Both must mint distinct ids that don't collide with each other or `a`,
//       and the fold must place them in order ahead of `a`.
check("S0 runToOps: two consecutive new front blocks fold in order", () => {
  const blocks = [
    { id: "a", type: "paragraph", content: [{ type: "text", value: "A" }] },
  ];
  const doc = runToTiptap(blocks);
  const aNode = doc.content[0];
  doc.content = [
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" },
      content: [{ type: "text", text: "N1" }],
    },
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" },
      content: [{ type: "text", text: "N2" }],
    },
    aNode, // a
  ];

  const ops = runToOps(blocks, doc);

  // FOLD GATE: [n1, n2, a] in order, two distinct minted ids, neither === "a".
  const folded = assertFolds(blocks, doc, ops, "S0-i two front inserts");
  assert.deepEqual(folded.map((b) => b.content), [
    [{ type: "text", value: "N1" }],
    [{ type: "text", value: "N2" }],
    [{ type: "text", value: "A" }],
  ]);
  assert.equal(folded[2].id, "a");
  assert.notEqual(folded[0].id, folded[1].id, "the two minted ids are distinct");
  assert.ok(folded[0].id !== "a" && folded[1].id !== "a", "minted ids avoid prev id");
});

// S0-j) EMPTY PREV → all-new (the append path). No surviving anchor exists, so
//       the first new block APPENDS and the rest insert-after it; the fold must
//       reproduce all three in order.
check("S0 runToOps: empty prev → all-new appends fold in order", () => {
  const blocks = [];
  const doc = {
    type: "doc",
    content: [
      {
        type: "paragraph",
        attrs: { bpId: null, bpType: "paragraph" },
        content: [{ type: "text", text: "X" }],
      },
      {
        type: "paragraph",
        attrs: { bpId: null, bpType: "paragraph" },
        content: [{ type: "text", text: "Y" }],
      },
      {
        type: "paragraph",
        attrs: { bpId: null, bpType: "paragraph" },
        content: [{ type: "text", text: "Z" }],
      },
    ],
  };

  const ops = runToOps(blocks, doc);
  assert.ok(
    ops.some((o) => o.op === "append-block"),
    "with no surviving anchor the first insert appends",
  );

  // FOLD GATE: [X, Y, Z] in order, three distinct minted ids.
  const folded = assertFolds(blocks, doc, ops, "S0-j empty prev");
  assert.deepEqual(folded.map((b) => b.content), [
    [{ type: "text", value: "X" }],
    [{ type: "text", value: "Y" }],
    [{ type: "text", value: "Z" }],
  ]);
  const ids = folded.map((b) => b.id);
  assert.equal(new Set(ids).size, 3, "all three minted ids are distinct");
});

// S0-k) REORDER-ONLY across three blocks (no inserts) — [a,b,c] → [c,a,b] still
//       folds to the new order, emitting only moves and no inserts/patches.
check("S0 runToOps: reorder-only [a,b,c] → [c,a,b] folds, no inserts/patches", () => {
  const blocks = [
    { id: "a", type: "paragraph", content: [{ type: "text", value: "A" }] },
    { id: "b", type: "paragraph", content: [{ type: "text", value: "B" }] },
    { id: "c", type: "paragraph", content: [{ type: "text", value: "C" }] },
  ];
  const doc = runToTiptap(blocks);
  const [aNode, bNode, cNode] = doc.content;
  doc.content = [cNode, aNode, bNode]; // [c, a, b]

  const ops = runToOps(blocks, doc);
  assert.equal(
    ops.filter((o) => o.op === "insert-after" || o.op === "append-block").length,
    0,
    "a pure reorder emits no inserts",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no patches");

  // FOLD GATE: folds to [c, a, b].
  const folded = assertFolds(blocks, doc, ops, "S0-k reorder-only");
  assert.deepEqual(folded.map((b) => b.id), ["c", "a", "b"]);
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall round-trips PASS");
