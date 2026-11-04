// convert.js — pure converters between Barkpark portable-doc blocks and TipTap
// document JSON. NO DOM, NO TipTap imports here so the smoke test can import
// and round-trip these in plain Node.
//
// Exact shapes (verified against api/lib/barkpark/portable_doc/render.ex,
// patch.ex, and the golden op fixtures in priv/portable_doc/goldens/ops/):
//
//   heading   : { id, type:"heading", level:1..6, text:"..." }   (flat string)
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

import { deepClone as deepCloneJson } from "./canvas/projection-json.js";
import { deepClone, jsonEqual } from "./convert-json.js";
import { inlineArrayToTiptap, tiptapInlineToPd } from "./inline-codec.js";

export { inlineArrayToTiptap, tiptapInlineToPd };
export {
  buildTableCellsOp,
  tableProjection,
  tableProjectionMatchesAction,
  tableProjectionMatchesCells,
  tableTiptapDocSupported,
} from "./table-projection.js";

// Match the list readers: arrays, encoded arrays, content-first maps, then text.
// This is list-specific; JSON-looking paragraph strings remain literal prose.
function listItemToInlineArray(item) {
  if (Array.isArray(item)) return item;
  if (typeof item === "string") {
    try {
      const parsed = JSON.parse(item);
      if (Array.isArray(parsed) && parsed.length && parsed[0] && typeof parsed[0] === "object" && !Array.isArray(parsed[0])) return parsed;
    } catch { /* Plain strings remain literal text. */ }
    return [{ type: "text", value: item }];
  }
  if (item && typeof item === "object") {
    if (Array.isArray(item.content) && item.content.length) return item.content;
    return typeof item.text === "string" && item.text !== ""
      ? [{ type: "text", value: item.text }] : [];
  }
  // Any other non-array scalar (number, etc.) → its string form as one text node;
  // null/undefined → an empty item (an empty `<li>`), never a throw.
  if (item == null) return [];
  return [{ type: "text", value: String(item) }];
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
      const source = {};
      for (const key of ["content", "text"]) {
        if (Object.hasOwn(block, key)) source[key] = deepCloneJson(block[key]);
      }
      // A level outside the six the editor offers (a malformed import) is shown at the
      // nearest level and carried on the source, so an edit to the text never rewrites it
      // (D-headings: six levels to author since owner ruling 2026-10-03; a stored level the
      // editor cannot show is never restructured).
      if (Number.isFinite(Number(block.level)) && clampLevel(block.level) !== Number(block.level)) source.level = Number(block.level);
      if (Object.hasOwn(block, "align")) source.align = block.align === "center" || block.align === "right" ? block.align : null;
      const node = { type: "heading", attrs: { level, bpHeadingSource: source } };
      if (block.align === "center" || block.align === "right") node.attrs.textAlign = block.align;
      const inline = headingInline(source);
      if (inline.length) node.content = inline;
      return { type: "doc", content: [node] };
    }
    case "list": {
      return { type: "doc", content: [listToTiptap(block, String(block.id || "list"))] };
    }
    case "paragraph":
    default: {
      const source = {};
      for (const key of ["content", "text"]) {
        if (Object.hasOwn(block, key)) source[key] = deepCloneJson(block[key]);
      }
      // The key's presence rides the source even when cleared (align:null), so a re-projection of
      // a live doc (the diff runs on one) still knows the block carries an align to drop.
      if (Object.hasOwn(block, "align")) source.align = block.align === "center" || block.align === "right" ? block.align : null;
      const node = { type: "paragraph", attrs: { bpParagraphSource: source } };
      if (block.align === "center" || block.align === "right") node.attrs.textAlign = block.align;
      const inline = inlineArrayToTiptap(listItemToInlineArray(source));
      if (inline.length) node.content = inline;
      return { type: "doc", content: [node] };
    }
  }
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


// tiptapToBlock(editorJSON, blockId, blockType) → portable-doc patch fields for
// the block, in the EXACT shape patch-block's `patch` map expects.
//
// Returns ONLY the mutable fields (NOT id/type — patch.ex re-pins those):
//   heading   → { text, level }
//   paragraph → { content: [inline...] }
//   list      → { ordered, items: [[inline...], ...] }
function comparableListInline(content) {
  const out = [];
  for (const node of content || []) {
    const next = deepCloneJson(node);
    // Chromium may parse a literal inline newline as a native break while
    // typing. Both represent the same PortableDoc text; retain source carriers
    // when this DOM normalization is the only difference (including Undo).
    if (next.type === "hardBreak") {
      next.type = "text";
      next.text = "\n";
    }
    if (!next.marks?.length) delete next.marks;
    // The Link extension decorates a mounted link mark with its render defaults
    // (target/rel/class); only `href` is PortableDoc (markToPd reads nothing else).
    // Compare on href alone so an untouched carrier with a link still matches its
    // source and is kept verbatim instead of being re-serialized.
    else next.marks = next.marks.map((mark) => mark?.type === "link"
      ? { type: "link", attrs: { href: (mark.attrs && mark.attrs.href) || "" } } : mark);
    const previous = out[out.length - 1];
    if (previous?.type === "text" && next.type === "text" && jsonEqual(previous.marks, next.marks)) {
      previous.text += next.text;
    } else out.push(next);
  }
  return out;
}

function supportedListChild(child) {
  return child && typeof child === "object" && !Array.isArray(child) &&
    Array.isArray(child.items) && ["list", "bulletList", "bullet_list", "bulleted-list",
      "bulleted_list", "ordered-list", "numbered_list"].includes(child.type);
}

function orderedListSource(block) {
  return block.ordered === true || block.type === "ordered-list" || block.type === "numbered_list";
}

// An ordered list's first number: the block's integer `start` when it is not 1,
// else null (numbering from 1) — the reader's rule (compose.ex list_start/1).
// It mounts as TipTap's orderedList `start` attr and comes back from it.
export function listStart(block) {
  const start = block && block.start;
  return Number.isInteger(start) && start !== 1 ? start : null;
}

function nodeListStart(node) {
  const start = node && node.type === "orderedList" ? node.attrs?.start : null;
  return Number.isInteger(start) && start !== 1 ? start : null;
}

// A checklist is `{type:"list", task:true, items:[{content|text, checked, children?}…]}`; it mounts
// as TipTap's taskList/taskItem so the checkbox is a native control, and comes back through
// listItemFromTiptap with `checked` on every item map.
function listToTiptap(block, path, nested = false) {
  const task = block.task === true;
  const itemChecked = (item) => item && typeof item === "object" && !Array.isArray(item) && item.checked === true;
  const items = (Array.isArray(block.items) ? block.items : []).map((item, index) => ({
    type: task ? "taskItem" : "listItem",
    attrs: { bpListSource: { item: deepCloneJson(item) }, ...(task ? { checked: itemChecked(item) } : {}) },
    content: [{ type: "paragraph", content: inlineArrayToTiptap(listItemToInlineArray(item)) },
      ...(Array.isArray(item?.children) ? item.children.flatMap((child, at) =>
        supportedListChild(child) ? [listToTiptap(child, `${path}/${index}/${at}`, true)] : []) : [])],
  }));
  const start = !task && orderedListSource(block) ? listStart(block) : null;
  const attrs = {
    ...(nested ? { bpListFrameSource: { block: deepCloneJson(block), path } } : {}),
    ...(start === null ? {} : { start }),
  };
  return {
    type: task ? "taskList" : orderedListSource(block) ? "orderedList" : "bulletList",
    ...(Object.keys(attrs).length ? { attrs } : {}),
    content: items.length ? items : [{ type: task ? "taskItem" : "listItem", ...(task ? { attrs: { checked: false } } : {}), content: [{ type: "paragraph" }] }],
  };
}

// The item as the wire wants it for a checklist: always a map carrying `checked`.
function withChecked(result, li, content) {
  const checked = li.attrs?.checked === true;
  if (result && typeof result === "object" && !Array.isArray(result)) return { ...result, checked };
  if (Array.isArray(result)) return { content: result, checked };
  if (typeof result === "string") return { text: result, checked };
  return { content: tiptapInlineToPd(content), checked };
}

function nestedListFromTiptap(node, seen) {
  const source = node.attrs?.bpListFrameSource;
  const ownsSource = source?.block && !seen.has(source.path);
  if (ownsSource) seen.add(source.path);
  const ordered = node.type === "orderedList";
  const task = node.type === "taskList";
  const items = (node.content || []).map(li => listItemFromTiptap(li, seen));
  const start = nodeListStart(node);
  if (!ownsSource) return { type: "list", ordered, items, ...(start === null ? {} : { start }), ...(task ? { task: true } : {}) };
  const fields = deepCloneJson(source.block);
  // An empty source list needs a schema placeholder, not a new persisted item.
  const emptyPlaceholder = fields.items.length === 0 && node.content?.length === 1 &&
    node.content[0].content?.length === 1 && !(node.content[0].content[0].content || []).length;
  fields.items = emptyPlaceholder ? [] : items;
  if (ordered !== orderedListSource(fields)) {
    fields.type = "list";
    fields.ordered = ordered;
  }
  if (task !== (fields.task === true)) {
    fields.type = "list";
    fields.task = task;
  }
  // The shown first number wins: an ordered list the canvas numbers from 1 drops a
  // stored start it no longer shows. Anything else (a bullet list, a start the
  // reader ignores) keeps its source bytes.
  if (start !== null) fields.start = start;
  else if (ordered && listStart(fields) !== null) delete fields.start;
  return fields;
}

function listItemFromTiptap(li, seen = new Set()) {
  const content = li.content?.[0]?.content;
  const source = li.attrs?.bpListSource;
  const item = source && Object.hasOwn(source, "item")
    ? inlineCarrierFromTiptap(source.item, content) : tiptapInlineToPd(content);
  const nested = (li.content || []).slice(1).filter(node =>
    node.type === "bulletList" || node.type === "orderedList" || node.type === "taskList").map(node => nestedListFromTiptap(node, seen));
  const original = Array.isArray(source?.item?.children) ? source.item.children : [];
  const finish = (result) => li.type === "taskItem" ? withChecked(result, li, content) : result;
  if (!nested.length && !original.some(supportedListChild)) return finish(item);
  let index = 0;
  const children = original.flatMap(child => supportedListChild(child)
    ? index < nested.length ? [nested[index++]] : [] : [deepCloneJson(child)]);
  children.push(...nested.slice(index));
  return finish(item && typeof item === "object" && !Array.isArray(item)
    ? { ...item, children } : { content: tiptapInlineToPd(content), children });
}

// reuseInlineSource(source, content) → the portable-doc inline array for an EDITED
// carrier, keeping the author's own source nodes wherever the edit did not reach.
//
// A touched carrier re-serializes through tiptapInlineToPd, which writes the
// canonical spelling of every run: `strike`/`s` become `strikethrough`, a flat
// `marks` leaf becomes nested wrappers, a legacy `text` key becomes `value`, and
// any key the canvas has no attr for is dropped — on runs the author never
// touched. So the edit is located instead: the longest run of SOURCE nodes at the
// start, and then at the end, whose own canvas projection equals the matching
// stretch of the edited content is kept verbatim; only the stretch between them
// is re-serialized. When the two ends cannot be told apart the canonical array
// stands, and the result is checked to project exactly as the edited content does.
function reuseInlineSource(source, content) {
  const inline = tiptapInlineToPd(content);
  if (!Array.isArray(source) || !source.length) return inline;
  const whole = comparableListInline(content);
  const target = whole.map(deepCloneJson);
  const pieces = source.map((node) => comparableListInline(inlineArrayToTiptap([node])));
  const matchesAt = (piece, at) => piece.length > 0 && at >= 0 && at + piece.length <= target.length &&
    piece.every((node, k) => jsonEqual(node, target[at + k]));
  // ProseMirror merges neighbouring text of the same marks into one node, so a source
  // leaf can also be the leading (or trailing) part of a longer edited text node.
  const partAt = (piece, at, fromEnd) => {
    const node = target[at];
    if (piece.length !== 1 || !node || piece[0].type !== "text" || node.type !== "text") return false;
    if (!jsonEqual(piece[0].marks, node.marks) || node.text.length <= piece[0].text.length) return false;
    return fromEnd ? node.text.endsWith(piece[0].text) : node.text.startsWith(piece[0].text);
  };
  let head = 0;
  let from = 0;
  let to = target.length;
  while (head < source.length) {
    if (matchesAt(pieces[head], from)) from += pieces[head++].length;
    else if (from < to && partAt(pieces[head], from, false)) target[from].text = target[from].text.slice(pieces[head++][0].text.length);
    else break;
  }
  let tail = source.length;
  while (tail > head) {
    const piece = pieces[tail - 1];
    if (matchesAt(piece, to - piece.length) && to - piece.length >= from) to -= pieces[--tail].length;
    else if (to - 1 >= from && partAt(piece, to - 1, true)) { const node = target[to - 1]; node.text = node.text.slice(0, -pieces[--tail][0].text.length); }
    else break;
  }
  if (head === 0 && tail === source.length) return inline;
  const middle = tiptapInlineToPd(target.slice(from, to));
  // New text joins a plain neighbouring leaf rather than sitting beside it, so a
  // paragraph does not gain one more leaf per editing session; kept source leaves
  // never merge with each other.
  const plain = (node) => node && node.type === "text" && typeof node.value === "string" &&
    Object.keys(node).length === 2;
  const out = source.slice(0, head).map(deepCloneJson);
  const rest = source.slice(tail).map(deepCloneJson);
  middle.forEach((node, k) => {
    const last = out[out.length - 1];
    if (plain(node) && plain(last)) last.value += node.value;
    else if (k === middle.length - 1 && plain(node) && plain(rest[0])) rest[0].value = node.value + rest[0].value;
    else out.push(node);
  });
  out.push(...rest);
  return jsonEqual(comparableListInline(inlineArrayToTiptap(out)), whole) ? out : inline;
}

function inlineCarrierFromTiptap(item, content) {
  const inline = tiptapInlineToPd(content);
  if (jsonEqual(comparableListInline(inlineArrayToTiptap(listItemToInlineArray(item))),
    comparableListInline(content))) return deepCloneJson(item);
  if (item && typeof item === "object" && !Array.isArray(item)) {
    const next = deepCloneJson(item);
    if (!(Array.isArray(item.content) && item.content.length) && typeof item.text === "string" &&
      inline.every(node => node.type === "text")) next.text = inline.map(node => node.value).join("");
    else {
      next.content = Array.isArray(item.content) && item.content.length ? reuseInlineSource(item.content, content) : inline;
      // Reader maps fall back to text when content is empty. Clearing the
      // authored body must not resurrect an old shadow text value.
      if (!inline.length && typeof next.text === "string") next.text = "";
    }
    return next;
  }
  if (typeof item === "string") {
    const decoded = listItemToInlineArray(item);
    if (!jsonEqual(decoded, [{ type: "text", value: item }])) return JSON.stringify(inline);
    if (inline.every(node => node.type === "text")) return inline.map(node => node.value).join("");
  }
  return Array.isArray(item) ? reuseInlineSource(item, content) : inline;
}

function headingInline(source) {
  if (Array.isArray(source.content) && source.content.length) return inlineArrayToTiptap(source.content);
  const text = source.text;
  return inlineArrayToTiptap(text != null && ["string", "number", "boolean"].includes(typeof text) ? String(text) : "");
}

export function tiptapToBlock(editorJSON, blockId, blockType) {
  const doc = editorJSON || {};
  const top = (doc.content && doc.content[0]) || {};

  switch (blockType) {
    case "heading": {
      const shown = clampLevel(top.attrs && top.attrs.level);
      const source = top.attrs?.bpHeadingSource;
      // The carried deeper level stands while the canvas still shows its nearest level; a
      // turn-into to another level is the author's change and wins.
      const level = source && typeof source === "object" && Number.isFinite(source.level) && clampLevel(source.level) === shown ? source.level : shown;
      if (source && typeof source === "object") {
        const fields = deepCloneJson(source);
        delete fields.level;
        if (jsonEqual(comparableListInline(headingInline(source)), comparableListInline(top.content))) return withAlign({ ...fields, level }, top, source);
        const content = Array.isArray(source.content) && source.content.length
          ? reuseInlineSource(source.content, top.content) : tiptapInlineToPd(top.content);
        const rich = content.some(node => node.type !== "text");
        if ((Array.isArray(source.content) && source.content.length) || rich) {
          fields.content = content;
          if (!content.length && fields.text != null && ["string", "number", "boolean"].includes(typeof fields.text)) fields.text = "";
        } else {
          fields.text = plainText(top.content);
        }
        return withAlign({ ...fields, level }, top, source);
      }
      const content = tiptapInlineToPd(top.content);
      if (content.some(node => node.type !== "text")) return withAlign({ content, level }, top, null);
      const text = plainText(top.content);
      return withAlign({ text, level }, top, null);
    }
    case "list": {
      const task = top.type === "taskList";
      const ordered = !task && top.type === "orderedList";
      const seen = new Set();
      const items = (top.content || []).map(li => listItemFromTiptap(li, seen));
      // `task` rides only when true; run-convert adds task:false when a checklist turns back into a plain list.
      // `start` rides only when the canvas numbers from something other than 1; run-convert
      // adds start:null when a stored start is no longer shown.
      const start = nodeListStart(top);
      if (task) return { ordered, items, task: true };
      return start === null ? { ordered, items } : { ordered, items, start };
    }
    case "paragraph":
    default: {
      const source = top.attrs?.bpParagraphSource;
      if (source && typeof source === "object") return withAlign(inlineCarrierFromTiptap(source, top.content), top, source);
      return withAlign({ content: tiptapInlineToPd(top.content) }, top, null);
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

// The author's alignment on the way back: "center" | "right" ride as `align`; left drops the
// key — as `align: null` on a block whose source carried one (the patch merge drops it),
// as nothing on a fresh block.
function withAlign(fields, top, source) {
  const out = fields && typeof fields === "object" ? fields : {};
  const align = top && top.attrs && top.attrs.textAlign;
  if (align === "center" || align === "right") out.align = align;
  else if (source && Object.hasOwn(source, "align")) out.align = null;
  else delete out.align;
  return out;
}

function clampLevel(level) {
  const n = Number(level);
  if (!Number.isFinite(n)) return 1;
  if (n < 1) return 1;
  if (n > 6) return 6;
  return Math.trunc(n);
}

// Concatenate the plain text of a flat TipTap inline content array — headings
// carry a flat string in portable-doc, so marks are dropped here by design.
function plainText(content) {
  return (content || [])
    .filter((n) => n.type === "text" || n.type === "hardBreak")
    .map((n) => n.type === "hardBreak" ? "\n" : n.text || "")
    .join("");
}
