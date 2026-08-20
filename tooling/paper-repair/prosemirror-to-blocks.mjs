// prosemirror-to-blocks.mjs — convert a stored ProseMirror/TipTap DOCUMENT node
// ({type:"doc", content:[…]}) into a top-level PortableDoc `blocks` array.
//
// WHY THIS EXISTS. A paper whose `body` is a ProseMirror doc matches NONE of the
// four shapes `PortableDoc.Projection.read_blocks/1` accepts (top-level blocks
// list · body.blocks list · body as a list · body as a markdown string). With no
// `body_html` to fall back on, `Papers.reader_source` returns
// `{:error, :semantic_empty}` and every surface — web reader, `bp paper view` —
// answers 422. Writing a top-level `blocks` array is the whole repair: those
// papers store no `body_html`, so `cache_provenance/4` short-circuits to
// `:coherent` and the reader serves the blocks. No server change.
//
// The INLINE half is not reinvented here: it reuses `tiptapInlineToPd` from the
// SHIPPED editor converter (api/assets/paper-editor/src/convert.js), which is
// pure, DOM-free and Node-runnable. Only the BLOCK half — which the editor never
// needed, because it edits one block at a time — is new.
//
// THE TRAP THIS AVOIDS (read before "simplifying" the blockquote case). The
// PortableDoc callout body is a SINGLE inline slot: compose.ex:357 says it
// verbatim — "The callout FLATTENS its single-paragraph body slot to INLINE".
// A blockquote with N paragraphs mapped naively to one callout silently DROPS
// paragraphs 2..N. So the extra paragraphs SPILL into sibling `paragraph`
// blocks right after the callout. Pass {spillCallouts:false} to reproduce the
// lossy behaviour on purpose (the repair CLI uses it to prove the loss is real).

import { tiptapInlineToPd } from "../../api/assets/paper-editor/src/convert.js";

// ── normalisation ──────────────────────────────────────────────────────────

// Some stored documents carry CORRUPT text nodes shaped
// {type:"text", text:{type:"text", text:"…", marks:[…]}} — text nested inside
// text. `tiptapInlineToPd` would read `.text` as an object and stringify it to
// nothing, losing the prose. Unwrap to a flat {type:"text", text:"…", marks}
// with the outer and inner marks merged (outer first, inner appended).
function unwrapNestedText(node) {
  let out = node;
  let guard = 0;
  while (
    out &&
    out.type === "text" &&
    out.text &&
    typeof out.text === "object" &&
    guard++ < 8
  ) {
    const inner = out.text;
    out = {
      ...out,
      text: inner.text,
      marks: [...(out.marks || []), ...(inner.marks || [])],
    };
  }
  return out;
}

// Mark names the shipped converter understands are TipTap's own
// (bold/italic/code/strike/underline/link/…). Stored documents also carry the
// PortableDoc spellings `strong`/`em`; map them across so the emphasis survives
// instead of being dropped as an unknown mark.
const MARK_ALIASES = { strong: "bold", em: "italic", italic: "italic" };

function normalizeMarks(marks) {
  return (marks || []).map((m) =>
    m && MARK_ALIASES[m.type] ? { ...m, type: MARK_ALIASES[m.type] } : m,
  );
}

// One inline content array, made safe for `tiptapInlineToPd`.
function normalizeInline(content) {
  return (Array.isArray(content) ? content : [])
    .map(unwrapNestedText)
    .filter((n) => n && n.type === "text" && typeof n.text === "string")
    .map((n) => (n.marks ? { ...n, marks: normalizeMarks(n.marks) } : n));
}

function inlineOf(node) {
  return tiptapInlineToPd(normalizeInline(node && node.content));
}

function plainTextOf(node) {
  return normalizeInline(node && node.content)
    .map((n) => n.text || "")
    .join("");
}

// Inline arrays joined with a single space — used where PortableDoc has ONE
// inline slot but ProseMirror had several paragraphs (a list item, a table
// cell). The space keeps words from fusing; whitespace-normalised fidelity
// checks are unaffected by it.
function joinInline(arrays) {
  const kept = arrays.filter((a) => a.length);
  const out = [];
  kept.forEach((a, i) => {
    if (i > 0) out.push({ type: "text", value: " " });
    out.push(...a);
  });
  return out;
}

function clampLevel(level) {
  const n = Number(level);
  if (!Number.isFinite(n)) return 1;
  return Math.min(3, Math.max(1, Math.trunc(n)));
}

// ── block conversion ───────────────────────────────────────────────────────

// A list item is one inline array in PortableDoc. A ProseMirror listItem may
// hold several paragraphs and nested lists; flatten it losslessly — the item's
// own paragraphs join into its inline array, and a nested list's items are
// emitted as further items of the SAME list (indentation is lost, prose is not).
function listItemsOf(node, out) {
  (node.content || []).forEach((li) => {
    const own = [];
    (li.content || []).forEach((child) => {
      if (child.type === "paragraph") own.push(inlineOf(child));
      else if (child.type === "bulletList" || child.type === "orderedList") {
        // defer: emit after the item's own text
      } else own.push(inlineOf(child));
    });
    out.push(joinInline(own));
    (li.content || [])
      .filter((c) => c.type === "bulletList" || c.type === "orderedList")
      .forEach((sub) => listItemsOf(sub, out));
  });
}

function tableCell(cell) {
  return joinInline((cell.content || []).map((p) => inlineOf(p)));
}

function tableBlock(node, id) {
  const rows = (node.content || []).filter((r) => r.type === "tableRow");
  const isHeaderRow = (r) =>
    (r.content || []).length > 0 &&
    (r.content || []).every((c) => c.type === "tableHeader");

  let head = null;
  let bodyRows = rows;
  if (rows.length && isHeaderRow(rows[0])) {
    head = (rows[0].content || []).map(tableCell);
    bodyRows = rows.slice(1);
  }
  const block = {
    id,
    type: "table",
    rows: bodyRows.map((r) => (r.content || []).map(tableCell)),
  };
  if (head) block.head = head;
  return block;
}

// Convert ONE top-level ProseMirror node into one or more PortableDoc blocks.
function convertNode(node, ctx) {
  const id = () => `block-${++ctx.n}`;
  const blocks = [];

  switch (node && node.type) {
    case "heading":
      blocks.push({
        id: id(),
        type: "heading",
        level: clampLevel(node.attrs && node.attrs.level),
        text: plainTextOf(node),
      });
      break;

    case "paragraph":
      blocks.push({ id: id(), type: "paragraph", content: inlineOf(node) });
      break;

    case "bulletList":
    case "orderedList": {
      const items = [];
      listItemsOf(node, items);
      blocks.push({
        id: id(),
        type: "list",
        ordered: node.type === "orderedList",
        items,
      });
      break;
    }

    // A stored `callout` node and a `blockquote` land in the same PortableDoc
    // block; both hit the single-inline-slot constraint, so both spill.
    case "blockquote":
    case "callout": {
      const children = node.content || [];
      const [first, ...rest] = children;
      blocks.push({
        id: id(),
        type: "callout",
        tone: (node.attrs && node.attrs.tone) || "info",
        content: first ? inlineOf(first) : [],
      });
      // THE SPILL — see the header note. The callout body is one inline slot,
      // so anything after the first paragraph must become sibling blocks or it
      // is silently lost.
      if (ctx.spillCallouts) {
        rest.forEach((child) => blocks.push(...convertNode(child, ctx)));
      } else {
        ctx.dropped += rest.length;
      }
      break;
    }

    case "table":
      blocks.push(tableBlock(node, id()));
      break;

    case "codeBlock":
      blocks.push({ id: id(), type: "code", value: plainTextOf(node) });
      break;

    case "horizontalRule":
      blocks.push({ id: id(), type: "divider" });
      break;

    default: {
      // Unknown node: never drop its prose, and report the type so a corpus run
      // can be audited. A wrapper (children of its own) is recursed into so its
      // paragraphs survive as blocks; a leaf keeps its inline text.
      ctx.unsupported.add((node && node.type) || "(untyped)");
      const children = (node && node.content) || [];
      if (children.some((c) => c && c.type && c.type !== "text")) {
        children.forEach((child) => blocks.push(...convertNode(child, ctx)));
      } else {
        blocks.push({ id: id(), type: "paragraph", content: inlineOf(node) });
      }
    }
  }

  return blocks;
}

/**
 * Convert a stored ProseMirror document node to a PortableDoc blocks array.
 *
 * @param {object} body  {type:"doc", content:[…]} (a bare array is tolerated)
 * @param {object} [opts]
 * @param {boolean} [opts.spillCallouts=true]  false ⇒ the NAIVE, lossy mapping
 * @returns {{blocks: Array, unsupported: string[], droppedCalloutParagraphs: number}}
 */
export function prosemirrorDocToBlocks(body, opts = {}) {
  const spillCallouts = opts.spillCallouts !== false;
  const content = Array.isArray(body) ? body : (body && body.content) || [];
  const ctx = { n: 0, spillCallouts, unsupported: new Set(), dropped: 0 };
  const blocks = [];
  content.forEach((node) => blocks.push(...convertNode(node, ctx)));
  return {
    blocks,
    unsupported: [...ctx.unsupported],
    droppedCalloutParagraphs: ctx.dropped,
  };
}

/** True when `body` is a ProseMirror document the reader cannot project. */
export function isProseMirrorDoc(body) {
  return !!body && typeof body === "object" && body.type === "doc" && Array.isArray(body.content);
}

// ── fidelity ───────────────────────────────────────────────────────────────

/** Whitespace-normalised plain text of a ProseMirror document node. */
export function prosemirrorText(body) {
  const out = [];
  const walk = (node) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== "object") return;
    const n = unwrapNestedText(node);
    if (n.type === "text" && typeof n.text === "string") out.push(n.text);
    if (Array.isArray(n.content)) n.content.forEach(walk);
  };
  walk(Array.isArray(body) ? body : (body && body.content) || []);
  return normalizeWhitespace(out.join(" "));
}

/** Whitespace-normalised plain text of a PortableDoc blocks array. */
export function blocksText(blocks) {
  const out = [];
  const inline = (nodes) =>
    (Array.isArray(nodes) ? nodes : []).forEach((n) => {
      if (!n || typeof n !== "object") return;
      if (n.type === "text" || n.type === "code") out.push(n.value || "");
      else if (Array.isArray(n.children)) inline(n.children);
    });

  (blocks || []).forEach((b) => {
    if (!b || typeof b !== "object") return;
    switch (b.type) {
      case "heading":
        out.push(b.text || "");
        break;
      case "code":
        out.push(b.value || "");
        break;
      case "list":
        (b.items || []).forEach(inline);
        break;
      case "table":
        (b.head || []).forEach(inline);
        (b.rows || []).forEach((row) => (row || []).forEach(inline));
        break;
      case "divider":
        break;
      default:
        inline(b.content);
    }
  });
  return normalizeWhitespace(out.join(" "));
}

export function normalizeWhitespace(s) {
  return String(s).replace(/\s+/g, " ").trim();
}
