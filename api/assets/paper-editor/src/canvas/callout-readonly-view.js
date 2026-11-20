// callout-readonly-view.js — how the rich editor shows a callout that holds a body
// (task-c6355c4cb9cb7707).
//
// markdown/callout-words.js holds what a callout's words are. The editable callout
// node holds one inline run, so a callout with a body is carried whole
// (run-content-codecs.js calloutBlockToNode → bpOpaque) and opaque-node.js hands it to
// this view: the callout's tone card with its title and content, then each body block,
// then one line saying it is read-only. Each body block shows either every word it
// holds or one line naming its kind ("↪ table"), never a part of itself. Only the
// kinds in DRAWN below are drawn; every other kind, and any kind added later, shows
// its marker. Drawing the other kinds is task-1bbcad33a02eac6a. Tone and heading level
// are not words and are not shown here. The view never writes; the block rides
// verbatim on bpBlock, so nothing is sent for it. Editing a body in place is
// task-7150941fd03ca94a.

import { t } from "../i18n.js";
import { calloutToneClass } from "./callout-node.js";
import { calloutBodyBlocks } from "../markdown/callout-words.js";
import { readerInline } from "../markdown/reader-inline.js";

// Plain words of an inline array (marks dropped), or of a string.
function inlineWords(value) {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value.map((run) => {
    if (typeof run === "string") return run;
    if (!run || typeof run !== "object") return "";
    if (typeof run.value === "string") return run.value;
    if (typeof run.text === "string") return run.text;
    return inlineWords(run.children);
  }).join("");
}

// The reader's choice for a run of words: `content` when it holds runs, else `text`.
function contentElseText(holder) {
  return Array.isArray(holder.content) && holder.content.length > 0 ? holder.content : holder.text;
}

function el(tag, text) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  return node;
}

// A list item: its own words, then each block nested in it, drawn as a body block.
function listItemView(item) {
  const li = el("li");
  if (Array.isArray(item) || typeof item === "string") {
    li.textContent = inlineWords(item);
    return li;
  }
  if (!item || typeof item !== "object") return li;
  const words = inlineWords(contentElseText(item));
  if (words !== "") li.appendChild(el("span", words));
  for (const child of Array.isArray(item.children) ? item.children : []) li.appendChild(bodyBlockView(child));
  return li;
}

function listView(block) {
  const ordered = block.type === "ordered-list" || block.ordered === true;
  const list = el(ordered ? "ol" : "ul");
  for (const item of Array.isArray(block.items) ? block.items : []) list.appendChild(listItemView(item));
  return list;
}

// The kinds drawn with every word they hold. A kind not here shows its marker.
const DRAWN = {
  paragraph: (block) => el("p", inlineWords(readerInline(block))),
  heading: (block) => el("p", inlineWords(readerInline(block))),
  code: (block) => el("pre", [block.value, block.code, block.text].find((v) => typeof v === "string") ?? ""),
  list: listView,
  "ordered-list": listView,
  blockquote: (block) => {
    const quote = el("blockquote");
    quote.appendChild(el("p", inlineWords(readerInline(block))));
    const cite = inlineWords(block.cite);
    if (cite !== "") quote.appendChild(el("cite", cite));
    return quote;
  },
  callout: (block) => calloutWordsView(block),
};

// One body block: drawn whole when its kind is in DRAWN, else its marker.
function bodyBlockView(block) {
  const type = block && typeof block === "object" && typeof block.type === "string" ? block.type : "block";
  const draw = Object.prototype.hasOwnProperty.call(DRAWN, type) ? DRAWN[type] : null;
  const view = draw ? draw(block) : el("p", `↪ ${type}`);
  view.setAttribute("data-bp-callout-body-block", type);
  return view;
}

// The callout's words: title and content on the first line, then every body block.
function calloutWordsView(block) {
  const words = el("div");
  const head = el("p");
  if (typeof block.title === "string" && block.title !== "") {
    head.appendChild(el("strong", block.title));
    head.appendChild(document.createTextNode(" "));
  }
  head.appendChild(document.createTextNode(inlineWords(contentElseText(block))));
  if (head.textContent.trim() !== "") words.appendChild(head);
  for (const child of calloutBodyBlocks(block)) words.appendChild(bodyBlockView(child));
  return words;
}

function paint(dom, block) {
  dom.className = `bp-canvas-callout bp-callout bp-callout--${calloutToneClass(block.tone || "info")} bp-canvas-callout-readonly`;
  dom.setAttribute("data-bp-callout-readonly", block.id == null ? "" : String(block.id));
  const note = el("p", t("Read only: this callout has a body, which the editor cannot edit yet."));
  note.className = "bp-canvas-callout-readonly-note";
  note.setAttribute("data-bp-callout-readonly-note", "");
  const words = calloutWordsView(block);
  words.setAttribute("data-bp-callout-words", "");
  dom.replaceChildren(words, note);
}

// The node view for a carried callout with a body; `nodeName` is the carry's node
// name (bpOpaque), passed in by opaque-node.js.
export function calloutReadonlyView(node, nodeName) {
  const dom = document.createElement("div");
  dom.setAttribute("data-bp-opaque", "");
  dom.setAttribute("data-bp-type", "callout");
  dom.setAttribute("contenteditable", "false");
  dom.setAttribute("data-test-id", "paper-opaque-callout");
  paint(dom, node.attrs.bpBlock || {});
  return {
    dom,
    update(updated) {
      const block = updated.attrs && updated.attrs.bpBlock;
      if (updated.type.name !== nodeName || (updated.attrs.bpType || (block && block.type)) !== "callout") return false;
      paint(dom, updated.attrs.bpBlock || {});
      return true;
    },
    stopEvent: () => true,
    ignoreMutation: () => true,
  };
}
