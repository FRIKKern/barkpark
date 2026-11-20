// callout-readonly-view.js — how the rich editor shows a callout that holds a body
// (task-c6355c4cb9cb7707).
//
// A callout's words are its content, then every block of its body, in that order. The
// editable callout node holds one inline run, so a callout with a body is carried
// whole (run-content-codecs.js calloutBlockToNode → bpOpaque) and opaque-node.js hands
// it to this view: the callout's tone card with its title, its content and every body
// block as plain words, and one line saying it is read-only. The view never writes;
// the block rides verbatim on bpBlock, so nothing is sent for it. Editing a body in
// place is task-7150941fd03ca94a.

import { t } from "../i18n.js";
import { calloutToneClass } from "./callout-node.js";

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

function el(tag, text) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  return node;
}

function listItemWords(item) {
  if (Array.isArray(item) || typeof item === "string") return inlineWords(item);
  if (!item || typeof item !== "object") return "";
  return inlineWords(item.content ?? item.text ?? item.children);
}

// One body block as plain words: a list as its items, code as its source, a callout
// as its own words, anything else as its content or text.
function bodyBlockView(block) {
  if (!block || typeof block !== "object") return null;
  if (block.type === "callout") return calloutWordsView(block);
  if (block.type === "list" || block.type === "ordered-list") {
    const list = el(block.type === "ordered-list" || block.ordered === true ? "ol" : "ul");
    for (const item of Array.isArray(block.items) ? block.items : []) list.appendChild(el("li", listItemWords(item)));
    return list;
  }
  if (block.type === "code") {
    const source = [block.value, block.code, block.text].find((v) => typeof v === "string");
    return el("pre", source ?? inlineWords(block.content));
  }
  const words = inlineWords(block.content ?? block.text ?? block.value);
  return el("p", words !== "" ? words : `↪ ${block.type || "block"}`);
}

// The callout's words: title and content on the first line, then every body block.
function calloutWordsView(block) {
  const words = el("div");
  words.setAttribute("data-bp-callout-words", "");
  const head = el("p");
  if (typeof block.title === "string" && block.title !== "") {
    head.appendChild(el("strong", block.title));
    head.appendChild(document.createTextNode(" "));
  }
  head.appendChild(document.createTextNode(inlineWords(block.content ?? block.text)));
  if (head.textContent.trim() !== "") words.appendChild(head);
  const body = block.slots && Array.isArray(block.slots.body) ? block.slots.body : [];
  for (const child of body) {
    const view = bodyBlockView(child);
    if (view) words.appendChild(view);
  }
  return words;
}

function paint(dom, block) {
  dom.className = `bp-canvas-callout bp-callout bp-callout--${calloutToneClass(block.tone || "info")} bp-canvas-callout-readonly`;
  dom.setAttribute("data-bp-callout-readonly", block.id == null ? "" : String(block.id));
  const note = el("p", t("Read only: this callout has a body, which the editor cannot edit yet."));
  note.className = "bp-canvas-callout-readonly-note";
  note.setAttribute("data-bp-callout-readonly-note", "");
  dom.replaceChildren(calloutWordsView(block), note);
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
