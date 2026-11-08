import { buildPatchBlockOp, tiptapToBlock } from "../convert.js";
import { canonicalJSON, deepClone } from "./projection-json.js";
import {
  calloutNodeChanged, calloutNodeToPatch, cardNodeChanged, cardNodeToPatch, noteNodeChanged,
  noteNodeToPatch,
} from "./run-content-codecs.js";
import { withAlignDrop } from "./run-diff-utils.js";
import {
  BP_COLUMN_ATOM_NODE_NAME, BP_TERMINAL_ATOM_NODE_NAME, CANVAS_CONTAINER_BP_TYPE_BY_NODE,
  CANVAS_ROWS, isNoteType, isPlainObject,
} from "./run-kinds.js";
import {
  classifyNode, isEmptyParagraphBlock, mintId, nodeToDocEnvelope, proseNodeChanged,
} from "./run-node-core.js";
import { expandableBody } from "./run-project.js";
import {
  codeNodeChanged, codeNodeToPatch, diagramNodeChanged, diagramNodeToPatch, isTechnicalAtomNode,
  roleNodeChanged, roleNodeToPatch, stageNodeChanged, stageNodeToPatch, technicalNodeChanged,
  technicalNodeToPatch,
} from "./run-scalar-codecs.js";
import {
  fieldNodeChanged, fieldNodeToPatch, imageNodeChanged, imageNodeToPatch, islandNodeChanged,
  islandNodeToPatch, readOnlyAtomRetargetPatch,
} from "./run-structured-codecs.js";

// sectionNodeToBlock(node, id, taken) → the reconstructed `section` block. Each child
// keeps its bpId or is CLIENT-MINTED one from the CALL-SHARED `taken` set (so a nested
// mint never collides with a nested prev id — the duplicate_id-abort guard). RECURSES:
// a nested bpOpaque section child rebuilds verbatim via nextNodeToBlock's opaque path.
// A container rebuilt from its canvas node (a replace-block, or a rows patch) is
// reconstructed from the keys the node models. Keys the node does NOT model — an
// author's own metadata, a producer's provenance, any key a newer schema added —
// are carried over from the stored block so a rebuild never drops them. Found by
// mounting the whole pd-parity inventory: opening a section / expandable whose
// children had no ids yet replaced it without its unknown keys.
const CONTAINER_MODELED_KEYS = {
  section: ["id", "type", "title", "layout", "variant", "blocks", "children", "cells", "locked", "role"],
  expandable: ["id", "type", "summary", "open", "blocks", "children", "locked", "role"],
};
function carryUnmodeledKeys(prevBlock, rebuilt, bpType) {
  const modeled = CONTAINER_MODELED_KEYS[bpType];
  if (!modeled || !isPlainObject(prevBlock)) return rebuilt;
  const out = { ...rebuilt };
  for (const [k, v] of Object.entries(prevBlock)) {
    if (!modeled.includes(k) && !Object.hasOwn(out, k)) out[k] = deepClone(v);
  }
  return out;
}
// Rows (steps / tabs): each rebuilt row keeps its stored row's unmodeled keys, and a
// stored row that carried no body key at all does not gain an empty one.
function carryRowKeys(prevRows, rows, spec) {
  if (!Array.isArray(prevRows)) return rows;
  const byId = new Map(prevRows.filter((r) => isPlainObject(r) && r.id != null).map((r) => [r.id, r]));
  const modeled = ["id", spec.titleKey, "blocks", "children"];
  return rows.map((row, i) => {
    const prev = byId.get(row.id) || (isPlainObject(prevRows[i]) && prevRows[i].id == null ? prevRows[i] : null);
    if (!prev) return row;
    const out = { ...row };
    for (const [k, v] of Object.entries(prev)) {
      if (!modeled.includes(k) && !Object.hasOwn(out, k)) out[k] = deepClone(v);
    }
    const bodyless = !Object.hasOwn(prev, "blocks") && !Object.hasOwn(prev, "children");
    if (bodyless && Array.isArray(out.blocks) && out.blocks.length === 0) delete out.blocks;
    return out;
  });
}

function sectionNodeToBlock(node, id, taken, nextNodeToBlock) {
  const seen = taken || new Set();
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "section" };
  if (attrs.title != null) block.title = attrs.title;
  // STEP-2: lower the layout VERBATIM (present-only; NO cells inside — cells is a
  // SEPARATE attr). The persisted layout stays cells-free (doctrine: span/order
  // live on children, hoisted into attrs.cells for canvas transport only).
  if (attrs.layout != null) block.layout = attrs.layout;
  // FRAMED-FINALE (charter D34): lower the scalar variant back, present-only. This
  // ONE site covers replace-block, insert, docToBlocks AND the source-mode
  // sentinels — every reconstruction path funnels through here.
  if (attrs.variant != null) block.variant = attrs.variant;

  // STEP-6: cells is a bpId-keyed OBJECT map (not a positional array). Split each
  // child's cell back BY THE CHILD'S OWN bpId, so a canvas reorder (which changes
  // content order but leaves attrs.cells untouched) pulls the correct span/order
  // onto each child regardless of position — the reorder-safety fix.
  const cells =
    attrs.cells && typeof attrs.cells === "object" && !Array.isArray(attrs.cells)
      ? attrs.cells
      : null;

  const children = (node && node.content) || [];
  block.blocks = children.map((child) => {
    const cls = classifyNode(child);
    const childBpId = child.attrs && child.attrs.bpId;
    const cid = childBpId != null ? childBpId : mintId(seen);
    const built = nextNodeToBlock({ ...cls, id: cid, isNew: childBpId == null }, seen);
    // Key by the child's OWN bpId (present-only). A canvas-new (null-bpId) child has
    // NO cell — correct, a freshly created child carries no span/order.
    const cell = cells && childBpId != null && Object.hasOwn(cells, childBpId)
      ? cells[childBpId] : child.attrs?.bpSectionCell;
    if (cell && cell.span != null) built.span = cell.span;
    if (cell && cell.order != null) built.order = cell.order;
    return built;
  });
  return block;
}

function expandableNodeToBlock(node, id, taken, nextNodeToBlock) {
  const seen = taken || new Set();
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "expandable" };
  if (attrs.summary != null) block.summary = attrs.summary;
  if (attrs.open != null) block.open = attrs.open === true;
  const key = attrs.bodyKey === "children" ? "children" : "blocks";
  block[key] = ((node && node.content) || []).map((child) => {
    const cls = classifyNode(child);
    const childBpId = child.attrs && child.attrs.bpId;
    const cid = childBpId != null ? childBpId : mintId(seen);
    return nextNodeToBlock({ ...cls, id: cid, isNew: childBpId == null }, seen);
  });
  return block;
}

function expandableSummaryChanged(prevNode, nextNode) {
  const norm = (n) => {
    const t = n && n.attrs && n.attrs.summary;
    return t == null || t === "" ? null : t;
  };
  return norm(prevNode) !== norm(nextNode);
}

function expandableSummaryPatch(nextNode) {
  const t = nextNode && nextNode.attrs && nextNode.attrs.summary;
  return { summary: t == null || t === "" ? null : t };
}

// Per-child interior patches when the child-id sequence is unchanged — the section's
// helper, fed the body under whichever key the persisted block keeps it.
function expandableChildPatchOps(prevNode, nextNode, prevBlock) {
  const { children } = expandableBody(prevBlock);
  return sectionChildPatchOps(prevNode, nextNode, { blocks: children });
}

function stableExpandableKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    summary: a.summary == null || a.summary === "" ? null : a.summary,
    open: a.open == null ? null : a.open === true,
    content: node.content || null,
  });
}

// The rows array from a container node: row ids kept or minted, titles present-only,
// children reconstructed with ids (an empty seed paragraph strips back to []).
function rowsNodeToRows(node, bpType, taken, nextNodeToBlock) {
  const spec = CANVAS_ROWS[bpType];
  const seen = taken || new Set();
  return ((node && node.content) || []).map((rowNode) => {
    const a = (rowNode && rowNode.attrs) || {};
    const row = {};
    if (a.bpId != null) row.id = a.bpId;
    else if (bpType !== "tabs" || a.bpSourceIdMissing !== true) row.id = mintId(seen);
    if (a.title != null && a.title !== "") row[spec.titleKey] = a.title;
    const key = a.bodyKey === "children" ? "children" : "blocks";
    const only = (rowNode && rowNode.content) || [];
    const kids = only.map((child) => {
      const cls = classifyNode(child);
      const childBpId = child.attrs && child.attrs.bpId;
      const cid = childBpId != null ? childBpId : mintId(seen);
      return nextNodeToBlock({ ...cls, id: cid, isNew: childBpId == null }, seen);
    });
    // The paragraph the projection seeds into an empty row (canvas-created, no id)
    // strips back to [] so an empty row round-trips byte-identically; a server-held
    // empty paragraph (it has an id) is content and stays.
    const seeded =
      only.length === 1 &&
      only[0].type === "paragraph" &&
      !(only[0].attrs && only[0].attrs.bpId != null) &&
      isEmptyParagraphBlock(kids[0]);
    row[key] = seeded ? [] : kids;
    return row;
  });
}

function rowsNodeToBlock(node, id, taken, nextNodeToBlock) {
  const bpType = CANVAS_CONTAINER_BP_TYPE_BY_NODE[node && node.type] || "steps";
  const spec = CANVAS_ROWS[bpType];
  return { id, type: bpType, [spec.rowsKey]: rowsNodeToRows(node, bpType, taken, nextNodeToBlock) };
}

// Canonical shape without minted ids: titles, body keys and the nested content as the
// node carries it (child bpIds included; a canvas-new child is null on both sides only
// when unchanged, so an unedited container compares equal).
function stableRowsKey(node) {
  return canonicalJSON(((node && node.content) || []).map((r) => ({
    id: r.attrs && r.attrs.bpId != null ? r.attrs.bpId : null,
    title: r.attrs && r.attrs.title != null && r.attrs.title !== "" ? r.attrs.title : null,
    bodyKey: (r.attrs && r.attrs.bodyKey) || "blocks",
    content: r.content || null,
  })));
}

function rowsNodeChanged(prevNode, nextNode) {
  return stableRowsKey(prevNode) !== stableRowsKey(nextNode);
}

// The child-id sequence of a section node (each child's bpId, or null for a
// canvas-created child). Structural equality of this sequence is the coarse-path
// pivot: ANY difference (add / remove / reorder / reparent / a null-id child) →
// replace-block the whole rebuilt subtree; an IDENTICAL sequence → recurse per-child
// fine-grained patches.
function sectionChildIdSeq(node) {
  return ((node && node.content) || []).map((c) =>
    c && c.attrs && c.attrs.bpId != null ? c.attrs.bpId : null,
  );
}

// True when two child-id sequences differ (length or any position). A null-id child
// makes them differ (a null !== a real prev id), forcing the coarse replace path.
function sectionChildSeqChanged(prevNode, nextNode) {
  const a = sectionChildIdSeq(prevNode);
  const b = sectionChildIdSeq(nextNode);
  if (a.length !== b.length) return true;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return true;
  }
  return false;
}

// True when a section node's OWN title attr changed prev↔next (independent of its
// children). The fine-grained else path (identical child-id seq) diffs child interiors
// only — WITHOUT this a title-only edit would emit ZERO ops and silently revert to the
// server title on the next echo. Normalizes absent/"" to null (both mean "no title"),
// so a "" ⇄ absent flip is NOT a spurious change.
function sectionTitleChanged(prevNode, nextNode) {
  const norm = (n) => {
    const t = n && n.attrs && n.attrs.title;
    return t == null || t === "" ? null : t;
  };
  return norm(prevNode) !== norm(nextNode);
}

// The title patch for a section: { title } when set, { title: null } when cleared
// (patch.ex drops a null key → the section renders no title line, reader parity). The
// SAME normalization as sectionNodeToBlock (attrs.title != null gates block.title).
function sectionTitlePatch(nextNode) {
  const t = nextNode && nextNode.attrs && nextNode.attrs.title;
  return { title: t == null || t === "" ? null : t };
}

// STEP-2: True when a section node's OWN `layout` attr changed prev↔next
// (independent of its children / title). Compares canonicalJSON of the normalized
// layout — cells are EXCLUDED (cells is not a layout key, it is a separate attr), so
// a hypothetical span echo never masquerades as a layout change (RISK #4). A missing
// layout normalizes to null, so absent ⇄ absent is NOT a change (zero-ops on an
// unedited no-layout section).
function normLayout(node) {
  const l = node && node.attrs && node.attrs.layout;
  return l == null ? null : l;
}

function sectionLayoutChanged(prevNode, nextNode) {
  return canonicalJSON(normLayout(prevNode)) !== canonicalJSON(normLayout(nextNode));
}

// The layout patch for a section: { layout } when set, { layout: null } when cleared.
// patch.ex merge_block shallow-merges {layout:{…}} onto the section; {layout:null}
// merges null → compose grid_layout→nil→stack (reader parity, mirrors title:null).
function sectionLayoutPatch(nextNode) {
  const l = nextNode && nextNode.attrs && nextNode.attrs.layout;
  return { layout: l == null ? null : l };
}

// When a section's child-id sequence is IDENTICAL prev↔next (no structural change),
// emit a fine-grained patch-block per child whose INTERIOR changed — keyed by the
// childId (patch.ex resolves nested ids). Reuses the SAME per-kind change-detectors as
// the top-level patch pass. Returns an ordered op list.
function sectionChildPatchOps(prevNode, nextNode, prevBlock) {
  const ops = [];
  const prevChildren = (prevNode && prevNode.content) || [];
  const nextChildren = (nextNode && nextNode.content) || [];
  const prevBlocks = Array.isArray(prevBlock && prevBlock.blocks) ? prevBlock.blocks : [];
  for (let i = 0; i < nextChildren.length; i++) {
    const nextChild = nextChildren[i];
    const prevChild = prevChildren[i];
    const cid = nextChild && nextChild.attrs && nextChild.attrs.bpId;
    if (cid == null) continue; // an identical seq means every child has an id
    const cls = classifyNode(nextChild);
    const patch = childInteriorPatch(cls, prevChild, nextChild, cid, prevBlocks[i]);
    if (patch) ops.push({ op: "patch-block", id: cid, patch });
  }
  return ops;
}

// The mutable-fields patch for a nested child whose interior changed, dispatched by
// its canvas KIND — the SAME detectors + patch builders the top-level patch pass uses.
// Returns null when unchanged (or a no-interior kind: atom / read-only / fleet /
// opaque never report an interior change). A nested container is impossible (v1
// forbids it), so there is no recursive container case here.
function childInteriorPatch(cls, prevChild, nextChild, cid, prevBlock) {
  if (cls.isContent) {
    // callout OR note (the notes-grid split) — sub-route by node type.
    if (isNoteType(nextChild && nextChild.type)) {
      return noteNodeChanged(prevChild, nextChild)
        ? noteNodeToPatch(nextChild, prevBlock)
        : null;
    }
    return calloutNodeChanged(prevChild, nextChild)
      ? calloutNodeToPatch(nextChild, prevChild)
      : null;
  }
  if (cls.isCard) {
    // STEP 4: a card child of a grid section — diff body + chrome; emit the slots+tone
    // patch when it changed (the same detector/builder the top-level pass uses).
    return cardNodeChanged(prevChild, nextChild)
      ? cardNodeToPatch(nextChild, prevBlock)
      : null;
  }
  if (cls.isStage) {
    // A stage child of a section (a pipeline flow) — diff the five scalars; emit the
    // present-or-null patch when it changed (same detector/builder as the top-level pass).
    return stageNodeChanged(prevChild, nextChild) ? stageNodeToPatch(nextChild) : null;
  }
  if (cls.isIsland) {
    return islandNodeChanged(prevChild, nextChild) ? islandNodeToPatch(nextChild) : null;
  }
  if (cls.isImage) {
    return imageNodeChanged(prevChild, nextChild) ? imageNodeToPatch(nextChild) : null;
  }
  if (cls.isAttrAtom) {
    if (nextChild.type === "bpDiagram") {
      return diagramNodeChanged(prevChild, nextChild)
        ? diagramNodeToPatch(nextChild)
        : null;
    }
    if (isTechnicalAtomNode(nextChild.type)) {
      return technicalNodeChanged(prevChild, nextChild)
        ? technicalNodeToPatch(nextChild, prevChild)
        : null;
    }
    return codeNodeChanged(prevChild, nextChild)
      ? codeNodeToPatch(nextChild, prevChild)
      : null;
  }
  if (cls.isField) {
    return fieldNodeChanged(prevChild, nextChild)
      ? fieldNodeToPatch(nextChild, prevChild)
      : null;
  }
  if (cls.isRole) {
    return roleNodeChanged(prevChild, nextChild)
      ? roleNodeToPatch(nextChild)
      : null;
  }
  if (cls.isReadOnlyAtom) {
    // A nested sheet / embed child can be retargeted exactly like a top-level one —
    // the node-view is the same factory wherever the atom sits — so the one interior
    // change it can report is diffed here too. null for any other read-only atom.
    return readOnlyAtomRetargetPatch(cls.bpType, prevChild, nextChild);
  }
  if (cls.isAtom || cls.isFleet || cls.isOpaque) {
    // No interior to patch — a divider / fleet / opaque child never reports a content
    // change (identical child-id sequence + verbatim carry).
    return null;
  }
  // Prose child (paragraph / heading / list).
  if (proseNodeChanged(prevChild, nextChild)) {
    const bpType =
      cls.bpType || (prevChild && prevChild.attrs && prevChild.attrs.bpType);
    const patch = buildPatchBlockOp(nodeToDocEnvelope(nextChild), cid, bpType).patch;
    // A checklist turned back into a plain list must clear task (patch-block merges keys).
    if (bpType === "list" && prevBlock && prevBlock.task === true && patch.task !== true) patch.task = false;
    return withAlignDrop(patch, nextChild, prevBlock);
  }
  return null;
}

// Reconstruct ONE column child NODE → its portable-doc block (the inverse of
// childBlockToNode). bpColumnAtom → the carried bpBlock VERBATIM (deep-cloned). divider
// → { type:"divider" }. prose → the per-type block via tiptapToBlock (NO id — child ids
// are omitted for byte-parity with id-less fixtures).
function childNodeToBlock(childNode) {
  const type = childNode && childNode.type;
  if (type === BP_COLUMN_ATOM_NODE_NAME) {
    const bpBlock = childNode.attrs && childNode.attrs.bpBlock;
    if (bpBlock != null) return deepClone(bpBlock);
    return { type: (childNode.attrs && childNode.attrs.bpType) || "paragraph" };
  }
  if (type === "divider") return { type: "divider" };
  const env = nodeToDocEnvelope(childNode);
  if (type === "heading") return { type: "heading", ...tiptapToBlock(env, null, "heading") };
  if (type === "bulletList" || type === "orderedList" || type === "taskList") {
    return { type: "list", ...tiptapToBlock(env, null, "list") };
  }
  return { type: "paragraph", ...tiptapToBlock(env, null, "paragraph") };
}

// Reconstruct ONE bpColumn node → its column (a LIST OF blocks). A lone empty-paragraph
// sentinel (the seed for an empty source column) collapses back to `[]`.
function columnNodeChildren(colNode) {
  const kids = ((colNode && colNode.content) || []).map(childNodeToBlock);
  if (kids.length === 1 && isEmptyParagraphBlock(kids[0])) return [];
  return kids;
}

// columnsNodeToColumns(node) → the `columns` array of portable-doc blocks (a list of
// columns, each a list of blocks). The projection columnsNodeToBlock uses minus id/type
// — and the SAME derivation the coarse diff (columnsNodeChanged) and the patch use, so
// an UNEDITED columns emits ZERO ops (the reconstruction is byte-stable).
function columnsNodeToColumns(node) {
  return ((node && node.content) || []).map(columnNodeChildren);
}

// columnsNodeToBlock(node, id) → { id, type:"columns", columns:[…] }
//
// Reconstruct the whole columns block from a bpColumns node (used by docToBlocks + the
// insert path). NOTE: a SURVIVING columns block never rebuilds through this — its diff
// emits ONLY a `{columns:[…]}` patch (patch.ex merges it, so unknown sibling keys
// survive). This full rebuild is for a genuinely-NEW columns block (no unknown keys) and
// the source-mode baseline.
function columnsNodeToBlock(node, id) {
  return { id, type: "columns", columns: columnsNodeToColumns(node) };
}

// True when a columns node's interior changed (any child edit / add / delete / reorder
// in any column). CRITICAL: an UNEDITED columns must emit ZERO ops (else every mount
// spuriously patches). We compare the canonical (key-order-insensitive) projection of
// the reconstructed `columns` array — which reconstructs to BLOCKS and thus IGNORES
// child node attrs (phantom null bpId/bpType a nested paragraph gains via BpAttrs), so
// the coarse diff is immune to the depth>0 attr-presence gap.
function columnsNodeChanged(prevNode, nextNode) {
  return (
    canonicalJSON(columnsNodeToColumns(prevNode)) !==
    canonicalJSON(columnsNodeToColumns(nextNode))
  );
}

// Reconstruct ONE terminal body child NODE → its portable-doc block (inverse of
// terminalChildBlockToNode). bpTerminalAtom → the carried bpBlock VERBATIM; divider →
// { type:"divider" }; prose → the per-type block via tiptapToBlock (NO id — child ids
// are omitted for byte-parity with id-less fixtures).
function terminalChildNodeToBlock(childNode) {
  const type = childNode && childNode.type;
  if (type === BP_TERMINAL_ATOM_NODE_NAME) {
    const bpBlock = childNode.attrs && childNode.attrs.bpBlock;
    if (bpBlock != null) return deepClone(bpBlock);
    return { type: (childNode.attrs && childNode.attrs.bpType) || "paragraph" };
  }
  if (type === "divider") return { type: "divider" };
  const env = nodeToDocEnvelope(childNode);
  if (type === "heading") return { type: "heading", ...tiptapToBlock(env, null, "heading") };
  if (type === "bulletList" || type === "orderedList" || type === "taskList") {
    return { type: "list", ...tiptapToBlock(env, null, "list") };
  }
  return { type: "paragraph", ...tiptapToBlock(env, null, "paragraph") };
}

// terminalNodeChildren(node) → the body child BLOCK array. A lone empty-paragraph
// sentinel (an empty source body's seed) collapses back to []. The SAME derivation the
// coarse diff (terminalNodeChanged), the patch, and the insert reconstruction share, so
// an UNEDITED terminal is byte-stable (→ ZERO ops).
function terminalNodeChildren(node) {
  const kids = ((node && node.content) || []).map(terminalChildNodeToBlock);
  if (kids.length === 1 && isEmptyParagraphBlock(kids[0])) return [];
  return kids;
}

// terminalNodeToBlock(node, id) → { id, type:"terminal", children:[…], title?, footer?,
//   live? } — the INSERT path (a genuinely-NEW terminal, no unknown sibling keys). OMITS
// absent chrome: title/footer only when != null, live only when true (byte-parity with
// the reader emitting nothing for absent chrome).
function terminalNodeToBlock(node, id) {
  const a = (node && node.attrs) || {};
  const block = { id, type: "terminal", children: terminalNodeChildren(node) };
  if (a.title != null) block.title = a.title;
  if (a.footer != null) block.footer = a.footer;
  if (a.live === true) block.live = true;
  return block;
}

// terminalNodeToPatch(node) → the COARSE patch (EXPLICIT chrome — the shallow-merge-
// can't-delete contract). Explicit null title/footer + false live so a title-CLEAR /
// live-OFF actually lands; null/false render as absent in compose, so byte-parity holds.
// patch.ex shallow-merges { children, title, footer, live }, overwriting those keys and
// leaving any unknown sibling key (a legacy `blocks`, a custom prop) intact.
function terminalNodeToPatch(node) {
  const a = (node && node.attrs) || {};
  return {
    title: a.title == null ? null : a.title,
    footer: a.footer == null ? null : a.footer,
    live: a.live === true,
    children: terminalNodeChildren(node),
  };
}

// The stable diff key: chrome scalars (normalized) + the RECONSTRUCTED children (→
// blocks, ignoring depth>0 phantom bpId/bpType attrs) so an UNEDITED terminal emits
// ZERO ops (the columns immunity).
function stableTerminalKey(node) {
  const a = (node && node.attrs) || {};
  return {
    title: a.title == null ? null : a.title,
    footer: a.footer == null ? null : a.footer,
    live: a.live === true,
    children: terminalNodeChildren(node),
  };
}

// True when a terminal node's interior OR chrome changed. CRITICAL: an UNEDITED terminal
// must emit ZERO ops. Canonical (key-order-insensitive) compare on the reconstructed key.
function terminalNodeChanged(prevNode, nextNode) {
  return (
    canonicalJSON(stableTerminalKey(prevNode)) !==
    canonicalJSON(stableTerminalKey(nextNode))
  );
}

export {
  carryRowKeys, carryUnmodeledKeys, columnsNodeChanged, columnsNodeToBlock, columnsNodeToColumns,
  expandableChildPatchOps, expandableNodeToBlock, expandableSummaryChanged, expandableSummaryPatch,
  rowsNodeChanged, rowsNodeToBlock, rowsNodeToRows, sectionChildPatchOps, sectionChildSeqChanged,
  sectionLayoutChanged, sectionLayoutPatch, sectionNodeToBlock, sectionTitleChanged,
  sectionTitlePatch, stableExpandableKey, terminalNodeChanged, terminalNodeToBlock,
  terminalNodeToPatch,
};
