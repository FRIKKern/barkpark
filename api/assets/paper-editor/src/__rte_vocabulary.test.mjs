// __rte_vocabulary.test.mjs — stage S3 of the Portable Text plan: the Classic
// rich-text editor's toolbar reads the field's declared vocabulary
// (data-vocabulary). It offers only the declared styles, lists and
// decorators, one button per declared annotation and an "Insert inline" menu
// of the declared inline objects. A field with no data-vocabulary keeps the
// toolbar it always had. The schemas and text are made up.
//
// Runs the TRACKED static asset under jsdom.
// Run: node src/__rte_vocabulary.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "Element", "Event", "HTMLElement", "MouseEvent", "KeyboardEvent", "Node", "MutationObserver", "CSS"]) {
  if (window[name]) globalThis[name] = window[name];
}
if (!globalThis.CSS) globalThis.CSS = { escape: (s) => String(s).replace(/["\\]/g, "\\$&") };
globalThis.window = window;
window.document.execCommand = () => true;
await import("../../../priv/static/assets/bp-rich-text-editor.js");

const simple = { styles: ["normal"], lists: ["bullet", "number"], decorators: ["strong", "em", "underline"], annotations: [], inline: [] };
const doc = {
  styles: ["normal", "h1", "h2", "h3", "h4", "h5", "h6"],
  lists: ["bullet", "number"],
  decorators: ["strong", "em", "code", "strike-through"],
  annotations: [{ name: "docLink", title: "Doc link" }],
  inline: [{ name: "docBreak", title: "Line break" }]
};

function mount(value, vocab) {
  const el = document.createElement("bp-rich-text-editor");
  el.setAttribute("value", value);
  if (vocab) el.setAttribute("data-vocabulary", JSON.stringify(vocab));
  document.body.appendChild(el);
  return el;
}

function collect(el, name) {
  const seen = [];
  el.addEventListener(name, (e) => seen.push(e.detail));
  return seen;
}

function select(el, node, start, end) {
  const editor = el.querySelector(".bp-rte-body");
  editor.focus();
  const r = document.createRange();
  r.setStart(node, start);
  r.setEnd(node, end);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(r);
  el._lastRange = r.cloneRange();
}

const press = (b) => b.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
const args = (el) => Array.from(el.querySelectorAll(".bp-rte-toolbar [data-arg]")).map((b) => b.dataset.arg);
const cmds = (el) => Array.from(el.querySelectorAll(".bp-rte-toolbar [data-cmd]")).map((b) => b.dataset.cmd);

let passed = 0;
const check = (label, fn) => {
  fn();
  passed += 1;
  console.log("PASS ", label);
};

check("no data-vocabulary keeps today's toolbar", () => {
  const el = mount("<p>Plain text</p>");
  assert.deepEqual(args(el), ["p", "h2", "h3", "h4"]);
  assert.deepEqual(cmds(el), ["bold", "italic", "underline", "strikeThrough", "formatBlock", "formatBlock", "formatBlock", "formatBlock", "insertUnorderedList", "insertOrderedList"]);
  assert.ok(el.querySelector(".bp-rte-link"), "the link button stays");
  assert.equal(el.querySelector(".bp-rte-annot"), null);
  assert.equal(el.querySelector(".bp-rte-insert-inline"), null);
  el.remove();
});

check("a field that declares only normal offers no heading and no style button", () => {
  const el = mount("<p>Short answer</p>", simple);
  assert.deepEqual(args(el), []);
  assert.deepEqual(cmds(el), ["bold", "italic", "underline", "insertUnorderedList", "insertOrderedList"]);
  assert.equal(el.querySelector(".bp-rte-link"), null, "no annotation declared, no link button");
  assert.equal(el.querySelector(".bp-rte-annot"), null);
  el.remove();
});

check("declared styles, lists and decorators are the buttons", () => {
  const el = mount("<p>Doc text</p>", doc);
  assert.deepEqual(args(el), ["p", "h1", "h2", "h3", "h4", "h5", "h6"]);
  assert.ok(cmds(el).includes("strikeThrough"));
  assert.ok(!cmds(el).includes("underline"));
  assert.ok(el.querySelector('.bp-rte-toolbar [data-wrap="code"]'), "code is a wrap button");
  el.remove();
});

check("code wraps the selection in <code> and unwraps it again", () => {
  const el = mount("<p>Run make now</p>", doc);
  const text = el.querySelector(".bp-rte-body p").firstChild;
  const changes = collect(el, "bp-change");
  select(el, text, 4, 8);
  press(el.querySelector('[data-wrap="code"]'));
  assert.equal(el.value, "<p>Run <code>make</code> now</p>");
  select(el, el.querySelector("code").firstChild, 1, 2);
  press(el.querySelector('[data-wrap="code"]'));
  assert.equal(el.value, "<p>Run make now</p>");
  assert.equal(changes.length, 2);
  el.remove();
});

check("an annotation button marks the selection under a new key and asks the host", () => {
  const el = mount("<p>See the guide here</p>", doc);
  const inserts = collect(el, "bp-pt-def-insert");
  const btn = el.querySelector('.bp-rte-annot[data-annot="docLink"]');
  assert.ok(btn, "one button per declared annotation");
  assert.match(btn.getAttribute("aria-label"), /Doc link/);
  select(el, el.querySelector(".bp-rte-body p").firstChild, 8, 13);
  press(btn);
  assert.equal(inserts.length, 1);
  assert.equal(inserts[0].type, "docLink");
  assert.match(inserts[0].key, /^[0-9a-f]{12}$/);
  assert.equal(inserts[0].html, `<p>See the <span data-pt-def="${inserts[0].key}">guide</span> here</p>`);
  // Refused: the mark comes off and the text stays.
  el.ptDefReady(inserts[0].key, false);
  assert.equal(el.value, "<p>See the guide here</p>");
  el.remove();
});

check("the caret in an annotation opens it; a removed one leaves its text", () => {
  const el = mount('<p>See <span data-pt-def="k1">the guide</span></p>', doc);
  const opens = collect(el, "bp-pt-def-open");
  select(el, el.querySelector("[data-pt-def]").firstChild, 2, 2);
  press(el.querySelector(".bp-rte-annot"));
  assert.deepEqual(opens.map((o) => o.key), ["k1"]);
  el.ptDefRemove("k1");
  assert.equal(el.value, "<p>See the guide</p>");
  el.remove();
});

check("a saved link annotation shows its new address", () => {
  const el = mount('<p><a href="https://old.example" data-pt-def="k2">Site</a></p>', { ...doc, annotations: [{ name: "link", title: "Link" }] });
  el.ptDefUpdate("k2", "https://new.example");
  assert.equal(el.querySelector("a").getAttribute("href"), "https://new.example");
  el.remove();
});

check("Insert inline places a placeholder at the caret and the answer replaces it", () => {
  const el = mount("<p>Line one</p>", doc);
  const inserts = collect(el, "bp-pt-inline-insert");
  select(el, el.querySelector(".bp-rte-body p").firstChild, 4, 4);
  const menu = el.querySelector(".bp-rte-insert-inline");
  assert.ok(menu, "declared inline objects get a menu");
  assert.deepEqual(Array.from(menu.options).map((o) => o.value), ["", "docBreak"]);
  menu.value = "docBreak";
  menu.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(inserts.length, 1);
  const key = inserts[0].key;
  assert.equal(inserts[0].type, "docBreak");
  assert.match(inserts[0].html, new RegExp(`data-pt-object="\\{&quot;_key&quot;:&quot;${key}&quot;\\}"`));
  const chip = `<span data-pt-object="{&quot;_type&quot;:&quot;docBreak&quot;,&quot;_key&quot;:&quot;${key}&quot;}" contenteditable="false">[docBreak]</span>`;
  el.ptInlineReady(key, chip);
  assert.equal(el.value, `<p>Line${chip} one</p>`);
  el.remove();
});

check("clicking an inline object opens it", () => {
  const chip = '<span data-pt-object="{&quot;_type&quot;:&quot;docBreak&quot;,&quot;_key&quot;:&quot;i1&quot;}" contenteditable="false">[docBreak]</span>';
  const el = mount(`<p>A${chip}B</p>`, doc);
  const opens = collect(el, "bp-pt-inline-open");
  el.querySelector("[data-pt-object]").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.deepEqual(opens.map((o) => o.key), ["i1"]);
  el.remove();
});

check("with no declared inline objects a click on one does nothing, as before", () => {
  const chip = '<span data-pt-object="{&quot;_type&quot;:&quot;chip&quot;,&quot;_key&quot;:&quot;i2&quot;}" contenteditable="false">Chip</span>';
  const el = mount(`<p>A${chip}B</p>`);
  const opens = collect(el, "bp-pt-inline-open");
  el.querySelector("[data-pt-object]").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.equal(opens.length, 0);
  el.remove();
});

console.log(`\nall ${passed} rich-text vocabulary checks passed`);
