// __smoke.mjs — pure converter round-trip check. No DOM, no TipTap engine.
// Run: node src/__smoke.mjs   (or: npm run smoke)
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

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall round-trips PASS");
