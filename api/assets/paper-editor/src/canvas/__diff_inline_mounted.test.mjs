import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

// task-bbfdcf4c80b8300d long tail: a diff's painted rows edit where the reader
// paints them. Before this, the diff was a read-only server paint whose text was
// editable only in the "Edit diff" disclosure, and a body edit wrote file:"" and
// lang:"" keys the author never set.
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

const DIFF = "diff --git a/lib/a.ex b/lib/a.ex\nindex 1..2 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1,2 +1,2 @@\n context\n-old line\n+new line";
// The reader's bytes (components.ex diff_html/1 + chat_diff_rows_html/1).
const r = (prefix, text) => `<div style="white-space: pre-wrap;">${prefix}${text}</div>`;
const html = `<div class="bp-diff text-xs"><div class="text-dim"><span>+1</span> <span>−1</span></div>` +
  `<div style="font-weight: 600;">lib/a.ex</div>${r("&nbsp;&nbsp;", "@@ -1,2 +1,2 @@")}${r("&nbsp;&nbsp;", "context")}${r("- ", "old line")}${r("+ ", "new line")}</div>`;

function paint(host, markup = html) {
  const hole = host.querySelector("[data-bp-fleet-body]");
  const event = new CustomEvent("bp-fleet-paint", { detail: { html: markup, sourceBlock: host.blocks[0] }, cancelable: true });
  if (hole.dispatchEvent(event)) hole.innerHTML = markup;
}
function mount() {
  const block = { id: "d", type: "diff", diff: DIFF };
  const host = document.createElement("bp-paper-canvas");
  host.blocks = [block];
  const batches = [];
  host.addEventListener("bp-canvas-ops", e => batches.push(e.detail));
  document.body.appendChild(host);
  paint(host);
  return { host, block, batches };
}
function input(el, text, prefix = "") {
  assert.equal(el.childNodes.length, 1);
  assert.equal(el.firstChild.nodeType, Node.TEXT_NODE);
  el.firstChild.nodeValue = prefix + text;
  el.dispatchEvent(new Event("input", { bubbles: true }));
}
function select(node, from, to = from) {
  const range = document.createRange();
  range.setStart(node, from);
  range.setEnd(node, to);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  return range;
}
const rows = host => [...host.querySelectorAll('[data-test-id^="paper-inline-diff-line"]')];

try {
  const { host, block, batches } = mount();
  try {
    const hosts = rows(host);
    assert.deepEqual(hosts.map(el => el.textContent), ["lib/a.ex", "\u00a0\u00a0@@ -1,2 +1,2 @@", "\u00a0\u00a0context", "- old line", "+ new line"],
      "every painted row's text edits where it reads; header lines paint nothing");
    assert.ok(hosts.every(el => el.childNodes.length === 1 && el.firstChild.nodeType === Node.TEXT_NODE),
      "decoration preserves every reader row as one bare text node");
    assert.equal(hosts[4].contentEditable, "plaintext-only");

    hosts[4].focus(); input(hosts[4], "newer line", "+ "); host.flushPendingChanges(); hosts[4].blur();
    const expected = DIFF.replace("+new line", "+newer line");
    assert.equal(host._editor.state.doc.firstChild.attrs.diff, expected, "only that stored line changes, its + kept");
    assert.deepEqual(batches.at(-1).ops.at(-1).patch, { diff: expected }, "no file/lang keys the author never set ride the patch");

    hosts[0].focus(); input(hosts[0], "lib/b.ex"); host.flushPendingChanges(); hosts[0].blur();
    assert.ok(host._editor.state.doc.firstChild.attrs.diff.includes("\n+++ b/lib/b.ex\n"), "a path row edits the path after +++ b/");
    assert.equal(block.diff, DIFF, "the source block is never mutated in place");
  } finally { host.remove(); }

  const hostile = mount();
  try {
    const hosts = rows(hostile.host);
    const plus = hosts[4];
    const text = plus.firstChild;
    plus.focus();
    plus.dispatchEvent(new KeyboardEvent("keydown", { key: "Home", bubbles: true, cancelable: true }));
    select(text, 0);
    const backspace = new KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true });
    plus.dispatchEvent(backspace);
    assert.equal(backspace.defaultPrevented, true, "Home then Backspace cannot remove the generated + marker");
    assert.equal(plus.textContent, "+ new line");

    const selectAll = new KeyboardEvent("keydown", { key: "a", ctrlKey: true, bubbles: true, cancelable: true });
    plus.dispatchEvent(selectAll);
    const range = window.getSelection().getRangeAt(0);
    assert.equal(range.startContainer, text);
    assert.equal(range.startOffset, 2, "Mod+A starts after the generated marker");
    assert.equal(range.endOffset, text.length);
    input(plus, "+ literal", "+ ");
    hostile.host.flushPendingChanges();
    const stored = hostile.host._editor.state.doc.firstChild.attrs.diff;
    assert.ok(stored.includes("\n++ literal"), "a payload beginning with + is stored after the original + prefix");
    assert.ok(stored.includes("\n-old line\n++ literal"), "the neighboring line and original stored marker stay unchanged");
    assert.ok(stored.startsWith("diff --git a/lib/a.ex b/lib/a.ex\nindex 1..2 100644\n--- a/lib/a.ex\n+++ b/lib/a.ex\n"),
      "header and path bytes stay unchanged");
  } finally { hostile.host.remove(); }

  const mismatch = mount();
  try {
    paint(mismatch.host, `<div class="bp-diff text-xs"><div class="text-dim">x</div>${r("+ ", "something else")}</div>`);
    assert.equal(rows(mismatch.host).length, 0, "a paint that does not match the stored lines never maps onto them");
  } finally { mismatch.host.remove(); }
  console.log("diff inline: bare reader text nodes edit behind protected markers; hostile prefix replacement is lossless; mismatched paints refused");
} finally { window.close(); }
