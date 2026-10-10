// paste-vocabulary.js — fit PASTED blocks to a field's vocabulary, node by node
// (task-76c5440175affe20).
//
// A field canvas carries its declared vocabulary on data-vocabulary, and the
// filterTransaction veto (vocabulary.js transactionVetoesVocabulary) drops a
// transaction that introduces anything outside it. That is right for a typed
// edit, and silent data loss for a paste: ONE out-of-vocabulary node (a markdown
// `> quote`, a table, a <pre>) took the whole clipboard with it, and a `code`
// block the veto cannot name landed only to be refused on save.
//
// fitBlocksToVocabulary(blocks, vocab) rewrites each pasted portable-doc block
// into the nearest shape the field admits, keeping its text:
//
//   heading at a level the field lacks → the nearest admitted level, else a paragraph
//   a list kind the field lacks        → the other kind, else one paragraph per item
//   blockquote / pullquote             → the field's quote block, else a paragraph
//   code                               → a paragraph with a code mark (plain when the
//                                        field has no code mark)
//   table                              → one paragraph per cell, header first
//   image / figure / anything textless → left out, and NAMED in `dropped`
//   any other block                    → a paragraph of its text
//
// and unwraps inline marks the field lacks (the text stays). It never drops a
// block that has text. `dropped` lists what had nothing to keep, so the canvas can
// say so. PURE: no DOM, no ProseMirror — it unit-tests in plain Node.

import { allowedBlockTypes, allowedHeadingLevels, allowedInlineTypes, quoteTypeFor } from "./vocabulary.js";
import { t } from "../i18n.js";

const LEAF_INLINES = new Set(["text", "code"]);

function plainText(inline) {
  if (typeof inline === "string") return inline;
  if (!Array.isArray(inline)) return "";
  return inline
    .map((n) => {
      if (!n || typeof n !== "object") return "";
      if (typeof n.value === "string") return n.value;
      if (typeof n.text === "string") return n.text;
      return plainText(n.children || n.content);
    })
    .join("");
}

// Unwrap the marks the field lacks; text always survives.
function fitInline(inline, allowed) {
  if (!Array.isArray(inline)) return [];
  const out = [];
  for (const n of inline) {
    if (!n || typeof n !== "object") continue;
    if (n.type === "text") {
      out.push(n);
    } else if (n.type === "code" && typeof n.value === "string") {
      out.push(allowed.has("code") ? n : { type: "text", value: n.value });
    } else if (Array.isArray(n.children)) {
      const kids = fitInline(n.children, allowed);
      if (allowed.has(n.type)) out.push({ ...n, children: kids });
      else out.push(...kids);
    } else if (!LEAF_INLINES.has(n.type) && allowed.has(n.type)) {
      out.push(n);
    } else {
      const text = plainText([n]);
      if (text) out.push({ type: "text", value: text });
    }
  }
  return out;
}

const paragraph = (id, content) => ({ id, type: "paragraph", content });

// A fresh id for the extra paragraphs one block becomes (table cells, list items).
function childId(id, i) {
  return i === 0 ? id : `${id}-${i}`;
}

// Inline content of a block that holds it under `content`, `children` or a flat `text`.
function blockInline(block) {
  if (Array.isArray(block.content)) return block.content;
  if (Array.isArray(block.children) && block.children.length && block.children.every((c) => c && c.type && !c.id)) return block.children;
  if (typeof block.text === "string" && block.text !== "") return [{ type: "text", value: block.text }];
  return null;
}

// Every text-bearing piece under an unknown block, as paragraphs.
function textParagraphs(block, allowed) {
  const inline = blockInline(block);
  if (inline) {
    const fitted = fitInline(inline, allowed);
    return plainText(fitted).trim() ? [paragraph(block.id, fitted)] : [];
  }
  const nested = [block.children, block.blocks, block.body].find(Array.isArray) || [];
  const out = [];
  for (const child of nested) if (child && typeof child === "object") out.push(...textParagraphs(child, allowed));
  for (const key of ["caption", "title", "alt"]) {
    const v = block[key];
    const text = typeof v === "string" ? v : plainText(v);
    if (text && text.trim() && !out.length) out.push(paragraph(block.id, [{ type: "text", value: text.trim() }]));
  }
  return out.map((p, i) => ({ ...p, id: childId(block.id, i) }));
}

function nearestLevel(level, levels) {
  const sorted = [...levels].sort((a, b) => Math.abs(a - level) - Math.abs(b - level) || b - a);
  return sorted[0];
}

const DROP_NAMES = { image: "an image", figure: "an image", video: "a video", embed: "an embed" };

export function fitBlocksToVocabulary(blocks, vocab) {
  if (!vocab || !Array.isArray(blocks)) return { blocks: blocks || [], dropped: [] };
  const types = allowedBlockTypes(vocab);
  const levels = allowedHeadingLevels(vocab);
  const allowed = allowedInlineTypes(vocab);
  const quoteAs = quoteTypeFor(vocab);
  const out = [];
  const dropped = [];

  for (const block of blocks) {
    if (!block || typeof block !== "object") continue;
    const t = block.type;

    if (t === "paragraph") {
      out.push({ ...block, content: fitInline(block.content, allowed) });
    } else if (t === "heading") {
      const level = Number(block.level || 1);
      if (types.has("heading") && levels.size) out.push({ ...block, level: levels.has(level) ? level : nearestLevel(level, levels) });
      else out.push(paragraph(block.id, [{ type: "text", value: block.text || plainText(block.content) }]));
    } else if (t === "list") {
      const want = block.ordered ? "number" : "bullet";
      const items = Array.isArray(block.items) ? block.items : [];
      if (vocab.lists.length) {
        const kind = vocab.lists.includes(want) ? want : vocab.lists.includes("bullet") ? "bullet" : "number";
        out.push({ ...block, ordered: kind === "number", items: items.map((it) => (Array.isArray(it) ? fitInline(it, allowed) : it)) });
      } else {
        items.forEach((it, i) => {
          const inline = Array.isArray(it) ? it : blockInline(it || {}) || [];
          const fitted = fitInline(inline, allowed);
          if (plainText(fitted).trim()) out.push(paragraph(childId(block.id, i), fitted));
        });
      }
    } else if (t === "blockquote" || t === "pullquote") {
      const inline = fitInline(blockInline(block) || [], allowed);
      if (types.has(t)) out.push({ ...block, content: inline });
      else if (types.has(quoteAs)) out.push({ id: block.id, type: quoteAs, content: inline });
      else out.push(paragraph(block.id, inline));
    } else if (t === "code" && !types.has("code")) {
      const value = typeof block.value === "string" ? block.value : plainText(blockInline(block) || []);
      if (value) out.push(paragraph(block.id, [allowed.has("code") ? { type: "code", value } : { type: "text", value }]));
    } else if (t === "table" && !types.has("table")) {
      const cells = [...(Array.isArray(block.head) ? block.head : []), ...(Array.isArray(block.rows) ? block.rows.flat() : [])];
      let i = 0;
      for (const cell of cells) {
        const fitted = fitInline(Array.isArray(cell) ? cell : blockInline(cell || {}) || [], allowed);
        if (plainText(fitted).trim()) out.push(paragraph(childId(block.id, i++), fitted));
      }
    } else if (types.has(t)) {
      out.push(block);
    } else {
      const paras = textParagraphs(block, allowed);
      if (paras.length) out.push(...paras);
      if (!paras.length || DROP_NAMES[t]) dropped.push(DROP_NAMES[t] || `block:${t}`);
    }
  }
  return { blocks: out, dropped };
}

// Would these blocks need fitting? A cheap pre-check so an in-vocabulary paste
// keeps ProseMirror's native slice (and its open ends) untouched.
export function blocksNeedFitting(blocks, vocab) {
  if (!vocab || !Array.isArray(blocks)) return false;
  const fitted = fitBlocksToVocabulary(blocks, vocab);
  return fitted.dropped.length > 0 || JSON.stringify(fitted.blocks) !== JSON.stringify(blocks);
}

// The notice for what a paste had to leave out, or null. Its words ride the
// canvas strings (StudioLocale.component_strings(:paper_canvas)).
export function droppedNotice(dropped) {
  if (!dropped || !dropped.length) return null;
  const counts = new Map();
  for (const d of dropped) counts.set(d, (counts.get(d) || 0) + 1);
  // Each entry is an English key ("an image") or `block:<type>`; both translate.
  const name = (d) => (d.startsWith("block:") ? t("a %{type} block", { type: d.slice(6) }) : t(d));
  const parts = [...counts].map(([d, n]) => (n === 1 ? name(d) : t("%{what} (×%{count})", { what: name(d), count: n })));
  return t("Pasted the text. Left out: %{what}. Add it separately: drag the image file in, or insert the block from the menu.", { what: parts.join(", ") });
}
