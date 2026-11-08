// Real-Chrome regression for the two reader-shaped editable rows in this lane.
// Run: BP_REQUIRE_CHROME=1 node src/__diff_note_keys.mjs
// It builds the package into a temp folder and serves that build.

import { createServer } from "node:http";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildLocal } from "../scripts/build-local.mjs";
import { launchChrome, evaluate, waitFor } from "../hosts/browser.mjs";

const ASSETS = mkdtempSync(join(tmpdir(), "bp-diff-note-"));
process.on("exit", () => rmSync(ASSETS, { recursive: true, force: true }));
await buildLocal({ outDir: ASSETS, logLevel: "warning" });
const PAGE = `<!doctype html><html><head><meta charset="utf-8">
<script>window.BP_PAPER_EDITOR_NO_INJECT = true;</script>
<link rel="stylesheet" href="/bp-paper-editor.css"></head><body>
<bp-paper-canvas id="canvas"></bp-paper-canvas>
<script src="/bp-paper-editor.bundle.js"></script>
<script>
const canvas = document.getElementById("canvas");
canvas.acknowledgedSaves = true;
canvas.addEventListener("bp-canvas-ops", event => canvas.acknowledgeOps(event.detail.seq, true));
const esc = value => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
window.mountDiff = () => {
  canvas.blocks = [{ id: "d", type: "diff", diff: "diff --git a/lib/a.ex b/lib/a.ex\\nindex 1..2 100644\\n--- a/lib/a.ex\\n+++ b/lib/a.ex\\n@@ -1,2 +1,2 @@\\n context\\n-old line\\n+new line" }];
  const html = '<div class="bp-diff text-xs"><div class="text-dim"><span>+1</span> <span>−1</span></div>' +
    '<div style="font-weight: 600;">lib/a.ex</div><div style="white-space: pre-wrap;">&nbsp;&nbsp;@@ -1,2 +1,2 @@</div>' +
    '<div style="white-space: pre-wrap;">&nbsp;&nbsp;context</div><div style="white-space: pre-wrap;">- old line</div>' +
    '<div style="white-space: pre-wrap;">+ new line</div></div>';
  const hole = canvas.querySelector("[data-bp-fleet-body]");
  hole.dispatchEvent(new CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock: canvas.blocks[0] }, cancelable: true }));
};
window.mountNote = () => {
  const blocks = [
    { id: "p1", type: "paragraph", content: [{ type: "text", value: "Before" }] },
    { id: "n", type: "note", label: "Note", lead: "Bold", text: "Body text" },
    { id: "p2", type: "paragraph", content: [{ type: "text", value: "After" }] },
  ];
  canvas.blocks = blocks;
  window.paintNote = () => {
    const hole = canvas.querySelector('[data-bp-fleet-id="n"] [data-bp-fleet-body]');
    const html = '<div class="bp-note"><span class="bp-note__k">Note</span><div class="bp-note__d"><b>Bold</b> Body text</div></div>';
    hole.dispatchEvent(new CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock: blocks[1] }, cancelable: true }));
  };
  paintNote();
};
window.caret = (text, offset, end = offset) => {
  const walker = document.createTreeWalker(canvas._editor.view.dom, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.data !== text) continue;
    const range = document.createRange();
    range.setStart(node, offset); range.setEnd(node, end);
    const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
    canvas._editor.view.dom.focus(); document.dispatchEvent(new Event("selectionchange"));
    return true;
  }
  return false;
};
window.selectionState = () => ({
  from: canvas._editor.state.selection.from,
  to: canvas._editor.state.selection.to,
  parent: canvas._editor.state.selection.$from.parent.type.name,
  parentOffset: canvas._editor.state.selection.$from.parentOffset,
  text: canvas._editor.state.doc.textBetween(canvas._editor.state.selection.from, canvas._editor.state.selection.to),
});
</script></body></html>`;

const server = createServer((request, response) => {
  const name = request.url.split("?")[0].slice(1);
  if (!name) return response.end(PAGE);
  if (!["bp-paper-editor.css", "bp-paper-editor.bundle.js"].includes(name)) {
    response.statusCode = 404;
    return response.end();
  }
  response.setHeader("content-type", name.endsWith(".css") ? "text/css" : "text/javascript");
  response.end(readFileSync(join(ASSETS, name)));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}/`;

const chrome = await launchChrome();
const { cdp } = chrome;
// A throw outside the try below, such as one in the page server, would end node
// before the finally runs and leave Chrome behind.
let closing;
const closeChrome = () => (closing ??= chrome.close());
const failAndClose = async (error) => {
  console.error(error);
  try {
    await closeChrome();
  } finally {
    process.exit(1);
  }
};
// on, not once: a second error during the close must wait for it too, or node dies and leaves the profile.
process.on("uncaughtException", failAndClose);
process.on("unhandledRejection", failAndClose);
// A kill skips the finally as well, so SIGTERM and SIGINT close Chrome before node exits.
for (const [signal, code] of [["SIGTERM", 143], ["SIGINT", 130]])
  process.on(signal, () => closeChrome().finally(() => process.exit(code)));
const equal = (actual, expected, label) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`${label}: ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
};
async function key(key, { code = key, modifiers = 0, virtualKeyCode } = {}) {
  const common = { key, code, modifiers, windowsVirtualKeyCode: virtualKeyCode, nativeVirtualKeyCode: virtualKeyCode };
  await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", ...common });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...common });
}
async function controlA() {
  await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Control", code: "ControlLeft", modifiers: 2, windowsVirtualKeyCode: 17 });
  await key("a", { code: "KeyA", modifiers: 2, virtualKeyCode: 65 });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Control", code: "ControlLeft", windowsVirtualKeyCode: 17 });
}
async function type(text) {
  for (const character of text) {
    await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: character, text: character, unmodifiedText: character });
    await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: character });
  }
}

try {
  await cdp.send("Page.navigate", { url: origin });
  await waitFor(cdp, `document.readyState === "complete" && Boolean(customElements.get("bp-paper-canvas"))`);

  await evaluate(cdp, `mountDiff(); true`);
  await waitFor(cdp, `document.querySelectorAll('[data-test-id^="paper-inline-diff-line"]').length === 5`);
  await evaluate(cdp, `(() => { const el = document.querySelectorAll('[data-test-id^="paper-inline-diff-line"]')[4]; el.focus(); const r = document.createRange(); r.setStart(el.firstChild, 5); r.collapse(true); getSelection().removeAllRanges(); getSelection().addRange(r); return true; })()`);
  await key("Home", { virtualKeyCode: 36 });
  await key("Backspace", { virtualKeyCode: 8 });
  equal(await evaluate(cdp, `document.querySelectorAll('[data-test-id^="paper-inline-diff-line"]')[4].textContent`), "+ new line", "Home/Backspace protects + marker");
  await controlA();
  await cdp.send("Input.insertText", { text: "+ literal" });
  await evaluate(cdp, `canvas.flushPendingChanges(); true`);
  const diff = await evaluate(cdp, `canvas._editor.state.doc.firstChild.attrs.diff`);
  if (!diff.includes("\n-old line\n++ literal") || !diff.startsWith("diff --git a/lib/a.ex b/lib/a.ex\nindex 1..2 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n"))
    throw new Error(`diff prefix/header/sibling drift: ${JSON.stringify(diff)}`);

  await evaluate(cdp, `mountNote(); true`);
  await waitFor(cdp, `Boolean(document.querySelector('[data-bp-fleet-id="n"] [data-test-id="paper-note-body"]'))`);
  await evaluate(cdp, `caret("Before", 6)`);
  await key("ArrowRight", { virtualKeyCode: 39 });
  await waitFor(cdp, `selectionState().parent === "note"`);
  equal((await evaluate(cdp, `selectionState()`)).parent, "note", "ArrowRight enters note body");
  await evaluate(cdp, `caret("Body text", 0, 4)`);
  await waitFor(cdp, `selectionState().text === "Body"`);
  await evaluate(cdp, `canvas._bubble.update(); true`);
  equal(await evaluate(cdp, `canvas._bubble._el?.style.display`), "flex", "FormatBubble remains available in note contentDOM");
  await evaluate(cdp, `caret("Body text", 9)`);
  await key("ArrowRight", { virtualKeyCode: 39 });
  await waitFor(cdp, `selectionState().parent === "paragraph"`);
  equal((await evaluate(cdp, `selectionState()`)).parent, "paragraph", "ArrowRight exits note body");
  equal((await evaluate(cdp, `selectionState()`)).from > 0, true, "selection remains mapped");
  await evaluate(cdp, `caret("Body text", 0)`);
  await waitFor(cdp, `selectionState().parent === "note" && selectionState().parentOffset === 0`);
  await key("ArrowLeft", { virtualKeyCode: 37 });
  await waitFor(cdp, `selectionState().parent === "paragraph"`);
  equal((await evaluate(cdp, `selectionState()`)).parent, "paragraph", "ArrowLeft exits note body to prior text");

  await new Promise(resolve => setTimeout(resolve, 600));
  await evaluate(cdp, `paintNote(); caret("Body text", 0, 9)`);
  await waitFor(cdp, `selectionState().parent === "note" && selectionState().text === "Body text"`);
  await type("Changed");
  const typed = await evaluate(cdp, `new Promise(resolve => setTimeout(() => resolve({ model: canvas._editor.state.doc.child(1).textContent, dom: document.querySelector('[data-bp-fleet-id="n"] [data-test-id="paper-note-body"]').textContent, active: document.activeElement?.className, selection: selectionState() }), 100))`);
  equal(typed.model, "Changed", `edit after host repaint (${JSON.stringify(typed)})`);
  await evaluate(cdp, `canvas.undo(); true`);
  equal(await evaluate(cdp, `canvas._editor.state.doc.child(1).textContent`), "Body text", "undo after host repaint");
  await evaluate(cdp, `canvas.redo(); true`);
  equal(await evaluate(cdp, `canvas._editor.state.doc.child(1).textContent`), "Changed", "redo after host repaint");

  console.log(`PASS real Chrome ${chrome.chrome.version}: diff prefix traps; note keyboard run, FormatBubble, repaint edit/undo/redo`);
} finally {
  await closeChrome();
  await new Promise(resolve => server.close(resolve));
}
