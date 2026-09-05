import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const jsdom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = jsdom;
for (const name of [
  "CustomEvent",
  "document",
  "Event",
  "HTMLElement",
  "Node",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);

const { Diagram, BP_DIAGRAM_NODE_NAME } = await import("./diagram-node.js");
const mount = (attrs, runtime = null) => {
  let current = { type: { name: BP_DIAGRAM_NODE_NAME }, attrs: { ...attrs } };
  const editor = {
    isEditable: true,
    state: { doc: { nodeAt: () => current } },
    chain() {
      return {
        command(fn) {
          fn({
            tr: {
              setNodeMarkup(_pos, _type, nextAttrs) {
                current = {
                  type: { name: BP_DIAGRAM_NODE_NAME },
                  attrs: nextAttrs,
                };
              },
            },
          });
          return this;
        },
        run() {
          return true;
        },
      };
    },
  };
  window.BarkparkPaperMermaid = runtime;
  const view = Diagram.config.addNodeView()({
    node: current,
    editor,
    getPos: () => 0,
  });
  document.body.appendChild(view.dom);
  return { view, editor, current: () => current };
};

const renderCalls = [];
const runtime = {
  runMermaid() {
    const pre = this.el.querySelector("pre.mermaid");
    renderCalls.push(pre.dataset.bpSrc);
    pre.dataset.processed = "true";
    const svg = document.createElement("svg");
    svg.dataset.source = pre.dataset.bpSrc;
    pre.replaceChildren(svg);
  },
};

const mounted = mount(
  {
    bpId: "diagram-1",
    bpType: "diagram",
    source: "graph TD\n  A-->B",
    caption: "Figure 3. Request flow",
  },
  runtime,
);
try {
  const { dom } = mounted.view;
  const figure = dom.querySelector("figure.bp-canvas-diagram-figure");
  const preview = figure.querySelector("pre.mermaid");
  const caption = figure.querySelector("figcaption.bp-figcaption");
  const disclosure = dom.querySelector("details.bp-canvas-diagram-editor");
  const area = disclosure.querySelector("textarea[aria-label='Mermaid source']");

  assert.ok(figure && preview && caption && disclosure && area,
    "the mounted node uses reader figure anatomy plus disclosed edit controls");
  assert.equal(disclosure.open, false, "raw source controls are closed at rest");
  assert.equal(preview.dataset.bpSrc, "graph TD\n  A-->B",
    "the canonical theme rerender source is stashed on the Mermaid host");
  assert.equal(preview.querySelector("svg").dataset.source, "graph TD\n  A-->B",
    "the shared Mermaid runtime renders the resting preview");
  assert.equal(caption.querySelector("b").textContent, "Figure 3.");
  assert.equal(caption.textContent, "Figure 3. Request flow");

  disclosure.open = true;
  area.value = "graph LR\n  B-->C";
  area.dispatchEvent(new window.Event("input", { bubbles: true }));
  dom.dispatchEvent(new window.CustomEvent("bp-flush-node"));
  assert.equal(mounted.current().attrs.source, "graph LR\n  B-->C",
    "flushing commits the latest disclosed source to the node attr");
  assert.equal(preview.dataset.bpSrc, "graph LR\n  B-->C");
  assert.equal(preview.querySelector("svg").dataset.source, "graph LR\n  B-->C",
    "the saved source refreshes the rendered preview");
  assert.deepEqual(renderCalls, ["graph TD\n  A-->B", "graph LR\n  B-->C"]);
} finally {
  mounted.view.destroy();
  mounted.view.dom.remove();
}

const fallback = mount({
  bpId: "diagram-2",
  bpType: "diagram",
  source: "graph TD\n  Offline-->Source",
  caption: null,
});
try {
  const preview = fallback.view.dom.querySelector("pre.mermaid");
  assert.equal(preview.textContent, "graph TD\n  Offline-->Source",
    "without the Mermaid runtime the preview degrades to readable source");
  assert.equal(fallback.view.dom.querySelector("figcaption").hidden, true,
    "a missing caption stays absent like reader output");
} finally {
  fallback.view.destroy();
  fallback.view.dom.remove();
  window.close();
}

console.log("mounted diagram reader-preview regression passed");
