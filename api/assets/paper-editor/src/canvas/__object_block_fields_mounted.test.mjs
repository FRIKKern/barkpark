// __object_block_fields_mounted.test.mjs — task-aebfe6c1b3c3f881, in a real
// mounted field canvas whose vocabulary declares a custom object block under
// blocks.of with fields (a required `body`, a `tone` from a list):
//
//   * an untouched object block round-trips byte-identical and emits no op;
//   * the slash pick opens the field dialog; a required field blocks Save; Esc
//     inserts nothing; Save inserts the block with its fields;
//   * Enter or a double-click on a selected object block edits it, keeping keys
//     the dialog does not own, and the edit reaches the server as ONE
//     replace-block;
//   * the block is named "<kind title>: <first field text>";
//   * a server refusal reopens the dialog with the reason on the field it names.
// Run: node src/canvas/__object_block_fields_mounted.test.mjs
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
const { docToBlocks } = await import("./run-convert.js");
const { NodeSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);

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
    console.log(`      ${e.message.split("\n").slice(0,8).join(" | ")}`);
  }
}
const EXPECTED = 8;

const dialog = () => document.querySelector(".bp-inline-object-dialog");
const field = (name) => dialog().querySelector(`[data-field="${name}"]`);
const submit = () => dialog().querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
function key(el, name, extra = {}) {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...extra }));
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
  const fb = () => blocks().find((b) => b.node.attrs.bpId === "fb1");
  const select = (pos) => editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, pos)));
  const endOf = (id) => canvas._topLevelPos(id) + editor.state.doc.nodeAt(canvas._topLevelPos(id)).nodeSize - 1;

  await check("an untouched object block round-trips byte-identical and emits no op", async () => {
    assert.equal(canonical(docToBlocks(editor.getJSON()).find((b) => b.id === "fb1")), canonical(FB));
    editor.chain().setTextSelection(endOf("p-end")).insertContent("!").run();
    canvas.flushPendingChanges();
    await tick(20);
    assert.ok(ops.length > 0, "the edit elsewhere emitted ops");
    assert.deepEqual(ops.filter((op) => op.id === "fb1" || (op.block && op.block.id === "fb1")), [], JSON.stringify(ops));
  });

  await check("the block is named '<kind title>: <first field text>'", () => {
    const dom = editor.view.nodeDOM(fb().pos);
    assert.equal(dom.getAttribute("aria-label"), "Faktaboks: Old fact.");
    assert.equal(dom.getAttribute("role"), "group");
  });

  editor.commands.setTextSelection(endOf("p-end"));
  editor.commands.splitBlock();
  editor.commands.insertContent("/fakt");

  await check("the slash pick opens the dialog; required blocks Save; Esc inserts nothing", () => {
    canvas._chooseSlash({ group: "Blocks", type: "factBox", label: "Faktaboks", object: true });
    assert.ok(dialog(), "the dialog opened");
    assert.equal(dialog().querySelector("h2").textContent, "Edit Faktaboks");
    submit();
    assert.ok(dialog(), "an empty required body keeps it open");
    assert.equal(field("body").getAttribute("aria-invalid"), "true");
    key(dialog(), "Escape");
    assert.equal(dialog(), null);
    assert.equal(blocks().length, 1, "nothing was inserted");
    assert.ok(editor.state.doc.textContent.includes("/fakt"), "the slash line stays, as after a dismiss");
  });

  await check("Save inserts the block with its fields", async () => {
    ops.length = 0;
    canvas._chooseSlash({ group: "Blocks", type: "factBox", label: "Faktaboks", object: true });
    field("body").value = "New fact.";
    field("tone").value = "warning";
    submit();
    assert.equal(blocks().length, 2);
    const order = [];
    editor.state.doc.forEach((n) => order.push(n.type.name === "bpOpaque" ? n.attrs.bpBlock.body : n.textContent));
    assert.deepEqual(order, ["Intro.", "Old fact.", "End!", "New fact."], "it replaced the slash line, in place");
    canvas.flushPendingChanges();
    await tick(20);
    const insert = ops.find((op) => op.block && op.block.type === "factBox");
    assert.ok(insert, JSON.stringify(ops));
    assert.equal(insert.block.body, "New fact.");
    assert.equal(insert.block.tone, "warning");
  });

  await check("Enter edits the block and the edit is ONE replace-block keeping unowned keys", async () => {
    ops.length = 0;
    select(fb().pos);
    key(editor.view.dom, "Enter");
    assert.ok(dialog(), "Enter opened the dialog");
    assert.equal(field("body").value, "Old fact.");
    field("body").value = "Changed fact.";
    submit();
    canvas.flushPendingChanges();
    await tick(20);
    // The new block above has no server id yet (no echo in this harness), so each
    // batch re-places it; only fb1's CONTENT ops matter here.
    const mine = ops.filter((op) => op.id === "fb1" && op.op !== "move-block");
    assert.equal(mine.length, 1, JSON.stringify(ops));
    assert.equal(mine[0].op, "replace-block");
    assert.deepEqual(mine[0].block, { id: "fb1", type: "factBox", body: "Changed fact.", tone: "info", extra: "keep" });
  });

  await check("a double-click on the block opens the dialog", () => {
    const dom = editor.view.nodeDOM(fb().pos);
    dom.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true }));
    assert.ok(dialog());
    key(dialog(), "Escape");
  });

  await check("near the viewport's bottom the dialog flips above its anchor and keeps Save on screen", () => {
    window.innerHeight = 900;
    window.innerWidth = 1200;
    const dom = editor.view.nodeDOM(fb().pos);
    const realDom = dom.getBoundingClientRect;
    const realEl = window.HTMLElement.prototype.getBoundingClientRect;
    dom.getBoundingClientRect = () => ({ top: 830, bottom: 850, left: 40, right: 640, width: 600, height: 20 });
    window.HTMLElement.prototype.getBoundingClientRect = function () {
      return this.classList && this.classList.contains("bp-inline-object-dialog")
        ? { top: 0, bottom: 220, left: 0, right: 300, width: 300, height: 220 }
        : realEl.call(this);
    };
    try {
      select(fb().pos);
      key(editor.view.dom, "Enter");
      const top = parseFloat(dialog().style.top);
      assert.equal(top, 604, `flipped above the anchor (top ${dialog().style.top})`);
      assert.ok(top + 220 <= 900 - 8, "its bottom (Save, Cancel) is inside the viewport");
      key(dialog(), "Escape");
    } finally {
      dom.getBoundingClientRect = realDom;
      window.HTMLElement.prototype.getBoundingClientRect = realEl;
    }
  });

  await check("a server refusal reopens the dialog with the reason on the field it names", async () => {
    canvas.flushPendingChanges();
    await tick(20);
    canvas.acknowledgedSaves = true;
    let seq = null;
    canvas.addEventListener("bp-canvas-ops", (e) => { seq = e.detail.seq; }, { once: true });
    select(fb().pos);
    key(editor.view.dom, "Enter");
    field("tone").value = "warning";
    submit();
    canvas.flushPendingChanges();
    await tick(20);
    assert.ok(seq != null, "the save went out as an acknowledged batch");
    assert.equal(canvas.discardInflightOps(seq, { reason: "factBox/tone: must be one of info" }), true);
    assert.ok(dialog(), "the dialog reopened");
    assert.equal(field("tone").getAttribute("aria-invalid"), "true");
    assert.equal(document.getElementById(field("tone").getAttribute("aria-describedby")).textContent, "must be one of info");
    key(dialog(), "Escape");
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
} finally {
  if (ran !== EXPECTED) { failures += 1; console.log(`FAIL  ran ${ran} of ${EXPECTED} checks`); }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\nobject block fields mounted: all checks passed");
  process.exit(0);
}
