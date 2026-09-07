import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

// An unstyled reader uses browser paragraph margins, not article tokens. Keep
// the public shell and standalone editor mirrors scoped to that explicit case.
for (const file of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.match(css, /\[data-paper-palette="legacy"\] \.bp-paper-editor-body \.ProseMirror > p\s*\{\s*margin: 1em 0;\s*\}/,
    "legacy paragraphs retain reader spacing without changing article typography");
  assert.match(css, /\[data-paper-palette="legacy"\] \.bp-paper-contextual-controls\s*\{[^}]*bottom: 100%;/s,
    "legacy fallback control sits above, not over, authored text");
  assert.match(css, /\[data-paper-palette="legacy"\] \.bp-paper-contextual-controls\[open\]\s*\{[^}]*position: relative;/s,
    "opened legacy configuration remains reachable in normal flow");
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

const first = '<div class="bp-card bp-card--info"><div class="bp-card__t">Title</div><div class="bp-card__d">Body</div></div>';
const second = '<div class="bp-card"><div class="bp-card__t">Sibling</div><div class="bp-card__d">Untouched</div></div>';
const html = `<div class="bp-cards">${first}${second}</div>`;
function paint(host, markup = html, sourceBlock = host.blocks[0]) {
  const hole = host.querySelector("[data-bp-fleet-body]");
  const event = new CustomEvent("bp-fleet-paint", { detail: { html: markup, sourceBlock }, cancelable: true });
  if (hole.dispatchEvent(event)) hole.innerHTML = markup;
}
function mount(attrs = {}, acknowledged = false, palette = null) {
  const block = { id: "legacy", type: "cards", items: [
    { id: "first", title: "Title", text: "Body", tone: "info", href: "/kept", audit: { keep: true } },
    { id: "second", title: "Sibling", text: "Untouched", extra: [1, 2] },
  ], audit: { collection: true }, ...attrs };
  const host = document.createElement("bp-paper-canvas");
  if (palette) host.setAttribute("data-paper-palette", palette);
  host.acknowledgedSaves = acknowledged;
  host.blocks = [block];
  const batches = [];
  host.addEventListener("bp-canvas-ops", e => batches.push(e.detail));
  document.body.appendChild(host);
  paint(host);
  return { host, block, batches };
}
function input(el, text) { el.textContent = text; el.dispatchEvent(new Event("input", { bubbles: true })); }
function key(el, name, extra = {}) { el.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...extra })); }

try {
  for (const palette of ["legacy", "article"]) {
    const row = mount({}, false, palette);
    try {
      assert.equal(row.host.querySelector("[data-bp-fleet-body]").classList.contains("bp-paper-surface"),
        palette !== "legacy", "paint inherits the reader palette instead of restyling legacy content");
      assert.ok(row.host.querySelector('[aria-label="Card title"]'), "legacy palette still supports native editing");
    } finally { row.host.remove(); }
  }
  for (const type of ["figure", "task-list"]) {
    const row = mount({ type }, false, "legacy");
    try {
      assert.equal(row.host.querySelector("[data-bp-fleet-body]").classList.contains("bp-paper-surface"), false,
        `${type} paint also inherits the legacy reader palette`);
    } finally { row.host.remove(); }
  }
  const { host, block, batches } = mount();
  try {
    const title = host.querySelector('[aria-label="Card title"]');
    const body = host.querySelector('[aria-label="Card body"]');
    assert.ok(title, "legacy Cards title edits where it is rendered");
    assert.ok(body, "legacy Cards body edits where it is rendered");
    assert.equal(title.contentEditable, "plaintext-only");
    assert.equal(host.querySelector(".bp-paper-cards-config").open, false);
    title.focus(); title.blur(); host.flushPendingChanges();
    assert.deepEqual(batches, [], "focus/blur is not an authored change");
    title.focus(); input(title, "Direct title");
    key(title, "a", { metaKey: true });
    assert.equal(window.getSelection().toString(), "Direct title");
    paint(host, html, block);
    assert.equal(document.activeElement, title);
    assert.equal(title.textContent, "Direct title", "old paint cannot erase focused text");
    key(title, "z", { metaKey: true });
    assert.equal(title.textContent, "Title");
    key(title, "z", { metaKey: true, shiftKey: true });
    assert.equal(title.textContent, "Direct title");
    body.focus(); input(body, "Direct body ");
    assert.equal(body.textContent, "Direct body ", "typing keeps its trailing space");
    host.flushPendingChanges();
    const expected = structuredClone(block);
    expected.items[0].title = "Direct title";
    expected.items[0].text = "Direct body ";
    const { id, type, ...expectedPatch } = expected;
    assert.deepEqual(batches.at(-1).ops.at(-1).patch, expectedPatch, "only the two authored fields change");
    assert.deepEqual(host._editor.state.doc.firstChild.attrs.bpBlock, expected, "legacy block identity/type remain unchanged");
    body.blur();
    const fallback = host.querySelector('[aria-label="edit cards content"]');
    const items = JSON.parse(fallback.value);
    assert.equal(items[0].title, "Direct title");
    assert.equal(items[0].text, "Direct body ");
    items[1].text = "Fallback sibling";
    fallback.value = JSON.stringify(items);
    fallback.dispatchEvent(new Event("input", { bubbles: true }));
    host.flushPendingChanges();
    expected.items[1].text = "Fallback sibling";
    assert.deepEqual(host._editor.state.doc.firstChild.attrs.bpBlock, expected);
  } finally { host.remove(); }
  for (const attrs of [{ locked: true }, { query: { source: "derived" } }]) {
    const row = mount(attrs);
    try { assert.equal(row.host.querySelector('[aria-label="Card title"]'), null); }
    finally { row.host.remove(); }
  }
  const mixed = mount({ items: [null, { title: "Title", text: "Body", extra: 7 }, { title: "Sibling", text: "Untouched" }] });
  try {
    paint(mixed.host, `<div class="bp-cards"><div class="bp-card"></div>${first}${second}</div>`);
    const body = mixed.host.querySelector('[aria-label="Card body"]');
    body.focus(); input(body, "Correct source row"); mixed.host.flushPendingChanges();
    assert.deepEqual(mixed.batches.at(-1).ops.at(-1).patch.items,
      [null, { title: "Title", text: "Correct source row", extra: 7 }, { title: "Sibling", text: "Untouched" }]);
    body.blur();
    paint(mixed.host, `<div class="bp-cards">${first}</div>`);
    assert.equal(mixed.host.querySelector('[aria-label="Card title"]'), null, "mismatched paint never maps onto an arbitrary item");
  } finally { mixed.host.remove(); }
  const numeric = mount({ items: [{ title: 12.5, text: "Body" }] });
  try {
    paint(numeric.host, `<div class="bp-cards">${first.replace(">Title<", ">12.5<")}</div>`);
    const title = numeric.host.querySelector('[aria-label="Card title"]');
    title.focus(); title.blur(); numeric.host.flushPendingChanges();
    assert.deepEqual(numeric.batches, [], "no-op focus preserves a numeric title carrier");
  } finally { numeric.host.remove(); }
  const concurrent = mount({}, true);
  try {
    const title = concurrent.host.querySelector('[aria-label="Card title"]');
    title.focus(); input(title, "Local draft");
    const remote = structuredClone(concurrent.block);
    remote.items.reverse(); remote.audit.remote = true;
    concurrent.host.applyServerBlocks([remote]);
    assert.equal(title.textContent, "Local draft");
    concurrent.host.flushPendingChanges();
    assert.deepEqual(concurrent.batches.at(-1).conflictBlocks, [remote]);
    concurrent.host.resolveConflictWithServerBlocks([remote]);
    assert.deepEqual(concurrent.host._editor.state.doc.firstChild.attrs.bpBlock, remote);
  } finally { concurrent.host.remove(); }
  console.log("legacy Cards inline: title/body, native selection/history, paint, fallback and exact conflict preservation passed");
} finally { window.close(); }
