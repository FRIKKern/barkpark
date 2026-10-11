// __move_matrix_mounted.test.mjs — task-4da8ae48eee9ec35. The MOVE matrix, the
// sibling of __data_loss_key_matrix_mounted.test.mjs: moving a NodeSelected
// non-text block must never lose it.
//
// The block list is the SAME predicate: every stored block in the pd-parity
// corpus (plus the declared callout carry, an ordered list, a checklist and a
// live task-list) is mounted in [paragraph, block, paragraph, paragraph], and it
// is in scope when the canvas projects it as a top-level node that is not a
// textblock. Three paths per block:
//
//   cut + paste  The cut event (ProseMirror's default, Mod+X) puts the block on
//                the clipboard; pasting exactly what it wrote, back at the same
//                place, restores a block of the same type whose stored form
//                equals the original's (its id may be new).
//   grip drag    block-handle.js: pointer drag on the grip to the end and to the
//                start of the document.
//   native drag  ProseMirror dragstart/drop on the editor, to the end and to the
//                start of the document.
//
// A drag must land the block in its new place under its own id, with no
// remove-block of any original block. (That a drag is exactly ONE move-block is
// task-d20a8200b28f0d7a, pinned with its own fix.)
// Control: a paste that carries only the plain text of a cut block IS reported
// as not restored, so the round-trip assertion can fail.
// Run: node src/canvas/__move_matrix_mounted.test.mjs
import { readdirSync, readFileSync } from "node:fs";
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
window.Element.prototype.getClientRects ||= () => [];

await import("./index.js");
const { docToBlocks } = await import("./run-convert.js");
const { NodeSelection, TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const canonical = (v) => JSON.stringify(v, (k, val) =>
  val && typeof val === "object" && !Array.isArray(val)
    ? Object.fromEntries(Object.keys(val).sort().map((key) => [key, val[key]])) : val);

// ── the corpus (the key matrix's) ───────────────────────────────────────────
const GOLDEN_DIR = new URL("../../../../../js/packages/react/tests/fixtures/pd-golden/", import.meta.url);
const corpus = readdirSync(GOLDEN_DIR)
  .filter((f) => f.endsWith(".golden.json"))
  .sort()
  .map((f) => JSON.parse(readFileSync(new URL(f, GOLDEN_DIR), "utf8")))
  .filter((g) => g && g.input && typeof g.input.type === "string")
  .map((g) => ({ label: g.input.type, block: g.input, vocabulary: null }));
const DECLARED = {
  styles: ["normal"],
  of: [{
    name: "callout",
    title: "Callout",
    fields: [
      { name: "tone", title: "Tone", type: "string", options: { list: ["info", "warning"] } },
      { name: "text", title: "Text", type: "text" },
    ],
  }],
};
const ITEMS = [[{ type: "text", value: "First" }], [{ type: "text", value: "Second" }]];
corpus.push({ label: "callout (declared carry)", block: { type: "callout", tone: "info", text: "Mind the gap." }, vocabulary: DECLARED });
corpus.push({ label: "list (ordered)", block: { type: "list", ordered: true, items: ITEMS }, vocabulary: null });
corpus.push({ label: "list (checklist)", block: { type: "list", task: true, items: ITEMS }, vocabulary: null });
corpus.push({ label: "task-list (live query)", block: { type: "task-list", query: { label: "proj:x" }, title: "Plan" }, vocabulary: null });

const para = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const TARGET = "mv-target";
const AROUND = ["mv-before", "mv-after", "mv-tail"];
const ORIGINAL = new Set(["mv-before", TARGET, "mv-after", "mv-tail"]);

async function mount(entry) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  if (entry.vocabulary) canvas.setAttribute("data-vocabulary", JSON.stringify(entry.vocabulary));
  canvas.blocks = [para("mv-before", "Before."), { ...entry.block, id: TARGET }, para("mv-after", "After."), para("mv-tail", "Tail.")]
    .map((b) => JSON.parse(JSON.stringify(b)));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(15);
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  return { root, canvas, editor: canvas._editor, ops };
}
const topNodes = (editor) => { const out = []; editor.state.doc.forEach((node, pos) => out.push({ node, pos })); return out; };
const targetNode = (editor) => topNodes(editor).find((n) => n.node.attrs.bpId === TARGET);
const stored = (editor) => docToBlocks(editor.getJSON());
// A pasted copy may carry new ids at any depth (nested blocks are copies too);
// the stored CONTENT is what must survive.
const withoutId = (v) => (Array.isArray(v) ? v.map(withoutId)
  : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).filter(([k]) => k !== "id").map(([k, x]) => [k, withoutId(x)])) : v);
async function settle(c) { c.canvas.flushPendingChanges(); await tick(10); }

// ── cut + paste ─────────────────────────────────────────────────────────────
function clipboard() {
  const data = {};
  return {
    data,
    types: [],
    files: [],
    clearData() { for (const k of Object.keys(data)) delete data[k]; },
    setData(type, value) { data[type] = value; },
    getData(type) { return data[type] || ""; },
  };
}
function fire(target, type, extra) {
  const event = new Event(type, { bubbles: true, cancelable: true });
  for (const [k, v] of Object.entries(extra)) Object.defineProperty(event, k, { value: v });
  target.dispatchEvent(event);
  return event;
}
async function cutPaste(entry, { plainOnly = false, copy = false } = {}) {
  const c = await mount(entry);
  const t = targetNode(c.editor);
  const baseline = stored(c.editor).find((b) => b.id === TARGET);
  c.editor.view.dispatch(c.editor.state.tr.setSelection(NodeSelection.create(c.editor.state.doc, t.pos)));
  const board = clipboard();
  fire(c.editor.view.dom, copy ? "copy" : "cut", { clipboardData: board });
  await settle(c);
  const problems = [];
  if (!board.data["text/html"] && !board.data["text/plain"]) problems.push(`the ${copy ? "copy" : "cut"} put nothing on the clipboard`);
  if (!copy && targetNode(c.editor)) problems.push("the cut left the block in place");
  if (copy && !targetNode(c.editor)) problems.push("the copy removed the block");
  // Paste back where the block was: the caret sits at the start of the
  // paragraph that followed it.
  const after = topNodes(c.editor).find((n) => n.node.attrs.bpId === "mv-after");
  c.editor.view.dispatch(c.editor.state.tr.setSelection(TextSelection.create(c.editor.state.doc, after.pos + 1)));
  const paste = clipboard();
  if (!plainOnly && board.data["text/html"]) paste.setData("text/html", board.data["text/html"]);
  paste.setData("text/plain", board.data["text/plain"] || "");
  paste.types = Object.keys(paste.data);
  fire(c.editor.view.dom, "paste", { clipboardData: paste });
  await settle(c);
  const blocks = stored(c.editor);
  // The restored block may keep its id (the clipboard HTML carries data-bp-id)
  // or take a new one; it is any block that is not one of the paragraphs.
  const candidates = blocks.filter((b) => !AROUND.includes(b.id));
  const restored = candidates.filter((b) => b.type === baseline.type && canonical(withoutId(b)) === canonical(withoutId(baseline)));
  // A copy leaves the original AND adds a copy: two equal blocks, two ids.
  if (copy) {
    const ids = restored.map((b) => b.id);
    if (restored.length !== 2) problems.push(`copy+paste: ${restored.length} matching blocks, wanted the original and one copy: got ${canonical(candidates).slice(0, 200)}`);
    else if (new Set(ids).size !== 2 || !ids.includes(TARGET)) problems.push(`copy+paste: the copy shares the original's id (${canonical(ids)})`);
    c.root.remove();
    return problems;
  }
  if (restored.length !== 1) {
    problems.push(`the paste did not restore it (${restored.length} matching blocks): wanted ${canonical(withoutId(baseline)).slice(0, 160)}, got ${canonical(candidates).slice(0, 200)}`);
  }
  const lostAround = AROUND.filter((id) => !blocks.some((b) => b.id === id));
  if (lostAround.length) problems.push(`the round trip removed ${lostAround.join(",")}`);
  c.root.remove();
  return problems;
}

// ── drags ───────────────────────────────────────────────────────────────────
// A drag to the END lands after the tail paragraph; to the START before the
// first one. The expected order of the original ids after the move:
const DESTINATIONS = {
  end: ["mv-before", "mv-after", "mv-tail", TARGET],
  start: [TARGET, "mv-before", "mv-after", "mv-tail"],
};
function checkMove(c, label, where) {
  const problems = [];
  const order = topNodes(c.editor).map((n) => n.node.attrs.bpId).filter((id) => ORIGINAL.has(id));
  if (canonical(order) !== canonical(DESTINATIONS[where])) problems.push(`${label} to ${where}: order ${canonical(order)}`);
  const removed = c.ops.filter((op) => op.op === "remove-block" && ORIGINAL.has(op.id));
  if (removed.length) problems.push(`${label} to ${where}: remove-block ${removed.map((o) => o.id).join(",")}`);
  // An insert of the block's content under a new id would be a remove+insert in
  // disguise: the moved block must keep its id.
  const reinserted = c.ops.filter((op) => op.op === "insert-after" && op.block && op.block.type !== "paragraph");
  if (reinserted.length) problems.push(`${label} to ${where}: re-inserted as a new block ${canonical(reinserted.map((o) => o.block.id))}`);
  return problems;
}

// Every top-level node DOM gets a 100px row, so the grip's nearest-boundary
// geometry has something to measure.
function layRows(c) {
  topNodes(c.editor).forEach(({ pos }, i) => {
    const el = c.editor.view.nodeDOM(pos);
    if (el) el.getBoundingClientRect = () => ({ top: i * 100, bottom: i * 100 + 90, left: 0, right: 600, width: 600, height: 90 });
  });
}
async function gripDrag(entry, where) {
  const c = await mount(entry);
  const handle = c.canvas._handle;
  if (!handle || typeof handle._startDrag !== "function") { c.root.remove(); return ["grip: the canvas has no block handle"]; }
  layRows(c);
  const source = topNodes(c.editor).findIndex((n) => n.node.attrs.bpId === TARGET);
  handle._index = source;
  const grip = handle._el.querySelector(".bp-block-handle__grip");
  c.ops.length = 0;
  handle._startDrag({ button: 0, clientY: source * 100 + 5, currentTarget: grip, pointerId: 1, preventDefault() {} });
  const y = where === "end" ? 4 * 100 - 5 : -50;
  fire(grip, "pointermove", { clientY: y });
  fire(grip, "pointerup", { clientY: y });
  await settle(c);
  const problems = checkMove(c, "grip drag", where);
  c.root.remove();
  return problems;
}
async function nativeDrag(entry, where) {
  const c = await mount(entry);
  const { view } = c.editor;
  const t = targetNode(c.editor);
  view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, t.pos)));
  c.ops.length = 0;
  const transfer = clipboard();
  const realPosAtCoords = view.posAtCoords.bind(view);
  // dragstart: the pointer is on the selected block.
  view.posAtCoords = () => ({ pos: t.pos, inside: t.pos });
  fire(view.dom, "dragstart", { dataTransfer: transfer, clientX: 1, clientY: 1 });
  // drop: the pointer is at the document's end, or its start.
  const at = where === "end" ? view.state.doc.content.size : 0;
  view.posAtCoords = () => ({ pos: at, inside: -1 });
  fire(view.dom, "drop", { dataTransfer: transfer, clientX: 1, clientY: 1 });
  view.posAtCoords = realPosAtCoords;
  await settle(c);
  const problems = checkMove(c, "native drag", where);
  c.root.remove();
  return problems;
}

// ── run ─────────────────────────────────────────────────────────────────────
const findings = [];
const covered = new Set();
const counts = { "cut+paste": 0, "copy+paste": 0, "grip drag": 0, "native drag": 0 };
let inScope = 0;
let failures = 0;

try {
  for (const entry of corpus) {
    const probe = await mount(entry);
    const hit = probe.editor && targetNode(probe.editor);
    probe.root.remove();
    // THE PREDICATE: a top-level node the canvas renders that is not a textblock.
    if (!hit || hit.node.isTextblock) continue;
    inScope += 1;
    const nodeType = hit.node.type.name;
    covered.add(nodeType);
    const cases = [
      ["cut+paste", () => cutPaste(entry)],
      ["copy+paste", () => cutPaste(entry, { copy: true })],
      ["grip drag", () => gripDrag(entry, "end")], ["grip drag", () => gripDrag(entry, "start")],
      ["native drag", () => nativeDrag(entry, "end")], ["native drag", () => nativeDrag(entry, "start")],
    ];
    for (const [path, run] of cases) {
      let problems;
      try {
        problems = await run();
      } catch (e) {
        problems = [`${path}: threw ${e.message.split("\n")[0]}`];
      }
      counts[path] += 1;
      for (const p of problems) findings.push(`${entry.label} [${nodeType}] ${path}: ${p}`);
    }
  }

  // Control: a lossy round trip IS reported — a paste carrying only the plain
  // text of a cut divider cannot restore the divider.
  {
    const problems = await cutPaste(corpus.find((c) => c.label === "divider"), { plainOnly: true });
    if (!problems.some((p) => p.startsWith("the paste did not restore it"))) {
      failures += 1;
      console.log(`FAIL  control: a plain-text-only paste of a cut divider was reported restored (${canonical(problems)})`);
    } else {
      console.log("PASS  control: a plain-text-only paste of a cut divider is reported as not restored");
    }
  }

  // Coverage: every non-textblock block node in the schema is reached.
  {
    const m = await mount(corpus.find((c) => c.label === "paragraph"));
    const blockNodes = Object.values(m.editor.schema.nodes).filter((n) => n.isBlock && !n.isTextblock && n.name !== "doc" && (n.spec.group || "").split(" ").includes("block"));
    const uncovered = blockNodes.map((n) => n.name).filter((n) => !covered.has(n)).sort();
    console.log(`cover ${covered.size} of ${blockNodes.length} schema non-text block nodes`);
    if (uncovered.length) { failures += 1; console.log(`FAIL  control: the corpus does not reach ${uncovered.join(", ")}`); }
    m.root.remove();
  }
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
}

console.log(`\n${inScope} non-text block(s) in scope; cases: ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(", ")}`);
if (inScope < 20) { failures += 1; console.log(`FAIL  only ${inScope} non-text blocks in scope — the predicate or the corpus is broken`); }
for (const f of findings) console.log(`FAIL  ${f}`);
failures += findings.length;
if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\nmove matrix: every cut and copy round-trips and every drag keeps its block");
process.exit(0);
