// ── THE SAFETY NET: a pure-JS reference fold mirroring patch.ex ──────────────
//
// applyOps(prevBlocks, ops) folds the emitted op list through the SAME
// semantics api/lib/barkpark/portable_doc/patch.ex implements, so a test can
// PROVE that runToOps's output reproduces nextDoc — not merely that each op has
// the right SHAPE. The original S0 tests asserted only shape, which is why two
// real fold bugs (a front-insert landing at END; an insert stranded by a later
// move) passed green. Faithful op semantics (top-level only — S0 has no
// sections):
//   append-block  → concat block at END (an id already anywhere in the tree is an
//                   error, patch.ex id_exists?)
//   insert-after  → splice block immediately after afterId (absent → error;
//                   an id already anywhere in the tree → error); RECURSES into
//                   section children
//   remove-block  → drop the block by id (absent → error); RECURSES into section
//                   children (patch.ex resolves ids against the whole tree)
//   move-block    → lift the block by id, splice after `after` (or head when
//                   null); after===id or already-in-place is a no-op (TOP-LEVEL only)
//   patch-block   → shallow-merge patch into the block by id, re-pin id+type;
//                   RECURSES into section children
//   replace-block → replace the block by id wholesale; RECURSES into section children
//                   (the container coarse path — the whole rebuilt subtree)
function applyOps(prevBlocks, ops) {
  let blocks = (prevBlocks || []).map((b) => ({ ...b }));
  const idAt = (id) => blocks.findIndex((b) => b && b.id === id);
  const idExists = (list, id) =>
    Array.isArray(list) && list.some((b) => b && (b.id === id || idExists(b.blocks, id)));

  // transformAtId(blocks, id, fn) — mirror patch.ex transform_at_id: find the block
  // `id` at TOP LEVEL or nested inside any block's `blocks` (a section body) at any
  // depth, and replace it with `fn(target)` (an ARRAY of 0/1/many blocks). Returns a
  // NEW tree (never mutates input) or null when the id is absent everywhere.
  const transformAtId = (list, id, fn) => {
    let found = false;
    const walk = (arr) => {
      const out = [];
      for (const b of arr || []) {
        if (b && b.id === id) {
          found = true;
          for (const nb of fn(b)) out.push(nb);
          continue;
        }
        if (b && Array.isArray(b.blocks)) {
          out.push({ ...b, blocks: walk(b.blocks) });
        } else {
          out.push(b);
        }
      }
      return out;
    };
    const result = walk(list);
    return found ? result : null;
  };

  for (const op of ops) {
    switch (op.op) {
      case "append-block": {
        if (op.block && op.block.id != null && idExists(blocks, op.block.id)) {
          throw new Error(`append-block: duplicate id ${op.block.id}`);
        }
        blocks = [...blocks, { ...op.block }];
        break;
      }
      case "insert-after": {
        if (op.block && op.block.id != null && idExists(blocks, op.block.id)) {
          throw new Error(`insert-after: duplicate id ${op.block.id}`);
        }
        const next = transformAtId(blocks, op.afterId, (target) => [target, { ...op.block }]);
        if (next == null) throw new Error(`insert-after: afterId not found ${op.afterId}`);
        blocks = next;
        break;
      }
      case "remove-block": {
        const next = transformAtId(blocks, op.id, () => []);
        if (next == null) throw new Error(`remove-block: id not found ${op.id}`);
        blocks = next;
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
        const next = transformAtId(blocks, op.id, (target) => [
          // Shallow-merge, then re-pin id + type (patch.ex merge_block).
          { ...target, ...op.patch, id: target.id, type: target.type },
        ]);
        if (next == null) throw new Error(`patch-block: id not found ${op.id}`);
        blocks = next;
        break;
      }
      case "replace-block": {
        // Replace the block `id` wholesale with op.block (patch.ex replace-block).
        const next = transformAtId(blocks, op.id, () => [{ ...op.block }]);
        if (next == null) throw new Error(`replace-block: id not found ${op.id}`);
        blocks = next;
        break;
      }
      default:
        throw new Error(`applyOps: unknown op ${JSON.stringify(op)}`);
    }
  }
  return blocks;
}

export { applyOps };
