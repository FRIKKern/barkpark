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
    default:
      // Unknown inline type: render its children if any, else drop.
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, marks, out));
      return;
  }
}

// portable-doc inline array → flat TipTap inline content array.
//
// Exported so the canvas (run-convert.js) reuses the SAME inline serializer the
// per-block paragraph path uses — a callout body is INLINE runs (compose.ex:155
// feeds callout `content` through compose_inline_children), so its body↔TipTap
// mapping MUST be byte-identical to a paragraph's. Do NOT reinvent it downstream.
export function inlineArrayToTiptap(inline) {
  const out = [];
  (inline || []).forEach((node) => inlineToTiptapNodes(node, [], out));
  return out;
}

// ── flat TipTap text nodes  →  portable-doc inline tree ────────────────────

// Mark priority controls nesting order when a run carries multiple marks.
// Outer-most first. link/wikilink are the outermost wrappers; strong/em/
// underline/strikethrough nest inside; code/blockref/tag are value-LEAVES
// (the node IS the leaf — see LEAF_KINDS). This order MUST stay aligned with
// inline.ex's right-to-left apply_marks fold or round-trips lose idempotency.
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
    default:
      return null; // unknown marks: no portable-doc node, unwrap silently
  }
}

// Value-LEAF marks: the node IS the leaf, not a wrapper. `code` takes its value
// from the text; `blockref`/`tag` take theirs from the mark attrs (the visible
// text is just the `^anchor`/`#name` display token). At most one per run.
const LEAF_KINDS = ["code", "blockref", "tag"];

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
      const items = (block.items || []).map((itemInline) => ({
        type: "listItem",
        content: [
          { type: "paragraph", content: inlineArrayToTiptap(itemInline) },
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
