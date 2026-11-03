import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

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

for (const view of [callout, card, stage, terminal]) {
  view.destroy?.();
  view.dom.remove();
}
window.close();

console.log("canvas widget text semantic roots preserve mounted editing: ok");
