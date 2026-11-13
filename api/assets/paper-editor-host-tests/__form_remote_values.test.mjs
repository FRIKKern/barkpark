// __form_remote_values.test.mjs — task-e6ef964ac2e41d5a: another editor saves
// the field this tab has focused. A LiveView patch never touches the focused
// input, so it kept the old text and the next keystroke posted it back over the
// other's words. The page now hears `bp:form-remote-values` (each changed text
// field: new value, value shown before) and sets the focused input when it
// still shows exactly the old value.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-array-focus.js under
// jsdom and dispatches the window event LiveView dispatches for a push_event.
//
// Run: node ../paper-editor-host-tests/__form_remote_values.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "MouseEvent", "HTMLElement", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-array-focus.js");

function mount(title, excerpt) {
  document.body.innerHTML =
    `<form id="editor-form"><input type="hidden" name="_bp_seen" value="{}">` +
    `<input type="text" name="doc[title]" value="${title}">` +
    `<textarea name="doc[excerpt]">${excerpt}</textarea></form>` +
    `<form id="other-form"><input type="text" name="doc[title]" value="${title}"></form>`;
  return {
    title: document.querySelector('#editor-form [name="doc[title]"]'),
    excerpt: document.querySelector('#editor-form [name="doc[excerpt]"]'),
    other: document.querySelector('#other-form [name="doc[title]"]'),
  };
}

const push = (values, seqs) =>
  window.dispatchEvent(
    new window.CustomEvent("phx:bp:form-remote-values", { detail: seqs ? { values, seqs } : { values } }),
  );

const seen = () => JSON.parse(document.querySelector('#editor-form [name="_bp_seen"]').value);

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

check("the focused field that shows the old value takes the other's words, and keeps focus", () => {
  const { title } = mount("Fixture post A2 A5", "First");
  title.focus();
  title.setSelectionRange(18, 18);
  push({ "doc[title]": { value: "Fixture post A2 A5 B3", was: "Fixture post A2 A5" } });
  assert.equal(title.value, "Fixture post A2 A5 B3");
  assert.equal(document.activeElement, title, "focus stays");
  assert.equal(title.selectionStart, 18, "the caret stays where the person left it");
});

check("a caret after the other's change moves with the text", () => {
  const { title } = mount("Hello world", "First");
  title.focus();
  title.setSelectionRange(11, 11);
  push({ "doc[title]": { value: "Hello, big world", was: "Hello world" } });
  assert.equal(title.value, "Hello, big world");
  assert.equal(title.selectionStart, 16);
});

check("a textarea is set the same way", () => {
  const { excerpt } = mount("T", "First line");
  excerpt.focus();
  excerpt.setSelectionRange(0, 0);
  push({ "doc[excerpt]": { value: "New first line", was: "First line" } });
  assert.equal(excerpt.value, "New first line");
  assert.equal(excerpt.selectionStart, 0);
});

check("typing not yet sent (the field no longer shows the old value) is kept", () => {
  const { title } = mount("Fixture post A2 A5", "First");
  title.focus();
  title.value = "Fixture post A2 A5 A7";
  push({ "doc[title]": { value: "Fixture post A2 A5 B3", was: "Fixture post A2 A5" } });
  assert.equal(title.value, "Fixture post A2 A5 A7");
});

check("a field without focus is left to the LiveView patch", () => {
  const { title, excerpt } = mount("Old", "First");
  excerpt.focus();
  push({ "doc[title]": { value: "New", was: "Old" } });
  assert.equal(title.value, "Old");
});

check("only the editor form: a focused input of the same name elsewhere is not touched", () => {
  const { other } = mount("Old", "First");
  other.focus();
  push({ "doc[title]": { value: "New", was: "Old" } });
  assert.equal(other.value, "Old");
});

// task-35956a566dd2c862: the page reports, per free-text field, the number of
// the value it shows, so the server knows what the next post was typed from.
check("a field that shows the new value reports the new number", () => {
  const { title } = mount("Fixture post", "First");
  title.focus();
  push({ "doc[title]": { value: "Fixture post B3", was: "Fixture post" } }, { "doc[title]": [1, 2] });
  assert.deepEqual(seen(), { "doc[title]": 2 });
});

check("an unfocused field the patch already set reports the new number", () => {
  const { title, excerpt } = mount("Fixture post", "First");
  excerpt.focus();
  title.value = "Fixture post B3";
  push({ "doc[title]": { value: "Fixture post B3", was: "Fixture post" } }, { "doc[title]": [1, 2] });
  assert.deepEqual(seen(), { "doc[title]": 2 });
});

check("a field with typing not sent reports the value it was typed from, and keeps it", () => {
  const { title } = mount("Fixture post", "First");
  title.focus();
  title.value = "Fixture post A7";
  push({ "doc[title]": { value: "Fixture post B3", was: "Fixture post" } }, { "doc[title]": [1, 2] });
  assert.deepEqual(seen(), { "doc[title]": 1 });
  push({ "doc[title]": { value: "Fixture post B3 B4", was: "Fixture post B3" } }, { "doc[title]": [2, 3] });
  assert.deepEqual(seen(), { "doc[title]": 1 }, "a later value it did not take changes nothing");
});

check("a push without numbers (not free text) reports nothing", () => {
  mount("Old", "First");
  push({ "doc[title]": { value: "New", was: "Old" } });
  assert.deepEqual(seen(), {});
});

window.close();
if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nform remote values: all checks passed");
