// Exercise the rendered controls, then inspect their emitted persistence patches.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true, url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element",
  "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: value => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const text = value => [{ type: "text", value }];
const table = { id: "table", type: "table", head: [text("Name"), text("Age")],
  rows: [[text("Ada"), text("36")], [text("Bob"), text("40")]] };
const section = { id: "section", type: "section", title: "Group",
  layout: { mode: "grid", tracks: 2, cells: { child: { span: 2 } } },
  blocks: [{ id: "child", type: "paragraph", content: text("Keep this") }] };
let cases = 0;
async function exercise(block, action, verify) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = structuredClone([block]);
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", event => batches.push(event.detail.ops));
  document.body.appendChild(canvas);
  try {
    await new Promise(resolve => setTimeout(resolve, 350));
    assert.equal(batches.length, 0, "mount must not author an edit");
    action(canvas);
    canvas.flushPendingChanges();
    assert.equal(batches.length, 1, "control emits exactly one batch");
    assert.equal(batches[0].length, 1, "control changes exactly one block");
    const [op] = batches[0];
    assert.equal(op.op, "patch-block");
    assert.equal(op.id, block.id);
    verify(op.patch, canvas);
    assert.equal(canvas.flushPendingChanges(), false, "flush does not duplicate the change");
    cases++;
  } finally { canvas.remove(); }
}
const click = selector => canvas => {
  const control = canvas.querySelector(selector);
  assert.ok(control, `rendered control ${selector}`);
  assert.equal(control.disabled, false);
  control.click();
};
const change = (canvas, id, value, event = "change") => {
  const control = canvas.querySelector(`[data-test-id="${id}"]`);
  assert.ok(control, `rendered control ${id}`);
  control.value = value;
  control.dispatchEvent(new window.Event(event, { bubbles: true }));
};

try {
  for (const [type, before, after, extra] of [
    ["field-boolean", false, true, {}],
    ["field-boolean", true, false, {}],
    ["field-select", "a", "b", { options: [{ value: "a", label: "Alpha" }, { value: "b", label: "Beta" }] }],
    ["field-datetime", "2026-09-05T09:00", "2026-09-06T14:30", {}],
    ["field-color", "#000000", "#12abef", {}],
  ]) {
    await exercise({ id: "field", type, value: before, label: "Keep label", ...extra }, canvas => {
      const control = canvas.querySelector(`[data-test-id="paper-field-${type}"]`);
      assert.ok(control, `native ${type} control mounts`);
      if (type === "field-boolean") control.checked = after;
      else control.value = after;
      control.dispatchEvent(new window.Event("change", { bubbles: true }));
    }, patch => assert.deepEqual(patch, { value: after }, `${type} preserves the exact value type`));
  }
  for (const [title, expected] of [
    ["Add row", { head: table.head, rows: [...table.rows, [[], []]] }],
    ["Remove row", { head: table.head, rows: table.rows.slice(0, 1) }],
    ["Add column", { head: [...table.head, []], rows: table.rows.map(row => [...row, []]) }],
    ["Remove column", { head: table.head.slice(0, 1), rows: table.rows.map(row => row.slice(0, 1)) }],
    ["Toggle header row", { head: [], rows: [table.head, ...table.rows] }],
  ]) {
    await exercise(table, click(`button[title="${title}"]`), patch => {
      assert.deepEqual(patch.rows, expected.rows, title);
      assert.deepEqual(patch.head ?? null, expected.head, title);
    });
  }
  for (const [id, mode, tracks] of [
    ["paper-section-mode", "stack", 2],
    ["paper-section-tracks-inc", "grid", 3],
    ["paper-section-tracks-dec", "grid", 1],
  ]) {
    await exercise(section, click(`[data-test-id="${id}"]`), patch => {
      assert.equal(patch.layout.mode, mode);
      assert.equal(patch.layout.tracks, tracks);
      assert.deepEqual(patch.layout.cells, section.layout.cells);
      if (patch.blocks) assert.deepEqual(patch.blocks, section.blocks);
    });
  }
  await exercise({ id: "action", type: "action", label: "Read", href: "/before" }, canvas => {
    change(canvas, "paper-action-href", "/after", "input");
    change(canvas, "paper-action-priority", "primary");
  }, patch => {
    assert.equal(patch.href, "/after");
    assert.equal(patch.priority, "primary");
    assert.equal(patch.label, "Read");
  });
  await exercise({ id: "card", type: "card", slots: {
    title: [{ type: "heading", text: "Keep title" }],
    body: [{ type: "paragraph", content: text("Keep body") }],
  } }, canvas => {
    change(canvas, "paper-card-action-label", "Visit");
    change(canvas, "paper-card-action-href", "/visit");
    change(canvas, "paper-card-action-priority", "primary");
    canvas.querySelector('[data-test-id="paper-card-media-src"]').dispatchEvent(
      new window.CustomEvent("bp-change", { bubbles: true, detail: { value: "/chosen.png" } }));
  }, patch => {
    assert.equal(patch.slots.title[0].text, "Keep title");
    assert.deepEqual(patch.slots.body, [{ type: "paragraph", content: text("Keep body") }]);
    assert.equal(patch.slots.media[0].src, "/chosen.png");
    assert.deepEqual(patch.slots.action[0], {
      type: "action", label: "Visit", href: "/visit", priority: "primary",
    });
  });
  console.log(`mounted control matrix: ${cases} interaction/payload cases passed`);
} finally { window.close(); }
