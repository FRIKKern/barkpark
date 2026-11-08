import { canonicalJSON } from "./projection-json.js";
import {
  CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE, CANVAS_CONTAINER_BP_TYPE_BY_NODE, CANVAS_IMAGE_NODE_NAME,
  CANVAS_ISLAND_BP_TYPE_BY_NODE, CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE, CANVAS_ROW_NODE_NAMES,
  CONVERTIBLE_KINDS, CONVERTIBLE_NODE_KIND, isCanvasActionNode, isCanvasAtomType,
  isCanvasAttrAtomNode, isCanvasCardNode, isCanvasContainerNode, isCanvasContentType,
  isCanvasFieldNode, isCanvasFigureNode, isCanvasFleetNode, isCanvasImageNode, isCanvasIslandNode,
  isCanvasReadOnlyAtomNode, isCanvasRoleType, isCanvasStageNode, isCanvasTableNode,
  isCanvasTaskListNode,
} from "./run-kinds.js";

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

export {
  classifyNode, isEmptyParagraphBlock, mintId, nodeToDocEnvelope, proseNodeChanged, walkBlockIds,
  walkNodeIds,
};
