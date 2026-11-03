import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");
assert.match(
  css,
  /\.bp-canvas-term__title-input\s*\{[^}]*font-family:\s*var\(--paper-font-mono\);[^}]*font-size:\s*0\.76rem;[^}]*line-height:\s*1\.6;[^}]*color:\s*var\(--paper-ink-soft\);/s,
  "terminal title input keeps the reader title typography outside its semantic span",
);
assert.match(
  css,
  /\.bp-canvas-term__foot-input\s*\{[^}]*font-family:\s*var\(--paper-font-mono\);[^}]*font-size:\s*0\.75rem;[^}]*line-height:\s*1\.6;[^}]*color:\s*var\(--paper-ink-soft\);/s,
  "terminal footer input keeps the reader footer typography outside its semantic node",
);

const jsdom = new JSDOM("<!doctype html><body></body>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = jsdom;
for (const name of [
  "CustomEvent",
  "document",
  "Event",
  "HTMLElement",
  "KeyboardEvent",
  "MutationObserver",
  "Node",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.ResizeObserver = class {
  observe() {}
  disconnect() {}
};

const { Callout } = await import("./callout-node.js");
const { Card } = await import("./card-node.js");
const { Stage } = await import("./stage-node.js");
const { Terminal } = await import("./terminal-node.js");

function mount(extension, attrs) {
  const current = { type: { name: extension.name }, attrs };
  const editor = {
    isEditable: true,
    state: { doc: { nodeAt: () => current } },
    chain: () => ({ command() { return this; }, run: () => true }),
    view: { dispatch() {} },
    commands: { undo() {}, redo() {} },
  };
  const view = extension.config.addNodeView()({ node: current, editor, getPos: () => 0 });
  document.body.appendChild(view.dom);
  return view;
}

const callout = mount(Callout, { tone: "warning", title: "Heads up" });
const card = mount(Card, {
  tone: "info",
  title: "Card title",
  action: { label: "Open the board", href: "https://example.com/board" },
});
const stage = mount(Stage, {
  kind: "gate",
  title: "Review",
  detail: "checks the criteria",
  source: true,
});
const terminal = mount(Terminal, { title: "bp tasks", live: true, footer: "q to quit" });

for (const [name, view] of Object.entries({ callout, card, stage, terminal })) {
  assert.equal(
    view.dom.getAttribute("data-bp-conformance-root"),
    "",
    `${name} exposes its mounted reader surface as the semantic root`,
  );
}

assert.ok(callout.dom.querySelector("[role='textbox']"), "callout title editor remains mounted");
assert.ok(card.dom.querySelector(".bp-canvas-card__controls"), "card controls remain mounted");
assert.ok(stage.dom.querySelector("input[data-test-id='paper-stage-title']"), "stage inputs remain mounted");
assert.ok(terminal.dom.querySelector(".bp-canvas-term__live-toggle"), "terminal controls remain mounted");

assert.ok(stage.dom.matches("div.bp-pnode.bp-pnode--src"), "stage mounts the canonical reader cell");
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__k")?.textContent, "gate");
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__t")?.textContent, "Review");
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__d")?.textContent, "checks the criteria");
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__f"), null);
assert.ok(
  stage.dom.querySelector(":scope > .bp-paper-contextual-controls.bp-canvas-stage__controls"),
  "stage controls have one removable editor-only boundary",
);

stage.update({
  type: { name: Stage.name },
  attrs: { kind: null, title: "Deploy", files: "release.ex", source: "queue.ex:42" },
});
assert.ok(stage.dom.matches("div.bp-pnode:not(.bp-pnode--src)"));
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__k"), null);
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__t")?.textContent, "Deploy");
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__f")?.textContent, "release.ex");
assert.equal(stage.dom.querySelector(":scope > .bp-pnode__src")?.textContent, "queue.ex:42");
assert.deepEqual(
  [...stage.dom.children]
    .filter((el) => el.classList.contains("bp-pnode__k") || el.classList.contains("bp-pnode__t") || el.classList.contains("bp-pnode__d") || el.classList.contains("bp-pnode__f") || el.classList.contains("bp-pnode__src"))
    .map((el) => el.className),
  ["bp-pnode__t", "bp-pnode__f", "bp-pnode__src"],
  "stage semantic cells stay in reader order after removal and insertion",
);

const terminalBar = terminal.dom.querySelector(":scope > .bp-term__bar");
assert.equal(terminalBar?.querySelector(":scope > span.bp-term__title")?.textContent, "bp tasks");
assert.ok(
  terminalBar?.querySelector(":scope > .bp-paper-contextual-controls.bp-canvas-term__bar-controls input"),
  "terminal title input remains mounted outside the semantic title",
);
const terminalFoot = terminal.dom.querySelector(":scope > .bp-term__foot");
assert.equal(terminalFoot?.childNodes.length, 1);
assert.equal(terminalFoot?.firstChild?.nodeType, window.Node.TEXT_NODE);
assert.equal(terminalFoot?.firstChild?.nodeValue, "q to quit");

terminal.update({
  type: { name: Terminal.name },
  attrs: { title: "deploy", live: false, footer: null },
});
assert.equal(terminalBar?.querySelector(":scope > span.bp-term__title")?.textContent, "deploy");
assert.equal(terminalBar?.querySelector(":scope > .bp-term__live")?.style.display, "none");
assert.equal(terminal.dom.querySelector(":scope > .bp-term__foot"), null, "absent footer has no semantic node");
terminal.update({
  type: { name: Terminal.name },
  attrs: { title: "deploy", live: false, footer: "esc" },
});
assert.equal(terminal.dom.querySelector(":scope > .bp-term__foot")?.textContent, "esc");

for (const view of [callout, card, stage, terminal]) {
  view.destroy?.();
  view.dom.remove();
}
window.close();

console.log("canvas widget text semantic roots preserve mounted editing: ok");
