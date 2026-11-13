// __rte_move_focus.test.mjs — task-8205f1f56b0b9c2d: narrowing the window
// mid-edit moves the pane that holds the Classic rich text editor (LiveView's
// morphdom appends #studio-panes again behind the new crumb trail). A moved
// node loses the focus: the text was blurred, the caret was gone, and the next
// keystrokes went nowhere until the person clicked the text again. LiveView
// puts the focus back on a text input after a patch, but not on a
// contenteditable.
//
// Chrome blurs the text before it is taken out: `focusout` with no
// relatedTarget, while it is still connected. jsdom fires no event on a move,
// so `move()` plays Chrome's order: focusout, blur, then the move.
//
// Runs the TRACKED static asset under jsdom.
// Run: node ../paper-editor-host-tests/__rte_move_focus.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "MouseEvent", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
window.document.execCommand = () => true;
await import("../../priv/static/assets/bp-rich-text-editor.js");

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

function mount() {
  const from = document.createElement("section");
  const to = document.createElement("section");
  const other = document.createElement("input");
  document.body.append(from, to, other);
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", "<p>Hello world</p>");
  from.appendChild(el);
  const body = el.querySelector(".bp-rte-body");
  // jsdom has no contenteditable focus; a tabindex makes the text focusable.
  body.tabIndex = -1;
  return { el, to, other, body };
}

// The caret in the text, after "Hello" (offset 5 of the text node).
function typeAt(body, offset) {
  body.focus();
  const text = body.querySelector("p").firstChild;
  window.getSelection().collapse(text, offset);
  return text;
}

// What Chrome does when a focused node's ancestor is moved.
function move(el, to) {
  const active = document.activeElement;
  active.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true, relatedTarget: null }));
  active.blur();
  to.appendChild(el);
}

const tick = () => new Promise((r) => setTimeout(r, 0));

await check("the moved text keeps the focus and the caret", async () => {
  const { el, to, body } = mount();
  const text = typeAt(body, 5);
  move(el, to);
  assert.equal(document.activeElement, body, "the text has the focus after the move");
  const sel = window.getSelection();
  assert.equal(sel.anchorNode, text);
  assert.equal(sel.anchorOffset, 5);
});

await check("a selection, not only a caret, comes back", async () => {
  const { el, to, body } = mount();
  body.focus();
  const text = body.querySelector("p").firstChild;
  const range = document.createRange();
  range.setStart(text, 0);
  range.setEnd(text, 5);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(range);
  move(el, to);
  assert.equal(document.activeElement, body);
  assert.equal(window.getSelection().toString(), "Hello");
});

await check("a blur on its own, then a later move, does not take the focus back (control)", async () => {
  const { el, to, body } = mount();
  typeAt(body, 5);
  body.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true, relatedTarget: null }));
  body.blur();
  await tick();
  to.appendChild(el);
  assert.notEqual(document.activeElement, body);
});

await check("focus that went to another field stays there (control)", async () => {
  const { el, to, other, body } = mount();
  typeAt(body, 5);
  body.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true, relatedTarget: other }));
  other.focus();
  to.appendChild(el);
  assert.equal(document.activeElement, other);
});

await check("an editor taken out and not put back keeps nothing for later (control)", async () => {
  const { el, to, body } = mount();
  typeAt(body, 5);
  body.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true, relatedTarget: null }));
  body.blur();
  el.remove();
  await tick();
  to.appendChild(el);
  assert.notEqual(document.activeElement, body);
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");
