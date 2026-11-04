// Mounted jsdom coverage proves the real schema retains the source carrier and
// the existing opaque NodeView exposes no stale-save controls. Not browser proof.
const { JSDOM } = await import("jsdom");
const { window } = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
globalThis.window = window;
globalThis.document = window.document;
for (const name of ["customElements", "CustomEvent", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
const { Editor } = await import("@tiptap/core");
const { default: StarterKit } = await import("@tiptap/starter-kit");
const { Note } = await import("./canvas/note-node.js");
const { Opaque } = await import("./canvas/opaque-node.js");
const { runToTiptap, runToOps, docToBlocks } = await import("./canvas/run-convert.js");
const { default: assert } = await import("node:assert/strict");
const { readFileSync } = await import("node:fs");
const { applyOps, check } = await import("./smoke/harness.mjs");
await import("./canvas/index.js");
const tick = () => new Promise(resolve => setTimeout(resolve, 20));
const fieldValue = (field, value) => {
  if ("value" in field) field.value = value;
  else field.textContent = value;
};
const readField = field => "value" in field ? field.value : field.textContent;
const escapeHTML = value => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
const noteHTML = node => {
  const label = escapeHTML(node.attrs.label || "");
  const lead = String(node.attrs.lead || "").trim();
  const leadHTML = lead ? `<b>${escapeHTML(lead)}</b> ` : "";
  return `<div class="bp-note"><span class="bp-note__k">${label}</span><div class="bp-note__d">${leadHTML}${escapeHTML(node.textContent || "")}</div></div>`;
};
const paintNotes = (root, editor, blocks) => {
  const sources = new Map(blocks.map(block => [block.id, block]));
  editor.state.doc.forEach(node => {
    if (node.type.name !== "note") return;
    const id = node.attrs.bpId || "";
    const host = [...root.querySelectorAll("[data-bp-fleet-id]")]
      .find(element => element.getAttribute("data-bp-fleet-id") === id);
    const hole = host?.querySelector("[data-bp-fleet-body]");
    if (!hole) return;
    const sourceBlock = sources.get(id) || docToBlocks({ type: "doc", content: [node.toJSON()] })[0];
    const html = noteHTML(node);
    if (hole.dispatchEvent(new CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock }, cancelable: true })))
      hole.innerHTML = html;
  });
};
const mountCanvas = blocks => {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = blocks;
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail));
  document.body.appendChild(canvas);
  paintNotes(canvas, canvas._editor, blocks);
  return { canvas, batches };
};
async function mountedCheck(name, fn) {
  try { await fn(); check(name, () => {}); }
  catch (error) { check(name, () => { throw error; }); }
}
const original = {
  id: "mounted-note", type: "note", label: "divergent", custom: { keep: [null, 7] },
  slots: {
    label: [{ id: "label-p", type: "paragraph", meta: true, content: [
      { type: "strong", extra: "wrapper", children: [{ type: "text", value: "Shown", extra: "leaf" }] },
    ] }],
    body: [{ type: "paragraph", content: [{ type: "text", value: "Body", custom: true }] }],
    unknown: [{ extra: "keep" }],
  },
};
function mount(block) {
  const element = document.createElement("div");
  document.body.appendChild(element);
  const editor = new Editor({ element, extensions: [StarterKit.configure({ trailingNode: false }), Note, Opaque], content: runToTiptap([block]) });
  paintNotes(element, editor, [block]);
  return editor;
}

export {
  window,
  runToTiptap,
  runToOps,
  docToBlocks,
  assert,
  readFileSync,
  applyOps,
  check,
  tick,
  fieldValue,
  readField,
  paintNotes,
  mountCanvas,
  mountedCheck,
  original,
  mount,
};
