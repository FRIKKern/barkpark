import { toFieldNumber } from "./field-node.js";
import { canonicalJSON, deepClone } from "./projection-json.js";
import { carryTemplateAttrs, stampTemplateAttrs } from "./run-template-attrs.js";
import {
  CANVAS_ACTION_NODE_NAME,
  CANVAS_FIELD_NODE_NAME,
  CANVAS_FIGURE_NODE_NAME,
  CANVAS_FLEET_NODE_NAME,
  CANVAS_IMAGE_NODE_NAME,
  CANVAS_ISLAND_BP_TYPE_BY_NODE,
  CANVAS_ISLAND_SPECS,
  CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE,
  CANVAS_READONLY_ATOM_NODE_NAMES,
  CANVAS_TASK_LIST_NODE_NAME,
  isPlainObject,
} from "./run-kinds.js";

// ── field ⇄ canvas control-atom node (S3.5) ─────────────────────────────────
//
// The 7 NATIVE field blocks { id, type:"field-*", value:<typed>, label?, fieldName?,
// rows?(text), options?(select) } ⇄ the TipTap `bpField` CONTROL-ATOM node. UNLIKE
// code/diagram (fully described by value+lang / source+caption), a field block
// carries CONFIG keys (label / options / rows / fieldName) the canvas must NOT lose,
// so the node carries the FULL config and fieldNodeToBlock merges the edited `value`
// over it. The value's TYPE is BOOLEAN for field-boolean, STRING for the rest —
// COERCED by the node-view exactly like BarkparkFieldBlockBridge (boolean →
// control.checked; else control.value).
//
// node.type is `bpField` (the NODE name) for ALL 7 types; the specific bpType
// ("field-string" | … | "field-color") rides the node's bpType attr and is what
// reconstructs block.type.

// Normalize a value to its per-type stored form. A field-boolean coerces to a
// strict boolean (true ONLY for the boolean true / "true"); every other native
// type coerces to a string ("" when absent). Mirrors the BarkparkFieldBlockBridge
// coercion target (boolean vs string) so a round-tripped value matches the
// per-block path byte-for-byte.
function normalizeFieldValue(bpType, value) {
  if (bpType === "field-boolean") {
    return value === true || value === "true";
  }
  // field-number stores a NUMBER, or null when empty (blocks.ex default_block).
  if (bpType === "field-number") return toFieldNumber(value);
  if (value == null) return "";
  return typeof value === "string" ? value : String(value);
}

// fieldBlockToNode(block) → { type:"bpField", attrs:{ bpId, bpType, value, fieldName?,
//   label?, options?, rows? } }
//
// The editable VALUE → the `value` attr (normalized to its per-type stored form).
// The CONFIG keys ride attrs ONLY when present so an untouched field block's getJSON
// re-projection matches and emits zero ops:
//   * fieldName — only when present + non-empty (an unbound block has no key).
//   * label     — only when present (label is a string; carry it as-is when set).
//   * options   — only when present (field-select carries it; others don't).
//   * rows      — only when present (field-text's optional row count).
const FIELD_NUMBER_CONFIG = ["min", "max", "step", "unit"];

function fieldBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    value: normalizeFieldValue(bpType, block && block.value),
  };
  if (block && block.fieldName != null && block.fieldName !== "")
    attrs.fieldName = block.fieldName;
  if (block && block.label != null) attrs.label = block.label;
  if (block && block.options != null) attrs.options = block.options;
  if (block && block.rows != null) attrs.rows = block.rows;
  // field-number config: min / max / step / unit, only when present.
  for (const k of FIELD_NUMBER_CONFIG) if (block && block[k] != null) attrs[k] = block[k];
  // PICKER config (field-image / field-reference) carried verbatim so the round-trip is
  // byte-identical: refType (field-reference's target schema) + dataset (a per-block
  // fetch-scope override). Carried ONLY when present so an untouched picker's getJSON
  // re-projection matches and emits zero ops (a field-reference's default refType is ""
  // — present and kept; an unset dataset has no key).
  if (block && block.refType != null) attrs.refType = block.refType;
  if (block && block.dataset != null) attrs.dataset = block.dataset;
  // Doctrine template attrs (pdd-t2): a field block could itself be a mandated
  // template block (a future doc type's forced field) — carry locked/role so the
  // round-trip is byte-identical and the node can be recognized as locked. D3:
  // only when present.
  stampTemplateAttrs(attrs, block);
  return { type: CANVAS_FIELD_NODE_NAME, attrs };
}

// fieldNodeToBlock(node, id) → { id, type:"field-*", value, fieldName?, label?,
//   options?, rows? }
//
// Reconstruct the portable-doc field block from a bpField NODE (the inverse of
// fieldBlockToNode). block.type comes off the bpType attr (the specific kind);
// `value` is normalized to its per-type stored form; config keys are threaded ONLY
// when present so the reconstructed block is byte-identical to one that round-tripped
// through the per-block path (no stray fieldName:"" / null options).
function fieldNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const bpType = attrs.bpType || "field-string";
  const block = {
    id,
    type: bpType,
    value: normalizeFieldValue(bpType, attrs.value),
  };
  if (attrs.fieldName != null && attrs.fieldName !== "")
    block.fieldName = attrs.fieldName;
  if (attrs.label != null) block.label = attrs.label;
  if (attrs.options != null) block.options = attrs.options;
  if (attrs.rows != null) block.rows = attrs.rows;
  for (const k of FIELD_NUMBER_CONFIG) if (attrs[k] != null) block[k] = attrs[k];
  // PICKER config (field-image / field-reference): refType + dataset threaded ONLY when
  // present so the reconstructed block is byte-identical to one that round-tripped
  // through the per-block path (no stray refType/dataset on a native field). The inverse
  // of fieldBlockToNode.
  if (attrs.refType != null) block.refType = attrs.refType;
  if (attrs.dataset != null) block.dataset = attrs.dataset;
  // Doctrine template attrs (pdd-t2): carry locked/role back — the inverse of
  // fieldBlockToNode's stamp. D3: only when present.
  carryTemplateAttrs(block, attrs);
  return block;
}

// The mutable-fields PATCH for a field block (the analogue of codeNodeToPatch). The
// ONLY mutable field is `value` — EXACTLY what BarkparkFieldBlockBridge emits
// ({op:"patch-block", id, patch:{value}}). label/options/rows/fieldName are CONFIG,
// not edited through the control, so they NEVER ride the patch — matching the
// per-block bridge byte-for-byte. The value is normalized to its per-type stored
// form (boolean for field-boolean; string otherwise) so a canvas field edit persists
// IDENTICALLY to a per-block field edit.
// With the previous node, the patch carries only the keys the author changed: a
// label typed in place writes `label` and leaves the stored value's form untouched.
function fieldNodeToPatch(node, prevNode) {
  const attrs = (node && node.attrs) || {};
  const bpType = attrs.bpType || "field-string";
  const value = normalizeFieldValue(bpType, attrs.value);
  if (!prevNode) return { value };
  const prev = prevNode.attrs || {};
  const patch = {};
  if (canonicalJSON(value) !== canonicalJSON(normalizeFieldValue(prev.bpType || bpType, prev.value))) patch.value = value;
  if ((attrs.label ?? null) !== (prev.label ?? null)) patch.label = attrs.label ?? null;
  // Unbind (contract 1.13.0): the block's fieldName cleared makes it a free block, the
  // patch LiveView's Properties × sends ({fieldName: null}).
  if ((attrs.fieldName || null) !== (prev.fieldName || null)) patch.fieldName = attrs.fieldName || null;
  // Config edited in the field's settings disclosure: a select's options, a number's
  // min / max / step / unit. Each rides only when it changed.
  for (const k of FIELD_SETTINGS_CONFIG) {
    if (canonicalJSON(attrs[k] ?? null) !== canonicalJSON(prev[k] ?? null)) patch[k] = attrs[k] ?? null;
  }
  return Object.keys(patch).length ? patch : { value };
}

const FIELD_SETTINGS_CONFIG = ["options", ...FIELD_NUMBER_CONFIG];

// True when a field node's VALUE changed (the only mutable datum). Canonical
// (key-order-insensitive) compare of the normalized value, so a value edit flips it
// but a pure reorder (or a config-only re-render) does not. The value is normalized
// to its per-type stored form before comparison so a boolean true and "true", or a
// null and "" string, compare EQUAL (they persist identically).
function fieldNodeChanged(prevNode, nextNode) {
  return stableFieldKey(prevNode) !== stableFieldKey(nextNode);
}

function stableFieldKey(node) {
  const a = (node && node.attrs) || {};
  const bpType = a.bpType || "field-string";
  const key = { value: normalizeFieldValue(bpType, a.value), label: a.label ?? null, fieldName: a.fieldName || null };
  for (const k of FIELD_SETTINGS_CONFIG) key[k] = a[k] ?? null;
  return canonicalJSON(key);
}

// ── action ⇄ canvas control-atom node (editable-action) ──────────────────────
//
// The CTA action block { id, type:"action", href?, label?, priority? } ⇄ the TipTap
// `bpAction` CONTROL-ATOM node. UNLIKE the field control-atom (one `value`, coerced by
// field type) an action carries THREE optional payload keys edited by native controls,
// and serves ONE bpType. UNLIKE code/diagram (droppable optional field emitted "" on
// clear) the V1 coarse re-emit threads each key ONLY when present — a user edit sets
// href+label via the inputs (both present after a touch) and priority when non-nil.
//
// priority is a TRI-STATE at rest that the reader (walk.ex button/2 :article) collapses
// to BINARY: primary iff =="primary", else secondary. normalizeActionPriority mirrors
// that collapse so nil≡secondary — selecting "Secondary" on a never-set-priority block
// is a ZERO-op and only href/label text or a primary↔secondary flip emits.
//
// node.type is `bpAction` (the NODE name), NOT `action` (the bpType).

// Collapse a tri-state priority to the reader's binary value (walk.ex button/2).
function normalizeActionPriority(p) {
  return p === "primary" ? "primary" : "secondary";
}

// actionBlockToNode(block) → { type:"bpAction", attrs:{ bpId, bpType, href?, label?,
//   priority? } }
//
// Each payload key rides an attr ONLY when present (null = the absence sentinel), so an
// untouched action's getJSON re-projection matches and emits zero ops. Doctrine
// template attrs (locked/role) carried when set (an action could be a mandated block).
function actionBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType };
  if (block && block.href != null) attrs.href = block.href;
  if (block && block.label != null) attrs.label = block.label;
  if (block && block.priority != null) attrs.priority = block.priority;
  stampTemplateAttrs(attrs, block);
  return { type: CANVAS_ACTION_NODE_NAME, attrs };
}

// actionNodeToBlock(node, id) → { id, type:"action", href?, label?, priority? }
//
// The inverse of actionBlockToNode — absence preserved. block.type is the FIXED
// "action" (the node serves one bpType); each payload key is threaded ONLY when present
// so the reconstructed block is byte-identical to one that round-tripped through
// compose.ex (no stray href:"" / null priority).
function actionNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "action" };
  if (attrs.href != null) block.href = attrs.href;
  if (attrs.label != null) block.label = attrs.label;
  if (attrs.priority != null) block.priority = attrs.priority;
  carryTemplateAttrs(block, attrs);
  return block;
}

// The COARSE whole-attrs PATCH for an action block. href/label/priority are threaded
// when !=null. Since any user edit sets href+label via the inputs, both are present
// after a touch; priority is present when non-nil. This is the v1 coarse re-emit
// (the greenlit coarse round-trip).
function actionNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  const patch = {};
  if (attrs.href != null) patch.href = attrs.href;
  if (attrs.label != null) patch.label = attrs.label;
  if (attrs.priority != null) patch.priority = attrs.priority;
  return patch;
}

// The canonical (order/absence-insensitive) key of an action node's diff-relevant
// attrs — href/label as their display strings ("" when absent), priority collapsed to
// its binary value. The normalize collapses nil≡secondary so selecting "Secondary" on a
// never-set block is a ZERO-op (matches the reader). Mirrors action-node.js:actionKey.
function stableActionKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    href: a.href == null ? "" : a.href,
    label: a.label == null ? "" : a.label,
    priority: normalizeActionPriority(a.priority),
  });
}

// True when an action node's href/label/priority changed (a control edit). Canonical
// compare so a pure reorder (bpId/bpType only) does not flip it, and a nil→secondary
// select is a no-op.
function actionNodeChanged(prevNode, nextNode) {
  return stableActionKey(prevNode) !== stableActionKey(nextNode);
}

// ── sheet / embed ⇄ canvas read-only atom node (S3.6) ────────────────────────
//
// The sheet { id, type:"sheet", ref?, snapshot:<cached value-grid> } and embed
// { id, type:"embed", target:"<note title>" } blocks ⇄ the TipTap `bpSheet` /
// `bpEmbed` READ-ONLY ATOM nodes. UNLIKE every other canvas node, NOTHING here is
// EDITED in the editor: a sheet is edited in its own surface and an embed resolves at
// VIEW render (walk.ex), so the editor only ever renders a READ-ONLY chip. The WHOLE
// block rides VERBATIM on the `bpBlock` attr (the bpOpaque verbatim-carry), so the
// block round-trips byte-identically with ZERO value/content ops. The node carries NO
// individually-mutable attr — there is nothing for the editor to write back.
//
// node.type is `bpSheet` / `bpEmbed` (the NODE name), NOT the bpType (sheet / embed) —
// see the CANVAS_READONLY_ATOM_NODE_NAMES note.

// readOnlyAtomBlockToNode(block) → { type:"bpSheet"|"bpEmbed",
//   attrs:{ bpId, bpType, bpBlock:<the WHOLE block, deep-cloned> } }
//
// The whole block is deep-cloned onto bpBlock (no shared ref / no mutation), so an
// UNCHANGED sheet/embed is deep-equal to the original. The node name comes off the
// bpType (sheet → bpSheet; embed → bpEmbed).
function readOnlyAtomBlockToNode(block, bpId, bpType) {
  const nodeName = CANVAS_READONLY_ATOM_NODE_NAMES[bpType] || "bpSheet";
  return {
    type: nodeName,
    attrs: { bpId, bpType, bpBlock: deepClone(block) },
  };
}

// readOnlyAtomNodeToBlock(node, id) → the carried block VERBATIM, with the given id
// stamped on. The inverse of readOnlyAtomBlockToNode: it returns the deep-cloned
// bpBlock (so callers never share a ref with the node's attr) with `id` pinned —
// EXACTLY the bpOpaque insert reconstruction. A node with no bpBlock (a freshly-typed
// read-only atom, which the canvas never produces) degrades to a bare { id, type }.
function readOnlyAtomNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const bpType =
    attrs.bpType || CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE[node && node.type] || "sheet";
  if (attrs.bpBlock != null) {
    const block = deepClone(attrs.bpBlock);
    block.id = id;
    return block;
  }
  return { id, type: bpType };
}

// ── pd-ee-sheet-embed-retarget: the ONE op a read-only atom can emit ──────────
//
// The read-only-never-patches guarantee above holds for everything a read-only atom
// RESOLVES — a sheet's cells, an embed's transcluded prose. It gains exactly ONE
// exception per atom: the REFERENCE the author authors, now editable in-canvas
// through the reference picker the node-view mounts (embed-node.js,
// mountAtomRetarget). A retarget mutates the carried block, so the diff below sees it
// and emits a single patch-block. An atom with no entry in the key map below (a future
// read-only atom) keeps the original zero-ops-by-construction guarantee.
//
// THE TWO ATOMS PATCH DIFFERENT KEY SETS, and the difference is not cosmetic:
//
//   sheet → { ref, snapshot: null }. `snapshot` is a cached projection of the OLD
//     sheet; shipping only `ref` would leave patch.ex's shallow merge holding the
//     previous sheet's cells under the new sheet's name — the stale-snapshot hazard.
//     Clearing costs nothing: Barkpark.Content.Sheets' hydrate_sheet_embed_snapshots
//     runs PRE-WRITE on the same save (content/writer.ex) and re-projects the grid for
//     the NEW ref, and PortableDoc.Render.Compose reads `Map.get(b, "snapshot") || %{}`,
//     so an unresolved ref paints an empty grid instead of another sheet's numbers.
//   embed → { target }. An embed caches NOTHING: its transclusion is resolved fresh on
//     every render (Papers.resolve_embeds_in_blocks → walk.ex embed/2 reads
//     `pal.embeds[target]`), so there is no stale projection to clear and a
//     `snapshot: null` here would write a key the embed block does not own.
//
// NEITHER IS VALIDATED. An embed target that resolves to nothing still saves — the
// reader has an unresolved-fallback branch and notes get renamed under drafts that
// point at them.

// The key each read-only atom's retarget authors on the carried block. Absent ⇒ that
// atom emits no ops at all.
const READ_ONLY_ATOM_RETARGET_KEY = { sheet: "ref", embed: "target" };

// The reference carried by a read-only atom node, as a comparable string ("" for an
// absent/nulled value).
function readOnlyAtomRef(node, key) {
  const block = (node && node.attrs && node.attrs.bpBlock) || {};
  const value = block[key];
  return value == null ? "" : String(value);
}

// The retarget patch for a read-only atom whose carried reference CHANGED, or null.
// Any other difference in the carried block (a server re-projected snapshot, say) is
// NOT an authored edit and emits nothing.
function readOnlyAtomRetargetPatch(bpType, prevNode, nextNode) {
  const key = READ_ONLY_ATOM_RETARGET_KEY[bpType];
  if (!key) return null;
  const next = readOnlyAtomRef(nextNode, key);
  if (readOnlyAtomRef(prevNode, key) === next) return null;
  // sheet also clears the OLD ref's cached grid; embed has no cached projection.
  return bpType === "sheet" ? { ref: next, snapshot: null } : { target: next };
}

// ── fleet ⇄ canvas server-painted read-only atom node (pdd-t8) ────────────────
//
// The component-fleet blocks ({ id, type:"tasks"|"cards"|"pipeline"|"form"|…, … })
// ⇄ the SINGLE TipTap `bpFleet` READ-ONLY ATOM node. Structurally these are the
// sheet/embed read-only atom (the WHOLE block rides VERBATIM on `bpBlock`; ZERO
// value/content ops; structural-only participation) — the ONLY differences are (1)
// ALL fleet kinds share the ONE `bpFleet` node (the specific kind rides the bpType
// attr, exactly like bpField multiplexes the 9 field-* kinds) and (2) the node-view
// paints the reader's OWN pushed HTML (bp:block-html) instead of a client-computed
// chip. Nothing here is EDITED in the editor — a task board / card grid / pipeline /
// grill is authored elsewhere and rendered read-only in the canvas exactly as the
// /papers reader renders it.

// fleetBlockToNode(block) → { type:"bpFleet", attrs:{ bpId, bpType, bpBlock:<whole
//   block, deep-cloned> } }
//
// The whole block is deep-cloned onto bpBlock (no shared ref / no mutation), so an
// UNCHANGED fleet block is deep-equal to the original. The node name is ALWAYS
// bpFleet; the original kind rides bpType (so runToOps/reconstruct read it back).
function fleetBlockToNode(block, bpId, bpType) {
  return {
    type: CANVAS_FLEET_NODE_NAME,
    attrs: { bpId, bpType, bpBlock: deepClone(block) },
  };
}

// fleetNodeToBlock(node, id) → the carried block VERBATIM, with the given id stamped
// on. The inverse of fleetBlockToNode: it returns the deep-cloned bpBlock (so callers
// never share a ref with the node's attr) with `id` pinned — EXACTLY the bpOpaque /
// read-only-atom insert reconstruction. A node with no bpBlock (which the canvas never
// produces) degrades to a bare { id, type } off the bpType attr.
function fleetNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  if (attrs.bpBlock != null) {
    const block = deepClone(attrs.bpBlock);
    block.id = id;
    return block;
  }
  return { id, type: attrs.bpType || "tasks" };
}

// The mutable-fields PATCH for an EDITABLE fleet block (pd-ee-fleet-editors). UNLIKE
// the read-only sheet/embed atom (which never patches), a fleet block carries authored
// content — cards/notes/pipeline items, task-* query/id config — on `bpBlock`, edited
// by the node-view's structured island. patch.ex's patch-block is a SHALLOW Map.merge,
// so we emit the block's EDITABLE PAYLOAD: every key EXCEPT the immutable `id`/`type`
// (patch.ex re-pins both and strips locked/role anyway). The shallow merge REPLACES the
// edited arrays/query (e.g. { cards:[…] } / { items:[…] } / { stages:[…] } /
// { query:{…} }) and leaves unknown sibling keys intact. Deep-cloned so the emitted op
// never shares a ref with the node attr.
function fleetNodeToPatch(node) {
  const block = (node && node.attrs && node.attrs.bpBlock) || {};
  const patch = {};
  for (const key of Object.keys(block)) {
    if (key === "id" || key === "type") continue;
    patch[key] = deepClone(block[key]);
  }
  return patch;
}

// True when a fleet block's carried content changed. Canonical (key-order-insensitive)
// compare of the bpBlock with `id` STRIPPED (id is STRUCTURAL — a reorder/move changes
// it, not the content), so an authored edit (a card added, a note's text changed, a
// pipeline stage removed, a task query relabelled) flips it while a pure reorder does
// NOT — an UNEDITED fleet block emits ZERO ops (D3 byte-stability). `type` stays in the
// key (it never changes; keeping it self-documents the compared shape).
function fleetNodeChanged(prevNode, nextNode) {
  return stableFleetKey(prevNode) !== stableFleetKey(nextNode);
}

function stableFleetKey(node) {
  const block = (node && node.attrs && node.attrs.bpBlock) || {};
  const { id, ...rest } = block;
  return canonicalJSON(rest);
}

// ── figure ⇄ canvas server-painted-child + editable-caption atom ─────────────
//
// The `figure` block { id, type:"figure", caption?:<string>, child:<BLOCK> } ⇄ the
// TipTap `bpFigure` ATOM (figure-node.js). UNLIKE the fleet/sheet read-only atoms
// (whole block verbatim on bpBlock, ZERO ops) OR the diagram attr-atom (a fully
// self-describing source+caption), a figure is a HYBRID: the CHILD rides VERBATIM/
// immutable on `bpChild` (deep-cloned, no shared ref) AND is server-painted
// read-only, while the CAPTION is the SOLE editable datum and emits a
// patch-block{caption}. Carrying ONLY the child (NOT the whole figure) keeps the
// editable caption the single source of truth, so echo-equality compares child-only
// (no stale-caption-in-a-carried-block misdetect). node.type is `bpFigure` (the NODE
// name), NOT `figure` (the bpType).

// figureBlockToNode(block) → { type:"bpFigure", attrs:{ bpId, bpType, caption, bpChild } }
//
// caption → the `caption` attr ONLY when non-empty (byte-fidelity: ""/absent → null,
// mirrors the diagram caption). bpChild → the deep-cloned child block (VERBATIM), or
// null when the figure carries no child.
function figureBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    // "" → null so a caption-less figure round-trips with no caption key.
    caption:
      block && block.caption != null && block.caption !== ""
        ? block.caption
        : null,
    bpChild: block && block.child != null ? deepClone(block.child) : null,
  };
  return { type: CANVAS_FIGURE_NODE_NAME, attrs };
}

// figureNodeToBlock(node, id) → { id, type:"figure", child, ...(caption?) }
//
// Reconstruct the portable-doc figure block from a bpFigure NODE (the inverse of
// figureBlockToNode). `child` is the deep-cloned bpChild VERBATIM (so callers never
// share a ref with the node attr); `caption` is threaded ONLY when non-empty so an
// absent caption reconstructs byte-identically (no stray caption:"").
function figureNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "figure",
    child: attrs.bpChild != null ? deepClone(attrs.bpChild) : null,
  };
  if (attrs.caption != null && attrs.caption !== "") block.caption = attrs.caption;
  return block;
}

// The mutable-fields PATCH for a figure block. The caption is the WHOLE editable
// interior; the child is immutable in v1. patch.ex's patch-block is a SHALLOW
// Map.merge, so emitting ONLY { caption } leaves the stored `child` untouched. The
// value is null when cleared/absent (compose/walk treat ""/absent the same, and the
// merge stores null → render-equivalent to a caption-less figure). Extend to
// { caption, child } only if a future editable child lands (harmless additive).
function figureNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return { caption: attrs.caption == null ? null : attrs.caption };
}

// True when a figure node's caption changed. Canonical (key-order-insensitive)
// compare of the diff-relevant fields — caption + child — so a caption edit flips it
// but a pure reorder (bpId/bpType only) does not. The child rides the key so a future
// editable child would be detected too; today it is immutable, so only the caption
// ever moves. An absent caption normalizes to null so a caption-less node and one
// carrying caption:"" / caption:null compare EQUAL (they persist render-identically).
function figureNodeChanged(prevNode, nextNode) {
  return stableFigureKey(prevNode) !== stableFigureKey(nextNode);
}

function stableFigureKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    caption: a.caption == null || a.caption === "" ? null : a.caption,
    child: a.bpChild != null ? a.bpChild : null,
  });
}

// ── island atoms ⇄ typed attrs + verbatim rest ────────────────────────────────
const islandEmpty = (v) => v == null || v === "" || (Array.isArray(v) && v.length === 0);

function islandBlockToNode(block, bpId, bpType) {
  const spec = CANVAS_ISLAND_SPECS[bpType];
  const attrs = { bpId, bpType };
  const rest = {};
  let hasRest = false;
  for (const k of Object.keys(block || {})) {
    if (k === "id" || k === "type") continue;
    if (spec.fields.includes(k)) continue;
    rest[k] = deepClone(block[k]);
    hasRest = true;
  }
  for (const k of spec.fields) {
    const v = block ? block[k] : undefined;
    attrs[k] = v === undefined || v === "" ? null : deepClone(v);
  }
  attrs.bpRest = hasRest ? rest : null;
  return { type: spec.nodeName, attrs };
}

function islandNodeToBlock(node, id) {
  const bpType = CANVAS_ISLAND_BP_TYPE_BY_NODE[node && node.type];
  const spec = CANVAS_ISLAND_SPECS[bpType];
  const attrs = (node && node.attrs) || {};
  const block = { id, type: bpType };
  for (const k of spec.fields) {
    if (attrs[k] != null && attrs[k] !== "") block[k] = deepClone(attrs[k]);
  }
  if (attrs.bpRest && typeof attrs.bpRest === "object") {
    for (const k of Object.keys(attrs.bpRest)) {
      if (k !== "id" && k !== "type" && !spec.fields.includes(k)) block[k] = deepClone(attrs.bpRest[k]);
    }
  }
  return block;
}

// The patch: every editable key, present or cleared ("" for a string, [] for a list,
// false for a flag) — patch-block merges keys, so a cleared field must ride, not vanish.
function islandNodeToPatch(node) {
  const bpType = CANVAS_ISLAND_BP_TYPE_BY_NODE[node && node.type];
  const spec = CANVAS_ISLAND_SPECS[bpType];
  const attrs = (node && node.attrs) || {};
  const patch = {};
  for (const k of spec.fields) {
    const v = attrs[k];
    patch[k] = v == null ? (k === "notes" || k === "items" ? [] : k === "display" || k === "numbered" || k === "loop" ? false : "") : deepClone(v);
  }
  return patch;
}

function stableIslandKey(node) {
  const bpType = CANVAS_ISLAND_BP_TYPE_BY_NODE[node && node.type];
  const spec = CANVAS_ISLAND_SPECS[bpType] || { fields: [] };
  const a = (node && node.attrs) || {};
  const data = {};
  for (const k of spec.fields) data[k] = islandEmpty(a[k]) ? null : a[k];
  return canonicalJSON({ data, rest: a.bpRest != null ? a.bpRest : null });
}

function islandNodeChanged(prevNode, nextNode) {
  return stableIslandKey(prevNode) !== stableIslandKey(nextNode);
}

// ── image ⇄ canvas self-painting atom ─────────────────────────────────────────
//
// { id, type:"image", src?, alt?, width?, height?, locked?, role?, …rest } ⇄
// { type:"bpImage", attrs:{ bpId, bpType, src, alt, locked, role, bpRest } }.
// src/alt: ""/absent → null (byte-fidelity: an absent alt reconstructs absent).
// bpRest: every other key except id/type/src/alt/locked/role, deep-cloned, or null.
const IMAGE_OWN_KEYS = new Set(["id", "type", "src", "alt", "width", "locked", "role"]);

function imageBlockToNode(block, bpId, bpType) {
  const rest = {};
  let hasRest = false;
  for (const k of Object.keys(block || {})) {
    if (IMAGE_OWN_KEYS.has(k)) continue;
    rest[k] = deepClone(block[k]);
    hasRest = true;
  }
  const attrs = stampTemplateAttrs(
    {
      bpId,
      bpType,
      src: block && block.src != null && block.src !== "" ? String(block.src) : null,
      alt: block && block.alt != null && block.alt !== "" ? String(block.alt) : null,
      width: block && Number.isFinite(parseInt(block.width, 10)) ? parseInt(block.width, 10) : null,
      bpRest: hasRest ? rest : null,
    },
    block,
  );
  return { type: CANVAS_IMAGE_NODE_NAME, attrs };
}

// The inverse: src/alt only when set, then the carried rest, then locked/role.
function imageNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = { id, type: "image" };
  if (attrs.src != null && attrs.src !== "") block.src = attrs.src;
  if (attrs.alt != null && attrs.alt !== "") block.alt = attrs.alt;
  if (attrs.width != null) block.width = attrs.width;
  if (attrs.bpRest && typeof attrs.bpRest === "object") {
    for (const k of Object.keys(attrs.bpRest)) {
      if (!IMAGE_OWN_KEYS.has(k)) block[k] = deepClone(attrs.bpRest[k]);
    }
  }
  return carryTemplateAttrs(block, attrs);
}

// The mutable-fields patch: src + alt only. patch.ex's patch-block is a shallow merge,
// so width/height/role stay untouched; a cleared value rides as "" (the reader treats
// an empty src as scaffolding and skips the block).
function imageNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return { src: attrs.src == null ? "" : attrs.src, alt: attrs.alt == null ? "" : attrs.alt, width: attrs.width == null ? null : attrs.width };
}

function stableImageKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    src: a.src == null || a.src === "" ? null : a.src,
    alt: a.alt == null || a.alt === "" ? null : a.alt,
    width: a.width == null ? null : a.width,
    rest: a.bpRest != null ? a.bpRest : null,
  });
}

function imageNodeChanged(prevNode, nextNode) {
  return stableImageKey(prevNode) !== stableImageKey(nextNode);
}

// ── task-list ⇄ canvas editable-query + server-painted-rows atom ──────────────
//
// The LIVE `task-list` block { id, type:"task-list", query:{…}, title?, config? } ⇄
// the TipTap `bpTaskList` ATOM (task-list-node.js). UNLIKE the fleet/sheet read-only
// atoms (whole block verbatim on bpBlock, ZERO ops) the task-list carries ONLY its
// EDITABLE data as typed attrs: `query` (the filter, JSON — the sole authored datum,
// analogous to figure's caption over a server-painted child), an optional `title`
// string, and an optional `config` JSON. There is NO snapshot on the node — the rows
// are a resolve-at-read PROJECTION the server paints. An edit emits patch-block{query}
// (a SHALLOW Map.merge replacing the stored query, leaving unknown sibling keys
// intact); the server RE-RESOLVES + repaints. node.type is `bpTaskList` (the NODE
// name), NOT `task-list` (the bpType). Mirrors figureBlockToNode..stableFigureKey.

// taskListBlockToNode(block) → { type:"bpTaskList", attrs:{ bpId, bpType, query,
//   title, config } }. query is deep-cloned (VERBATIM — non-label keys like parent_id
//   /labels/status round-trip untouched); title "" → null; config passes through
//   (null when absent).
function taskListBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    query: block && isPlainObject(block.query) ? deepClone(block.query) : {},
    // "" → null so a title-less task-list round-trips with no title key.
    title:
      block && block.title != null && block.title !== "" ? block.title : null,
    config: block && block.config != null ? deepClone(block.config) : null,
  };
  return { type: CANVAS_TASK_LIST_NODE_NAME, attrs };
}

// taskListNodeToBlock(node, id) → { id, type:"task-list", query, ...(title?),
//   ...(config?) }. The inverse of taskListBlockToNode: query is the deep-cloned attr
//   VERBATIM (so callers never share a ref); title/config are threaded ONLY when
//   present so an absent key reconstructs byte-identically (no stray title:"" /
//   config:null). NEVER emits a snapshot — a live task-list has none.
function taskListNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "task-list",
    query: isPlainObject(attrs.query) ? deepClone(attrs.query) : {},
  };
  if (attrs.title != null && attrs.title !== "") block.title = attrs.title;
  if (attrs.config != null) block.config = deepClone(attrs.config);
  return block;
}

// The mutable-fields PATCH for a task-list block. The query is the WHOLE editable
// datum; patch.ex's patch-block is a SHALLOW Map.merge, so { query } REPLACES the
// stored query and leaves unknown sibling keys intact. `query` is ALWAYS present (an
// emptied query is null → the reader shows the "configure me" empty state). `title`
// rides as the string (or "" when cleared, so the shallow merge overwrites a stale
// title — the code/diagram caption rule) ONLY when it changed; `config` likewise.
function taskListNodeToPatch(node, prevNode) {
  const a = (node && node.attrs) || {};
  const patch = { query: isPlainObject(a.query) ? a.query : null };

  const prev = (prevNode && prevNode.attrs) || {};
  const prevTitle = prev.title == null || prev.title === "" ? null : prev.title;
  const nextTitle = a.title == null || a.title === "" ? null : a.title;
  if (prevTitle !== nextTitle) patch.title = nextTitle == null ? "" : nextTitle;

  if (canonicalJSON(prev.config ?? null) !== canonicalJSON(a.config ?? null)) {
    patch.config = a.config ?? null;
  }
  return patch;
}

// True when a task-list node's editable data changed. Canonical (key-order-
// insensitive) compare of query + title + config, so an edit flips it but a pure
// reorder (bpId/bpType only) does not — an UNEDITED task-list emits ZERO ops (D3). An
// absent/"" title and an absent config normalize to null so absent ⇄ "" ⇄ null
// compare EQUAL.
function taskListNodeChanged(prevNode, nextNode) {
  return stableTaskListKey(prevNode) !== stableTaskListKey(nextNode);
}

function stableTaskListKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    query: isPlainObject(a.query) ? a.query : null,
    title: a.title == null || a.title === "" ? null : a.title,
    config: a.config == null ? null : a.config,
  });
}

export {
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
};
