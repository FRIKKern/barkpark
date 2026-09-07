import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

for (const path of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(path, import.meta.url), "utf8");
  const rule = css.match(/\.bp-paper-surface \.bp-canvas-stats-inline > \.bp-paper-surface\s*\{([^}]+)\}/)?.[1];
  assert.ok(rule, "nested Stats paint retains the enclosing reader evidence band");
  for (const token of ["band", "band-max", "fill", "gutter", "width", "pull"]) {
    assert.ok(rule.includes(`--bp-evidence-${token}: inherit;`), `${path}: inherit ${token}`);
  }
}

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("../index.js");

const cell = '<div class="bp-stat"><div class="bp-stat__v">10<span class="bp-stat__denom">/20</span><span class="bp-stat__unit">%</span></div><div class="bp-stat__l">Changes</div></div>';
const sibling = '<div class="bp-stat"><div class="bp-stat__v">20</div><div class="bp-stat__l">Days</div></div>';
function paint(host, html, sourceBlock = host.blocks[0]) {
  const hole = host.querySelector("[data-bp-fleet-body]");
  const event = new CustomEvent("bp-fleet-paint", { detail: { html, sourceBlock }, cancelable: true });
  if (hole.dispatchEvent(event)) hole.innerHTML = html;
}
function mount(type, attrs = {}, acknowledged = false) {
  const item = { value: 10, label: "Changes", denom: "20", unit: "%", source: "commit:1234567", custom: { untouched: true } };
  const block = { id: "stats", type, ...(type === "stat" ? item : { items: [item, { value: "20", label: "Days", extra: [1, 2] }], sourceDefault: "paper:original" }), audit: { keep: true }, ...attrs };
  const host = document.createElement("bp-paper-canvas");
  host.acknowledgedSaves = acknowledged;
  host.blocks = [block];
  const ops = [];
  const batches = [];
  host.addEventListener("bp-canvas-ops", e => { ops.push(...e.detail.ops); batches.push(e.detail); });
  document.body.appendChild(host);
  const html = type === "stat" ? cell : `<div class="bp-stats">${cell}${sibling}</div>`;
  paint(host, html);
  return { host, block, ops, batches, html };
}
function input(el, text) { el.textContent = text; el.dispatchEvent(new Event("input", { bubbles: true })); }
function key(el, name, extra = {}) { el.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...extra })); }

try {
  for (const type of ["stat", "stats", "stat-grid"]) {
    const { host, block, ops, html } = mount(type);
    try {
      const label = host.querySelector('[aria-label="Stat label"]');
      const value = host.querySelector('[aria-label="Stat value"]');
      assert.ok(label, `${type}: visible label is an inline textbox`);
      assert.ok(label.closest(".bp-canvas-stats-inline"), "Stats has its scoped reader-token boundary");
      assert.ok(value, `${type}: visible value is an inline textbox`);
      assert.equal(label.contentEditable, "plaintext-only");
      assert.equal(value.parentElement.querySelector('.bp-stat__denom').textContent, "/20");
      assert.equal(host.querySelector(".bp-paper-stats-config").open, false, "JSON is a closed fallback");
      value.focus(); value.blur(); host.flushPendingChanges();
      assert.deepEqual(ops, [], "focus/blur retains numeric carriers without an authored change");
      label.focus(); input(label, "Edited directly");
      key(label, "a", { metaKey: true });
      assert.equal(window.getSelection().toString(), "Edited directly", "select-all stays inside the field");
      assert.equal(document.activeElement, label, "select-all does not focus the outer canvas");
      paint(host, html);
      assert.equal(document.activeElement, label, "server repaint preserves the native editing host");
      assert.equal(label.textContent, "Edited directly", "stale paint cannot erase pending text");
      key(label, "z", { metaKey: true });
      assert.equal(label.textContent, "Changes");
      key(label, "z", { metaKey: true, shiftKey: true });
      assert.equal(label.textContent, "Edited directly");
      host.flushPendingChanges();
      const expected = structuredClone(block);
      if (type === "stat") expected.label = "Edited directly";
      else expected.items[0].label = "Edited directly";
      assert.deepEqual({ ...block, ...ops.at(-1).patch }, expected, "only the selected label changes");
      label.blur();
      assert.equal(host.querySelector('[aria-label="Stat label"]').textContent, "Edited directly");
    } finally { host.remove(); }
  }
  for (const attrs of [{ locked: true }, { query: { label: "live-data" } }]) {
    const { host, ops } = mount("stats", attrs);
    try {
      assert.equal(host.querySelector('[aria-label="Stat value"]'), null, "locked/derived values are not authored inline");
      host.flushPendingChanges(); assert.deepEqual(ops, []);
    } finally { host.remove(); }
  }
  const composition = mount("stats");
  try {
    const label = composition.host.querySelector('[aria-label="Stat label"]');
    label.focus();
    input(label, "Two ");
    assert.equal(label.textContent, "Two ", "typing a space must not trim it before the next word");
    label.dispatchEvent(new Event("compositionstart", { bubbles: true }));
    input(label, "日本語");
    assert.equal(composition.host._editor.state.doc.firstChild.attrs.bpBlock.items[0].label, "Two ");
    label.dispatchEvent(new Event("compositionend", { bubbles: true }));
    composition.host.flushPendingChanges();
    assert.equal(composition.ops.at(-1).patch.items[0].label, "日本語");
    assert.deepEqual(composition.ops.at(-1).patch.items[1], composition.block.items[1]);
    label.blur();
    const value = composition.host.querySelector('[aria-label="Stat value"]');
    value.focus(); input(value, "12.50 USD");
    composition.host.flushPendingChanges();
    assert.equal(composition.ops.at(-1).patch.items[0].value, "12.50 USD", "display strings are never numerically coerced");
    assert.equal(composition.ops.at(-1).patch.items[0].denom, "20");
    value.blur();
    const fallback = composition.host.querySelector('.bp-fleet-edit-area');
    const rows = JSON.parse(fallback.value);
    assert.equal(rows[0].label, "日本語", "fallback starts from the latest inline edits");
    assert.equal(rows[0].value, "12.50 USD");
    rows[1].label = "Fallback edit";
    fallback.value = JSON.stringify(rows);
    fallback.dispatchEvent(new Event("input", { bubbles: true }));
    composition.host.flushPendingChanges();
    assert.equal(composition.ops.at(-1).patch.items[0].label, "日本語");
    assert.equal(composition.ops.at(-1).patch.items[1].label, "Fallback edit");
    assert.deepEqual(composition.ops.at(-1).patch.audit, composition.block.audit);
  } finally { composition.host.remove(); }
  const mixed = mount("stats", { items: [null, { value: "", label: "Hidden" }, { value: "20", label: "Days", extra: 7 }] });
  try {
    paint(mixed.host, `<div class="bp-stats"><div class="bp-dataviz--empty">Empty</div>${sibling}</div>`, mixed.block);
    const label = mixed.host.querySelector('[aria-label="Stat label"]');
    label.focus(); input(label, "Correct row"); mixed.host.flushPendingChanges();
    assert.deepEqual(mixed.ops.at(-1).patch.items, [null, { value: "", label: "Hidden" }, { value: "20", label: "Correct row", extra: 7 }]);
  } finally { mixed.host.remove(); }
  const concurrent = mount("stats", {}, true);
  try {
    const label = concurrent.host.querySelector('[aria-label="Stat label"]');
    label.focus(); input(label, "Local draft");
    const remote = structuredClone(concurrent.block);
    remote.items.reverse();
    remote.audit.remote = true;
    concurrent.host.applyServerBlocks([remote]);
    assert.equal(label.textContent, "Local draft", "remote reorder cannot erase the local field");
    concurrent.host.flushPendingChanges();
    assert.deepEqual(concurrent.batches.at(-1).conflictBlocks, [remote], "remote collection reorder requires conflict recovery, never silent stale array replacement");
    concurrent.host.resolveConflictWithServerBlocks([remote]);
    assert.deepEqual(concurrent.host._editor.state.doc.firstChild.attrs.bpBlock, remote, "Use latest retains the exact remote array, values and metadata");
  } finally { concurrent.host.remove(); }
  console.log("stats inline: authored values/labels, native focus, repaint, undo/redo, exact preservation and locked/query guards passed");
} finally { window.close(); }
