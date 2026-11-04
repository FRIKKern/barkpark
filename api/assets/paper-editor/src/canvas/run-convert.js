// run-convert.js — Phase-4 Stage S0: the headless system-of-record projector.
//
// This is the SEED of the continuous canvas. It projects a portable-doc block
// LIST into a SINGLE ProseMirror-style doc JSON (one top-level node per block,
// in order) and diffs an edited doc back into the EXACT op vocabulary the
// server already folds (patch-block / insert-after / remove-block / move-block).
//
// It SHIPS DARK. Nothing imports it — not index.js, not the bundle, not the
// LiveView, not the server. The working per-block <bp-paper-editor> and its
// committed bundle literally cannot regress because this module is unreachable
// at runtime. S0 is the system-of-record proof BEFORE any caret touches a
// screen: it lets us prove the blocks ⇄ one-doc ⇄ ops projection is lossless
// in pure Node, on harness fixtures, with zero UI risk.
//
// PURE, DOM-free, TipTap-free, ProseMirror-free, Node-API-free. It imports
// ONLY from ../convert.js — the same pure converter index.js uses today, so an
// interior edit emitted here is BYTE-IDENTICAL to what the per-block editor
// emits (convert.js:331 buildPatchBlockOp is the shared path).
//
// ── shapes (verified against the real code) ───────────────────────────────
//
//   convert.js:252 blockToTiptap(block) → { type:"doc", content:[ node ] }
//       for a PROSE block (paragraph | heading | list). We lift content[0].
//   convert.js:331 buildPatchBlockOp(editorJSON, id, type)
//       → { op:"patch-block", id, patch:{ ...mutable fields only } }
//
//   patch.ex op wire shapes (api/lib/barkpark/portable_doc/patch.ex):
//       patch-block   patch.ex:153  { "op":"patch-block",  "id":…, "patch":{…} }
//       insert-after  patch.ex:140  { "op":"insert-after",  "afterId":…, "block":{…} }
//       append-block  patch.ex:132  { "op":"append-block",  "block":{…} }
//       remove-block  patch.ex:191  { "op":"remove-block",  "id":… }
//       move-block    patch.ex:203  { "op":"move-block",    "id":…, "after":… | null }
//
// The block kinds convert.js treats as PROSE are exactly paragraph | heading |
// list (convert.js:257-288 — the switch in blockToTiptap). Everything else is
// non-prose and is carried as an OPAQUE placeholder node, verbatim.

import {
  blockToTiptap,
  buildPatchBlockOp,
  listStart,
  tiptapToBlock,
} from "../convert.js";
import { canonicalJSON, deepClone } from "./projection-json.js";
import { tableBlockToNode, tableNodeChanged, tableNodeToBlock, tableNodeToPatch } from "./table-convert.js";
import {
  calloutBlockToNode,
  calloutNodeChanged,
  calloutNodeToBlock,
  calloutNodeToPatch,
  noteBlockToNode,
  noteNodeChanged,
  noteNodeToBlock,
  noteNodeToPatch,
  stableNoteKey,
  cardBlockEditable,
  cardBlockToNode,
  cardNodeChanged,
  cardNodeToBlock,
  cardNodeToPatch,
} from "./run-content-codecs.js";
import {
  codeBlockToNode,
  codeNodeChanged,
  codeNodeToBlock,
  codeNodeToPatch,
  diagramBlockToNode,
  diagramNodeChanged,
  diagramNodeToBlock,
  diagramNodeToPatch,
  isTechnicalAtomNode,
  roleBlockToNode,
  roleNodeChanged,
  roleNodeToBlock,
  roleNodeToPatch,
  stageBlockToNode,
  stageNodeChanged,
  stageNodeToBlock,
  stageNodeToPatch,
  technicalBlockToNode,
  technicalNodeChanged,
  technicalNodeToBlock,
  technicalNodeToPatch,
} from "./run-scalar-codecs.js";
import {
  READ_ONLY_ATOM_RETARGET_KEY,
  actionBlockToNode,
  actionNodeChanged,
  actionNodeToBlock,
  actionNodeToPatch,
  fieldBlockToNode,
  fieldNodeChanged,
  fieldNodeToBlock,
  fieldNodeToPatch,
  figureBlockToNode,
  figureNodeChanged,
  figureNodeToBlock,
  figureNodeToPatch,
  fleetBlockToNode,
  fleetNodeChanged,
  fleetNodeToBlock,
  fleetNodeToPatch,
  imageBlockToNode,
  imageNodeChanged,
  imageNodeToBlock,
  imageNodeToPatch,
  islandBlockToNode,
  islandNodeChanged,
  islandNodeToBlock,
  islandNodeToPatch,
  readOnlyAtomBlockToNode,
  readOnlyAtomNodeToBlock,
  readOnlyAtomRetargetPatch,
  taskListBlockToNode,
  taskListNodeChanged,
  taskListNodeToBlock,
  taskListNodeToPatch,
} from "./run-structured-codecs.js";
import { carryTemplateAttrs, stampTemplateAttrs } from "./run-template-attrs.js";
import {
  isNoteType,
  isCanvasRoleType,
  CONVERTIBLE_NODE_KIND,
  CONVERTIBLE_KINDS,
  blockKind,
  isCanvasTableType,
  tableBlockEditable,
  isCanvasTableNode,
  isCanvasCardType,
  isCanvasCardNode,
  isCanvasStageType,
  isCanvasStageNode,
  TECHNICAL_ATOM_SHAPES,
  CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE,
  CANVAS_PICKER_FIELD_TYPES,
  CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE,
  CANVAS_ISLAND_BP_TYPE_BY_NODE,
  isCanvasIslandType,
  isCanvasIslandNode,
  CANVAS_IMAGE_NODE_NAME,
  isCanvasImageType,
  isCanvasImageNode,
  isCanvasFigureType,
  isCanvasFigureNode,
  isLiveTaskListBlock,
  isCanvasTaskListNode,
  CANVAS_CONTAINER_TYPES,
  CANVAS_CONTAINER_NODE_NAMES,
  CANVAS_EXPANDABLE_NODE_NAME,
  CANVAS_ROWS,
  CANVAS_ROW_NODE_NAMES,
  CANVAS_CONTAINER_NODE_NAME,
  CANVAS_CONTAINER_BP_TYPE_BY_NODE,
  BP_COLUMN_NODE_NAME,
  BP_COLUMN_ATOM_NODE_NAME,
  BP_TERMINAL_ATOM_NODE_NAME,
  isCanvasActionType,
  isCanvasActionNode,
  isProseType,
  isCanvasAtomType,
  isCanvasContentType,
  isCanvasAttrAtomType,
  isCanvasAttrAtomNode,
  isCanvasFieldType,
  isCanvasFieldNode,
  isCanvasReadOnlyAtomType,
  isCanvasReadOnlyAtomNode,
  isCanvasFleetType,
  isCanvasFleetNode,
  isCanvasContainerType,
  isCanvasContainerNode,
  isPlainObject
} from "./run-kinds.js";
export { idCarriesKind } from "./run-kinds.js";



// ── projection: blocks → one doc ───────────────────────────────────────────

// runToTiptap(blocks) → { type:"doc", content:[ node, … ] }
//
// One top-level node per block, IN ORDER. Every node is stamped with
// attrs:{ bpId, bpType } so the reverse diff can key by bpId.
//
//   PROSE block → blockToTiptap(block).content[0] (the single prose node),
//     with { bpId, bpType } MERGED into its attrs (preserving any attrs
//     blockToTiptap already set, e.g. heading level).
//   CANVAS ATOM block (S3: divider) → a native leaf node of that type carrying
//     ONLY { bpId, bpType } attrs — e.g. { type:"divider", attrs:{bpId,bpType} }.
//     No bpBlock: a divider is a content-free leaf, fully described by its type +
//     id, so it round-trips through the canvas schema's own node (divider-node.js)
//     rather than as an opaque blob.
//   OTHER NON-PROSE block → an opaque placeholder:
//       { type:"bpOpaque", attrs:{ bpId, bpType, bpBlock:<deep-cloned block> } }
//     carrying the original block JSON verbatim so it round-trips untouched.
export function runToTiptap(blocks) {
  return { type: "doc", content: (blocks || []).map(blockToNode) };
}

// Declared object block names that WIN over a same-named canvas-native type
// (task-5bc7771edf30199a). A field that declares `blocks.of: [{name:"callout",
// fields:[…]}]` means ITS callout (Sanity's `{tone, text}`), not the canvas's
// built-in: such a block projects as a bpOpaque carry, edited through the field
// dialog (inline-object.js), never through the built-in node. Scoped to ONE
// synchronous call by withObjectOverrides, so two canvases with different
// vocabularies on one page never see each other's set.
let OBJECT_OVERRIDES = null;

export function withObjectOverrides(names, fn) {
  const prev = OBJECT_OVERRIDES;
  OBJECT_OVERRIDES = names && names.size ? names : null;
  try {
    return fn();
  } finally {
    OBJECT_OVERRIDES = prev;
  }
}

// blockToNode(block) → ONE ProseMirror node. The per-block dispatch runToTiptap maps
// over its block list — factored out so a CONTAINER (section) can recurse it over its
// nested children (sectionBlockToNode). The container branch is checked BEFORE the
// opaque fallback so a top-level section projects to the editable bpSection.
function blockToNode(block) {
  {
    const bpId = block && block.id;
    const bpType = block && block.type;

    if (OBJECT_OVERRIDES && OBJECT_OVERRIDES.has(bpType)) {
      return { type: "bpOpaque", attrs: { bpId, bpType, bpBlock: deepClone(block) } };
    }

    if (isProseType(bpType)) {
      // Lift the single prose node convert.js produced and merge our stamp into
      // its attrs without clobbering blockToTiptap's own attrs (heading level).
      const node = blockToTiptap(block).content[0];
      const attrs = { ...(node.attrs || {}), bpId, bpType };
      // Doctrine template attrs (pdd-t2): stamp locked/role so the live PM node
      // carries them (BpAttrs declares them → they survive getJSON, and the
      // filterTransaction veto reads node.attrs.locked). D3 additive: ONLY when
      // present, so an unlocked prose block projects with no locked/role attr and
      // round-trips byte-identically.
      stampTemplateAttrs(attrs, block);
      return { ...node, attrs };
    }

    if (isCanvasAtomType(bpType)) {
      // A canvas atom (divider): a native leaf node of that type, stamped with
      // bpId/bpType only. The canvas schema (divider-node.js) declares the node,
      // so getJSON() round-trips it. No content, no bpBlock — a leaf is fully
      // described by type + id.
      return { type: bpType, attrs: { bpId, bpType } };
    }

    if (isCanvasContentType(bpType)) {
      // A canvas CONTENT node (S3.2: callout; notes-grid split: note): a native node
      // of that type whose BODY is editable inline content. callout chrome (tone/
      // title/collapsible/collapsed) rides node attrs; note chrome (label/lead) rides
      // node attrs too (edited via input islands). The canvas schema declares each, so
      // getJSON() round-trips the body + chrome attrs. Sub-route by bpType.
      if (isNoteType(bpType)) return noteBlockToNode(block, bpId, bpType);
      return calloutBlockToNode(block, bpId, bpType);
    }

    if (isCanvasCardType(bpType)) {
      // STEP 4: the card WIDGET — a slots-native node whose BODY slot becomes an
      // editable inline contentDOM and whose title/tone/media/action ride attrs
      // (present-only). card-node.js declares the bpCard node, so getJSON() round-
      // trips the body + the chrome attrs. node.type is the NODE name (bpCard), not
      // the bpType (card).
      if (cardBlockEditable(block)) return cardBlockToNode(block, bpId, bpType);
      return {
        type: "bpOpaque",
        attrs: { bpId, bpType, bpBlock: deepClone(block) },
      };
    }

    if (isCanvasStageType(bpType)) {
      // The stage WIDGET — a control-atom whose five scalars ride node.attrs (kind/
      // title/detail text + files/source chrome), edited by native controls. stage-
      // node.js declares the bpStage node, so getJSON() round-trips the attrs. node.type
      // is the NODE name (bpStage), not the bpType (stage).
      return stageBlockToNode(block, bpId, bpType);
    }

    if (isCanvasAttrAtomType(bpType)) {
      // A canvas ATTR-ATOM node (S3.3: code; S3.4: diagram): an atom node whose body
      // TEXT rides in an attr (a plain string, edited by a non-PM textarea) plus an
      // optional second field. The canvas schema declares the node (code-node.js /
      // diagram-node.js), so getJSON() round-trips the body + optional field. NOTE the
      // node.type is the NODE name (bpCode / bpDiagram), not the bpType (code /
      // diagram). Dispatch by bpType: code → value/lang; diagram → source/caption.
      if (bpType === "diagram") return diagramBlockToNode(block, bpId, bpType);
      // diff / filetree: the TECHNICAL pair — one verbatim-body attr + optional
      // scalar metadata, driven by TECHNICAL_ATOM_SHAPES.
      if (TECHNICAL_ATOM_SHAPES[bpType])
        return technicalBlockToNode(block, bpId, bpType);
      return codeBlockToNode(block, bpId, bpType);
    }

    if (isCanvasFieldType(bpType)) {
      // A canvas CONTROL-ATOM node (S3.5): the 7 native field-* types PLUS the 2
      // picker types (field-image / field-reference). An atom node whose VALUE rides
      // in an attr, edited by a NATIVE control (the 7) or by a picker WC —
      // bp-media-picker / bp-reference-picker (field-node.js) — for the pickers. ALL
      // project to the SAME `bpField` node, discriminated by the bpType attr. The
      // node carries the FULL config (label/options/rows/fieldName) so the round-trip
      // is byte-identical — UNLIKE code/diagram, a field block has config keys the
      // canvas must not lose. field-image/field-reference ARE in this set
      // (CANVAS_PICKER_FIELD_TYPES): they dispatch here to fieldBlockToNode and mount
      // an editable picker — they are NOT boundaries, do NOT fall through to bpOpaque.
      return fieldBlockToNode(block, bpId, bpType);
    }

    if (isCanvasActionType(bpType)) {
      // A canvas CONTROL-ATOM node (editable-action): a LEAF whose href/label/priority
      // ride attrs, edited by native controls. It projects to the `bpAction` node
      // (node.type !== bpType "action"). Each payload key is threaded ONLY when present
      // (null = absence) so an untouched action's getJSON re-projection matches and
      // emits zero ops.
      return actionBlockToNode(block, bpId, bpType);
    }

    if (isCanvasReadOnlyAtomType(bpType)) {
      // A canvas READ-ONLY ATOM node (S3.6: sheet / embed): an atom node that is a
      // REFERENCE, NOT editable text. It carries the WHOLE block VERBATIM (deep-cloned,
      // no shared ref) on `bpBlock` — the bpOpaque verbatim-carry, but on a
      // canvas-eligible node (so it no longer SPLITS a run) with a dedicated read-only
      // node-view (embed-node.js) instead of the generic opaque placeholder. NOTE the
      // node.type is the NODE name (bpSheet / bpEmbed), not the bpType (sheet / embed).
      return readOnlyAtomBlockToNode(block, bpId, bpType);
    }

    if (isLiveTaskListBlock(block)) {
      // A LIVE task-list WIDGET (a `task-list` carrying a `query` map): an
      // EDITABLE-QUERY + server-painted-ROWS atom (bpTaskList). Checked BEFORE the
      // fleet branch — a snapshot-only task-list (no query) falls through to bpFleet
      // (read-only), the additive presence-of-query discriminant. It carries ONLY the
      // editable data (query/title/config) as typed attrs; the rows are NEVER on the
      // node (server-painted projection). NOTE the node.type is the NODE name
      // (bpTaskList), not the bpType (task-list).
      return taskListBlockToNode(block, bpId, bpType);
    }

    if (isCanvasFleetType(bpType)) {
      // A canvas FLEET node (pdd-t8: tasks / cards / pipeline / form / …): a
      // SERVER-PAINTED read-only atom. Structurally identical to the sheet/embed
      // read-only atom — the WHOLE block rides VERBATIM on `bpBlock`, ZERO
      // value/content ops — but ALL fleet kinds share the ONE `bpFleet` node
      // (discriminated by bpType), and its node-view paints the reader's own pushed
      // HTML (bp:block-html) rather than a client-computed chip. NOTE the node.type
      // is the NODE name (bpFleet), not the bpType.
      return fleetBlockToNode(block, bpId, bpType);
    }

    if (isCanvasIslandType(bpType)) {
      // A "data + island" atom (equation / footnote / toc / video): editable keys on
      // typed attrs, the rest verbatim. node.type is the NODE name, not the bpType.
      return islandBlockToNode(block, bpId, bpType);
    }

    if (isCanvasImageType(bpType)) {
      // A canvas IMAGE atom (editable-image): the picture paints itself; src + alt
      // are typed attrs, the rest of the block rides verbatim. node.type is the NODE
      // name (bpImage), not the bpType (image).
      return imageBlockToNode(block, bpId, bpType);
    }

    if (isCanvasFigureType(bpType)) {
      // A canvas FIGURE atom (editable-figure: figure): a SERVER-PAINTED
      // read-only-child + editable-caption atom. The CHILD rides VERBATIM
      // (deep-cloned) on `bpChild` and paints read-only via the fleet hook; the
      // CAPTION is the sole editable attr (patch-block{caption}). NOTE the node.type
      // is the NODE name (bpFigure), not the bpType (figure).
      return figureBlockToNode(block, bpId, bpType);
    }

    if (isCanvasContainerType(bpType)) {
      // A canvas CONTAINER node — sub-route by bpType (all fold into a run):
      //   * section → bpSection: nested block+ body + editable title; a nested
      //     (depth>=1) section child is carried opaque (V1 forbid-nesting) — see
      //     sectionBlockToNode's depth-guard.
      //   * terminal → bpTerminal: a nested block+ body wrapped in reader chrome
      //     (title/live/footer); non-first-class body children ride a bpTerminalAtom.
      //   * columns → bpColumns: a recursive nested-block node whose column
      //     child-block trees become editable PM regions (prose+divider); any
      //     non-first-class child rides a read-only bpColumnAtom (columns-node.js).
      // node.type is the NODE name (bpSection/bpTerminal/bpColumns), not the bpType.
      if (bpType === "section") return sectionBlockToNode(block, bpId, bpType);
      if (bpType === "expandable") return expandableBlockToNode(block, bpId, bpType);
      if (bpType === "steps" || bpType === "tabs") return rowsBlockToNode(block, bpId, bpType);
      if (bpType === "terminal") return terminalBlockToNode(block, bpId, bpType);
      return columnsBlockToNode(block, bpId, bpType);
    }

    if (isCanvasRoleType(bpType)) {
      // An article-chrome ROLE node (eyebrow / byline / ingress / pullquote): a
      // native prose node of that type whose BODY carries the role's persisted text/
      // items/inline, styled by a bp-role-* class to MATCH THE READER. role-nodes.js
      // declares the node, so getJSON() round-trips the body + bpId/bpType. node.type
      // === bpType (no NODE_NAME indirection).
      return roleBlockToNode(block, bpId, bpType);
    }

    if (isCanvasTableType(bpType)) {
      // The table as a NESTED node tree (bpTable > bpTableRow > cells). Its rows/head
      // live in PM child nodes (each cell body = inline runs), NOT attrs — which is
      // what earns free inline-mark editing. table-node.js declares the four nodes so
      // getJSON() round-trips the whole grid. node.type is the NODE name (bpTable),
      // not the bpType (table).
      if (tableBlockEditable(block)) return tableBlockToNode(block, bpId, bpType);
      return {
        type: "bpOpaque",
        attrs: { bpId, bpType, bpBlock: deepClone(block) },
      };
    }

    // Opaque carry-through: the original block JSON, deep-cloned (no shared refs).
    return {
      type: "bpOpaque",
      attrs: { bpId, bpType, bpBlock: deepClone(block) },
    };
  }
}

// ── section ⇄ canvas container node ─────────────────────────────────────────
//
// A `section` block { id, type:"section", title?, blocks:[child, …] } ⇄ a bpSection
// node { type:"bpSection", attrs:{ bpId, bpType, title? }, content:[childNode, …] }.
// Each child recurses through blockToNode; a nested section child is carried opaque
// (V1 forbid-nesting). The title rides node.attrs, PRESENT-ONLY (a null/absent title
// round-trips as ABSENT, byte-mirroring callout.title).

// sectionBlockToNode(block, bpId, bpType) → the bpSection node.
//
// STEP-2 LAYOUT ENGINE: a section MAY carry `layout` ({mode,tracks?,gap?,
// breakpoints?}) and its children MAY carry span/order. Both are PRESENT-ONLY —
// a no-layout section adds NOTHING new to attrs, so it projects byte-identically
// to the pre-layout path (backward-compat: runToOps zero-ops on open/save).
//
// CELLS HOIST: prose/canvas child nodes DROP unknown keys on getJSON, so a child's
// span/order can't ride the child node without touching ~10 node files. Instead we
// hoist them into the section's OWN declared `cells` attr (a JSON data-attr,
// getJSON-safe — the bpColumnAtom bpBlock precedent), keyed BY CHILD bpId, ONLY
// when some child actually carries span/order. STEP-6 (RISK #1 fix, LANDED): cells
// is a bpId-keyed OBJECT map `{ [childBpId]: { span?, order? } }`, NOT a positional
// array. A positional array misassigned span/order under a canvas reorder (the
// coarse replace path rebuilds children in the new order but attrs.cells is
// independent of content) — bpId keying is position-independent, so a reorder pulls
// each child's OWN cell regardless of where it sits. Present-only: a section with no
// child span/order adds NO cells attr (byte-identical to a plain section).
function sectionBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "section" };
  if (block && block.title != null) attrs.title = block.title;
  if (block && block.layout != null) attrs.layout = block.layout;
  // FRAMED-FINALE (charter D34): the scalar `variant` ("framed") rides node.attrs
  // VERBATIM, PRESENT-ONLY (a no-variant section adds NOTHING — byte-identical to
  // the pre-variant path; mirrors layout above). Without this thread the canvas
  // silently DROPPED the frame on open.
  if (block && block.variant != null) attrs.variant = block.variant;

  const children = (block && block.blocks) || [];

  // Hoist child span/order into a bpId-keyed cells object — present-only (omitted
  // entirely when no child carries either key, so a plain section is unchanged). A
  // child with no id (should not happen for a persisted child) is skipped.
  const cellsById = {};
  for (const child of children) {
    const cid = child && child.id;
    if (cid == null) continue;
    const cell = {};
    if (child.span != null) cell.span = child.span;
    if (child.order != null) cell.order = child.order;
    if (Object.keys(cell).length) cellsById[cid] = cell;
  }
  if (Object.keys(cellsById).length) attrs.cells = cellsById;

  const content = children.map((child) => {
    // DEPTH-GUARD (V1 forbid-nesting): a child of type "section" is carried VERBATIM
    // as bpOpaque (read-only), NOT projected as another bpSection — so a legacy nested
    // section round-trips byte-identical and is never restructured (the silent-lift
    // trap). Every other child projects normally via blockToNode (which itself falls
    // to bpOpaque for a non-canvas child like composite/codelist).
    if (child && isCanvasContainerType(child.type)) {
      return {
        type: "bpOpaque",
        attrs: {
          bpId: child.id,
          bpType: child.type,
          bpBlock: deepClone(child),
        },
      };
    }
    const node = blockToNode(child);
    if (child?.id == null && (child?.span != null || child?.order != null)) {
      const { span, order } = child;
      node.attrs = { ...node.attrs, bpSectionCell: { span, order } };
    }
    return node;
  });

  const node = { type: CANVAS_CONTAINER_NODE_NAME, attrs };
  if (content.length) node.content = content;
  return node;
}

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

function sectionNodeToBlock(node, id, taken) {
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

// ── expandable ⇄ canvas toggle container (bpExpandable) ───────────────────────
//
// { id, type:"expandable", summary?, open?, blocks|children:[child, …] } ⇄ the
// bpExpandable CONTAINER (expandable-node.js): summary/open on attrs, the body as
// nested content, and the persisted body KEY on attrs.bodyKey (patch.ex visible_alias:
// a `children` body stays `children`; the default is `blocks`). Diff strategy, echo
// key and reconstruction mirror the section (child-id sequence → coarse replace, else
// summary patch + per-child interior patches). A container child rides bpOpaque (V1).
function expandableBody(block) {
  if (block && Array.isArray(block.children)) return { key: "children", children: block.children };
  if (block && Array.isArray(block.blocks)) return { key: "blocks", children: block.blocks };
  return { key: "blocks", children: [] };
}

function expandableBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "expandable" };
  if (block && block.summary != null) attrs.summary = block.summary;
  if (block && block.open != null) attrs.open = block.open === true;
  const { key, children } = expandableBody(block);
  if (key !== "blocks") attrs.bodyKey = key;
  const content = children.map((child) =>
    child && isCanvasContainerType(child.type)
      ? { type: "bpOpaque", attrs: { bpId: child.id, bpType: child.type, bpBlock: deepClone(child) } }
      : blockToNode(child),
  );
  const node = { type: CANVAS_EXPANDABLE_NODE_NAME, attrs };
  if (content.length) node.content = content;
  return node;
}

function expandableNodeToBlock(node, id, taken) {
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

// ── steps / tabs ⇄ canvas containers of titled rows (bpSteps / bpTabs) ────────
//
// { id, type:"steps", steps:[ { id?, title?, blocks|children } ] } ⇄ bpSteps > bpStep+
// (tabs: `tabs` rows with `label`). Each row keeps its id (or is minted one), its
// title on attrs, its body key, and its children as nested nodes (a container child
// rides bpOpaque). The diff is COARSE like columns: any change → ONE patch-block
// carrying the whole rebuilt rows array (row and child ids kept, new ones minted off
// the call-shared `taken`), which patch.ex merges onto the block.
function rowsBody(row) {
  if (row && Array.isArray(row.children)) return { key: "children", children: row.children };
  if (row && Array.isArray(row.blocks)) return { key: "blocks", children: row.blocks };
  return { key: "blocks", children: [] };
}

function rowsBlockToNode(block, bpId, bpType) {
  const spec = CANVAS_ROWS[bpType];
  const rows = (block && Array.isArray(block[spec.rowsKey]) ? block[spec.rowsKey] : []).filter((r) => r && typeof r === "object");
  const content = rows.map((row) => {
    const attrs = {
      bpId: row.id != null ? row.id : null,
      bpType: spec.rowName,
      bpSourceIdMissing: bpType === "tabs" && !Object.hasOwn(row, "id"),
    };
    const t = row[spec.titleKey];
    if (t != null) attrs.title = String(t);
    const { key, children } = rowsBody(row);
    if (key !== "blocks") attrs.bodyKey = key;
    const kids = children.map((child) =>
      child && isCanvasContainerType(child.type)
        ? { type: "bpOpaque", attrs: { bpId: child.id, bpType: child.type, bpBlock: deepClone(child) } }
        : blockToNode(child),
    );
    return { type: spec.rowName, attrs, content: kids.length ? kids : [{ type: "paragraph" }] };
  });
  return {
    type: spec.containerName,
    attrs: { bpId, bpType },
    content: content.length ? content : [{ type: spec.rowName, attrs: { bpId: null, bpType: spec.rowName }, content: [{ type: "paragraph" }] }],
  };
}

// The rows array from a container node: row ids kept or minted, titles present-only,
// children reconstructed with ids (an empty seed paragraph strips back to []).
function rowsNodeToRows(node, bpType, taken) {
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

function rowsNodeToBlock(node, id, taken) {
  const bpType = CANVAS_CONTAINER_BP_TYPE_BY_NODE[node && node.type] || "steps";
  const spec = CANVAS_ROWS[bpType];
  return { id, type: bpType, [spec.rowsKey]: rowsNodeToRows(node, bpType, taken) };
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

// ── the duplicate_id-abort guard: recursive id seeds (the make-or-break) ─────
//
// runToOps / docToBlocks mint ids for canvas-created (null-id) blocks. mintId keys
// collision-freedom off a `taken` set. If that set is seeded from TOP-LEVEL ids only,
// a nested child id (living inside block.blocks / a bpSection body's content) is
// INVISIBLE to the seed → a mint can collide with it → patch.ex duplicate_id
// (patch.ex:182/191) ABORTS THE WHOLE ATOMIC BATCH, losing every co-batched edit. The
// two walkers below seed `taken` from the ENTIRE tree (top-level + section bodies at
// any depth), closing that gap.

// Walk a portable-doc BLOCK tree (descend section.blocks at any depth), adding every
// id into `sink`.
function walkBlockIds(blocks, sink) {
  for (const block of blocks || []) {
    if (!block) continue;
    if (block.id != null) sink.add(block.id);
    if (Array.isArray(block.blocks)) walkBlockIds(block.blocks, sink);
    if (Array.isArray(block.children)) walkBlockIds(block.children, sink);
    // steps / tabs rows: each row is an id-bearing container of its own.
    if (Array.isArray(block.steps)) walkBlockIds(block.steps, sink);
    if (Array.isArray(block.tabs)) walkBlockIds(block.tabs, sink);
  }
}

// Every block id → the ids of the blocks holding it (null: the top level), over
// walkBlockIds' scope. A set, because a legacy doc can hold one id in two places.
export function blockParents(blocks, parent = null, out = new Map()) {
  for (const block of blocks) {
    if (!block) continue;
    if (block.id != null) out.set(block.id, (out.get(block.id) || new Set()).add(parent));
    for (const key of ["blocks", "children", "steps", "tabs"]) {
      if (Array.isArray(block[key])) blockParents(block[key], block.id, out);
    }
  }
  return out;
}

// A getJSON node whose children carry block ids the projection keeps: a container
// (section, expandable, steps, tabs, columns) or a steps / tabs row. A column's own
// children and a list's paragraphs carry none.
export function holdsNodeIds(node) {
  return (isCanvasContainerNode(node.type) || CANVAS_ROW_NODE_NAMES.has(node.type)) && Array.isArray(node.content);
}

// Walk a canvas NODE tree (descend a bpSection node's content at any depth), adding
// every node.attrs.bpId into `sink`.
function walkNodeIds(nodes, sink) {
  for (const node of nodes || []) {
    if (!node) continue;
    const id = node.attrs && node.attrs.bpId;
    if (id != null) sink.add(id);
    if (holdsNodeIds(node)) walkNodeIds(node.content, sink);
  }
}



// ── columns ⇄ canvas container node (S10) ────────────────────────────────────
//
// The `columns` block { id, type:"columns", columns:[ [childBlock,…], [childBlock,…] ] }
// ⇄ the TipTap `bpColumns` CONTAINER node (columns-node.js). UNLIKE every other canvas
// node, a columns block's interior is a NESTED BLOCK TREE: `columns` is a LIST OF
// COLUMNS, each column a LIST OF BLOCKS (a list-of-lists — NOT `[{blocks:[…]}]`;
// verified against compose.ex:731-743). Each column maps to a `bpColumn` node holding
// its child blocks; a prose/divider child projects to its NORMAL editable node, and
// ANY other kind (callout/code/sheet/fleet/image/terminal/nested-container/composite/
// table) — none of which is a valid bpColumn child by NAME — is carried VERBATIM on a
// read-only `bpColumnAtom` (else PM would DROP it = DATA LOSS).
//
// V1 COARSE round-trip: any interior change (a keystroke in a column, a child add/
// delete, a column-child reorder) re-emits ONE `patch-block` REPLACING the whole
// `columns` array. patch.ex merges the patch into the block content, so `{columns:[…]}`
// overwrites `columns` and leaves sibling keys (an unknown top-level `children`/`gap`)
// INTACT — byte-fidelity of unknown keys comes for free from patching only `columns`.
//
// node.type is `bpColumns` (the NODE name), NOT `columns` (the bpType).

// True when a reconstructed child block is a lone empty-paragraph SENTINEL — the
// placeholder an EMPTY source column is seeded with so bpColumn's `…+` content is
// satisfiable (PM rejects a contentless container). Stripped on the way back ONLY when
// it is the column's SOLE child, so a truly-empty column round-trips as `[]` while a
// column that also holds real blocks keeps every child (mirrors the featured-
// placeholder sentinel pattern).
function isEmptyParagraphBlock(block) {
  return (
    block &&
    block.type === "paragraph" &&
    (!block.content || block.content.length === 0)
  );
}

// Project ONE column child block → its canvas node. Prose (paragraph/heading/list) →
// its native editable node (via blockToTiptap, the SAME per-block prose path); divider
// → the divider atom; EVERYTHING ELSE → a bpColumnAtom carrying the whole child block
// VERBATIM (deep-cloned) so it round-trips byte-identically and PM never drops it. NO
// bpId/bpType stamp on prose/divider children — the reader ignores child ids, and an
// unstamped node matches the depth>0-normalized live doc (index.js normalizeCanvasDoc
// strips a child's phantom null bpId/bpType).
function childBlockToNode(child) {
  const bpType = child && child.type;
  if (isProseType(bpType)) {
    // The single prose node convert.js produces — the byte-identical per-block path.
    return blockToTiptap(child).content[0];
  }
  if (isCanvasAtomType(bpType)) {
    // divider — a content-free leaf, fully described by its type.
    return { type: bpType };
  }
  // Any non-first-class child → the verbatim read-only carrier.
  return columnAtomBlockToNode(child);
}

// columnAtomBlockToNode(child) → { type:"bpColumnAtom", attrs:{ bpType, bpId?, bpBlock } }
//
// The whole child block is deep-cloned onto bpBlock (no shared ref), so an UNCHANGED
// child round-trips deep-equal to the original. bpType is the CARRIED child's kind (so
// the chip can label it and the reverse read it back). bpId rides only when the child
// carries one (child ids are not load-bearing; fixtures are id-less).
function columnAtomBlockToNode(child) {
  const attrs = { bpType: child && child.type, bpBlock: deepClone(child) };
  if (child && child.id != null) attrs.bpId = child.id;
  return { type: BP_COLUMN_ATOM_NODE_NAME, attrs };
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

// columnsBlockToNode(block) → { type:"bpColumns", attrs:{ bpId, bpType, cols }, content:[bpColumn…] }
//
// Each source column → a bpColumn node holding its child nodes; an EMPTY source column
// is seeded with a single empty paragraph so bpColumn's `…+` content is satisfiable
// (stripped on the way back). A columns block with no columns at all is seeded with one
// empty column. `cols` = the rendered bpColumn count (= max(sourceColumns,1) = the
// reader's own `n`), so `--bp-cols:N` matches the reader.
function columnsBlockToNode(block, bpId, bpType) {
  const srcCols = (block && block.columns) || [];
  const cols = (Array.isArray(srcCols) ? srcCols : []).map((col) => {
    const kids = (Array.isArray(col) ? col : []).map(childBlockToNode);
    return {
      type: BP_COLUMN_NODE_NAME,
      content: kids.length ? kids : [{ type: "paragraph" }],
    };
  });
  const content = cols.length
    ? cols
    : [{ type: BP_COLUMN_NODE_NAME, content: [{ type: "paragraph" }] }];
  return {
    type: CANVAS_CONTAINER_NODE_NAMES[bpType] || "bpColumns",
    attrs: { bpId, bpType, cols: content.length },
    content,
  };
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

// ── terminal ⇄ canvas container node ─────────────────────────────────────────
//
// The `terminal` block { id, type:"terminal", title?, footer?, live?, children:[BLOCK…]
// (or legacy `blocks`) } ⇄ the TipTap `bpTerminal` CONTAINER node (terminal-node.js).
// UNLIKE columns (a list-of-lists) a terminal has a SINGLE body child array + THREE
// chrome scalars (title/footer/live). Each body child maps like a column child: a
// prose/divider child → its NORMAL editable node, ANY other kind (callout/code/sheet/
// fleet/image/nested-container/table) → a VERBATIM read-only `bpTerminalAtom` (else PM
// would DROP it = DATA LOSS). Reader source: compose.ex:708-727 + container_children
// (compose.ex:902 — `children || blocks || []`; canonical key = "children").
//
// V1 COARSE round-trip (mirrors calloutNodeToPatch — EXPLICIT chrome, omit-on-insert):
// any interior change re-emits ONE `patch-block` carrying the whole body child array +
// the three chrome scalars EXPLICITLY (title/footer null, live false) so a title-CLEAR
// / live-OFF actually LANDS through patch.ex's shallow Map.merge (a shallow merge can't
// DELETE a key — so we send explicit null/false, which compose renders byte-identically
// to absent: Map.get(b,"title","") and the live-in-[…] gate — VERIFIED compose.ex).
//
// node.type is `bpTerminal` (the NODE name), NOT `terminal` (the bpType).

// Project ONE terminal body child block → its canvas node. IDENTICAL to childBlockToNode
// (columns) but routes a non-first-class child to a bpTerminalAtom. Prose → native
// editable node; divider → the leaf atom; EVERYTHING ELSE → the verbatim carrier.
function terminalChildBlockToNode(child) {
  const bpType = child && child.type;
  if (isProseType(bpType)) return blockToTiptap(child).content[0];
  if (isCanvasAtomType(bpType)) return { type: bpType };
  return terminalAtomBlockToNode(child);
}

// terminalAtomBlockToNode(child) → { type:"bpTerminalAtom", attrs:{ bpType, bpId?, bpBlock } }
// The whole child block deep-cloned onto bpBlock (no shared ref) so an UNCHANGED child
// round-trips deep-equal. IDENTICAL to columnAtomBlockToNode, only the node name differs.
function terminalAtomBlockToNode(child) {
  const attrs = { bpType: child && child.type, bpBlock: deepClone(child) };
  if (child && child.id != null) attrs.bpId = child.id;
  return { type: BP_TERMINAL_ATOM_NODE_NAME, attrs };
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

// terminalBlockToNode(block) → { type:"bpTerminal", attrs:{ bpId, bpType, title, footer,
//   live }, content:[child…] }. An EMPTY body is seeded with one paragraph so bpTerminal's
// `…+` content is satisfiable (stripped on the way back via the isEmptyParagraphBlock
// sentinel — the columns/featured-placeholder pattern). title/footer normalize to null
// when null; live normalizes the compose [true,"true","live"] gate to a strict boolean.
function terminalBlockToNode(block, bpId, bpType) {
  const src = (block && (block.children || block.blocks)) || [];
  const kids = (Array.isArray(src) ? src : []).map(terminalChildBlockToNode);
  return {
    type: CANVAS_CONTAINER_NODE_NAMES[bpType] || "bpTerminal",
    attrs: {
      bpId,
      bpType,
      title: block && block.title != null ? block.title : null,
      footer: block && block.footer != null ? block.footer : null,
      live: !!(
        block &&
        (block.live === true || block.live === "true" || block.live === "live")
      ),
    },
    content: kids.length ? kids : [{ type: "paragraph" }],
  };
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

// NOTE: `columns`, `section` and `terminal` containers do NOT share a single generic
// dispatcher — each has a materially different op strategy (columns = coarse
// {columns:[…]}; section = seq-changed replace-block else fine-grained child+title
// patches; terminal = coarse whole-body+chrome patch). The op-branch / echo / insert
// paths sub-route by bpType directly and call the per-container round-trip fns
// (columnsNode* / sectionNode* / terminalNode*). Keep in lockstep with
// CANVAS_CONTAINER_TYPES + CANVAS_CONTAINER_BP_TYPE_BY_NODE.

// ── reverse diff: prev blocks + edited doc → ordered ops ────────────────────

// Strip our { bpId, bpType } stamp back off a prose node so the node is the
// plain convert.js shape buildPatchBlockOp expects (it reads node.attrs.level
// for headings; the extra keys are harmless but we keep the doc tidy and the
// emitted op byte-identical to the per-block path by leaving level intact).
//
// We DON'T need to remove bpId/bpType for correctness — buildPatchBlockOp only
// reads top.type, top.attrs.level, top.content — but wrapping the node back in
// the {type:"doc",content:[node]} envelope is what it expects.
function nodeToDocEnvelope(node) {
  return { type: "doc", content: [node] };
}

// ── id minting for new/split blocks ─────────────────────────────────────────
//
// The reverse diff MUST give every next-doc node a KNOWN id, because the op
// vocabulary can only express a front-insert / reorder via move-block, and
// move-block keys by a known id. So a new block (a split, a typed paragraph,
// anything with no surviving bpId) is CLIENT-MINTED an id here.
//
// The id must be unique within the call AND collision-free against every prev
// id and every other minted id — patch.ex rejects a duplicate id on both
// append-block and insert-after. We use a per-call monotonic counter prefixed
// "c-" plus a high-entropy nonce; the caller hands us a `taken` set so we can
// retry on the astronomically-unlikely collision.
function mintId(taken) {
  let id;
  do {
    mintCounter += 1;
    // Counter guarantees per-call uniqueness; the nonce guarantees the id can
    // never collide with a server/prev id of the conventional shape.
    id = "c-" + mintCounter.toString(36) + "-" + randomNonce();
  } while (taken.has(id));
  taken.add(id);
  return id;
}

let mintCounter = 0;

// A short high-entropy token. crypto.randomUUID is a global in modern V8 and
// browsers; fall back to Math.random (uniqueness within a call is all we need —
// the per-call counter already guarantees that, the nonce only widens the gap
// against externally-minted ids).
function randomNonce() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID().slice(0, 8);
  }
  return Math.random().toString(36).slice(2, 10);
}

// True when two prose nodes carry different content (an interior edit). We
// compare the node minus our bp* stamp via a stable JSON of the fields
// buildPatchBlockOp actually reads (type, attrs.level, content). Cheap + exact:
// any text/mark/level/list-shape change flips this; a pure reorder does not.
function proseNodeChanged(prevNode, nextNode) {
  return stableProseKey(prevNode) !== stableProseKey(nextNode);
}

// A deferred remote edit is not part of the author's visible baseline. Allow
// independent fields (and convergent values), but never silently patch over a
// different remote value or remove a remotely changed block. The host owns review.
export function hasOverlappingOps(ops, baseline, remote) {
  if (!Array.isArray(remote)) return false;
  const beforeById = new Map(baseline.map((block) => [block.id, block]));
  const remoteById = new Map(remote.map((block) => [block.id, block]));
  return ops.some((op) => {
    if (op.op !== "patch-block" && op.op !== "remove-block") return false;
    const before = beforeById.get(op.id);
    const latest = remoteById.get(op.id);
    if (!before || !latest) return false;
    if (op.op === "remove-block") return canonicalJSON(before) !== canonicalJSON(latest);
    if (before.type !== latest.type) return true;
    return Object.entries(op.patch || {}).some(([key, value]) =>
      canonicalJSON(before[key]) !== canonicalJSON(latest[key]) &&
      canonicalJSON(value) !== canonicalJSON(latest[key]));
  });
}

// Whether a batch of id-keyed ops authored against `baseline` can be resent on
// a NEWER stored version `server` of the same run without losing either writer's
// edit (task-e0987185b4de61e3). Two tabs editing different paragraphs of one
// paper must both land. Safe when the other writer left the run's block list as
// it was (no insert, remove or move there), every op is one that addresses a
// block by id that the newer version still holds, and no op touches a field the
// other writer changed. Anything else is held for the author to decide.
export function opsRebaseSafe(ops, baseline, server) {
  if (!Array.isArray(ops) || !ops.length || !Array.isArray(baseline) || !Array.isArray(server)) {
    return false;
  }
  const order = (blocks) => blocks.map((block) => (block && block.id) || "").join("\n");
  if (order(baseline) !== order(server)) return false;
  const known = new Set(server.map((block) => block && block.id));
  for (const op of ops) {
    if (op.op === "insert-after" || op.op === "append-block") {
      if (op.block && op.block.id) known.add(op.block.id);
    }
  }
  const addressable = ops.every((op) => {
    switch (op.op) {
      case "patch-block":
      case "remove-block":
        return known.has(op.id);
      case "insert-after":
        return op.afterId == null || known.has(op.afterId);
      case "append-block":
        return true;
      default:
        return false;
    }
  });
  return addressable && !hasOverlappingOps(ops, baseline, server);
}

// The byte-significant projection of a prose node for change detection: its
// type, heading level (if any), and content — i.e. exactly the inputs to
// buildPatchBlockOp / tiptapToBlock. bpId/bpType are excluded so an identity
// move never looks like an edit. Canonicalized (key-order-insensitive) so a
// node serialized by runToTiptap and the SAME node serialized by the live
// editor's getJSON compare EQUAL despite their differing attr/text key order.
function stableProseKey(node) {
  const level = node.attrs && node.attrs.level;
  const align = node.attrs && node.attrs.textAlign;
  const start = node.type === "orderedList" && node.attrs ? node.attrs.start : null;
  return canonicalJSON({
    type: node.type,
    level: level == null ? null : level,
    // Author alignment is diff-relevant (a patch must follow it); left and absent are one.
    align: align === "center" || align === "right" ? align : null,
    // An ordered list's first number is diff-relevant too; 1 and absent are one.
    start: Number.isInteger(start) && start !== 1 ? start : null,
    content: node.content || null,
  });
}

// classifyNode(node) → { node, bpType, isOpaque, isAtom, isContent, isAttrAtom,
//   isField, isReadOnlyAtom }
//
// The PURE per-node classification both runToOps (op-emission) and docToBlocks
// (live-doc → blocks projection) share — the SINGLE place a getJSON node is
// mapped to its canvas KIND + resolved bpType. Factored out so the two callers
// agree byte-for-byte on what a node IS (an own-echo stamp and a source-mode
// baseline must classify a node identically). It does NOT resolve the id — that
// is the caller's job (runToOps keys against prev ids + mints; docToBlocks reads
// the live bpId + mints) — because id resolution is the ONE thing that differs.
function classifyNode(node) {
  const isOpaque = node.type === "bpOpaque";
  const isAtom = isCanvasAtomType(node.type);
  const isContent = isCanvasContentType(node.type);
  // STEP 4: the card WIDGET (bpCard). A callout-shaped content node (inline body +
  // chrome attrs) but slots-native, so it gets its OWN kind flag + diff path.
  const isCard = isCanvasCardNode(node.type);
  // The stage WIDGET (bpStage). A control-atom (five scalar attrs, no interior), so it
  // gets its OWN kind flag + diff path — like bpAction but multi-field + slots-aware.
  const isStage = isCanvasStageNode(node.type);
  const isAttrAtom = isCanvasAttrAtomNode(node.type);
  const isField = isCanvasFieldNode(node.type);
  // editable-action: a canvas control-atom node (bpAction). Its bpType resolves to
  // "action" via the node.attrs.bpType default below.
  const isAction = isCanvasActionNode(node.type);
  const isReadOnlyAtom = isCanvasReadOnlyAtomNode(node.type);
  const isFleet = isCanvasFleetNode(node.type);
  // editable-figure: a canvas figure atom (bpFigure). Its bpType resolves to "figure"
  // off node.attrs.bpType (the isFigure fallback below).
  const isFigure = isCanvasFigureNode(node.type);
  // editable-image: the self-painting image atom (bpImage); bpType resolves to "image".
  const isImage = isCanvasImageNode(node.type);
  // island atoms (equation / footnote / toc / video); bpType off the node-name map.
  const isIsland = isCanvasIslandNode(node.type);
  // live-data task-list: a canvas task-list widget (bpTaskList). Its bpType resolves
  // to "task-list" off node.attrs.bpType (the isTaskList fallback below).
  const isTaskList = isCanvasTaskListNode(node.type);
  // S10: a canvas container node (bpColumns). Its bpType resolves to "columns" via
  // CANVAS_CONTAINER_BP_TYPE_BY_NODE below.
  const isContainer = isCanvasContainerNode(node.type);
  // Article-chrome role node — node.type IS the bpType (eyebrow/byline/ingress/
  // pullquote), so the bpType fallback below resolves it via `node.type`.
  const isRole = isCanvasRoleType(node.type);
  // Table container node — node.type is bpTable, bpType resolves to "table" off attrs.
  const isTable = isCanvasTableNode(node.type);
  const bpType =
    (node.attrs && node.attrs.bpType) ||
    CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE[node.type] ||
    CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE[node.type] ||
    CANVAS_CONTAINER_BP_TYPE_BY_NODE[node.type] ||
    (isField
      ? "field-string"
      : isFleet
        ? "tasks"
        : isFigure
          ? "figure"
          : isImage
            ? "image"
          : isIsland
            ? CANVAS_ISLAND_BP_TYPE_BY_NODE[node.type]
          : isTaskList
            ? "task-list"
            : isCard
              ? "card"
          : isCard
            ? "card"
            : isStage
              ? "stage"
              : node.type);
  // A list the person just created (input rule, toggle, paste) has no bpType attr yet: its
  // node name is bulletList/orderedList, but the portable-doc kind is "list". Without this the
  // new block was emitted as {type:"bulletList", content:[]} and its items were lost on save.
  const listAware = bpType === "bulletList" || bpType === "orderedList" || bpType === "taskList" ? "list" : bpType;
  // Turn-into (heading ⇄ paragraph ⇄ list ⇄ pullquote…) keeps the node's stamped bpType attr,
  // so for the kinds the canvas converts between the NODE TYPE is the truth, not the attr.
  // Kinds the canvas cannot represent natively keep their stamped bpType untouched.
  const nodeKind = isRole ? node.type : CONVERTIBLE_NODE_KIND[node.type];
  const resolved = nodeKind && (!listAware || CONVERTIBLE_KINDS.has(listAware)) ? nodeKind : listAware;
  return {
    node,
    bpType: resolved,
    isOpaque,
    isAtom,
    isContent,
    isCard,
    isStage,
    isAttrAtom,
    isField,
    isAction,
    isReadOnlyAtom,
    isFleet,
    isFigure,
    isImage,
    isIsland,
    isTaskList,
    isContainer,
    isRole,
    isTable,
  };
}

// docToBlocks(doc) → [ block, … ]
//
// Project an EDITED canvas doc (the getJSON shape, after normalizeCanvasDoc) BACK
// to a portable-doc block LIST — the SAME node→block path runToOps uses internally
// (classifyNode + nextNodeToBlock), exposed so a caller can derive the LIVE run
// from the live editor. This is what source-mode needs for its baseline: the diff
// baseline (this._blocks) is ECHO-CONFIRMED and LAGS the live doc by the round-trip
// to the server; the LIVE doc (getJSON) carries the user's just-typed,
// not-yet-confirmed edits. docToBlocks(normalizeCanvasDoc(getJSON())) is exactly the
// run _emitOps diffs the live doc to internally (runToOps maps each node via the
// same classify + nextNodeToBlock), so the markdown the user sees in source mode
// reflects everything on screen, not the stale confirmed run.
//
// A node that already carries a bpId keeps it; a freshly-typed / split node
// (bpId:null) is CLIENT-MINTED a unique id here (so blocksToMarkdown has a stable
// key and the exit realign can donate it back). The `taken` set guards uniqueness
// within the call. PURE, DOM-free — like runToOps it touches no editor.
//
// `options.reuse(index)` (the canvas emit's fast path, task-fb938eb8be3bce48) may
// answer the block a top-level node projected to at an earlier call, when the
// caller KNOWS the node is unchanged since then; that node is not re-projected.
// The default answers nothing, so every node is projected as before.
export function docToBlocks(doc, options = {}) {
  const nodes = (doc && doc.content) || [];
  const reuse = typeof options.reuse === "function" ? options.reuse : null;
  const taken = new Set();
  // Seed `taken` with every id ALREADY on a node so a mint can never collide with a
  // surviving id. RECURSIVE (descend bpSection bodies at any depth) — the make-or-break
  // duplicate_id-abort guard: a nested child id is invisible to a top-level-only seed,
  // so a mint could collide with it and abort the whole atomic batch.
  walkNodeIds(nodes, taken);
  return nodes.map((node, index) => {
    const reused = reuse && reuse(index);
    if (reused) return reused;
    const cls = classifyNode(node);
    const bpId = node.attrs && node.attrs.bpId;
    const id = bpId != null ? bpId : mintId(taken);
    return nextNodeToBlock({ ...cls, id, isNew: bpId == null }, taken);
  });
}

// The fewest move-block ops that fold `running` into nextSeq's order, or null when
// the batch would not reproduce it. Stable = the longest increasing subsequence
// of running positions in nextSeq order, plus every locked id (a locked block
// never moves). Each other id moves right after its nextSeq predecessor, left to
// right: nothing is ever spliced between a moved id and its predecessor, so the
// fold lands exactly on nextSeq. The fold is simulated to prove it.
function minimalMoves(running, nextSeq, lockedIds) {
  const ids = nextSeq.map((e) => e.id);
  if (running.length !== ids.length) return null;
  const pos = new Map(running.map((id, i) => [id, i]));
  if (ids.some((id) => !pos.has(id))) return null;
  const seq = ids.map((id) => pos.get(id));
  // Longest increasing subsequence of `seq` (patience sorting, O(n log n)).
  const tails = [];
  const prev = new Array(seq.length).fill(-1);
  for (let i = 0; i < seq.length; i++) {
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (seq[tails[mid]] < seq[i]) lo = mid + 1;
      else hi = mid;
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    tails[lo] = i;
  }
  const stable = new Set(lockedIds);
  for (let i = tails.length ? tails[tails.length - 1] : -1; i !== -1; i = prev[i]) stable.add(ids[i]);
  const ops = [];
  const order = running.slice();
  for (let i = 0; i < ids.length; i++) {
    const id = ids[i];
    if (stable.has(id)) continue;
    const after = i === 0 ? null : ids[i - 1];
    ops.push({ op: "move-block", id, after });
    order.splice(order.indexOf(id), 1);
    order.splice(after == null ? 0 : order.indexOf(after) + 1, 0, id);
  }
  return order.every((id, i) => id === ids[i]) ? ops : null;
}

// runToOps(prevBlocks, nextDoc) → [ op, … ] (ordered)
//
// Diff the ORIGINAL block list against the edited doc (the runToTiptap shape
// after edits) and emit an ordered op set in the EXISTING vocabulary that, when
// FOLDED through patch.ex left-to-right, reproduces nextDoc EXACTLY — id order
// and surviving content both.
//
// The pivot that makes this provable: EVERY new block (a split, a typed
// paragraph, anything with no surviving bpId) is CLIENT-MINTED a unique id up
// front, so every next node has a KNOWN id. The op vocabulary has no
// prepend / insert-before — a front-insert or any reorder can ONLY be expressed
// via move-block, which keys by a known id. Minting closes that gap.
//
// Emission order: removes → inserts → moves → patches.
//   1. removes shrink the running list to the surviving prev ids.
//   2. inserts graft every new block in (anchored to the FIRST surviving prev
//      block, or appended when nothing survives). Position here does NOT matter.
//   3. moves permute the running list — now exactly nextSeq's id SET in some
//      order — into nextSeq ORDER. An already-correct subsequence emits nothing.
//   4. interior patches mutate surviving prose content in place (order-free).
// A pasted or dropped picture is not a block until its upload gives it a src: while it
// uploads, or after the upload failed, a NEW top-level image node with no src stays in
// the canvas (its badge says why) and out of the ops. Emitted, the host saved an empty
// image block that outlived the error on reload (task-797f973032044a56). The upload
// flags are transient attrs, so this reads the LIVE doc (before docToBlocks drops them)
// and answers top-level indexes. An image the server already holds is never held back.
export function pendingUploadIndexes(liveDoc, prevBlocks) {
  const held = new Set();
  const known = new Set((prevBlocks || []).map((b) => b && b.id).filter((id) => id != null));
  ((liveDoc && liveDoc.content) || []).forEach((node, i) => {
    if (!node || node.type !== CANVAS_IMAGE_NODE_NAME) return;
    const a = node.attrs || {};
    if (a.src || (!a.uploading && !a.uploadError)) return;
    if (a.bpId != null && known.has(a.bpId)) return;
    held.add(i);
  });
  return held;
}

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
                rowsNodeToRows(entry.node, entry.bpType, taken),
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
            block: carryUnmodeledKeys(prevBlock, expandableNodeToBlock(entry.node, entry.id, taken), "expandable"),
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
            block: carryUnmodeledKeys(prevBlock, sectionNodeToBlock(entry.node, entry.id, taken), "section"),
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

// Back to left on a block the BASELINE holds centred or flushed right: the node's source
// only carries `align` when the block mounted with one, and a block aligned earlier in this
// session and acknowledged since has a baseline with the key but a source without it - so
// tiptapToBlock drops the key from the patch and the server would keep the old alignment.
// The baseline is the truth the patch merges onto; when it has an alignment the node no
// longer shows, the patch says align:null (the shallow merge then drops it).
function withAlignDrop(patch, node, prevBlock) {
  if (!patch || typeof patch !== "object" || !prevBlock) return patch;
  const prev = prevBlock.align;
  if (prev !== "center" && prev !== "right") return patch;
  const now = node && node.attrs && node.attrs.textAlign;
  if (now === "center" || now === "right") return patch;
  if (Object.hasOwn(patch, "align")) return patch;
  return { ...patch, align: null };
}

// The same for an ordered list's first number: tiptapToBlock carries `start` only
// while the canvas numbers from something other than 1, so an ordered list the
// author set back to 1 would keep the baseline's start on the shallow merge. When the
// baseline has a start and the node is an ordered list that no longer shows one, the
// patch says start:null. A bullet list keeps whatever the baseline holds.
function withListStartDrop(patch, node, prevBlock) {
  if (!patch || typeof patch !== "object" || !prevBlock) return patch;
  if (!node || node.type !== "orderedList" || Object.hasOwn(patch, "start")) return patch;
  if (listStart(prevBlock) === null) return patch;
  return { ...patch, start: null };
}

// ── echo reconciliation: server-confirmed blocks ⇄ live doc (S4a) ────────────
//
// reconcileServerEcho(serverBlocks, liveContent) → { ownEcho, idWrites }
//
// THE PROBLEM this solves. When the canvas emits an `insert-after` for a NEW
// block (Enter-split / paste / typed paragraph), the live ProseMirror node has
// bpId:null (a freshly-typed block has no id yet). The server mints an id (say
// "srv-9") and echoes the confirmed blocks carrying it. A naive own-echo gate —
// runToOps(serverBlocks, liveDoc).length === 0 — MISDETECTS this as an external
// edit: the live new-block node still has bpId:null while the confirmed block
// has "srv-9", so runToOps mints a FRESH id for the null node and reports
// remove-block("srv-9") + insert-after(fresh) — a non-empty diff. Worse, because
// the live node never learns "srv-9", every later batch re-mints it: the op size
// never shrinks and the server block-id churns.
//
// THE FIX. Treat a live bpId:null at index i as a WILDCARD that matches
// serverBlocks[i].id. We build serverDoc = runToTiptap(serverBlocks) (the
// canonical node shape per kind) and compare it to the live doc node-by-node:
//
//   ownEcho IFF liveContent.length === serverBlocks.length AND for every i:
//     • the live node and the server node are the SAME node KIND/type, AND
//     • the live node's bpId === server id  OR  the live node's bpId == null
//       (a just-minted block at that position), AND
//     • the block's mutable content matches per kind — the SAME stable/canonical
//       comparison runToOps uses (prose/heading/list/callout/code/diagram/field/
//       read-only-atom/opaque), so an own echo carrying an UNRELATED content
//       change still falls through to the external path.
//
//   idWrites — for every live node whose bpId == null AND that passed the match,
//     { index, id: serverBlocks[index].id, bpType: serverBlocks[index].type }.
//     applyServerBlocks stamps these onto the live nodes (an ATTR-ONLY change PM
//     maps the selection through → the caret does NOT move) so the echo no-ops
//     AND the NEXT diff is truly incremental.
//
// Precise, not over-matching: a length mismatch, a kind/type mismatch, a real
// content change, or a bpId that is neither the server id nor null → ownEcho
// false (external path). Pure, DOM-free, testable without an editor.
export function reconcileServerEcho(serverBlocks, liveContent) {
  const server = serverBlocks || [];
  const live = liveContent || [];

  // Length mismatch → structurally different → external.
  if (live.length !== server.length) return { ownEcho: false, idWrites: [] };

  // Canonical server node shapes (one top-level node per block, per kind).
  const serverNodes = runToTiptap(server).content;

  const idWrites = [];
  for (let i = 0; i < live.length; i++) {
    const liveNode = live[i];
    const serverNode = serverNodes[i];
    const serverBlock = server[i];
    const serverId = serverBlock && serverBlock.id;
    const liveId = liveNode && liveNode.attrs && liveNode.attrs.bpId;

    // The id wildcard: the live id must EQUAL the server id, or be null (a
    // just-minted block at this position whose id we will stamp).
    const idOk = liveId == null || liveId === serverId;
    if (!idOk) return { ownEcho: false, idWrites: [] };

    // Same node KIND/type (and same mutable content per kind). bpId is excluded
    // from every comparison below (the stable-key fns ignore it), so the null
    // wildcard never trips the content check.
    if (!nodeContentEqual(serverNode, liveNode)) {
      return { ownEcho: false, idWrites: [] };
    }

    // A matched, just-minted live node → record the id (and bpType) to stamp.
    if (liveId == null) {
      idWrites.push({
        index: i,
        id: serverId,
        bpType: liveNode && liveNode.attrs && liveNode.attrs.bpType == null
          ? serverBlock && serverBlock.type
          : undefined,
      });
    }
  }

  return { ownEcho: true, idWrites };
}

// True when two top-level canvas nodes are the SAME kind AND carry the SAME
// MUTABLE content — bpId/bpType EXCLUDED. Dispatches by node kind exactly as
// runToOps's patch pass does, reusing the SAME stable-key change-detection so an
// own echo is recognized despite live-editor vs projector key-order differences,
// and an UNRELATED content change is NOT.
export function nodeContentEqual(serverNode, liveNode) {
  if (!serverNode || !liveNode) return false;
  // Kind/type must match first (a paragraph echo onto a heading is external).
  if (serverNode.type !== liveNode.type) return false;
  const type = serverNode.type;

  // Table (nested node tree): the header cells + body rows.
  if (isCanvasTableNode(type)) {
    return !tableNodeChanged(serverNode, liveNode);
  }
  // Content node — callout (tone/title/collapsible/collapsed/body) OR note
  // (label/lead/body, the notes-grid split). Sub-route by node type.
  if (isCanvasContentType(type)) {
    if (isNoteType(type)) return stableNoteKey(serverNode, true) === stableNoteKey(liveNode, true);
    return !calloutNodeChanged(serverNode, liveNode);
  }
  // Card (STEP 4 widget, bpCard): tone/title/media/action/body.
  if (isCanvasCardNode(type)) {
    return !cardNodeChanged(serverNode, liveNode);
  }
  // Stage (widget, bpStage): the five scalars, canonically compared.
  if (isCanvasStageNode(type)) {
    return !stageNodeChanged(serverNode, liveNode);
  }
  // Code / diagram (attr-atom): value+lang / source+caption.
  if (isCanvasAttrAtomNode(type)) {
    if (type === "bpDiagram") return !diagramNodeChanged(serverNode, liveNode);
    if (isTechnicalAtomNode(type))
      return !technicalNodeChanged(serverNode, liveNode);
    return !codeNodeChanged(serverNode, liveNode);
  }
  // Field (control-atom): the normalized value.
  if (isCanvasFieldNode(type)) {
    return !fieldNodeChanged(serverNode, liveNode);
  }
  // Action (control-atom): href/label/priority (priority collapsed nil≡secondary).
  if (isCanvasActionNode(type)) {
    return !actionNodeChanged(serverNode, liveNode);
  }
  // Divider (content-free atom leaf): same type with no interior → equal.
  if (isCanvasAtomType(type)) {
    return true;
  }
  // Read-only atom (sheet / embed): the whole carried block, id excluded.
  if (isCanvasReadOnlyAtomNode(type)) {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Fleet (pdd-t8: bpFleet — tasks / cards / pipeline / form / …): the whole carried
  // block, id excluded — same verbatim-carry equality as the read-only atom.
  if (isCanvasFleetNode(type)) {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Figure (editable-figure: bpFigure): caption + child (child immutable in v1). The
  // own-echo of a caption edit — and the id-wildcard for a just-minted figure — is
  // recognized by the SAME stable-key compare runToOps uses.
  if (isCanvasFigureNode(type)) {
    return !figureNodeChanged(serverNode, liveNode);
  }
  // Image (editable-image: bpImage): src + alt + the carried rest.
  if (isCanvasImageNode(type)) {
    return !imageNodeChanged(serverNode, liveNode);
  }
  // Island atoms: the editable keys + the carried rest.
  if (isCanvasIslandNode(type)) {
    return !islandNodeChanged(serverNode, liveNode);
  }
  // Task-list (live-data: bpTaskList): query + title + config (rows server-painted,
  // never on the node). The own-echo of a query edit — and the id-wildcard for a
  // just-minted task-list — is recognized by the SAME stable-key compare runToOps uses.
  if (isCanvasTaskListNode(type)) {
    return !taskListNodeChanged(serverNode, liveNode);
  }
  // Opaque carry-through: the whole carried block, id excluded.
  if (type === "bpOpaque") {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Container node — sub-route by bpType (node.type → bpType via the reverse map):
  //   * columns (bpColumns): the reconstructed columns array (child attrs excluded).
  //   * terminal (bpTerminal): the reconstructed body + chrome (child attrs excluded).
  //   * section (bpSection): V1 does NOT recurse reconcile (product decision 1 defers
  //     recursive idWrites) — compare the WHOLE subtree canonically (title on attrs +
  //     the nested children incl. bpIds). A section holding a canvas-CREATED child (a
  //     live bpId:null vs a server minted id) never own-echo-matches, so each batch
  //     re-emits replace-block{wholeSection} — the accepted V1 churn; a section with
  //     all-stable children whose echoed interior edit matched DOES own-echo. bpId of
  //     the section itself is excluded (stableSectionKey ignores it).
  if (isCanvasContainerNode(type)) {
    const bp = CANVAS_CONTAINER_BP_TYPE_BY_NODE[type];
    if (bp === "section") {
      return stableSectionKey(serverNode) === stableSectionKey(liveNode);
    }
    if (bp === "expandable") {
      return stableExpandableKey(serverNode) === stableExpandableKey(liveNode);
    }
    if (bp === "steps" || bp === "tabs") {
      return !rowsNodeChanged(serverNode, liveNode);
    }
    if (bp === "terminal") {
      return !terminalNodeChanged(serverNode, liveNode);
    }
    return !columnsNodeChanged(serverNode, liveNode);
  }
  // Article-chrome role (eyebrow/byline/ingress/pullquote): the derived body.
  if (isCanvasRoleType(type)) {
    return !roleNodeChanged(serverNode, liveNode);
  }
  // Prose (paragraph / heading / list nodes): type + level + content.
  return !proseNodeChanged(serverNode, liveNode);
}

// The byte-significant projection of a section node for echo-equality: its title +
// the nested child content (each child's own bpId/content). The section's OWN bpId is
// excluded (an id-stamp echo must still match). Canonical so key order never trips it.
function stableSectionKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    title: a.title == null ? null : a.title,
    // STEP-2: layout + cells join the echo key so a layout-only own-echo is
    // recognized (no phantom replace-block). A layout-bearing section the server
    // just confirmed must still match the live node.
    layout: a.layout == null ? null : a.layout,
    cells: a.cells == null ? null : a.cells,
    // FRAMED-FINALE (charter D34): variant joins the echo key so a variant-bearing
    // section the server just confirmed still matches the live node (and a DROPPED
    // variant is never mistaken for an own-echo).
    variant: a.variant == null ? null : a.variant,
    content: node.content || null,
  });
}

// Compare the WHOLE block carried on a read-only-atom / opaque node's bpBlock
// attr, with `id` excluded (a just-minted live node carries no id yet). Canonical
// so key order never trips it.
function carriedBlockEqual(serverNode, liveNode) {
  const sb = serverNode && serverNode.attrs && serverNode.attrs.bpBlock;
  const lb = liveNode && liveNode.attrs && liveNode.attrs.bpBlock;
  return canonicalJSON(stripId(sb)) === canonicalJSON(stripId(lb));
}

// A shallow clone of a block with `id` removed, for id-insensitive comparison.
function stripId(block) {
  if (!block || typeof block !== "object") return block;
  const { id: _id, ...rest } = block;
  return rest;
}

// Reconstruct a portable-doc block from a NEW nextSeq entry, carrying its
// CLIENT-MINTED id. PROSE → the convert.js patch fields plus { id, type };
// CANVAS ATOM (S3: divider) → a bare { id, type } leaf block (no body); the id
// is minted on insert and the leaf carries no other fields. OPAQUE → its carried
// bpBlock verbatim, with the minted id stamped on (so move-block / later folds
// can key it). Every inserted block carries an id — that is what makes a
// front-insert / reorder expressible via move-block.
function nextNodeToBlock(entry, taken) {
  const node = entry.node;
  if (entry.isContainer) {
    // Canvas container insert — sub-route by bpType:
    //   * section → rebuild the WHOLE section subtree (title + nested children) with
    //     the minted id; nested null-id children mint ids off the CALL-SHARED `taken`
    //     (the duplicate_id-abort guard) — a fresh Set only when none is threaded.
    //   * terminal → reconstruct the full terminal block (body children + chrome) with
    //     the minted id; a NEW terminal carries no unknown sibling keys, lossless.
    //   * columns → reconstruct the full columns block (its column child-block trees)
    //     with the minted id; a NEW columns carries no unknown sibling keys, lossless.
    if (entry.bpType === "section") {
      return sectionNodeToBlock(node, entry.id, taken || new Set());
    }
    if (entry.bpType === "expandable") {
      return expandableNodeToBlock(node, entry.id, taken || new Set());
    }
    if (entry.bpType === "steps" || entry.bpType === "tabs") {
      return rowsNodeToBlock(node, entry.id, taken || new Set());
    }
    if (entry.bpType === "terminal") {
      return terminalNodeToBlock(node, entry.id);
    }
    return columnsNodeToBlock(node, entry.id);
  }
  if (entry.isAtom) {
    // Canvas atom insert (divider): a content-free leaf, fully described by its
    // type + the minted id. No body fields to reconstruct.
    return { id: entry.id, type: entry.bpType || node.type };
  }
  if (entry.isTable) {
    // Canvas table insert: reconstruct the full table block (rows + optional head)
    // from the nested node tree with the minted id, via the dedicated mapper.
    return tableNodeToBlock(node, entry.id);
  }
  if (entry.isContent) {
    // Canvas content insert (callout OR note): reconstruct the full block from the
    // node (body + chrome) with the minted id, via the dedicated mapper. Sub-route
    // by node type — a note reconstructs its flat { label?, lead?, text } wire form.
    if (isNoteType(node.type)) return noteNodeToBlock(node, entry.id);
    return calloutNodeToBlock(node, entry.id);
  }
  if (entry.isCard) {
    // STEP 4 card WIDGET insert: reconstruct the full slots-native card block (body
    // slot + title/tone/media/action chrome) with the minted id, via the mapper.
    return cardNodeToBlock(node, entry.id);
  }
  if (entry.isStage) {
    // The stage WIDGET insert: reconstruct the WIRE-canonical scalar stage block
    // (kind/title/detail + files/source, present-only) with the minted id, via the mapper.
    return stageNodeToBlock(node, entry.id);
  }
  if (entry.isAttrAtom) {
    // Canvas attr-atom insert (S3.3: code; S3.4: diagram): reconstruct the block (body
    // + optional field) with the minted id. The optional field is OMITTED on insert
    // when absent/empty — the insert path mirrors the persist default (a lang-less
    // code / caption-less diagram has no key). Dispatch by NODE type.
    if (node.type === "bpDiagram") return diagramNodeToBlock(node, entry.id);
    if (isTechnicalAtomNode(node.type))
      return technicalNodeToBlock(node, entry.id);
    return codeNodeToBlock(node, entry.id);
  }
  if (entry.isField) {
    // Canvas control-atom insert (S3.5: a native field-* block): reconstruct the
    // full field block (value + carried config) with the minted id. block.type comes
    // off the bpType attr; config keys (label/options/rows/fieldName) ride only when
    // present, mirroring the per-type persist default. The value is normalized to its
    // per-type stored form.
    return fieldNodeToBlock(node, entry.id);
  }
  if (entry.isAction) {
    // Canvas control-atom insert (editable-action): reconstruct the full action block
    // (href/label/priority, each only when present) with the minted id, via the
    // dedicated mapper. block.type is the fixed "action".
    return actionNodeToBlock(node, entry.id);
  }
  if (entry.isReadOnlyAtom) {
    // Read-only atom insert (S3.6: sheet / embed): the carried WHOLE block, deep-cloned
    // VERBATIM, with the minted id stamped on — EXACTLY the bpOpaque insert
    // reconstruction (the read-only atom carries the full block, not just a value).
    return readOnlyAtomNodeToBlock(node, entry.id);
  }
  if (entry.isFleet) {
    // Fleet insert (pdd-t8: tasks / cards / pipeline / form / …): the carried WHOLE
    // block, deep-cloned VERBATIM, with the minted id stamped on — identical to the
    // sheet/embed read-only-atom reconstruction (the whole block, not just a value).
    return fleetNodeToBlock(node, entry.id);
  }
  if (entry.isTaskList) {
    // Task-list insert/move (live-data): reconstruct the task-list block (its query
    // + optional title/config) with the minted id. title/config are OMITTED when
    // absent (mirrors the persist default); NO snapshot (a live task-list has none —
    // the rows are server-resolved at read).
    return taskListNodeToBlock(node, entry.id);
  }
  if (entry.isImage) {
    // Image insert/move (editable-image): src/alt when set, the carried rest, locked/role.
    return imageNodeToBlock(node, entry.id);
  }
  if (entry.isIsland) {
    return islandNodeToBlock(node, entry.id);
  }
  if (entry.isFigure) {
    // Figure insert/move (editable-figure): reconstruct the figure block (its
    // verbatim child + optional caption) with the minted id. The caption is OMITTED
    // when absent/empty (mirrors the persist default: a caption-less figure has no
    // caption key); the child rides VERBATIM.
    return figureNodeToBlock(node, entry.id);
  }
  if (entry.isRole) {
    // Article-chrome role insert (eyebrow/byline/ingress/pullquote): reconstruct the
    // full role block (its text/items/content body) with the minted id, via the
    // dedicated mapper. block.type comes off the node.type (=== bpType).
    return roleNodeToBlock(node, entry.id);
  }
  if (entry.isOpaque) {
    // Opaque insert: the carried block JSON, deep-cloned, with the minted id.
    const block = deepClone((node.attrs && node.attrs.bpBlock) || {});
    block.id = entry.id;
    return block;
  }
  const bpType = entry.bpType || node.type;
  // buildPatchBlockOp().patch is exactly the mutable-fields map — the body of a
  // new block of this type. Stamp the minted id + type.
  const op = buildPatchBlockOp(nodeToDocEnvelope(node), entry.id, bpType);
  const block = { id: entry.id, type: bpType, ...op.patch };
  // Doctrine template attrs (pdd-t2): carry locked/role from the prose node so a
  // reconstructed locked title (e.g. the source-mode baseline via docToBlocks)
  // stays byte-identical. D3: only when present.
  return carryTemplateAttrs(block, node.attrs);
}
