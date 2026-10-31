import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { MISSING, PACK, cli, diffShapes, shapeOf } from "../../../priv/portable_doc/conformance/conformance.mjs";
import { runToTiptap } from "./canvas/run-convert.js";

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"])
  globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const fragments = JSON.parse(readFileSync(join(PACK, "fragments.json"), "utf8"));
const PLUMBING_ATTRS = ["contenteditable", "draggable", "spellcheck", "tabindex", "data-bp-id", "data-bp-type", "data-test-id"];
const CHROME = ".ProseMirror-trailingBreak, .ProseMirror-separator, .ProseMirror-gapcursor, .bp-paper-contextual-controls";

function paint(canvas, block) {
  let hostPainted = false;
  for (const hole of canvas.querySelectorAll("[data-bp-fleet-body]")) {
    const html = fragments[block.type];
    if (hole.dispatchEvent(new CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock: block }, cancelable: true }))) {
      hole.innerHTML = html;
      hostPainted = true;
    }
  }
  return hostPainted;
}

function unwrapFleet(root) {
  for (const atom of root.querySelectorAll("[data-bp-fleet-id]")) atom.replaceWith(...atom.querySelector("[data-bp-fleet-body]").childNodes);
}

function strip(root) {
  root.querySelectorAll(CHROME).forEach((el) => el.remove());
  for (const el of root.querySelectorAll("*")) {
    PLUMBING_ATTRS.forEach((a) => el.removeAttribute(a));
    for (const c of [...el.classList]) if (c.startsWith("ProseMirror") || c.startsWith("bp-canvas-")) el.classList.remove(c);
    if (el.getAttribute("class") === "") el.removeAttribute("class");
  }
}

function fragment(html) {
  const t = document.createElement("template");
  t.innerHTML = html;
  return t.content.childNodes;
}

async function judge(golden) {
  const { content } = runToTiptap([golden.input]);
  if (content.length > 0 && content.every((n) => n.type === "bpOpaque")) return MISSING;
  const block = { ...golden.input, id: "conformance" };
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = [block];
  document.body.append(canvas);
  try {
    await new Promise((r) => setTimeout(r, 0));
    const pm = canvas.querySelector(".ProseMirror");
    if (!pm) return [`canvas mounted no editor for ${golden.type}`];
    const hostPainted = paint(canvas, block);
    await new Promise((r) => setTimeout(r, 0));
    const root = pm.cloneNode(true);
    unwrapFleet(root);
    strip(root);
    const diff = diffShapes(shapeOf(root.childNodes), shapeOf(fragment(golden.expectedHtml)));
    return hostPainted ? { via: "host-paint", diff } : diff;
  } finally {
    canvas.remove();
  }
}

await cli({ renderer: "editor-canvas", compare: "dom", judge });
window.close();
