// record-replay.mjs — record the op batches an editor tree sends, for the old-client
// replay test (api/test/barkpark/portable_doc/old_client_replay_test.exs).
//
// Mounts <bp-paper-canvas> and <bp-paper-editor> from one checkout of this folder
// in jsdom, plays the same synthetic edits on each, and prints every batch the tree
// emitted as JSON. Run it against an older contract's tree to get what that client
// sent:
//
//   git archive <commit> api/assets/paper-editor/src | tar -x -C /tmp/tree
//   ln -s "$PWD/node_modules" /tmp/tree/api/assets/paper-editor/node_modules
//   node scripts/record-replay.mjs /tmp/tree/api/assets/paper-editor <commit> > replay.json
//
// The edits go through the doors a person uses: typed characters through
// handleTextInput, keydown events, paste events, the toolbar commands and the
// block menu's move and delete.
import { JSDOM } from "jsdom";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [treeArg, commit] = process.argv.slice(2);
if (process.argv.length !== 4) {
  console.error("usage: node scripts/record-replay.mjs <paper-editor tree> <commit>");
  process.exit(2);
}
const tree = resolve(treeArg);
const load = (rel) => import(pathToFileURL(resolve(tree, rel)).href);

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "FormData", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement",
  "HTMLSelectElement", "InputEvent", "KeyboardEvent", "MouseEvent", "MutationObserver",
  "Node", "NodeFilter", "Option", "Selection", "Text",
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

const { CONTRACT_VERSION } = await load("src/contract.js");
await load("src/canvas/index.js");
await load("src/index.js");
const { moveTopLevel, deleteTopLevel } = await load("src/canvas/block-handle.js");
const { TextSelection } = await import("@tiptap/pm/state");

const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const clone = (v) => JSON.parse(JSON.stringify(v));
const text = (value) => ({ type: "text", value });
const para = (id, value) => ({ id, type: "paragraph", content: [text(value)] });

const ROWS = [
  { title: "Plan", id: "n-plan", type: "note" },
  { title: "Packing list", id: "n-pack", type: "note" },
];

function caret(editor, pos) {
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, pos)));
}
function select(editor, from, to) {
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, from, to)));
}
function endOf(editor, index) {
  let at = 0;
  editor.state.doc.forEach((node, offset, i) => { if (i === index) at = offset + node.nodeSize - 1; });
  return at;
}
function find(editor, words) {
  let at;
  editor.state.doc.descendants((node, pos) => {
    if (node.isText && node.text.includes(words)) at = pos + node.text.indexOf(words);
  });
  return { from: at, to: at + words.length };
}
function type(editor, chars) {
  const { view } = editor;
  for (const char of chars) {
    const { from, to } = view.state.selection;
    const handled = view.someProp("handleTextInput", (f) => f(view, from, to, char));
    if (!handled) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}
function paste(editor, plain) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { types: ["text/plain"], getData: (t) => (t === "text/plain" ? plain : ""), files: [] },
  });
  editor.view.dom.dispatchEvent(event);
}
function key(editor, init) {
  editor.view.dom.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
}

async function canvasScene(name, blocks, play) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.wikilinkSource = (q) => ROWS.filter((r) => r.title.toLowerCase().includes(q.toLowerCase()));
  canvas.blocks = clone(blocks);
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => {
    batches.push(clone(e.detail.ops));
    canvas.acknowledgeOps(e.detail.seq, true);
    canvas.applyServerBlocks(clone(canvas.blocks), { mode: "own" });
  });
  document.body.appendChild(canvas);
  await tick(350);
  const editor = canvas._editor;
  const flush = async () => { canvas.flushPendingChanges(); await tick(350); };
  await play({ canvas, editor, flush });
  await flush();
  const after = clone(canvas.blocks);
  canvas.remove();
  return { scene: name, element: "bp-paper-canvas", before: clone(blocks), batches, client_after: after };
}

async function editorScene(name, mode, block, play) {
  const el = document.createElement("bp-paper-editor");
  el.setAttribute("data-editor-mode", mode);
  el.block = clone(block);
  const batches = [];
  el.addEventListener("bp-op", (e) => batches.push([clone(e.detail)]));
  document.body.appendChild(el);
  await tick(50);
  await play({ el, editor: el._editor, flush: async () => { el.flushPendingChanges(); await tick(50); } });
  el.remove();
  return { scene: name, element: `bp-paper-editor[data-editor-mode=${mode}]`, before: [clone(block)], batches };
}

const ridge = [
  para("p-ridge", "Field notes from the ridge."),
  para("p-camp", "We made camp below the saddle."),
  para("p-water", "Water at the second stream."),
  para("p-return", "Back by noon."),
];

const row = { kind: "array", cells: ["inline-array", "inline-array"] };
const gearTable = {
  id: "t-gear",
  type: "table",
  shape: { v: 1, head: { state: "row", row }, rows: [row, row] },
  head: [[text("Item")], [text("Weight")]],
  rows: [[[text("Tent")], [text("2 kg")]], [[text("Stove")], [text("400 g")]]],
};

const scenes = [
  () => canvasScene("type-and-mark", ridge, async ({ canvas, editor, flush }) => {
    caret(editor, endOf(editor, 0));
    type(editor, " Wind from the west.");
    await flush();
    const r = find(editor, "ridge");
    select(editor, r.from, r.to);
    canvas.toggleMark("strong");
    const s = find(editor, "saddle");
    select(editor, s.from, s.to);
    canvas.toggleMark("link", { href: "https://example.com/saddle" });
    const w = find(editor, "second");
    select(editor, w.from, w.to);
    canvas.toggleMark("em");
  }),
  () => canvasScene("split-and-heading", ridge, async ({ canvas, editor, flush }) => {
    caret(editor, endOf(editor, 1));
    key(editor, { key: "Enter" });
    type(editor, "Camp at dusk");
    canvas.setBlockStyle("h2");
    await flush();
    caret(editor, endOf(editor, 0));
    canvas.setBlockStyle("h3");
  }),
  () => canvasScene("lists", ridge, async ({ canvas, editor, flush }) => {
    caret(editor, endOf(editor, 2));
    canvas.toggleList("bullet");
    key(editor, { key: "Enter" });
    type(editor, "Filter the third");
    await flush();
    canvas.toggleList("number");
  }),
  () => canvasScene("move-and-remove", ridge, async ({ editor, flush }) => {
    moveTopLevel(editor, 0, 2);
    await flush();
    deleteTopLevel(editor, 1);
    await flush();
    moveTopLevel(editor, 2, 0);
  }),
  () => canvasScene("turn-into-quote", ridge, async ({ canvas, editor }) => {
    caret(editor, endOf(editor, 3));
    canvas.setBlockStyle("blockquote");
  }),
  () => canvasScene("select-all-retype", ridge, async ({ editor }) => {
    key(editor, { key: "a", ctrlKey: true });
    type(editor, "A");
    caret(editor, endOf(editor, 0));
    type(editor, " fresh start.");
  }),
  () => canvasScene("insert-blocks", ridge, async ({ canvas, editor, flush }) => {
    caret(editor, endOf(editor, 0));
    canvas.insertBlock("divider");
    await flush();
    caret(editor, endOf(editor, 2));
    canvas.insertBlock("code");
    type(editor, "tar -czf notes.tgz notes/");
  }),
  () => canvasScene("wikilink-menu-pick", ridge, async ({ editor }) => {
    caret(editor, endOf(editor, 0));
    type(editor, " [[Pla");
    await tick(30);
    key(editor, { key: "Enter" });
    await tick(30);
    type(editor, " and @Pack");
    await tick(30);
    key(editor, { key: "Enter" });
  }),
  () => canvasScene("wikilink-typed", ridge, async ({ editor }) => {
    caret(editor, endOf(editor, 1));
    type(editor, " See [[Plan]].");
    await tick(30);
  }),
  () => canvasScene("wikilink-pasted", ridge, async ({ editor }) => {
    caret(editor, endOf(editor, 2));
    paste(editor, " Check [[packing list]] and [[Nobody]].");
    await tick(30);
  }),
  () => canvasScene("wikilink-alias", ridge, async ({ editor }) => {
    caret(editor, endOf(editor, 3));
    type(editor, " Read [[Plan|the plan]].");
    await tick(30);
    paste(editor, " Also [[Packing list|our list]].");
    await tick(30);
  }),
  () => canvasScene("markdown-paste", ridge, async ({ editor }) => {
    caret(editor, endOf(editor, 3));
    key(editor, { key: "Enter" });
    paste(editor, "## Gear\n\n- rope\n- stove\n\n> Pack light.\n\n```sh\nls gear/\n```");
    await tick(30);
  }),
  () => canvasScene("undo-redo", ridge, async ({ canvas, editor }) => {
    caret(editor, endOf(editor, 0));
    type(editor, " Fog.");
    await tick(600);
    type(editor, " Rain.");
    canvas.undo();
    canvas.redo();
    canvas.undo();
  }),
  () => editorScene("card-body", "card-body", {
    id: "c-trail",
    type: "card",
    tone: "info",
    slots: {
      title: [{ type: "heading", text: "Trail" }],
      body: [{ type: "paragraph", content: [text("Six hours return.")] }],
    },
  }, async ({ editor, flush }) => {
    editor.commands.focus("end");
    type(editor, " Bring a map.");
    await flush();
  }),
  () => editorScene("table-cells", "table", gearTable, async ({ editor, flush }) => {
    const at = find(editor, "400 g");
    select(editor, at.from, at.to);
    type(editor, "350 g");
    await flush();
  }),
  () => editorScene("table-structure", "table", gearTable, async ({ el }) => {
    el.requestTableStructure("add-row");
    await tick(50);
  }),
  () => canvasScene("nested-edits", [
    { id: "h-trip", type: "heading", level: 2, text: "Trip" },
    {
      id: "s-day",
      type: "section",
      title: "Day one",
      blocks: [
        para("p-day", "Left the car park at six."),
        { id: "co-ice", type: "callout", tone: "warning", content: [text("Ice on the north face.")] },
      ],
    },
    para("p-after", "Home by dark."),
  ], async ({ editor, flush }) => {
    const day = find(editor, "at six");
    caret(editor, day.to);
    type(editor, " in fog");
    await flush();
    const ice = find(editor, "north face");
    caret(editor, ice.to);
    type(editor, " and the ridge");
  }),
];

const recorded = [];
for (const scene of scenes) recorded.push(await scene());

process.stdout.write(JSON.stringify({
  contract: CONTRACT_VERSION,
  commit,
  recorded_by: "api/assets/paper-editor/scripts/record-replay.mjs",
  scenes: recorded,
}, null, 2) + "\n");
process.exit(0);
