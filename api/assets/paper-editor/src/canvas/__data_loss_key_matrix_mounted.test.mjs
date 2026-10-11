// __data_loss_key_matrix_mounted.test.mjs — task-fd26d871b09115cb. The DATA-LOSS
// KEY MATRIX: a follow-up to the P1 in task-0075081d540d1390, where an end-of-line
// key NodeSelected a declared callout carry and the next keystroke deleted it.
//
// The block list is a PREDICATE, not a hand list: every stored block in the
// pd-parity corpus (one golden input per PortableDoc type, plus the declared
// callout carry, which needs a field vocabulary) is mounted between two
// paragraphs, and it is in scope when the canvas projects it as a top-level node
// that is NOT a textblock. For each such block, from the textblock boundary
// before it and after it, every navigation key is pressed and then the author
// types, pastes or starts an IME composition. The emitted batch must never hold
// remove-block for a block the author did not Backspace/Delete.
//
// Controls: a deliberate Backspace on a selected block IS reported as
// remove-block (the assertion can fail), and every non-textblock block node in
// the canvas schema is reached by the corpus (a node no stored block reaches
// fails the run).
// Run: node src/canvas/__data_loss_key_matrix_mounted.test.mjs
import assert from "node:assert/strict";
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
const { NodeSelection, TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

// ── the corpus ──────────────────────────────────────────────────────────────
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
corpus.push({ label: "callout (declared carry)", block: { type: "callout", tone: "info", text: "Mind the gap." }, vocabulary: DECLARED });
// Stored variants the golden corpus holds only in one form: an ordered list, a
// checklist, and a LIVE task-list (a `query`; the golden one is the snapshot form).
const ITEMS = [[{ type: "text", value: "First" }], [{ type: "text", value: "Second" }]];
corpus.push({ label: "list (ordered)", block: { type: "list", ordered: true, items: ITEMS }, vocabulary: null });
corpus.push({ label: "list (checklist)", block: { type: "list", task: true, items: ITEMS }, vocabulary: null });
corpus.push({ label: "task-list (live query)", block: { type: "task-list", query: { label: "proj:x" }, title: "Plan" }, vocabulary: null });

const BEFORE = { id: "dl-before", type: "paragraph", content: [{ type: "text", value: "Before the block." }] };
const AFTER = { id: "dl-after", type: "paragraph", content: [{ type: "text", value: "After the block." }] };
const TARGET = "dl-target";

// ── keys ProseMirror and the canvas read (keyCode for PM's own arrows) ──────
const MAC = /Mac|iP(hone|[oa]d)/.test(navigator.platform);
const MOD = MAC ? { metaKey: true } : { ctrlKey: true };
const CODES = { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, PageUp: 33, PageDown: 34, End: 35, Home: 36 };
const KEYS = [
  ["(no key)", null, {}],
  ["End", "End", {}], ["Home", "Home", {}],
  ["Mod+ArrowRight", "ArrowRight", MOD], ["Mod+ArrowLeft", "ArrowLeft", MOD],
  ["Alt+ArrowRight", "ArrowRight", { altKey: true }], ["Alt+ArrowLeft", "ArrowLeft", { altKey: true }],
  ["ArrowUp", "ArrowUp", {}], ["ArrowDown", "ArrowDown", {}],
  ["PageUp", "PageUp", {}], ["PageDown", "PageDown", {}],
];
function press(el, name, extra) {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: name, keyCode: CODES[name] || 0, bubbles: true, cancelable: true, ...extra }));
}

// ── author actions ──────────────────────────────────────────────────────────
function type(editor, text) {
  const { view } = editor;
  for (const char of text) {
    const { from, to } = view.state.selection;
    const handled = view.someProp("handleTextInput", (f) => f(view, from, to, char));
    if (!handled) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}
function paste(editor, text) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { types: ["text/plain"], getData: (t) => (t === "text/plain" ? text : ""), files: [] } });
  editor.view.dom.dispatchEvent(event);
}
function compose(editor, text) {
  editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
  editor.view.dispatch(editor.state.tr.insertText(text));
  editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data: text }));
}
const ACTIONS = [["type", (ed) => type(ed, " Z")], ["paste", (ed) => paste(ed, "Pasted")], ["IME", (ed) => compose(ed, "あ")]];

// ── harness ─────────────────────────────────────────────────────────────────
async function mount(entry) {
  const root = document.createElement("div");
  root.className = "bp-paper-editor";
  const canvas = document.createElement("bp-paper-canvas");
  if (entry.vocabulary) canvas.setAttribute("data-vocabulary", JSON.stringify(entry.vocabulary));
  canvas.blocks = [BEFORE, { ...entry.block, id: TARGET }, AFTER].map((b) => JSON.parse(JSON.stringify(b)));
  root.appendChild(canvas);
  document.body.appendChild(root);
  await tick(15);
  const ops = [];
  canvas.addEventListener("bp-canvas-ops", (e) => ops.push(...(e.detail.ops || [])));
  return { root, canvas, editor: canvas._editor, ops };
}
const topNodes = (editor) => { const out = []; editor.state.doc.forEach((node, pos) => out.push({ node, pos })); return out; };
const targetNode = (editor) => topNodes(editor).find((n) => n.node.attrs.bpId === TARGET);
const ORIGINAL = new Set(["dl-before", TARGET, "dl-after"]);
const removals = (ops) => ops.filter((op) => op.op === "remove-block" && ORIGINAL.has(op.id));

const findings = [];
const covered = new Map(); // node type name → cases run
let ran = 0;
let inScope = 0;
let failures = 0;

try {
  for (const entry of corpus) {
    let m;
    try {
      m = await mount(entry);
    } catch (e) {
      console.log(`SKIP  ${entry.label}: mount threw ${e.message}`);
      continue;
    }
    const { root, editor } = m;
    const hit = editor && targetNode(editor);
    root.remove();
    // THE PREDICATE: a top-level node the canvas renders that is not a textblock.
    if (!hit || hit.node.isTextblock) continue;
    inScope += 1;
    const nodeType = hit.node.type.name;
    let cases = 0;

    for (const side of ["before", "after"]) {
      for (const [keyLabel, key, mods] of KEYS) {
        for (const [actionLabel, act] of ACTIONS) {
          const where = `${entry.label} [${nodeType}] ${side} · ${keyLabel} · ${actionLabel}`;
          // Each case starts from its own fresh mount: a reset through the host
          // is refused while an earlier batch is unacknowledged, and a batch
          // that lands late would be charged to the NEXT case.
          const c = await mount(entry);
          const t = targetNode(c.editor);
          // PRECONDITION: exactly the three blocks, the target as the canvas
          // first projected it.
          const ids = topNodes(c.editor).map((n) => n.node.attrs.bpId);
          if (!t || t.node.type.name !== nodeType || ids.join() !== [...ORIGINAL].join()) {
            findings.push(`${where}: precondition — mounted ${JSON.stringify(ids)}`);
            c.root.remove();
            continue;
          }
          const caret = side === "before" ? t.pos - 1 : t.pos + t.node.nodeSize + 1;
          c.editor.view.dispatch(c.editor.state.tr.setSelection(TextSelection.create(c.editor.state.doc, caret)));
          c.ops.length = 0;
          try {
            if (key) press(c.editor.view.dom, key, mods);
            act(c.editor);
          } catch (e) {
            findings.push(`${where}: threw ${e.message.split("\n")[0]}`);
            c.root.remove();
            continue;
          }
          c.canvas.flushPendingChanges();
          await tick(10);
          cases += 1;
          ran += 1;
          // Loss is judged on the DOCUMENT (is every original block still there,
          // with its type?) and on the emitted batch.
          const after = topNodes(c.editor);
          const missing = [...ORIGINAL].filter((id) => !after.some((n) => n.node.attrs.bpId === id));
          const retyped = after.find((n) => n.node.attrs.bpId === TARGET && n.node.type.name !== nodeType);
          const lost = removals(c.ops);
          if (missing.length || retyped || lost.length) {
            findings.push(`${where}: lost ${[...new Set([...missing, ...lost.map((o) => o.id)])].join(",")}${retyped ? ` (target became ${retyped.node.type.name})` : ""}`);
          }
          c.root.remove();
        }
      }
    }
    covered.set(nodeType, (covered.get(nodeType) || 0) + cases);
    console.log(`ran   ${String(cases).padStart(3)} cases  ${entry.label} [${nodeType}]`);
  }

  // Control 1: the assertion CAN fail — a deliberate Backspace on a selected
  // block emits remove-block for it.
  {
    const m = await mount(corpus.find((c) => c.label === "divider"));
    const t = targetNode(m.editor);
    m.editor.view.dispatch(m.editor.state.tr.setSelection(NodeSelection.create(m.editor.state.doc, t.pos)));
    m.ops.length = 0;
    press(m.editor.view.dom, "Backspace", { keyCode: 8 });
    m.canvas.flushPendingChanges();
    await tick(5);
    if (!m.ops.some((op) => op.op === "remove-block" && op.id === TARGET)) {
      failures += 1;
      console.log("FAIL  control: a deliberate Backspace on a selected divider emitted no remove-block");
    } else {
      console.log("PASS  control: a deliberate Backspace on a selected divider emits remove-block");
    }
    m.root.remove();
  }

  // Control 2: coverage against the schema's non-textblock block nodes.
  {
    const m = await mount(corpus.find((c) => c.label === "paragraph"));
    const schema = m.editor.schema;
    const blockNodes = Object.values(schema.nodes).filter((n) => n.isBlock && !n.isTextblock && n.name !== "doc" && (n.spec.group || "").split(" ").includes("block"));
    const uncovered = blockNodes.map((n) => n.name).filter((n) => !covered.has(n)).sort();
    console.log(`cover ${covered.size} of ${blockNodes.length} schema non-text block nodes; not reached by the corpus: ${uncovered.join(", ") || "(none)"}`);
    // A schema node no stored block reaches is a block the matrix never tested.
    if (uncovered.length > 0) {
      failures += 1;
      console.log(`FAIL  control: the corpus does not reach ${uncovered.join(", ")} — add a stored block that projects to it`);
    }
    m.root.remove();
  }
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.stack}`);
}

console.log(`\n${inScope} non-text block(s) in scope, ${ran} case(s) run`);
if (inScope < 20) { failures += 1; console.log(`FAIL  only ${inScope} non-text blocks in scope — the predicate or the corpus is broken`); }
for (const f of findings) console.log(`FAIL  ${f}`);
failures += findings.length;
if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\ndata-loss key matrix: no untouched block was removed");
process.exit(0);
