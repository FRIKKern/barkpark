// Pure portable-doc inline tree and TipTap inline conversion.
import { deepClone as deepCloneJson } from "./canvas/projection-json.js";
import { jsonEqual } from "./convert-json.js";

// ── portable-doc inline tree  →  flat TipTap text nodes ────────────────────

// A text leaf's string the way the reader coerces it (inline.ex coerce_text_value):
// binaries pass, numbers stringify, anything else is empty.
function coerceInlineText(value) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

// One entry of a text leaf's flat `marks` array (the ProseMirror-style spelling the
// reader folds in inline.ex apply_mark/3) → the TipTap mark the canvas edits. A mark
// the canvas has no editor for returns null and is left out of the projection.
function flatMarkToTiptap(mark) {
  // BPML stores a mark as a bare string ("code"); the editor stores {type}.
  const type = typeof mark === "string" ? mark : mark && typeof mark === "object" ? mark.type : null;
  switch (type) {
    case "bold": case "strong": return { type: "bold" };
    case "italic": case "em": return { type: "italic" };
    case "underline": return { type: "underline" };
    case "highlight": return { type: "highlight" };
    case "sub": return { type: "subscript" };
    case "sup": return { type: "superscript" };
    case "strike": case "s": case "strikethrough": return { type: "strike" };
    case "code": return { type: "code" };
    case "link": {
      const href = (mark.attrs && typeof mark.attrs.href === "string" && mark.attrs.href) ||
        (typeof mark.href === "string" ? mark.href : "");
      return { type: "link", attrs: { href } };
    }
    default: return null;
  }
}

// An unknown flat mark rides as a bpOpaqueMark (./opaque-mark.js) holding the stored
// mark and its leaf's whole `marks` array verbatim, so a save writes both back.
const OPAQUE_MARK = "bpOpaqueMark";
// A mark object may name itself `_type` (Portable Text's spelling) instead of `type`;
// it is carried the same way (task-87c8c9503e4f6028).
function opaqueMarkToTiptap(mark, leafMarks) {
  const nameOf = (m) => (typeof m.type === "string" && m.type !== "" ? m.type : m._type);
  const named = typeof mark === "string" ? mark !== "" :
    mark && typeof mark === "object" && !Array.isArray(mark) && typeof nameOf(mark) === "string" && nameOf(mark) !== "";
  if (!named) return null;
  return { type: OPAQUE_MARK, attrs: { mark: deepCloneJson(mark), leaf: deepCloneJson(leafMarks) } };
}

// Walk one portable-doc inline node, accumulating active marks, and push the
// resulting flat TipTap text nodes into `out`.
function inlineToTiptapNodes(node, marks, out) {
  if (!node || typeof node !== "object") return;

  switch (node.type) {
    case "text": {
      // The reader dual-reads `value` || legacy `text` (inline.ex compose_inline) and
      // applies a flat `marks` array; read both the same way so the canvas shows — and a
      // touched block keeps — what the reader paints.
      const text = coerceInlineText(node.value) || coerceInlineText(node.text);
      if (text.length === 0) return;
      const own = Array.isArray(node.marks)
        ? node.marks.map((m) => flatMarkToTiptap(m) || opaqueMarkToTiptap(m, node.marks)).filter(Boolean) : [];
      const all = [...marks, ...own];
      const tnode = { type: "text", text };
      if (all.length) tnode.marks = all.map((m) => ({ ...m }));
      out.push(tnode);
      return;
    }
    case "code": {
      // inline code is a leaf in portable-doc; in TipTap it is a `code` mark. The
      // leaf's own flat `marks` ride like a text leaf's, so typing inside the code
      // writes them back (task-87c8c9503e4f6028).
      const text = node.value || "";
      if (text.length === 0) return;
      const own = Array.isArray(node.marks)
        ? node.marks.map((m) => flatMarkToTiptap(m) || opaqueMarkToTiptap(m, node.marks)).filter(Boolean) : [];
      out.push({ type: "text", text, marks: [...marks, { type: "code" }, ...own].map((m) => ({ ...m })) });
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
    // `strike` / `s` are reader-accepted spellings of strikethrough (inline.ex, inline.go).
    case "strikethrough":
    case "strike":
    case "s": {
      const next = [...marks, { type: "strike" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "underline": {
      const next = [...marks, { type: "underline" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "highlight": {
      const next = [...marks, { type: "highlight" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "sub": {
      const next = [...marks, { type: "subscript" }];
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, next, out));
      return;
    }
    case "sup": {
      const next = [...marks, { type: "superscript" }];
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
    // `chip` is a reader-known inline (render/inline.ex) the editor has no UI
    // for yet (inline objects: task-85fee859cf3bfef6): carried verbatim.
    case "chip":
      out.push(inlineOpaqueNode(node, marks));
      return;
    default:
      // Any other typed inline node the editor does not know is carried VERBATIM
      // as an inert atom (task-a110126ce9111388). It used to render its children
      // or, childless, DROP — and the first save of its paragraph then deleted it
      // from the stored document. Only a node with no type at all still falls
      // back to its children.
      if (typeof node.type === "string" && node.type !== "") {
        out.push(inlineOpaqueNode(node, marks));
        return;
      }
      (node.children || []).forEach((c) => inlineToTiptapNodes(c, marks, out));
      return;
  }
}

function inlineOpaqueNode(node, marks) {
  const atom = { type: "bpInlineOpaque", attrs: { node: deepCloneJson(node) } };
  if (marks.length) atom.marks = marks.map((m) => ({ ...m }));
  return atom;
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
  const arr = Array.isArray(inline) ? inline
    : inline == null ? [] : [{ type: "text", value: String(inline) }];
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
  "highlight",
  "sub",
  "sup",
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
    case "highlight":
      return { kind: "highlight" };
    case "subscript":
      return { kind: "sub" };
    case "superscript":
      return { kind: "sup" };
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
  const { flat, rest } = opaqueLeafMarks(tnode.marks || []);
  // Collect wrappers, ordered outer→inner per MARK_ORDER.
  const wrappers = [];
  rest.forEach((m) => {
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
  if (flat) node.marks = flat;

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

// A run holding bpOpaqueMarks came from a text leaf whose flat `marks` named a mark
// the canvas has no editor for. Rebuild that leaf's `marks` in its stored order and
// spelling: each opaque mark verbatim, and each known one the run still carries.
// The run's other marks (outer wrappers, marks added since) wrap as usual.
function opaqueLeafMarks(marks) {
  const opaque = marks.filter((m) => m.type === OPAQUE_MARK && m.attrs && m.attrs.mark);
  if (!opaque.length) return { flat: null, rest: marks };
  const stored = opaque.map((m) => m.attrs.leaf).find(Array.isArray) || [];
  const same = (run, known) => run.type === known.type &&
    (known.type !== "link" || ((run.attrs && run.attrs.href) || "") === known.attrs.href);
  const used = new Set();
  const flat = [];
  stored.forEach((entry) => {
    const known = flatMarkToTiptap(entry);
    const hit = known ? marks.find((m) => same(m, known))
      : opaque.find((m) => jsonEqual(m.attrs.mark, entry));
    if (!hit) return;
    flat.push(deepCloneJson(entry));
    used.add(hit);
  });
  opaque.forEach((m) => {
    if (!used.has(m)) flat.push(deepCloneJson(m.attrs.mark));
  });
  return { flat, rest: marks.filter((m) => !used.has(m) && m.type !== OPAQUE_MARK) };
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
  if (kind === "highlight") return "highlight";
  if (kind === "sub") return "subscript";
  if (kind === "sup") return "superscript";
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
    .filter((n) => n.type === "text" || n.type === "hardBreak" || n.type === "bpInlineOpaque")
    .map((n) => {
      if (n.type === "bpInlineOpaque") return inlineOpaqueToPd(n);
      return tiptapTextNodeToPd(n.type === "hardBreak" ? { ...n, type: "text", text: "\n" } : n);
    });
}

// The stored node back, byte-exact, inside the wrappers its marks name (the
// same wrapping tiptapTextNodeToPd gives a text run).
function inlineOpaqueToPd(atom) {
  let node = deepCloneJson((atom.attrs && atom.attrs.node) || {});
  const wrappers = (atom.marks || []).map(markToPd).filter((w) => w && !LEAF_KINDS.includes(w.kind));
  wrappers.sort(
    (a, b) => MARK_ORDER.indexOf(pdKindToMark(a.kind)) - MARK_ORDER.indexOf(pdKindToMark(b.kind)),
  );
  for (let i = wrappers.length - 1; i >= 0; i--) {
    const w = wrappers[i];
    if (w.kind === "link") {
      node = { type: "link", href: w.href, children: [node] };
    } else if (w.kind === "wikilink") {
      const wrapped = { type: "wikilink", target: w.target, children: [node] };
      if (w.alias != null) wrapped.alias = w.alias;
      if (w.docId != null) wrapped.docId = w.docId;
      node = wrapped;
    } else {
      node = { type: w.kind, children: [node] };
    }
  }
  return node;
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
