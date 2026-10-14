// __clipboard_slice_untrusted.test.mjs — task-57414d08eec4d151. The exact-slice
// stamp a canvas copy puts on the clipboard (`data-bp-fragment`) is UNTRUSTED:
// any web page can write a crafted one. A paste rebuilds from it only when it is
// small, names known node and mark types, carries no script-bearing attribute
// string, and survives schema.nodeFromJSON + node.check(). Undeclared attributes
// and ids never come through. Anything else falls back to the normal paste path.
// Run: node src/canvas/__clipboard_slice_untrusted.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement",
  "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Option", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const { exactClipboardSerializer, exactSliceFromClipboard } = await import("./clipboard-slice.js");
const { TextSelection } = await import("@tiptap/pm/state");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

let ran = 0;
let failures = 0;
async function check(name, fn) {
  ran += 1;
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message.split("\n").slice(0, 4).join(" | ")}`);
  }
}
const EXPECTED = 13;

const canvas = document.createElement("bp-paper-canvas");
canvas.blocks = [
  { id: "p1", type: "paragraph", content: [{ type: "text", value: "Before." }] },
  { id: "dv", type: "divider" },
  { id: "p2", type: "paragraph", content: [{ type: "text", value: "After." }] },
];
document.body.appendChild(canvas);
await tick(30);
const editor = canvas._editor;
const schema = editor.schema;

// A clipboard HTML whose first element carries `json` as the stamp.
const stamped = (json, body = "<p>Plain fallback</p>") =>
  body.replace(/^<(\w+)/, (_m, tag) => `<${tag} data-pm-slice="0 0 []" data-bp-fragment="${String(JSON.stringify(json)).replace(/&/g, "&amp;").replace(/"/g, "&quot;")}"`);
const eventWith = (html, text = "Plain fallback") => ({ clipboardData: { getData: (t) => (t === "text/html" ? html : t === "text/plain" ? text : "") } });
const sliceOf = (json, body) => exactSliceFromClipboard(schema, eventWith(stamped(json, body)));

await check("a genuine canvas copy round-trips: the serializer stamps it and the paste rebuilds it", () => {
  const at = editor.state.doc.child(0).nodeSize;
  const divider = editor.state.doc.child(1);
  const out = exactClipboardSerializer(() => schema).serializeFragment(editor.state.doc.slice(at, at + divider.nodeSize).content, { document });
  const wrap = document.createElement("div");
  wrap.appendChild(out);
  wrap.firstChild.setAttribute("data-pm-slice", "0 0 []");
  const slice = exactSliceFromClipboard(schema, eventWith(wrap.innerHTML));
  assert.ok(slice, "the stamp was not read");
  assert.equal(slice.content.firstChild.type.name, "divider");
});

await check("ids: a well-formed id absent from the doc is kept (cut); a present, repeated or malformed id is cleared", () => {
  const doc = editor.state.doc; // holds p1, dv, p2
  const kept = exactSliceFromClipboard(schema, eventWith(stamped([{ type: "divider", attrs: { bpId: "cut-away-1" } }])), doc);
  assert.equal(kept.content.firstChild.attrs.bpId, "cut-away-1", "a cut block keeps its id");
  const present = exactSliceFromClipboard(schema, eventWith(stamped([{ type: "divider", attrs: { bpId: "dv" } }])), doc);
  assert.equal(present.content.firstChild.attrs.bpId, null, "a copy of a block still in the doc gets a new id");
  const twice = exactSliceFromClipboard(schema, eventWith(stamped([{ type: "divider", attrs: { bpId: "x-1" } }, { type: "divider", attrs: { bpId: "x-1" } }])), doc);
  assert.deepEqual([twice.content.child(0).attrs.bpId, twice.content.child(1).attrs.bpId], ["x-1", null], "a repeat within the paste is cleared");
  for (const bad of ["<b>x</b>", "a b", "", "-lead", "x".repeat(200)]) {
    const s1 = exactSliceFromClipboard(schema, eventWith(stamped([{ type: "divider", attrs: { bpId: bad } }])), doc);
    assert.equal(s1.content.firstChild.attrs.bpId, null, `malformed id ${JSON.stringify(bad).slice(0, 20)} kept`);
  }
});

await check("an unknown NODE type is refused (fallback)", () => {
  assert.equal(sliceOf([{ type: "evilWidget", attrs: {} }]) === null, true);
  assert.equal(sliceOf([{ type: "paragraph", content: [{ type: "evilInline" }] }]) === null, true);
});

await check("an unknown MARK type is refused (fallback)", () => {
  assert.equal(sliceOf([{ type: "paragraph", content: [{ type: "text", text: "x", marks: [{ type: "evilMark" }] }] }]) === null, true);
});

await check("an attribute the schema does not declare never comes through (sanitised)", () => {
  const slice = sliceOf([{ type: "divider", attrs: { bpType: "divider", onclick: "steal()", evil: "x" } }]);
  assert.ok(slice, "a known node with an extra attribute is rebuilt without it");
  const attrs = slice.content.firstChild.attrs;
  assert.ok(!("evil" in attrs) && !("onclick" in attrs), JSON.stringify(attrs));
});

await check("a script-bearing attribute string is refused (fallback)", () => {
  const image = schema.nodes.bpImage ? "bpImage" : null;
  assert.ok(image, "the schema has an image node");
  assert.equal(sliceOf([{ type: image, attrs: { src: "javascript:alert(1)", alt: "x" } }]) === null, true);
  assert.equal(sliceOf([{ type: image, attrs: { src: "https://ok.example/a.png", alt: "<img src=x onerror=alert(1)>" } }]) === null, true);
  assert.equal(sliceOf([{ type: "paragraph", attrs: { bpType: "<script>alert(1)</script>" } }]) === null, true);
  assert.ok(sliceOf([{ type: image, attrs: { src: "https://ok.example/a.png", alt: "A cover" } }]), "control: a safe image is rebuilt");
});

await check("a text node that claims children is refused (fallback)", () => {
  assert.equal(sliceOf([{ type: "paragraph", content: [{ type: "text", text: "x", content: [{ type: "paragraph" }] }] }]) === null, true);
});

await check("content the schema refuses is refused (node.check / nodeFromJSON throw → fallback)", () => {
  // A block inside a paragraph's inline content, and a divider (a leaf) with children.
  assert.equal(sliceOf([{ type: "paragraph", content: [{ type: "divider" }] }]) === null, true);
  assert.equal(sliceOf([{ type: "divider", content: [{ type: "paragraph" }] }]) === null, true);
});

await check("an oversized clipboard (over 1 MB) is refused before it is parsed", () => {
  const big = stamped([{ type: "divider" }], `<p>${"x".repeat(1024 * 1024)}</p>`);
  assert.equal(exactSliceFromClipboard(schema, eventWith(big)) === null, true);
});

await check("malformed stamps are refused (not JSON, not a list)", () => {
  const notJson = '<p data-pm-slice="0 0 []" data-bp-fragment="{nope">x</p>';
  assert.equal(exactSliceFromClipboard(schema, eventWith(notJson)) === null, true);
  assert.equal(sliceOf({ type: "divider" }) === null, true);
});

// End to end: a crafted stamp falls back to the normal paste path.
async function pasteAtEnd(html, text) {
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, editor.state.doc.content.size - 1)));
  const event = new Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { types: ["text/html", "text/plain"], files: [], getData: (t) => (t === "text/html" ? html : t === "text/plain" ? text : "") } });
  editor.view.dom.dispatchEvent(event);
  canvas.flushPendingChanges();
  await tick(20);
}
const textOf = () => { const out = []; editor.state.doc.forEach((n) => out.push(n.type.name + ":" + n.textContent)); return out; };

await check("end to end: an unknown-type stamp falls back — the HTML's own paragraph is pasted, nothing crafted lands", async () => {
  await pasteAtEnd(stamped([{ type: "evilWidget" }], "<p>Fallback text</p>"), "Fallback text");
  assert.ok(textOf().some((t) => t.includes("Fallback text")), JSON.stringify(textOf()));
  assert.ok(!editor.state.doc.toString().includes("evilWidget"));
});

await check("end to end: a script-bearing stamp falls back — no javascript: URL reaches the document", async () => {
  await pasteAtEnd(stamped([{ type: "bpImage", attrs: { src: "javascript:alert(1)", alt: "x" } }], "<p>Safe body</p>"), "Safe body");
  assert.ok(textOf().some((t) => t.includes("Safe body")), JSON.stringify(textOf()));
  assert.ok(!JSON.stringify(editor.getJSON()).includes("javascript:"));
});

await check("a javascript: href in a link mark comes out no worse than the normal paste path (the stamp is refused, the link sanitising applies)", async () => {
  const body = '<p><a href="javascript:alert(1)">bad link</a> and <a href="https://ok.example/">good link</a></p>';
  const linkMark = schema.marks.link ? "link" : Object.keys(schema.marks).find((m) => /link/i.test(m));
  assert.ok(linkMark, "the schema has a link mark");
  const json = [{ type: "paragraph", content: [{ type: "text", text: "bad link", marks: [{ type: linkMark, attrs: { href: "javascript:alert(1)" } }] }] }];
  assert.equal(sliceOf(json, body) === null, true, "the stamp with a javascript: href is refused");
  const hrefs = () => [...JSON.stringify(editor.getJSON()).matchAll(/"href":"([^"]*)"/g)].map((m) => m[1]);
  // The normal path alone, then the same body behind the crafted stamp.
  const before = hrefs().length;
  await pasteAtEnd(body, "bad link and good link");
  const plainPath = hrefs().slice(before);
  const mid = hrefs().length;
  await pasteAtEnd(stamped(json, body), "bad link and good link");
  const stampPath = hrefs().slice(mid);
  // Precondition: the normal path really pastes links (else both lists are empty).
  assert.ok(plainPath.includes("https://ok.example/"), `the normal paste landed no link: ${JSON.stringify(plainPath)}`);
  assert.deepEqual(stampPath, plainPath, "the stamped paste did not land exactly like the normal paste");
  assert.ok(!stampPath.some((h) => /^\s*javascript:/i.test(h)), `a javascript: href landed: ${JSON.stringify(stampPath)}`);
});

if (ran !== EXPECTED) { failures += 1; console.log(`FAIL  ran ${ran} of ${EXPECTED} checks`); }
if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\nclipboard slice untrusted: all checks passed");
process.exit(0);
