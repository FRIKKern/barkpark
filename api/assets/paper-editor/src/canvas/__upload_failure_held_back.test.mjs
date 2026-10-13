// __upload_failure_held_back.test.mjs — task-797f973032044a56, in a real mounted canvas:
// a pasted picture is not a block until its upload gives it a src. With a throwing
// mediaUploader the node shows the failure and NO bp-canvas-ops carries an image
// block without src (the host used to save one that outlived the error on reload);
// with a working uploader the image is emitted once, with its src.
// Run: node src/canvas/__upload_failure_held_back.test.mjs
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
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
window.URL.createObjectURL ||= () => "blob:preview";
window.URL.revokeObjectURL ||= () => {};

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const BLOCKS = [{ id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] }];

async function mount(uploader) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  canvas.mediaUploader = uploader;
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the canvas editor is mounted");
  return canvas;
}
const imageBlocks = (events) => events.flatMap((ops) => ops).filter((op) => op.block && op.block.type === "image").map((op) => op.block);
const nodeTypes = (editor) => { const t = []; editor.state.doc.forEach((n) => t.push(n.type.name)); return t; };
function paste(canvas) {
  const editor = canvas._editor;
  editor.commands.setTextSelection(editor.state.doc.child(0).nodeSize - 1);
  const file = new window.File(["png"], "photo.png", { type: "image/png" });
  canvas._pasteImageFiles(editor.view, { clipboardData: { files: [file] } });
}

let failures = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS  ${name}`); } catch (error) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${error.message}`); }
}

try {
  {
    const canvas = await mount(async () => { throw new Error("storage is down"); });
    const ops = [];
    canvas.addEventListener("bp-canvas-ops", (e) => ops.push(e.detail.ops));
    paste(canvas);
    await tick(50);
    canvas.flushPendingChanges();
    await tick(400);
    canvas.flushPendingChanges();
    await tick(400);
    check("the failed picture stays in the canvas, saying why", () => {
      assert.ok(nodeTypes(canvas._editor).includes("bpImage"));
      assert.match(canvas.querySelector(".bp-canvas-image-badge")?.textContent || "", /Upload failed: storage is down/);
    });
    check("no bp-canvas-ops carries an image block without a src", () => {
      assert.deepEqual(imageBlocks(ops).filter((b) => !b.src), [], JSON.stringify(ops));
    });
    canvas.closest(".bp-paper-editor").remove();
  }
  {
    const canvas = await mount(async () => ({ url: "/media/files/photo.png" }));
    const ops = [];
    canvas.addEventListener("bp-canvas-ops", (e) => ops.push(e.detail.ops));
    paste(canvas);
    await tick(50);
    canvas.flushPendingChanges();
    await tick(400);
    canvas.flushPendingChanges();
    await tick(400);
    check("an uploaded picture is emitted with its src, and never without one", () => {
      const images = imageBlocks(ops);
      assert.ok(images.some((b) => b.src === "/media/files/photo.png"), JSON.stringify(ops));
      assert.deepEqual(images.filter((b) => !b.src), []);
    });
    canvas.closest(".bp-paper-editor").remove();
  }
} finally {
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nupload failure: all checks passed");
  process.exit(0);
}
