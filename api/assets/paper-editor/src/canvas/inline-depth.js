// inline-depth.js — how the rich editor carries a prose block whose inline nests
// past the depth limit (task-11bbe4b4ae8c85f4).
//
// The rule every Barkpark reader shares (api/lib/barkpark/portable_doc/render/
// inline_depth.ex, internal/pdrender/inline_depth.go, js/packages/react
// src/inline-depth.ts, apps/mobile inline-depth.ts):
//
//   - A wrapper (a node holding `children`, or a bare list) is drawn while its inline
//     depth is under MAX_INLINE_DEPTH (100). A text at depth d with k marks draws all
//     of them when d + k <= 100.
//   - A wrapper at depth 100 or deeper is not drawn. The words under it are, flat and
//     in order, then one space and the notice. A text with more marks than fit keeps
//     its word, then the notice.
//   - Words are read by a loop, never by recursion, down to inline depth
//     MAX_WORD_DEPTH (1000).
//
// The editor's inline nodes cannot hold such a block (TipTap folds the marks and the
// notice must never enter the doc), so run-project.js carries it whole (bpOpaque) and
// opaque-node.js shows it with inlineDepthReadonlyView: its words, with the notice
// after each part past the limit; it takes no typing. Nothing is sent for it, so
// saving the Paper writes the block as it was stored.
//
// The carry is a copy of the block made by a loop. A stored block is at most 1000
// JSON levels deep (Validate.max_value_depth), well inside MAX_CARRY_DEPTH, so its
// copy is exact. A block deeper than MAX_CARRY_DEPTH (only an unstored input can be)
// is cut there: JSON.stringify and structuredClone cannot hold it at all.

import { t } from "../i18n.js";

export const MAX_INLINE_DEPTH = 100;
export const MAX_WORD_DEPTH = 1000;
// MAX_CARRY_DEPTH, written as its sum:
//   2 x MAX_WORD_DEPTH (1000)     2000  inline levels, an object and its children list each
// + 2 x MAX_INLINE_DEPTH (100)     200  levels for the block's own lists and items
// + 16                              16  room
// = 2216
// It is not Go's maxJSONDepth (2416, which counts four JSON levels per block level for
// nested tabs, steps and list items): the carry copies one stored block, and a stored
// block is at most 1000 JSON levels (Validate.max_value_depth), so 2216 already copies it
// exact. api/test/support/fixtures/portable-doc-slot-depth.json holds both sums, and
// __inline_depth_notice.test.mjs fails if this stops equalling its row.
export const MAX_CARRY_DEPTH = 2 * MAX_WORD_DEPTH + 2 * MAX_INLINE_DEPTH + 16;

const NOTICE = "Nested too deep to show";

const isRecord = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isWrapper = (n) => Array.isArray(n) || (isRecord(n) && "children" in n);
const leafText = (v) => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "");
const marksOf = (n) => (Array.isArray(n.marks) ? n.marks.length : 0);

// The inline runs a prose block holds, each read from inline depth 0: `content`, or
// `text` when it is a list of runs; for a list, each item and each nested item.
function inlineRoots(block) {
  const roots = [];
  if (!isRecord(block)) return roots;
  for (const key of ["content", "text", "cite"]) if (Array.isArray(block[key])) roots.push(block[key]);
  const items = Array.isArray(block.items) ? [...block.items] : [];
  while (items.length) {
    const item = items.pop();
    if (Array.isArray(item)) roots.push(item);
    else if (isRecord(item)) {
      for (const key of ["content", "text"]) if (Array.isArray(item[key])) roots.push(item[key]);
      if (Array.isArray(item.children)) items.push(...item.children);
    }
  }
  return roots;
}

// Whether any inline run of the block nests past the depth limit. A loop; it stops at
// the first part past the limit, so it reads no deeper than MAX_INLINE_DEPTH + 1.
export function inlineTooDeep(block) {
  const stack = inlineRoots(block).flatMap((run) => run.map((n) => [n, 0]));
  while (stack.length) {
    const [n, d] = stack.pop();
    if (isWrapper(n)) {
      if (d >= MAX_INLINE_DEPTH) return true;
      const kids = Array.isArray(n) ? n : Array.isArray(n.children) ? n.children : [];
      for (const kid of kids) stack.push([kid, d + 1]);
    } else if (isRecord(n) && d + marksOf(n) > MAX_INLINE_DEPTH) return true;
  }
  return false;
}

// A copy of `value` made by a loop; anything deeper than `limit` JSON levels is cut
// to null. Exact for a value within the limit.
export function boundedClone(value, limit = MAX_CARRY_DEPTH) {
  const holder = [null];
  const stack = [[holder, 0, value, 1]];
  while (stack.length) {
    const [into, key, v, depth] = stack.pop();
    if (v === null || typeof v !== "object") { into[key] = v; continue; }
    if (depth > limit) { into[key] = null; continue; }
    const copy = Array.isArray(v) ? new Array(v.length) : {};
    into[key] = copy;
    // Pushed last key first, so each key is copied, and inserted, in its own order.
    const keys = Object.keys(v);
    for (let i = keys.length - 1; i >= 0; i--) {
      const k = keys[i];
      stack.push([copy, Array.isArray(v) ? Number(k) : k, v[k], depth + 1]);
    }
  }
  return holder[0];
}

const NOTICE_MARK = Symbol("notice");

// The words an inline run shows by the shared rule, marks dropped: every word, with
// the notice after each part past the limit. A loop.
export function inlineDepthText(run, notice = t(NOTICE)) {
  const out = [];
  const stack = (Array.isArray(run) ? run : [run]).map((n) => [n, 0, false]).reverse();
  while (stack.length) {
    const [n, d, cut] = stack.pop();
    // The notice after a cut part: one space after its words, or alone when it has none.
    // (`d` here is where the cut part's words start in `out`.)
    if (n === NOTICE_MARK) { out.push(out.slice(d).join("") !== "" ? ` ${notice}` : notice); continue; }
    if (cut && d >= MAX_WORD_DEPTH) continue;
    if (typeof n === "string" || typeof n === "number") { out.push(String(n)); continue; }
    if (isWrapper(n)) {
      const kids = Array.isArray(n) ? n : Array.isArray(n.children) ? n.children : [];
      const cutHere = !cut && d >= MAX_INLINE_DEPTH;
      if (cutHere) stack.push([NOTICE_MARK, out.length, false]);
      for (let i = kids.length - 1; i >= 0; i--) stack.push([kids[i], d + 1, cut || cutHere]);
      continue;
    }
    if (isRecord(n)) {
      const words = leafText(n.value) || leafText(n.text);
      out.push(words);
      if (!cut && d + marksOf(n) > MAX_INLINE_DEPTH) out.push(` ${notice}`);
    }
  }
  return out.join("");
}

// The lines a carried block shows: its content (or text), its cite, and each list
// item, nested items after their parent.
function blockLines(block) {
  const lines = [];
  const run = Array.isArray(block.content) && block.content.length > 0 ? block.content : block.text;
  if (run != null && run !== "") lines.push(inlineDepthText(run));
  if (Array.isArray(block.cite) || typeof block.cite === "string") lines.push(inlineDepthText(block.cite));
  const items = Array.isArray(block.items) ? block.items.map((item) => item).reverse() : [];
  while (items.length) {
    const item = items.pop();
    if (Array.isArray(item) || typeof item === "string") { lines.push(inlineDepthText(item)); continue; }
    if (!isRecord(item)) continue;
    const own = Array.isArray(item.content) && item.content.length > 0 ? item.content : item.text;
    if (own != null && own !== "") lines.push(inlineDepthText(own));
    if (Array.isArray(item.children)) for (let i = item.children.length - 1; i >= 0; i--) items.push(item.children[i]);
  }
  return lines;
}

function el(tag, text) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  return node;
}

function paint(dom, block) {
  const words = el("div");
  words.setAttribute("data-bp-inline-depth-words", "");
  for (const line of blockLines(block)) words.appendChild(el("p", line));
  dom.setAttribute("data-bp-inline-depth-readonly", block.id == null ? "" : String(block.id));
  dom.replaceChildren(words);
}

// The node view for a carried prose block that nests too deep; `nodeName` is the
// carry's node name (bpOpaque), passed in by opaque-node.js.
export function inlineDepthReadonlyView(node, nodeName) {
  const dom = document.createElement("div");
  dom.className = "bp-canvas-readonly bp-canvas-inline-depth-readonly";
  dom.setAttribute("data-bp-opaque", "");
  dom.setAttribute("contenteditable", "false");
  dom.setAttribute("data-test-id", "paper-opaque-inline-depth");
  paint(dom, node.attrs.bpBlock || {});
  return {
    dom,
    update(updated) {
      if (updated.type.name !== nodeName || !inlineTooDeep(updated.attrs.bpBlock)) return false;
      paint(dom, updated.attrs.bpBlock || {});
      return true;
    },
    stopEvent: () => true,
    ignoreMutation: () => true,
  };
}
