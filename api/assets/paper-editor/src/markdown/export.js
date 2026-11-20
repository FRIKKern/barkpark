// Markdown export — PortableDoc blocks to Markdown a person reads.
//
//   blocksToExportMarkdown(blocks, { baseUrl?, placeholder? }) -> string
//
// serialize.js writes Markdown that parses back to the same blocks, so anything
// Markdown cannot say rides an HTML-comment sentinel holding the block's JSON.
// That is right for source mode and wrong for a file a writer hands to someone
// else. This direction is one way and text first:
//
//   native      heading, paragraph, list, checklist, quote, code, table, divider,
//               image, link, diagram (a mermaid fence), equation ($$)
//   as text     callout and note (a quote with a bold label), steps (a numbered
//               list), tabs, columns, section, expandable, figure, card, terminal
//               (their blocks in order), sheet (its snapshot as a table), fields
//               (**Label:** value)
//   placeholder everything else: one quoted line naming the block, then the
//               words it holds, if any
//
// No block is dropped without a line. Inline marks Markdown lacks (underline,
// highlight, sub, sup) keep their text; a document link keeps its words.
// The inline writer, the escaping and the fence picker are serialize.js's own.

import { calloutBodyBlocks } from "./callout-words.js";
import { clampLevel } from "./shared.js";
import { escapeInlineText, inlineToMarkdown, pickFence } from "./serialize.js";

const DEFAULT_PLACEHOLDER = "%{block}: not included in Markdown export";
const TONES = { info: "Note", neutral: "Note", note: "Note", tip: "Tip", success: "Success", warn: "Warning", warning: "Warning", danger: "Danger", error: "Danger" };
const WRAPS = { bold: "strong", strong: "strong", italic: "em", em: "em", strike: "strikethrough", s: "strikethrough", strikethrough: "strikethrough" };
const isMap = (v) => !!v && typeof v === "object" && !Array.isArray(v);
const str = (v) => (typeof v === "string" ? v : typeof v === "number" || typeof v === "boolean" ? String(v) : "");
const oneLine = (text) => str(text).replace(/\s*[\r\n]+\s*/g, " ").trim();
const humanize = (type) => {
  const words = str(type).replace(/[-_]+/g, " ").replace(/([a-z])([A-Z])/g, "$1 $2").trim().toLowerCase();
  return words ? words[0].toUpperCase() + words.slice(1) : "Block";
};

export function blocksToExportMarkdown(blocks, options = {}) {
  const ctx = {
    baseUrl: typeof options.baseUrl === "string" ? options.baseUrl : "",
    placeholder: typeof options.placeholder === "string" && options.placeholder.includes("%{block}") ? options.placeholder : DEFAULT_PLACEHOLDER,
  };
  return chunks(blocks, ctx).join("\n\n");
}

// The blocks a container holds, under `children` or `blocks` as the reader reads them.
const inside = (node, ctx) => chunks(Array.isArray(node.children) ? node.children : node.blocks, ctx);

function chunks(blocks, ctx) {
  return (Array.isArray(blocks) ? blocks : []).map((block) => blockMd(block, ctx)).filter((md) => md !== "");
}

// ── addresses ────────────────────────────────────────────────────────────────

// An address as the exported file can use it: absolute when a base is known,
// and with the characters that would end a Markdown destination encoded.
function address(raw, ctx) {
  let url = str(raw).trim();
  if (url === "") return "";
  if (ctx.baseUrl && !/^(#|[a-z][a-z0-9+.-]*:)/i.test(url)) {
    try { url = new URL(url, ctx.baseUrl).href; } catch (_) { /* keep it as written */ }
  }
  return url.replace(/\s/g, "%20").replace(/\(/g, "%28").replace(/\)/g, "%29");
}

// ── inline ───────────────────────────────────────────────────────────────────

// The inline tree with only what Markdown can say: flat `marks` become nested
// marks, a mark Markdown lacks keeps its text, links get a usable address.
function plain(nodes, ctx, inStrike) {
  const list = typeof nodes === "string" ? [nodes] : Array.isArray(nodes) ? nodes : [];
  const out = [];
  const text = (value) => { if (value !== "") out.push({ type: "text", value }); };
  for (const node of list) {
    if (typeof node === "string") { text(node); continue; }
    if (!isMap(node)) continue;
    const kids = (strike) => plain(node.children || [], ctx, strike || inStrike);
    switch (node.type) {
      case "text": case "code": out.push(...leaf(node, ctx, inStrike)); break;
      case "strong": case "em": { const k = kids(); if (k.length) out.push({ type: node.type, children: k }); break; }
      case "strikethrough": { const k = kids(true); if (k.length) out.push(...(inStrike ? k : [{ type: "strikethrough", children: k }])); break; }
      case "link": {
        const k = kids();
        const href = address(node.href, ctx);
        if (k.length) out.push(...(href ? [{ type: "link", href, children: k }] : k));
        break;
      }
      case "wikilink": { const k = kids(); k.length ? out.push(...k) : text(str(node.alias) || str(node.target)); break; }
      case "tag": text("#" + str(node.name)); break;
      default: {
        const k = kids();
        k.length ? out.push(...k) : text(str(node.value) || str(node.text) || str(node.display) || str(node.target));
      }
    }
  }
  return out;
}

// A text or code leaf, wrapped in the marks its flat `marks` array names.
function leaf(node, ctx, inStrike) {
  const value = str(node.value ?? node.text);
  if (value === "") return [];
  const marks = (Array.isArray(node.marks) ? node.marks : []).map((m) => (typeof m === "string" ? { type: m } : m)).filter(isMap);
  const code = node.type === "code" || marks.some((m) => m.type === "code");
  let out = code && oneLine(value) !== "" ? { type: "code", value: oneLine(value) } : { type: "text", value };
  for (const mark of marks) {
    const wrap = WRAPS[mark.type];
    if (wrap === "strikethrough" && inStrike) continue;
    if (wrap) out = { type: wrap, children: [out] };
    else if (mark.type === "link") {
      const href = address((mark.attrs && mark.attrs.href) || mark.href, ctx);
      if (href) out = { type: "link", href, children: [out] };
    }
  }
  return [out];
}

// Inline content (an inline array, or a plain string) as one Markdown string;
// a line break inside it becomes `br`.
function inline(content, ctx, br) {
  return inlineToMarkdown(plain(content, ctx, false), null).replace(/\r?\n/g, br === undefined ? "  \n" : br).trim();
}

// A line of body text may not open with a marker that would turn it into
// another block.
function guard(line) {
  const numbered = /^(\d+)[.)](\s|$)/.exec(line);
  if (numbered) return numbered[1] + "\\" + line.slice(numbered[1].length);
  return /^([-+>]|\*\s)/.test(line) ? "\\" + line : line;
}

function paragraph(content, ctx) {
  return inline(content, ctx).split("\n").map(guard).join("\n");
}

const quote = (md) => (md === "" ? "" : md.split("\n").map((line) => (line ? "> " + line : ">")).join("\n"));
const indent = (md, pad) => md.split("\n").map((line) => (line ? pad + line : line)).join("\n");
const fenced = (value, info) => { const fence = pickFence(str(value)); return fence + (info || "") + "\n" + str(value) + "\n" + fence; };
const bold = (text) => (oneLine(text) ? "**" + escapeInlineText(oneLine(text)) + "**" : "");
const italic = (text) => (oneLine(text) ? "*" + escapeInlineText(oneLine(text)) + "*" : "");
const joined = (parts) => parts.filter((part) => part !== "").join("\n\n");

// ── blocks ───────────────────────────────────────────────────────────────────

function blockMd(block, ctx) {
  if (!isMap(block) || typeof block.type !== "string") return "";
  const type = block.type;
  switch (type) {
    case "heading": {
      const text = typeof block.text === "string" ? escapeInlineText(oneLine(block.text)) : inline(block.content, ctx, " ");
      return text ? "#".repeat(clampLevel(block.level)) + " " + text : "";
    }
    case "paragraph": case "ingress": return paragraph(block.content ?? block.text, ctx);
    case "eyebrow": return paragraph(block.text ?? block.content, ctx);
    case "byline": return paragraph(Array.isArray(block.items) ? block.items.map(str).filter(Boolean).join(" · ") : block.text ?? block.content, ctx);
    case "list": case "ordered-list": return listMd(block, ctx);
    case "blockquote": case "pullquote": {
      const cite = oneLine(block.cite ?? block.attribution);
      return quote(joined([inline(block.content ?? block.text, ctx), cite ? "— " + escapeInlineText(cite) : ""]));
    }
    // A callout's words: callout-words.js holds the rule.
    case "callout": {
      const tone = TONES[str(block.tone).toLowerCase()] || humanize(block.tone || "note");
      const title = oneLine(block.title);
      const head = title ? "**" + tone + ":** " + escapeInlineText(title) : "**" + tone + "**";
      return quote(joined([head, inline(block.content, ctx), ...chunks(calloutBodyBlocks(block), ctx), ...inside(block, ctx)]));
    }
    case "note": return quote(noteLine(block, ctx));
    case "notes": return quote(joined((Array.isArray(block.items) ? block.items : []).map((item) => noteLine(item, ctx)))) || placeholder(block, ctx);
    case "code": {
      const source = ["value", "code", "content", "text"].map((key) => (Array.isArray(block[key]) ? plainText(block[key]) : str(block[key]))).find((text) => text.trim() !== "");
      return source === undefined ? "" : fenced(source, /^[^\s`]+$/.test(str(block.lang || block.language)) ? str(block.lang || block.language) : "");
    }
    case "diff": return joined([block.file ? "`" + oneLine(block.file) + "`" : "", fenced(block.diff, "diff")]);
    case "filetree": return joined([fenced(block.text, ""), italic(block.legend)]);
    case "code-tabs": return joined((Array.isArray(block.tabs) ? block.tabs : []).flatMap((tab) => [bold(tab && tab.label), fenced(tab && tab.value, oneLine(tab && (tab.language || tab.lang)).replace(/[\s`]/g, ""))]));
    case "diagram": return joined([fenced(block.source, "mermaid"), italic(block.caption)]);
    case "equation": return str(block.tex).trim() ? "$$\n" + str(block.tex).trim() + "\n$$" : "";
    case "divider": return "---";
    case "image": {
      const src = address(block.src, ctx);
      if (!src) return placeholder(block, ctx);
      return joined(["![" + oneLine(block.alt).replace(/[\[\]]/g, "") + "](" + src + ")", italic(block.caption)]);
    }
    case "figure": return joined([blockMd(block.child, ctx), ...inside(block, ctx), italic(block.caption)]) || placeholder(block, ctx);
    case "table": return tableMd(block, ctx) || placeholder(block, ctx);
    case "sheet": {
      const snap = isMap(block.snapshot) ? block.snapshot : {};
      return gfm(snap.head, Array.isArray(snap.rows) ? snap.rows : [], [], ctx) || placeholder(block, ctx);
    }
    case "steps": {
      const steps = (Array.isArray(block.steps) ? block.steps : []).filter(isMap);
      return steps.map((step, i) => {
        const marker = i + 1 + ". ";
        return marker + indent(joined([bold(step.title), ...inside(step, ctx)]), " ".repeat(marker.length)).trimStart();
      }).join("\n\n") || placeholder(block, ctx);
    }
    case "tabs": return joined((Array.isArray(block.tabs) ? block.tabs : []).filter(isMap).flatMap((tab) => [bold(tab.label), ...inside(tab, ctx)])) || placeholder(block, ctx);
    case "columns": return joined((Array.isArray(block.columns) ? block.columns : []).flatMap((column) => chunks(isMap(column) ? column.blocks : column, ctx))) || placeholder(block, ctx);
    case "expandable": return joined([bold(block.summary), ...inside(block, ctx)]) || placeholder(block, ctx);
    case "terminal": return joined([bold(block.title), ...inside(block, ctx), italic(block.footer)]) || placeholder(block, ctx);
    case "section": return joined([bold(block.title), ...inside(block, ctx)]) || placeholder(block, ctx);
    case "card": {
      const slots = isMap(block.slots) ? block.slots : {};
      const title = (Array.isArray(slots.title) ? slots.title : []).map((b) => bold(b && (b.text ?? plainText(b.content))));
      return joined([...title, ...chunks(slots.body, ctx), ...chunks(slots.action, ctx)]) || placeholder(block, ctx);
    }
    case "action": {
      const href = address(block.href, ctx);
      const label = escapeInlineText(oneLine(block.label) || href);
      return href ? "[" + label + "](" + href + ")" : label;
    }
    default:
      if (/^field-/.test(type) || ["composite", "arrayOf", "codelist", "localizedText"].includes(type)) return fieldMd(block);
      return fallback(block, ctx);
  }
}

function noteLine(note, ctx) {
  if (!isMap(note)) return "";
  const lead = oneLine(note.lead);
  const body = inline(note.content ?? note.text, ctx);
  return ["**" + escapeInlineText(oneLine(note.label) || "Note") + ":**", lead ? "*" + escapeInlineText(lead) + "*" : "", body].filter(Boolean).join(" ");
}

// A list item whatever carrier the wire used: an inline array, a string, or a
// map holding `content` or `text`, `checked` and nested lists in `children`.
function listMd(block, ctx) {
  const ordered = block.ordered === true || block.type === "ordered-list";
  const start = Number.isInteger(block.start) ? block.start : 1;
  return (Array.isArray(block.items) ? block.items : []).map((item, i) => {
    const map = isMap(item) ? item : null;
    const marker = ordered ? start + i + ". " : "- ";
    const box = block.task === true ? (map && map.checked === true ? "[x] " : "[ ] ") : "";
    const content = map ? (Array.isArray(map.content) && map.content.length ? map.content : str(map.text)) : item;
    const pad = " ".repeat(marker.length);
    const nested = map ? chunks(map.children, ctx).map((md) => "\n" + indent(md, pad)).join("") : "";
    return marker + box + inline(content, ctx).replace(/\n/g, "\n" + pad) + nested;
  }).join("\n");
}

// ── tables ───────────────────────────────────────────────────────────────────

const rowCells = (row) => (Array.isArray(row) ? row : isMap(row) && Array.isArray(row.cells) ? row.cells : []);
const cellAlign = (cell) => (isMap(cell) && (cell.align === "center" || cell.align === "right") ? cell.align : "");

function cellMd(cell, ctx) {
  const content = isMap(cell) && !cell.type ? cell.content ?? cell.text ?? cell.value : isMap(cell) ? [cell] : cell;
  return inline(typeof content === "number" ? String(content) : content, ctx, "<br>").replace(/\n/g, "<br>");
}

function tableMd(block, ctx) {
  let rows = Array.isArray(block.rows) ? block.rows.slice() : [];
  let head = Array.isArray(block.head) && block.head.length ? block.head : Array.isArray(block.header) && block.header.length ? block.header : null;
  const first = rows[0];
  const headerRow = isMap(first) && (first.header === true || (rowCells(first).length > 0 && rowCells(first).every((c) => isMap(c) && c.header === true)));
  if (!head && rows.length && (block.header === true || headerRow)) head = rowCells(rows.shift());
  const aligns = (head ? rowCells(head) : []).map(cellAlign);
  rows.forEach((row) => rowCells(row).forEach((cell, i) => { if (!aligns[i]) aligns[i] = cellAlign(cell); }));
  return gfm(head, rows, aligns, ctx);
}

// A GFM table. Markdown needs a header row, so a table without one gets an
// empty header.
function gfm(head, rows, aligns, ctx) {
  const body = rows.map((row) => rowCells(row).map((cell) => cellMd(cell, ctx)));
  const top = head ? rowCells(head).map((cell) => cellMd(cell, ctx)) : [];
  const width = Math.max(top.length, ...body.map((row) => row.length), 0);
  if (width === 0) return "";
  const line = (cells) => "| " + Array.from({ length: width }, (_, i) => cells[i] || "").join(" | ") + " |";
  const rule = Array.from({ length: width }, (_, i) => (aligns[i] === "center" ? ":---:" : aligns[i] === "right" ? "---:" : "---"));
  return [line(top), "| " + rule.join(" | ") + " |", ...body.map(line)].join("\n");
}

// ── fields and everything else ───────────────────────────────────────────────

function valueText(value) {
  if (Array.isArray(value)) return value.map(valueText).filter(Boolean).join(", ");
  if (isMap(value)) return Object.keys(value).map((key) => key + ": " + valueText(value[key])).join("; ");
  return oneLine(value);
}

function fieldMd(block) {
  const label = oneLine(block.label) || humanize(block.type.replace(/^field-/, ""));
  const value = valueText(block.value);
  return "**" + escapeInlineText(label) + ":**" + (value ? " " + escapeInlineText(value) + (block.unit ? " " + escapeInlineText(oneLine(block.unit)) : "") : "");
}

function plainText(content) {
  return plain(content, { baseUrl: "" }, false).map((node) => (node.children ? plainText(node.children) : str(node.value))).join("");
}

function placeholder(block, ctx) {
  return "> [" + ctx.placeholder.replace("%{block}", humanize(block.type)) + "]";
}

const WORD_KEYS = ["method", "path", "target", "overline", "label", "title", "name", "prompt", "question", "summary", "caption", "lead", "text", "content", "body", "detail", "description", "preview", "reason", "value", "unit", "note", "legend"];
const SKIP_KEYS = new Set(["id", "type", "kind", "src", "href", "poster", "polyline", "anchor", "source", "sourceDefault", "status", "tone", "layout", "captions", "cells", "spark", "dots", "axes", "points"]);

// The words a block holds, in order: one line per map that has any, then the
// maps and lists inside it.
function words(node, out, depth) {
  if (out.length >= 40 || depth > 6) return;
  if (Array.isArray(node)) {
    const strings = node.length > 0 && node.every((item) => typeof item === "string");
    if (strings) { const line = node.map(oneLine).filter(Boolean).join(", "); if (line) out.push(line); }
    else node.forEach((item) => words(item, out, depth + 1));
    return;
  }
  if (!isMap(node)) return;
  const said = new Set();
  const line = WORD_KEYS.map((key) => {
    const text = oneLine(Array.isArray(node[key]) ? plainText(node[key]) : node[key]);
    if (text) said.add(key);
    return text;
  }).filter(Boolean).join(" — ");
  if (line) out.push(line);
  for (const key of Object.keys(node)) if (!SKIP_KEYS.has(key) && !said.has(key)) words(node[key], out, depth + 1);
}

// A block Markdown has no form for: its child blocks when it holds some, else
// a line naming it, followed by its words.
function fallback(block, ctx) {
  const nested = [block.children, block.blocks].find((list) => Array.isArray(list) && list.some((b) => isMap(b) && typeof b.type === "string"));
  if (nested) return joined(chunks(nested, ctx)) || placeholder(block, ctx);
  const out = [];
  words(block, out, 0);
  return [placeholder(block, ctx), ...out.map((line) => "> " + escapeInlineText(line))].join("\n");
}
