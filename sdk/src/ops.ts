/**
 * Typed DocPatchOp union + constructors.
 *
 * Keys mirror EXACTLY `Barkpark.PortableDoc.Patch` (api/lib/barkpark/portable_doc/patch.ex)
 * and the batch route in BulldocsIngestController.apply_op/2:
 *
 *   append-block  -> { op, block }
 *   insert-after  -> { op, afterId, block }
 *   patch-block   -> { op, id, patch }      (shallow-merge; id+type immutable)
 *   replace-block -> { op, id, block }
 *   remove-block  -> { op, id }
 *   move-block    -> { op, id, after|null } (top-level reorder; Barkpark-local)
 *
 * The discriminator key is "op" (a hyphenated string), NOT a camelCase tag.
 */

import type { Block } from "./blocks.js";

export interface AppendBlockOp {
  op: "append-block";
  block: Block;
}
export interface InsertAfterOp {
  op: "insert-after";
  afterId: string;
  block: Block;
}
export interface PatchBlockOp {
  op: "patch-block";
  id: string;
  patch: Record<string, unknown>;
}
export interface ReplaceBlockOp {
  op: "replace-block";
  id: string;
  block: Block;
}
export interface RemoveBlockOp {
  op: "remove-block";
  id: string;
}
export interface MoveBlockOp {
  op: "move-block";
  id: string;
  after: string | null;
}

export type Op =
  | AppendBlockOp
  | InsertAfterOp
  | PatchBlockOp
  | ReplaceBlockOp
  | RemoveBlockOp
  | MoveBlockOp;

/** Append `block` to the document's top-level block list. */
export function appendBlock(block: Block): AppendBlockOp {
  return { op: "append-block", block };
}

/** Insert `block` directly after the block `afterId` (recurses sections). */
export function insertAfter(afterId: string, block: Block): InsertAfterOp {
  return { op: "insert-after", afterId, block };
}

/**
 * Shallow-merge `patch` into block `id`. The renderer/patch pin `id` + `type`
 * as immutable, so a patch can't re-key the block.
 */
export function patchBlock(id: string, patch: Record<string, unknown>): PatchBlockOp {
  return { op: "patch-block", id, patch };
}

/** Replace block `id` wholesale with `block`. */
export function replaceBlock(id: string, block: Block): ReplaceBlockOp {
  return { op: "replace-block", id, block };
}

/** Remove block `id` from its parent's block list. */
export function removeBlock(id: string): RemoveBlockOp {
  return { op: "remove-block", id };
}

/**
 * Move block `id` directly after `opts.after` (top-level only). `after: null`
 * (the default) moves it to the head of the list.
 */
export function moveBlock(id: string, opts: { after?: string | null } = {}): MoveBlockOp {
  return { op: "move-block", id, after: opts.after ?? null };
}
