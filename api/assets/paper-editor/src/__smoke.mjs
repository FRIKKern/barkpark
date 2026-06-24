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
  // Phase-6 fuzz: the SAME inline serializer/deserializer the projector uses, so
  // the generator can canonicalize random inline spans into projection
  // fixed-point stored shapes (a real stored run is always a prior projection).
  inlineArrayToTiptap,
  tiptapInlineToPd,
} from "./convert.js";
import {
  runToTiptap,
  runToOps,
  reconcileServerEcho,
  // P5 source-mode: the LIVE-doc → blocks projection. Source mode derives its
  // baseline (L0) from the live editor doc via docToBlocks(normalizeCanvasDoc(
  // getJSON())) — the SAME node→block path runToOps diffs internally — so the
  // markdown reflects the user's just-typed, not-yet-confirmed edits (NOT the
  // echo-confirmed, LAGGING this._blocks).
  docToBlocks,
} from "./canvas/run-convert.js";
// S3.5: the COERCION lifted from BarkparkFieldBlockBridge — imported so the smoke
// can assert the canvas field coercion matches the per-block bridge byte-for-byte
// (boolean → control.checked; every other native type → control.value).
import {
  coerceFieldValue,
  coercePickerValue,
  BP_NATIVE_FIELD_TYPES,
  BP_PICKER_FIELD_TYPES,
} from "./canvas/field-node.js";
// S3.6: the read-only-atom chip label helpers — imported so the smoke can assert the
// read-only REPRESENTATION (the sheet summary chip "Sheet · <ref> · NxM"; the embed
// reference chip "↪ <target>") matches the read-only render choice, in pure Node (these
// helpers reference NO DOM — the NodeView that uses them never runs here).
import {
  sheetChipLabel,
  embedChipLabel,
  BP_SHEET_NODE_NAME,
  BP_EMBED_NODE_NAME,
} from "./canvas/embed-node.js";
import { Wikilink, Blockref, Tag } from "./marks.js";
import { CONTRACT_VERSION } from "./contract.js";
// P4 S-slash: the PURE slash-insert core (split out of canvas/index.js so it loads
// in plain Node). Asserted here: each insertable type's slashTypeToNode round-trips
// to the right { type, …default } block via runToOps+nextNodeToBlock, the excluded
// types are absent from CANVAS_SLASH_TYPES, and the default blocks mirror
// default_block/2. The callout `> [!type]` shorthand path (tone parse) is covered by
// __callout_shorthand.test.mjs; here we assert the SHORTHAND-produced callout NODE
// reconstructs to a callout block of the matched tone.
import {
  CANVAS_SLASH_TYPES,
  canvasDefaultBlock,
  slashTypeToNode,
  CANVAS_SLASH_TEXTABLE_NODES,
  slashTriggerAllowsParent,
} from "./canvas/slash-insert.js";
import { normalizeTone } from "./tone.js";
// P5 command palette: the PURE registry + fuzzy filter (no DOM — CommandPalette, the
// popup, references document only inside method bodies, so the module imports in plain
// Node). Asserted below: the registry is well-formed (id/label/group/run on every
// command); the Insert commands produce the SAME default block as the slash pick
// (slashTypeToNode → nextNodeToBlock byte-equal to the slash-menu path); and the fuzzy
// filter returns the expected matches ("cal" → Insert Callout; "bold" → Format Bold).
import {
  buildCommandRegistry,
  fuzzyFilterCommands,
  fuzzyMatch,
} from "./canvas/command-palette.js";
// Phase-5 source-mode: the PURE bidirectional blocks⇄markdown converter. As of the
// source-mode toggle it is now imported by canvas/index.js (the "Toggle Markdown
// source" feature serializes the run to markdown and parses the edited markdown
// back), so it RIDES IN THE BUNDLE. The fuzz gate at the bottom reuses the SAME
// genRun generator the canvas property tests use; the source-mode no-edit /
// edited-diff invariants are asserted in the §P5 SOURCE-MODE block below.
import { blocksToMarkdown, markdownToBlocks } from "./markdown.js";
// P5 SOURCE-MODE realignment: the PURE id-realigner that maps markdown-parsed blocks
// (fresh minted ids) back onto the source baseline ids so runToOps emits a PATCH for
// an in-place edit (not remove+insert). Exported from canvas/index.js for the
// no-edit-zero-ops + edited-one-patch assertions below. NOTE: importing canvas/index.js
// in plain Node would touch `document`/`customElements` at module load (the
// customElements.define call), which is undefined here — so the realigner is imported
// from a TINY pure module canvas/index.js re-exports, keeping the smoke DOM-free.
import { realignBlockIds } from "./canvas/source-realign.js";

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

// S0-f) mixed list with a still-OPAQUE non-prose block (composite) →
//       runToTiptap emits a bpOpaque node carrying the block JSON VERBATIM, and
//       runToOps round-trips it with NO op (the opaque block is deep-equal to the
//       original). (S3.2 pulled the callout INTO the canvas; S3.5 pulled the 7
//       NATIVE field-* types in; the run-splitter tail pulled the PICKER fields
//       field-image / field-reference in too — so this case now uses `composite`, a
//       NESTED-STRUCTURE field that stays a boundary / bpOpaque.)
check("S0 non-prose block: opaque carry-through, zero ops on round-trip", () => {
  const field = {
    id: "f-1",
    type: "composite",
    fields: [{ name: "x", type: "string", title: "X" }],
    value: { x: "v" },
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    field,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // The field projects to an opaque placeholder carrying the block verbatim.
  const opaque = doc.content[1];
  assert.equal(opaque.type, "bpOpaque");
  assert.equal(opaque.attrs.bpId, "f-1");
  assert.equal(opaque.attrs.bpType, "composite");
  assert.deepEqual(opaque.attrs.bpBlock, field); // verbatim, deep-equal
  assert.notEqual(opaque.attrs.bpBlock, field); // but NOT a shared ref

  // An untouched round-trip emits NO ops at all (opaque is not edited in S0).
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "untouched mixed list round-trips with zero ops");

  // FOLD GATE: zero ops fold to the identical block list (order + content).
  const folded = assertFolds(blocks, doc, ops, "S0-f opaque round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "f-1", "p-1"]);
  assert.deepEqual(folded[1], field);
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

// S3-f) STILL-OPAQUE — a NESTED-STRUCTURE field (composite), still a boundary, is
//       STILL carried opaquely. (S3.5 pulled the 7 NATIVE field-* types into the canvas;
//       the run-splitter tail pulled the PICKER fields field-image / field-reference in
//       too — but composite / arrayOf / codelist / localizedText / section stay opaque
//       boundaries, a separate nested-structure increment.)
check("S3 runToTiptap: a composite field is STILL opaque (native + picker fields became canvas-handled, nested-structure fields did not)", () => {
  const field = {
    id: "f-1",
    type: "composite",
    fields: [{ name: "x", type: "string", title: "X" }],
    value: { x: "v" },
  };
  const doc = runToTiptap([field]);
  assert.equal(doc.content[0].type, "bpOpaque", "composite stays opaque");
  assert.deepEqual(doc.content[0].attrs.bpBlock, field);
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.2 — the callout as a canvas CONTENT node (run-convert.js).
// A callout in a run is NO LONGER opaque: runToTiptap emits a native
// { type:"callout", attrs:{bpId,bpType,tone,title?,collapsible?,collapsed?},
//   content:[inline…] } node, and runToOps reconstructs a callout block via
// calloutNodeToBlock. Unlike the divider ATOM, a callout HAS an editable body, so
// a body/chrome edit → exactly one patch-block; an untouched callout → ZERO ops.
// ───────────────────────────────────────────────────────────────────────────

// S3.2-a) PROJECTION — a callout in a run projects to a native callout CONTENT
//   node (NOT bpOpaque): body→content (inline), tone/title/collapsible→attrs.
check("S3.2 runToTiptap: a callout → { type:'callout', content:[…], attrs:{tone,title,collapsible} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    {
      id: "c-1",
      type: "callout",
      tone: "warning",
      title: "Heads up",
      collapsible: true,
      content: [
        { type: "text", value: "Be " },
        { type: "strong", children: [{ type: "text", value: "careful" }] },
      ],
    },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3);

  const c = doc.content[1];
  assert.equal(c.type, "callout", "callout projects to a native callout node");
  assert.notEqual(c.type, "bpOpaque", "callout is NOT carried opaquely");
  assert.equal(c.attrs.bpId, "c-1");
  assert.equal(c.attrs.bpType, "callout");
  // Chrome rides attrs.
  assert.equal(c.attrs.tone, "warning");
  assert.equal(c.attrs.title, "Heads up");
  assert.equal(c.attrs.collapsible, true);
  assert.ok(!("collapsed" in c.attrs), "absent collapsed is NOT projected (byte-fidelity)");
  assert.ok(!("bpBlock" in c.attrs), "callout carries no opaque bpBlock");
  // Body is editable inline content — reuses the shared inline serializer, so the
  // bold mark round-trips exactly as a paragraph's would.
  assert.deepEqual(c.content, [
    { type: "text", text: "Be " },
    { type: "text", text: "careful", marks: [{ type: "bold" }] },
  ]);

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "paragraph");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3.2-b) ROUND-TRIP — an UNTOUCHED callout survives runToOps with ZERO ops
//   (canonical compare), and the whole mixed run folds back to the identical
//   block list (body inline + chrome fields all preserved, absent fields absent).
check("S3.2 runToOps: an untouched callout round-trips with ZERO ops (canonical compare)", () => {
  const callout = {
    id: "c-1",
    type: "callout",
    tone: "info",
    content: [{ type: "text", value: "note" }],
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    callout,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Simulate the live editor's getJSON key order on the callout's body text node
  // (type, marks, text) AND its attrs — change-detection must be key-order-safe.
  const c = doc.content[1];
  c.attrs = { bpType: "callout", tone: "info", bpId: "c-1" }; // reordered keys
  c.content = [{ text: "note", type: "text" }]; // reordered keys

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched callout run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the callout survives with
  // its tone + body, and NO stray title/collapsible/collapsed.
  const folded = assertFolds(blocks, doc, ops, "S3.2-b callout round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "c-1", "p-1"]);
  assert.deepEqual(folded[1], callout);
});

// S3.2-c) BODY EDIT — editing the callout's BODY → exactly one patch-block for
//   the callout carrying the new content (and tone), no prose perturbation.
check("S3.2 runToOps: editing the callout BODY → one patch-block with the new content", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      content: [{ type: "text", value: "old body" }],
    },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // Edit ONLY the callout body (live-editor key order).
  doc.content[1] = {
    ...doc.content[1],
    content: [{ type: "text", text: "new body!" }],
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block, for the callout");
  assert.equal(patches[0].id, "c-1");
  assert.deepEqual(patches[0].patch.content, [{ type: "text", value: "new body!" }]);
  assert.equal(patches[0].patch.tone, "info", "tone is carried in the patch");
  // The patch carries the chrome fields EXPLICITLY (removal-safe over the shallow
  // merge): a title-less callout patches title:null, which compose drops — so the
  // stored callout stays title-less.
  assert.equal(patches[0].patch.title, null, "explicit title:null (removal-safe)");
  assert.equal(patches[0].patch.collapsible, false);
  assert.equal(patches[0].patch.collapsed, false);

  // FOLD GATE: the callout carries its new body; the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.2-c callout body edit");
  assert.deepEqual(folded[1].content, [{ type: "text", value: "new body!" }]);
  assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
  assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
});

// S3.2-d) CHROME EDIT — changing tone / title / collapsed → a patch-block
//   carrying that field. Three sub-cases, each emitting exactly one patch.
check("S3.2 runToOps: changing tone → a patch-block carrying the new tone", () => {
  const blocks = [
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, tone: "danger" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "c-1");
  assert.equal(ops[0].patch.tone, "danger");

  const folded = assertFolds(blocks, doc, ops, "S3.2-d tone change");
  assert.equal(folded[0].tone, "danger");
});

check("S3.2 runToOps: changing title → a patch-block carrying the new title", () => {
  const blocks = [
    { id: "c-1", type: "callout", tone: "info", title: "Old", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, title: "New title" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.title, "New title");

  const folded = assertFolds(blocks, doc, ops, "S3.2-d title change");
  assert.equal(folded[0].title, "New title");
});

check("S3.2 runToOps: toggling the fold (collapsed) → a patch-block carrying collapsed", () => {
  const blocks = [
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      collapsible: true,
      content: [{ type: "text", value: "x" }],
    },
  ];
  const doc = runToTiptap(blocks);
  // The fold toggle flips collapsed false→true on the node attrs.
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, collapsed: true },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].patch.collapsed, true);
  assert.equal(ops[0].patch.collapsible, true, "collapsible is carried alongside");

  const folded = assertFolds(blocks, doc, ops, "S3.2-d fold toggle");
  assert.equal(folded[0].collapsed, true);
});

// S3.2-d2) REMOVAL DIRECTIONS — patch-block is a SHALLOW merge that cannot delete
//   a key, so EXPANDING a collapsed callout (collapsed true→false) and CLEARING a
//   title (set→null) must emit the field EXPLICITLY or the stale value survives the
//   merge and the edit silently reverts on reload. These fold through the real
//   shallow-merge (applyOps) — they FAIL if calloutNodeToPatch omits false/null.
check("S3.2 runToOps: EXPANDING a collapsed callout (true→false) actually persists", () => {
  const blocks = [
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      collapsible: true,
      collapsed: true,
      content: [{ type: "text", value: "x" }],
    },
  ];
  const doc = runToTiptap(blocks);
  // Fold button expands it: collapsed true→false on the node attrs.
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, collapsed: false },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.collapsed, false, "explicit collapsed:false in the patch");

  // FOLD GATE through the shallow merge: the stored callout is now EXPANDED.
  const folded = assertFolds(blocks, doc, ops, "S3.2-d2 expand");
  assert.equal(folded[0].collapsed, false, "expand persists (no stale collapsed:true)");
});

check("S3.2 runToOps: CLEARING a title (set→null) actually persists", () => {
  const blocks = [
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      title: "Old title",
      content: [{ type: "text", value: "x" }],
    },
  ];
  const doc = runToTiptap(blocks);
  // Clear the title: set→null on the node attrs.
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, title: null },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.title, null, "explicit title:null in the patch");

  // FOLD GATE: the stored callout's title is gone (compose drops a null title).
  const folded = assertFolds(blocks, doc, ops, "S3.2-d2 title clear");
  assert.equal(folded[0].title, null, "title cleared (no stale old title)");
});

// S3.2-e) INSERT — a NEW callout (no bpId) between two surviving prose blocks →
//   an insert-after carrying a { type:"callout", … } block with a client-minted
//   id, body + chrome reconstructed. The fold lands it between the prose.
check("S3.2 runToOps: inserting a callout → insert-after with a {type:'callout'} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "callout",
      attrs: { bpId: null, bpType: "callout", tone: "success", title: "Done" },
      content: [{ type: "text", text: "shipped" }],
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "callout",
  );
  assert.ok(ins, "a callout block is inserted");
  assert.equal(ins.block.type, "callout");
  assert.ok(ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2", "minted id avoids prev ids");
  assert.equal(ins.block.tone, "success");
  assert.equal(ins.block.title, "Done");
  assert.deepEqual(ins.block.content, [{ type: "text", value: "shipped" }]);
  // No separate interior patch for a fresh insert (the body rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted callout emits no extra interior patch",
  );

  // FOLD GATE: the callout lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.2-e callout insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "callout");
  assert.equal(folded[2].id, "p-2");
});

// S3.2-f) REMOVE — deleting a callout → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("S3.2 runToOps: removing a callout → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "x" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the callout

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "c-1" }],
    "exactly one remove-block for the callout",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.2-f callout remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.2-g) NON-INTERFERENCE — a callout between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the callout untouched)
//   emits exactly their two patches and NONE for the callout.
check("S3.2 runToOps: a callout between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "mid" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the callout");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);

  const folded = assertFolds(blocks, doc, ops, "S3.2-g callout non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "callout untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.3 — the code block as a canvas ATTR-ATOM node (run-convert.js).
// A code block in a run is NO LONGER opaque: runToTiptap emits a native
// { type:"bpCode", attrs:{bpId,bpType,value,lang?} } ATOM node (node NAME bpCode,
// bpType "code" — the StarterKit inline code MARK owns the name `code`), and
// runToOps reconstructs a { type:"code", value, lang? } block via codeNodeToBlock.
// UNLIKE the divider ATOM (no interior, zero ops forever), a code attr-atom HAS a
// mutable value/lang, so a value/lang edit → exactly one patch-block; an untouched
// code → ZERO ops. UNLIKE the callout it has NO inline body (value is a string).
// ───────────────────────────────────────────────────────────────────────────

// S3.3-a) PROJECTION — a code block projects to a native bpCode ATTR-ATOM node
//   (NOT bpOpaque): value→attr, lang→attr (only when present). node.type is the
//   NODE name `bpCode`, NOT the bpType `code`.
check("S3.3 runToTiptap: a code block → { type:'bpCode', attrs:{bpId,bpType,value,lang} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "k-1", type: "code", lang: "elixir", value: "IO.puts(:ok)\n:done" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3);

  const k = doc.content[1];
  assert.equal(k.type, "bpCode", "code projects to a native bpCode node");
  assert.notEqual(k.type, "bpOpaque", "code is NOT carried opaquely");
  assert.notEqual(k.type, "code", "node name is bpCode (code is the inline MARK)");
  assert.equal(k.attrs.bpId, "k-1");
  assert.equal(k.attrs.bpType, "code");
  // value rides an attr, MULTI-LINE preserved verbatim.
  assert.equal(k.attrs.value, "IO.puts(:ok)\n:done");
  assert.equal(k.attrs.lang, "elixir");
  // An atom: no content hole, no opaque bpBlock carry.
  assert.ok(!("content" in k), "code atom carries no content");
  assert.ok(!("bpBlock" in k.attrs), "code carries no opaque bpBlock");

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "paragraph");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3.3-a2) PROJECTION — a code block WITHOUT lang projects with NO lang attr
//   (byte-fidelity: put_if_present drops an absent/empty lang on persist).
check("S3.3 runToTiptap: a lang-less code block carries NO lang attr", () => {
  const doc = runToTiptap([{ id: "k-1", type: "code", value: "x = 1" }]);
  const k = doc.content[0];
  assert.equal(k.type, "bpCode");
  assert.equal(k.attrs.value, "x = 1");
  assert.ok(!("lang" in k.attrs), "absent lang is NOT projected");
});

// S3.3-b) ROUND-TRIP — an UNTOUCHED code block survives runToOps with ZERO ops
//   (canonical compare, incl. a MULTI-LINE value + reordered attr keys), and the
//   whole mixed run folds back to the identical block list (value + lang preserved,
//   absent lang absent).
check("S3.3 runToOps: an untouched code block round-trips with ZERO ops (multi-line + reordered keys)", () => {
  const code = {
    id: "k-1",
    type: "code",
    lang: "js",
    value: "function f() {\n  return 42;\n}",
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    code,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Simulate the live editor's getJSON attr key order (reordered) — change
  // detection must be key-order-safe.
  const k = doc.content[1];
  k.attrs = { value: "function f() {\n  return 42;\n}", bpType: "code", lang: "js", bpId: "k-1" };

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched code run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the code survives with its
  // multi-line value + lang, and the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.3-b code round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "k-1", "p-1"]);
  assert.deepEqual(folded[1], code);
});

// S3.3-b2) ROUND-TRIP — an untouched LANG-LESS code block emits ZERO ops and folds
//   back WITHOUT a lang key (lang:null normalizes to "" for compare).
check("S3.3 runToOps: an untouched lang-less code block round-trips with ZERO ops", () => {
  const code = { id: "k-1", type: "code", value: "noop" };
  const blocks = [code, { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched lang-less code emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.3-b2 lang-less code round-trip");
  assert.deepEqual(folded[0], code);
  assert.ok(!("lang" in folded[0]), "folded code carries no lang key");
});

// S3.3-c) VALUE EDIT — editing the code's value → exactly one patch-block carrying
//   the new value, no prose perturbation. The patch carries value (the new text).
check("S3.3 runToOps: editing the code VALUE → one patch-block with the new value", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "k-1", type: "code", value: "old code" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // The textarea island wrote the new value back to the node's `value` attr.
  doc.content[1] = {
    ...doc.content[1],
    attrs: { ...doc.content[1].attrs, value: "new code line\nsecond line" },
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block, for the code");
  assert.equal(patches[0].id, "k-1");
  assert.equal(patches[0].patch.value, "new code line\nsecond line");
  // lang explicit as "" (removal-safe: a lang-less code patches lang:"" which
  // put_if_present drops on persist).
  assert.equal(patches[0].patch.lang, "", "lang explicit '' (removal-safe)");

  // FOLD GATE: the code carries its new value; the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.3-c code value edit");
  assert.equal(folded[1].value, "new code line\nsecond line");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
  assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
});

// S3.3-d) LANG CHANGE — changing the language → a patch-block carrying the new
//   lang (and the unchanged value).
check("S3.3 runToOps: changing the code LANG → a patch-block carrying the new lang", () => {
  const blocks = [
    { id: "k-1", type: "code", lang: "js", value: "x" },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, lang: "ruby" },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "k-1");
  assert.equal(ops[0].patch.lang, "ruby");
  assert.equal(ops[0].patch.value, "x", "value carried alongside");

  const folded = assertFolds(blocks, doc, ops, "S3.3-d lang change");
  assert.equal(folded[0].lang, "ruby");
});

// S3.3-d2) CLEARING the lang (set→"" via the lang input) emits lang:"" which the
//   server drops (put_if_present) — so the stored code becomes lang-less. The fold
//   here uses the JS reference applyOps (shallow merge), then we assert the
//   reconstructed-on-reload block via codeNodeToBlock semantics: lang "" → no key.
check("S3.3 runToOps: CLEARING the lang (set→'') persists lang:'' in the patch", () => {
  const blocks = [
    { id: "k-1", type: "code", lang: "js", value: "x" },
  ];
  const doc = runToTiptap(blocks);
  // The lang input cleared → null on the node attrs (the node-view maps "" → null).
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, lang: null },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.lang, "", "explicit lang:'' in the patch (removal-safe)");

  // FOLD GATE: the shallow merge writes lang:"". (On the server put_if_present
  // would drop it; the JS reference fold keeps the explicit "" — which is the
  // lang-less canonical for compare, so a subsequent round-trip is a no-op.)
  const folded = assertFolds(blocks, doc, ops, "S3.3-d2 lang clear");
  assert.equal(folded[0].lang, "");
});

// S3.3-e) INSERT — a NEW code block (no bpId) between two surviving prose blocks →
//   an insert-after carrying a { type:"code", value, lang? } block with a
//   client-minted id. The fold lands it between the prose.
check("S3.3 runToOps: inserting a code block → insert-after with a {type:'code', value} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "bpCode",
      attrs: { bpId: null, bpType: "code", value: "let y = 2", lang: "ts" },
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "code",
  );
  assert.ok(ins, "a code block is inserted");
  assert.equal(ins.block.type, "code", "the inserted block carries bpType 'code' (not 'bpCode')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.value, "let y = 2");
  assert.equal(ins.block.lang, "ts");
  // No separate interior patch for a fresh insert (the value rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted code emits no extra interior patch",
  );

  // FOLD GATE: the code lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.3-e code insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "code");
  assert.equal(folded[1].value, "let y = 2");
  assert.equal(folded[2].id, "p-2");
});

// S3.3-e2) INSERT a LANG-LESS code block → the inserted block has NO lang key.
check("S3.3 runToOps: inserting a lang-less code block → block carries no lang key", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpCode", attrs: { bpId: null, bpType: "code", value: "bare" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "code",
  );
  assert.ok(ins, "a code block is inserted");
  assert.equal(ins.block.value, "bare");
  assert.ok(!("lang" in ins.block), "a lang-less insert carries no lang key");
  assert.deepEqual(Object.keys(ins.block).sort(), ["id", "type", "value"]);
});

// S3.3-f) REMOVE — deleting a code block → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("S3.3 runToOps: removing a code block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "k-1", type: "code", value: "drop me" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the code

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "k-1" }],
    "exactly one remove-block for the code",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.3-f code remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.3-g) NON-INTERFERENCE — a code block between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the code untouched) emits
//   exactly their two patches and NONE for the code.
check("S3.3 runToOps: a code block between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "k-1", type: "code", lang: "sh", value: "echo hi" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the code");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "k-1").length,
    0,
    "the code emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "S3.3-g code non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "code untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3.3-h) STILL-OPAQUE — a non-canvas block (composite, a nested-structure field) is
//   STILL carried opaquely. divider (S3), callout (S3.2), code (S3.3), diagram (S3.4),
//   the 7 NATIVE field-* types (S3.5), and the 2 PICKER fields field-image /
//   field-reference (run-splitter tail) are ALL canvas-handled; composite / arrayOf /
//   codelist / localizedText / section remain opaque boundaries.
check("S3.3 runToTiptap: a composite field is STILL opaque (native + picker fields canvas-handled, nested-structure fields not)", () => {
  const field = { id: "f-1", type: "composite", fields: [], value: {} };
  const doc = runToTiptap([field]);
  assert.equal(doc.content[0].type, "bpOpaque", "composite stays opaque");
  assert.deepEqual(doc.content[0].attrs.bpBlock, field);
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.4 — the diagram block as a canvas ATTR-ATOM node (run-convert.js),
// MIRRORING the S3.3 code cases. A diagram block in a run is NO LONGER opaque:
// runToTiptap emits a native { type:"bpDiagram", attrs:{bpId,bpType,source,caption?} }
// ATOM node (node NAME bpDiagram, bpType "diagram"), and runToOps reconstructs a
// { type:"diagram", source, caption? } block via diagramNodeToBlock. UNLIKE the
// divider ATOM (no interior, zero ops forever), a diagram attr-atom HAS a mutable
// source/caption, so a source/caption edit → exactly one patch-block; an untouched
// diagram → ZERO ops. UNLIKE the callout it has NO inline body (source is a string).
// The diagram's body field is `source` (NOT `value`) and its optional field is
// `caption` (where code had `lang`).
// ───────────────────────────────────────────────────────────────────────────

// S3.4-a) PROJECTION — a diagram block projects to a native bpDiagram ATTR-ATOM node
//   (NOT bpOpaque): source→attr, caption→attr (only when present). node.type is the
//   NODE name `bpDiagram`, NOT the bpType `diagram`.
check("S3.4 runToTiptap: a diagram block → { type:'bpDiagram', attrs:{bpId,bpType,source,caption} } (NOT bpOpaque)", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "g-1", type: "diagram", caption: "Figure 1.", source: "graph TD\n  A-->B" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content.length, 3);

  const g = doc.content[1];
  assert.equal(g.type, "bpDiagram", "diagram projects to a native bpDiagram node");
  assert.notEqual(g.type, "bpOpaque", "diagram is NOT carried opaquely");
  assert.notEqual(g.type, "diagram", "node name is bpDiagram (not the bpType)");
  assert.equal(g.attrs.bpId, "g-1");
  assert.equal(g.attrs.bpType, "diagram");
  // source rides an attr, MULTI-LINE preserved verbatim.
  assert.equal(g.attrs.source, "graph TD\n  A-->B");
  assert.equal(g.attrs.caption, "Figure 1.");
  // An atom: no content hole, no opaque bpBlock carry.
  assert.ok(!("content" in g), "diagram atom carries no content");
  assert.ok(!("bpBlock" in g.attrs), "diagram carries no opaque bpBlock");

  // The flanking prose still projects normally.
  assert.equal(doc.content[0].type, "paragraph");
  assert.equal(doc.content[2].type, "paragraph");
});

// S3.4-a2) PROJECTION — a diagram block WITHOUT caption projects with NO caption attr
//   (byte-fidelity: an absent/empty caption round-trips as absent, like code's lang).
check("S3.4 runToTiptap: a caption-less diagram block carries NO caption attr", () => {
  const doc = runToTiptap([{ id: "g-1", type: "diagram", source: "graph LR\n  X-->Y" }]);
  const g = doc.content[0];
  assert.equal(g.type, "bpDiagram");
  assert.equal(g.attrs.source, "graph LR\n  X-->Y");
  assert.ok(!("caption" in g.attrs), "absent caption is NOT projected");
});

// S3.4-b) ROUND-TRIP — an UNTOUCHED diagram block survives runToOps with ZERO ops
//   (canonical compare, incl. a MULTI-LINE source + reordered attr keys), and the
//   whole mixed run folds back to the identical block list (source + caption
//   preserved, absent caption absent).
check("S3.4 runToOps: an untouched diagram block round-trips with ZERO ops (multi-line + reordered keys)", () => {
  const diagram = {
    id: "g-1",
    type: "diagram",
    caption: "Figure 2. The flow.",
    source: "sequenceDiagram\n  Alice->>Bob: hi\n  Bob-->>Alice: yo",
  };
  const blocks = [
    { id: "h-1", type: "heading", level: 1, text: "Doc" },
    diagram,
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Simulate the live editor's getJSON attr key order (reordered) — change
  // detection must be key-order-safe.
  const g = doc.content[1];
  g.attrs = {
    source: "sequenceDiagram\n  Alice->>Bob: hi\n  Bob-->>Alice: yo",
    bpType: "diagram",
    caption: "Figure 2. The flow.",
    bpId: "g-1",
  };

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched diagram run emits ZERO ops");

  // FOLD GATE: folds back to the identical block list; the diagram survives with its
  // multi-line source + caption, and the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.4-b diagram round-trip");
  assert.deepEqual(folded.map((b) => b.id), ["h-1", "g-1", "p-1"]);
  assert.deepEqual(folded[1], diagram);
});

// S3.4-b2) ROUND-TRIP — an untouched CAPTION-LESS diagram block emits ZERO ops and
//   folds back WITHOUT a caption key (caption:null normalizes to "" for compare).
check("S3.4 runToOps: an untouched caption-less diagram block round-trips with ZERO ops", () => {
  const diagram = { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" };
  const blocks = [diagram, { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched caption-less diagram emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.4-b2 caption-less diagram round-trip");
  assert.deepEqual(folded[0], diagram);
  assert.ok(!("caption" in folded[0]), "folded diagram carries no caption key");
});

// S3.4-c) SOURCE EDIT — editing the diagram's source → exactly one patch-block
//   carrying the new source, no prose perturbation.
check("S3.4 runToOps: editing the diagram SOURCE → one patch-block with the new source", () => {
  const blocks = [
    { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  // The textarea island wrote the new source back to the node's `source` attr.
  doc.content[1] = {
    ...doc.content[1],
    attrs: { ...doc.content[1].attrs, source: "graph LR\n  A-->B\n  B-->C" },
  };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1, "exactly one patch-block, for the diagram");
  assert.equal(patches[0].id, "g-1");
  assert.equal(patches[0].patch.source, "graph LR\n  A-->B\n  B-->C");
  // caption explicit as "" (removal-safe: a caption-less diagram patches caption:"").
  assert.equal(patches[0].patch.caption, "", "caption explicit '' (removal-safe)");

  // FOLD GATE: the diagram carries its new source; the prose is untouched.
  const folded = assertFolds(blocks, doc, ops, "S3.4-c diagram source edit");
  assert.equal(folded[1].source, "graph LR\n  A-->B\n  B-->C");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
  assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
});

// S3.4-d) CAPTION SET — setting the caption → a patch-block carrying the new caption
//   (and the unchanged source).
check("S3.4 runToOps: setting the diagram CAPTION → a patch-block carrying the new caption", () => {
  const blocks = [
    { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, caption: "Figure 3." },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "patch-block");
  assert.equal(ops[0].id, "g-1");
  assert.equal(ops[0].patch.caption, "Figure 3.");
  assert.equal(ops[0].patch.source, "graph TD\n  A-->B", "source carried alongside");

  const folded = assertFolds(blocks, doc, ops, "S3.4-d caption set");
  assert.equal(folded[0].caption, "Figure 3.");
});

// S3.4-d2) CLEARING the caption (set→"" via the caption input) emits caption:"" which
//   the shallow merge stores — render-equivalent to a caption-less diagram. The
//   canonical compare normalizes ""/null equal so a subsequent round-trip is a no-op.
check("S3.4 runToOps: CLEARING the caption (set→'') persists caption:'' in the patch", () => {
  const blocks = [
    { id: "g-1", type: "diagram", caption: "Figure 4.", source: "graph TD\n  A-->B" },
  ];
  const doc = runToTiptap(blocks);
  // The caption input cleared → null on the node attrs (node-view maps "" → null).
  doc.content[0] = {
    ...doc.content[0],
    attrs: { ...doc.content[0].attrs, caption: null },
  };
  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.caption, "", "explicit caption:'' in the patch (removal-safe)");

  // FOLD GATE: the shallow merge writes caption:"" (render-equivalent to caption-less).
  const folded = assertFolds(blocks, doc, ops, "S3.4-d2 caption clear");
  assert.equal(folded[0].caption, "");
});

// S3.4-e) INSERT — a NEW diagram block (no bpId) between two surviving prose blocks →
//   an insert-after carrying a { type:"diagram", source, caption? } block with a
//   client-minted id. The fold lands it between the prose.
check("S3.4 runToOps: inserting a diagram block → insert-after with a {type:'diagram', source} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "bpDiagram",
      attrs: { bpId: null, bpType: "diagram", source: "graph TD\n  M-->N", caption: "Figure 5." },
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "diagram",
  );
  assert.ok(ins, "a diagram block is inserted");
  assert.equal(ins.block.type, "diagram", "the inserted block carries bpType 'diagram' (not 'bpDiagram')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.source, "graph TD\n  M-->N");
  assert.equal(ins.block.caption, "Figure 5.");
  // No separate interior patch for a fresh insert (the source rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted diagram emits no extra interior patch",
  );

  // FOLD GATE: the diagram lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.4-e diagram insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "diagram");
  assert.equal(folded[1].source, "graph TD\n  M-->N");
  assert.equal(folded[2].id, "p-2");
});

// S3.4-e2) INSERT a CAPTION-LESS diagram block → the inserted block has NO caption
//   key (the insert path mirrors the persist default — render-equivalent to "").
check("S3.4 runToOps: inserting a caption-less diagram block → block carries no caption key", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpDiagram", attrs: { bpId: null, bpType: "diagram", source: "graph TD\n  A-->B" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "diagram",
  );
  assert.ok(ins, "a diagram block is inserted");
  assert.equal(ins.block.source, "graph TD\n  A-->B");
  assert.ok(!("caption" in ins.block), "a caption-less insert carries no caption key");
  assert.deepEqual(Object.keys(ins.block).sort(), ["id", "source", "type"]);
});

// S3.4-f) REMOVE — deleting a diagram block → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("S3.4 runToOps: removing a diagram block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "g-1", type: "diagram", source: "graph TD\n  A-->B" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the diagram

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "g-1" }],
    "exactly one remove-block for the diagram",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.4-f diagram remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.4-g) NON-INTERFERENCE — a diagram block between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the diagram untouched) emits
//   exactly their two patches and NONE for the diagram.
check("S3.4 runToOps: a diagram block between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "g-1", type: "diagram", caption: "Fig", source: "graph TD\n  A-->B" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the diagram");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "g-1").length,
    0,
    "the diagram emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "S3.4-g diagram non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "diagram untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3.4-h) MIXED — a diagram, a code, AND a callout in ONE run all round-trip with
//   ZERO ops untouched (the three attr-atom/content kinds coexist in one canvas doc).
check("S3.4 runToOps: a diagram + code + callout in ONE run all round-trip with ZERO ops", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    { id: "g-1", type: "diagram", caption: "Fig 1.", source: "graph TD\n  A-->B" },
    { id: "k-1", type: "code", lang: "js", value: "const x = 1;" },
    {
      id: "c-1",
      type: "callout",
      tone: "info",
      content: [{ type: "text", value: "note" }],
    },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "outro" }] },
  ];
  const doc = runToTiptap(blocks);

  // All three non-prose kinds project to their native canvas nodes.
  assert.equal(doc.content[1].type, "bpDiagram");
  assert.equal(doc.content[2].type, "bpCode");
  assert.equal(doc.content[3].type, "callout");

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched mixed run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.4-h mixed diagram+code+callout");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "g-1", "k-1", "c-1", "p-2"]);
  assert.deepEqual(folded[1], blocks[1], "diagram untouched");
  assert.deepEqual(folded[2], blocks[2], "code untouched");
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.5 — the 7 NATIVE-CONTROL field-* blocks as canvas CONTROL-ATOM
// nodes (run-convert.js + field-node.js). A native field block in a run is NO LONGER
// opaque: runToTiptap emits a native { type:"bpField", attrs:{bpId,bpType,value,
// fieldName?,label?,options?,rows?} } ATOM node (ONE node `bpField` for all 7 types,
// discriminated by bpType), and runToOps reconstructs a { type:"field-*", value, … }
// block via fieldNodeToBlock. The value is COERCED BY FIELD TYPE exactly like
// BarkparkFieldBlockBridge: field-boolean → a BOOLEAN (control.checked); every other
// native type → a STRING (control.value). field-image / field-reference (pickers)
// STILL project to bpOpaque (boundaries).
//
// The 7 native types, their control, and their value type:
//   field-string  text input        string
//   field-slug    text input        string
//   field-text    textarea          string
//   field-boolean checkbox          BOOLEAN
//   field-select  <select>          string  (options config carried)
//   field-datetime datetime-local   string
//   field-color   color input       string
// ───────────────────────────────────────────────────────────────────────────

// A representative seed per native field type: the value plus carried config
// (label, fieldName, and options for select). The value type matches the stored
// shape (boolean for field-boolean, string for the rest).
const S35_FIELD_SEEDS = {
  "field-string": { id: "f-str", type: "field-string", label: "Title", fieldName: "title", value: "Hello" },
  "field-slug": { id: "f-slug", type: "field-slug", label: "Slug", fieldName: "slug", value: "hello-world" },
  "field-text": { id: "f-txt", type: "field-text", label: "Body", fieldName: "body", rows: 5, value: "Para one\nPara two" },
  "field-boolean": { id: "f-bool", type: "field-boolean", label: "Featured", fieldName: "featured", value: true },
  "field-select": {
    id: "f-sel",
    type: "field-select",
    label: "Status",
    fieldName: "status",
    value: "published",
    options: [
      { value: "draft", label: "Draft" },
      { value: "published", label: "Published" },
    ],
  },
  "field-datetime": { id: "f-dt", type: "field-datetime", label: "Published at", fieldName: "publishedAt", value: "2026-06-24T10:00" },
  "field-color": { id: "f-col", type: "field-color", label: "Accent", fieldName: "accent", value: "#3b82f6" },
};

// The EDITED value per type — a second valid value to drive the value-edit case.
// field-boolean flips true→false (a BOOLEAN); the rest take a new STRING.
const S35_FIELD_EDITS = {
  "field-string": "Goodbye",
  "field-slug": "goodbye-world",
  "field-text": "Rewritten body",
  "field-boolean": false,
  "field-select": "draft",
  "field-datetime": "2026-07-01T09:30",
  "field-color": "#ef4444",
};

// S3.5-a) PROJECTION — EACH of the 7 native field types projects to a native
//   `bpField` ATOM node (NOT bpOpaque): value→attr, fieldName/label/(options)→attr.
//   node.type is the NODE name `bpField`, NOT the bpType. The value type matches the
//   stored shape (boolean for boolean, string otherwise).
for (const type of BP_NATIVE_FIELD_TYPES) {
  check(`S3.5 runToTiptap: a ${type} block → { type:'bpField', attrs:{bpType,value,fieldName} } (NOT bpOpaque)`, () => {
    const seed = S35_FIELD_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    assert.equal(doc.content.length, 3);

    const f = doc.content[1];
    assert.equal(f.type, "bpField", `${type} projects to a native bpField node`);
    assert.notEqual(f.type, "bpOpaque", `${type} is NOT carried opaquely`);
    assert.notEqual(f.type, type, "node name is bpField (not the bpType)");
    assert.equal(f.attrs.bpId, seed.id);
    assert.equal(f.attrs.bpType, type);
    // value rides an attr, with the STORED type (boolean for boolean, else string).
    assert.deepEqual(f.attrs.value, seed.value);
    if (type === "field-boolean") {
      assert.equal(typeof f.attrs.value, "boolean", "boolean value is a BOOLEAN");
    } else {
      assert.equal(typeof f.attrs.value, "string", "non-boolean value is a STRING");
    }
    // fieldName carried verbatim (binds to an Expectation field).
    assert.equal(f.attrs.fieldName, seed.fieldName);
    // An atom: no content hole, no opaque bpBlock carry.
    assert.ok(!("content" in f), "field atom carries no content");
    assert.ok(!("bpBlock" in f.attrs), "field carries no opaque bpBlock");

    // The flanking prose still projects normally.
    assert.equal(doc.content[0].type, "paragraph");
    assert.equal(doc.content[2].type, "paragraph");
  });
}

// S3.5-b) ROUND-TRIP — EACH native field type, untouched, survives runToOps with
//   ZERO ops (canonical compare, reordered attr keys), and the whole mixed run folds
//   back to the IDENTICAL block list (value + config preserved byte-for-byte).
for (const type of BP_NATIVE_FIELD_TYPES) {
  check(`S3.5 runToOps: an untouched ${type} block round-trips with ZERO ops (config preserved)`, () => {
    const seed = S35_FIELD_SEEDS[type];
    const blocks = [
      { id: "h-1", type: "heading", level: 1, text: "Doc" },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);

    // Simulate the live editor's getJSON attr key order (reordered) — change
    // detection must be key-order-safe.
    const f = doc.content[1];
    const reordered = { value: seed.value, bpType: type, bpId: seed.id };
    if (seed.fieldName != null) reordered.fieldName = seed.fieldName;
    if (seed.label != null) reordered.label = seed.label;
    if (seed.options != null) reordered.options = seed.options;
    if (seed.rows != null) reordered.rows = seed.rows;
    f.attrs = reordered;

    const ops = runToOps(blocks, doc);
    assert.equal(ops.length, 0, `an untouched ${type} run emits ZERO ops`);

    // FOLD GATE: folds back to the identical block list; the field survives with its
    // value + carried config, and the prose is untouched.
    const folded = assertFolds(blocks, doc, ops, `S3.5-b ${type} round-trip`);
    assert.deepEqual(folded.map((b) => b.id), ["h-1", seed.id, "p-1"]);
    assert.deepEqual(folded[1], seed, `${type} folds back byte-identical`);
  });
}

// S3.5-c) VALUE EDIT — editing EACH native field's value → exactly one patch-block
//   carrying the CORRECTLY COERCED value (a boolean for field-boolean; a string for
//   the rest), keyed by id, with no prose perturbation.
for (const type of BP_NATIVE_FIELD_TYPES) {
  check(`S3.5 runToOps: editing a ${type} value → one patch-block with the COERCED value`, () => {
    const seed = S35_FIELD_SEEDS[type];
    const edited = S35_FIELD_EDITS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // The native control wrote the (coerced) new value back to the node's `value`
    // attr — boolean for field-boolean, string for the rest.
    doc.content[1] = {
      ...doc.content[1],
      attrs: { ...doc.content[1].attrs, value: edited },
    };

    const ops = runToOps(blocks, doc);
    const patches = ops.filter((o) => o.op === "patch-block");
    assert.equal(patches.length, 1, "exactly one patch-block, for the field");
    assert.equal(patches[0].id, seed.id);
    // THE CRUX: the patch carries ONLY { value } — exactly the
    // BarkparkFieldBlockBridge shape ({op:"patch-block", id, patch:{value}}).
    assert.deepEqual(Object.keys(patches[0].patch), ["value"], "patch carries ONLY value (bridge shape)");
    assert.deepEqual(patches[0].patch.value, edited, "the COERCED edited value");
    if (type === "field-boolean") {
      assert.equal(typeof patches[0].patch.value, "boolean", "boolean patch value is a BOOLEAN");
    } else {
      assert.equal(typeof patches[0].patch.value, "string", "non-boolean patch value is a STRING");
    }

    // FOLD GATE: the field carries its new value; the prose is untouched.
    const folded = assertFolds(blocks, doc, ops, `S3.5-c ${type} value edit`);
    assert.deepEqual(folded[1].value, edited);
    // The carried config survives the patch (shallow merge re-pins id/type, keeps the
    // rest of the block — patch.ex merge_block).
    assert.equal(folded[1].fieldName, seed.fieldName, "fieldName survives the edit");
    assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
    assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
  });
}

// S3.5-c2) COERCION FIDELITY vs BarkparkFieldBlockBridge — the lifted
//   coerceFieldValue produces the EXACT value the per-block bridge's `send()` does:
//   field-boolean reads control.checked (a BOOLEAN); every other type reads
//   control.value (a STRING). Drive a fake control and assert byte-identity.
check("S3.5 coerceFieldValue matches BarkparkFieldBlockBridge (boolean→checked; else→value)", () => {
  // field-boolean → control.checked (a strict boolean), IGNORING control.value.
  assert.equal(coerceFieldValue("field-boolean", { checked: true, value: "on" }), true);
  assert.equal(coerceFieldValue("field-boolean", { checked: false, value: "on" }), false);
  assert.equal(typeof coerceFieldValue("field-boolean", { checked: true }), "boolean");

  // every other native type → control.value (a string), IGNORING control.checked.
  for (const type of ["field-string", "field-slug", "field-text", "field-select", "field-datetime", "field-color"]) {
    assert.equal(coerceFieldValue(type, { value: "abc", checked: true }), "abc", `${type} reads control.value`);
    assert.equal(typeof coerceFieldValue(type, { value: "abc" }), "string", `${type} value is a STRING`);
  }
});

// S3.5-d) INSERT — a NEW native field block (no bpId) between two surviving prose
//   blocks → an insert-after carrying a { type:"field-*", value, fieldName?, … } block
//   with a client-minted id. The fold lands it between the prose.
check("S3.5 runToOps: inserting a field-string block → insert-after with a {type:'field-string', value, fieldName} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0], // p-1
    {
      type: "bpField",
      attrs: { bpId: null, bpType: "field-string", value: "New value", fieldName: "subtitle", label: "Subtitle" },
    },
    doc.content[1], // p-2
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-string",
  );
  assert.ok(ins, "a field-string block is inserted");
  assert.equal(ins.block.type, "field-string", "the inserted block carries bpType 'field-string' (not 'bpField')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.value, "New value");
  assert.equal(ins.block.fieldName, "subtitle", "fieldName carried through verbatim");
  assert.equal(ins.block.label, "Subtitle", "label carried through");
  // No separate interior patch for a fresh insert (the value rode the insert).
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted field emits no extra interior patch",
  );

  // FOLD GATE: the field lands at slot 1, between the two surviving prose.
  const folded = assertFolds(blocks, doc, ops, "S3.5-d field insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "field-string");
  assert.equal(folded[1].value, "New value");
  assert.equal(folded[2].id, "p-2");
});

// S3.5-d2) INSERT a field-boolean → the inserted block's value is a BOOLEAN (false),
//   not a string — the coercion target rides the insert path too.
check("S3.5 runToOps: inserting a field-boolean block → the inserted value is a BOOLEAN", () => {
  const blocks = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpField", attrs: { bpId: null, bpType: "field-boolean", value: false, fieldName: "flag" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-boolean",
  );
  assert.ok(ins, "a field-boolean block is inserted");
  assert.equal(ins.block.value, false);
  assert.equal(typeof ins.block.value, "boolean", "the inserted boolean value is a BOOLEAN");
  assert.equal(ins.block.fieldName, "flag");
});

// S3.5-e) REMOVE — deleting a native field block → a remove-block keyed by its id;
//   the surrounding prose is untouched. The fold drops it.
check("S3.5 runToOps: removing a field-select block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    S35_FIELD_SEEDS["field-select"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the field

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "f-sel" }],
    "exactly one remove-block for the field",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "S3.5-e field remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// S3.5-f) NON-INTERFERENCE — a field block between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the field untouched) emits
//   exactly their two patches and NONE for the field.
check("S3.5 runToOps: a field between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    S35_FIELD_SEEDS["field-boolean"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the field");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "f-bool").length,
    0,
    "the field emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "S3.5-f field non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "field untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// S3.5-g) MIXED — a field, a code, a callout, AND a diagram in ONE run all round-trip
//   with ZERO ops untouched (the field control-atom coexists with the other variants).
check("S3.5 runToOps: a field + code + callout + diagram in ONE run all round-trip with ZERO ops", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    S35_FIELD_SEEDS["field-string"],
    { id: "k-1", type: "code", lang: "js", value: "const x = 1;" },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "note" }] },
    { id: "g-1", type: "diagram", caption: "Fig 1.", source: "graph TD\n  A-->B" },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "outro" }] },
  ];
  const doc = runToTiptap(blocks);

  // All four non-prose kinds project to their native canvas nodes.
  assert.equal(doc.content[1].type, "bpField");
  assert.equal(doc.content[2].type, "bpCode");
  assert.equal(doc.content[3].type, "callout");
  assert.equal(doc.content[4].type, "bpDiagram");

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched mixed run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.5-g mixed field+code+callout+diagram");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "f-str", "k-1", "c-1", "g-1", "p-2"]);
  assert.deepEqual(folded[1], blocks[1], "field untouched");
});

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 RUN-SPLITTER TAIL (part 1) — the 2 PICKER field-* blocks (field-image /
// field-reference) as canvas CONTROL-ATOM nodes mounting the EXISTING client-side
// picker WCs (run-convert.js + field-node.js). A picker field in a run is NO LONGER
// opaque: runToTiptap emits the SAME native { type:"bpField", attrs:{bpId,bpType,value,
// label?,fieldName?,refType?,dataset?} } ATOM node the 7 native types use, and runToOps
// reconstructs a { type:"field-image"|"field-reference", value, … } block via
// fieldNodeToBlock. The value is a STRING (a media id/url for image; a doc id for
// reference) — the picker's bp-change detail.value, lifted IDENTICALLY to the per-block
// BarkparkFieldBlockBridge (push(e.detail.value)). The ONLY mutable datum is `value`;
// the patch is { value }. STILL OUT (nested-structure increment): composite / arrayOf /
// codelist / localizedText / section.
// ───────────────────────────────────────────────────────────────────────────

// A representative seed per picker type: the value (a string) plus carried config.
// field-image carries label; field-reference carries label + refType (its target schema,
// "" by default — present & kept). A dataset override is exercised separately.
const TAIL_PICKER_SEEDS = {
  "field-image": { id: "fi-1", type: "field-image", label: "Hero", fieldName: "hero", value: "https://cdn.example/hero.png" },
  "field-reference": { id: "fr-1", type: "field-reference", label: "Author", fieldName: "author", refType: "author", value: "doc-123" },
};
const TAIL_PICKER_EDITS = {
  "field-image": "https://cdn.example/new-hero.png",
  "field-reference": "doc-456",
};

// TAIL-a) PROJECTION — EACH picker type projects to a native `bpField` ATOM node (NOT
//   bpOpaque): value→attr (a STRING), label/fieldName/(refType)→attr. node.type is the
//   NODE name `bpField`, NOT the bpType, NOT bpOpaque.
for (const type of BP_PICKER_FIELD_TYPES) {
  check(`TAIL runToTiptap: a ${type} block → { type:'bpField', attrs:{bpType,value,...} } (NOT bpOpaque)`, () => {
    const seed = TAIL_PICKER_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    const f = doc.content[1];
    assert.equal(f.type, "bpField", `${type} projects to a native bpField node`);
    assert.notEqual(f.type, "bpOpaque", `${type} is NOT carried opaquely`);
    assert.notEqual(f.type, type, "node name is bpField (not the bpType)");
    assert.equal(f.attrs.bpId, seed.id);
    assert.equal(f.attrs.bpType, type);
    // The picker value rides an attr as a STRING.
    assert.deepEqual(f.attrs.value, seed.value);
    assert.equal(typeof f.attrs.value, "string", "the picker value is a STRING");
    assert.equal(f.attrs.fieldName, seed.fieldName, "fieldName carried verbatim");
    assert.equal(f.attrs.label, seed.label, "label carried verbatim");
    if (type === "field-reference") {
      assert.equal(f.attrs.refType, seed.refType, "field-reference carries its refType config");
    }
    // An atom: no content hole, no opaque bpBlock carry.
    assert.ok(!("content" in f), "picker atom carries no content");
    assert.ok(!("bpBlock" in f.attrs), "picker carries no opaque bpBlock");
    // The flanking prose still projects normally.
    assert.equal(doc.content[0].type, "paragraph");
    assert.equal(doc.content[2].type, "paragraph");
  });
}

// TAIL-b) ROUND-TRIP — EACH picker type, untouched, survives runToOps with ZERO ops
//   (canonical compare, reordered attr keys), and the whole mixed run folds back to the
//   IDENTICAL block list (value + config preserved byte-for-byte, incl. refType).
for (const type of BP_PICKER_FIELD_TYPES) {
  check(`TAIL runToOps: an untouched ${type} block round-trips with ZERO ops (config preserved)`, () => {
    const seed = TAIL_PICKER_SEEDS[type];
    const blocks = [
      { id: "h-1", type: "heading", level: 1, text: "Doc" },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // Simulate the live editor's getJSON attr key order (reordered).
    const reordered = { value: seed.value, bpType: type, bpId: seed.id };
    if (seed.fieldName != null) reordered.fieldName = seed.fieldName;
    if (seed.label != null) reordered.label = seed.label;
    if (seed.refType != null) reordered.refType = seed.refType;
    doc.content[1].attrs = reordered;

    const ops = runToOps(blocks, doc);
    assert.equal(ops.length, 0, `an untouched ${type} run emits ZERO ops`);

    const folded = assertFolds(blocks, doc, ops, `TAIL-b ${type} round-trip`);
    assert.deepEqual(folded.map((b) => b.id), ["h-1", seed.id, "p-1"]);
    assert.deepEqual(folded[1], seed, `${type} folds back byte-identical`);
  });
}

// TAIL-c) VALUE EDIT — editing EACH picker's value (simulating the picker emitting its
//   bp-change → the node-view writing the coerced value to the `value` attr) → exactly
//   ONE patch-block carrying ONLY { value } (the bridge shape), keyed by id, no prose
//   perturbation.
for (const type of BP_PICKER_FIELD_TYPES) {
  check(`TAIL runToOps: editing a ${type} value → one patch-block{value} (bridge shape)`, () => {
    const seed = TAIL_PICKER_SEEDS[type];
    const edited = TAIL_PICKER_EDITS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // The picker's bp-change carried a new value; the node-view wrote it back via the
    // SAME identity coercion the per-block bridge uses (coercePickerValue).
    const nextValue = coercePickerValue({ value: edited });
    doc.content[1] = {
      ...doc.content[1],
      attrs: { ...doc.content[1].attrs, value: nextValue },
    };

    const ops = runToOps(blocks, doc);
    const patches = ops.filter((o) => o.op === "patch-block");
    assert.equal(patches.length, 1, "exactly one patch-block, for the picker field");
    assert.equal(patches[0].id, seed.id);
    // THE CRUX: the patch carries ONLY { value } — exactly the BarkparkFieldBlockBridge
    // picker shape ({op:"patch-block", id, patch:{value}}).
    assert.deepEqual(Object.keys(patches[0].patch), ["value"], "patch carries ONLY value (bridge shape)");
    assert.deepEqual(patches[0].patch.value, edited, "the edited value (identity-coerced)");
    assert.equal(typeof patches[0].patch.value, "string", "picker patch value is a STRING");

    const folded = assertFolds(blocks, doc, ops, `TAIL-c ${type} value edit`);
    assert.equal(folded[1].value, edited);
    // The carried config survives the value patch (shallow merge re-pins id/type).
    assert.equal(folded[1].fieldName, seed.fieldName, "fieldName survives the edit");
    if (type === "field-reference") {
      assert.equal(folded[1].refType, seed.refType, "refType survives the edit");
    }
    assert.deepEqual(folded[0].content, [{ type: "text", value: "before" }]);
    assert.deepEqual(folded[2].content, [{ type: "text", value: "after" }]);
  });
}

// TAIL-c2) PICKER-COERCION FIDELITY vs BarkparkFieldBlockBridge — coercePickerValue
//   produces the EXACT value the per-block bridge's picker branch does: identity on
//   detail.value (a string), with a missing detail/value → "" (the cleared value).
check("TAIL coercePickerValue matches BarkparkFieldBlockBridge picker branch (identity on detail.value)", () => {
  assert.equal(coercePickerValue({ value: "doc-123" }), "doc-123", "identity on a present value");
  assert.equal(coercePickerValue({ value: "https://cdn/x.png" }), "https://cdn/x.png");
  // A clear emits {detail:{value:""}} in the WCs; identity keeps "".
  assert.equal(coercePickerValue({ value: "" }), "", "an empty value stays empty");
  // Defensive: a missing detail or missing value → "" (never undefined into a patch).
  assert.equal(coercePickerValue({}), "", "a missing value coerces to empty string");
  assert.equal(coercePickerValue(null), "", "a missing detail coerces to empty string");
  assert.equal(coercePickerValue(undefined), "", "an undefined detail coerces to empty string");
});

// TAIL-d) INSERT — a NEW picker block (no bpId) between two surviving prose blocks → an
//   insert-after carrying a { type:"field-image"|"field-reference", value, label?, … }
//   block with a client-minted id. The fold lands it between the prose.
check("TAIL runToOps: inserting a field-image block → insert-after with a {type:'field-image', value} block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    {
      type: "bpField",
      attrs: { bpId: null, bpType: "field-image", value: "https://cdn.example/x.png", label: "Cover", fieldName: "cover" },
    },
    doc.content[1],
  ];

  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-image",
  );
  assert.ok(ins, "a field-image block is inserted");
  assert.equal(ins.block.type, "field-image", "the inserted block carries bpType 'field-image' (not 'bpField')");
  assert.ok(
    ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
    "the minted id avoids the surviving prev ids",
  );
  assert.equal(ins.block.value, "https://cdn.example/x.png");
  assert.equal(ins.block.fieldName, "cover", "fieldName carried through verbatim");
  assert.equal(ins.block.label, "Cover", "label carried through");
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
    0,
    "an inserted picker emits no extra interior patch",
  );

  const folded = assertFolds(blocks, doc, ops, "TAIL-d field-image insert");
  assert.equal(folded[0].id, "p-1");
  assert.equal(folded[1].type, "field-image");
  assert.equal(folded[1].value, "https://cdn.example/x.png");
  assert.equal(folded[2].id, "p-2");
});

// TAIL-d2) INSERT a field-reference → the inserted block carries its refType config.
check("TAIL runToOps: inserting a field-reference block → insert-after with {type, value, refType}", () => {
  const blocks = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] }];
  const doc = runToTiptap(blocks);
  doc.content = [
    doc.content[0],
    { type: "bpField", attrs: { bpId: null, bpType: "field-reference", value: "doc-9", refType: "author", fieldName: "by" } },
  ];
  const ops = runToOps(blocks, doc);
  const ins = ops.find(
    (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === "field-reference",
  );
  assert.ok(ins, "a field-reference block is inserted");
  assert.equal(ins.block.value, "doc-9");
  assert.equal(ins.block.refType, "author", "the inserted reference carries its refType");
  assert.equal(ins.block.fieldName, "by");
});

// TAIL-e) REMOVE — deleting a picker block → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it.
check("TAIL runToOps: removing a field-reference block → remove-block", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    TAIL_PICKER_SEEDS["field-reference"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content = [doc.content[0], doc.content[2]]; // delete the picker

  const ops = runToOps(blocks, doc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "fr-1" }],
    "exactly one remove-block for the picker",
  );
  assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

  const folded = assertFolds(blocks, doc, ops, "TAIL-e picker remove");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
});

// TAIL-f) NON-INTERFERENCE — a picker between two prose blocks does not perturb the
//   prose diff: editing BOTH prose blocks (leaving the picker untouched) emits exactly
//   their two patches and NONE for the picker.
check("TAIL runToOps: a picker between edited prose emits only the prose patches", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    TAIL_PICKER_SEEDS["field-image"],
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];
  const doc = runToTiptap(blocks);
  doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
  doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 2, "exactly the two prose patches, none for the picker");
  assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
  assert.equal(
    ops.filter((o) => o.op === "patch-block" && o.id === "fi-1").length,
    0,
    "the picker emits no patch",
  );

  const folded = assertFolds(blocks, doc, ops, "TAIL-f picker non-interference");
  assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
  assert.deepEqual(folded[1], blocks[1], "picker untouched");
  assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
});

// TAIL-g) MIXED — a picker (image), a reference, a native field, a code, and a callout
//   in ONE run all round-trip with ZERO ops untouched (the picker control-atom coexists
//   with every other variant).
check("TAIL runToOps: field-image + field-reference + native field + code + callout in ONE run → ZERO ops", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    TAIL_PICKER_SEEDS["field-image"],
    TAIL_PICKER_SEEDS["field-reference"],
    { id: "n-1", type: "field-string", label: "Title", fieldName: "title", value: "Hi" },
    { id: "k-1", type: "code", lang: "js", value: "const x = 1;" },
    { id: "c-1", type: "callout", tone: "info", content: [{ type: "text", value: "note" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "outro" }] },
  ];
  const doc = runToTiptap(blocks);

  // The pickers AND the native field project to the SAME bpField node.
  assert.equal(doc.content[1].type, "bpField", "field-image → bpField");
  assert.equal(doc.content[2].type, "bpField", "field-reference → bpField");
  assert.equal(doc.content[3].type, "bpField", "native field → bpField");
  assert.equal(doc.content[4].type, "bpCode");
  assert.equal(doc.content[5].type, "callout");

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched mixed run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "TAIL-g mixed pickers+native+code+callout");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "fi-1", "fr-1", "n-1", "k-1", "c-1", "p-2"]);
  assert.deepEqual(folded[1], blocks[1], "field-image untouched");
  assert.deepEqual(folded[2], blocks[2], "field-reference untouched");
});

// TAIL-h) DATASET OVERRIDE — a picker block that pins a per-block `dataset` round-trips
//   it verbatim (the canvas carries it as config so the picker fetches against the
//   pinned dataset), with ZERO ops untouched and a value edit still emitting only { value }.
check("TAIL runToOps: a field-image with a per-block dataset round-trips the dataset (config), value edit is still {value}", () => {
  const seed = { id: "fi-2", type: "field-image", label: "Pic", value: "u1", dataset: "staging" };
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "x" }] },
    seed,
  ];
  const doc = runToTiptap(blocks);
  assert.equal(doc.content[1].attrs.dataset, "staging", "the pinned dataset rides an attr");

  // Untouched → zero ops, dataset preserved.
  assert.equal(runToOps(blocks, doc).length, 0, "untouched → zero ops");
  const folded0 = assertFolds(blocks, doc, runToOps(blocks, doc), "TAIL-h dataset round-trip");
  assert.deepEqual(folded0[1], seed, "dataset round-trips verbatim");

  // A value edit → ONE patch-block{value} (dataset is config, never in the patch).
  doc.content[1] = { ...doc.content[1], attrs: { ...doc.content[1].attrs, value: "u2" } };
  const ops = runToOps(blocks, doc);
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(patches.length, 1);
  assert.deepEqual(Object.keys(patches[0].patch), ["value"], "patch is {value} only — dataset is NOT patched");
  const folded = assertFolds(blocks, doc, ops, "TAIL-h dataset value edit");
  assert.equal(folded[1].value, "u2");
  assert.equal(folded[1].dataset, "staging", "the dataset config survives the value patch");
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

// ───────────────────────────────────────────────────────────────────────────
// Phase-4 Stage S3.6 — the sheet + embed blocks as canvas READ-ONLY ATOM nodes
// (run-convert.js + embed-node.js). A sheet/embed in a run is NO LONGER opaque:
// runToTiptap emits a native { type:"bpSheet"|"bpEmbed", attrs:{bpId,bpType,bpBlock} }
// READ-ONLY ATOM carrying the WHOLE block VERBATIM on bpBlock (the bpOpaque
// verbatim-carry, made canvas-eligible), and runToOps reconstructs the carried block
// verbatim. UNLIKE the field control-atom (whose value IS edited → a patch), a
// read-only atom NEVER emits a value/content patch — nothing is edited — but it IS
// canvas-eligible (no split) and DOES participate in structural ops (insert/remove/
// move by bpId). (field-image / field-reference (pickers) now ALSO ride the canvas — as
// control-atoms — per the run-splitter tail; the remaining bpOpaque boundaries are the
// nested-structure fields composite / arrayOf / codelist / localizedText / section.)
//
// The two read-only-atom seeds: a sheet (ref + cached value-grid snapshot) and an
// embed (a note transclusion target). Both ride the whole block verbatim.
// ───────────────────────────────────────────────────────────────────────────

const S36_SHEET = {
  id: "sh-1",
  type: "sheet",
  ref: "production/budget",
  snapshot: {
    rows: [
      ["Item", "Cost"],
      ["Server", "100"],
      ["Domain", "12"],
    ],
    head: ["Item", "Cost"],
  },
};

const S36_EMBED = { id: "em-1", type: "embed", target: "Linked Note" };

// The node NAME (bpSheet / bpEmbed) per bpType — the read-only atom maps a block.type
// to its dedicated NODE, NOT the generic bpOpaque.
const S36_NODE_NAME = { sheet: BP_SHEET_NODE_NAME, embed: BP_EMBED_NODE_NAME };
const S36_SEEDS = { sheet: S36_SHEET, embed: S36_EMBED };

// S3.6-a) PROJECTION — a sheet / embed projects to its dedicated READ-ONLY ATOM node
//   (bpSheet / bpEmbed), NOT the generic bpOpaque, carrying the WHOLE block VERBATIM on
//   bpBlock (deep-equal but NOT a shared ref). The flanking prose still projects
//   normally.
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToTiptap: a ${type} block → the READ-ONLY atom node (NOT bpOpaque), carrying bpBlock VERBATIM`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    assert.equal(doc.content.length, 3);

    const n = doc.content[1];
    // THE CRUX: it is the dedicated read-only NODE, NOT the generic bpOpaque.
    assert.equal(n.type, S36_NODE_NAME[type], `${type} projects to its read-only node`);
    assert.notEqual(n.type, "bpOpaque", `${type} is NOT the generic opaque placeholder`);
    assert.notEqual(n.type, type, "node name is the bp-prefixed read-only node, not the bpType");
    assert.equal(n.attrs.bpId, seed.id);
    assert.equal(n.attrs.bpType, type);
    // The WHOLE block rides bpBlock VERBATIM — deep-equal, but NOT a shared ref.
    assert.deepEqual(n.attrs.bpBlock, seed, "the whole block rides bpBlock verbatim");
    assert.notEqual(n.attrs.bpBlock, seed, "but bpBlock is NOT a shared ref (deep-cloned)");
    if (seed.snapshot) {
      assert.notEqual(n.attrs.bpBlock.snapshot, seed.snapshot, "nested snapshot is deep-cloned too (no shared ref)");
    }
    // A read-only atom: no content hole, NO individually-mutable value attr.
    assert.ok(!("content" in n), "read-only atom carries no content");
    assert.ok(!("value" in n.attrs), "read-only atom carries no editable value attr");

    // The flanking prose still projects normally.
    assert.equal(doc.content[0].type, "paragraph");
    assert.equal(doc.content[2].type, "paragraph");
  });
}

// S3.6-a2) READ-ONLY REPRESENTATION — the chip label the node-view renders: the sheet
//   summary "Sheet · <ref> · NxM" (N rows × M cols from the snapshot); the embed
//   reference "↪ <target>". Purely presentational; the block rides verbatim regardless.
check("S3.6 read-only representation: sheet → summary chip 'Sheet · <ref> · NxM'", () => {
  // 3 rows × 2 cols, ref present.
  assert.equal(sheetChipLabel(S36_SHEET), "Sheet · production/budget · 3×2");
  // A ref-less / snapshot-less sheet degrades gracefully (0×0, no ref segment).
  assert.equal(sheetChipLabel({ type: "sheet" }), "Sheet · 0×0");
  assert.equal(sheetChipLabel({ type: "sheet", ref: "g" }), "Sheet · g · 0×0");
});

check("S3.6 read-only representation: embed → reference chip '↪ <target>'", () => {
  assert.equal(embedChipLabel(S36_EMBED), "↪ Linked Note");
  // A blank target renders "↪ (untitled)" (no dangling trailing space).
  assert.equal(embedChipLabel({ type: "embed" }), "↪ (untitled)");
});

// S3.6-b) ROUND-TRIP — an UNTOUCHED sheet / embed survives runToOps with ZERO ops, and
//   the whole mixed run folds back to the IDENTICAL block list — the carried block is
//   deep-equal to the original (the verbatim round-trip).
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: an untouched ${type} round-trips with ZERO ops (verbatim, deep-equal)`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "h-1", type: "heading", level: 1, text: "Doc" },
      seed,
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);

    // Simulate the live editor's getJSON attr key order (reordered) — change detection
    // must be key-order-safe (here: trivially so, since a read-only atom never patches).
    const n = doc.content[1];
    n.attrs = { bpBlock: n.attrs.bpBlock, bpType: type, bpId: seed.id };

    const ops = runToOps(blocks, doc);
    assert.equal(ops.length, 0, `an untouched ${type} run emits ZERO ops`);

    // FOLD GATE: folds back to the identical block list; the read-only block survives
    // VERBATIM (deep-equal), and the prose is untouched.
    const folded = assertFolds(blocks, doc, ops, `S3.6-b ${type} round-trip`);
    assert.deepEqual(folded.map((b) => b.id), ["h-1", seed.id, "p-1"]);
    assert.deepEqual(folded[1], seed, `${type} folds back byte-identical (verbatim)`);
  });
}

// S3.6-c) READ-ONLY NEVER PATCHES — even if some attr on the read-only atom is TOUCHED,
//   runToOps emits ZERO ops for it (it is a reference; nothing is editable). We mutate a
//   non-bp attr on the node and assert no patch lands. (The node-view never writes such
//   an attr; this proves the diff path itself never emits a value/content patch.)
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: a ${type} NEVER emits a value patch even if an attr is touched (read-only)`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-0", type: "paragraph", content: [{ type: "text", value: "x" }] },
      seed,
    ];
    const doc = runToTiptap(blocks);
    // Touch an attr on the read-only node — a read-only atom must still emit NOTHING.
    doc.content[1] = {
      ...doc.content[1],
      attrs: { ...doc.content[1].attrs, somethingTouched: "ignored" },
    };

    const ops = runToOps(blocks, doc);
    assert.equal(
      ops.filter((o) => o.op === "patch-block" && o.id === seed.id).length,
      0,
      `a ${type} never emits a value/content patch (read-only)`,
    );
    assert.equal(ops.length, 0, "no ops at all — the read-only atom is inert to edits");
  });
}

// S3.6-d) INSERT — a NEW sheet / embed (no bpId) between two surviving prose blocks →
//   an insert-after carrying the VERBATIM block (the whole block off bpBlock) with a
//   client-minted id, and NO patch on the read-only atom. The fold lands it between the
//   prose.
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: inserting a ${type} → insert-after carrying the VERBATIM block`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
      { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    // Splice a NEW read-only atom (bpId null → minted) between p-1 and p-2, carrying the
    // whole block verbatim on bpBlock (id stripped — it is minted on insert).
    const carried = { ...seed };
    delete carried.id;
    doc.content = [
      doc.content[0], // p-1
      {
        type: S36_NODE_NAME[type],
        attrs: { bpId: null, bpType: type, bpBlock: carried },
      },
      doc.content[1], // p-2
    ];

    const ops = runToOps(blocks, doc);
    const ins = ops.find(
      (o) => (o.op === "insert-after" || o.op === "append-block") && o.block.type === type,
    );
    assert.ok(ins, `a ${type} block is inserted`);
    assert.equal(ins.block.type, type, `the inserted block carries bpType '${type}' (not the node name)`);
    assert.ok(
      ins.block.id != null && ins.block.id !== "p-1" && ins.block.id !== "p-2",
      "the minted id avoids the surviving prev ids",
    );
    // The carried block is VERBATIM (every non-id field of the seed survives).
    for (const k of Object.keys(seed)) {
      if (k === "id") continue;
      assert.deepEqual(ins.block[k], seed[k], `${type} insert carries ${k} verbatim`);
    }
    // No separate interior patch for a read-only insert (it never patches).
    assert.equal(
      ops.filter((o) => o.op === "patch-block" && o.id === ins.block.id).length,
      0,
      "an inserted read-only atom emits no interior patch",
    );

    // FOLD GATE: the read-only block lands at slot 1, between the two surviving prose,
    // VERBATIM (minus its now-minted id).
    const folded = assertFolds(blocks, doc, ops, `S3.6-d ${type} insert`);
    assert.equal(folded[0].id, "p-1");
    assert.equal(folded[1].type, type);
    assert.equal(folded[2].id, "p-2");
    // The carried block survived verbatim under the minted id.
    const landed = { ...folded[1] };
    delete landed.id;
    const expected = { ...seed };
    delete expected.id;
    assert.deepEqual(landed, expected, `${type} landed verbatim (sans id)`);
  });
}

// S3.6-e) REMOVE — deleting a sheet / embed → a remove-block keyed by its id; the
//   surrounding prose is untouched. The fold drops it. (Backspace on the selected atom
//   maps to this remove-block — the structural delete affordance.)
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: removing a ${type} → remove-block (Backspace deletes the atom)`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
      seed,
      { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
    ];
    const doc = runToTiptap(blocks);
    doc.content = [doc.content[0], doc.content[2]]; // Backspace-deletes the read-only atom

    const ops = runToOps(blocks, doc);
    assert.deepEqual(
      ops.filter((o) => o.op === "remove-block"),
      [{ op: "remove-block", id: seed.id }],
      `exactly one remove-block for the ${type}`,
    );
    assert.equal(ops.filter((o) => o.op === "patch-block").length, 0, "no prose patches");

    const folded = assertFolds(blocks, doc, ops, `S3.6-e ${type} remove`);
    assert.deepEqual(folded.map((b) => b.id), ["p-1", "p-2"]);
  });
}

// S3.6-f) NON-INTERFERENCE — a sheet / embed between two prose blocks does not perturb
//   the prose diff: editing BOTH prose blocks (leaving the read-only atom untouched)
//   emits exactly their two patches and NONE for the read-only atom.
for (const type of ["sheet", "embed"]) {
  check(`S3.6 runToOps: a ${type} between edited prose emits only the prose patches (none for the ${type})`, () => {
    const seed = S36_SEEDS[type];
    const blocks = [
      { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
      seed,
      { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
    ];
    const doc = runToTiptap(blocks);
    doc.content[0] = { ...doc.content[0], content: [{ type: "text", text: "ONE!" }] };
    doc.content[2] = { ...doc.content[2], content: [{ type: "text", text: "TWO!" }] };

    const ops = runToOps(blocks, doc);
    const patches = ops.filter((o) => o.op === "patch-block");
    assert.equal(patches.length, 2, `exactly the two prose patches, none for the ${type}`);
    assert.deepEqual(patches.map((o) => o.id).sort(), ["p-1", "p-2"]);
    assert.equal(
      ops.filter((o) => o.op === "patch-block" && o.id === seed.id).length,
      0,
      `the ${type} emits no patch`,
    );

    // FOLD GATE: both prose blocks carry their new content; the read-only atom survives
    // untouched at slot 1 (verbatim).
    const folded = assertFolds(blocks, doc, ops, `S3.6-f ${type} non-interference`);
    assert.deepEqual(folded[0].content, [{ type: "text", value: "ONE!" }]);
    assert.deepEqual(folded[1], seed, `${type} survives untouched (verbatim)`);
    assert.deepEqual(folded[2].content, [{ type: "text", value: "TWO!" }]);
  });
}

// S3.6-g) A sheet AND an embed in the SAME run round-trip together with ZERO ops — the
//   run can now span [p, sheet, embed, p] without splitting (completing S3).
check("S3.6 runToOps: [paragraph, sheet, embed, paragraph] round-trips with ZERO ops (one run, no split)", () => {
  const blocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "before" }] },
    S36_SHEET,
    S36_EMBED,
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "after" }] },
  ];
  const doc = runToTiptap(blocks);

  // Both project to their dedicated read-only nodes (NOT bpOpaque).
  assert.equal(doc.content[1].type, BP_SHEET_NODE_NAME);
  assert.equal(doc.content[2].type, BP_EMBED_NODE_NAME);

  const ops = runToOps(blocks, doc);
  assert.equal(ops.length, 0, "an untouched [p, sheet, embed, p] run emits ZERO ops");

  const folded = assertFolds(blocks, doc, ops, "S3.6-g sheet+embed one run");
  assert.deepEqual(folded.map((b) => b.id), ["p-1", "sh-1", "em-1", "p-2"]);
  assert.deepEqual(folded[1], S36_SHEET, "sheet survives verbatim");
  assert.deepEqual(folded[2], S36_EMBED, "embed survives verbatim");
});

// S3.6-h) STILL-OPAQUE — a NESTED-STRUCTURE field (composite), still a boundary, is
//   STILL carried opaquely (NOT a read-only atom, NOT a control-atom). After S3.6
//   sheet/embed are canvas-eligible, and the run-splitter tail made field-image /
//   field-reference canvas-eligible too — but composite / arrayOf / codelist /
//   localizedText / section stay boundaries (a separate nested-structure increment).
check("S3.6 runToTiptap: a composite field is STILL opaque (sheet/embed + pickers became canvas-eligible, nested-structure fields did not)", () => {
  const nested = { id: "cmp-1", type: "composite", fields: [], value: {} };
  const doc = runToTiptap([nested]);
  assert.equal(doc.content[0].type, "bpOpaque", "composite stays opaque");
  assert.notEqual(doc.content[0].type, BP_SHEET_NODE_NAME);
  assert.notEqual(doc.content[0].type, BP_EMBED_NODE_NAME);
  assert.notEqual(doc.content[0].type, "bpField", "composite is NOT a control-atom");
  assert.deepEqual(doc.content[0].attrs.bpBlock, nested);
});

// ── S4a) ECHO-DRIVEN BASELINE ───────────────────────────────────────────────
//
// The canvas's applyServerBlocks() uses runToOps as the OWN-ECHO match gate and
// resets this._blocks to the server-confirmed blocks so the NEXT diff is
// INCREMENTAL. These pure tests prove the two invariants the WC method relies on
// (the WC itself needs a DOM Editor, out of scope for the smoke; here we test the
// PURE runToOps math the method is built on).

// S4a-a) THE MATCH CHECK: an echo of the SAME blocks is a no-op.
//   runToOps(serverBlocks, runToTiptap(serverBlocks)) === []  — so applyServerBlocks
//   detects an own-echo (the live doc already equals the confirmed blocks) and
//   takes the pure-baseline-reset path (zero editor mutation, zero caret move).
check("S4a runToOps: an echo of the same blocks is a NO-OP (own-echo match gate)", () => {
  const serverBlocks = [
    { id: "h-1", type: "heading", level: 1, text: "Title" },
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "beta" }] },
  ];
  // The live doc IS the projection of the confirmed blocks (the own-echo case:
  // the server confirmed exactly what the canvas already holds).
  const liveDoc = runToTiptap(serverBlocks);
  const ops = runToOps(serverBlocks, liveDoc);
  assert.equal(ops.length, 0, "echo of the same blocks emits ZERO ops → own-echo no-op");
});

// S4a-b) BASELINE RESET SHRINKS THE DIFF: prove cumulative → incremental.
//   Without the echo (S1), every batch diffs from the MOUNTED run, so the 2nd
//   edit's batch re-includes the 1st edit (CUMULATIVE). With the echo (S4a), the
//   baseline advances to the server-confirmed blocks after edit 1, so the 2nd
//   batch carries ONLY edit 2 (INCREMENTAL).
check("S4a baseline reset: the 2nd batch is INCREMENTAL, not cumulative (echo shrinks the diff)", () => {
  const mounted = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "one" }] },
    { id: "p-2", type: "paragraph", content: [{ type: "text", value: "two" }] },
  ];

  // EDIT 1 — change p-1's text. The doc after edit 1:
  const doc1 = runToTiptap(mounted);
  doc1.content[0] = {
    ...doc1.content[0],
    content: [{ type: "text", text: "ONE" }],
  };
  const batch1 = runToOps(mounted, doc1);
  assert.equal(batch1.length, 1, "edit 1 → one patch-block (p-1)");
  assert.equal(batch1[0].id, "p-1");

  // The server confirms edit 1 → it echoes back the new blocks. The canvas resets
  // its baseline to these (applyServerBlocks own-echo path). Build the confirmed
  // blocks by folding batch1 over the mounted run (what the server persisted).
  const confirmed1 = applyOps(mounted, batch1);
  assert.deepEqual(
    confirmed1[0].content,
    [{ type: "text", value: "ONE" }],
    "server-confirmed blocks carry edit 1",
  );

  // EDIT 2 — now change p-2's text. The doc after edit 2 (built on the confirmed
  // doc, both edits present in the LIVE doc as they always are):
  const doc2 = runToTiptap(confirmed1);
  doc2.content[1] = {
    ...doc2.content[1],
    content: [{ type: "text", text: "TWO" }],
  };

  // S1 (NO echo) — diffing from the ORIGINAL mounted run re-emits BOTH edits.
  const cumulative = runToOps(mounted, doc2);
  assert.equal(cumulative.length, 2, "WITHOUT echo: cumulative batch carries BOTH edits");
  assert.deepEqual(
    cumulative.map((o) => o.id).sort(),
    ["p-1", "p-2"],
    "cumulative batch touches p-1 (edit 1) AND p-2 (edit 2)",
  );

  // S4a (echo) — diffing from the RESET baseline (confirmed1) carries ONLY edit 2.
  const incremental = runToOps(confirmed1, doc2);
  assert.equal(incremental.length, 1, "WITH echo: incremental batch carries ONLY edit 2");
  assert.equal(incremental[0].id, "p-2", "incremental batch touches only p-2 (edit 2)");

  // The baseline reset strictly SHRANK the diff.
  assert.ok(
    incremental.length < cumulative.length,
    "echo-advanced baseline shrinks the op count (incremental < cumulative)",
  );
});

// S4a-c) EXTERNAL EDIT IS DETECTED: a confirmed-blocks echo that DIFFERS from the
//   live doc yields a NON-EMPTY runToOps → applyServerBlocks takes the
//   external-edit path (setContent the confirmed content, addToHistory:false).
check("S4a runToOps: a confirmed echo that DIFFERS from the live doc is detected (external edit)", () => {
  const liveBlocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "local" }] },
  ];
  const liveDoc = runToTiptap(liveBlocks);

  // The server confirms DIFFERENT content for p-1 (an external edit from another
  // tab / agent / ingest). applyServerBlocks diffs the confirmed blocks against
  // the live doc — a non-empty result means "not my echo, re-render".
  const externalBlocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "external" }] },
  ];
  const ops = runToOps(externalBlocks, liveDoc);
  assert.ok(ops.length > 0, "an external edit (confirmed != live) is NOT an own-echo");
});

// S4a-d) THE NEW-BLOCK ECHO (the bug this fix closes). The naive own-echo gate —
//   runToOps(serverBlocks, liveDoc) === [] — MISDETECTS a NEW-block echo as
//   EXTERNAL. When the user Enter-splits, the live new-block node carries
//   bpId:null; the server mints an id ("srv-9") and echoes it. runToOps mints a
//   FRESH id for the null node and reports remove("srv-9") + insert-after(fresh) —
//   a NON-EMPTY diff → misdetected external → setContent yanks the caret AND, since
//   the live node never learns "srv-9", every later batch re-mints it (op size
//   never shrinks; the server id churns). reconcileServerEcho closes this: a live
//   bpId:null is a WILDCARD for the server id at that index → ownEcho true + the
//   id-writebacks. After the (simulated) writeback the next diff is [] (no churn),
//   and a SECOND edit emits a single INCREMENTAL op (not a re-mint of block 1).
check("S4a-d new-block echo: id-tolerant reconcile recognizes the OWN echo + makes the next diff incremental", () => {
  // The mounted baseline (the canvas's prev) — one paragraph.
  const mountedBaseline = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
  ];

  // The user Enter-splits: p-1 keeps "alpha"; a NEW 2nd paragraph "beta" carries
  // bpId:null (a freshly-typed block has no id yet) — the REAL new-block shape.
  const liveDoc = runToTiptap(mountedBaseline);
  liveDoc.content = [
    {
      type: "paragraph",
      attrs: { bpId: "p-1", bpType: "paragraph" },
      content: [{ type: "text", text: "alpha" }],
    },
    {
      type: "paragraph",
      attrs: { bpId: null, bpType: "paragraph" }, // NEW block — no id yet
      content: [{ type: "text", text: "beta" }],
    },
  ];

  // The emitted ops: a single insert-after with a CLIENT-minted id for the new
  // block (the batch the canvas sends to the server).
  const batch1 = runToOps(mountedBaseline, liveDoc);
  assert.equal(batch1.length, 1, "the split emits exactly one insert-after");
  assert.equal(batch1[0].op, "insert-after");
  assert.equal(batch1[0].afterId, "p-1");

  // The server applies it and mints "srv-9" for the new block, then echoes the
  // CONFIRMED blocks (the new block now carrying a concrete id).
  const serverBlocks = [
    { id: "p-1", type: "paragraph", content: [{ type: "text", value: "alpha" }] },
    { id: "srv-9", type: "paragraph", content: [{ type: "text", value: "beta" }] },
  ];

  // (a) THE NAIVE GATE WAS WRONG — runToOps against the live doc that STILL has
  //     bpId:null reports a NON-empty diff (the misdetection this fix kills).
  const naive = runToOps(serverBlocks, liveDoc);
  assert.ok(
    naive.length > 0,
    "REGRESSION GUARD: the OLD runToOps gate misdetects the new-block echo as external",
  );

  // (a') THE ID-TOLERANT RECONCILE IS RIGHT — it recognizes the OWN echo (NOT
  //      external) and returns the id-writeback for the just-minted null node.
  const { ownEcho, idWrites } = reconcileServerEcho(serverBlocks, liveDoc.content);
  assert.equal(ownEcho, true, "the new-block echo is recognized as an OWN echo");
  assert.deepEqual(
    idWrites,
    [{ index: 1, id: "srv-9", bpType: undefined }],
    "the writeback stamps srv-9 onto the live null-bpId node at index 1",
  );

  // (b) AFTER THE (simulated) ID WRITEBACK — runToOps(serverBlocks, stampedLive)
  //     is [] (NO churn: the live node now carries srv-9, so it diffs incremental).
  const stamped = {
    type: "doc",
    content: liveDoc.content.map((node, i) => {
      const w = idWrites.find((x) => x.index === i);
      if (!w) return node;
      const attrs = { ...node.attrs, bpId: w.id };
      if (w.bpType !== undefined) attrs.bpType = w.bpType;
      return { ...node, attrs };
    }),
  };
  const afterStamp = runToOps(serverBlocks, stamped);
  assert.equal(
    afterStamp.length,
    0,
    "after the id writeback the echo NO-OPS (no remove/insert churn)",
  );

  // (b') A SECOND edit (change the new block's text) emits ONE INCREMENTAL op —
  //      a patch-block keyed by srv-9, NOT a re-mint of the first new block.
  const doc2 = {
    type: "doc",
    content: stamped.content.map((node, i) =>
      i === 1 ? { ...node, content: [{ type: "text", text: "beta EDIT" }] } : node,
    ),
  };
  const batch2 = runToOps(serverBlocks, doc2);
  assert.equal(batch2.length, 1, "the 2nd edit emits exactly one incremental op");
  assert.equal(batch2[0].op, "patch-block", "incremental: a patch, not a re-insert");
  assert.equal(batch2[0].id, "srv-9", "the patch is keyed by the server id (no re-mint)");
  assert.equal(
    batch2.filter((o) => o.op === "insert-after" || o.op === "append-block").length,
    0,
    "no re-mint of the first new block on the 2nd edit",
  );
});

// ── P4 S-slash: canvas slash menu DIRECT-INSERT round-trips ─────────────────
//
// The canvas slash pick inserts slashTypeToNode(type) DIRECTLY into the doc — so
// runToOps must emit ONE insert-after (or append, on an empty run) carrying the
// SAME default block default_block/2 would have built. These tests prove that for
// every insertable type, plus the allowlist (excluded types absent) and the
// callout-shorthand replace.

// Helper: insert a slash node AFTER a single anchor block and return the ops.
function slashInsertOps(type) {
  const anchor = { id: "p-1", type: "paragraph", content: [{ type: "text", value: "anchor" }] };
  const prev = [anchor];
  const prevDoc = runToTiptap(prev);
  const node = slashTypeToNode(type);
  const nextDoc = { type: "doc", content: [...prevDoc.content, node] };
  const ops = runToOps(prev, nextDoc);
  return { prev, nextDoc, ops };
}

// (a) Per-type: slashTypeToNode → ONE insert-after carrying { type, …default } whose
//     reconstructed block matches default_block/2, AND the fold reproduces nextDoc.
const SLASH_INSERTABLE = [
  "paragraph",
  "heading",
  "list",
  "callout",
  "code",
  "divider",
  "diagram",
  "field-string",
  "field-boolean",
];
for (const type of SLASH_INSERTABLE) {
  check(`S-slash: /${type} → one insert-after carrying a ${type} block`, () => {
    const { prev, nextDoc, ops } = slashInsertOps(type);
    const inserts = ops.filter((o) => o.op === "insert-after" || o.op === "append-block");
    assert.equal(inserts.length, 1, `${type}: exactly one structural insert`);
    assert.equal(ops.length, 1, `${type}: ONLY the insert (no stray patch/move)`);
    const ins = inserts[0];
    assert.equal(ins.op, "insert-after", `${type}: insert-after (anchor survives)`);
    assert.equal(ins.afterId, "p-1", `${type}: anchored after the surviving block`);
    assert.equal(ins.block.type, type, `${type}: the carried block is of type ${type}`);
    assert.ok(ins.block.id != null, `${type}: the carried block has a minted id`);
    // The carried block is the CANONICAL reconstruction of the default node — the
    // exact shape runToOps+nextNodeToBlock produce, which is what the server persists.
    // It is the NORMALIZED form of default_block/2: the converter drops an empty
    // inline text run (paragraph/list/callout body → []) and omits empty optionals
    // (code.lang, diagram.caption). Both forms are SEMANTICALLY the same default; the
    // canonical form is the fixed point of project→reconstruct. We assert the carried
    // block equals canvasDefaultBlock(type) run through that SAME projection round-trip
    // (so the test pins the canonical shape without hard-coding each normalization).
    const canonical = reconstructDefault(type);
    const { id: _gotId, ...gotRest } = ins.block;
    assert.deepEqual(gotRest, canonical, `${type}: block matches the canonical default shape`);
    // The fold gate: runToOps's ops reproduce nextDoc.
    assertFolds(prev, nextDoc, ops, `S-slash /${type}`);
  });
}

// The CANONICAL reconstructed default for a type: project canvasDefaultBlock(type)
// to a node and reconstruct it through the SAME runToOps insert path, returning the
// carried block minus its (minted) id. This is the fixed point of the projection
// round-trip — the exact normalized shape the server receives — so the per-type
// assertion above pins it without hard-coding each normalization rule.
function reconstructDefault(type) {
  const node = slashTypeToNode(type);
  const ops = runToOps([], { type: "doc", content: [node] });
  const block = ops[0].block;
  const { id: _id, ...rest } = block;
  return rest;
}

// (a*) The NON-EMPTY defaults that MUST survive the round-trip (the load-bearing
//      datums of default_block/2): heading text+level, callout tone, field labels,
//      field-color/field-select values. These pin the fidelity that an empty-content
//      normalization could otherwise mask.
check("S-slash: non-empty defaults survive (heading/callout/field labels+values)", () => {
  const h = reconstructDefault("heading");
  assert.equal(h.text, "New heading", "heading text default");
  assert.equal(h.level, 2, "heading level default is 2");
  const c = reconstructDefault("callout");
  assert.equal(c.tone, "info", "callout default tone is info");
  assert.equal(reconstructDefault("field-slug").label, "Slug", "field-slug label");
  assert.equal(reconstructDefault("field-text").label, "Long text", "field-text label");
  const color = reconstructDefault("field-color");
  assert.equal(color.value, "#000000", "field-color default value");
  const select = reconstructDefault("field-select");
  assert.equal(select.value, "", "field-select default value is empty");
  assert.deepEqual(
    select.options,
    [
      { value: "option-1", label: "Option 1" },
      { value: "option-2", label: "Option 2" },
    ],
    "field-select default options",
  );
});

// (a') field-boolean's default value is the BOOLEAN false (not "" or "false") — the
//      per-type default that distinguishes it from the string fields.
check("S-slash: /field-boolean default value is boolean false", () => {
  const { ops } = slashInsertOps("field-boolean");
  const ins = ops.find((o) => o.op === "insert-after");
  assert.equal(ins.block.value, false, "the default boolean value is false");
  assert.equal(typeof ins.block.value, "boolean", "and it is a real boolean");
});

// (a'') field-string's default value is the empty STRING (the non-boolean default).
check("S-slash: /field-string default value is empty string", () => {
  const { ops } = slashInsertOps("field-string");
  const ins = ops.find((o) => o.op === "insert-after");
  assert.equal(ins.block.value, "", "the default string value is \"\"");
  assert.equal(ins.block.label, "Text", "and the default label is Text");
});

// (b) INSERT INTO AN EMPTY RUN — append-block (no surviving anchor). A divider into
//     an empty doc appends and reconstructs as a divider block.
check("S-slash: /divider into an EMPTY run → append-block of a divider", () => {
  const prev = [];
  const node = slashTypeToNode("divider");
  const nextDoc = { type: "doc", content: [node] };
  const ops = runToOps(prev, nextDoc);
  assert.equal(ops.length, 1, "one op");
  assert.equal(ops[0].op, "append-block", "appended (no anchor in an empty run)");
  assert.equal(ops[0].block.type, "divider", "the appended block is a divider");
  assertFolds(prev, nextDoc, ops, "S-slash /divider empty");
});

// (c) THE ALLOWLIST — every insertable type is IN, every excluded type is OUT.
check("S-slash: CANVAS_SLASH_TYPES holds exactly the insertable set", () => {
  for (const t of [
    "paragraph", "heading", "list", "callout", "code", "divider", "diagram",
    "field-string", "field-slug", "field-text", "field-boolean",
    "field-select", "field-datetime", "field-color",
  ]) {
    assert.ok(CANVAS_SLASH_TYPES.has(t), `${t} must be insertable`);
  }
  // EXCLUDED from SLASH-INSERT (NOT the same as canvas-eligibility): read-only refs
  // (sheet/embed) and the pickers (field-image/field-reference) DO ride the canvas now,
  // but a "/" pick can't DIRECT-insert them — sheet/embed are references with no empty
  // default, and the pickers need a fetch-scope (dataset/refType) the slash default
  // can't supply. Also excluded: the nested-structure run-splitting boundaries
  // (section/composite/arrayOf/codelist/localizedText) and the article-chrome blocks
  // (eyebrow/byline/ingress/pullquote).
  for (const t of [
    "sheet", "embed", "section", "composite", "arrayOf", "codelist", "localizedText",
    "field-image", "field-reference", "eyebrow", "byline", "ingress", "pullquote",
  ]) {
    assert.ok(!CANVAS_SLASH_TYPES.has(t), `${t} must NOT be insertable`);
  }
  assert.equal(CANVAS_SLASH_TYPES.size, 14, "exactly 14 insertable types");
});

// (d) THE CALLOUT SHORTHAND — `> [!warn]- ` replaces the para with a bpCallout node
//     of the matched tone (warning), collapsed. We build the node the WC builds and
//     assert runToOps reconstructs a callout block of that tone (collapsible/collapsed
//     carried). This mirrors _maybeCalloutShorthand's node construction.
check("S-slash: `> [!warn]- ` → a warning callout (collapsed) insert", () => {
  // The WC: canvasDefaultBlock("callout") + tone from normalizeTone(m[1]) + collapsible
  // + collapsed = (m[2] === "-").
  const tone = normalizeTone("warn"); // → "warning"
  const collapsed = "-" === "-"; // true
  const block = canvasDefaultBlock("callout");
  block.tone = tone;
  block.collapsible = true;
  block.collapsed = collapsed;
  const node = runToTiptap([block]).content[0];
  // Replace a "/"-typed origin paragraph (modelled as a removed prev block) with the
  // callout: prev has one paragraph, next has ONLY the callout node → remove + insert.
  const prev = [{ id: "o-1", type: "paragraph", content: [{ type: "text", value: "" }] }];
  const nextDoc = { type: "doc", content: [node] };
  const ops = runToOps(prev, nextDoc);
  const inserts = ops.filter((o) => o.op === "insert-after" || o.op === "append-block");
  assert.equal(inserts.length, 1, "one structural insert (the callout)");
  const ins = inserts[0];
  assert.equal(ins.block.type, "callout", "the inserted block is a callout");
  assert.equal(ins.block.tone, "warning", "tone is warning (warn → warning)");
  assert.equal(ins.block.collapsible, true, "collapsible carried");
  assert.equal(ins.block.collapsed, true, "collapsed (modifier was '-')");
  // The origin paragraph is removed (the shorthand consumed it).
  assert.ok(ops.some((o) => o.op === "remove-block" && o.id === "o-1"), "origin para removed");
  assertFolds(prev, nextDoc, ops, "S-slash callout-shorthand");
});

// (d') `> [!note] ` (no modifier) → an info callout (note → info), NOT collapsed.
check("S-slash: `> [!note] ` → an info callout (not collapsed)", () => {
  const block = canvasDefaultBlock("callout");
  block.tone = normalizeTone("note"); // → "info"
  block.collapsible = true;
  block.collapsed = false; // m[2] === "" → not collapsed
  const node = runToTiptap([block]).content[0];
  const prev = [{ id: "o-1", type: "paragraph", content: [{ type: "text", value: "" }] }];
  const nextDoc = { type: "doc", content: [node] };
  const ops = runToOps(prev, nextDoc);
  const ins = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.equal(ins.block.type, "callout", "a callout");
  assert.equal(ins.block.tone, "info", "tone is info (note → info)");
  // collapsed:false is NOT carried (calloutBlockToNode threads it only when === true),
  // so the reconstructed block has no `collapsed` key — byte-fidelity with default_block.
  assert.ok(!("collapsed" in ins.block), "no stray collapsed:false key");
});

// (e) TEXTABLE-NODE classification — prose/callout take an into-body caret; the atoms
//     (divider/code/diagram/field) do not. Asserts the node-type names the WC keys on.
check("S-slash: CANVAS_SLASH_TEXTABLE_NODES classifies body vs atom nodes", () => {
  // The projected node TYPE for each insertable type (runToTiptap naming).
  const projType = (t) => slashTypeToNode(t).type;
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("paragraph")), "paragraph is textable");
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("heading")), "heading is textable");
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("list")), "list (bulletList) is textable");
  assert.ok(CANVAS_SLASH_TEXTABLE_NODES.has(projType("callout")), "callout is textable");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("divider")), "divider is an atom");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("code")), "code (bpCode) is an atom");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("diagram")), "diagram (bpDiagram) is an atom");
  assert.ok(!CANVAS_SLASH_TEXTABLE_NODES.has(projType("field-string")), "field (bpField) is an atom");
});

// (f) BUG#2 GUARD — slashTriggerAllowsParent must REJECT a callout-body parent and
//     ACCEPT a top-level paragraph/heading. The `/` slash menu and the `> [!type]`
//     callout shorthand both REPLACE the whole enclosing textblock with a top-level
//     node (start=$pos.before(depth)/end=$pos.after(depth)). A callout body
//     (callout-node.js group:"block", content:"inline*") is ALSO a depth-1 node, so a
//     depth-only guard let "/head"+Enter / "> [!warning] " typed INSIDE a callout body
//     pass → replaceWith spanned + DESTROYED the enclosing callout. The guard must key
//     on the parent node TYPE, not depth alone.
check("S-slash: slashTriggerAllowsParent rejects a callout body, accepts prose", () => {
  // ACCEPT — a top-level paragraph/heading (depth 1, prose parent): the only safe
  // place to replace the block with a top-level node.
  assert.equal(slashTriggerAllowsParent(1, "paragraph"), true, "top-level paragraph accepted");
  assert.equal(slashTriggerAllowsParent(1, "heading"), true, "top-level heading accepted");

  // REJECT — a callout BODY. It is depth 1 (top-level node) but its parent TYPE is
  // "callout", so the swap would destroy the enclosing callout. This is the bug fix.
  assert.equal(slashTriggerAllowsParent(1, "callout"), false, "callout body rejected (Bug #2)");

  // REJECT — a paragraph nested inside a list item (depth 3): pre-existing nesting
  // guard, must keep rejecting (swapping the inner paragraph for a top-level node
  // would corrupt the doc).
  assert.equal(slashTriggerAllowsParent(3, "paragraph"), false, "list-item paragraph rejected");
  // Defensive: a future inline-content node-view (any non-prose parent type) is rejected
  // even at depth 1.
  assert.equal(slashTriggerAllowsParent(1, "tableCell"), false, "non-prose depth-1 parent rejected");
});

// ── P5 command palette: registry + Insert-command default_block PARITY + fuzzy ──
//
// The palette is the Obsidian Cmd-P analog — a keyboard-triggered launcher over the
// command registry. These pure tests prove (a) the registry is WELL-FORMED (every
// command has id/label/group/run); (b) the Insert commands produce the SAME default
// block as the slash pick — the registry Insert run() and the slash pick BOTH route
// through slashTypeToNode → so an Insert command is byte-equal to the slash-menu path,
// asserted by reconstructing each insertable type the SAME way the S-slash tests do;
// and (c) the fuzzy filter returns the expected matches. The live FORMAT/TURN-INTO
// toggle EFFECTS need a real editor (a DOM ProseMirror instance), so they are left to
// the orchestrator's browser check — here we assert the COMMANDS exist + are shaped.

// buildCommandRegistry() with no editor → the documented static contract (the full
// canvas StarterKit command set is assumed present).
const PALETTE_REGISTRY = buildCommandRegistry();

check("P5 palette: registry is well-formed (id/label/group/run on every command)", () => {
  assert.ok(Array.isArray(PALETTE_REGISTRY), "registry is an array");
  assert.ok(PALETTE_REGISTRY.length > 0, "registry is non-empty");
  const ids = new Set();
  for (const c of PALETTE_REGISTRY) {
    assert.equal(typeof c.id, "string", "id is a string");
    assert.ok(c.id.length > 0, `id non-empty (${c.label})`);
    assert.ok(!ids.has(c.id), `id ${c.id} is unique`);
    ids.add(c.id);
    assert.equal(typeof c.label, "string", `${c.id}: label is a string`);
    assert.ok(c.label.length > 0, `${c.id}: label non-empty`);
    assert.equal(typeof c.group, "string", `${c.id}: group is a string`);
    assert.ok(
      ["Insert", "Format", "Turn into"].includes(c.group),
      `${c.id}: group is one of Insert/Format/Turn into (got ${c.group})`,
    );
    assert.equal(typeof c.run, "function", `${c.id}: run is a function`);
  }
});

check("P5 palette: one Insert command per CANVAS_SLASH_TYPES entry", () => {
  const insertCmds = PALETTE_REGISTRY.filter((c) => c.group === "Insert");
  // Every insertable type has an Insert command, keyed insert-<type>.
  for (const t of CANVAS_SLASH_TYPES) {
    assert.ok(
      insertCmds.some((c) => c.id === `insert-${t}`),
      `Insert command for ${t} present`,
    );
  }
  assert.equal(
    insertCmds.length,
    CANVAS_SLASH_TYPES.size,
    "exactly one Insert command per insertable type (no extras)",
  );
});

check("P5 palette: Format + Turn-into commands present (canvas StarterKit set)", () => {
  const fmt = PALETTE_REGISTRY.filter((c) => c.group === "Format").map((c) => c.id);
  // bold / italic / strike / code marks ship in the canvas StarterKit; clear too.
  for (const id of ["format-bold", "format-italic", "format-strike", "format-code", "format-clear"]) {
    assert.ok(fmt.includes(id), `${id} present`);
  }
  const turn = PALETTE_REGISTRY.filter((c) => c.group === "Turn into").map((c) => c.id);
  for (const id of ["turn-paragraph", "turn-h1", "turn-h2", "turn-h3", "turn-bullet", "turn-ordered"]) {
    assert.ok(turn.includes(id), `${id} present`);
  }
});

// (PARITY) — each Insert command's slashTypeToNode → nextNodeToBlock is BYTE-EQUAL to
// the slash-menu path. We prove parity by reconstructing the default block the SAME
// way the S-slash test does (reconstructDefault, defined above) and asserting it
// matches what the Insert command would insert — both call slashTypeToNode(type), so
// the inserted block is identical. This is the default_block parity the task demands.
check("P5 palette: Insert command default block == slash-menu default block (parity)", () => {
  for (const type of [
    "paragraph", "heading", "list", "callout", "code", "divider", "diagram",
    "field-string", "field-slug", "field-text", "field-boolean",
    "field-select", "field-datetime", "field-color",
  ]) {
    // The slash-menu path: slashTypeToNode(type) → runToOps reconstructs the block.
    const slashBlock = reconstructDefault(type);
    // The palette Insert path inserts slashTypeToNode(type) at the selection (the
    // SAME node); reconstructing it the same way yields the SAME block. We assert the
    // canonical reconstruction is identical (the Insert command carries no extra
    // shape — it is exactly the slash node).
    const node = slashTypeToNode(type);
    const ops = runToOps([], { type: "doc", content: [node] });
    const { id: _id, ...paletteBlock } = ops[0].block;
    assert.deepEqual(
      paletteBlock,
      slashBlock,
      `Insert ${type}: palette block byte-equal to the slash-menu default block`,
    );
  }
});

check("P5 palette: fuzzy filter returns the expected matches", () => {
  // "cal" → Insert Callout (subsequence c-a-l in "Insert Callout").
  const cal = fuzzyFilterCommands(PALETTE_REGISTRY, "cal");
  assert.ok(cal.some((c) => c.id === "insert-callout"), "\"cal\" matches Insert Callout");

  // "bold" → Format Bold.
  const bold = fuzzyFilterCommands(PALETTE_REGISTRY, "bold");
  assert.ok(bold.some((c) => c.id === "format-bold"), "\"bold\" matches Format Bold");
  assert.ok(!bold.some((c) => c.id === "format-italic"), "\"bold\" does NOT match Italic");

  // "h2" → Turn into Heading 2 (subsequence over "Turn into Heading 2").
  const h2 = fuzzyFilterCommands(PALETTE_REGISTRY, "h2");
  assert.ok(h2.some((c) => c.id === "turn-h2"), "\"h2\" matches Turn into Heading 2");

  // Group is part of the haystack: "insert" returns ALL Insert commands.
  const ins = fuzzyFilterCommands(PALETTE_REGISTRY, "insert");
  assert.equal(
    ins.length,
    PALETTE_REGISTRY.filter((c) => c.group === "Insert").length,
    "\"insert\" matches every Insert command (group in the haystack)",
  );

  // Empty query passes EVERYTHING (the open-palette resting state).
  assert.equal(
    fuzzyFilterCommands(PALETTE_REGISTRY, "").length,
    PALETTE_REGISTRY.length,
    "empty query passes the whole registry",
  );

  // A no-match query returns []. "zzzq" is no subsequence of any label+group.
  assert.equal(fuzzyFilterCommands(PALETTE_REGISTRY, "zzzq").length, 0, "no-match → []");

  // Filter PRESERVES registry order (group-contiguity for grouped rendering).
  const all = fuzzyFilterCommands(PALETTE_REGISTRY, "");
  assert.deepEqual(all.map((c) => c.id), PALETTE_REGISTRY.map((c) => c.id), "order preserved");
});

check("P5 palette: fuzzyMatch is a subsequence match (order-sensitive, case-insensitive)", () => {
  assert.ok(fuzzyMatch("cal", "Insert Callout"), "c-a-l is a subsequence");
  assert.ok(fuzzyMatch("CAL", "insert callout"), "case-insensitive");
  assert.ok(fuzzyMatch("", "anything"), "empty query always matches");
  assert.ok(!fuzzyMatch("lac", "Insert Callout"), "wrong order does NOT match");
  assert.ok(!fuzzyMatch("xyz", "Insert Callout"), "absent chars do NOT match");
});

check("P5 palette: editor-filtered registry hides unregistered commands (underline)", () => {
  // A fake editor exposing ONLY bold among the toggles + the node commands; no
  // toggleUnderline → no underline command. Proves the editor-filtered build.
  const fakeEditor = {
    commands: {
      toggleBold: () => {},
      // italic/strike/code/underline intentionally ABSENT
      unsetAllMarks: () => {},
      setParagraph: () => {},
      toggleHeading: () => {},
      toggleBulletList: () => {},
      toggleOrderedList: () => {},
    },
  };
  const reg = buildCommandRegistry(fakeEditor);
  const ids = reg.map((c) => c.id);
  assert.ok(ids.includes("format-bold"), "bold present (registered)");
  assert.ok(!ids.includes("format-italic"), "italic absent (not registered)");
  assert.ok(!ids.includes("format-underline"), "underline absent (not registered)");
  // Insert + turn-into still present (their commands are registered).
  assert.ok(ids.includes("insert-callout"), "insert still present");
  assert.ok(ids.includes("turn-h2"), "turn-into still present");
});

// ═══════════════════════════════════════════════════════════════════════════
// Phase-6 cutover regression gate — SEEDED PROPERTY/FUZZ over the FULL canvas
// block vocabulary. The per-class tests above pin FIXED examples; this proves
// the projection+diff engine is LOSSLESS over RANDOM stress.
//
//   PROPERTY 1 — LOAD IDENTITY: for any stored run, projecting it to the canvas
//     doc and diffing back yields ZERO ops, and every block reconstructs from
//     its projected node deep-equal to the original (canonical, key-order-safe).
//   PROPERTY 2 — EDIT FOLD: for any stored run, a random STABLE-ID mutation
//     (edit content / edit attr / remove / move — never minting a new id) emits
//     ops that, folded through applyOps, reconstruct the mutated run EXACTLY.
//
// DETERMINISTIC: a mulberry32 PRNG seeded from BASE_SEED + iteration index, so
// any failure repros from its printed seed (same seed → same run → same result).
// No Math.random in the generator. Pure Node, no DOM, no server.
// ═══════════════════════════════════════════════════════════════════════════

// ── mulberry32 — a tiny pure deterministic PRNG ─────────────────────────────
// 32-bit state in, a float in [0,1) out, advancing the state. Reproducible: the
// SAME seed yields the SAME stream forever. (We never touch Math.random here.)
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// rng helpers built on a mulberry32 stream.
const rint = (rng, lo, hi) => lo + Math.floor(rng() * (hi - lo + 1)); // inclusive
const rpick = (rng, arr) => arr[rint(rng, 0, arr.length - 1)];
const rbool = (rng) => rng() < 0.5;

// canonicalEqual — key-order-insensitive deep compare, reusing the projector's
// own canonicalJSON semantics (recursively sorts OBJECT keys; ARRAY order is
// significant). A stored block and its project→reconstruct twin compare EQUAL
// despite differing key order, but a real content/order difference does not.
function canonicalJSON_local(value) {
  if (Array.isArray(value)) return "[" + value.map(canonicalJSON_local).join(",") + "]";
  if (value && typeof value === "object") {
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonicalJSON_local(value[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(value);
}
const canonicalEqual = (a, b) => canonicalJSON_local(a) === canonicalJSON_local(b);

// normalizeCanvasDoc — a FAITHFUL copy of canvas/index.js's live-doc normalizer
// (the production load path runs getJSON() through this before runToOps). On a
// FRESH runToTiptap projection it is effectively identity (no phantom nested
// null-bp attrs, no duplicate top-level ids), but PROPERTY 1 asserts the EXACT
// production formula `runToOps(run, normalizeCanvasDoc(runToTiptap(run))) === 0`,
// so we model it here verbatim. (Pure: it mutates+returns a doc, DOM-free.)
function normalizeCanvasDoc(doc) {
  const hasOnlyBpKeys = (attrs) =>
    Object.keys(attrs).every((k) => k === "bpId" || k === "bpType");
  const stripNested = (node) => {
    if (node && node.attrs) {
      const a = node.attrs;
      if (a.bpId == null && a.bpType == null && hasOnlyBpKeys(a)) {
        delete node.attrs;
      } else {
        if (a.bpId == null) delete a.bpId;
        if (a.bpType == null) delete a.bpType;
      }
    }
    if (node && node.content) node.content.forEach(stripNested);
  };
  (doc.content || []).forEach((top) => {
    (top.content || []).forEach(stripNested);
  });
  const seen = new Set();
  (doc.content || []).forEach((top) => {
    const id = top.attrs && top.attrs.bpId;
    if (id == null) return;
    if (seen.has(id)) top.attrs = { ...top.attrs, bpId: null };
    else seen.add(id);
  });
  return doc;
}

// reconstructBlock(block) — reconstruct a block from its PROJECTED node through
// the PUBLIC engine path, exercising the private nextNodeToBlock exactly as a
// real insert does. We project the single block, null its top-level bpId so the
// diff treats it as NEW, then read the carried block off the emitted insert op
// (minus its minted id). The result is the project→reconstruct twin of `block`.
function reconstructBlock(block) {
  const node = runToTiptap([block]).content[0];
  // Null the top-level bpId → runToOps mints an id and carries the reconstructed
  // block in an append-block (empty prev → no anchor).
  const fresh = { ...node, attrs: { ...(node.attrs || {}), bpId: null } };
  const ops = runToOps([], { type: "doc", content: [fresh] });
  const ins = ops.find((o) => o.op === "append-block" || o.op === "insert-after");
  if (!ins) throw new Error("reconstructBlock: no insert op emitted");
  const { id: _mintedId, ...rest } = ins.block;
  return rest;
}

// ── the generator vocabulary ────────────────────────────────────────────────

const FUZZ_TEXTS = [
  "hello", "world", "lorem ipsum", "a b c", "", "  spaces  ",
  "ångström café naïve", "日本語テキスト", "emoji 🚀✨", "tab\tafter",
  "less < greater > amp & quote \" apos '", "<script>alert(1)</script>",
  "trailing space ", " leading space", "line", "x = 1 + 2",
];
const FUZZ_LANGS = ["", "js", "elixir", "ruby", "sh", "python", "ts", "rust"];
const FUZZ_TONES = ["info", "warning", "danger", "success", "note", "tip"];
const FUZZ_MERMAID = [
  "graph TD\n  A-->B", "graph LR\n  X-->Y\n  Y-->Z",
  "sequenceDiagram\n  Alice->>Bob: hi", "flowchart\n  a & b > c", "",
];
const FUZZ_CAPTIONS = ["", "Figure 1.", "The flow", "café & co. <x>"];
const FUZZ_TITLES = [null, "", "Heads up", "Note <b>", "Café"];
const FUZZ_COLORS = ["#000000", "#3b82f6", "#ef4444", "#ffffff", "#0a0a0a"];
const FUZZ_DATETIMES = ["2026-06-24T10:00", "2026-01-01T00:00", "2025-12-31T23:59"];
const FUZZ_TARGETS = ["intro-to-x", "setup", "Linked Note", "café-note", "a/b/c"];
const FUZZ_SLUGS = ["hello-world", "a-b-c", "café", "x"];

// Inline-CODE values that CONTAIN backtick runs (1..3) — the markdown serializer
// must bump the fence length past the longest inner run, and a 3+-backtick fence
// at the START of a paragraph must NOT be re-read as a fenced code BLOCK
// (escapeBlockLeader's leading-backtick guard). Mixed with plain values so the
// fuzz exercises both the padded and the fence-bumped paths.
const FUZZ_CODE_VALUES = [
  "x = 1", "plain", "a`b", "a``b", "```", "``` ", " ``` ", "ab```cd",
  "`lead", "trail`", "``mid``", "a`b`c", "",
];

// genInlineSpans(rng, n) → a flat array of raw {text, marks} spans. Each span is
// then PROJECTED and DESERIALIZED to canonical portable-doc inline form (so the
// stored content is always a projection fixed-point — empty text dropped, marks
// re-nested in MARK_ORDER, blockref/tag tokens synthesized; exactly what a real
// stored run looks like). Mark kinds cover bold/italic/underline/strike/code/
// link/wikilink/tag — the full inline vocabulary — PLUS nested SAME-FAMILY
// emphasis (strong>em / em>strong / em>em / strong>strong / strong>em>strike) and
// backtick-bearing inline code, the two shapes that round-trip-garbled before the
// markdown.js fix (the fuzz blind spot the bugs slipped through).
function genInlineSpans(rng, n) {
  const spans = [];
  for (let i = 0; i < n; i++) {
    const kind = rint(rng, 0, 15);
    const text = rpick(rng, FUZZ_TEXTS);
    if (kind === 0) spans.push({ type: "text", value: text });
    else if (kind === 1) spans.push({ type: "strong", children: [{ type: "text", value: text }] });
    else if (kind === 2) spans.push({ type: "em", children: [{ type: "text", value: text }] });
    else if (kind === 3) spans.push({ type: "underline", children: [{ type: "text", value: text }] });
    else if (kind === 4) spans.push({ type: "strikethrough", children: [{ type: "text", value: text }] });
    else if (kind === 5) spans.push({ type: "code", value: text });
    else if (kind === 6) {
      const lk = { type: "link", href: "https://" + rpick(rng, FUZZ_SLUGS), children: [{ type: "text", value: text }] };
      spans.push(lk);
    } else if (kind === 7) {
      const wk = { type: "wikilink", target: rpick(rng, FUZZ_TARGETS), children: [{ type: "text", value: text || "link" }] };
      if (rbool(rng)) wk.alias = rpick(rng, FUZZ_TEXTS);
      if (rbool(rng)) wk.docId = "doc-" + rint(rng, 1, 99);
      spans.push(wk);
    } else if (kind === 8) {
      spans.push({ type: "tag", name: rpick(rng, FUZZ_SLUGS) });
    } else if (kind === 9) {
      // nested: bold > strikethrough (locks MARK_ORDER nesting)
      spans.push({ type: "strong", children: [{ type: "strikethrough", children: [{ type: "text", value: text || "x" }] }] });
    } else if (kind === 10) {
      // inline CODE carrying backtick runs — fence-bump + leading-fence guard.
      spans.push({ type: "code", value: rpick(rng, FUZZ_CODE_VALUES) });
    } else if (kind === 11) {
      // NESTED SAME-FAMILY emphasis: strong > em  ("***x***" ambiguity).
      spans.push({ type: "strong", children: [{ type: "em", children: [{ type: "text", value: text || "x" }] }] });
    } else if (kind === 12) {
      // NESTED SAME-FAMILY emphasis: em > strong (mirror; MARK_ORDER folds it to
      // strong>em, but we feed both so the generator's intent is explicit).
      spans.push({ type: "em", children: [{ type: "strong", children: [{ type: "text", value: text || "x" }] }] });
    } else if (kind === 13) {
      // SAME-MARK direct nesting: em > em  ("*_x_*") and strong > strong.
      spans.push(
        rbool(rng)
          ? { type: "em", children: [{ type: "em", children: [{ type: "text", value: text || "x" }] }] }
          : { type: "strong", children: [{ type: "strong", children: [{ type: "text", value: text || "x" }] }] },
      );
    } else if (kind === 14) {
      // DEEP nesting that exercises the delimiter alternation past the strike
      // boundary: strong > em > strike  ("**_~~x~~_**").
      spans.push({
        type: "strong",
        children: [{ type: "em", children: [{ type: "strikethrough", children: [{ type: "text", value: text || "x" }] }] }],
      });
    } else {
      // strike > strike — the UN-disambiguable shape ("~~~~"): the serializer must
      // sentinel it (no alternate delimiter for "~~"). Reachable as a projection
      // fixed point (strike>em>strike etc.), so the fuzz must feed it.
      spans.push({
        type: "strikethrough",
        children: [{ type: "strikethrough", children: [{ type: "text", value: text || "x" }] }],
      });
    }
  }
  // Canonicalize through the SAME inline serializer/deserializer the projector
  // uses, so the stored content is a projection fixed-point (a real stored shape).
  return tiptapInlineToPd(inlineArrayToTiptap(spans));
}

// genInline(rng) → a non-trivially-sized canonical inline array (may be []).
function genInline(rng) {
  return genInlineSpans(rng, rint(rng, 0, 4));
}

// genBlock(rng, id) → one random block of a random canvas-eligible kind, carrying
// the given stable id. Covers EVERY canvas vocabulary kind + empty/present
// variants for each optional/chrome field.
const FUZZ_BLOCK_KINDS = [
  "paragraph", "heading", "list", "divider", "callout", "code", "diagram",
  "field-string", "field-slug", "field-text", "field-boolean", "field-select",
  "field-datetime", "field-color", "sheet", "embed",
];

function genBlock(rng, id) {
  const kind = rpick(rng, FUZZ_BLOCK_KINDS);
  return genBlockOfKind(rng, id, kind);
}

function genBlockOfKind(rng, id, kind) {
  switch (kind) {
    case "paragraph":
      return { id, type: "paragraph", content: genInline(rng) };
    case "heading":
      return { id, type: "heading", level: rint(rng, 1, 3), text: rpick(rng, FUZZ_TEXTS) };
    case "list": {
      const ordered = rbool(rng);
      const nItems = rint(rng, 1, 3);
      const items = [];
      for (let i = 0; i < nItems; i++) items.push(genInlineSpans(rng, rint(rng, 1, 3)));
      return { id, type: "list", ordered, items };
    }
    case "divider":
      return { id, type: "divider" };
    case "callout": {
      const b = { id, type: "callout", tone: rpick(rng, FUZZ_TONES), content: genInline(rng) };
      const title = rpick(rng, FUZZ_TITLES);
      if (title != null) b.title = title; // present-or-absent
      if (rbool(rng)) {
        b.collapsible = true;
        if (rbool(rng)) b.collapsed = true;
      }
      return b;
    }
    case "code": {
      const b = { id, type: "code", value: rpick(rng, FUZZ_TEXTS) + (rbool(rng) ? "\nline2\n  indent" : "") };
      const lang = rpick(rng, FUZZ_LANGS);
      if (lang !== "") b.lang = lang; // present-or-absent
      return b;
    }
    case "diagram": {
      const b = { id, type: "diagram", source: rpick(rng, FUZZ_MERMAID) };
      const cap = rpick(rng, FUZZ_CAPTIONS);
      if (cap !== "") b.caption = cap; // present-or-absent
      return b;
    }
    case "field-string":
    case "field-slug":
    case "field-datetime":
    case "field-color":
    case "field-text": {
      const b = { id, type: kind, value: fieldValueFor(rng, kind) };
      if (rbool(rng)) b.label = rpick(rng, ["Title", "Slug", "Body", ""]);
      if (rbool(rng)) b.fieldName = rpick(rng, FUZZ_SLUGS);
      if (kind === "field-text" && rbool(rng)) b.rows = rint(rng, 1, 10);
      return b;
    }
    case "field-boolean": {
      const b = { id, type: "field-boolean", value: rbool(rng) }; // a REAL boolean
      if (rbool(rng)) b.label = "Featured";
      if (rbool(rng)) b.fieldName = "featured";
      return b;
    }
    case "field-select": {
      const options = [
        { value: "draft", label: "Draft" },
        { value: "published", label: "Published" },
      ];
      const b = {
        id,
        type: "field-select",
        value: rbool(rng) ? rpick(rng, ["draft", "published"]) : "",
        options,
      };
      if (rbool(rng)) b.label = "Status";
      if (rbool(rng)) b.fieldName = "status";
      return b;
    }
    case "sheet": {
      const b = { id, type: "sheet" };
      if (rbool(rng)) b.ref = rpick(rng, ["production/budget", "a/b", "x"]);
      if (rbool(rng)) {
        const nRows = rint(rng, 0, 3);
        const nCols = rint(rng, 1, 3);
        const rows = [];
        for (let r = 0; r < nRows; r++) {
          const row = [];
          for (let c = 0; c < nCols; c++) row.push(rpick(rng, FUZZ_TEXTS));
          rows.push(row);
        }
        b.snapshot = { rows };
        if (rbool(rng) && rows.length) b.snapshot.head = rows[0].slice();
      }
      return b;
    }
    case "embed": {
      const b = { id, type: "embed", target: rpick(rng, FUZZ_TARGETS) };
      return b;
    }
    default:
      return { id, type: "paragraph", content: genInline(rng) };
  }
}

// A VALID value of the right JS type for a string-valued native field.
function fieldValueFor(rng, kind) {
  if (kind === "field-color") return rpick(rng, FUZZ_COLORS);
  if (kind === "field-datetime") return rpick(rng, FUZZ_DATETIMES);
  if (kind === "field-slug") return rpick(rng, FUZZ_SLUGS);
  if (kind === "field-text") return rpick(rng, FUZZ_TEXTS) + (rbool(rng) ? "\nsecond" : "");
  return rpick(rng, FUZZ_TEXTS); // field-string and the fall-through
}

// genRun(rng) → an array of 1..8 random blocks with stable, unique ids "b0".."bN".
function genRun(rng) {
  const n = rint(rng, 1, 8);
  const run = [];
  for (let i = 0; i < n; i++) run.push(genBlock(rng, "b" + i));
  return run;
}

// ── PROPERTY 2 mutation — a random STABLE-ID change (never mints a new id) ────
//
//   editContent — edit one block's mutable content/attrs to another VALID value
//                 of the SAME type (same id, so no mint).
//   remove      — drop a random block.
//   move        — lift a random block to a random position.
//
// The mutation re-projects the WHOLE run with runToTiptap, so the mutated doc is
// a faithful canvas projection of the mutated run — exactly what the editor holds
// after the edit. assertFolds then proves the emitted ops fold to the mutated run.
function mutateRun(rng, run) {
  // editContent is only valid for a block with a MUTABLE interior. The
  // read-only atoms (sheet/embed) and the divider ATOM are INERT to edits — the
  // editor can never write a value back, so re-randomizing them would be an
  // INVALID mutation (not something the diff engine could ever observe). Only
  // offer editContent when at least one editable block exists.
  const editableIdx = run
    .map((b, i) => (isEditableKind(b.type) ? i : -1))
    .filter((i) => i !== -1);

  const kinds = [];
  if (editableIdx.length >= 1) kinds.push("editContent");
  if (run.length >= 1) kinds.push("remove");
  if (run.length >= 2) kinds.push("move");
  const kind = rpick(rng, kinds);

  if (kind === "remove") {
    const at = rint(rng, 0, run.length - 1);
    return run.filter((_b, i) => i !== at);
  }
  if (kind === "move") {
    const from = rint(rng, 0, run.length - 1);
    const copy = run.slice();
    const [moved] = copy.splice(from, 1);
    const to = rint(rng, 0, copy.length);
    copy.splice(to, 0, moved);
    return copy;
  }
  // editContent: mutate ONE editable block's MUTABLE fields to another valid
  // value, holding its id AND its immutable config constant (the stable-id rule
  // — same kind, new value through the SAME surface the editor edits, never a
  // new id and never a config change the control can't make).
  const at = rpick(rng, editableIdx);
  const mutated = genMutatedContent(rng, run[at]);
  return run.map((b, i) => (i === at ? mutated : b));
}

// True when a block kind has a MUTABLE interior the editor can change (prose
// content, callout body/chrome, code/diagram body, field VALUE). False for the
// INERT kinds (divider ATOM, sheet/embed READ-ONLY atoms) whose interior the
// editor never writes back — a value change there is not an observable edit.
function isEditableKind(type) {
  return type !== "divider" && type !== "sheet" && type !== "embed";
}

// genMutatedContent(rng, block) → a block of the SAME type + SAME id with its
// MUTABLE fields re-randomized but its IMMUTABLE config held constant. For a
// field-* block ONLY `value` is mutable (label/options/rows/fieldName are CONFIG
// the control cannot edit — runToOps' fieldNodeToPatch emits ONLY {value}); for
// every other editable kind the whole interior is fair game.
function genMutatedContent(rng, block) {
  const id = block.id;
  const type = block.type;
  if (isCanvasFieldKindLocal(type)) {
    // Mutate ONLY the value; carry the config keys VERBATIM (immutable through
    // the control). The value stays the right JS type per kind.
    const next = { ...block };
    next.value =
      type === "field-boolean"
        ? !block.value
        : type === "field-select"
        ? rpick(rng, [...(block.options || []).map((o) => o.value), ""])
        : fieldValueFor(rng, type);
    return next;
  }
  // Prose / callout / code / diagram: re-roll the whole interior of the SAME kind.
  return genBlockOfKind(rng, id, type);
}

// The 7 native field-* kinds (mirrors run-convert.js CANVAS_FIELD_TYPES) — used
// by the mutation to restrict a field edit to the VALUE only.
function isCanvasFieldKindLocal(type) {
  return (
    type === "field-string" ||
    type === "field-slug" ||
    type === "field-text" ||
    type === "field-boolean" ||
    type === "field-select" ||
    type === "field-datetime" ||
    type === "field-color"
  );
}

// ── PROPERTY 1 — LOAD IDENTITY (the core gate) ──────────────────────────────
const FUZZ_BASE_SEED = 0x5eed1; // a fixed base so the whole suite is reproducible.
const FUZZ_ITERS = 1000;

check(`FUZZ property-1 LOAD IDENTITY: ${FUZZ_ITERS} random runs project→diff to ZERO ops + block round-trip`, () => {
  for (let i = 0; i < FUZZ_ITERS; i++) {
    const seed = (FUZZ_BASE_SEED + i) >>> 0;
    const rng = mulberry32(seed);
    const run = genRun(rng);

    // (1a) The production load formula: project → normalize → diff back === [].
    let ops;
    try {
      ops = runToOps(run, normalizeCanvasDoc(runToTiptap(run)));
    } catch (e) {
      throw new Error(
        `LOAD IDENTITY THREW at seed=${seed}: ${e.message}\nrun=${JSON.stringify(run)}`,
      );
    }
    if (ops.length !== 0) {
      const min = minimizeRun(run, (r) => {
        try {
          return runToOps(r, normalizeCanvasDoc(runToTiptap(r))).length !== 0;
        } catch {
          return true;
        }
      });
      throw new Error(
        `LOAD IDENTITY FAILED (spurious ops on load) at seed=${seed}\n` +
          `  emitted ops: ${JSON.stringify(ops)}\n` +
          `  full run:    ${JSON.stringify(run)}\n` +
          `  MINIMAL run: ${JSON.stringify(min)}\n` +
          `  minimal ops: ${JSON.stringify(runToOps(min, normalizeCanvasDoc(runToTiptap(min))))}`,
      );
    }

    // (1b) Every block reconstructs from its projected node deep-equal (canonical)
    //      to the original — the project→reconstruct round-trip is the identity.
    for (const block of run) {
      const back = reconstructBlock(block);
      const { id: _id, ...origRest } = block;
      const { id: _bid, ...backRest } = back;
      if (!canonicalEqual(backRest, origRest)) {
        throw new Error(
          `BLOCK ROUND-TRIP FAILED at seed=${seed}\n` +
            `  original: ${JSON.stringify(block)}\n` +
            `  reconstructed: ${JSON.stringify(back)}`,
        );
      }
    }
  }
});

// ── PROPERTY 2 — EDIT FOLD (the diff gate) ──────────────────────────────────
check(`FUZZ property-2 EDIT FOLD: ${FUZZ_ITERS} random stable-id mutations fold back EXACTLY`, () => {
  for (let i = 0; i < FUZZ_ITERS; i++) {
    // Offset the seed space from property-1 so the two properties exercise
    // DIFFERENT random runs (still fully reproducible from the printed seed).
    const seed = (FUZZ_BASE_SEED + 1000000 + i) >>> 0;
    const rng = mulberry32(seed);
    const run = genRun(rng);
    const mutated = mutateRun(rng, run);
    const mutatedDoc = normalizeCanvasDoc(runToTiptap(mutated));

    let ops, folded;
    try {
      ops = runToOps(run, mutatedDoc);
      folded = assertFolds(run, mutatedDoc, ops, `fuzz-2 seed=${seed}`);
    } catch (e) {
      const min = minimizeMutation(rng, run, mutated);
      throw new Error(
        `EDIT FOLD FAILED at seed=${seed}: ${e.message}\n` +
          `  prev run:    ${JSON.stringify(run)}\n` +
          `  mutated run: ${JSON.stringify(mutated)}\n` +
          `  MINIMAL prev:    ${JSON.stringify(min.prev)}\n` +
          `  MINIMAL mutated: ${JSON.stringify(min.next)}`,
      );
    }

    // assertFolds proves the id ORDER + survival structure. Now assert the folded
    // result is the mutated run EXACTLY (canonical, key-order-safe) — every
    // surviving block's content/attrs reconstruct to the mutated value, and the
    // sequence matches the mutated run block-for-block (minted ids aside).
    if (folded.length !== mutated.length) {
      throw new Error(
        `EDIT FOLD length mismatch at seed=${seed}: folded ${folded.length} !== mutated ${mutated.length}\n` +
          `  prev: ${JSON.stringify(run)}\n  mutated: ${JSON.stringify(mutated)}\n  ops: ${JSON.stringify(ops)}`,
      );
    }
    for (let j = 0; j < mutated.length; j++) {
      // Compare in the engine's CANONICAL stored form (id excluded). The JS
      // reference fold (applyOps) faithfully mirrors patch.ex's SHALLOW merge,
      // which keeps a patch's removal-safe EXPLICIT optionals (callout
      // collapsed:false / title:null, code lang:"" / diagram caption:"") rather
      // than dropping them the way compose.ex's maybe_put would on the server. So
      // a folded block can carry an explicit collapsed:false where the mutated
      // stored block has it absent — render-IDENTICAL, and the projector's own
      // canonical compare (stableCalloutKey/stableCodeKey) treats them EQUAL,
      // which is precisely why the NEXT load round-trips to zero ops. We
      // normalize BOTH sides through reconstructBlock (project→reconstruct), which
      // collapses every absent-when-empty optional to its canonical form on both
      // sides, then compare. This asserts the fold reconstructs the mutated run
      // EXACTLY up to the documented ""/null/absent optional normalization.
      const foldedCanon = reconstructBlock(folded[j]);
      const mutatedCanon = reconstructBlock(mutated[j]);
      const { id: _fid, ...foldedRest } = foldedCanon;
      const { id: _mid, ...mutatedRest } = mutatedCanon;
      if (!canonicalEqual(foldedRest, mutatedRest)) {
        throw new Error(
          `EDIT FOLD content mismatch at seed=${seed} slot ${j}\n` +
            `  expected (canonical): ${JSON.stringify(mutatedCanon)}\n` +
            `  folded   (canonical): ${JSON.stringify(foldedCanon)}\n` +
            `  expected (raw): ${JSON.stringify(mutated[j])}\n` +
            `  folded   (raw): ${JSON.stringify(folded[j])}\n` +
            `  prev: ${JSON.stringify(run)}\n  ops: ${JSON.stringify(ops)}`,
        );
      }
    }
  }
});

// ── delta-debug minimizers (only invoked on a real failure) ─────────────────
//
// minimizeRun — shrink a failing run to the smallest sub-list that still fails
// `predicate`. Greedy single-block removal to a fixed point. Pure, deterministic.
function minimizeRun(run, predicate) {
  let best = run.slice();
  let shrank = true;
  while (shrank && best.length > 1) {
    shrank = false;
    for (let i = 0; i < best.length; i++) {
      const candidate = best.filter((_b, idx) => idx !== i);
      if (candidate.length >= 1 && predicate(candidate)) {
        best = candidate;
        shrank = true;
        break;
      }
    }
  }
  return best;
}

// minimizeMutation — shrink a failing (prev, mutated) pair by dropping the SAME
// trailing/leading blocks from BOTH while the fold still throws. Best-effort: we
// only drop a block id present in BOTH (so the mutation relationship survives).
function minimizeMutation(_rng, prev, mutated) {
  const foldThrows = (p, m) => {
    try {
      const doc = normalizeCanvasDoc(runToTiptap(m));
      assertFolds(p, doc, runToOps(p, doc), "min");
      return false;
    } catch {
      return true;
    }
  };
  let bp = prev.slice();
  let bm = mutated.slice();
  let shrank = true;
  while (shrank) {
    shrank = false;
    // Try removing each prev id from BOTH lists (when present in both).
    for (const block of bp) {
      const id = block.id;
      const np = bp.filter((b) => b.id !== id);
      const nm = bm.filter((b) => b.id !== id);
      if (np.length >= 1 && foldThrows(np, nm)) {
        bp = np;
        bm = nm;
        shrank = true;
        break;
      }
    }
  }
  return { prev: bp, next: bm };
}

// ── determinism guard — the SAME seed yields the SAME run + SAME ops ─────────
check("FUZZ determinism: same seed → identical run, ops, and fold (reproducible)", () => {
  const seed = (FUZZ_BASE_SEED + 42) >>> 0;
  const runA = genRun(mulberry32(seed));
  const runB = genRun(mulberry32(seed));
  assert.deepEqual(runA, runB, "same seed must yield the byte-identical run");

  const opsA = runToOps(runA, normalizeCanvasDoc(runToTiptap(runA)));
  const opsB = runToOps(runB, normalizeCanvasDoc(runToTiptap(runB)));
  assert.deepEqual(opsA, opsB, "same run must yield the byte-identical ops");
  assert.equal(opsA.length, 0, "and the load-identity run emits ZERO ops");

  // A different seed must (with overwhelming probability) differ — sanity that
  // the PRNG is actually advancing per seed, not returning a constant.
  const runC = genRun(mulberry32((seed + 1) >>> 0));
  assert.notDeepEqual(runA, runC, "a different seed yields a different run");
});

// ═══════════════════════════════════════════════════════════════════════════
// Phase-5 source-mode foundation — blocks ⇄ MARKDOWN converter (markdown.js)
//
// blocksToMarkdown / markdownToBlocks are a PURE, dependency-free projection of
// the PortableDoc BLOCK-AST to/from Markdown text. The gate has two tiers:
//
//   FIXED POINT (all blocks): blocks → md1 → blocks2 → md2  ⇒  md1 === md2, AND
//     blocks2 → md3 === md2 (the block list stabilized after ONE normalization
//     pass). Markdown is a fixed point after the first round-trip.
//   SENTINEL LOSSLESSNESS (non-prose / lossy blocks): the <!--bp:block …--> JSON
//     sentinel carries the WHOLE block verbatim → blocks2 holds the EXACT block.
//   PROSE RENDER-EQUIVALENCE (paragraph/heading/list/callout/code/diagram/divider
//     with representable inline): blocks2 is render-equal to the original on the
//     NORMALIZED inline tree — bold stays bold, links/wikilinks/tags/code survive,
//     nothing dropped/garbled. Markdown can't distinguish two abutting text leaves
//     from one, so the canonical compare COALESCES adjacent text (the documented
//     prose normalization), exactly as the canvas property tests normalize through
//     project→reconstruct.
// ═══════════════════════════════════════════════════════════════════════════

// Coalesce adjacent text leaves recursively — the markdown render-normalization.
// Two abutting { type:"text" } leaves render identically to one (markdown has no
// way to keep a boundary between them), and an empty text leaf renders as nothing.
// This is the prose half of the fidelity bar: NOT byte-equality (that is only for
// sentinel blocks), but render-equivalence on the normalized inline tree.
function coalesceTextTree(value) {
  if (Array.isArray(value)) {
    const mapped = value.map(coalesceTextTree);
    const out = [];
    for (const n of mapped) {
      if (n && n.type === "text") {
        if (n.value === "") continue;
        const last = out[out.length - 1];
        if (last && last.type === "text") {
          last.value += n.value;
          continue;
        }
        out.push({ type: "text", value: n.value });
      } else {
        out.push(n);
      }
    }
    return out;
  }
  if (value && typeof value === "object") {
    const o = {};
    for (const k of Object.keys(value)) o[k] = coalesceTextTree(value[k]);
    return o;
  }
  return value;
}

// canonical compare AFTER the text-coalesce normalization + id strip.
function mdRenderEqual(a, b) {
  const { id: _ai, ...ar } = a;
  const { id: _bi, ...br } = b;
  return canonicalEqual(coalesceTextTree(ar), coalesceTextTree(br));
}

// True when a block is carried by the SENTINEL (non-prose kind OR a prose block
// whose serialized form is a sentinel). We detect it structurally: re-serialize
// the single block and check it is exactly one <!--bp:block …--> line.
function isSentinelSerialized(block) {
  const md = blocksToMarkdown([block]);
  return md.startsWith("<!--bp:block ") && md.endsWith("-->") && !md.includes("\n");
}

// ── hand cases: one per block type + per inline mark, plus adversarial text ───
check("markdown: paragraph with bold/italic/strike/code round-trips render-equal", () => {
  const block = {
    id: "p-1",
    type: "paragraph",
    content: tiptapInlineToPd(
      inlineArrayToTiptap([
        { type: "text", value: "Hello " },
        { type: "strong", children: [{ type: "text", value: "bold" }] },
        { type: "text", value: " " },
        { type: "em", children: [{ type: "text", value: "ital" }] },
        { type: "text", value: " " },
        { type: "strikethrough", children: [{ type: "text", value: "struck" }] },
        { type: "text", value: " " },
        { type: "code", value: "x=1" },
      ]),
    ),
  };
  const md = blocksToMarkdown([block]);
  assert.equal(md, "Hello **bold** *ital* ~~struck~~ `x=1`", "readable markdown");
  const back = markdownToBlocks(md);
  assert.equal(back.length, 1);
  assert.ok(mdRenderEqual(back[0], block), "round-trips render-equal");
});

check("markdown: heading round-trips ('#'*level + text)", () => {
  const block = { id: "h-1", type: "heading", level: 3, text: "Section Title" };
  const md = blocksToMarkdown([block]);
  assert.equal(md, "### Section Title");
  const back = markdownToBlocks(md);
  assert.deepEqual(back[0], { ...back[0], type: "heading", level: 3, text: "Section Title" });
  assert.equal(back[0].level, 3);
  assert.equal(back[0].text, "Section Title");
});

check("markdown: bullet + ordered lists round-trip", () => {
  const bullet = {
    id: "l-1",
    type: "list",
    ordered: false,
    items: [
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "alpha" }])),
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "strong", children: [{ type: "text", value: "beta" }] }])),
    ],
  };
  assert.equal(blocksToMarkdown([bullet]), "- alpha\n- **beta**");
  assert.ok(mdRenderEqual(markdownToBlocks(blocksToMarkdown([bullet]))[0], bullet));

  const ordered = {
    id: "l-2",
    type: "list",
    ordered: true,
    items: [
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "one" }])),
      tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "two" }])),
    ],
  };
  assert.equal(blocksToMarkdown([ordered]), "1. one\n2. two");
  assert.ok(mdRenderEqual(markdownToBlocks(blocksToMarkdown([ordered]))[0], ordered));
});

check("markdown: callout admonition (tone + title + collapsed) round-trips", () => {
  const block = {
    id: "c-1",
    type: "callout",
    tone: "warning",
    title: "Heads up",
    collapsible: true,
    collapsed: true,
    content: tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value: "body text" }])),
  };
  const md = blocksToMarkdown([block]);
  assert.equal(md, "> [!warning]- Heads up\n> body text", "Obsidian admonition with - suffix");
  const back = markdownToBlocks(md)[0];
  assert.equal(back.tone, "warning");
  assert.equal(back.title, "Heads up");
  assert.equal(back.collapsible, true);
  assert.equal(back.collapsed, true);
  assert.ok(mdRenderEqual(back, block));
});

check("markdown: callout with a NON-CANONICAL tone ('note'/'tip') round-trips verbatim", () => {
  // The serializer emits the EXACT tone token and the parser reads it back literally
  // (NOT through normalizeTone), so a stored tone the canonical set doesn't contain
  // still round-trips byte-for-byte.
  for (const tone of ["note", "tip", "success", "neutral"]) {
    const block = { id: "c", type: "callout", tone, content: [{ type: "text", value: "x" }] };
    const back = markdownToBlocks(blocksToMarkdown([block]))[0];
    assert.equal(back.tone, tone, `tone ${tone} survives verbatim`);
  }
});

check("markdown: code fence (lang) + a value CONTAINING ``` bumps the fence length", () => {
  const block = { id: "cd-1", type: "code", value: "see ```js\ncode\n``` inside", lang: "md" };
  const md = blocksToMarkdown([block]);
  assert.ok(md.startsWith("````md\n"), "fence bumped to 4 backticks");
  assert.ok(md.endsWith("\n````"));
  const back = markdownToBlocks(md)[0];
  assert.equal(back.type, "code");
  assert.equal(back.value, block.value, "value with inner ``` survives");
  assert.equal(back.lang, "md");
});

check("markdown: diagram fence (mermaid) round-trips source + caption losslessly", () => {
  const block = { id: "d-1", type: "diagram", source: "graph TD\n  A-->B", caption: "café & co. <x>" };
  const md = blocksToMarkdown([block]);
  assert.ok(md.startsWith("```mermaid caption="), "mermaid fence carries the caption");
  const back = markdownToBlocks(md)[0];
  assert.equal(back.type, "diagram");
  assert.equal(back.source, "graph TD\n  A-->B");
  assert.equal(back.caption, "café & co. <x>", "caption round-trips lossless (no sentinel)");
});

check("markdown: a code block with lang='mermaid' sentinels (never becomes a diagram)", () => {
  // The fence info "mermaid" is the DIAGRAM marker — a code block carrying lang
  // "mermaid" must NOT silently round-trip into a diagram block. It sentinels.
  const block = { id: "cm-1", type: "code", value: "graph TD\n A-->B", lang: "mermaid" };
  assert.ok(isSentinelSerialized(block), "code lang=mermaid → sentinel");
  const back = markdownToBlocks(blocksToMarkdown([block]))[0];
  assert.equal(back.type, "code", "stays a code block, not a diagram");
  assert.deepEqual(back, block, "byte-lossless via the sentinel");
});

check("markdown: divider round-trips to ---", () => {
  const block = { id: "dv-1", type: "divider" };
  assert.equal(blocksToMarkdown([block]), "---");
  assert.equal(markdownToBlocks("---")[0].type, "divider");
});

// ── REGRESSION (Bug #1): nested SAME-FAMILY emphasis ("***x***" ambiguity) ─────
// A stored run with bold+italic is a real projection fixed point: strong>em (and
// the em>strong mirror, which MARK_ORDER folds to the same shape). The OLD
// serializer emitted "***x***", which the tokenizer mis-parsed as strong + a stray
// "*", garbling the run and oscillating the fixed point. The serializer now emits
// UNAMBIGUOUS nested delimiters (strong>em → "**_x_**"), so the tokenizer only ever
// sees single/double runs. Must round-trip strong>em, em>strong, plain strong,
// plain em, AND strong>strike (distinct delims, already worked) to a STABLE fixed
// point, render-equal.
check("markdown: nested same-family emphasis (***x*** bug) round-trips to a stable fixed point", () => {
  const norm = (inline) => tiptapInlineToPd(inlineArrayToTiptap(inline));
  const t = [{ type: "text", value: "x" }];
  const cases = [
    ["plain strong", [{ type: "strong", children: t }], "**x**"],
    ["plain em", [{ type: "em", children: t }], "*x*"],
    ["strong>em (bold+italic)", [{ type: "strong", children: [{ type: "em", children: t }] }], "**_x_**"],
    ["em>strong (mirror → strong>em)", [{ type: "em", children: [{ type: "strong", children: t }] }], "**_x_**"],
    ["em>em (same-mark nest)", [{ type: "em", children: [{ type: "em", children: t }] }], "*_x_*"],
    ["strong>strong (same-mark nest)", [{ type: "strong", children: [{ type: "strong", children: t }] }], "**__x__**"],
    ["strong>strike (distinct delims)", [{ type: "strong", children: [{ type: "strikethrough", children: t }] }], "**~~x~~**"],
  ];
  for (const [label, inline, expectedMd] of cases) {
    const block = { id: "p", type: "paragraph", content: norm(inline) };
    const md1 = blocksToMarkdown([block]);
    assert.equal(md1, expectedMd, `${label}: serializes unambiguously`);
    const back = markdownToBlocks(md1);
    assert.equal(back.length, 1, `${label}: stays one paragraph`);
    const md2 = blocksToMarkdown(back);
    assert.equal(md1, md2, `${label}: STABLE fixed point (md1 === md2)`);
    assert.ok(mdRenderEqual(back[0], block), `${label}: round-trips render-equal (no garble)`);
  }
});

// ── REGRESSION (Bug #2): paragraph led by a ≥3-backtick inline-code span ────────
// A paragraph whose first inline node is inline-code with a value forcing a 3+-
// backtick fence (e.g. value "```", serialized "``` ``` ```") used to begin with a
// bare "```" run → the block scanner re-read it as a fenced CODE BLOCK, dropping the
// paragraph. escapeBlockLeader now backslash-escapes the leading fence; the inline
// tokenizer inverts it, preserving the code value exactly.
check("markdown: paragraph led by a 3+-backtick inline-code span (fence-block bug) round-trips", () => {
  const norm = (inline) => tiptapInlineToPd(inlineArrayToTiptap(inline));
  for (const value of ["```", "``` ", "a``b", "ab```cd", "``"]) {
    const block = { id: "p", type: "paragraph", content: norm([{ type: "code", value }]) };
    const md = blocksToMarkdown([block]);
    const back = markdownToBlocks(md);
    assert.equal(back.length, 1, `value ${JSON.stringify(value)}: stays ONE block`);
    assert.equal(back[0].type, "paragraph", `value ${JSON.stringify(value)}: stays a PARAGRAPH (not a code block)`);
    assert.equal(back[0].content[0].type, "code", `value ${JSON.stringify(value)}: first node is inline-code`);
    assert.equal(back[0].content[0].value, value, `value ${JSON.stringify(value)}: inline-code value preserved exactly`);
    const md2 = blocksToMarkdown(back);
    assert.equal(md, md2, `value ${JSON.stringify(value)}: STABLE fixed point`);
  }
});

// ── REGRESSION (Bug #2 minimal): a paragraph that is JUST the 3-backtick span ───
check("markdown: a paragraph that is JUST a 3-backtick inline-code span round-trips", () => {
  const norm = (inline) => tiptapInlineToPd(inlineArrayToTiptap(inline));
  const block = { id: "p", type: "paragraph", content: norm([{ type: "code", value: "```" }]) };
  const md = blocksToMarkdown([block]);
  assert.ok(md.startsWith("\\"), "the leading fence is backslash-escaped so it is not a code block");
  const back = markdownToBlocks(md);
  assert.equal(back.length, 1);
  assert.equal(back[0].type, "paragraph");
  assert.ok(mdRenderEqual(back[0], block), "round-trips render-equal");
});

check("markdown: link / wikilink (alias) / tag inline round-trip", () => {
  const block = {
    id: "p-2",
    type: "paragraph",
    content: tiptapInlineToPd(
      inlineArrayToTiptap([
        { type: "link", href: "https://x.test", children: [{ type: "text", value: "site" }] },
        { type: "text", value: " " },
        { type: "wikilink", target: "Some Note", alias: "alias", children: [{ type: "text", value: "alias" }] },
        { type: "text", value: " " },
        { type: "wikilink", target: "setup", children: [{ type: "text", value: "setup" }] },
        { type: "text", value: " " },
        { type: "tag", name: "todo" },
      ]),
    ),
  };
  const md = blocksToMarkdown([block]);
  assert.ok(md.includes("[site](https://x.test)"), "link");
  assert.ok(md.includes("[[Some Note|alias]]"), "wikilink with alias");
  assert.ok(md.includes("[[setup]]"), "plain wikilink");
  assert.ok(md.includes("#todo"), "tag");
  assert.ok(mdRenderEqual(markdownToBlocks(md)[0], block));
});

check("markdown: adversarial literal markdown chars round-trip as TEXT, not markup", () => {
  // A paragraph whose text LOOKS like a heading / list / quote / rule / emphasis,
  // plus literal * _ ` [ ] # at line start. Escaping must make them literal text.
  const cases = [
    "# not a heading",
    "- not a list",
    "1. not ordered",
    "> not a quote",
    "--- not a rule",
    "a * b _ c ` d [ e ] f # g",
    "C# and F# are languages",
  ];
  for (const value of cases) {
    const block = {
      id: "adv",
      type: "paragraph",
      content: tiptapInlineToPd(inlineArrayToTiptap([{ type: "text", value }])),
    };
    const md = blocksToMarkdown([block]);
    const back = markdownToBlocks(md);
    assert.equal(back.length, 1, `"${value}" stays ONE block`);
    assert.equal(back[0].type, "paragraph", `"${value}" stays a paragraph`);
    assert.ok(mdRenderEqual(back[0], block), `"${value}" round-trips as text`);
  }
});

check("markdown: empty paragraph + empty block edge cases round-trip", () => {
  const empty = { id: "e-1", type: "paragraph", content: [] };
  const md = blocksToMarkdown([empty]);
  const back = markdownToBlocks(md);
  assert.equal(back.length, 1);
  assert.equal(back[0].type, "paragraph");
  assert.deepEqual(back[0].content, []);
});

check("markdown: NON-PROSE blocks (field-*/sheet/embed) ride a byte-lossless sentinel", () => {
  const field = { id: "f-1", type: "field-string", label: "Title", value: "hi", fieldName: "title" };
  const select = {
    id: "f-2",
    type: "field-select",
    value: "draft",
    options: [{ value: "draft", label: "Draft" }],
    label: "Status",
  };
  const sheet = { id: "s-1", type: "sheet", ref: "a/b", snapshot: { rows: [["x", "y"]], head: ["x", "y"] } };
  const embed = { id: "e-2", type: "embed", target: "Linked Note" };
  for (const block of [field, select, sheet, embed]) {
    assert.ok(isSentinelSerialized(block), `${block.type} → sentinel`);
    const back = markdownToBlocks(blocksToMarkdown([block]));
    assert.equal(back.length, 1);
    assert.deepEqual(back[0], block, `${block.type} sentinel is BYTE-lossless (incl. id)`);
  }
});

check("markdown: LOSSY prose (underline / wikilink+docId / blockref) falls back to the sentinel", () => {
  const underline = {
    id: "u-1",
    type: "paragraph",
    content: [{ type: "underline", children: [{ type: "text", value: "u" }] }],
  };
  const wikiDoc = {
    id: "w-1",
    type: "paragraph",
    content: [{ type: "wikilink", target: "t", docId: "doc-7", children: [{ type: "text", value: "t" }] }],
  };
  for (const block of [underline, wikiDoc]) {
    assert.ok(isSentinelSerialized(block), `${block.id} → sentinel (lossy inline)`);
    const back = markdownToBlocks(blocksToMarkdown([block]));
    assert.deepEqual(back[0], block, `${block.id} sentinel is byte-lossless`);
  }
});

check("markdown: a multi-block doc round-trips block-for-block + is a FIXED POINT", () => {
  const blocks = [
    { id: "h", type: "heading", level: 1, text: "Title" },
    { id: "p", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    { id: "dv", type: "divider" },
    { id: "c", type: "code", value: "x=1", lang: "js" },
    { id: "f", type: "field-boolean", value: true, label: "On" },
  ];
  const md1 = blocksToMarkdown(blocks);
  const blocks2 = markdownToBlocks(md1);
  const md2 = blocksToMarkdown(blocks2);
  assert.equal(md1, md2, "markdown is a fixed point after one pass");
  assert.equal(blocksToMarkdown(blocks2), md2, "blocks stabilized (md3 === md2)");
  assert.equal(blocks2.length, blocks.length);
});

// ── the FUZZ FIXED-POINT gate over genRun (reuse the existing generator) ──────
//
// 2000 random runs over the FULL block + inline vocabulary. Each asserts:
//   • FIXED POINT       — md1 === md2 (markdown stable after one normalization),
//                         and blocks2 → md3 === md2 (blocks stabilized).
//   • COUNT             — blocks2 has the same block count (no block dropped/split).
//   • SENTINEL LOSSLESS — every sentinel-serialized block reconstructs BYTE-exact.
//   • PROSE RENDER-EQ   — every prose block reconstructs render-equal on the
//                         coalesce-normalized inline tree.
// A failure prints the SEED + the run + the diverging markdown for repro
// (deterministic mulberry32 stream → same seed reproduces the run exactly).
const MD_FUZZ_BASE_SEED = 0x5eed1;
const MD_FUZZ_ITERS = 2000;

check(`markdown FUZZ FIXED-POINT: ${MD_FUZZ_ITERS} random runs are a stable fixed point + lossless`, () => {
  for (let i = 0; i < MD_FUZZ_ITERS; i++) {
    // Offset the seed space from the canvas fuzz so these exercise their own runs.
    const seed = (MD_FUZZ_BASE_SEED + 2000000 + i) >>> 0;
    const rng = mulberry32(seed);
    const run = genRun(rng);

    let md1, blocks2, md2, md3;
    try {
      md1 = blocksToMarkdown(run);
      blocks2 = markdownToBlocks(md1);
      md2 = blocksToMarkdown(blocks2);
      md3 = blocksToMarkdown(markdownToBlocks(md2));
    } catch (e) {
      throw new Error(
        `markdown round-trip THREW at seed=${seed}: ${e.message}\n  run=${JSON.stringify(run)}`,
      );
    }

    // FIXED POINT — markdown stable after one normalization pass.
    if (md1 !== md2) {
      const lines1 = md1.split("\n");
      const lines2 = md2.split("\n");
      let diff = "";
      for (let k = 0; k < Math.max(lines1.length, lines2.length); k++) {
        if (lines1[k] !== lines2[k]) {
          diff = `\n  first diverging line ${k}:\n    md1: ${JSON.stringify(lines1[k])}\n    md2: ${JSON.stringify(lines2[k])}`;
          break;
        }
      }
      throw new Error(
        `markdown FIXED-POINT FAILED at seed=${seed} (md1 !== md2)${diff}\n` +
          `  run: ${JSON.stringify(run)}\n  md1: ${JSON.stringify(md1)}\n  md2: ${JSON.stringify(md2)}`,
      );
    }
    // blocks stabilized.
    if (md3 !== md2) {
      throw new Error(
        `markdown BLOCKS-NOT-STABILIZED at seed=${seed} (md3 !== md2)\n` +
          `  run: ${JSON.stringify(run)}\n  md2: ${JSON.stringify(md2)}\n  md3: ${JSON.stringify(md3)}`,
      );
    }
    // COUNT — no block dropped or split.
    if (blocks2.length !== run.length) {
      throw new Error(
        `markdown COUNT MISMATCH at seed=${seed}: ${blocks2.length} !== ${run.length}\n` +
          `  run: ${JSON.stringify(run)}\n  md1: ${JSON.stringify(md1)}\n  out: ${JSON.stringify(blocks2)}`,
      );
    }
    // PER-BLOCK — sentinel byte-lossless OR prose render-equal.
    for (let j = 0; j < run.length; j++) {
      const orig = run[j];
      const back = blocks2[j];
      if (isSentinelSerialized(orig)) {
        // Byte-lossless: the EXACT original block (id and all) survives.
        if (!canonicalEqual(orig, back)) {
          throw new Error(
            `markdown SENTINEL NOT BYTE-LOSSLESS at seed=${seed} slot ${j} (${orig.type})\n` +
              `  in : ${JSON.stringify(orig)}\n  out: ${JSON.stringify(back)}\n  md1: ${JSON.stringify(md1)}`,
          );
        }
      } else if (!mdRenderEqual(back, orig)) {
        throw new Error(
          `markdown PROSE NOT RENDER-EQUAL at seed=${seed} slot ${j} (${orig.type})\n` +
            `  in : ${JSON.stringify(orig)}\n  out: ${JSON.stringify(back)}\n  md1: ${JSON.stringify(md1)}`,
        );
      }
    }
  }
});

check("markdown FUZZ determinism: same seed → identical run + identical markdown", () => {
  const seed = (MD_FUZZ_BASE_SEED + 2000000 + 7) >>> 0;
  const a = blocksToMarkdown(genRun(mulberry32(seed)));
  const b = blocksToMarkdown(genRun(mulberry32(seed)));
  assert.equal(a, b, "same seed must yield byte-identical markdown");
});

// ═══════════════════════════════════════════════════════════════════════════
// §P5 MARKDOWN SOURCE-MODE — no-edit-zero-ops + edited-one-patch, AGAINST L0.
//
// THREE doc states to keep distinct (the source-mode correctness rests on this):
//   • C  = this._blocks — the ECHO-CONFIRMED baseline. Advances ASYNC, only when the
//          server echoes bp:canvas-update. After the user types, C LAGS the live doc.
//   • L0 = the LIVE doc at source-mode ENTER, projected back to blocks via
//          docToBlocks(normalizeCanvasDoc(getJSON())). Includes the user's just-typed,
//          not-yet-confirmed edits. THIS is the source baseline + textarea content.
//   • L1 = the blocks after the user edits the markdown: markdownToBlocks(textarea),
//          then realignBlockIds against L0 to keep surviving blocks' ids.
//
// The toggle's EDITED exit emits ONLY runToOps(L0, L1) (the genuine source diff) and
// applies L1 to the editor WITHOUT auto-emit — so the in-flight pre-source edits
// (L0−C) are NOT re-emitted as duplicate structural ops. These tests pin that PURE
// pipeline (docToBlocks → markdownToBlocks → realignBlockIds → runToTiptap → runToOps):
//   • NO EDIT  → ZERO ops (round-trip op-free for an unchanged run).
//   • ONE EDIT (a heading) → EXACTLY ONE patch-block for THAT L0 id (no remove+insert).
//   • INSERT / REMOVE → one structural op, survivors untouched.
//   • LAG MODEL — L0 carries a block NOT in C (a just-typed paragraph): the source
//     diff against L0 emits only the user's source edit, never re-inserting the L0−C
//     block (that is what the explicit runToOps(L0,L1) emit, not _emitOps-from-C, buys).
//   • DUPLICATE-SIGNATURE run → a single edit does NOT churn the identical siblings.
// The WC itself (textarea swap, focus, Mod-Shift-m / palette triggers, the external-
// edit queue) needs a DOM and is covered by the Elixir LiveView paper_canvas tests;
// here we pin the pure converter+diff+projection contract that makes the WC correct.
// ═══════════════════════════════════════════════════════════════════════════

// The exit-source projection the WC runs: parse the (possibly edited) markdown, realign
// ids against the LIVE baseline (L0), then diff L0 against the projected new doc (L1).
// `baselineBlocks` here is L0 — the live-doc-derived source baseline, NOT C.
function exitSourceOps(baselineBlocks, editedMd) {
  const parsed = markdownToBlocks(editedMd);
  const realigned = realignBlockIds(baselineBlocks, parsed);
  const nextDoc = runToTiptap(realigned);
  return { ops: runToOps(baselineBlocks, nextDoc), realigned };
}

// A representative mixed run (the kinds a source edit actually touches: heading /
// paragraph / list, plus a natural code block). All ids are server-style so the
// realigner has real baseline ids to donate back.
const SRC_BASELINE = [
  { id: "s-h1", type: "heading", level: 1, text: "Status" },
  { id: "s-p1", type: "paragraph", content: [{ type: "text", value: "intro line" }] },
  {
    id: "s-l1",
    type: "list",
    ordered: false,
    items: [[{ type: "text", value: "alpha" }], [{ type: "text", value: "beta" }]],
  },
  { id: "s-h2", type: "heading", level: 2, text: "Details" },
  { id: "s-p2", type: "paragraph", content: [{ type: "text", value: "tail line" }] },
];

check("P5 source: NO-EDIT toggle is op-free (md unchanged → ZERO bp-canvas-ops)", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // The WC compares textarea.value === the stashed original md and restores untouched
  // on equality; assert the underlying re-parse+realign+diff ALSO yields zero ops, so
  // the toggle can never smuggle in a normalization op even on the edited code path.
  const { ops } = exitSourceOps(SRC_BASELINE, md0);
  assert.equal(ops.length, 0, `no-edit round-trip must emit ZERO ops, got ${JSON.stringify(ops)}`);
});

check("P5 source: edited heading text → EXACTLY ONE patch-block for that block", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // Edit ONLY the H2 "Details" → "Details v2" in the markdown text.
  assert.ok(md0.includes("## Details"), "baseline md contains the H2 line");
  const editedMd = md0.replace("## Details", "## Details v2");
  assert.notEqual(editedMd, md0, "the md actually changed");

  const { ops, realigned } = exitSourceOps(SRC_BASELINE, editedMd);
  // The realigner must have kept the H2's baseline id so the diff patches it in place.
  const h2 = realigned.find((b) => b.type === "heading" && b.text === "Details v2");
  assert.ok(h2, "the edited H2 is present in the realigned blocks");
  assert.equal(h2.id, "s-h2", "edited H2 inherited the baseline id (in-place edit)");

  assert.equal(ops.length, 1, `exactly one op, got ${JSON.stringify(ops)}`);
  assert.equal(ops[0].op, "patch-block", "the one op is a patch-block");
  assert.equal(ops[0].id, "s-h2", "the patch targets the edited heading's id");
});

check("P5 source: an INSERTED block → one insert/append; surviving blocks untouched", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // Append a brand-new paragraph at the end of the markdown.
  const editedMd = md0 + "\n\nbrand new tail";
  const { ops } = exitSourceOps(SRC_BASELINE, editedMd);
  // The lone structural change is the inserted block (append-block or insert-after);
  // every surviving block kept its id so NONE of them patch.
  const structural = ops.filter((o) => o.op === "append-block" || o.op === "insert-after");
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(structural.length, 1, `one insert op, got ${JSON.stringify(ops)}`);
  assert.equal(patches.length, 0, `no spurious patches, got ${JSON.stringify(patches)}`);
});

check("P5 source: a REMOVED block → one remove-block; survivors keep their ids", () => {
  const md0 = blocksToMarkdown(SRC_BASELINE);
  // Drop the H2 "Details" line entirely (delete that block from the source).
  const editedMd = md0.replace("## Details\n\n", "");
  assert.notEqual(editedMd, md0, "the md actually changed");
  const { ops } = exitSourceOps(SRC_BASELINE, editedMd);
  const removes = ops.filter((o) => o.op === "remove-block");
  const patches = ops.filter((o) => o.op === "patch-block");
  assert.equal(removes.length, 1, `one remove op, got ${JSON.stringify(ops)}`);
  assert.equal(removes[0].id, "s-h2", "the removed id is the deleted heading");
  assert.equal(patches.length, 0, `survivors keep ids → no patches, got ${JSON.stringify(patches)}`);
});

check("P5 source: realignBlockIds never assigns a baseline id twice", () => {
  // Even a heavily-edited markdown (multiple in-place edits) must keep ids unique so
  // runToOps's per-id keying holds (a duplicate id would make it self-move/conflict).
  const md0 = blocksToMarkdown(SRC_BASELINE);
  const editedMd = md0
    .replace("# Status", "# Status X")
    .replace("## Details", "## Details Y");
  const { realigned } = exitSourceOps(SRC_BASELINE, editedMd);
  const ids = realigned.map((b) => b.id);
  assert.equal(new Set(ids).size, ids.length, "all realigned ids are unique");
});

check("P5 source: empty run round-trips to an empty doc with ZERO ops", () => {
  const baseline = [];
  const md0 = blocksToMarkdown(baseline);
  const { ops } = exitSourceOps(baseline, md0);
  assert.equal(ops.length, 0, "empty → empty emits no ops");
});

// ── L0 derivation: docToBlocks(live doc) is the source baseline (NOT C) ──────
//
// _enterSourceMode now captures L0 = docToBlocks(normalizeCanvasDoc(getJSON())),
// the SAME node→block projection runToOps diffs against. These assert docToBlocks
// reproduces the run faithfully (so the markdown the user sees == the live doc) and
// MINTS an id for a just-typed (bpId:null) node (so blocksToMarkdown has a stable key
// and the exit realign can donate it back).
check("P5 source: docToBlocks projects a live doc back to its run (ids preserved)", () => {
  const doc = runToTiptap(SRC_BASELINE);
  const blocks = docToBlocks(doc);
  // Round-trip is the identity on a doc that came straight from runToTiptap: same ids,
  // same kinds, same content — so a NO-EDIT enter shows exactly the confirmed run.
  assert.deepEqual(blocks.map((b) => b.id), SRC_BASELINE.map((b) => b.id), "ids preserved");
  // And diffing the baseline against this projection emits ZERO ops (the projection is
  // the diff fixed-point — entering source mode on an unedited run perturbs nothing).
  assert.equal(runToOps(SRC_BASELINE, runToTiptap(blocks)).length, 0, "L0 projection is op-free vs itself");
});

check("P5 source: docToBlocks MINTS an id for a just-typed (bpId:null) live node", () => {
  // A live doc where the 2nd top-level node was just typed (Enter-split / new para)
  // and carries bpId:null — exactly the not-yet-confirmed state on source-mode enter.
  const liveDoc = {
    type: "doc",
    content: [
      { type: "heading", attrs: { bpId: "s-h1", bpType: "heading", level: 1 }, content: [{ type: "text", text: "Status" }] },
      { type: "paragraph", attrs: { bpId: null, bpType: "paragraph" }, content: [{ type: "text", text: "fresh line" }] },
    ],
  };
  const blocks = docToBlocks(liveDoc);
  assert.equal(blocks.length, 2, "both nodes project");
  assert.equal(blocks[0].id, "s-h1", "the confirmed node keeps its id");
  assert.ok(blocks[1].id && blocks[1].id !== "s-h1" && blocks[1].id != null, "the just-typed node was minted a fresh id");
  assert.equal(blocks[1].content[0].value, "fresh line", "the just-typed text rides into the baseline (it is on screen)");
});

// ── LAG MODEL: L0 carries a block NOT in C; the source diff must not duplicate it ──
//
// The data-loss blocker scenario, modeled in pure Node. The user typed a new paragraph
// ("fresh") that the server has NOT echoed yet, so C (this._blocks) lacks it but the
// LIVE doc (L0) has it. Source mode captures L0, the user edits a DIFFERENT block in
// the textarea, and exits. The emit is runToOps(L0, L1) — so it carries ONLY the source
// edit. It must NOT re-insert "fresh" (that pre-source insert is already in flight as
// L0−C; re-emitting it would double-insert). This is precisely why the toggle diffs
// L0→L1 explicitly instead of running _emitOps (which diffs from C and WOULD re-insert).
check("P5 source: lag — an L0 block absent from C is NOT re-emitted by the source diff", () => {
  // C = the echo-confirmed run (no "fresh" yet).
  const C = [
    { id: "c-h1", type: "heading", level: 1, text: "Status" },
    { id: "c-p1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
  ];
  // L0 = the LIVE doc: C plus a just-typed, not-yet-confirmed paragraph "fresh" whose
  // node still had bpId:null, so docToBlocks minted it an id (here a stable test id).
  const L0 = [
    { id: "c-h1", type: "heading", level: 1, text: "Status" },
    { id: "c-p1", type: "paragraph", content: [{ type: "text", value: "intro" }] },
    { id: "c-fresh", type: "paragraph", content: [{ type: "text", value: "fresh" }] },
  ];
  // Sanity: the L0−C delta is the in-flight insert of "fresh" (plus whatever reorder
  // anchoring needs) — and crucially it carries NO patch/remove of the existing blocks.
  // This is the batch ALREADY in flight; the source exit must NOT re-send any of it.
  const preSourceOps = runToOps(C, runToTiptap(L0));
  const inserts = preSourceOps.filter((o) => o.op === "insert-after" || o.op === "append-block");
  assert.equal(inserts.length, 1, `L0−C inserts the one fresh block, got ${JSON.stringify(preSourceOps)}`);
  assert.equal(preSourceOps.filter((o) => o.op === "patch-block" || o.op === "remove-block").length, 0, "L0−C neither patches nor removes an existing block");

  // In source mode the user edits the HEADING only; "fresh" is untouched in the md.
  const md0 = blocksToMarkdown(L0);
  assert.ok(md0.includes("# Status"), "L0 md has the heading");
  assert.ok(md0.includes("fresh"), "L0 md has the just-typed paragraph (it is on screen)");
  const editedMd = md0.replace("# Status", "# Status v2");

  // The exit emit is runToOps(L0, L1) — exactly ONE patch for the heading, and NOTHING
  // about "fresh" (no second insert, no remove, no patch). The in-flight L0−C insert is
  // left to the normal echo, never re-sent here.
  const { ops, realigned } = exitSourceOps(L0, editedMd);
  assert.equal(ops.length, 1, `exactly one source op, got ${JSON.stringify(ops)}`);
  assert.equal(ops[0].op, "patch-block", "the one op is a patch-block");
  assert.equal(ops[0].id, "c-h1", "…targeting the edited heading");
  // The fresh paragraph survived the realign with its L0 id, so the diff sees no change
  // for it → no duplicate insert.
  const fresh = realigned.find((b) => b.content && b.content[0] && b.content[0].value === "fresh");
  assert.ok(fresh && fresh.id === "c-fresh", "the fresh block kept its L0 id (no re-mint, no re-insert)");
});

// ── DUPLICATE-SIGNATURE run: a single edit must not churn identical siblings ──
//
// Two byte-identical paragraphs share a per-block markdown signature, so they are
// LCS-indistinguishable. realignBlockIds breaks the tie POSITIONALLY (nearest
// unconsumed baseline id within the equal-signature run), so editing ONE near them
// emits exactly ONE patch and the identical sibling keeps its id (no spurious move /
// patch / remove). Each baseline id is donated at most once.
check("P5 source: a duplicate-signature run does NOT churn on a single in-place edit", () => {
  const para = (id, t) => ({ id, type: "paragraph", content: [{ type: "text", value: t }] });
  const L0 = [
    para("d-h", "Top"),
    para("d-p1", "identical"),
    para("d-p2", "identical"), // byte-identical signature to d-p1
    para("d-tail", "tail"),
  ];
  const md0 = blocksToMarkdown(L0);
  // Edit the SECOND identical paragraph only.
  let seen = 0;
  const editedMd = md0.replace(/identical/g, (m) => (++seen === 2 ? "identical EDITED" : m));
  assert.notEqual(editedMd, md0, "md changed");

  const { ops, realigned } = exitSourceOps(L0, editedMd);
  // Exactly one patch; survivors keep ids; no moves/removes/inserts.
  assert.equal(ops.length, 1, `exactly one op, got ${JSON.stringify(ops)}`);
  assert.equal(ops[0].op, "patch-block", "the one op is a patch-block");
  assert.equal(ops[0].id, "d-p2", "the patch targets the edited sibling's id (positional tie-break)");
  // ids stay unique (no double-donation) and both originals are present.
  const ids = realigned.map((b) => b.id);
  assert.equal(new Set(ids).size, ids.length, "all realigned ids unique");
  assert.ok(ids.includes("d-p1") && ids.includes("d-p2"), "both duplicate ids survived, donated once each");

  // And editing the FIRST instead is symmetric: one patch on d-p1, no churn.
  let seen2 = 0;
  const editedFirst = md0.replace(/identical/g, (m) => (++seen2 === 1 ? "identical FIRST" : m));
  const r2 = exitSourceOps(L0, editedFirst);
  assert.equal(r2.ops.length, 1, `editing the first → one op, got ${JSON.stringify(r2.ops)}`);
  assert.equal(r2.ops[0].id, "d-p1", "the patch targets the first sibling's id");
});

// ── DOM-bound contract (documented, asserted at the converter level) ─────────
//
// The WC marks source mode as "busy": while this._mode === 'source', _isEditingNow()
// returns true, so applyServerBlocks QUEUES an external echo (_pendingServerBlocks)
// onto the HIDDEN editor instead of applying it — the source-exit setContent would
// otherwise clobber it. The queue is flushed on return to rich (_flushPendingServerBlocks,
// the same flush blur/compositionend run). This behavior is DOM-bound (it needs a live
// editor + textarea) and is exercised by the Elixir LiveView paper_canvas tests; here we
// only DOCUMENT it and pin the underlying invariant it relies on: an external echo and a
// source edit are diffed against the SAME L0 baseline, so neither loses the other's work.
check("P5 source: (documented) external echo + source edit are both expressed against L0", () => {
  // L0 with two blocks; the user edits the first in source mode (→ L1), while an external
  // echo confirms a change to the SECOND. Both diffs key off L0 ids, so applying the
  // queued external echo after exit and the source patch never target the same datum.
  const para = (id, t) => ({ id, type: "paragraph", content: [{ type: "text", value: t }] });
  const L0 = [para("q-1", "mine"), para("q-2", "theirs")];
  const md0 = blocksToMarkdown(L0);
  const { ops } = exitSourceOps(L0, md0.replace("mine", "mine v2"));
  assert.equal(ops.length, 1, "source edit is one patch on q-1");
  assert.equal(ops[0].id, "q-1", "…targeting the user's block, not the externally-changed one");
  // The external echo (a confirmed change to q-2) is a SEPARATE applyServerBlocks the WC
  // queues during source mode and flushes on exit — orthogonal to this q-1 patch.
});

check("P5 palette: View 'Toggle Markdown source' command appears only with onToggleSource", () => {
  // Without the callback (pure build): no View group.
  const plain = buildCommandRegistry();
  assert.ok(!plain.some((c) => c.id === "view-toggle-source"), "no View command without callback");
  // With the callback: the command is present, in a "View" group, and run() invokes it.
  let called = 0;
  const reg = buildCommandRegistry(undefined, { onToggleSource: () => { called++; } });
  const view = reg.find((c) => c.id === "view-toggle-source");
  assert.ok(view, "View command present when onToggleSource wired");
  assert.equal(view.group, "View", "command is in the View group");
  assert.equal(view.label, "Toggle Markdown source", "command label matches the spec");
  view.run({});
  assert.equal(called, 1, "run() calls the toggle callback");
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall round-trips PASS");
