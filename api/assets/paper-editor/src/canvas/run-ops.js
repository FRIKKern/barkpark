import { buildPatchBlockOp, tiptapToBlock } from "../convert.js";
import { canonicalJSON, deepClone } from "./projection-json.js";
import {
  carryRowKeys, carryUnmodeledKeys, columnsNodeChanged, columnsNodeToColumns,
  expandableChildPatchOps, expandableNodeToBlock, expandableSummaryChanged, expandableSummaryPatch,
  rowsNodeChanged, rowsNodeToRows, sectionChildPatchOps, sectionChildSeqChanged,
  sectionLayoutChanged, sectionLayoutPatch, sectionNodeToBlock, sectionTitleChanged,
  sectionTitlePatch, terminalNodeChanged, terminalNodeToPatch,
} from "./run-container-codecs.js";
import {
  calloutNodeChanged, calloutNodeToPatch, cardNodeChanged, cardNodeToPatch, noteNodeChanged,
  noteNodeToPatch,
} from "./run-content-codecs.js";
import { minimalMoves, withAlignDrop, withListStartDrop } from "./run-diff-utils.js";
import { CANVAS_ROWS, CONVERTIBLE_KINDS, blockKind, isNoteType } from "./run-kinds.js";
import {
  classifyNode, mintId, nodeToDocEnvelope, proseNodeChanged, walkBlockIds,
} from "./run-node-core.js";
import { runToTiptap } from "./run-project.js";
import { nextNodeToBlock, stripId } from "./run-reverse-echo.js";
import {
  codeNodeChanged, codeNodeToPatch, diagramNodeChanged, diagramNodeToPatch, isTechnicalAtomNode,
  roleNodeChanged, roleNodeToPatch, stageNodeChanged, stageNodeToPatch, technicalNodeChanged,
  technicalNodeToPatch,
} from "./run-scalar-codecs.js";
import {
  READ_ONLY_ATOM_RETARGET_KEY, actionNodeChanged, actionNodeToPatch, fieldNodeChanged,
  fieldNodeToPatch, figureNodeChanged, figureNodeToPatch, fleetNodeChanged, fleetNodeToPatch,
  imageNodeChanged, imageNodeToPatch, islandNodeChanged, islandNodeToPatch,
  readOnlyAtomRetargetPatch, taskListNodeChanged, taskListNodeToPatch,
} from "./run-structured-codecs.js";
import { tableNodeChanged, tableNodeToPatch } from "./table-convert.js";

export function runToOps(prevBlocks, nextDoc, options = {}) {
  const prev = prevBlocks || [];

  // prev id → index, and the block.
  const prevIndex = new Map();
  const prevById = new Map();
  prev.forEach((block, i) => {
    const id = block && block.id;
    if (id != null) {
      prevIndex.set(id, i);
      prevById.set(id, block);
    }
  });

  const nextNodes = (nextDoc && nextDoc.content) || [];

  // ── 0) BUILD nextSeq: every next node gets a KNOWN id (existing or minted) ──
  //
  // `taken` seeds with every prev id so a minted id can never collide with a
  // surviving block (patch.ex rejects duplicate ids on append/insert-after).
  // RECURSIVE (descend section.blocks at any depth) — the make-or-break
  // duplicate_id-abort guard: a NESTED prev child id is invisible to a top-level-only
  // seed, so a mint (for a new top-level block OR a new nested section child) could
  // collide with it and patch.ex duplicate_id (patch.ex:182/191) would abort the whole
  // atomic batch, silently dropping every co-batched edit. prevIndex/prevById stay
  // TOP-LEVEL (they key the top-level structural diff); only `taken` walks the full
  // tree.
  const taken = new Set();
  walkBlockIds(prev, taken);
  const claimedNewIds = new Set();

  // Classify each node into its canvas KIND + resolved bpType via the SHARED
  // classifyNode (the same path docToBlocks uses), then resolve the id HERE: a
  // surviving prev id keeps its id (existing); anything else (a split / typed /
  // paste node with bpId:null, or a bpId not in prev) is CLIENT-MINTED. This is
  // the one piece runToOps owns over docToBlocks — id resolution is keyed against
  // the PREV run, not just the live bpId.
  const nextSeq = nextNodes.map((node) => {
    const bpId = node.attrs && node.attrs.bpId;
    const existing = bpId != null && prevIndex.has(bpId);
    const preservedNew = options.preserveNewIds === true && bpId != null &&
      !taken.has(bpId) && !claimedNewIds.has(bpId);
    const id = existing || preservedNew ? bpId : mintId(taken);
    if (preservedNew) {
      taken.add(id);
      claimedNewIds.add(id);
    }
    return { ...classifyNode(node), id, isNew: !existing };
  });

  const nextIds = new Set(nextSeq.map((e) => e.id));

  // Doctrine template locks (pdd-t2): the ids of template-locked blocks. A locked
  // block can NEVER be removed or moved by a canvas diff — the server backstops it
  // (patch.ex:192-274 rejects a locked remove/move, halting the whole atomic batch
  // and losing co-batched edits) and the editor vetoes it live (filterTransaction).
  // This is the DIFF-layer guard so a remove/move op for a locked id is never even
  // EMITTED — belt-and-braces for any path that could still produce a doc missing
  // or reordering a locked block (e.g. a markdown source-mode round-trip). Locked-
  // ness is authoritative from the PREV (source) blocks: `locked` is server-seeded
  // and immutable through patch-block, so the prev run is the truth.
  const lockedIds = new Set();
  for (const block of prev) {
    if (block && block.locked === true && block.id != null) lockedIds.add(block.id);
  }

  const ops = [];

  // ── 1) REMOVES — prev id not present in nextSeq (a merge/delete) ───────────
  //
  // A LOCKED id is NEVER removed (pdd-t2): even if it went missing from the live
  // doc (which filterTransaction prevents), emitting remove-block would be rejected
  // by the server and halt the batch — so we skip it and let the block persist.
  for (const block of prev) {
    const id = block && block.id;
    if (id != null && !nextIds.has(id) && !lockedIds.has(id)) {
      ops.push({ op: "remove-block", id });
    }
  }

  // The running fold's id order, tracked as WE apply our own ops so move
  // emission can skip no-ops. After removes it is the surviving prev ids in
  // prev order.
  let running = prev
    .map((b) => b && b.id)
    .filter((id) => id != null && nextIds.has(id));

  // ── 2) INSERTS — each NEW entry grafted in with its MINTED id ──────────────
  //
  // Anchor every insert to the FIRST surviving prev block (guaranteed present
  // through the whole insert pass — inserts never remove it). When nothing
  // survives (prev empty or all-removed) the first insert appends and each
  // subsequent insert anchors after the previously-inserted block. Final
  // position is irrelevant — the moves pass fixes order.
  let firstSurvivor = running.length > 0 ? running[0] : null;
  for (const entry of nextSeq) {
    if (!entry.isNew) continue;
    // Pass the CALL-SHARED `taken` so a NEW section's nested null-id children mint ids
    // that never collide with any tree id (the duplicate_id-abort guard).
    const block = nextNodeToBlock(entry, taken);
    if (firstSurvivor == null) {
      // No anchor yet: append the first new block at the end, then use it as the
      // anchor for the rest so every later insert has a present afterId.
      ops.push({ op: "append-block", block });
      running.push(entry.id);
      firstSurvivor = entry.id;
    } else {
      ops.push({ op: "insert-after", afterId: firstSurvivor, block });
      // insert-after splices directly after firstSurvivor; reflect that in the
      // running order (position irrelevant for correctness — moves fix it).
      const at = running.indexOf(firstSurvivor);
      running.splice(at + 1, 0, entry.id);
    }
  }

  // WHY ONE ENTER AT THE TAIL OF A RUN EMITS ~N MOVE-BLOCKS (spd-bl-enter-at-tail-
  // block-drop). Pass 2 anchors EVERY insert at the FIRST SURVIVOR (there is no
  // prepend / insert-before op), so a paragraph typed at the END of a 13-block run is
  // grafted in at position 1 and this pass then walks it back down with a move for
  // every block it jumped. The batch reads alarming — `insert-after: pp-001` plus a
  // dozen `move-block`s for one keypress — and it is CORRECT: folded left-to-right
  // through patch.ex it reproduces the doc exactly, and every prev block survives.
  //
  // THE DISCRIMINANT, if you are staring at such a batch wondering if it ate a block:
  // look for a `remove-block` on the run's LAST id. Enter never emits one — pass 1
  // only removes a prev id that is ABSENT from the live doc. So a remove-block here
  // means the tail node was never IN the doc the diff read: a node type the mounted
  // schema does not register is dropped by ProseMirror on setContent (a stale
  // committed bundle is how that happens in the wild — .github/workflows/paper-
  // editor.yml gates it). That is real loss, and it is a BUNDLE/SCHEMA fault, not an
  // Enter fault. Both batches are pinned, mounted and folded, in
  // canvas/__enter_tail.test.mjs + api/test/barkpark/portable_doc/
  // patch_enter_at_tail_test.exs.
  // ── 3) MOVES — permute `running` (now exactly nextSeq's id SET) into order ──
  //
  // Walk nextSeq left-to-right. For each entry, the target predecessor is the
  // previous entry's id (or null for the first). Emit a move ONLY when the entry
  // is not ALREADY immediately after that predecessor in the running order — so
  // an already-correct subsequence (e.g. a pure interior edit) emits zero moves.
  // We apply each move to `running` as we go, so subsequent checks see the
  // post-move order and we never emit a redundant move.
  // Already in order (every interior edit, every keystroke): each entry sits one
  // slot after its predecessor, so the walk below would emit nothing. Checking
  // that is linear; the walk's indexOf per entry is quadratic in the run's length
  // (task-fb938eb8be3bce48).
  const inOrder = running.length === nextSeq.length && nextSeq.every((e, i) => running[i] === e.id);
  // MINIMAL MOVES (task-d20a8200b28f0d7a). The longest run of blocks already in
  // nextSeq's relative order stays put, and only the others move. Dragging one
  // block from [a, X, b, c] to [a, b, c, X] is ONE move-block for X; the greedy
  // walk below would emit moves for b and c, blocks the author never touched.
  // The minimal batch is checked by folding it; if it does not reproduce
  // nextSeq, the greedy walk runs instead.
  const minimal = inOrder ? [] : minimalMoves(running, nextSeq, lockedIds);
  if (minimal) {
    for (const op of minimal) ops.push(op);
    running.length = 0;
    for (const e of nextSeq) running.push(e.id);
  }
  for (let i = 0; !inOrder && !minimal && i < nextSeq.length; i++) {
    const id = nextSeq[i].id;
    // A LOCKED block holds its position (pdd-t2): never emit a move for it. The
    // filterTransaction veto keeps a locked node at its fixed index, so `running`
    // already has it correctly placed; skipping leaves the following entry's
    // `after` anchor pointing at the (stable) locked id.
    if (lockedIds.has(id)) continue;
    const after = i === 0 ? null : nextSeq[i - 1].id;
    const curIdx = running.indexOf(id);
    const afterIdx = after == null ? -1 : running.indexOf(after);
    // Already correctly placed iff it sits exactly one slot after its target
    // predecessor (or at the head when there is no predecessor).
    if (curIdx === afterIdx + 1) continue;
    ops.push({ op: "move-block", id, after });
    // Mirror patch.ex move-block on `running`: lift the id, splice after `after`
    // (or head when null).
    running.splice(curIdx, 1);
    const dest = after == null ? 0 : running.indexOf(after) + 1;
    running.splice(dest, 0, id);
  }

  // ── 4) PATCHES — surviving prose / content / attr-atom nodes whose interior
  //      changed ───────────────────────────────────────────────────────────────
  //
  // PROSE → byte-identical to the per-block editor's patch-block (buildPatchBlockOp).
  // CANVAS CONTENT (S3.2: callout) → a patch-block carrying the changed body/chrome
  //   fields (calloutNodeToPatch), keyed by id. An UNCHANGED callout emits NO op
  //   (canonical key-order-insensitive compare, same as prose).
  // CANVAS ATTR-ATOM (S3.3: code) → a patch-block carrying the changed value/lang
  //   (codeNodeToPatch), keyed by id. An UNCHANGED code emits NO op (canonical
  //   compare on value+lang). UNLIKE the divider atom (which can never change), an
  //   attr-atom's value/lang ARE mutable, so it IS diffed here.
  // A surviving opaque node is a no-op (opaque blocks just round-trip).
  // A surviving canvas ATOM (S3: divider) is likewise a no-op: a content-free leaf
  // has no interior to change, so it NEVER reports an interior patch.
  // A surviving canvas READ-ONLY ATOM (S3.6: sheet / embed) carries the whole block
  // verbatim and its RESOLVED content is never edited here. Each has ONE authored
  // field — a sheet's `ref`, an embed's `target` — which the canvas now retargets
  // through the reference picker, so an atom whose reference CHANGED emits exactly one
  // patch-block and one whose reference did not emits nothing.
  // `options.unchangedIds` (the canvas emit's fast path, task-fb938eb8be3bce48)
  // names surviving ids whose node the caller KNOWS still equals its prev block:
  // their compare below could only find nothing to patch, so it is skipped.
  const unchangedIds = options.unchangedIds instanceof Set ? options.unchangedIds : null;
  for (const entry of nextSeq) {
    // A surviving opaque block whose CARRIED block changed → ONE replace-block with
    // the edited block. Only a declared custom object block's field dialog
    // (inline-object.js, task-aebfe6c1b3c3f881) rewrites a carried block, so an
    // untouched carry compares equal (id excluded, key order ignored) and emits
    // nothing, exactly as before.
    if (entry.isOpaque && !entry.isNew) {
      if (unchangedIds && unchangedIds.has(entry.id)) continue;
      const carried = entry.node.attrs && entry.node.attrs.bpBlock;
      const before = prevById.get(entry.id);
      if (before && carried && canonicalJSON(stripId(before)) !== canonicalJSON(stripId(carried))) {
        ops.push({ op: "replace-block", id: entry.id, block: { ...deepClone(carried), id: entry.id } });
      }
      continue;
    }
    if (entry.isNew || entry.isOpaque || entry.isAtom) continue;
    if (unchangedIds && unchangedIds.has(entry.id)) continue;
    // A read-only atom with no retargetable reference keeps the original
    // zero-ops-by-construction guarantee.
    if (entry.isReadOnlyAtom && !(entry.bpType in READ_ONLY_ATOM_RETARGET_KEY)) continue;
    const prevBlock = prevById.get(entry.id);
    const prevNode = runToTiptap([prevBlock]).content[0];

    if (entry.isReadOnlyAtom) {
      // RETARGET: one patch-block carrying the new reference (plus, for a sheet, the
      // explicit clear of the old ref's cached grid). An untouched atom emits NOTHING
      // (the D3 byte stability guarantee is unchanged for every block nobody
      // retargeted).
      const patch = readOnlyAtomRetargetPatch(entry.bpType, prevNode, entry.node);
      if (patch) ops.push({ op: "patch-block", id: entry.id, patch });
      continue;
    }

    if (entry.isTable) {
      // Canvas table (nested node tree): diff the grid; emit one COARSE whole-table
      // patch-block (rows + head, head explicit-[] on header removal) when anything
      // changed. prevNode is reconstructed via tableBlockToNode so the compare is
      // apples-to-apples. An UNCHANGED table emits NO op.
      if (tableNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: tableNodeToPatch(entry.node, prevBlock),
        });
      }
      continue;
    }

    if (entry.isContainer) {
      // Canvas container node — sub-route by bpType (section | expandable | terminal | columns).
      if (entry.bpType === "steps" || entry.bpType === "tabs") {
        // steps / tabs: the columns strategy — any change → ONE coarse patch-block
        // carrying the whole rows array (ids kept, new ones minted off `taken`).
        if (rowsNodeChanged(prevNode, entry.node)) {
          const spec = CANVAS_ROWS[entry.bpType];
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: {
              [spec.rowsKey]: carryRowKeys(
                prevBlock && prevBlock[spec.rowsKey],
                rowsNodeToRows(entry.node, entry.bpType, taken, nextNodeToBlock),
                spec,
              ),
            },
          });
        }
        continue;
      }
      if (entry.bpType === "expandable") {
        // expandable: the section's strategy. A changed child-id sequence → ONE coarse
        // replace-block of the rebuilt subtree; identical → the summary patch, then
        // each changed child's interior patch (nested ids resolve in patch.ex).
        if (sectionChildSeqChanged(prevNode, entry.node)) {
          ops.push({
            op: "replace-block",
            id: entry.id,
            block: carryUnmodeledKeys(prevBlock, expandableNodeToBlock(entry.node, entry.id, taken, nextNodeToBlock), "expandable"),
          });
        } else {
          if (expandableSummaryChanged(prevNode, entry.node)) {
            ops.push({ op: "patch-block", id: entry.id, patch: expandableSummaryPatch(entry.node) });
          }
          for (const childOp of expandableChildPatchOps(prevNode, entry.node, prevBlock)) {
            ops.push(childOp);
          }
        }
        continue;
      }
      if (entry.bpType === "section") {
        // section: op strategy hinges on whether the child-id SEQUENCE changed:
        //   * DIFFERS (child add/remove/reorder/reparent, or a canvas-created null-id
        //     child) → ONE coarse replace-block carrying the fully-rebuilt section
        //     subtree; sectionNodeToBlock mints ids for null children off the
        //     CALL-SHARED `taken`.
        //   * IDENTICAL → recurse per-child fine-grained patch-block{id:childId,patch}
        //     for each child whose INTERIOR changed; an unchanged section emits NOTHING.
        // NEVER a move-block/append-block on a nested id (top-level only, patch.ex:42).
        if (sectionChildSeqChanged(prevNode, entry.node)) {
          ops.push({
            op: "replace-block",
            id: entry.id,
            block: carryUnmodeledKeys(prevBlock, sectionNodeToBlock(entry.node, entry.id, taken, nextNodeToBlock), "section"),
          });
        } else {
          // Fine-grained path: the section's own LAYOUT and TITLE are each diffed
          // separately from its children (a layout- or title-only edit leaves the
          // child-id seq identical, so without this it would emit nothing and revert).
          // Emit the LAYOUT patch FIRST (step 2), THEN the title patch, THEN each
          // changed child's interior patch. patch.ex shallow-merges {layout} onto the
          // section; {layout:null} → compose stack path (reader parity, mirrors title).
          if (sectionLayoutChanged(prevNode, entry.node)) {
            ops.push({
              op: "patch-block",
              id: entry.id,
              patch: sectionLayoutPatch(entry.node),
            });
          }
          if (sectionTitleChanged(prevNode, entry.node)) {
            ops.push({
              op: "patch-block",
              id: entry.id,
              patch: sectionTitlePatch(entry.node),
            });
          }
          for (const childOp of sectionChildPatchOps(prevNode, entry.node, prevBlock)) {
            ops.push(childOp);
          }
        }
      } else if (entry.bpType === "terminal") {
        // terminal: the V1 COARSE whole-body+chrome round-trip. ANY interior change
        // (a body keystroke, a child add/delete/reorder, a title/footer/live edit)
        // re-emits ONE patch-block replacing children + chrome scalars. An UNEDITED
        // terminal emits NO op. patch.ex shallow-merges, leaving unknown sibling keys
        // (a legacy `blocks` key) intact.
        if (terminalNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: terminalNodeToPatch(entry.node),
          });
        }
      } else {
        // columns: the V1 COARSE round-trip. ANY interior change (a keystroke in a
        // column, a child add/delete, a column-child reorder) re-emits ONE patch-block
        // REPLACING the whole `columns` array. An UNEDITED columns emits NO op
        // (canonical compare on the reconstructed columns). patch.ex merges
        // { columns:[…] } into the block content, leaving unknown sibling keys intact.
        if (columnsNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: { columns: columnsNodeToColumns(entry.node) },
          });
        }
      }
      continue;
    }

    if (entry.isTaskList) {
      // Canvas task-list widget (live-data): the QUERY is the WHOLE editable datum
      // (+ optional title/config); the rows are server-painted, never on the node.
      // Emit ONE patch-block{query,…} when the editable data changed; the shallow
      // patch-block merge replaces the stored query and leaves unknown sibling keys
      // intact. An UNEDITED task-list emits NO op (canonical compare on
      // query+title+config). prevNode is passed so title/config only ride the patch
      // when they actually changed.
      if (taskListNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: taskListNodeToPatch(entry.node, prevNode),
        });
      }
      continue;
    }

    if (entry.isIsland) {
      // Island atom: one patch-block of the editable keys when any changed.
      if (islandNodeChanged(prevNode, entry.node)) {
        ops.push({ op: "patch-block", id: entry.id, patch: islandNodeToPatch(entry.node) });
      }
      continue;
    }

    if (entry.isImage) {
      // Canvas image atom (editable-image): src + alt are the editable interior;
      // one patch-block{src, alt} when either changed, nothing for a pure reorder.
      if (imageNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: imageNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isFigure) {
      // Canvas figure atom (editable-figure): the caption is the WHOLE editable
      // interior (the child is immutable in v1). Emit ONE patch-block{caption} when
      // the caption changed; the shallow patch-block merge leaves `child` untouched.
      // An UNEDITED figure emits NO op (canonical compare on caption + child).
      if (figureNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: figureNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isFleet) {
      // Canvas FLEET atom (pd-ee-fleet-editors): the authored content — cards/notes/
      // pipeline items and the task-* query/id config — rides VERBATIM on `bpBlock`
      // and is edited by the node-view's structured EDIT ISLAND (embed-node.js). This
      // is the read-only-atom shape made EDITABLE (like task-list vs the snapshot
      // fleet): the whole block still round-trips on bpBlock, but a structured edit
      // mutates it via setNodeMarkup → this diff. Emit ONE patch-block carrying the
      // block's EDITABLE PAYLOAD (every key EXCEPT the immutable id/type) when the
      // carried block changed; patch.ex's SHALLOW Map.merge REPLACES the edited
      // arrays/query and leaves unknown sibling keys intact, then the server repaints
      // the fleet HTML (shared/paper.ex push_block_renders / @fleet_render_types — the
      // ONE-producer contract / D8: the canvas never hand-renders fleet markup). An
      // UNEDITED fleet block emits ZERO ops (canonical compare on bpBlock with id
      // ignored — the D3 byte-stability guarantee).
      if (fleetNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: fleetNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isContent) {
      // Canvas content node (callout OR note): diff body + chrome; emit one patch-block
      // carrying ONLY the mutable fields when anything changed. Sub-route by node type.
      if (isNoteType(entry.node.type)) {
        if (noteNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: noteNodeToPatch(entry.node, prevBlock),
          });
        }
        continue;
      }
      if (calloutNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: calloutNodeToPatch(entry.node, prevNode),
        });
      }
      continue;
    }

    if (entry.isCard) {
      // STEP 4 card WIDGET: diff body + chrome (tone/title/media/action); emit ONE
      // patch-block carrying only changed top-level fields. A slot edit overlays onto
      // the authoritative slots map; tone is independent. An unchanged card emits no
      // op, and a tone clear lands as explicit null.
      if (cardNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: cardNodeToPatch(entry.node, prevBlock),
        });
      }
      continue;
    }

    if (entry.isStage) {
      // The stage WIDGET: diff the five scalars; emit ONE patch-block carrying the
      // present-or-null field set when anything changed. An UNCHANGED stage emits NO op
      // (canonical compare). The explicit-null fields make a cleared text/source removal
      // LAND (patch-block can't delete a key otherwise — the card `tone:null` precedent).
      if (stageNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: stageNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (entry.isAttrAtom) {
      // Canvas attr-atom node (S3.3: code; S3.4: diagram): diff the body + optional
      // field; emit one patch-block carrying the body (always) + the optional field
      // (the string, "" when cleared) when changed. Dispatch by NODE type:
      //   bpDiagram → source/caption (diagramNodeChanged / diagramNodeToPatch);
      //   bpCode    → value/lang     (codeNodeChanged    / codeNodeToPatch).
      if (entry.node.type === "bpDiagram") {
        if (diagramNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: diagramNodeToPatch(entry.node),
          });
        }
        continue;
      }
      if (isTechnicalAtomNode(entry.node.type)) {
        if (technicalNodeChanged(prevNode, entry.node)) {
          ops.push({
            op: "patch-block",
            id: entry.id,
            patch: technicalNodeToPatch(entry.node, prevNode),
          });
        }
        continue;
      }
      if (codeNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: codeNodeToPatch(entry.node, prevNode),
        });
      }
      continue;
    }

    if (entry.isField) {
      // Canvas control-atom node (S3.5: the 7 native field-* types): diff the VALUE
      // (the only mutable datum); emit one patch-block carrying { value } — EXACTLY
      // the BarkparkFieldBlockBridge shape — when it changed. The value is normalized
      // to its per-type stored form (boolean for field-boolean; string otherwise) so
      // a canvas field edit persists IDENTICALLY to a per-block field edit. An
      // UNCHANGED field emits NO op (canonical compare on the normalized value).
      if (fieldNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: fieldNodeToPatch(entry.node, prevNode),
        });
      }
      continue;
    }

    if (entry.isAction) {
      // Canvas control-atom node (editable-action): diff href/label/priority; emit ONE
      // COARSE whole-attrs patch-block (href/label/priority threaded when set) when it
      // changed. prevNode is reconstructed via runToTiptap([prevBlock]) so the compare
      // is apples-to-apples. An UNCHANGED action (incl. a nil→secondary re-select)
      // emits NO op (canonical compare collapses nil≡secondary).
      if (actionNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: actionNodeToPatch(entry.node),
        });
      }
      continue;
    }

    // A same-id block whose KIND changed (turn-into, Backspace lift, `> ` on an existing
    // paragraph): patch-block cannot change `type`, so replace the block wholesale, same id.
    const prevKind = prevBlock ? blockKind(prevBlock) : null;
    if (prevBlock && prevKind !== entry.bpType && CONVERTIBLE_KINDS.has(prevKind) && CONVERTIBLE_KINDS.has(entry.bpType)) {
      const fields = entry.isRole
        ? roleNodeToPatch(entry.node)
        : tiptapToBlock(nodeToDocEnvelope(entry.node), entry.id, entry.bpType);
      ops.push({ op: "replace-block", id: entry.id, block: { ...fields, id: entry.id, type: entry.bpType } });
      continue;
    }

    if (entry.isRole) {
      // Article-chrome role node (eyebrow/byline/ingress/pullquote): diff the single
      // mutable body (text/items/content); emit one patch-block carrying only that
      // field when it changed. An UNCHANGED role emits NO op (canonical compare on the
      // DERIVED body — for a byline the split items, so join/split is idempotent).
      if (roleNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: roleNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (proseNodeChanged(prevNode, entry.node)) {
      const bpType = entry.bpType || (prevBlock && prevBlock.type);
      const op = buildPatchBlockOp(nodeToDocEnvelope(entry.node), entry.id, bpType);
      ops.push({ ...op, patch: withListStartDrop(withAlignDrop(op.patch, entry.node, prevBlock), entry.node, prevBlock) });
    }
  }

  return ops;
}
