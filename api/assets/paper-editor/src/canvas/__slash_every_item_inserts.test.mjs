// Mounted sweep (task-d170de40027ea448): every slash-menu item inserts a block in a
// plain embedder.
//
// Found by the barkpark-studio slash sweep: in a host that saves `bp-canvas-ops`
// over HTTP (EMBED-CONTRACT "an HTTP host"), Terminal and Stage removed the "/"
// line and inserted nothing. The canvas handed them to the host as
// `bp-server-insert`, which only Barkpark's own LiveView hook answers; that hook
// marks its editor `data-server-insert`. Without the mark, the canvas inserts the
// node itself and the insert rides the next ops batch, as image and equation did.
//
// The sweep picks every row the "/" menu offers, so a new item that inserts
// nothing reds here too.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
globalThis.fetch = async () => ({ ok: true, json: async () => ({ documents: [] }) });
window.fetch = globalThis.fetch;
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const BLOCKS = [
  { id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] },
  { id: "p-b", type: "paragraph", content: [{ type: "text", value: "Beta" }] },
];

async function mount() {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  document.body.appendChild(canvas);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the TipTap canvas editor is mounted");
  return canvas;
}

function openSlash(canvas) {
  const editor = canvas._editor;
  const first = editor.state.doc.child(0);
  editor.chain().focus().setTextSelection(first.nodeSize - 1).splitBlock().insertContent("/").run();
  return canvas._slash && canvas._slash.isOpen() ? canvas._slash._items : [];
}

const probe = await mount();
const rows = openSlash(probe).map((item) => ({ ...item }));
probe.remove();

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${error.message}`);
  }
}

try {
  check("the slash menu offers its rows", () => assert.ok(rows.length >= 40, `${rows.length} rows`));

  for (const [i, wanted] of rows.entries()) {
    const label = `${wanted.label || wanted.title || wanted.type} (${wanted.type})`;
    const canvas = await mount();
    const editor = canvas._editor;
    const ops = [];
    const asks = [];
    canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...e.detail.ops));
    canvas.addEventListener("bp-server-insert", (e) => asks.push(e.detail));
    const row = openSlash(canvas)[i];
    canvas._chooseSlash(row);
    canvas.flushPendingChanges();
    await tick(350);

    check(`/${label} inserts a block the ops batch carries`, () => {
      assert.equal(row.type, wanted.type, "the same row");
      assert.deepEqual(asks, [], "no request to a host that builds nothing");
      assert.ok(!editor.state.doc.textContent.includes("/"), "the slash line is gone");
      const known = new Set(BLOCKS.map((block) => block.id));
      const added = ops.filter((op) => op.block && !known.has(op.block.id));
      assert.ok(added.length > 0, `an op carries the new block (ops: ${ops.map((op) => op.op || op.type).join(",") || "none"})`);
      if (wanted.type === "terminal" || wanted.type === "stage") {
        assert.ok(added.some((op) => op.block.type === wanted.type), `the batch carries a ${wanted.type} block`);
      }
    });
    canvas.remove();
  }
} finally {
  dom.window.close();
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log(`\nslash_every_item_inserts: all ${rows.length} slash items insert a block in a plain embedder`);
process.exit(0);
