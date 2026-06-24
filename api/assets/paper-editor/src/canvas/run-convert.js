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
  inlineArrayToTiptap,
  tiptapInlineToPd,
} from "../convert.js";

// The doc-block kinds convert.js round-trips as prose (convert.js blockToTiptap
// switch). These project to a native ProseMirror textblock and diff via
// buildPatchBlockOp.
const PROSE_TYPES = new Set(["paragraph", "heading", "list"]);

// S3: non-prose block kinds the canvas handles as ATOM nodes — leaf nodes that
// live INSIDE the canvas document (not run boundaries, not opaque carry-through).
// The divider is the first: a leaf with no content, so it NEVER reports an
// interior change. As later increments land callout/code/field/sheet atoms they
// join this set. A node is "canvas-handled" if it is PROSE or a canvas ATOM;
// only a truly-unknown non-prose kind stays bpOpaque.
const CANVAS_ATOM_TYPES = new Set(["divider"]);

// S3.2: non-prose block kinds the canvas handles as CONTENT nodes — nodes with an
// EDITABLE interior (a contentDOM) living INSIDE the canvas document, NOT atoms
// and NOT opaque. The callout is the first: its body is an editable inline region
// (compose.ex:155 feeds callout `content` through compose_inline_children → ONE
// inline PdText), so unlike the divider ATOM it CAN report an interior change and
// emits a patch-block on a body/tone/title/collapsed edit. As later increments
// land sheet/field as content node-views they join this set.
//
// A node is "canvas-handled" if it is PROSE, a canvas ATOM, a canvas ATTR-ATOM, or
// a canvas CONTENT node; only a truly-unknown non-prose kind stays bpOpaque.
const CANVAS_CONTENT_TYPES = new Set(["callout"]);

// S3.3: non-prose block kinds the canvas handles as ATTR-ATOM nodes — ATOM nodes
// (no PM-managed interior, like the divider) whose body text rides in an ATTR and
// is edited by a NON-PM control (a <textarea> island; see code-node.js). The code
// block is the first: its `value` is a plain string (compose.ex:272 reads only
// Map.get(b,"value")) edited outside ProseMirror, with an optional `lang`. UNLIKE
// the divider ATOM (which has NOTHING to edit and emits zero ops forever), an
// attr-atom HAS a mutable value/lang, so it CAN emit a patch-block when those
// change — but UNLIKE the callout CONTENT node it has no contentDOM and no inline
// body (the text is an opaque string, not PM runs).
//
// S3.4 adds the `diagram` block to this SAME set: it reuses the code attr-atom shape
// ALMOST VERBATIM with two field differences — its body field is `source` (the
// Mermaid text, not `value`) plus an OPTIONAL `caption` (where code had `lang`).
// compose.ex:224 reads Map.get(b,"source") + Map.get(b,"caption"); the source rides
// the textarea island, edited outside ProseMirror. field-* / sheet STILL split until
// their own increments.
//
// A node is "canvas-handled" if it is PROSE, a canvas ATOM, a canvas ATTR-ATOM, or
// a canvas CONTENT node; only a truly-unknown non-prose kind stays bpOpaque.
const CANVAS_ATTR_ATOM_TYPES = new Set(["code", "diagram"]);

// The TipTap NODE name for an attr-atom block differs from its bpType. For code it is
// `bpCode`, NOT `code` — `code` is the StarterKit inline code MARK (a node + mark
// can't share a name). For diagram it is `bpDiagram` (the canvas naming convention;
// there is no StarterKit `diagram` node to collide with, but the canvas keeps the
// bp-prefix). runToTiptap maps a block.type → its node.type; runToOps maps it back
// via bpType. Keep aligned with code-node.js:BP_CODE_NODE_NAME and
// diagram-node.js:BP_DIAGRAM_NODE_NAME.
const CANVAS_ATTR_ATOM_NODE_NAMES = { code: "bpCode", diagram: "bpDiagram" };
// Reverse: node.type "bpCode" → bpType "code", "bpDiagram" → "diagram". Used by
// runToOps to detect an attr-atom by its NODE type (the type carried on a getJSON
// node).
const CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE = { bpCode: "code", bpDiagram: "diagram" };

// S3.5: the 7 NATIVE-CONTROL field-* block kinds the canvas handles as CONTROL-ATOM
// nodes — atom nodes (no PM-managed body, like the divider/code) whose VALUE rides
// in an attr and is edited by a NATIVE HTML control (input / textarea / checkbox /
// select / datetime-local / color; see field-node.js). UNLIKE the code/diagram
// attr-atoms (one bpType per TipTap node, body text in a free textarea), the field
// control-atom serves 7 bpTypes through ONE node (`bpField`), the edit surface is a
// TYPED control, and the value is COERCED BY FIELD TYPE exactly like the shipped
// BarkparkFieldBlockBridge (field-boolean → a BOOLEAN via control.checked; every
// other native type → a STRING via control.value).
//
// RUN-SPLITTER TAIL (part 1): field-image (bp-media-picker WC) and field-reference
// (bp-reference-picker WC) now ALSO ride the canvas through the SAME `bpField` atom —
// the PICKER variant. The pickers are CLIENT-SIDE (no LiveView dependency), so they
// mount inside the node-view exactly like a native control; the edit surface is the WC,
// and on its `bp-change` the node-view writes the new `value` back IDENTICALLY to the
// per-block bridge. From run-convert's POV the picker types are diffed/folded EXACTLY
// like the native types (value is the only mutable datum, patch is { value }), with two
// extra OPTIONAL config keys carried verbatim: refType (field-reference's target schema)
// and dataset (a per-block fetch-scope override). Keep CANVAS_FIELD_TYPES = native ∪
// picker aligned with field-node.js:(BP_NATIVE_FIELD_TYPES ∪ BP_PICKER_FIELD_TYPES) and
// paper_canvas.ex:(@canvas_field_types ∪ @canvas_picker_field_types).
//
// STILL OUT (separate nested-structure increment): section / composite / object /
// arrayOf / codelist / localizedText. Those are NOT in any canvas-field set and STILL
// split a run.
const CANVAS_NATIVE_FIELD_TYPES = new Set([
  "field-string",
  "field-slug",
  "field-text",
  "field-boolean",
  "field-select",
  "field-datetime",
  "field-color",
]);
const CANVAS_PICKER_FIELD_TYPES = new Set(["field-image", "field-reference"]);
const CANVAS_FIELD_TYPES = new Set([
  ...CANVAS_NATIVE_FIELD_TYPES,
  ...CANVAS_PICKER_FIELD_TYPES,
]);

// The TipTap NODE name for ALL 7 native field types is the SAME single node
// `bpField` (UNLIKE code/diagram, which are one-node-per-type). The specific
// field-* kind rides the node's bpType attr; the node-view dispatches the control
// by it. Keep aligned with field-node.js:BP_FIELD_NODE_NAME.
const CANVAS_FIELD_NODE_NAME = "bpField";

// S3.6: the READ-ONLY ATOM block kinds the canvas handles as READ-ONLY atom nodes —
// atom nodes (no PM-managed body, like the divider/code/field) that are REFERENCES,
// NOT editable text. `sheet` (a cached value-grid embed, edited in its own surface)
// and `embed` (a note transclusion ![[note]], resolved at VIEW render) are both
// carried INTO the canvas as read-only atoms. This is the bpOpaque mechanism (carry
// the WHOLE block verbatim, deep-cloned) made CANVAS-ELIGIBLE (no split) + given a
// dedicated read-only node-view (embed-node.js) instead of the generic opaque
// placeholder.
//
// UNLIKE the field control-atom (whose `value` IS edited → a patch), a read-only atom
// NEVER emits a value/content patch — nothing is edited in the editor. It carries the
// WHOLE block on `bpBlock` (NOT just a value) so it round-trips VERBATIM with ZERO
// value ops, and it DOES participate in STRUCTURAL ops (insert/remove/move by bpId)
// like any block — so it no longer SPLITS a run.
//
// EXPLICITLY OUT (still boundaries): field-image / field-reference (the deferred
// picker fields). After S3.6 sheet/embed are canvas-eligible, so the ONLY remaining
// run splitters are those two pickers (and any composite/object/arrayOf/codelist/
// localizedText). Keep aligned with embed-node.js:BP_SHEET_NODE_NAME /
// BP_EMBED_NODE_NAME and paper_canvas.ex:@canvas_readonly_atom_types.
const CANVAS_READONLY_ATOM_TYPES = new Set(["sheet", "embed"]);

// The TipTap NODE name for a read-only atom block differs from its bpType: for sheet
// it is `bpSheet`, for embed `bpEmbed` (the canvas bp-prefix convention; there is no
// StarterKit sheet/embed node to collide with). runToTiptap maps a block.type → its
// node.type; runToOps maps it back via bpType. Keep aligned with embed-node.js.
const CANVAS_READONLY_ATOM_NODE_NAMES = { sheet: "bpSheet", embed: "bpEmbed" };
// Reverse: node.type "bpSheet" → bpType "sheet", "bpEmbed" → "embed". Used by runToOps
// to detect a read-only atom by its NODE type (the type carried on a getJSON node).
const CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE = { bpSheet: "sheet", bpEmbed: "embed" };

function isProseType(type) {
  return PROSE_TYPES.has(type);
}

function isCanvasAtomType(type) {
  return CANVAS_ATOM_TYPES.has(type);
}

function isCanvasContentType(type) {
  return CANVAS_CONTENT_TYPES.has(type);
}

// True when a portable-doc BLOCK type is a canvas attr-atom (e.g. "code").
function isCanvasAttrAtomType(type) {
  return CANVAS_ATTR_ATOM_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas attr-atom (e.g. "bpCode"). runToOps
// reads node.type off a getJSON node, which is the NODE name, not the bpType.
function isCanvasAttrAtomNode(nodeType) {
  return Object.prototype.hasOwnProperty.call(
    CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE,
    nodeType,
  );
}

// True when a portable-doc BLOCK type is one of the 7 native field-* control-atoms
// (S3.5). field-image / field-reference are EXCLUDED (pickers stay boundaries).
function isCanvasFieldType(type) {
  return CANVAS_FIELD_TYPES.has(type);
}

// True when a TipTap NODE type is the canvas field control-atom ("bpField").
// runToOps reads node.type off a getJSON node (the NODE name); ALL 7 native field
// types share the single `bpField` node, so the specific kind comes off the bpType
// attr, not the node type.
function isCanvasFieldNode(nodeType) {
  return nodeType === CANVAS_FIELD_NODE_NAME;
}

// True when a portable-doc BLOCK type is a canvas read-only atom (S3.6: "sheet" |
// "embed"). These ride INTO the canvas as read-only atoms carrying the whole block
// verbatim; they never emit a value/content op.
function isCanvasReadOnlyAtomType(type) {
  return CANVAS_READONLY_ATOM_TYPES.has(type);
}

// True when a TipTap NODE type is a canvas read-only atom (e.g. "bpSheet" / "bpEmbed").
// runToOps reads node.type off a getJSON node (the NODE name, not the bpType).
function isCanvasReadOnlyAtomNode(nodeType) {
  return Object.prototype.hasOwnProperty.call(
    CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE,
    nodeType,
  );
}

// Structural deep clone, DOM-free and Node-API-free. structuredClone is a
// global in modern V8 (and browsers); fall back to JSON for older runtimes.
// Both are pure and create zero shared references with the source.
function deepClone(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

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
  const content = (blocks || []).map((block) => {
    const bpId = block && block.id;
    const bpType = block && block.type;

    if (isProseType(bpType)) {
      // Lift the single prose node convert.js produced and merge our stamp into
      // its attrs without clobbering blockToTiptap's own attrs (heading level).
      const node = blockToTiptap(block).content[0];
      const attrs = { ...(node.attrs || {}), bpId, bpType };
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
      // A canvas CONTENT node (S3.2: callout): a native node of that type whose
      // BODY is editable inline content and whose chrome (tone/title/collapsible/
      // collapsed) rides node attrs. The canvas schema (callout-node.js) declares
      // it, so getJSON() round-trips both the body and the chrome attrs.
      return calloutBlockToNode(block, bpId, bpType);
    }

    if (isCanvasAttrAtomType(bpType)) {
      // A canvas ATTR-ATOM node (S3.3: code; S3.4: diagram): an atom node whose body
      // TEXT rides in an attr (a plain string, edited by a non-PM textarea) plus an
      // optional second field. The canvas schema declares the node (code-node.js /
      // diagram-node.js), so getJSON() round-trips the body + optional field. NOTE the
      // node.type is the NODE name (bpCode / bpDiagram), not the bpType (code /
      // diagram). Dispatch by bpType: code → value/lang; diagram → source/caption.
      if (bpType === "diagram") return diagramBlockToNode(block, bpId, bpType);
      return codeBlockToNode(block, bpId, bpType);
    }

    if (isCanvasFieldType(bpType)) {
      // A canvas CONTROL-ATOM node (S3.5: the 7 native field-* types): an atom node
      // whose VALUE rides in an attr and is edited by a NATIVE control. ALL 7 types
      // project to the SAME `bpField` node, discriminated by the bpType attr. The
      // node carries the FULL config (label/options/rows/fieldName) so the round-trip
      // is byte-identical — UNLIKE code/diagram, a field block has config keys the
      // canvas must not lose. field-image/field-reference are NOT in this set; they
      // fall through to bpOpaque below (pickers stay boundaries).
      return fieldBlockToNode(block, bpId, bpType);
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

    // Opaque carry-through: the original block JSON, deep-cloned (no shared refs).
    return {
      type: "bpOpaque",
      attrs: { bpId, bpType, bpBlock: deepClone(block) },
    };
  });

  return { type: "doc", content };
}

// ── callout ⇄ canvas content node (S3.2) ────────────────────────────────────
//
// convert.js has NO callout path (it only round-trips paragraph|heading|list), so
// the callout block ⇄ TipTap-node mapping lives HERE, mirroring how blockToTiptap
// /tiptapToBlock handle inline — REUSING convert.js's exported inlineArrayToTiptap
// /tiptapInlineToPd verbatim for the body (the body IS inline runs; do not
// reinvent inline serialization).
//
// The chrome rides node.attrs:
//   tone        — string, defaults "info" (compose.ex:157 `tone || "info"`)
//   title       — optional; ABSENT (null) round-trips as no `title` field
//   collapsible — boolean; ABSENT (false) → no `collapsible` field
//   collapsed   — boolean; ABSENT (false) → no `collapsed` field
// Omitting absent chrome fields is the byte-fidelity contract: compose.ex
// maybe_put / maybe_put_true only thread these when present, so a callout that
// never had a title must round-trip WITHOUT a title key (not title:"").

// calloutBlockToNode(block) → { type:"callout", attrs:{…}, content:[inline…] }
//
// The body inline array (block.content) → TipTap inline nodes via the shared
// serializer. Chrome fields → attrs (only the present ones; tone always present
// with its "info" default so a tone swap is always diffable).
function calloutBlockToNode(block, bpId, bpType) {
  const attrs = {
    bpId,
    bpType,
    tone: (block && block.tone) || "info",
  };
  // Only carry title/collapsible/collapsed when PRESENT in the source block, so
  // an untouched callout's getJSON re-projection matches and emits zero ops.
  if (block && block.title != null) attrs.title = block.title;
  if (block && block.collapsible === true) attrs.collapsible = true;
  if (block && block.collapsed === true) attrs.collapsed = true;

  const node = { type: bpType || "callout", attrs };
  const inline = inlineArrayToTiptap((block && block.content) || []);
  if (inline.length) node.content = inline;
  return node;
}

// calloutNodeToBlock(node, id) → { id, type:"callout", tone, title?, collapsible?,
//   collapsed?, content:[inline…] }
//
// Reconstruct the portable-doc callout block from a callout NODE (the inverse of
// calloutBlockToNode). Body inline ← tiptapInlineToPd (the shared deserializer).
// Chrome fields read off node.attrs, threaded ONLY when present/true so the
// reconstructed block is byte-identical to one that round-tripped through
// compose.ex (no stray title:"" / collapsible:false).
function calloutNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "callout",
    tone: attrs.tone || "info",
    content: tiptapInlineToPd((node && node.content) || []),
  };
  if (attrs.title != null) block.title = attrs.title;
  if (attrs.collapsible === true) block.collapsible = true;
  if (attrs.collapsed === true) block.collapsed = true;
  return block;
}

// The mutable-fields PATCH for a callout (the analogue of buildPatchBlockOp's
// patch map for prose). It is calloutNodeToBlock MINUS id/type — patch.ex re-pins
// those (the same contract tiptapToBlock follows).
//
// CRITICAL: the patch emits the chrome fields (title/collapsible/collapsed)
// EXPLICITLY even when false/null. patch-block is a SHALLOW Map.merge (patch.ex
// merge_block) that can REPLACE or PRESERVE a key but never DELETE one — so
// OMITTING a now-false/null field would leave the STALE old value, silently
// reverting an EXPAND (collapsed true→false via the fold button), a TITLE-CLEAR
// (set→null), or a collapsible-off on persist/reload. An explicit collapsible/
// collapsed:false round-trips byte-identically (compose.ex), and title:null is
// dropped by compose maybe_put. The INSERT path (calloutNodeToBlock) correctly
// OMITS absent fields — only the patch is explicit, so removals actually land.
function calloutNodeToPatch(node) {
  const block = calloutNodeToBlock(node, null);
  const attrs = (node && node.attrs) || {};
  return {
    tone: block.tone,
    content: block.content,
    title: attrs.title == null ? null : attrs.title,
    collapsible: attrs.collapsible === true,
    collapsed: attrs.collapsed === true,
  };
}

// True when a callout node's body OR chrome changed (an interior edit). We
// compare the canonical (key-order-insensitive) projection of the diff-relevant
// fields — tone, title, collapsible, collapsed, content — so a tone swap, title
// edit, fold toggle, or body edit flips it, but a pure reorder (bpId/bpType only)
// does not. Uses the SAME canonicalJSON the prose path uses, so a node serialized
// by calloutBlockToNode and the SAME node from the live editor's getJSON compare
// EQUAL despite differing attr/text key order.
function calloutNodeChanged(prevNode, nextNode) {
  return stableCalloutKey(prevNode) !== stableCalloutKey(nextNode);
}

function stableCalloutKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    tone: a.tone || "info",
    title: a.title == null ? null : a.title,
    collapsible: a.collapsible === true,
    collapsed: a.collapsed === true,
    content: node.content || null,
  });
}

// ── code ⇄ canvas attr-atom node (S3.3) ─────────────────────────────────────
//
// The code block { id, type:"code", value:"<text>", lang?:"<lang>" } ⇄ the TipTap
// `bpCode` ATOM node. UNLIKE the callout (whose body is inline runs), code's body
// is a PLAIN STRING in the `value` attr — there is NO inline serialization; the
// string rides verbatim (multi-line and all). `lang` is OPTIONAL: put_if_present
// drops a nil/"" lang on persist (blocks.ex:113-115), so an absent/empty lang must
// round-trip as NO `lang` key — we omit it on insert and emit it explicitly only
// when set on the patch (mirroring the callout's removal-safe contract).
//
// node.type is `bpCode` (the NODE name), NOT `code` (the bpType) — see the
// CANVAS_ATTR_ATOM_NODE_NAMES note; the StarterKit inline code MARK owns `code`.

// codeBlockToNode(block) → { type:"bpCode", attrs:{ bpId, bpType, value, lang? } }
//
// The code TEXT → the `value` attr verbatim (default "" — Map.put always writes a
// value). `lang` → the `lang` attr ONLY when present + non-empty (byte-fidelity:
// an absent lang has no key).
function codeBlockToNode(block, bpId, bpType) {
  const nodeName = CANVAS_ATTR_ATOM_NODE_NAMES[bpType] || "bpCode";
  const attrs = {
    bpId,
    bpType,
    value: (block && block.value) || "",
  };
  // Carry lang ONLY when present + non-empty, so an untouched lang-less code
  // block's getJSON re-projection matches and emits zero ops.
  if (block && block.lang != null && block.lang !== "") attrs.lang = block.lang;
  return { type: nodeName, attrs };
}

// codeNodeToBlock(node, id) → { id, type:"code", value, lang? }
//
// Reconstruct the portable-doc code block from a bpCode NODE (the inverse of
// codeBlockToNode). `value` reads off the attr (default ""); `lang` is threaded
// ONLY when present + non-empty so the reconstructed block is byte-identical to
// one that round-tripped through compose.ex/build_block_patch (no stray lang:"").
function codeNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "code",
    value: attrs.value || "",
  };
  if (attrs.lang != null && attrs.lang !== "") block.lang = attrs.lang;
  return block;
}

// The mutable-fields PATCH for a code block (the analogue of calloutNodeToPatch).
// `value` always rides the patch (Map.put always writes it). `lang` rides
// EXPLICITLY — but the explicit value is the empty string "" when absent, NOT a
// dropped key. The canvas paper-ops path folds via Patch.apply_patches, where
// patch-block is a SHALLOW Map.merge (patch.ex merge_block) that can REPLACE or
// PRESERVE a key but never DELETE one (it does NOT run build_block_patch's
// put_if_present). So clearing a previously-set lang must emit lang:"" — the merge
// then STORES lang:"", which is render-equivalent to a lang-less block
// (compose/walk treat ""/absent the same) and round-trips (stableCodeKey below
// normalizes ""/null equal → zero spurious ops). Omitting lang would instead leave
// the STALE old lang. So: value always; lang as the string ("" when cleared).
function codeNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return {
    value: attrs.value || "",
    lang: attrs.lang == null ? "" : attrs.lang,
  };
}

// True when a code node's value OR lang changed (an attr edit). Canonical
// (key-order-insensitive) compare of the diff-relevant fields — value + lang — so
// a value edit or a lang change flips it, but a pure reorder (bpId/bpType only)
// does not. An absent lang normalizes to "" so a lang-less node and one carrying
// lang:"" / lang:null compare EQUAL (they persist identically).
function codeNodeChanged(prevNode, nextNode) {
  return stableCodeKey(prevNode) !== stableCodeKey(nextNode);
}

function stableCodeKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    value: a.value || "",
    lang: a.lang == null ? "" : a.lang,
  });
}

// ── diagram ⇄ canvas attr-atom node (S3.4) ──────────────────────────────────
//
// MIRRORS the code mapping (S3.3) ALMOST VERBATIM with two field renames: the body
// field is `source` (not `value`) and the optional second field is `caption` (not
// `lang`). The diagram block { id, type:"diagram", source:"<text>", caption?:"<short>" }
// ⇄ the TipTap `bpDiagram` ATOM node. UNLIKE the callout (whose body is inline runs),
// the diagram's body is a PLAIN STRING in the `source` attr — there is NO inline
// serialization; the string rides verbatim (multi-line Mermaid and all).
//
// caption handling MIRRORS code's lang: although the STORED diagram always carries
// caption (build_block_patch writes it UNCONDITIONALLY, NOT via put_if_present —
// blocks.ex:47), the CANVAS round-trip treats caption like the optional/droppable
// `lang`: omit it on insert and on the projection when absent/empty (compose.ex
// defaults a missing caption to "", so an omitted caption is render-equivalent to ""),
// and emit it EXPLICITLY ("" when cleared) on the patch for the removal-safe shallow
// merge. So an absent/empty caption round-trips as ABSENT and the canonical compare
// treats ""/null/absent EQUAL → zero spurious ops.
//
// node.type is `bpDiagram` (the NODE name), NOT `diagram` (the bpType) — see the
// CANVAS_ATTR_ATOM_NODE_NAMES note.

// diagramBlockToNode(block) → { type:"bpDiagram", attrs:{ bpId, bpType, source, caption? } }
//
// The Mermaid SOURCE → the `source` attr verbatim (default "" — the diagram patch
// always writes a source). `caption` → the `caption` attr ONLY when present +
// non-empty (byte-fidelity: an absent caption has no key). Mirrors codeBlockToNode.
function diagramBlockToNode(block, bpId, bpType) {
  const nodeName = CANVAS_ATTR_ATOM_NODE_NAMES[bpType] || "bpDiagram";
  const attrs = {
    bpId,
    bpType,
    source: (block && block.source) || "",
  };
  // Carry caption ONLY when present + non-empty, so an untouched caption-less diagram
  // block's getJSON re-projection matches and emits zero ops.
  if (block && block.caption != null && block.caption !== "")
    attrs.caption = block.caption;
  return { type: nodeName, attrs };
}

// diagramNodeToBlock(node, id) → { id, type:"diagram", source, caption? }
//
// Reconstruct the portable-doc diagram block from a bpDiagram NODE (the inverse of
// diagramBlockToNode). `source` reads off the attr (default ""); `caption` is
// threaded ONLY when present + non-empty so the reconstructed block is byte-identical
// to a caption-less round-trip (no stray caption:""). Mirrors codeNodeToBlock.
function diagramNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const block = {
    id,
    type: "diagram",
    source: attrs.source || "",
  };
  if (attrs.caption != null && attrs.caption !== "")
    block.caption = attrs.caption;
  return block;
}

// The mutable-fields PATCH for a diagram block (the analogue of codeNodeToPatch).
// `source` always rides the patch. `caption` rides EXPLICITLY — but the explicit
// value is the empty string "" when absent, NOT a dropped key (removal-safe). The
// canvas paper-ops path folds via Patch.apply_patches, where patch-block is a SHALLOW
// Map.merge (patch.ex merge_block) that can REPLACE or PRESERVE a key but never DELETE
// one. So clearing a previously-set caption must emit caption:"" — the merge then
// STORES caption:"", render-equivalent to a caption-less diagram (compose/walk treat
// ""/absent the same) and round-tripping (stableDiagramKey normalizes ""/null equal →
// zero spurious ops). Omitting caption would instead leave the STALE old caption. So:
// source always; caption as the string ("" when cleared). Mirrors codeNodeToPatch.
function diagramNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  return {
    source: attrs.source || "",
    caption: attrs.caption == null ? "" : attrs.caption,
  };
}

// True when a diagram node's source OR caption changed (an attr edit). Canonical
// (key-order-insensitive) compare of the diff-relevant fields — source + caption — so
// a source edit or a caption change flips it, but a pure reorder (bpId/bpType only)
// does not. An absent caption normalizes to "" so a caption-less node and one carrying
// caption:"" / caption:null compare EQUAL (they persist render-identically). Mirrors
// codeNodeChanged.
function diagramNodeChanged(prevNode, nextNode) {
  return stableDiagramKey(prevNode) !== stableDiagramKey(nextNode);
}

function stableDiagramKey(node) {
  const a = (node && node.attrs) || {};
  return canonicalJSON({
    source: a.source || "",
    caption: a.caption == null ? "" : a.caption,
  });
}

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
  // PICKER config (field-image / field-reference) carried verbatim so the round-trip is
  // byte-identical: refType (field-reference's target schema) + dataset (a per-block
  // fetch-scope override). Carried ONLY when present so an untouched picker's getJSON
  // re-projection matches and emits zero ops (a field-reference's default refType is ""
  // — present and kept; an unset dataset has no key).
  if (block && block.refType != null) attrs.refType = block.refType;
  if (block && block.dataset != null) attrs.dataset = block.dataset;
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
  // PICKER config (field-image / field-reference): refType + dataset threaded ONLY when
  // present so the reconstructed block is byte-identical to one that round-tripped
  // through the per-block path (no stray refType/dataset on a native field). The inverse
  // of fieldBlockToNode.
  if (attrs.refType != null) block.refType = attrs.refType;
  if (attrs.dataset != null) block.dataset = attrs.dataset;
  return block;
}

// The mutable-fields PATCH for a field block (the analogue of codeNodeToPatch). The
// ONLY mutable field is `value` — EXACTLY what BarkparkFieldBlockBridge emits
// ({op:"patch-block", id, patch:{value}}). label/options/rows/fieldName are CONFIG,
// not edited through the control, so they NEVER ride the patch — matching the
// per-block bridge byte-for-byte. The value is normalized to its per-type stored
// form (boolean for field-boolean; string otherwise) so a canvas field edit persists
// IDENTICALLY to a per-block field edit.
function fieldNodeToPatch(node) {
  const attrs = (node && node.attrs) || {};
  const bpType = attrs.bpType || "field-string";
  return { value: normalizeFieldValue(bpType, attrs.value) };
}

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
  return canonicalJSON({ value: normalizeFieldValue(bpType, a.value) });
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

// Order-insensitive deep stringify: sorts OBJECT keys recursively (array order
// is preserved — content/marks order is significant). Without this, two
// semantically-identical text nodes that differ only in KEY ORDER would hash
// differently — exactly the runToTiptap `{type,text,marks}` vs ProseMirror
// getJSON `{type,marks,text}` mismatch that otherwise flags EVERY marked block
// as "changed" on every keystroke.
function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJSON).join(",") + "]";
  }
  if (value && typeof value === "object") {
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonicalJSON(value[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(value);
}

// The byte-significant projection of a prose node for change detection: its
// type, heading level (if any), and content — i.e. exactly the inputs to
// buildPatchBlockOp / tiptapToBlock. bpId/bpType are excluded so an identity
// move never looks like an edit. Canonicalized (key-order-insensitive) so a
// node serialized by runToTiptap and the SAME node serialized by the live
// editor's getJSON compare EQUAL despite their differing attr/text key order.
function stableProseKey(node) {
  const level = node.attrs && node.attrs.level;
  return canonicalJSON({
    type: node.type,
    level: level == null ? null : level,
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
  const isAttrAtom = isCanvasAttrAtomNode(node.type);
  const isField = isCanvasFieldNode(node.type);
  const isReadOnlyAtom = isCanvasReadOnlyAtomNode(node.type);
  const bpType =
    (node.attrs && node.attrs.bpType) ||
    CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE[node.type] ||
    CANVAS_READONLY_ATOM_BP_TYPE_BY_NODE[node.type] ||
    (isField ? "field-string" : node.type);
  return {
    node,
    bpType,
    isOpaque,
    isAtom,
    isContent,
    isAttrAtom,
    isField,
    isReadOnlyAtom,
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
export function docToBlocks(doc) {
  const nodes = (doc && doc.content) || [];
  const taken = new Set();
  // Seed `taken` with every id ALREADY on a node so a mint can never collide with a
  // surviving id (two nodes can't legitimately share an id post-normalize, but a
  // belt-and-braces seed keeps minting collision-free regardless).
  for (const node of nodes) {
    const id = node && node.attrs && node.attrs.bpId;
    if (id != null) taken.add(id);
  }
  return nodes.map((node) => {
    const cls = classifyNode(node);
    const bpId = node.attrs && node.attrs.bpId;
    const id = bpId != null ? bpId : mintId(taken);
    return nextNodeToBlock({ ...cls, id, isNew: bpId == null });
  });
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
export function runToOps(prevBlocks, nextDoc) {
  const prev = prevBlocks || [];
  const nextNodes = (nextDoc && nextDoc.content) || [];

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

  // ── 0) BUILD nextSeq: every next node gets a KNOWN id (existing or minted) ──
  //
  // `taken` seeds with every prev id so a minted id can never collide with a
  // surviving block (patch.ex rejects duplicate ids on append/insert-after).
  const taken = new Set();
  prevById.forEach((_block, id) => taken.add(id));

  // Classify each node into its canvas KIND + resolved bpType via the SHARED
  // classifyNode (the same path docToBlocks uses), then resolve the id HERE: a
  // surviving prev id keeps its id (existing); anything else (a split / typed /
  // paste node with bpId:null, or a bpId not in prev) is CLIENT-MINTED. This is
  // the one piece runToOps owns over docToBlocks — id resolution is keyed against
  // the PREV run, not just the live bpId.
  const nextSeq = nextNodes.map((node) => {
    const bpId = node.attrs && node.attrs.bpId;
    const existing = bpId != null && prevIndex.has(bpId);
    const id = existing ? bpId : mintId(taken);
    return { ...classifyNode(node), id, isNew: !existing };
  });

  const nextIds = new Set(nextSeq.map((e) => e.id));

  const ops = [];

  // ── 1) REMOVES — prev id not present in nextSeq (a merge/delete) ───────────
  for (const block of prev) {
    const id = block && block.id;
    if (id != null && !nextIds.has(id)) {
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
    const block = nextNodeToBlock(entry);
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

  // ── 3) MOVES — permute `running` (now exactly nextSeq's id SET) into order ──
  //
  // Walk nextSeq left-to-right. For each entry, the target predecessor is the
  // previous entry's id (or null for the first). Emit a move ONLY when the entry
  // is not ALREADY immediately after that predecessor in the running order — so
  // an already-correct subsequence (e.g. a pure interior edit) emits zero moves.
  // We apply each move to `running` as we go, so subsequent checks see the
  // post-move order and we never emit a redundant move.
  for (let i = 0; i < nextSeq.length; i++) {
    const id = nextSeq[i].id;
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
  // A surviving canvas READ-ONLY ATOM (S3.6: sheet / embed) is ALSO a no-op: it is a
  // REFERENCE carrying the whole block verbatim — nothing is edited in the editor, so
  // it NEVER emits a value/content patch (the read-only-never-patches guarantee).
  for (const entry of nextSeq) {
    if (entry.isNew || entry.isOpaque || entry.isAtom || entry.isReadOnlyAtom)
      continue;
    const prevBlock = prevById.get(entry.id);
    const prevNode = runToTiptap([prevBlock]).content[0];

    if (entry.isContent) {
      // Canvas content node (callout): diff body + chrome; emit one patch-block
      // carrying ONLY the mutable fields when anything changed.
      if (calloutNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: calloutNodeToPatch(entry.node),
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
      if (codeNodeChanged(prevNode, entry.node)) {
        ops.push({
          op: "patch-block",
          id: entry.id,
          patch: codeNodeToPatch(entry.node),
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
          patch: fieldNodeToPatch(entry.node),
        });
      }
      continue;
    }

    if (proseNodeChanged(prevNode, entry.node)) {
      const bpType = entry.bpType || (prevBlock && prevBlock.type);
      ops.push(buildPatchBlockOp(nodeToDocEnvelope(entry.node), entry.id, bpType));
    }
  }

  return ops;
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
function nodeContentEqual(serverNode, liveNode) {
  if (!serverNode || !liveNode) return false;
  // Kind/type must match first (a paragraph echo onto a heading is external).
  if (serverNode.type !== liveNode.type) return false;
  const type = serverNode.type;

  // Callout (content node): tone/title/collapsible/collapsed/body.
  if (isCanvasContentType(type)) {
    return !calloutNodeChanged(serverNode, liveNode);
  }
  // Code / diagram (attr-atom): value+lang / source+caption.
  if (isCanvasAttrAtomNode(type)) {
    if (type === "bpDiagram") return !diagramNodeChanged(serverNode, liveNode);
    return !codeNodeChanged(serverNode, liveNode);
  }
  // Field (control-atom): the normalized value.
  if (isCanvasFieldNode(type)) {
    return !fieldNodeChanged(serverNode, liveNode);
  }
  // Divider (content-free atom leaf): same type with no interior → equal.
  if (isCanvasAtomType(type)) {
    return true;
  }
  // Read-only atom (sheet / embed): the whole carried block, id excluded.
  if (isCanvasReadOnlyAtomNode(type)) {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Opaque carry-through: the whole carried block, id excluded.
  if (type === "bpOpaque") {
    return carriedBlockEqual(serverNode, liveNode);
  }
  // Prose (paragraph / heading / list nodes): type + level + content.
  return !proseNodeChanged(serverNode, liveNode);
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
function nextNodeToBlock(entry) {
  const node = entry.node;
  if (entry.isAtom) {
    // Canvas atom insert (divider): a content-free leaf, fully described by its
    // type + the minted id. No body fields to reconstruct.
    return { id: entry.id, type: entry.bpType || node.type };
  }
  if (entry.isContent) {
    // Canvas content insert (callout): reconstruct the full callout block from
    // the node (body + chrome) with the minted id, via the dedicated mapper.
    return calloutNodeToBlock(node, entry.id);
  }
  if (entry.isAttrAtom) {
    // Canvas attr-atom insert (S3.3: code; S3.4: diagram): reconstruct the block (body
    // + optional field) with the minted id. The optional field is OMITTED on insert
    // when absent/empty — the insert path mirrors the persist default (a lang-less
    // code / caption-less diagram has no key). Dispatch by NODE type.
    if (node.type === "bpDiagram") return diagramNodeToBlock(node, entry.id);
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
  if (entry.isReadOnlyAtom) {
    // Read-only atom insert (S3.6: sheet / embed): the carried WHOLE block, deep-cloned
    // VERBATIM, with the minted id stamped on — EXACTLY the bpOpaque insert
    // reconstruction (the read-only atom carries the full block, not just a value).
    return readOnlyAtomNodeToBlock(node, entry.id);
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
  return { id: entry.id, type: bpType, ...op.patch };
}
