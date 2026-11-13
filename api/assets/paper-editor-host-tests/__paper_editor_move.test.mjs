// __paper_editor_move.test.mjs — task-fe3f7a8fbe7a7858: the Beta editor's
// block is moved in the page (LiveView's morphdom appends a moved node again;
// the narrow width bucket moves the pane). A moved custom element is
// disconnected and connected again. `disconnectedCallback` destroyed TipTap,
// and `connectedCallback` mounted a new one from `data-block`, which sits
// frozen inside phx-update="ignore": the editor showed the block as first
// drawn, and the next key saved that over the stored text.
//
// Run: node ../paper-editor-host-tests/__paper_editor_move.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../paper-editor/src/index.js");
const { DEBOUNCE_MS } = await import("../paper-editor/src/contract.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

let n = 0;
function mount() {
  n += 1;
  const from = document.createElement("section");
  const to = document.createElement("section");
  document.body.append(from, to);
  const el = document.createElement("bp-paper-editor");
  el.setAttribute("data-block", JSON.stringify({ id: `b${n}`, type: "paragraph", content: [{ type: "text", value: "Beta para" }] }));
  from.appendChild(el);
  const ops = [];
  el.addEventListener("bp-op", (e) => ops.push(JSON.stringify(e.detail)));
  return { el, from, to, ops };
}

// Types at the end of the paragraph, as a key press does.
function type(el, text) {
  const tiptap = el._editor;
  tiptap.view.dispatch(tiptap.state.tr.insertText(text, tiptap.state.doc.content.size - 1));
}

const shown = (el) => el._editor && el._editor.getText();

await check("typing, a move, then typing again: the editor and the next save hold both edits", async () => {
  const { el, to, ops } = mount();
  type(el, " BX");
  await tick(DEBOUNCE_MS + 50);
  assert.equal(ops.length, 1);
  assert.match(ops[0], /Beta para BX/);

  to.appendChild(el); // a move: disconnected, then connected again
  await tick();
  assert.equal(shown(el), "Beta para BX", "the editor still shows the typed text");

  type(el, " BY");
  await tick(DEBOUNCE_MS + 50);
  assert.equal(ops.length, 2);
  assert.match(ops[1], /Beta para BX BY/);
});

await check("an edit still waiting on its debounce when the move comes is saved", async () => {
  const { el, to, ops } = mount();
  type(el, " BZ");
  to.appendChild(el);
  await tick(DEBOUNCE_MS + 50);
  assert.equal(ops.length, 1, "the pending edit is sent after the move");
  assert.match(ops[0], /Beta para BZ/);
});

await check("a move keeps one editor body, not two (control)", async () => {
  const { el, from, to } = mount();
  to.appendChild(el);
  from.appendChild(el);
  await tick();
  assert.equal(el.querySelectorAll(".bp-paper-editor-body").length, 1);
});

await check("an editor taken out of the page is torn down and sends nothing (control)", async () => {
  const { el, ops } = mount();
  type(el, " gone");
  el.remove();
  await tick(DEBOUNCE_MS + 50);
  assert.equal(el._editor, null, "the editor is destroyed");
  assert.equal(ops.length, 0, "the pending edit of a removed editor is not sent");
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
