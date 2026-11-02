import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><body></body>");
globalThis.document = window.document;
const { paintHood } = await import("./page/hood.mjs");
const { paintReader } = await import("./page/reader.mjs");
const { watchTally } = await import("./page/tally.mjs");

const el = (tag = "div") => document.createElement(tag);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const p = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });

const hood = { fold: el("p"), batches: el("ol"), diff: el("pre"), json: el("pre") };
paintHood(hood, {
  start: [p("p-a", "Alpha")],
  host: {
    fold: { name: "stub" },
    saved: [p("p-a", "Alpha"), p("c-1", "")],
    batches: [
      { seq: 1, ops: [{ op: "insert-after", afterId: "p-a", block: p("c-1", "") }], answer: { ok: true } },
      { seq: 2, ops: [{ op: "remove-block", id: "p-a" }], answer: { ok: false, error: "refused: locked" } },
      { seq: 3, ops: [{ op: "append-block", block: p("c-2", "") }, { op: "move-block", id: "c-2", after: null }] },
    ],
  },
});
assert.equal(hood.fold.textContent, "Fold: stub");
assert.deepEqual([...hood.batches.children].map((li) => li.textContent), [
  "#1 insert-after c-1 → saved",
  "#2 remove-block p-a → refused: refused: locked",
  "#3 append-block c-2, move-block c-2 → waiting",
]);
assert.equal(hood.diff.textContent, "+ c-1 (paragraph)");
assert.match(hood.json.textContent, /"id": "c-1"/);
const many = Array.from({ length: 25 }, (_, i) => ({ seq: i + 1, ops: [{ op: "remove-block", id: "x" }], answer: { ok: true } }));
paintHood(hood, { start: [], host: { fold: { name: "stub" }, saved: [], batches: many } });
assert.equal(hood.batches.children.length, 20, "the last 20 batches");
assert.match(hood.batches.firstChild.textContent, /^#6 /);
assert.equal(hood.diff.textContent, "nothing yet");

const reader = { label: el("p"), body: el("article") };
await paintReader(reader, { golden: "<p>golden</p>", start: [p("p-a", "A")], saved: [p("p-a", "A")] }, async () => "<p>stand-in</p>");
assert.deepEqual([reader.label.textContent, reader.body.innerHTML], ["Golden reader HTML for this sample.", "<p>golden</p>"]);
await paintReader(reader, { golden: "<p>golden</p>", start: [p("p-a", "A")], saved: [p("p-a", "AB")] }, async (blocks) => `<p>${blocks[0].content[0].value}</p>`);
assert.deepEqual([reader.label.textContent, reader.body.innerHTML], ["Stand-in: the @barkpark/react render of this doc, not the golden reader.", "<p>AB</p>"]);
await paintReader(reader, { golden: null, start: [], saved: [] }, async () => { throw new Error("stand-in broke"); });
assert.equal(reader.body.textContent, "stand-in broke");
const releases = [];
const slow = (blocks) => new Promise((r) => releases.push(() => r(`<p>${blocks[0].id}</p>`)));
const older = paintReader(reader, { golden: null, start: [], saved: [p("old", "")] }, slow);
const newer = paintReader(reader, { golden: null, start: [], saved: [p("new", "")] }, slow);
await wait(0);
releases[1]();
await newer;
releases[0]();
await older;
assert.equal(reader.body.innerHTML, "<p>new</p>", "a slow older render never paints over a newer one");

function stubCanvas(at) {
  const canvas = { at, _editor: { state: { selection: { get $from() { return canvas.at ? { depth: 1, node: () => ({ attrs: { bpId: canvas.at } }) } : { depth: 0 }; } } } } };
  return canvas;
}
const root = el();
const canvas = stubCanvas("p-a");
const tally = { tries: 0, hits: 0 };
let counted = 0;
let rule = { from: "p-a", to: "p-e" };
watchTally(root, () => rule && { rule, canvas, tally, counted: () => counted++ });
const press = (key) => root.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true }));

press("ArrowDown");
canvas.at = "p-e";
await wait(150);
assert.deepEqual([tally, counted], [{ tries: 1, hits: 1 }, 1], "a landing on the empty line is a hit");
canvas.at = "p-a";
press("ArrowDown");
canvas.at = "p-b";
await wait(150);
assert.deepEqual(tally, { tries: 2, hits: 1 }, "a landing past it is a skip");
press("ArrowDown");
canvas.at = "p-a";
press("Enter");
canvas.at = null;
press("ArrowDown");
rule = null;
canvas.at = "p-a";
press("ArrowDown");
await wait(150);
assert.deepEqual([tally, counted], [{ tries: 2, hits: 1 }, 2], "only ArrowDown from the line above counts, and only on a drill with a tally");

console.log("PASS  testing-ground page modules: under the hood, the reader's paint order, the ArrowDown tally");
