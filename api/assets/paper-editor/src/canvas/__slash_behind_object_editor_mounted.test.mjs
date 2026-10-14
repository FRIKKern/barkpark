// __slash_behind_object_editor_mounted.test.mjs — after a slash pick of a declared
// object, its "/" line stays in the doc until the editor answers. A doc update while
// the editor is open (the save echo stamping ids) must not reopen the slash menu
// behind it — neither behind the canvas's popover nor behind a host editor
// (editBlockObject). Seen live on the studio's callout modal (task-60794476865ddb5f).
// Run: node src/canvas/__slash_behind_object_editor_mounted.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement",
  "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Option", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const VOCAB = {
  styles: ["normal"],
  of: [{ name: "factBox", title: "Faktaboks", fields: [{ name: "body", title: "Body", type: "text" }] }],
};
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro." }] },
  { id: "p-end", type: "paragraph", content: [{ type: "text", value: "End" }] },
];
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
const slashOpen = (canvas) => !!(canvas._slash && canvas._slash.isOpen());

try {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  document.body.appendChild(canvas);
  await tick(350);
  const editor = canvas._editor;
  const endOf = (id) => canvas._topLevelPos(id) + editor.state.doc.nodeAt(canvas._topLevelPos(id)).nodeSize - 1;
  // An update elsewhere in the doc, the caret left where it was (as an echo's id stamp).
  const touch = () => {
    const pos = canvas._topLevelPos("p1") + 1;
    const tr = editor.state.tr.insertText("x", pos);
    editor.view.dispatch(tr.setSelection(editor.state.selection.map(tr.doc, tr.mapping)));
  };
  const slashLine = () => {
    editor.commands.setTextSelection(endOf("p-end"));
    editor.commands.splitBlock();
    editor.commands.insertContent("/fakt");
  };

  await check("behind the popover: an update does not reopen the slash menu", async () => {
    slashLine();
    assert.ok(slashOpen(canvas), "the slash menu opened on '/fakt'");
    canvas._chooseSlash({ group: "Blocks", type: "factBox", label: "Faktaboks", object: true });
    assert.ok(canvas.inlineObjectDialog().isOpen(), "the popover is open");
    assert.equal(slashOpen(canvas), false);
    touch();
    await tick(20);
    assert.equal(slashOpen(canvas), false, "still closed after the update");
    canvas.inlineObjectDialog().close();
  });

  await check("behind a host editor: an update does not reopen it either", async () => {
    let answer;
    canvas.editBlockObject = () => new Promise((resolve) => { answer = resolve; });
    slashLine();
    assert.ok(slashOpen(canvas), "the slash menu opened on '/fakt'");
    canvas._chooseSlash({ group: "Blocks", type: "factBox", label: "Faktaboks", object: true });
    await tick(10);
    assert.ok(canvas.inlineObjectDialog().isOpen(), "the host editor is asked");
    touch();
    await tick(20);
    assert.equal(slashOpen(canvas), false, "no slash menu behind the host editor");
    answer({ body: "New fact." });
    await tick(20);
    assert.equal(slashOpen(canvas), false, "and none after the insert");
    canvas.editBlockObject = null;
  });

  await check("with no editor open, '/' still opens the menu", () => {
    editor.commands.setTextSelection(endOf("p1"));
    editor.commands.splitBlock();
    editor.commands.insertContent("/");
    assert.ok(slashOpen(canvas));
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nslash behind object editor mounted: all checks passed");
  process.exit(0);
}
