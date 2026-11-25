// __form_remote_values.test.mjs — task-e6ef964ac2e41d5a: another editor saves
// the field this tab has focused. A LiveView patch never touches the focused
// input, so it kept the old text and the next keystroke posted it back over the
// other's words. The page now hears `bp:form-remote-values` (each changed text
// field: new value, value shown before) and sets the focused input, a select
// too, when it still shows exactly the old value.
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

// task-165052f4fad43c1e: the desk's undo of a select leaves the focus in it,
// and a patch never sets a focused select either: another editor's later pick
// stayed out of sight until the person's next action.
const choice = (value) => {
  const box = document.createElement("div");
  box.innerHTML =
    `<select name="doc[choice]"><option value="a">Alpha</option><option value="b">Beta</option>` +
    `<option value="c">Gamma</option></select>`;
  const select = box.firstChild;
  document.getElementById("editor-form").appendChild(select);
  select.value = value;
  return select;
};

check("a focused select that shows the old option takes the other's pick, and keeps focus", () => {
  mount("T", "First");
  const select = choice("b");
  select.focus();
  push({ "doc[choice]": { value: "a", was: "b" } });
  assert.equal(select.value, "a");
  assert.equal(document.activeElement, select, "focus stays");
});

check("a focused select showing another option, or offered one it does not have, is left", () => {
  mount("T", "First");
  const select = choice("c");
  select.focus();
  push({ "doc[choice]": { value: "a", was: "b" } });
  assert.equal(select.value, "c", "the person's pick not yet sent stays");
  select.value = "b";
  push({ "doc[choice]": { value: "z", was: "b" } });
  assert.equal(select.value, "b", "no blank pick");
});

// task-35956a566dd2c862: the page reports, per free-text field, the number of
// the value it shows, so the server knows what the next post was typed from.
check("a field that shows the new value reports the new number", () => {
  const { title } = mount("Fixture post", "First");
  title.focus();
  push({ "doc[title]": { value: "Fixture post B3", was: "Fixture post" } }, { "doc[title]": [1, 2] });
  assert.deepEqual(seen(), { "doc[title]": 2, v: 2 });
});

check("an unfocused field the patch already set reports the new number", () => {
  const { title, excerpt } = mount("Fixture post", "First");
  excerpt.focus();
  title.value = "Fixture post B3";
  push({ "doc[title]": { value: "Fixture post B3", was: "Fixture post" } }, { "doc[title]": [1, 2] });
  assert.deepEqual(seen(), { "doc[title]": 2, v: 2 });
});

check("a field with typing not sent reports the value it was typed from, and keeps it", () => {
  const { title } = mount("Fixture post", "First");
  title.focus();
  title.value = "Fixture post A7";
  push({ "doc[title]": { value: "Fixture post B3", was: "Fixture post" } }, { "doc[title]": [1, 2] });
  assert.deepEqual(seen(), { "doc[title]": 1, v: 2 });
  push({ "doc[title]": { value: "Fixture post B3 B4", was: "Fixture post B3" } }, { "doc[title]": [2, 3] });
  assert.deepEqual(seen(), { "doc[title]": 1, v: 2 }, "a later value it did not take changes nothing");
});

// task-f18af43e26e46ff4: a field on another group tab (or hidden) is drawn
// later from the server's form, with the new value: that is its number.
check("a field not drawn reports the new number, and the next one too", () => {
  mount("Fixture post", "First");
  push({ "doc[kicker]": { value: "K B", was: "K" } }, { "doc[kicker]": [1, 2] });
  assert.deepEqual(seen(), { "doc[kicker]": 2, v: 2 });
  push({ "doc[kicker]": { value: "K B2", was: "K B" } }, { "doc[kicker]": [2, 3] });
  assert.deepEqual(seen(), { "doc[kicker]": 3, v: 2 });
});

// task-f18af43e26e46ff4: `v` tells the server this copy of the file numbers
// every value it shows, so a post with no number may be merged. Typing in
// the editor form writes it before LiveView reads the form; nothing else does.
check("typing in the editor form marks _bp_seen with v, and keeps its numbers", () => {
  const { title, other } = mount("Fixture post", "First");
  other.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.deepEqual(seen(), {}, "another form's typing writes nothing");
  push({ "doc[title]": { value: "Fixture post B3", was: "Fixture post" } }, { "doc[title]": [1, 2] });
  document.querySelector('#editor-form [name="_bp_seen"]').value = JSON.stringify({ "doc[title]": 2 });
  title.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.deepEqual(seen(), { "doc[title]": 2, v: 2 });
});

check("a push without numbers (not free text) reports nothing", () => {
  mount("Old", "First");
  push({ "doc[title]": { value: "New", was: "Old" } });
  assert.deepEqual(seen(), {});
});

// task-4fc7383b936f606a: a connected mount sends each free-text field its
// stored value (`bp:form-born`). A page that rejoined keeps its _bp_seen.
const born = (values, seqs) =>
  window.dispatchEvent(new window.CustomEvent("phx:bp:form-born", { detail: { values, seqs } }));

check("born: a field showing the stored value takes its number, and nothing is drawn", () => {
  const { title } = mount("Fixture post B3", "First");
  born({ "doc[title]": "Fixture post B3" }, { "doc[title]": 9 });
  assert.equal(title.value, "Fixture post B3");
  assert.deepEqual(seen(), { "doc[title]": 9, v: 2 });
});

check("born: a field showing typing done while away, with no number, reports 0 and keeps the typing", () => {
  const { title } = mount("Fixture post A7", "First");
  title.focus();
  born({ "doc[title]": "Fixture post B3" }, { "doc[title]": 9 });
  assert.equal(title.value, "Fixture post A7", "the typing stays");
  assert.deepEqual(seen(), { "doc[title]": 0, v: 2 });
});

check("born: a field with the old socket's number keeps it when it does not show the value", () => {
  const { title } = mount("Fixture post A7", "First");
  document.querySelector('#editor-form [name="_bp_seen"]').value = JSON.stringify({ "doc[title]": 4, v: 2 });
  born({ "doc[title]": "Fixture post B3" }, { "doc[title]": 9 });
  assert.deepEqual(seen(), { "doc[title]": 4, v: 2 });
});

check("born: a field not drawn takes the number; a textarea compares its line breaks as \\n", () => {
  mount("T", "one\ntwo");
  born({ "doc[kicker]": "K", "doc[excerpt]": "one\r\ntwo" }, { "doc[kicker]": 5, "doc[excerpt]": 6 });
  assert.deepEqual(seen(), { "doc[kicker]": 5, "doc[excerpt]": 6, v: 2 });
});

window.close();
if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nform remote values: all checks passed");
