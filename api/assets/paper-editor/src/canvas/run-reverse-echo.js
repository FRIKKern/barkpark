import { buildPatchBlockOp } from "../convert.js";
import { canonicalJSON, deepClone } from "./projection-json.js";
import {
  columnsNodeChanged, columnsNodeToBlock, expandableNodeToBlock, rowsNodeChanged, rowsNodeToBlock,
  sectionNodeToBlock, stableExpandableKey, terminalNodeChanged, terminalNodeToBlock,
} from "./run-container-codecs.js";
import {
  calloutNodeChanged, calloutNodeToBlock, cardNodeChanged, cardNodeToBlock, noteNodeToBlock,
  stableNoteKey,
} from "./run-content-codecs.js";
import {
  CANVAS_CONTAINER_BP_TYPE_BY_NODE, isCanvasActionNode, isCanvasAtomType, isCanvasAttrAtomNode,
  isCanvasCardNode, isCanvasContainerNode, isCanvasContentType, isCanvasFieldNode,
  isCanvasFigureNode, isCanvasFleetNode, isCanvasImageNode, isCanvasIslandNode,
  isCanvasReadOnlyAtomNode, isCanvasRoleType, isCanvasStageNode, isCanvasTableNode,
  isCanvasTaskListNode, isNoteType,
} from "./run-kinds.js";
import {
  classifyNode, mintId, nodeToDocEnvelope, proseNodeChanged, walkNodeIds,
} from "./run-node-core.js";
import { runToTiptap } from "./run-project.js";
import {
  codeNodeChanged, codeNodeToBlock, diagramNodeChanged, diagramNodeToBlock, isTechnicalAtomNode,
  roleNodeChanged, roleNodeToBlock, stageNodeChanged, stageNodeToBlock, technicalNodeChanged,
  technicalNodeToBlock,
} from "./run-scalar-codecs.js";
import {
  actionNodeChanged, actionNodeToBlock, fieldNodeChanged, fieldNodeToBlock, figureNodeChanged,
  figureNodeToBlock, fleetNodeToBlock, imageNodeChanged, imageNodeToBlock, islandNodeChanged,
  islandNodeToBlock, readOnlyAtomNodeToBlock, taskListNodeChanged, taskListNodeToBlock,
} from "./run-structured-codecs.js";
import { carryTemplateAttrs } from "./run-template-attrs.js";
import { tableNodeChanged, tableNodeToBlock } from "./table-convert.js";

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
      return sectionNodeToBlock(node, entry.id, taken || new Set(), nextNodeToBlock);
    }
    if (entry.bpType === "expandable") {
      return expandableNodeToBlock(node, entry.id, taken || new Set(), nextNodeToBlock);
    }
    if (entry.bpType === "steps" || entry.bpType === "tabs") {
      return rowsNodeToBlock(node, entry.id, taken || new Set(), nextNodeToBlock);
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

export { nextNodeToBlock, stripId };
