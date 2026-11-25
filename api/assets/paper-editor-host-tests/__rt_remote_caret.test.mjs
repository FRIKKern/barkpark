// __rt_remote_caret.test.mjs (task-5f946e8639cb479f, #28349 r3 review K2):
// another editor's save put into this page's open rich text editor
// (bp-rt-remote.js) put the caret at the END of its block when theirs
// changed that block, so the next letters landed at the paragraph's end
// ("X one twoQ" instead of "X oneQ two"). The caret now stays after the
// same characters, as TanStack's editor keeps its selection through a
// remote text patch.
//
// Runs the TRACKED asset api/priv/static/assets/bp-rt-remote.js under jsdom.
// The editor is a stand-in: `value` paints the body as the real editor's
// first-paint path does, which is all bp-rt-remote reads.
//
// Run: node ../paper-editor-host-tests/__rt_remote_caret.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const NAME = "doc[meta].rt";
const dom = new JSDOM(
  `<!doctype html><html><body><div data-pt-subfield="${NAME}">` +
    '<bp-rich-text-editor data-bridge-target="h"><div class="bp-rte-body"></div></bp-rich-text-editor>' +
    '<input type="hidden" id="h"></div></body></html>',
);
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
globalThis.NodeFilter = window.NodeFilter;

window.customElements.define(
  "bp-rich-text-editor",
  class extends window.HTMLElement {
    get value() {
      return this.querySelector(".bp-rte-body").innerHTML;
    }
    set value(html) {
      this.querySelector(".bp-rte-body").innerHTML = html;
    }
  },
);

await import("../../priv/static/assets/bp-rt-remote.js");

const editor = document.querySelector("bp-rich-text-editor");
const body = editor.querySelector(".bp-rte-body");
let seq = 0;

// The caret at `at` characters into block `i`.
const putCaret = (i, at) => {
  const walk = document.createTreeWalker(body.children[i], window.NodeFilter.SHOW_TEXT);
  let t;
  while ((t = walk.nextNode())) {
    if (at <= t.length) break;
    at -= t.length;
  }
  const r = document.createRange();
  r.setStart(t, at);
  r.collapse(true);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(r);
};

// What typing a letter at the caret makes of the block it is in.
const typeAt = (letter) => {
  const r = window.getSelection().getRangeAt(0);
  r.insertNode(document.createTextNode(letter));
  let block = r.startContainer;
  while (block.parentNode !== body) block = block.parentNode;
  return block.textContent;
};

const theirs = (html) =>
  window.dispatchEvent(
    new window.CustomEvent("phx:bp:rt-remote", { detail: { values: { [NAME]: { seq: ++seq, html } } } }),
  );

const caseOf = (label, mine, [i, at], next, expected) => {
  body.innerHTML = mine;
  putCaret(i, at);
  theirs(next);
  assert.equal(typeAt("Q"), expected, label);
};

caseOf("the task's case: text added before the caret", "<p>one two</p>", [0, 3], "<p>X one two</p>", "X oneQ two");
caseOf("text added after the caret", "<p>one two</p>", [0, 3], "<p>one two three</p>", "oneQ two three");
caseOf("text removed before the caret", "<p>one two three</p>", [0, 7], "<p>two three</p>", "twoQ three");
caseOf("a word changed before the caret", "<p>one two three</p>", [0, 7], "<p>uno two three</p>", "uno twoQ three");
caseOf(
  "across marks: the caret in a later text node",
  "<p>one <strong>two</strong> three</p>",
  [0, 7],
  "<p>A one <strong>two</strong> three</p>",
  "A one twoQ three",
);
caseOf(
  "inside the part theirs replaced: after what replaced it",
  "<p>one two three</p>",
  [0, 5],
  "<p>one 2 three</p>",
  "one 2Q three",
);
caseOf(
  "a paragraph theirs added above, the caret's block unchanged",
  "<p>one</p><p>two words</p>",
  [1, 3],
  "<p>one</p><p>new</p><p>two words</p>",
  "twoQ words",
);
caseOf(
  "another block changed: the caret's block keeps its offset",
  "<p>one</p><p>two words</p>",
  [1, 3],
  "<p>one more</p><p>two words</p>",
  "twoQ words",
);

// task-cfd4254783206ad7 (#28716 review): the change was read as starting at
// the first letter that differs, so beside the same letters the caret went
// inside their word: "say h|ello" with "hi " added made "say h|i hello", and
// "two " removed from "one t|wo three" made "one tQhree".
caseOf("an insert beside the same letters: the caret stays outside it", "<p>say hello</p>", [0, 5], "<p>say hi hello</p>", "say hi hQello");
caseOf("a delete beside the same letters: the caret goes where it was", "<p>one two three</p>", [0, 5], "<p>one three</p>", "one Qthree");
caseOf("an insert after the caret beside the same letters", "<p>say hello</p>", [0, 3], "<p>say hi hello</p>", "sayQ hi hello");

// A selection stays selected, in its direction, where main collapsed it to
// its start.
const putPoint = (i, at) => {
  const walk = document.createTreeWalker(body.children[i], window.NodeFilter.SHOW_TEXT);
  let t;
  while ((t = walk.nextNode())) {
    if (at <= t.length) break;
    at -= t.length;
  }
  return [t, at];
};
const selected = (label, mine, from, to, next, text, backward) => {
  body.innerHTML = mine;
  const [a, f] = [putPoint(...from), putPoint(...to)];
  window.getSelection().setBaseAndExtent(a[0], a[1], f[0], f[1]);
  theirs(next);
  const sel = window.getSelection();
  assert.equal(sel.toString(), text, label);
  const r = document.createRange();
  r.setStart(sel.anchorNode, sel.anchorOffset);
  assert.equal(r.comparePoint(sel.focusNode, sel.focusOffset), backward ? -1 : 1, label + ": its direction");
};

selected("a selected word after text theirs added before it", "<p>one two three</p>", [0, 8], [0, 13], "<p>X one two three</p>", "three", false);
selected("the same, selected backwards", "<p>one two three</p>", [0, 13], [0, 8], "<p>X one two three</p>", "three", true);
selected(
  "a selection across two blocks",
  "<p>one two</p><p>three four</p>",
  [0, 4],
  [1, 5],
  "<p>X one two</p><p>three four</p>",
  "twothree",
  false,
);

console.log("rt-remote caret: all cases pass");
