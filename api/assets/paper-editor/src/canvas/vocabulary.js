// vocabulary.js — Gyldendal parity stage E1: the PURE field-vocabulary decisions
// for a canvas that edits ONE schema field.
//
// A schema `richText` field with `"editor": "blocks"` declares what an author may
// put in it, in the shape Sanity's block-content registry uses:
//
//   { styles: ["normal","h2","h3","blockquote"], lists: ["bullet","number"],
//     marks: ["strong","em"], annotations: [{ name: "link" }], of: ["image"] }
//
// The server (Barkpark.PortableDoc.FieldVocabulary) is the truth and refuses an
// out-of-vocabulary op by name. The LiveView stamps the SAME declaration JSON on
// the canvas host as `data-vocabulary` (the twin of `data-constraints`), and this
// module turns it into the two calm client decisions — WITHOUT any DOM or
// ProseMirror import, so it unit-tests in plain Node like constraints.js:
//
//   1. slashItemsForVocabulary(items, vocab) — which slash rows to OFFER.
//   2. transactionVetoesVocabulary(tr, state, vocab) — the CALM VETO: a user edit
//      that would introduce an out-of-vocabulary node, heading level, list kind
//      or mark is dropped as a local no-op (a pasted h1 into an h2/h3-only field
//      simply does not land). Only NEWLY-introduced violations veto, so a doc the
//      server already holds never freezes the editor.
//
// Additive: an ABSENT `data-vocabulary` (null / "" / malformed) means "no field
// vocabulary" — nothing is filtered, nothing is vetoed, the paper canvas is
// byte-unchanged (the same D3 posture constraints.js keeps).

const HEADING_STYLES = new Set(["h1", "h2", "h3", "h4", "h5", "h6"]);
const STYLE_TYPES = { normal: "paragraph", blockquote: "pullquote" };

// TipTap mark name → portable-doc inline type (convert.js keeps the same table).
const MARK_TO_PD = {
  bold: "strong",
  italic: "em",
  strike: "strikethrough",
  underline: "underline",
  code: "code",
  link: "link",
  wikilink: "wikilink",
  blockref: "blockref",
  tag: "tag",
  valueref: "valueref",
};

// Plain TipTap node names the canvas uses for prose; every OTHER canvas node
// carries its portable-doc type on attrs.bpType (role nodes, bpOpaque, bpFigure,
// field atoms) — see run-convert.js.
const NODE_TO_PD = {
  paragraph: "paragraph",
  heading: "heading",
  bulletList: "list",
  orderedList: "list",
};

function stringList(v) {
  return Array.isArray(v) ? v.filter((s) => typeof s === "string") : [];
}

// The declaration JSON → a normalized vocabulary, or null when there is none.
export function parseVocabulary(json) {
  if (json == null || json === "") return null;
  let parsed;
  try {
    parsed = typeof json === "string" ? JSON.parse(json) : json;
  } catch (_e) {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const annotations = Array.isArray(parsed.annotations)
    ? parsed.annotations
        .map((a) => (a && typeof a === "object" ? a.name : a))
        .filter((n) => typeof n === "string")
    : [];
  return {
    styles: stringList(parsed.styles),
    lists: stringList(parsed.lists),
    marks: stringList(parsed.marks),
    annotations,
    of: stringList(parsed.of),
  };
}

// Portable-doc block types the vocabulary admits.
export function allowedBlockTypes(vocab) {
  const out = new Set();
  for (const s of vocab.styles) {
    if (HEADING_STYLES.has(s)) out.add("heading");
    else if (STYLE_TYPES[s]) out.add(STYLE_TYPES[s]);
  }
  if (vocab.lists.length > 0) out.add("list");
  for (const t of vocab.of) out.add(t);
  return out;
}

export function allowedHeadingLevels(vocab) {
  const out = new Set();
  for (const s of vocab.styles) if (HEADING_STYLES.has(s)) out.add(Number(s.slice(1)));
  return out;
}

// Portable-doc inline types the vocabulary admits (text always).
export function allowedInlineTypes(vocab) {
  return new Set(["text", ...vocab.marks, ...vocab.annotations]);
}

// The portable-doc type a TipTap node JSON stands for, or null when unknown.
function pdTypeOf(node) {
  if (!node) return null;
  const a = node.attrs || {};
  if (typeof a.bpType === "string" && a.bpType !== "") return a.bpType;
  return NODE_TO_PD[node.type] || null;
}

function listOrdered(node) {
  return node && node.type === "orderedList";
}

// Every text node's marks under `node`, depth-first.
function* marksOf(node) {
  if (!node) return;
  if (node.type === "text" && Array.isArray(node.marks)) {
    for (const m of node.marks) yield m && m.type;
  }
  if (Array.isArray(node.content)) {
    for (const child of node.content) yield* marksOf(child);
  }
}

// The FIRST vocabulary violation in a doc JSON ({ type:"doc", content:[…] }), as
// a short reason string — or null when the doc is inside the vocabulary. Pure.
export function docVocabularyViolation(docJson, vocab) {
  if (!vocab) return null;
  const types = allowedBlockTypes(vocab);
  const levels = allowedHeadingLevels(vocab);
  const inlines = allowedInlineTypes(vocab);
  const nodes = (docJson && Array.isArray(docJson.content) && docJson.content) || [];
  for (const node of nodes) {
    const t = pdTypeOf(node);
    if (t == null) continue; // a node the canvas owns but the vocabulary cannot name (e.g. an empty seed paragraph shell)
    if (!types.has(t)) return `block type ${t}`;
    if (t === "heading") {
      const level = Number((node.attrs && node.attrs.level) || 1);
      if (!levels.has(level)) return `heading level ${level}`;
    }
    if (t === "list") {
      const kind = listOrdered(node) ? "number" : "bullet";
      if (!vocab.lists.includes(kind)) return `${kind === "number" ? "numbered" : "bulleted"} list`;
    }
    for (const markName of marksOf(node)) {
      const pd = MARK_TO_PD[markName] || markName;
      if (!inlines.has(pd)) return `inline ${pd}`;
    }
  }
  return null;
}

// THE CALM VETO. Only a NEWLY-introduced violation vetoes: a transaction that
// leaves the doc no worse than it was passes (a calm content edit inside a doc
// the server already holds), exactly the "only newly-broken" rule
// constraints.js applies to relative order.
export function transactionVetoesVocabulary(tr, state, vocab) {
  if (!vocab) return false;
  if (!tr || !tr.docChanged) return false;
  const after = docVocabularyViolation(tr.doc.toJSON(), vocab);
  if (after == null) return false;
  const before = state && state.doc ? docVocabularyViolation(state.doc.toJSON(), vocab) : null;
  return before == null;
}

// Which slash rows to OFFER: the canvas's insertable items narrowed to the
// vocabulary's block types. Compound "Starters" rows (whole subtrees) are never
// offered inside a field. An absent vocabulary passes the items through intact.
export function slashItemsForVocabulary(items, vocab) {
  if (!vocab) return items;
  const types = allowedBlockTypes(vocab);
  return (items || []).filter((it) => it && !it.compound && types.has(it.type));
}
