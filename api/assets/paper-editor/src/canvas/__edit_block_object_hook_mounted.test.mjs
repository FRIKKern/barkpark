// __edit_block_object_hook_mounted.test.mjs — the host's editor for declared objects
// (editBlockObject, EMBED-CONTRACT): set, every object insert and edit (slash pick,
// Enter on a block, the inline chip, a server refusal) asks the host instead of
// opening the popover. Only declared fields are taken from its answer (type, id and
// unowned keys stay); a missing required field asks again with its error; null or a
// throw changes nothing; unset, the popover is back.
// Run: node src/canvas/__edit_block_object_hook_mounted.test.mjs   (or: npm test)
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
const { NodeSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const VOCAB = {
  styles: ["normal"],
  of: [{
    name: "factBox",
    title: "Faktaboks",
    fields: [
      { name: "body", title: "Body", type: "text", validation: { required: true } },
      { name: "tone", title: "Tone", type: "string", options: { list: ["info", "warning"] } },
    ],
  }],
  inline: [{
    name: "chip",
    title: "Status chip",
    fields: [{ name: "text", title: "Text", type: "string", validation: { required: true } }],
  }],
};
const FB = { id: "fb1", type: "factBox", body: "Old fact.", tone: "info", extra: "keep" };
const BLOCKS = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Intro." }] },
  FB,
  { id: "p-end", type: "paragraph", content: [{ type: "text", value: "End" }] },
];

let ran = 0;
let failures = 0;
async function check(name, fn) {
  ran += 1;
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message.split("\n").slice(0, 8).join(" | ")}`);
  }
}
const EXPECTED = 7;
const popover = () => document.querySelector(".bp-inline-object-dialog");
function key(el, name) {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
}

try {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  canvas.setAttribute("data-vocabulary", JSON.stringify(VOCAB));
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(350);
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  const editor = canvas._editor;
  const blocks = () => {
    const out = [];
    editor.state.doc.forEach((node, pos) => { if (node.type.name === "bpOpaque") out.push({ node, pos }); });
    return out;
  };
  const chips = () => {
    const out = [];
    editor.state.doc.descendants((node) => { if (node.type.name === "bpInlineOpaque") out.push(node.attrs.node); });
    return out;
  };
  const fb = () => blocks().find((b) => b.node.attrs.bpId === "fb1");
  const select = (pos) => editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, pos)));
  const endOf = (id) => canvas._topLevelPos(id) + editor.state.doc.nodeAt(canvas._topLevelPos(id)).nodeSize - 1;

  // The host: records each request and answers from a queue.
  const asked = [];
  const answers = [];
  canvas.editBlockObject = async (request) => {
    asked.push(request);
    const next = answers.shift();
    if (typeof next === "function") return next();
    return next ?? null;
  };

  editor.commands.setTextSelection(endOf("p-end"));
  editor.commands.splitBlock();
  editor.commands.insertContent("/fakt");

  await check("the slash pick asks the host, not the popover; a missing required field asks again; null inserts nothing", async () => {
    answers.push({ tone: "info" }, null);
    canvas._chooseSlash({ group: "Blocks", type: "factBox", label: "Faktaboks", object: true });
    await tick(10);
    assert.equal(popover(), null, "no popover");
    assert.equal(asked.length, 2, "asked, then asked again");
    assert.deepEqual(asked[0], { type: "factBox", title: "Faktaboks", inline: false, fields: VOCAB.of[0].fields, value: { type: "factBox" }, error: null });
    assert.deepEqual(asked[1].error, { field: "body", message: "Required" });
    assert.deepEqual(asked[1].value, { type: "factBox", tone: "info" }, "asked again over what it answered");
    assert.equal(blocks().length, 1, "nothing was inserted");
  });

  await check("the host's answer inserts the block; only declared fields are taken", async () => {
    ops.length = 0;
    answers.push({ type: "evil", id: "forged", body: "New fact.", tone: "warning", junk: 1 });
    canvas._chooseSlash({ group: "Blocks", type: "factBox", label: "Faktaboks", object: true });
    await tick(10);
    assert.equal(blocks().length, 2);
    const added = blocks().find((b) => b.node.attrs.bpId !== "fb1").node.attrs.bpBlock;
    assert.deepEqual(added, { type: "factBox", body: "New fact.", tone: "warning" });
    canvas.flushPendingChanges();
    await tick(20);
    const insert = ops.find((op) => op.block && op.block.type === "factBox");
    assert.ok(insert && insert.block.body === "New fact." && !("junk" in insert.block), JSON.stringify(ops));
  });

  await check("Enter on a block asks with its value; the edit is ONE replace-block keeping id and unowned keys", async () => {
    ops.length = 0;
    asked.length = 0;
    answers.push({ body: "Changed fact.", tone: "info" });
    select(fb().pos);
    key(editor.view.dom, "Enter");
    await tick(10);
    assert.equal(popover(), null);
    assert.deepEqual(asked[0].value, FB, "the stored value, unowned keys and all");
    canvas.flushPendingChanges();
    await tick(20);
    const mine = ops.filter((op) => op.id === "fb1" && op.op !== "move-block");
    assert.equal(mine.length, 1, JSON.stringify(ops));
    assert.deepEqual(mine[0].block, { id: "fb1", type: "factBox", body: "Changed fact.", tone: "info", extra: "keep" });
  });

  await check("a throwing host changes nothing", async () => {
    const before = editor.getJSON();
    answers.push(() => { throw new Error("closed"); });
    select(fb().pos);
    key(editor.view.dom, "Enter");
    await tick(10);
    assert.deepEqual(editor.getJSON(), before);
  });

  await check("an inline object asks the host with inline: true and lands at the caret", async () => {
    asked.length = 0;
    editor.commands.setTextSelection(endOf("p1"));
    answers.push({ text: "Reviewed" });
    canvas._chooseSlash({ group: "Inline", type: "inline:chip", label: "Status chip", inline: "chip" });
    await tick(10);
    assert.equal(popover(), null);
    assert.equal(asked[0].inline, true);
    assert.equal(asked[0].title, "Status chip");
    assert.deepEqual(chips(), [{ type: "chip", text: "Reviewed" }]);
  });

  await check("a server refusal asks the host again with the reason on the field it names", async () => {
    canvas.flushPendingChanges();
    await tick(20);
    canvas.acknowledgedSaves = true;
    let seq = null;
    canvas.addEventListener("bp-canvas-ops", (e) => { seq = e.detail.seq; }, { once: true });
    asked.length = 0;
    answers.push({ body: "Changed fact.", tone: "warning" }, null);
    select(fb().pos);
    key(editor.view.dom, "Enter");
    await tick(10);
    canvas.flushPendingChanges();
    await tick(20);
    assert.ok(seq != null, "the save went out as an acknowledged batch");
    assert.equal(canvas.discardInflightOps(seq, { reason: "factBox/tone: must be one of info" }), true);
    await tick(10);
    assert.equal(asked.length, 2);
    assert.deepEqual(asked[1].error, { field: "tone", message: "must be one of info" });
    canvas.acknowledgedSaves = false;
  });

  await check("unset, the popover is back", async () => {
    canvas.editBlockObject = null;
    select(fb().pos);
    key(editor.view.dom, "Enter");
    assert.ok(popover(), "the popover opened");
    key(popover(), "Escape");
    assert.equal(popover(), null);
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (ran !== EXPECTED) { failures += 1; console.log(`FAIL  ran ${ran} of ${EXPECTED} checks`); }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nedit block object hook mounted: all checks passed");
  process.exit(0);
}
