import { inlineArrayToTiptap, tiptapInlineToPd } from "../convert.js";
import { canonicalJSON } from "./projection-json.js";
import {
  CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE,
  CANVAS_ATTR_ATOM_NODE_NAMES,
  CANVAS_STAGE_NODE_NAME,
  ROLE_BODY_MODEL,
  TECHNICAL_ATOM_SHAPES,
} from "./run-kinds.js";

// ── stage ⇄ canvas control-atom node (the pipeline-node twin) ────────────────
//
// The `stage` block ⇄ a bpStage node. WIRE-canonical (scalar) shape, byte-aligned with
// one legacy pipeline `nodes[]` entry:
//   { id, type:"stage", kind?, title?, detail?, files?, source? }
// The three text fields ride via the slot API (slots OR scalar → the SAME plain string);
// files/source are chrome scalars. Every field ATTR is PRESENT-ONLY (absence sentinel
// null), so a stage that never entered the canvas round-trips byte-identical (zero ops).
//   kind/title/detail — string, PRESENT-ONLY (empty/absent → no attr).
//   files             — string chrome, PRESENT-ONLY.
//   source            — chrome flag carried VERBATIM (true|"true"|1), PRESENT-ONLY, so a
//                       hand-authored `source:"true"` round-trips byte-identical; the
//                       accent + change key interpret it truthy.

// The reader `truthy` (compose truthy/1): true | "true" | 1. Mirrors stage-node.js.
function stageTruthy(v) {
  return v === true || v === "true" || v === 1;
}

// stageFieldText(block, name) → the PLAIN string of a stage text slot. JS twin of
// Slots.stage_field_text/2: the lone slot element's text-runs FLATTENED to plain text
// (marks dropped) when a `slots` map carries it, ELSE the top-level scalar. A pasted
// `<strong>` must NOT survive — plain text only, so byte-identity with the escaped-plain
// reader holds.
function stageFieldText(block, name) {
  const slot = block && block.slots && block.slots[name];
  if (Array.isArray(slot) && slot.length) {
    return flattenInlineTextPlain((slot[0] && slot[0].content) || []);
  }
  const v = block && block[name];
  return v == null ? "" : String(v);
}

// Flatten a ProseMirror-style inline array to concatenated PLAIN text (marks dropped):
// a text/code leaf contributes its `value`; a mark node contributes its children
// flattened; a bare string is itself. JS twin of Slots.flatten_inline_text/1.
function flattenInlineTextPlain(list) {
  if (typeof list === "string") return list;
  if (!Array.isArray(list)) return "";
  let out = "";
  for (const n of list) {
    if (typeof n === "string") out += n;
    else if (n && (n.type === "text" || n.type === "code")) out += n.value == null ? "" : String(n.value);
    else if (n && Array.isArray(n.children)) out += flattenInlineTextPlain(n.children);
  }
  return out;
}

// stageBlockToNode(block) → { type:"bpStage", attrs:{…} }. Every field PRESENT-ONLY:
// an empty text field / absent chrome adds NO attr, so an untouched stage's getJSON
// re-projection matches and emits zero ops. `source` is carried VERBATIM.
function stageBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType: bpType || "stage" };
  const kind = stageFieldText(block, "kind");
  if (kind !== "") attrs.kind = kind;
  const title = stageFieldText(block, "title");
  if (title !== "") attrs.title = title;
  const detail = stageFieldText(block, "detail");
  if (detail !== "") attrs.detail = detail;
  const files = block && block.files;
  if (files != null && files !== "") attrs.files = String(files);
  if (block && block.source != null) attrs.source = block.source; // VERBATIM present-only
  return { type: CANVAS_STAGE_NODE_NAME, attrs };
}

// stageNodeToBlock(node, id) → { id, type:"stage", kind?, title?, detail?, files?,
// source? }. The inverse of stageBlockToNode — PRESENT-ONLY (byte-fidelity), source
// VERBATIM. This is the INSERT / reconstruct / docToBlocks path; a fresh-loaded stage
// re-projects to the SAME present-only scalars ⇒ zero ops on open.
function stageNodeToBlock(node, id) {
  const a = (node && node.attrs) || {};
  const block = { id, type: "stage" };
  if (a.kind != null && a.kind !== "") block.kind = a.kind;
  if (a.title != null && a.title !== "") block.title = a.title;
  if (a.detail != null && a.detail !== "") block.detail = a.detail;
  if (a.files != null && a.files !== "") block.files = a.files;
  if (a.source != null) block.source = a.source; // VERBATIM
  return block;
}

// The mutable-fields PATCH for a stage. patch-block is a SHALLOW Map.merge that CANNOT
// delete a key, so — the card `tone:null` precedent generalized — emit the WHOLE
// scalar field set EXPLICITLY: a cleared text field / unchecked source rides `null`
// (renders as an absent/empty cell — reader parity), a set field rides its value.
// source rides VERBATIM when truthy (a title-only edit preserves the original `"true"`),
// else null. So a removal LANDS despite the shallow merge.
function stageNodeToPatch(node) {
  const a = (node && node.attrs) || {};
  const norm = (v) => (v == null || v === "" ? null : v);
  return {
    kind: norm(a.kind),
    title: norm(a.title),
    detail: norm(a.detail),
    files: norm(a.files),
    source: stageTruthy(a.source) ? a.source : null,
  };
}

// True when a stage node's fields changed — a canonical (absence-insensitive) compare
// so a real edit flips it but a pure reorder (bpId only) or a null≡""≡absent flip does
// not. Mirrors stage-node.js:stageKey (kept in lockstep by construction).
function stageNodeChanged(prevNode, nextNode) {
  return stableStageKey(prevNode) !== stableStageKey(nextNode);
}

function stableStageKey(node) {
  const a = (node && node.attrs) || {};
  const s = (v) => (v == null || v === "" ? "" : String(v));
  return canonicalJSON({
    kind: s(a.kind),
    title: s(a.title),
    detail: s(a.detail),
    files: s(a.files),
    source: stageTruthy(a.source),
  });
}

// ── eyebrow / byline / ingress / pullquote ⇄ canvas role prose node ──────────
//
// The four article-chrome ROLE blocks ⇄ their same-named TipTap prose nodes. UNLIKE
// the callout (chrome + inline body) these are chrome-free styled prose, but their
// PERSIST shape differs by role — so the block ⇄ node body mapping dispatches on
// ROLE_BODY_MODEL:
//   text  (eyebrow)  — a PLAIN string in `text`. The node body is a single text run;
//     an empty string → a CONTENTLESS node (no `content` key) so an empty eyebrow's
//     getJSON re-projection matches (nodeText of a contentless node is "").
//   items (byline)   — an `items` LIST. The reader joins with " · "; the canvas shows
//     the JOINED display string as the node's text, and splits it back on "·" (the
//     BYTE-MIRROR of blocks.ex build_block_patch byline). A legacy text-only byline
//     (no `items`) falls back to its `text` on display and MIGRATES to items on first
//     save — the SAME behaviour the form has (its input value = items joined).
//   inline (ingress/pullquote) — an inline `content` array, via the SHARED
//     inlineArrayToTiptap / tiptapInlineToPd (the callout body path). Marks work.
//
// bpId/bpType ride node.attrs; node.type === bpType for all four (no NODE_NAME map).

// The concatenated text of a node's inline text children (an eyebrow/byline body is a
// single text run; a contentless node yields "").
function roleNodeText(node) {
  return ((node && node.content) || []).map((n) => n.text || "").join("");
}

// Split a byline display string into its items — the BYTE-MIRROR of blocks.ex:60-67
// build_block_patch byline: split on "·", trim each, drop the empties.
function splitBylineItems(s) {
  return String(s == null ? "" : s)
    .split("·")
    .map((x) => x.trim())
    .filter((x) => x !== "");
}

// The DISPLAY text a byline block shows in its node: the items joined with " · ", or
// (legacy) the plain `text` when there are no items. Mirrors the form input value.
function bylineDisplay(block) {
  const items = block && block.items;
  if (Array.isArray(items) && items.length) return items.join(" · ");
  return (block && block.text) || "";
}

// roleBlockToNode(block) → { type:<role>, attrs:{ bpId, bpType }, content?:[text|inline] }
//
// The body is built per ROLE_BODY_MODEL:
//   text  → a single text run of block.text (or a CONTENTLESS node when empty).
//   items → a single text run of the " · "-joined display (contentless when empty).
//   inline→ inlineArrayToTiptap(block.content) (the shared serializer; may be empty).
function roleBlockToNode(block, bpId, bpType) {
  const attrs = { bpId, bpType };
  // A quote's attribution rides on the node so a same-id replace keeps it; ops never patch it.
  if (bpType === "blockquote") {
    const cite = block && (block.cite ?? block.attribution);
    if (typeof cite === "string" && cite.trim() !== "") attrs.cite = cite;
  }
  const model = ROLE_BODY_MODEL[bpType];
  const node = { type: bpType, attrs };

  if (model === "inline") {
    const inline = inlineArrayToTiptap((block && block.content) || []);
    if (inline.length) node.content = inline;
    return node;
  }

  // text / items → a single text run of the display string (contentless when "").
  const text =
    model === "items" ? bylineDisplay(block) : (block && block.text) || "";
  if (text) node.content = [{ type: "text", text }];
  return node;
}

// roleNodeToBlock(node, id) → the reconstructed portable-doc role block. The inverse of
// roleBlockToNode, dispatched by ROLE_BODY_MODEL[node.type]:
//   text  → { id, type:"eyebrow", text:<nodeText> }
//   items → { id, type:"byline", items:splitBylineItems(<nodeText>) }
//   inline→ { id, type:<role>, content:tiptapInlineToPd(node.content) }
function roleNodeToBlock(node, id) {
  const bpType = (node && node.type) || "eyebrow";
  const model = ROLE_BODY_MODEL[bpType];
  if (model === "inline") {
    const block = {
      id,
      type: bpType,
      content: tiptapInlineToPd((node && node.content) || []),
    };
    const cite = node && node.attrs && node.attrs.cite;
    if (bpType === "blockquote" && typeof cite === "string" && cite !== "") block.cite = cite;
    return block;
  }
  if (model === "items") {
    return { id, type: bpType, items: splitBylineItems(roleNodeText(node)) };
  }
  return { id, type: bpType, text: roleNodeText(node) };
}

// The mutable-fields PATCH for a role block (the analogue of calloutNodeToPatch). It
// is roleNodeToBlock MINUS id/type — the shallow-merge fields patch.ex re-pins. Every
// role has exactly ONE mutable field (text / items / content), emitted UNCONDITIONALLY
// (simpler than the callout's removal-safe maybe_put — there is no optional field to
// drop), so a shallow merge always lands the current body.
function roleNodeToPatch(node) {
  const bpType = (node && node.type) || "eyebrow";
  const model = ROLE_BODY_MODEL[bpType];
  if (model === "inline") {
    return { content: tiptapInlineToPd((node && node.content) || []) };
  }
  if (model === "items") {
    return { items: splitBylineItems(roleNodeText(node)) };
  }
  return { text: roleNodeText(node) };
}

// True when a role node's body changed. We compare the canonical projection of the
// DERIVED stable body — for a byline the DERIVED `items` (NOT the raw " · " display
// string), so join/split is idempotent and an unedited byline emits ZERO ops. Uses the
// SAME canonicalJSON the prose/callout paths use, so a node from roleBlockToNode and the
// SAME node from getJSON compare EQUAL despite key-order differences.
function roleNodeChanged(prevNode, nextNode) {
  return stableRoleKey(prevNode) !== stableRoleKey(nextNode);
}

function stableRoleKey(node) {
  const bpType = (node && node.type) || "eyebrow";
  const model = ROLE_BODY_MODEL[bpType];
  if (model === "inline") {
    return canonicalJSON({ content: (node && node.content) || null });
  }
  if (model === "items") {
    return canonicalJSON({ items: splitBylineItems(roleNodeText(node)) });
  }
  return canonicalJSON({ text: roleNodeText(node) });
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
// the STALE old lang. A body-only edit must not create or normalize an untouched
// absent/null/empty language carrier, so emit the empty string only on clearing.
function codeNodeToPatch(node, prevNode) {
  const attrs = (node && node.attrs) || {};
  const lang = attrs.lang == null ? "" : attrs.lang;
  const previousLang = prevNode?.attrs?.lang ?? "";
  return {
    value: attrs.value || "",
    ...(lang !== "" || previousLang !== "" ? { lang } : {}),
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

// ── diff / filetree ⇄ canvas TECHNICAL attr-atom node ───────────────────────
//
// scaffy-backlog-blocks-editable-studio. The two VERBATIM-TEXT technical blocks
//   { id, type:"diff",     diff:"<text>", file?:"…", lang?:"…" }
//   { id, type:"filetree", text:"<text>", legend?:"…" }
// ⇄ the TipTap `bpDiff` / `bpFiletree` ATTR-ATOM nodes (technical-node.js). The
// shape is the code/diagram shape GENERALIZED: ONE verbatim-body attr (always
// projected, even "") plus N OPTIONAL scalar metadata attrs (present-only, so an
// absent value round-trips as ABSENT and a lossless no-op edit emits zero ops).
//
// node.type is the NODE name (bpDiff / bpFiletree), NOT the bpType (diff /
// filetree) — see the CANVAS_ATTR_ATOM_NODE_NAMES note.

// True for a TipTap node type that is one of the technical attr-atoms. Used to
// dispatch inside the isAttrAtom branches (which also serve bpCode / bpDiagram).
function isTechnicalAtomNode(type) {
  return type === "bpDiff" || type === "bpFiletree";
}

// The shape record for a technical NODE type (or undefined when it is not one).
function technicalShapeForNode(type) {
  const bpType = CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE[type];
  return bpType ? TECHNICAL_ATOM_SHAPES[bpType] : undefined;
}

// technicalBlockToNode(block) → { type:"bpDiff"|"bpFiletree", attrs:{ bpId, bpType,
//   <body>, <meta>? } }
//
// The verbatim TEXT → the body attr (default ""). Each metadata key rides ONLY when
// present + non-empty, so an untouched metadata-less block's getJSON re-projection
// matches and emits zero ops.
function technicalBlockToNode(block, bpId, bpType) {
  const shape = TECHNICAL_ATOM_SHAPES[bpType];
  const nodeName = CANVAS_ATTR_ATOM_NODE_NAMES[bpType];
  const attrs = { bpId, bpType };
  attrs[shape.body] = (block && block[shape.body]) || "";
  for (const key of shape.meta) {
    const value = block && block[key];
    if (value != null && value !== "") attrs[key] = value;
  }
  return { type: nodeName, attrs };
}

// technicalNodeToBlock(node, id) → { id, type, <body>, <meta>? }
//
// Reconstruct the portable-doc block from a technical NODE (the inverse of
// technicalBlockToNode). The body reads off the attr (default ""); each metadata key
// is threaded ONLY when present + non-empty, so the reconstructed block is
// byte-identical to a metadata-less round-trip (no stray file:"").
function technicalNodeToBlock(node, id) {
  const attrs = (node && node.attrs) || {};
  const shape = technicalShapeForNode(node && node.type);
  const bpType = CANVAS_ATTR_ATOM_BP_TYPE_BY_NODE[node && node.type];
  const block = { id, type: bpType };
  block[shape.body] = attrs[shape.body] || "";
  for (const key of shape.meta) {
    if (attrs[key] != null && attrs[key] !== "") block[key] = attrs[key];
  }
  return block;
}

// The mutable-fields PATCH for a technical block. The body ALWAYS rides the patch;
// each metadata key rides EXPLICITLY as a STRING ("" when cleared), NOT a dropped
// key. The canvas paper-ops path folds via Patch.apply_patches, where patch-block is
// a SHALLOW Map.merge (patch.ex merge_block) that can REPLACE or PRESERVE a key but
// never DELETE one — so clearing a previously-set `file` must emit file:"", or the
// merge would leave the STALE old value. "" is render-equivalent to absent
// (Components.diff_html / filetree_html treat a missing and an empty metadata string
// identically) and the canonical compare normalizes ""/null/absent equal, so the
// cleared block still round-trips with zero spurious ops. Mirrors diagramNodeToPatch.
//
// With the node the edit started from (prevNode), a metadata key rides only when its
// value CHANGED, so a body edit never materializes file:"" / lang:"" / legend:"" keys
// the author never wrote (the task-56bafb69a8a1f250 callout rule). A changed key is
// still explicit, so a clear still lands. Without prevNode every key rides.
function technicalNodeToPatch(node, prevNode = null) {
  const attrs = (node && node.attrs) || {};
  const prevAttrs = (prevNode && prevNode.attrs) || null;
  const shape = technicalShapeForNode(node && node.type);
  const patch = {};
  patch[shape.body] = attrs[shape.body] || "";
  for (const key of shape.meta) {
    const value = attrs[key] == null ? "" : attrs[key];
    if (prevAttrs && (prevAttrs[key] == null ? "" : prevAttrs[key]) === value) continue;
    patch[key] = value;
  }
  return patch;
}

// True when a technical node's body OR any metadata field changed (an attr edit).
// Canonical (key-order-insensitive) compare of the diff-relevant fields only, so a
// body edit or a metadata change flips it but a pure reorder (bpId/bpType only) does
// not. An absent metadata value normalizes to "" so a metadata-less node and one
// carrying ""/null compare EQUAL (they persist render-identically).
function technicalNodeChanged(prevNode, nextNode) {
  return stableTechnicalKey(prevNode) !== stableTechnicalKey(nextNode);
}

function stableTechnicalKey(node) {
  const attrs = (node && node.attrs) || {};
  const shape = technicalShapeForNode(node && node.type);
  if (!shape) return canonicalJSON(null);
  const key = { body: attrs[shape.body] || "" };
  for (const name of shape.meta) {
    key[name] = attrs[name] == null ? "" : attrs[name];
  }
  return canonicalJSON(key);
}

export {
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
};
