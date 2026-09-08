import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { tiptapToBlock } from "../convert.js";
import "../__nested_list_carriers.test.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle;
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
await import("../index.js");
await import("./index.js");

const fixture = JSON.parse(readFileSync(new URL("../../../../test/support/fixtures/nested-list-carriers.json", import.meta.url))).blocks[0];
const clone = value => structuredClone(value);
function position(ed, text, offset = 0) {
  let found;
  ed.state.doc.descendants((node, pos) => { if (node.isText && node.text === text) found = pos + offset; });
  assert.notEqual(found, undefined, `missing text ${text}`);
  ed.commands.setTextSelection(found);
  return found;
}
function mount(tag, block) {
  const host = document.createElement(tag);
  const ops = [];
  if (tag === "bp-paper-canvas") {
    host.blocks = [block];
    host.addEventListener("bp-canvas-ops", e => ops.push(...e.detail.ops));
  } else {
    host.block = block;
    host.addEventListener("bp-op", e => ops.push(e.detail));
  }
  document.body.appendChild(host);
  return { host, ed: host._editor, ops, saved: () => tiptapToBlock(host._editor.getJSON(), block.id, "list") };
}

try {
  for (const tag of ["bp-paper-canvas", "bp-paper-editor"]) {
    const { host, ed, ops, saved } = mount(tag, fixture);
    try {
      assert.equal(ed.state.doc.textContent, "PlanBuildVerifyShipFlat siblingFallback parentAlias child");
      assert.deepEqual(saved().items, fixture.items, `${tag}: mounted no-op keeps nested frame metadata`);
      assert.equal(host.querySelector('[data-bp-list-frame-source]'), null);
      if (tag === "bp-paper-canvas") {
        assert.equal(host.flushPendingChanges(), false, "opening a nested list does not write it");
        assert.deepEqual(ops, []);
      }
      position(ed, "Build", 5);
      ed.commands.insertContent(" carefully");
      const edited = clone(fixture.items);
      edited[0].children[0].items[0].text = "Build carefully";
      assert.deepEqual(saved().items, edited, `${tag}: direct child text edit`);
      host.flushPendingChanges();
      assert.deepEqual(ops.at(-1).patch.items, edited);
      assert.equal(ed.commands.undo(), true);
      assert.deepEqual(saved().items, fixture.items, `${tag}: exact undo`);
      assert.equal(ed.commands.redo(), true);
      assert.deepEqual(saved().items, edited);
      ed.commands.undo();
      position(ed, "Build", 2);
      ed.commands.splitListItem("listItem");
      assert.equal(ed.state.doc.textContent, "PlanBuildVerifyShipFlat siblingFallback parentAlias child");
      const split = saved().items[0].children[0].items;
      assert.equal(split.filter(item => item.id === "build").length, 1, `${tag}: split keeps original item ID once`);
      assert.equal(split.length, 3);
      ed.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Backspace", code: "Backspace", bubbles: true, cancelable: true }));
      assert.deepEqual(saved().items, fixture.items, `${tag}: native Backspace joins the split child without metadata loss`);
      ed.commands.undo();
      ed.commands.undo();
      assert.deepEqual(saved().items, fixture.items, `${tag}: split undo restores child ownership`);
      const beforeBreak = ed.getJSON();
      position(ed, "Build", 2);
      ed.commands.setHardBreak();
      assert.deepEqual(ed.getJSON(), beforeBreak, "hard breaks remain rejected");
      const invalidStart = ed.state.schema.nodes.orderedList.create({ start: 3 },
        ed.state.schema.nodes.listItem.create(null, ed.state.schema.nodes.paragraph.create(null, ed.state.schema.text("Custom start"))));
      ed.view.dispatch(ed.state.tr.replaceWith(0, ed.state.doc.content.size, invalidStart));
      assert.deepEqual(ed.getJSON(), beforeBreak, "unsupported ordered starts cannot look saved");
      const invalidItem = ed.state.schema.nodes.listItem.create(null, [
        ed.state.schema.nodes.paragraph.create(null, ed.state.schema.text("First")),
        ed.state.schema.nodes.paragraph.create(null, ed.state.schema.text("Second")),
      ]);
      ed.view.dispatch(ed.state.tr.replaceWith(0, ed.state.doc.content.size,
        ed.state.schema.nodes.bulletList.create(null, invalidItem)));
      assert.deepEqual(ed.getJSON(), beforeBreak, "multiple paragraphs per item remain rejected");
    } finally { host.remove(); }

    const flat = { id: "flat", type: "list", ordered: false, items: [
      { id: "a", text: "Alpha", audit: 1 }, { id: "b", text: "Beta", audit: 2 }, { id: "c", text: "Gamma", audit: 3 },
    ] };
    const m = mount(tag, flat);
    try {
      position(m.ed, "Beta");
      m.ed.commands.sinkListItem("listItem");
      assert.deepEqual(m.saved().items, [
        { ...flat.items[0], children: [{ type: "list", ordered: false, items: [flat.items[1]] }] }, flat.items[2],
      ], `${tag}: indentation preserves carriers`);
      m.ed.commands.liftListItem("listItem");
      assert.deepEqual(m.saved().items, flat.items, `${tag}: outdent returns exact carriers`);
    } finally { m.host.remove(); }

    const middle = { id: "middle", type: "list", items: [{ id: "a", text: "Alpha", children: [
      { id: "frame", type: "list", ordered: true, audit: "frame metadata", items: flat.items.slice(1).concat({ id: "d", text: "Delta" }) },
    ] }] };
    const m2 = mount(tag, middle);
    try {
      position(m2.ed, "Gamma");
      m2.ed.commands.liftListItem("listItem");
      const frames = m2.saved().items.flatMap(item => item.children || []);
      assert.equal(frames.filter(frame => frame.id === "frame").length, 1, `${tag}: outdent frame split cannot duplicate identity`);
      assert.equal(m2.ed.state.doc.textContent, "AlphaBetaGammaDelta");
      m2.ed.commands.undo();
      assert.deepEqual(m2.saved().items, middle.items, `${tag}: middle-outdent undo restores frame metadata`);
    } finally { m2.host.remove(); }

    const pasted = mount(tag, { id: "paste", type: "list", items: ["Before"] });
    try {
      position(pasted.ed, "Before", 6);
      const paste = new window.Event("paste", { bubbles: true, cancelable: true });
      Object.defineProperty(paste, "clipboardData", { value: {
        types: ["text/html", "text/plain"], files: [],
        getData: type => type === "text/html"
          ? '<ul><li>Parent<ol data-bp-list-frame-source="spoof"><li data-bp-list-source="spoof"><strong>Child</strong><ul><li>Grandchild</li></ul></li></ol></li></ul>'
          : type === "text/plain" ? "Parent\nChild\nGrandchild" : "",
      } });
      pasted.ed.view.dom.dispatchEvent(paste);
      const items = pasted.saved().items;
      const nested = items.find(item => item.children)?.children;
      assert.ok(nested, `${tag}: pasted nested structure is serialized, not just visible`);
      assert.equal(nested[0].ordered, true);
      assert.deepEqual(nested[0].items, [{ content: [{ type: "strong", children: [{ type: "text", value: "Child" }] }],
        children: [{ type: "list", ordered: false, items: [[{ type: "text", value: "Grandchild" }]] }] }]);
      assert.equal(JSON.stringify(items).includes("spoof"), false, "HTML cannot supply private carrier metadata");
      pasted.host.flushPendingChanges();
      assert.deepEqual(pasted.ops.at(-1).patch.items, items);
      pasted.ed.commands.undo();
      assert.deepEqual(pasted.saved().items, ["Before"], `${tag}: nested paste undo restores original scalar`);
      pasted.ed.commands.redo();
      assert.deepEqual(pasted.saved().items, items);
    } finally { pasted.host.remove(); }
  }
  console.log("mounted nested list authoring and source ownership passed");
} finally { window.close(); }
