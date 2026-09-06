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
  const content = rawContent == null ? [] : rawContent;
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
