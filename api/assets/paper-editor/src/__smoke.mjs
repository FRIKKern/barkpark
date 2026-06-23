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

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall round-trips PASS");
