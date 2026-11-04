import { blockToTiptap } from "../convert.js";
import { deepClone } from "./projection-json.js";
import {
  calloutBlockToNode, cardBlockEditable, cardBlockToNode, noteBlockToNode,
} from "./run-content-codecs.js";
import {
  BP_COLUMN_ATOM_NODE_NAME, BP_COLUMN_NODE_NAME, BP_TERMINAL_ATOM_NODE_NAME,
  CANVAS_CONTAINER_NODE_NAME, CANVAS_CONTAINER_NODE_NAMES, CANVAS_EXPANDABLE_NODE_NAME, CANVAS_ROWS,
  TECHNICAL_ATOM_SHAPES, isCanvasActionType, isCanvasAtomType, isCanvasAttrAtomType,
  isCanvasCardType, isCanvasContainerType, isCanvasContentType, isCanvasFieldType,
  isCanvasFigureType, isCanvasFleetType, isCanvasImageType, isCanvasIslandType,
  isCanvasReadOnlyAtomType, isCanvasRoleType, isCanvasStageType, isCanvasTableType,
  isLiveTaskListBlock, isNoteType, isProseType, tableBlockEditable,
} from "./run-kinds.js";
import {
  codeBlockToNode, diagramBlockToNode, roleBlockToNode, stageBlockToNode, technicalBlockToNode,
} from "./run-scalar-codecs.js";
import {
  actionBlockToNode, fieldBlockToNode, figureBlockToNode, fleetBlockToNode, imageBlockToNode,
  islandBlockToNode, readOnlyAtomBlockToNode, taskListBlockToNode,
} from "./run-structured-codecs.js";
import { stampTemplateAttrs } from "./run-template-attrs.js";
import { tableBlockToNode } from "./table-convert.js";



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

export { expandableBody };
