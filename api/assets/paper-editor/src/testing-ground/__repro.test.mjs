import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { drillFromRepro, reportArgs } from "./repro.mjs";

const { window } = new JSDOM("<!doctype html><body></body>");
const { recorder } = await import("./page/record.mjs");

const repro = {
  v: 1,
  build: { label: "main", sha: "4090b798ab" },
  fold: "Reference fold (the JS mirror of patch.ex)",
  doc: "drill:D07",
  width: "desk",
  theme: "light",
  start: [{ id: "p-a", type: "paragraph", content: [] }],
  events: [
    { t: 0, kind: "caret", id: "p-a", offset: 2 },
    { t: 5, kind: "caret", id: "p-e", offset: 0 },
    { t: 9, kind: "key", key: "Enter" },
    { t: 10, kind: "key", key: "Enter" },
    { t: 11, kind: "key", key: "Enter" },
    { t: 12, kind: "type", text: "x" },
    { t: 13, kind: "type", text: "<y" },
    { t: 14, kind: "key", key: "Meta+b" },
    { t: 15, kind: "key", key: "Backspace" },
    { t: 16, kind: "paste", html: "", text: "One\n<Two>" },
    { t: 17, kind: "paste", html: "<p><b>Three</b></p>", text: "Three" },
    { t: 18, kind: "reload" },
    { t: 19, kind: "reload" },
  ],
  batches: [{ seq: 1, ops: [{ op: "insert-after", afterId: "p-e", block: { id: "c-1", type: "paragraph" } }], answer: { ok: true } }],
  red: [{ key: "hidden-blocks", name: "Hidden blocks", words: "6 lines are in the doc but hidden on screen (9 blocks, 2 shown)." }],
};

assert.deepEqual(drillFromRepro(repro), {
  id: "R",
  title: "Repro from main at 4090b798ab",
  open: "drill:D07",
  green: ["hidden-blocks"],
  steps: [
    { say: "Put the caret in p-e after 0 characters", caret: { id: "p-e", offset: 0 } },
    { say: "Press Enter 3 times", key: "Enter", times: 3 },
    { say: "Type \"x<y\"", type: "x<y" },
    { say: "Press Meta+b", key: "Meta+b" },
    { say: "Press Backspace", key: "Backspace" },
    { say: "Paste the recorded clipboard", paste: { html: "<p>One</p><p>&lt;Two&gt;</p>" } },
    { say: "Paste the recorded clipboard", paste: { html: "<p><b>Three</b></p>" } },
    { say: "Press Reload", reload: true },
    { say: "Press Reload", reload: true },
  ],
}, "a repro replays as a drill: runs of one key, typing and clicks fold into one step; its red lights are what must go green");

const args = reportArgs({ what: "  Six Enters left one line\nand more  ", repro });
assert.deepEqual(args.slice(0, 4), ["task", "create", "--title", "Testing ground: Six Enters left one line"]);
assert.deepEqual(args.slice(6), [
  "--set", "parent_id=task-f89ee2dffffddb2c",
  "--set", 'tags:=[{"tag":"playground","strength":80,"rationale":"a bug found by hand in the editor testing ground"},{"tag":"testing","strength":40,"rationale":"carries a repro that replays as a drill with npm run drill"}]',
  "--publish", "--yes",
]);
assert.equal(args[4], "--description");
const description = args[5];
assert.match(description, /^Six Enters left one line\nand more\n\nBuild: main at 4090b798ab\. Doc: drill:D07\. Fold: Reference fold \(the JS mirror of patch\.ex\)\. desk, light\.\nRed lights:\n- Hidden blocks: 6 lines are in the doc but hidden on screen \(9 blocks, 2 shown\)\.\n/);
assert.match(description, /npm run drill -- --repro=repro\.json --build=<main \| PR number>/);
assert.deepEqual(JSON.parse(description.match(/```json\n([\s\S]*)\n```$/)[1]), repro, "the whole repro rides along, intact");
assert.equal(reportArgs({ what: "x".repeat(300), repro })[3].length, "Testing ground: ".length + 100);
assert.match(reportArgs({ what: "x", repro: { ...repro, red: [] } })[5], /Red lights:\n- No light was red\./);
for (const what of ["", "  \n "]) assert.throws(() => reportArgs({ what, repro }), /^Error: Say what went wrong first\.$/);

const root = window.document.createElement("div");
const canvas = window.document.createElement("div");
const other = window.document.createElement("div");
const outside = window.document.createElement("div");
root.append(canvas, other, outside);
window.document.body.append(root);
const at = (id, offset) => ({ state: { selection: { $from: { parent: { attrs: { bpId: id } }, parentOffset: offset } } } });
canvas._editor = at("p-b", 3);
other._editor = at("p-c", 1);
let clock = 1000;
const rec = recorder(root, () => [canvas, other], () => clock);
const fire = (target, event) => target.dispatchEvent(event);
const key = (init) => fire(canvas, new window.KeyboardEvent("keydown", { bubbles: true, ...init }));
key({ key: "Shift", shiftKey: true });
key({ key: "a" });
key({ key: "Enter" });
key({ key: "ArrowDown", shiftKey: true });
key({ key: "B", shiftKey: true });
key({ key: "b", metaKey: true });
key({ key: "B", metaKey: true, shiftKey: true });
key({ key: "z", ctrlKey: true });
key({ key: "y", altKey: true });
key({ key: "q", ctrlKey: true, altKey: true });
fire(canvas, new window.InputEvent("beforeinput", { bubbles: true, inputType: "insertText", data: "hi" }));
fire(canvas, new window.InputEvent("beforeinput", { bubbles: true, inputType: "deleteContentBackward" }));
const paste = new window.Event("paste", { bubbles: true });
paste.clipboardData = { getData: (kind) => ({ "text/html": "<p>P</p>", "text/plain": "P" })[kind] };
fire(canvas, paste);
fire(canvas, new window.Event("pointerup", { bubbles: true }));
fire(outside, new window.Event("pointerup", { bubbles: true }));
canvas._editor.state.selection.$from.parentOffset = 4;
clock = 1250;
rec.note({ kind: "reload" });
assert.deepEqual(rec.events(), [
  { t: 0, kind: "key", key: "Enter" },
  { t: 0, kind: "key", key: "Shift+ArrowDown" },
  { t: 0, kind: "key", key: "Meta+b" },
  { t: 0, kind: "key", key: "Meta+B" },
  { t: 0, kind: "key", key: "Control+z" },
  { t: 0, kind: "key", key: "Alt+y" },
  { t: 0, kind: "key", key: "Control+Alt+q" },
  { t: 0, kind: "type", text: "hi" },
  { t: 0, kind: "paste", html: "<p>P</p>", text: "P" },
  { t: 250, kind: "caret", id: "p-b", offset: 4 },
  { t: 250, kind: "reload" },
], "editing keys, typed text, paste, reloads, and where a click left the caret, read just before the next act; letters come as text, a bare modifier is nothing, a click outside the editor keeps the last click");
key({ key: "Enter" });
assert.deepEqual(rec.events().slice(-3), [{ t: 250, kind: "caret", id: "p-b", offset: 4 }, { t: 250, kind: "reload" }, { t: 250, kind: "key", key: "Enter" }], "one click is one caret step");
fire(canvas, new window.Event("pointerup", { bubbles: true }));
fire(other, new window.Event("pointerup", { bubbles: true }));
key({ key: "Enter" });
assert.deepEqual(rec.events().slice(-2), [{ t: 250, kind: "caret", id: "p-c", offset: 1 }, { t: 250, kind: "key", key: "Enter" }], "the last click wins");
rec.clear();
fire(outside, new window.Event("pointerup", { bubbles: true }));
key({ key: "Enter" });
assert.deepEqual(rec.events(), [{ t: 0, kind: "key", key: "Enter" }], "a click outside every editor is no caret");
fire(canvas, new window.Event("pointerup", { bubbles: true }));
rec.clear();
key({ key: "Enter" });
assert.deepEqual(rec.events(), [{ t: 0, kind: "key", key: "Enter" }], "a new doc forgets a click on the old one");
clock += 5 * 60 * 1000;
rec.note({ kind: "reload" });
assert.deepEqual(rec.events(), [{ t: 0, kind: "key", key: "Enter" }, { t: 5 * 60 * 1000, kind: "reload" }], "5 minutes back is still kept");
clock += 1;
rec.note({ kind: "reload" });
assert.deepEqual(rec.events(), [{ t: 0, kind: "reload" }, { t: 1, kind: "reload" }], "only the last 5 minutes are kept");
rec.clear();
assert.deepEqual(rec.events(), []);

console.log("PASS  testing-ground repro: what a report sends, the recorder behind it, and the drill a repro replays as");
