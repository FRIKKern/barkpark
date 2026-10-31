// Property test for contract 1.20.0 (flushKeepsSource): a remote change that lands
// while Markdown source mode is open, followed by one key, saves exactly "the remote
// change plus that one key". Each seed builds a random doc, types it with its own
// list markers, flushes and takes the echo, puts a caret or a selection in one block,
// applies a random remote change (edit, insert, delete or reorder; before, at, inside
// or after the caret), presses one key and flushes. Every batch replays on a
// patch.ex-shaped server. The caret maps through the change: before it, it stays;
// at or after its end, it moves with the text; inside it, it goes to the end of the
// new text; in a deleted block, it goes to the end of the block before it. A
// selection the change did not touch keeps exactly its text; one the change touched
// collapses where its end went. Nothing else is ever selected. SEEDS overrides the
// seed count; SEED runs one seed.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

const { markdownToBlocks, blocksToMarkdown } = await import("../markdown.js");
await import("../index.js");
await import("./index.js");

const SEEDS = Number(process.env.SEEDS || 3000);
const clone = (value) => JSON.parse(JSON.stringify(value));
const sorted = (value) => Array.isArray(value)
  ? value.map(sorted)
  : value && typeof value === "object"
    ? Object.fromEntries(Object.keys(value).sort()
      .filter((key) => !(key === "lang" && value[key] === ""))
      .map((key) => [key, sorted(value[key])]))
    : value;

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const textOf = (block) => block.type === "heading" ? block.text
  : block.type === "list" ? block.items[0][0].value
  : block.content[0].value;
const withText = (block, text) => block.type === "heading" ? { ...block, text }
  : block.type === "list" ? { ...block, items: [[{ type: "text", value: text }]] }
  : { ...block, content: [{ type: "text", value: text }] };

function replay(server, op) {
  const at = (id) => server.findIndex((block) => block.id === id);
  const need = (id) => {
    const index = at(id);
    if (index === -1) throw new Error(`${op.op} names ${id}, which the server does not hold`);
    return index;
  };
  if (op.op === "patch-block") {
    const index = need(op.id);
    server[index] = { ...server[index], ...clone(op.patch) };
  } else if (op.op === "replace-block") server[need(op.id)] = clone(op.block);
  else if (op.op === "remove-block") server.splice(need(op.id), 1);
  else if (op.op === "insert-after") {
    if (at(op.block.id) !== -1) throw new Error(`insert-after re-inserts ${op.block.id}`);
    server.splice(op.afterId == null ? 0 : need(op.afterId) + 1, 0, clone(op.block));
  } else if (op.op === "append-block") {
    if (at(op.block.id) !== -1) throw new Error(`append-block re-inserts ${op.block.id}`);
    server.push(clone(op.block));
  } else if (op.op === "move-block") {
    const [block] = server.splice(need(op.id), 1);
    server.splice(op.after == null ? 0 : need(op.after) + 1, 0, block);
  } else throw new Error(`unexpected op ${op.op}`);
}

// The caret through a text change from `before` to `after` (one span, found by
// trimming the common prefix and suffix).
function span(before, after) {
  let start = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start++;
  let tail = 0;
  while (tail < before.length - start && tail < after.length - start &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]) tail++;
  return { start, oldEnd: before.length - tail, newEnd: after.length - tail, delta: after.length - before.length };
}
function lineStarts(text) {
  const starts = [];
  let at = 0;
  for (const line of text.split("\n")) {
    if (line) starts.push(at);
    at += line.length + 1;
  }
  return starts;
}
function mapSelection(s, from, to) {
  const caret = (at) => at >= s.oldEnd ? at + s.delta : at <= s.start ? at : s.newEnd;
  const hit = (from < s.oldEnd && to > s.start) || (from < s.start && s.start < to);
  if (from === to || hit) return [caret(to), caret(to)];
  return [caret(from), to <= s.start ? to : to + s.delta];
}

const canvas = document.createElement("bp-paper-canvas");
canvas.acknowledgedSaves = true;
canvas.flushKeepsSource = true;
canvas.blocks = [{ id: "seed-0", type: "paragraph", content: [{ type: "text", value: "start" }] }];
const state = { server: [], batches: [], refused: [] };
canvas.addEventListener("bp-canvas-ops", (event) => {
  state.batches.push(event.detail.ops);
  try {
    for (const op of event.detail.ops) replay(state.server, op);
  } catch (error) {
    state.refused.push(error.message);
  }
  canvas.acknowledgeOps(event.detail.seq, true);
});
document.body.appendChild(canvas);
await new Promise((resolve) => setTimeout(resolve, 350));

const valueSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value").set;
const type = (textarea, value) => {
  valueSetter.call(textarea, value);
  textarea.dispatchEvent(new window.Event("input", { bubbles: true }));
};

function runSeed(seed) {
  const random = rng(seed);
  const pick = (list) => list[Math.floor(random() * list.length)];
  const int = (lo, hi) => lo + Math.floor(random() * (hi - lo + 1));
  const alphabet = random() < 0.5 ? "ab" : "abcdefghij";
  const word = (lo, hi) => Array.from({ length: int(lo, hi) }, () => pick(alphabet)).join("");
  let fresh = 0;
  const id = () => `s${seed}-${fresh++}`;

  let hasList = false;
  const doc = Array.from({ length: int(1, 5) }, () => {
    const kind = pick(hasList ? ["paragraph", "paragraph", "heading"] : ["paragraph", "paragraph", "heading", "list"]);
    if (kind === "list") hasList = true;
    const base = kind === "heading" ? { id: id(), type: "heading", level: 2, text: "" }
      : kind === "list" ? { id: id(), type: "list", ordered: false, items: [] }
      : { id: id(), type: "paragraph", content: [] };
    return withText(base, word(1, 4));
  });

  if (canvas.sourceMode) canvas.toggleSourceMode();
  canvas.blocks = clone(doc);
  state.server = clone(doc);
  state.refused = [];
  canvas.toggleSourceMode();
  const textarea = canvas.querySelector(".bp-canvas-source");
  textarea.focus();

  const user = clone(doc);
  if (random() < 0.5) {
    const j = int(0, user.length - 1);
    user[j] = withText(user[j], textOf(user[j]) + word(1, 2));
  }
  const prefix = (block) => block.type === "heading" ? "## " : block.type === "list" ? pick(["* ", "- "]) : "";
  const prefixes = user.map(prefix);
  const typed = user.map((block, j) => prefixes[j] + textOf(block)).join("\n\n");
  type(textarea, typed);
  canvas.flushPendingChanges();
  canvas.applyServerBlocks(clone(state.server));
  if (textarea.value !== typed) return `the echo of the writer's own save rewrote the textarea`;
  const mine = clone(state.server);
  if (JSON.stringify(mine.map(textOf)) !== JSON.stringify(user.map(textOf))) return `the writer's save holds ${JSON.stringify(mine.map(textOf))}`;

  const b = int(0, user.length - 1);
  const blockStart = user.slice(0, b).reduce((at, block, j) => at + prefixes[j].length + textOf(block).length + 2, 0) + prefixes[b].length;
  const caretText = textOf(user[b]);
  let from = int(0, caretText.length);
  let to = from;
  if (random() < 0.3) to = int(from, caretText.length);
  textarea.setSelectionRange(blockStart + from, blockStart + to, pick(["forward", "backward"]));
  const selected = caretText.slice(from, to);

  const remote = clone(state.server);
  const kinds = ["edit", "edit-caret", "insert", "move", "move-caret"];
  if (remote.length > 1) kinds.push("delete", "delete-caret");
  const kind = pick(kinds);
  const bid = mine[b].id;
  const others = remote.map((block, j) => j).filter((j) => remote[j].id !== bid);
  if (kind === "edit" || kind === "edit-caret") {
    const j = kind === "edit-caret" || others.length === 0 ? remote.findIndex((block) => block.id === bid) : pick(others);
    const text = textOf(remote[j]);
    let next = text;
    while (next === text || next.length === 0) {
      const anchor = remote[j].id === bid ? pick([0, from, to, text.length, int(0, text.length)]) : int(0, text.length);
      const a = Math.max(0, Math.min(anchor - int(0, 2), text.length));
      const z = Math.min(text.length, Math.max(a, anchor + int(0, 2)));
      next = text.slice(0, a) + word(0, 2) + text.slice(z);
    }
    remote[j] = withText(remote[j], next);
  } else if (kind === "insert") {
    remote.splice(int(0, remote.length), 0, { id: id(), type: "paragraph", content: [{ type: "text", value: word(1, 3) }] });
  } else if (kind === "delete" || kind === "delete-caret") {
    remote.splice(kind === "delete-caret" ? remote.findIndex((block) => block.id === bid) : pick(others), 1);
  } else {
    const j = kind === "move-caret" || others.length === 0 ? remote.findIndex((block) => block.id === bid) : pick(others);
    const [moved] = remote.splice(j, 1);
    remote.splice(int(0, remote.length), 0, moved);
  }
  state.server = clone(remote);
  state.batches = [];
  canvas.applyServerBlocks(clone(remote));
  const where = `${kind} ${JSON.stringify(caretText)} [${from},${to}]`;
  if (state.batches.length) return `${where}: the sync itself emitted ops ${JSON.stringify(state.batches)}`;
  const shown = markdownToBlocks(textarea.value).map((block) => blocksToMarkdown([block]));
  if (JSON.stringify(shown) !== JSON.stringify(remote.map((block) => blocksToMarkdown([block])))) {
    return `${where}: the textarea does not show the remote doc: ${JSON.stringify(textarea.value)}`;
  }
  const userIndex = new Map(mine.map((block, j) => [block.id, j]));
  for (const block of remote) {
    const j = userIndex.get(block.id);
    if (j !== undefined && prefixes[j] && textOf(user[j]) === textOf(block) && !textarea.value.includes(prefixes[j] + textOf(block))) {
      return `${where}: the remote change rewrote the writer's ${JSON.stringify(prefixes[j])} on a block it did not touch: ${JSON.stringify(textarea.value)}`;
    }
  }

  const after = remote.find((block) => block.id === bid);
  const key = pick("xyz");
  const expected = clone(remote);
  if (after) {
    const s = span(caretText, textOf(after));
    const [f, t] = mapSelection(s, from, to);
    const k = remote.indexOf(after);
    const textStart = lineStarts(textarea.value)[k] + (after.type === "heading" ? 3 : after.type === "list" ? 2 : 0);
    const want = [textStart + f, textStart + t];
    const got = [textarea.selectionStart, textarea.selectionEnd];
    if (got[0] !== want[0] || got[1] !== want[1]) {
      return `${where}: the selection maps to ${JSON.stringify(got)}, not ${JSON.stringify(want)} (text ${JSON.stringify(textarea.value)})`;
    }
    if (f !== t && textarea.value.slice(got[0], got[1]) !== selected) {
      return `${where}: the selection now holds ${JSON.stringify(textarea.value.slice(got[0], got[1]))}, not the writer's ${JSON.stringify(selected)}`;
    }
    const text = textOf(after);
    expected[k] = withText(after, text.slice(0, f) + key + text.slice(t));
  } else {
    const k = b > 0 ? remote.findIndex((block) => block.id === mine[b - 1].id) : 0;
    const end = lineStarts(textarea.value)[k] + blocksToMarkdown([remote[k]]).length;
    if (textarea.selectionStart !== end || textarea.selectionEnd !== end) {
      return `${where}: the writer's block was deleted and the selection maps to ${JSON.stringify([textarea.selectionStart, textarea.selectionEnd])}, not the end of the block before it (${end})`;
    }
    expected[k] = withText(remote[k], textOf(remote[k]) + key);
  }

  const [f, t, v] = [textarea.selectionStart, textarea.selectionEnd, textarea.value];
  type(textarea, v.slice(0, f) + key + v.slice(t));
  textarea.setSelectionRange(f + 1, f + 1);
  canvas.flushPendingChanges();
  if (state.refused.length) return `${where}: the server refused ${state.refused.join("; ")}`;
  const ops = state.batches.flat();
  if (ops.length !== 1 || ops[0].op !== "patch-block") return `${where}: one key emitted ${JSON.stringify(ops)}`;
  if (JSON.stringify(sorted(state.server)) !== JSON.stringify(sorted(expected))) {
    return `${where}: the server holds ${JSON.stringify(state.server.map(textOf))}, not ${JSON.stringify(expected.map(textOf))}`;
  }
  if (JSON.stringify(sorted(state.server)) !== JSON.stringify(sorted(canvas.blocks))) {
    return `${where}: the server and the canvas disagree`;
  }
  return { passed: `${kind}${from === to ? "" : " selection"}` };
}

const fails = [];
let ran = 0;
const passed = {};
for (let seed = Number(process.env.SEED || 1); seed <= (process.env.SEED ? Number(process.env.SEED) : SEEDS); seed++) {
  let failure;
  try {
    failure = runSeed(seed);
  } catch (error) {
    failure = `threw ${error.stack?.split("\n").slice(0, 3).join(" | ")}`;
  }
  ran++;
  if (typeof failure === "string") fails.push(`seed ${seed}: ${failure}`);
  else passed[failure.passed] = (passed[failure.passed] || 0) + 1;
}
const byKind = {};
for (const line of fails) {
  const kind = line.split(": ")[1]?.split(" ")[0];
  byKind[kind] = (byKind[kind] || 0) + 1;
}
console.log(`source sync property: ${ran} seeds, ${fails.length} failed ${JSON.stringify(byKind)}, passed ${JSON.stringify(passed)}`);
for (const line of fails.slice(0, 8)) console.log(line);
canvas.remove();
assert.equal(fails.length, 0, `${fails.length} of ${ran} seeds break "the remote change plus exactly that one key"`);
console.log("source sync property: ok");
process.exit(0);
