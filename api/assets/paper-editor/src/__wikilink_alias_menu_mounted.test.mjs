// Mounted regression for the one-block <bp-paper-editor> `[[` menu (contract 1.19.0):
// `[[Title|words` searches Title alone, and the pick links the words as an alias.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const key of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) {
  globalThis[key] = window[key];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Element.prototype.scrollIntoView ||= () => {};
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
await import("./index.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const ROWS = [{ title: "Plan", id: "n-plan", type: "note" }, { title: "Planning week", id: "n-week", type: "note" }];

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}

function mount() {
  const host = document.createElement("bp-paper-editor");
  host.block = { id: "p1", type: "paragraph", content: [{ type: "text", value: "Start " }] };
  const asked = [];
  host.wikilinkSource = (q) => { asked.push(q); return ROWS.filter((r) => r.title.toLowerCase().includes(q.toLowerCase())); };
  document.body.appendChild(host);
  const ed = host._editor;
  ed.commands.setTextSelection(ed.state.doc.content.size - 1);
  return { host, ed, asked };
}
function type(ed, text) {
  for (const char of text) {
    const { from, to } = ed.view.state.selection;
    ed.view.dispatch(ed.view.state.tr.insertText(char, from, to));
  }
}
const links = (ed) => {
  const out = [];
  ed.state.doc.descendants((n) => {
    const m = n.isText && n.marks.find((k) => k.type.name === "wikilink");
    if (m) out.push({ words: n.text, target: m.attrs.target, docId: m.attrs.docId, alias: m.attrs.alias });
  });
  return out;
};
const enter = (ed) => ed.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

await check("one-block [[ menu: [[plan|the plan searches plan alone, and the pick links the words as an alias", async () => {
  const { host, ed, asked } = mount();
  type(ed, "[[plan|the plan");
  await tick(10);
  assert.equal(asked.at(-1), "plan");
  assert.ok(asked.every((q) => !q.includes("|")), asked.join(", "));
  enter(ed);
  await tick(10);
  assert.deepEqual(links(ed), [{ words: "the plan", target: "Plan", docId: "n-plan", alias: "the plan" }]);
  assert.equal(ed.state.doc.textContent, "Start the plan ");
  host.remove();
});

await check("one-block [[ menu: no title before the | searches nothing; [[plan and [[plan| pick with no alias", async () => {
  const { host, ed, asked } = mount();
  type(ed, "[[");
  await tick(10);
  asked.length = 0;
  type(ed, "|plan");
  await tick(10);
  assert.deepEqual(asked, []);
  host.remove();
  for (const typed of ["[[plan", "[[plan|"]) {
    const again = mount();
    type(again.ed, typed);
    await tick(10);
    enter(again.ed);
    await tick(10);
    assert.deepEqual(links(again.ed), [{ words: "Plan", target: "Plan", docId: "n-plan", alias: null }], typed);
    again.host.remove();
  }
});

dom.window.close();
if (failures > 0) {
  console.log(`\n${failures} failing check(s)`);
  process.exit(1);
}
console.log("\none-block wikilink alias menu mounted: all checks passed");
process.exit(0);
