import { test } from "node:test";
import assert from "node:assert/strict";

import { resetBlockIds, paragraph } from "../src/blocks.js";
import {
  appendBlock,
  insertAfter,
  patchBlock,
  replaceBlock,
  removeBlock,
  moveBlock,
} from "../src/ops.js";

test("appendBlock -> {op:'append-block', block}", () => {
  resetBlockIds();
  const b = paragraph("x");
  assert.deepEqual(appendBlock(b), { op: "append-block", block: b });
});

test("insertAfter -> {op:'insert-after', afterId, block}", () => {
  resetBlockIds();
  const b = paragraph("x");
  const op = insertAfter("b1", b);
  assert.equal(op.op, "insert-after");
  assert.equal(op.afterId, "b1");
  assert.equal(op.block, b);
});

test("patchBlock -> {op:'patch-block', id, patch} (uses 'patch', not 'fields')", () => {
  const op = patchBlock("b2", { text: "new" });
  assert.deepEqual(op, { op: "patch-block", id: "b2", patch: { text: "new" } });
  assert.equal("fields" in op, false);
});

test("replaceBlock -> {op:'replace-block', id, block}", () => {
  resetBlockIds();
  const b = paragraph("x");
  assert.deepEqual(replaceBlock("b3", b), { op: "replace-block", id: "b3", block: b });
});

test("removeBlock -> {op:'remove-block', id}", () => {
  assert.deepEqual(removeBlock("b4"), { op: "remove-block", id: "b4" });
});

test("moveBlock -> {op:'move-block', id, after} (uses 'after'); null moves to head", () => {
  assert.deepEqual(moveBlock("b5", { after: "b1" }), {
    op: "move-block",
    id: "b5",
    after: "b1",
  });
  // default after -> null (head)
  assert.deepEqual(moveBlock("b5"), { op: "move-block", id: "b5", after: null });
});

test("every op discriminator key is 'op' with the hyphenated kind", () => {
  resetBlockIds();
  const b = paragraph("x");
  const ops = [
    appendBlock(b),
    insertAfter("a", b),
    patchBlock("a", {}),
    replaceBlock("a", b),
    removeBlock("a"),
    moveBlock("a"),
  ];
  assert.deepEqual(
    ops.map((o) => o.op),
    ["append-block", "insert-after", "patch-block", "replace-block", "remove-block", "move-block"],
  );
});
