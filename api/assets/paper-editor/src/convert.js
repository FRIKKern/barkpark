// convert.js — pure converters between Barkpark portable-doc blocks and TipTap
// document JSON. NO DOM, NO TipTap imports here so the smoke test can import
// and round-trip these in plain Node.
//
// Exact shapes (verified against api/lib/barkpark/portable_doc/render.ex,
// patch.ex, and the golden fixtures in test/support/fixtures/doc-patch-op/):
//
//   heading   : { id, type:"heading", level:1..3, text:"..." }   (flat string)
//   paragraph : { id, type:"paragraph", content:[ inline... ] }
//   list      : { id, type:"list", ordered:bool, items:[ [inline...], ... ] }
//
//   inline tree (recursive):
//     { type:"text",   value:"..." }                 leaf
//     { type:"strong", children:[ inline... ] }
//     { type:"em",     children:[ inline... ] }
//     { type:"code",   value:"..." }                 leaf (inline code)
//     { type:"link",   href:"...", children:[ inline... ] }
//     { type:"valueref", target:"<doc_id slug>", field:"<top-level field>",
//       as?, fallback?, label?, children?:[ inline... ] }   leaf (live value)
//
// TipTap/ProseMirror inline model is flat: a text node with a marks[] array
// ({type:"bold"|"italic"|"strike"|"code"|"link"}). We translate between the
// nested portable-doc tree and the flat TipTap marks on the way in and out.

// ── portable-doc inline tree  →  flat TipTap text nodes ────────────────────

// Walk one portable-doc inline node, accumulating active marks, and push the
// resulting flat TipTap text nodes into `out`.
function inlineToTiptapNodes(node, marks, out) {
  if (!node || typeof node !== "object") return;

  switch (node.type) {
    case "text": {
      const text = node.value || "";
      if (text.length === 0) return;
      const tnode = { type: "text", text };
      if (marks.length) tnode.marks = marks.map((m) => ({ ...m }));
      out.push(tnode);
      return;
    }
    case "code": {
      // inline code is a leaf in portable-doc; in TipTap it is a `code` mark.
      const text = node.value || "";
      if (text.length === 0) return;
      out.push({ type: "text", text, marks: [...marks, { type: "code" }] });
      return;
    }
    case "strong": {
      const next = [...marks, { type: "bold" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "em": {
      const next = [...marks, { type: "italic" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "strikethrough": {
      const next = [...marks, { type: "strike" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "underline": {
      const next = [...marks, { type: "underline" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "link": {
      const next = [...marks, { type: "link", attrs: { href: node.href || "" } }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "wikilink": {
      // Wrapper, link-shaped. `target` is UNRESOLVED (slug/title); `alias` is
      // optional ([[target|alias]]). Children carry the rendered label text.
      const attrs = { target: node.target || "" };
      if (node.alias != null) attrs.alias = node.alias;
      if (node.docId != null) attrs.docId = node.docId;
      const next = [...marks, { type: "wikilink", attrs }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "blockref": {
      // Leaf — the visible text is the `^anchor` token; target/anchor ride the
      // mark attrs (read back from attrs, not text, on the return trip).
      out.push({
        type: "text",
        text: "^" + (node.anchor || ""),
        marks: [
          ...marks,
          { type: "blockref", attrs: { target: node.target || "", anchor: node.anchor || "" } },
        ],
      });
      return;
    }
    case "tag": {
      // Leaf — the visible text is the `#name` token; name rides the mark attrs.
      out.push({
        type: "text",
        text: "#" + (node.name || ""),
        marks: [...marks, { type: "tag", attrs: { name: node.name || "" } }],
      });
      return;
    }
    case "valueref": {
      // Leaf — an inline live value (wire contract: the
      // portabledoc-inline-liveref-taskchip-wire paper, §3). The visible text is
      // DISPLAY-ONLY: the D6 dual-written fallback child's plain text, else the
      // `fallback` literal, else an inert `{target.field}` token — always
      // NON-EMPTY so the node can never drop as a zero-length text run. EVERY
      // wire field rides the mark attrs and is read back from attrs, never from
      // the text, on the return trip: target/field always; as/fallback/label/
      // children ONLY when present (a stray `as:undefined` would fail the
      // byte-exact round-trip). `as` and `label` are RESERVED passthrough —
      // round-trip opaquely, NEVER interpreted. `children` (the D6 fallback
      // subtree) is carried VERBATIM (deep-cloned, no shared refs) so it
      // round-trips unchanged even if the display run is retouched.
      const attrs = { target: node.target || "", field: node.field || "" };
      if (node.as != null) attrs.as = node.as;
      if (node.fallback != null) attrs.fallback = node.fallback;
      if (node.label != null) attrs.label = node.label;
      if (node.children != null) attrs.children = deepCloneJson(node.children);
      out.push({
        type: "text",
        text: valuerefDisplayText(node),
        marks: [...marks, { type: "valueref", attrs }],
      });
      return;
    }
    default:
      // Unknown inline type: render its children if any, else drop.
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, marks, out));
      return;
  }
}

// Coerce ONE list item into a canonical inline ARRAY. The canonical `list` block
// stores each item as an inline array (`items:[ [inline...], ... ]`, see :10), but
// 7 legacy papers (webhook-*/qstash-*/ga4-* specs) store a flat STRING per item
// (`items:["text one", ...]`). A flat string reaching `inlineArrayToTiptap` would
// run `.forEach` on a string and THROW ("forEach is not a function") — crashing
// BOTH editors (per-block + canvas) the moment such a paper opens. This coerces a
// string (or any non-array) item to a single text inline node, matching how the
// VIEW render already tolerates it (compose.ex `compose_inline_children(str) → [str]`
// renders byte-identically to the inline-text-array form). ADDITIVE: a canonical
// inline-ARRAY item is returned UNCHANGED (the byte-identical fast path); only a
// non-array item is coerced.
function listItemToInlineArray(item) {
  if (Array.isArray(item)) return item;
  if (typeof item === "string") return [{ type: "text", value: item }];
  // Any other non-array scalar (number, etc.) → its string form as one text node;
  // null/undefined → an empty item (an empty `<li>`), never a throw.
  if (item == null) return [];
  return [{ type: "text", value: String(item) }];
}

// portable-doc inline array → flat TipTap inline content array.
//
// Exported so the canvas (run-convert.js) reuses the SAME inline serializer the
// per-block paragraph path uses — a callout body is INLINE runs (compose.ex:155
// feeds callout `content` through compose_inline_children), so its body↔TipTap
// mapping MUST be byte-identical to a paragraph's. Do NOT reinvent it downstream.
//
// Crash-defensive (mirrors compose_inline_children's binary tolerance): a flat
// STRING where an inline ARRAY was expected — a legacy flat-string list item — is
// coerced to a single text inline node instead of throwing on `.forEach`. The
// canonical inline-ARRAY path is byte-unchanged; only a non-array input is coerced.
export function inlineArrayToTiptap(inline) {
  const arr = Array.isArray(inline) ? inline : listItemToInlineArray(inline);
  const out = [];
  arr.forEach((node) => inlineToTiptapNodes(node, [], out));
  return out;
}

// ── flat TipTap text nodes  →  portable-doc inline tree ────────────────────

// Mark priority controls nesting order when a run carries multiple marks.
// Outer-most first. link/wikilink are the outermost wrappers; strong/em/
// underline/strikethrough nest inside; code/blockref/tag/valueref are
// value-LEAVES (the node IS the leaf — see LEAF_KINDS). This order MUST stay
// aligned with inline.ex's right-to-left apply_marks fold or round-trips lose
// idempotency.
const MARK_ORDER = [
  "link",
  "wikilink",
  "strong",
  "em",
  "underline",
  "strikethrough",
  "code",
  "blockref",
  "tag",
  "valueref",
];

// Map a TipTap mark to a portable-doc wrapper descriptor.
function markToPd(mark) {
  switch (mark.type) {
    case "bold":
      return { kind: "strong" };
    case "italic":
      return { kind: "em" };
    case "code":
      return { kind: "code" };
    case "strike":
      return { kind: "strikethrough" };
    case "underline":
      return { kind: "underline" };
    case "link":
      return { kind: "link", href: (mark.attrs && mark.attrs.href) || "" };
    case "wikilink": {
      const w = { kind: "wikilink", target: (mark.attrs && mark.attrs.target) || "" };
      // Only carry `alias` when present — a stray `alias:undefined` would fail
      // the byte-exact round-trip for a plain (no-alias) wikilink.
      if (mark.attrs && mark.attrs.alias != null) w.alias = mark.attrs.alias;
      // Likewise the pinned `docId` (picked-paper id) only when present — a
      // typed-not-picked wikilink has none and must round-trip byte-identically.
      if (mark.attrs && mark.attrs.docId != null) w.docId = mark.attrs.docId;
      return w;
    }
    case "blockref":
      return {
        kind: "blockref",
        target: (mark.attrs && mark.attrs.target) || "",
        anchor: (mark.attrs && mark.attrs.anchor) || "",
      };
    case "tag":
      return { kind: "tag", name: (mark.attrs && mark.attrs.name) || "" };
    case "valueref": {
      // Leaf descriptor. target/field always; as/fallback/label/children ONLY
      // when present (mirrors the wikilink alias/docId guard — a stray
      // `as:undefined`/`children:null` would fail the byte-exact round-trip;
      // TipTap's live getJSON echoes absent attrs as null, so `!= null` filters
      // both). as/label/children are opaque passthrough — never interpreted.
      const a = mark.attrs || {};
      const v = { kind: "valueref", target: a.target || "", field: a.field || "" };
      if (a.as != null) v.as = a.as;
      if (a.fallback != null) v.fallback = a.fallback;
      if (a.label != null) v.label = a.label;
      if (a.children != null) v.children = a.children;
      return v;
    }
    default:
      return null; // unknown marks: no portable-doc node, unwrap silently
  }
}

// Value-LEAF marks: the node IS the leaf, not a wrapper. `code` takes its value
// from the text; `blockref`/`tag`/`valueref` take theirs from the mark attrs
// (the visible text is just the `^anchor`/`#name`/fallback display token). At
// most one per run.
const LEAF_KINDS = ["code", "blockref", "tag", "valueref"];

// Build a portable-doc inline subtree for one flat TipTap text node: pick the
// value-leaf (if any), then wrap the remaining marks from inner to outer.
function tiptapTextNodeToPd(tnode) {
  const text = tnode.text || "";
  // Collect wrappers, ordered outer→inner per MARK_ORDER.
  const wrappers = [];
  (tnode.marks || []).forEach((m) => {
    const w = markToPd(m);
    if (w) wrappers.push(w);
  });
  wrappers.sort(
    (a, b) =>
      MARK_ORDER.indexOf(pdKindToMark(a.kind)) -
      MARK_ORDER.indexOf(pdKindToMark(b.kind)),
  );

  const leaf = wrappers.find((w) => LEAF_KINDS.includes(w.kind));
  const nestW = wrappers.filter((w) => !LEAF_KINDS.includes(w.kind));

  let node = leafNode(leaf, text);

  // Wrap from inner-most non-leaf mark outward.
  for (let i = nestW.length - 1; i >= 0; i--) {
    const w = nestW[i];
    if (w.kind === "link") {
      node = { type: "link", href: w.href, children: [node] };
    } else if (w.kind === "wikilink") {
      node = { type: "wikilink", target: w.target, children: [node] };
      if (w.alias != null) node.alias = w.alias;
      if (w.docId != null) node.docId = w.docId;
    } else {
      node = { type: w.kind, children: [node] };
    }
  }
  return node;
}

// The value-leaf node for a flat text run: `code` → value from text; `blockref`
// /`tag` → fields from the mark descriptor; none → a plain text leaf.
function leafNode(leaf, text) {
  if (!leaf) return { type: "text", value: text };
  if (leaf.kind === "code") return { type: "code", value: text };
  if (leaf.kind === "blockref") {
    return { type: "blockref", target: leaf.target, anchor: leaf.anchor };
  }
  if (leaf.kind === "tag") return { type: "tag", name: leaf.name };
  if (leaf.kind === "valueref") {
    // Rebuilt ENTIRELY from the mark descriptor — the visible text is
    // display-only and is DISCARDED (the value is resolver-owned; children are
    // the D6 authoring-time fallback subtree, carried verbatim). Optional keys
    // thread ONLY when present so the node round-trips byte-exactly.
    const node = { type: "valueref", target: leaf.target, field: leaf.field };
    if (leaf.as != null) node.as = leaf.as;
    if (leaf.fallback != null) node.fallback = leaf.fallback;
    if (leaf.label != null) node.label = leaf.label;
    if (leaf.children != null) node.children = deepCloneJson(leaf.children);
    return node;
  }
  return { type: "text", value: text };
}

function pdKindToMark(kind) {
  if (kind === "strong") return "strong";
  if (kind === "em") return "em";
  if (kind === "underline") return "underline";
  if (kind === "strikethrough") return "strikethrough";
  if (kind === "link") return "link";
  if (kind === "wikilink") return "wikilink";
  if (kind === "code") return "code";
  if (kind === "blockref") return "blockref";
  if (kind === "tag") return "tag";
  if (kind === "valueref") return "valueref";
  return kind;
}

// flat TipTap inline content array → portable-doc inline array.
//
// Exported (with inlineArrayToTiptap above) so the canvas callout body reuses the
// SAME inline deserializer the per-block paragraph path uses — the callout body
// round-trips through these two, never a reinvented inline serializer.
export function tiptapInlineToPd(content) {
  return (content || [])
    .filter((n) => n.type === "text")
    .map(tiptapTextNodeToPd);
}

// ── block ⇄ TipTap document ────────────────────────────────────────────────

// blockToTiptap(block) → a TipTap top-level document JSON ({type:"doc",content:[...]})
// holding the single block's content node, ready for editor.commands.setContent.
export function blockToTiptap(block) {
  if (!block || typeof block !== "object") {
    return { type: "doc", content: [{ type: "paragraph" }] };
  }

  switch (block.type) {
    case "heading": {
      const level = clampLevel(block.level);
      const text = block.text || "";
      const node = { type: "heading", attrs: { level } };
      if (text.length) node.content = [{ type: "text", text }];
      return { type: "doc", content: [node] };
    }
    case "list": {
      const ordered = block.ordered === true;
      // Coerce each item to a canonical inline ARRAY first (legacy flat-string
      // items → a single text inline node) so neither editor throws on a string
      // item. A canonical inline-array item is passed through UNCHANGED.
      const items = (block.items || []).map((itemInline) => ({
        type: "listItem",
        content: [
          {
            type: "paragraph",
            content: inlineArrayToTiptap(listItemToInlineArray(itemInline)),
          },
        ],
      }));
      const listNode = {
        type: ordered ? "orderedList" : "bulletList",
        content: items.length
          ? items
          : [{ type: "listItem", content: [{ type: "paragraph" }] }],
      };
      return { type: "doc", content: [listNode] };
    }
    case "paragraph":
    default: {
      const node = { type: "paragraph" };
      const inline = inlineArrayToTiptap(block.content);
      if (inline.length) node.content = inline;
      return { type: "doc", content: [node] };
    }
  }
}

function jsonEqual(left, right) {
  if (left === right) return true;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right) &&
      left.length === right.length && left.every((value, index) => jsonEqual(value, right[index]));
  }
  if (!left || !right || typeof left !== "object" || typeof right !== "object") return false;
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length &&
    leftKeys.every((key, index) => key === rightKeys[index] && jsonEqual(left[key], right[key]));
}

function deepClone(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function canonicalEmptyCardBody(content) {
  if (!Array.isArray(content) || content.length !== 1) return false;
  const node = content[0];
  if (!node || typeof node !== "object" || Array.isArray(node)) return false;
  const keys = Object.keys(node).sort();
  return keys.length === 2 && keys[0] === "type" && keys[1] === "value" &&
    node.type === "text" && node.value === "";
}

// Strict projection for the Card contextual editor's explicit BODY mode.
// This deliberately does not make Card an ordinary per-block prose type:
// callers must opt into this projection and preserve the full Card separately.
export function cardBodyProjection(card) {
  const emptyDoc = { type: "doc", content: [{ type: "paragraph" }] };
  if (!card || typeof card !== "object" || Array.isArray(card) || card.type !== "card") {
    return { editable: false, content: [], doc: emptyDoc };
  }
  const slots = card.slots;
  if (!(slots == null || (typeof slots === "object" && !Array.isArray(slots)))) {
    return { editable: false, content: [], doc: emptyDoc };
  }
  const body = slots == null ? undefined : slots.body;
  let paragraph = null;
  if (!(body == null || (Array.isArray(body) && body.length === 0))) {
    if (!Array.isArray(body) || body.length !== 1) {
      return { editable: false, content: [], doc: emptyDoc };
    }
    paragraph = body[0];
    if (!paragraph || typeof paragraph !== "object" || Array.isArray(paragraph) || paragraph.type !== "paragraph") {
      return { editable: false, content: [], doc: emptyDoc };
    }
  }
  const rawContent = paragraph == null ? undefined : paragraph.content;
  if (!(rawContent == null || Array.isArray(rawContent))) {
    return { editable: false, content: [], doc: emptyDoc };
  }
  const content = rawContent == null || canonicalEmptyCardBody(rawContent) ? [] : rawContent;
  let tiptapInline;
  try {
    tiptapInline = inlineArrayToTiptap(content);
  } catch (_error) {
    return { editable: false, content: [], doc: emptyDoc };
  }
  if (!jsonEqual(tiptapInlineToPd(tiptapInline), content)) {
    return { editable: false, content: [], doc: emptyDoc };
  }
  const node = { type: "paragraph" };
  if (tiptapInline.length) node.content = tiptapInline;
  return { editable: true, content: deepClone(content), doc: { type: "doc", content: [node] } };
}

export function cardBodyTiptapDocSupported(editorJSON) {
  const content = editorJSON && editorJSON.content;
  if (!Array.isArray(content) || content.length !== 1 || content[0].type !== "paragraph") return false;
  const inline = content[0].content || [];
  return jsonEqual(inlineArrayToTiptap(tiptapInlineToPd(inline)), inline);
}

export function cardBodyContentMatches(content, sourceCard) {
  const projection = cardBodyProjection(sourceCard);
  return projection.editable && jsonEqual(content, projection.content);
}

export function buildCardBodyOp(editorJSON, sourceCard, force = false) {
  const projection = cardBodyProjection(sourceCard);
  if (!projection.editable || !cardBodyTiptapDocSupported(editorJSON)) return null;
  const nextContent = tiptapInlineToPd(editorJSON.content[0].content || []);
  if (!force && jsonEqual(nextContent, projection.content)) return null;

  // This is intentionally not patch-block{slots}: slots are a shallow Patch
  // field, so sending a captured map could overwrite concurrent Card chrome.
  // The server resolves this intent against the authoritative Card and changes
  // only its body paragraph's content.
  return { op: "patch-card-body", id: sourceCard.id, content: nextContent };
}

function tableInlineToTiptap(inline) {
  if (!Array.isArray(inline)) return null;
  try {
    const projected = inlineArrayToTiptap(inline);
    return jsonEqual(tiptapInlineToPd(projected), inline) ? projected : null;
  } catch (_error) {
    return null;
  }
}

function tableRowToTiptap(cells, header) {
  if (!Array.isArray(cells) || cells.length === 0) return null;
  const projected = cells.map(tableInlineToTiptap);
  if (projected.some((inline) => inline == null)) return null;
  return {
    type: "bpTableRow",
    content: projected.map((inline) => ({
      type: header ? "bpTableHeaderCell" : "bpTableCell",
      ...(inline.length ? { content: inline } : {}),
    })),
  };
}

function exactObjectKeys(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const keys = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return keys.length === wanted.length && keys.every((key, index) => key === wanted[index]);
}

function validTableRowShape(shape, width, header = false) {
  return exactObjectKeys(shape, ["kind", "cells"]) &&
    (header ? shape.kind === "array" : ["array", "cells-map"].includes(shape.kind)) &&
    Array.isArray(shape.cells) && shape.cells.length === width &&
    shape.cells.every((kind) => ["inline-array", "content-map"].includes(kind));
}

function validTableShape(shape, head, rows, width) {
  if (!exactObjectKeys(shape, ["v", "head", "rows"]) || shape.v !== 1 ||
      !Array.isArray(shape.rows) || shape.rows.length !== rows.length ||
      !shape.rows.every((row) => validTableRowShape(row, width))) return false;
  const headShape = shape.head;
  if (!headShape || typeof headShape !== "object" || Array.isArray(headShape)) return false;
  if (head === null) {
    return exactObjectKeys(headShape, ["state"]) &&
      ["absent", "null", "empty"].includes(headShape.state);
  }
  return exactObjectKeys(headShape, ["state", "row"]) && headShape.state === "row" &&
    validTableRowShape(headShape.row, width, true);
}

const TABLE_MARKS = new Set([
  "bold", "italic", "underline", "strike", "code", "link", "wikilink",
  "blockref", "tag", "valueref",
]);

function tableAttrsHaveOnly(attrs, allowed) {
  return attrs && typeof attrs === "object" && !Array.isArray(attrs) &&
    Object.keys(attrs).every((key) => allowed.includes(key));
}

function validTableMark(mark) {
  if (!mark || typeof mark !== "object" || Array.isArray(mark) ||
      !TABLE_MARKS.has(mark.type)) return false;
  if (["bold", "italic", "underline", "strike", "code"].includes(mark.type)) {
    return exactObjectKeys(mark, ["type"]);
  }
  if (!exactObjectKeys(mark, ["type", "attrs"])) return false;
  const attrs = mark.attrs;
  if (mark.type === "link") {
    if (!tableAttrsHaveOnly(attrs, ["href", "target", "rel", "class"]) ||
        typeof attrs.href !== "string") return false;
    const keys = Object.keys(attrs).sort();
    return jsonEqual(keys, ["href"]) ||
      (jsonEqual(keys, ["class", "href", "rel", "target"]) &&
        attrs.target === "_blank" && attrs.rel === "noopener noreferrer nofollow" &&
        attrs.class === null);
  }
  if (mark.type === "wikilink") {
    return tableAttrsHaveOnly(attrs, ["target", "alias", "docId"]) &&
      typeof attrs.target === "string";
  }
  if (mark.type === "blockref") {
    return exactObjectKeys(attrs, ["target", "anchor"]) &&
      typeof attrs.target === "string" && typeof attrs.anchor === "string";
  }
  if (mark.type === "tag") {
    return exactObjectKeys(attrs, ["name"]) && typeof attrs.name === "string";
  }
  return tableAttrsHaveOnly(attrs, ["target", "field", "as", "fallback", "label", "children"]) &&
    typeof attrs.target === "string" && typeof attrs.field === "string";
}

function tableTiptapInlineEqual(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false;
  const valid = left.every((node, index) => {
    const other = right[index];
    const keys = node?.marks == null ? ["type", "text"] : ["type", "text", "marks"];
    const otherKeys = other?.marks == null ? ["type", "text"] : ["type", "text", "marks"];
    if (!exactObjectKeys(node, keys) || !exactObjectKeys(other, otherKeys) ||
        node.type !== "text" || other.type !== "text" || node.text !== other.text) return false;
    const marks = Array.isArray(node.marks) ? node.marks : [];
    const otherMarks = Array.isArray(other.marks) ? other.marks : [];
    const markTypes = marks.map((mark) => mark?.type);
    const otherMarkTypes = otherMarks.map((mark) => mark?.type);
    const unique = new Set(markTypes);
    const otherUnique = new Set(otherMarkTypes);
    const leaves = markTypes.filter((type) => ["code", "blockref", "tag", "valueref"].includes(type));
    const otherLeaves = otherMarkTypes.filter((type) =>
      ["code", "blockref", "tag", "valueref"].includes(type));
    return marks.every(validTableMark) && otherMarks.every(validTableMark) &&
      unique.size === markTypes.length && otherUnique.size === otherMarkTypes.length &&
      leaves.length <= 1 && otherLeaves.length <= 1;
  });
  return valid && jsonEqual(tiptapInlineToPd(left), tiptapInlineToPd(right));
}

// The server owns the lossless storage lens. This client accepts only its
// JSON-safe projection envelope; raw carrier maps never enter ProseMirror.
export function tableProjection(projection) {
  const emptyDoc = { type: "doc", content: [{ type: "paragraph" }] };
  if (!projection || typeof projection !== "object" || Array.isArray(projection) ||
      projection.type !== "table" || typeof projection.id !== "string" ||
      projection.id.trim() !== projection.id || projection.id === "" ||
      !projection.shape || typeof projection.shape !== "object" ||
      Array.isArray(projection.shape) || !Array.isArray(projection.rows) ||
      projection.rows.length === 0 || !Object.prototype.hasOwnProperty.call(projection, "head")) {
    return { editable: false, shape: null, head: null, rows: [], doc: emptyDoc };
  }
  const body = projection.rows.map((row) => tableRowToTiptap(row, false));
  const width = projection.rows[0]?.length;
  const head = projection.head == null ? null : tableRowToTiptap(projection.head, true);
  if (!Number.isSafeInteger(width) || width < 1 || body.some((row, index) =>
    row == null || projection.rows[index].length !== width) ||
    (projection.head != null && (head == null || projection.head.length !== width)) ||
    !validTableShape(projection.shape, projection.head, projection.rows, width)) {
    return { editable: false, shape: null, head: null, rows: [], doc: emptyDoc };
  }
  const rows = head ? [head, ...body] : body;
  return {
    editable: true,
    shape: deepClone(projection.shape),
    head: deepClone(projection.head),
    rows: deepClone(projection.rows),
    doc: {
      type: "doc",
      content: [{
        type: "bpTable",
        attrs: { bpId: projection.id, bpType: "table" },
        content: rows,
      }],
    },
  };
}

function tableCellRows(editorJSON, projection) {
  const source = tableProjection(projection);
  const nodes = editorJSON?.content;
  if (!source.editable || !Array.isArray(nodes) || nodes.length !== 1 ||
      nodes[0]?.type !== "bpTable" || nodes[0]?.attrs?.bpId !== projection.id ||
      !Array.isArray(nodes[0].content)) return null;
  const liveRows = nodes[0].content;
  const hasHead = source.head != null;
  if (liveRows.length !== source.rows.length + (hasHead ? 1 : 0)) return null;
  const readRow = (row, header) => {
    if (row?.type !== "bpTableRow" || !Array.isArray(row.content) ||
        row.content.length !== source.rows[0].length) return null;
    const expectedType = header ? "bpTableHeaderCell" : "bpTableCell";
    const cells = row.content.map((cell) => {
      if (cell?.type !== expectedType) return null;
      const inline = cell.content || [];
      if (!Array.isArray(inline)) return null;
      try {
        if (!tableTiptapInlineEqual(inlineArrayToTiptap(tiptapInlineToPd(inline)), inline)) {
          return null;
        }
      } catch (_error) {
        return null;
      }
      return tiptapInlineToPd(inline);
    });
    return cells.some((cell) => cell == null) ? null : cells;
  };
  let offset = 0;
  const head = hasHead ? readRow(liveRows[offset++], true) : null;
  const rows = liveRows.slice(offset).map((row) => readRow(row, false));
  return (hasHead && head == null) || rows.some((row) => row == null)
    ? null
    : { source, head, rows };
}

export function tableTiptapDocSupported(editorJSON, projection) {
  return tableCellRows(editorJSON, projection) != null;
}

function tableCellKey(area, row, column) {
  return `${area}:${row}:${column}`;
}

export function buildTableCellsOp(editorJSON, projection, forceCells = []) {
  const current = tableCellRows(editorJSON, projection);
  if (!current) return null;
  const forced = new Set((Array.isArray(forceCells) ? forceCells : []).map((cell) =>
    tableCellKey(cell?.area, cell?.row, cell?.column)));
  const cells = [];
  if (current.head) current.head.forEach((content, column) => {
    if (forced.has(tableCellKey("head", 0, column)) ||
        !jsonEqual(content, current.source.head[column])) {
      cells.push({ area: "head", row: 0, column, content });
    }
  });
  current.rows.forEach((row, rowIndex) => row.forEach((content, column) => {
    if (forced.has(tableCellKey("body", rowIndex, column)) ||
        !jsonEqual(content, current.source.rows[rowIndex][column])) {
      cells.push({ area: "body", row: rowIndex, column, content });
    }
  }));
  if (!cells.length) return null;
  return {
    op: "patch-table-cells",
    id: projection.id,
    shape: deepClone(current.source.shape),
    cells,
  };
}

export function tableProjectionMatchesCells(projection, cells) {
  const source = tableProjection(projection);
  if (!source.editable || !Array.isArray(cells)) return false;
  return cells.every(({ area, row, column, content }) => {
    const actual = area === "head" && row === 0
      ? source.head?.[column]
      : area === "body" ? source.rows?.[row]?.[column] : undefined;
    return actual !== undefined && jsonEqual(actual, content);
  });
}

export function tableProjectionMatchesAction(before, after, action) {
  const source = tableProjection(before);
  const target = tableProjection(after);
  if (!source.editable || !target.editable || typeof action !== "string") return false;
  const expected = {
    shape: deepClone(source.shape),
    head: deepClone(source.head),
    rows: deepClone(source.rows),
  };
  const shapeRows = expected.shape?.rows;
  const shapeHead = expected.shape?.head;
  if (!Array.isArray(shapeRows) || !shapeHead || typeof shapeHead !== "object") return false;
  const swap = (items, left, right) => {
    [items[left], items[right]] = [items[right], items[left]];
  };
  const indexed = /^(remove|up|down)-row:(0|[1-9]\d*)$/.exec(action);
  const column = /^(remove|left|right)-column:(0|[1-9]\d*)$/.exec(action);
  if (action === "add-row") {
    expected.rows.push(Array(expected.rows[0].length).fill([]));
    shapeRows.push({ kind: "array", cells: Array(expected.rows[0].length).fill("inline-array") });
  } else if (action === "add-column") {
    expected.rows.forEach((row) => row.push([]));
    shapeRows.forEach((row) => row?.cells?.push("inline-array"));
    if (expected.head) {
      expected.head.push([]);
      shapeHead.row?.cells?.push("inline-array");
    }
  } else if (action === "add-header") {
    expected.head = Array(expected.rows[0].length).fill([]);
    expected.shape.head = {
      state: "row",
      row: { kind: "array", cells: Array(expected.rows[0].length).fill("inline-array") },
    };
  } else if (action === "remove-header") {
    expected.head = null;
    expected.shape.head = { state: "empty" };
  } else if (indexed) {
    const index = Number(indexed[2]);
    if (indexed[1] === "remove") {
      expected.rows.splice(index, 1);
      shapeRows.splice(index, 1);
    } else {
      const other = indexed[1] === "up" ? index - 1 : index + 1;
      swap(expected.rows, index, other);
      swap(shapeRows, index, other);
    }
  } else if (column) {
    const index = Number(column[2]);
    const editRow = (row) => {
      if (column[1] === "remove") row.splice(index, 1);
      else swap(row, index, column[1] === "left" ? index - 1 : index + 1);
    };
    expected.rows.forEach(editRow);
    shapeRows.forEach((row) => editRow(row.cells));
    if (expected.head) {
      editRow(expected.head);
      editRow(expected.shape.head.row.cells);
    }
  } else {
    return false;
  }
  return jsonEqual(expected.shape, target.shape) && jsonEqual(expected.head, target.head) &&
    jsonEqual(expected.rows, target.rows);
}

// tiptapToBlock(editorJSON, blockId, blockType) → portable-doc patch fields for
// the block, in the EXACT shape patch-block's `patch` map expects.
//
// Returns ONLY the mutable fields (NOT id/type — patch.ex re-pins those):
//   heading   → { text, level }
//   paragraph → { content: [inline...] }
//   list      → { ordered, items: [[inline...], ...] }
export function tiptapToBlock(editorJSON, blockId, blockType) {
  const doc = editorJSON || {};
  const top = (doc.content && doc.content[0]) || {};

  switch (blockType) {
    case "heading": {
      const level = clampLevel(top.attrs && top.attrs.level);
      const text = plainText(top.content);
      return { text, level };
    }
    case "list": {
      const ordered = top.type === "orderedList";
      const items = (top.content || []).map((li) => {
        const para = (li.content || []).find((c) => c.type === "paragraph") || {};
        return tiptapInlineToPd(para.content);
      });
      return { ordered, items };
    }
    case "paragraph":
    default: {
      return { content: tiptapInlineToPd(top.content) };
    }
  }
}

// Build a complete portable-doc block (id + type + patch fields) — used by the
// smoke round-trip and any caller that wants a full block back.
export function tiptapToFullBlock(editorJSON, blockId, blockType) {
  return { id: blockId, type: blockType, ...tiptapToBlock(editorJSON, blockId, blockType) };
}

// Build the on-the-wire patch-block op. Matches patch.ex / content.ex exactly:
//   { op: "patch-block", id, patch: { ...mutable fields } }
export function buildPatchBlockOp(editorJSON, blockId, blockType) {
  return {
    op: "patch-block",
    id: blockId,
    patch: tiptapToBlock(editorJSON, blockId, blockType),
  };
}

// ── helpers ────────────────────────────────────────────────────────────────

function clampLevel(level) {
  const n = Number(level);
  if (!Number.isFinite(n)) return 1;
  if (n < 1) return 1;
  if (n > 3) return 3;
  return Math.trunc(n);
}

// Concatenate the plain text of a flat TipTap inline content array — headings
// carry a flat string in portable-doc, so marks are dropped here by design.
function plainText(content) {
  return (content || [])
    .filter((n) => n.type === "text")
    .map((n) => n.text || "")
    .join("");
}

// The valueref's DISPLAY token: the plain text of its D6 dual-written fallback
// children, else the `fallback` literal, else an inert `{target.field}` token.
// GUARANTEED non-empty — inlineToTiptapNodes drops zero-length text runs, and a
// dropped display run would delete the valueref itself.
function valuerefDisplayText(node) {
  const fromChildren = inlinePlainText(node.children || []);
  if (fromChildren.length) return fromChildren;
  const fallback = node.fallback || "";
  if (fallback.length) return fallback;
  return "{" + (node.target || "") + "." + (node.field || "") + "}";
}

// Plain text of a portable-doc INLINE TREE (recursive; text/code values +
// wrapper children). Display-only — never used to reconstruct wire data.
function inlinePlainText(inline) {
  return (Array.isArray(inline) ? inline : [])
    .map((n) => {
      if (!n || typeof n !== "object") return "";
      if (n.type === "text" || n.type === "code") return n.value || "";
      return inlinePlainText(n.children);
    })
    .join("");
}

// Structural deep clone for opaque carried JSON (the valueref children
// subtree) — no shared refs between the portable-doc node and the mark attrs.
function deepCloneJson(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}
