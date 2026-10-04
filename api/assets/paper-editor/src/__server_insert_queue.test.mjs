// Canvas Terminal / Stage picks — the BarkparkPaperCanvas hook's half
// (task-f3c8acd1e09a0eda, owner ruling 2026-10-03 #56).
//
//   1. ORDER: bp-server-insert queues BEHIND a canvas batch already in flight (the
//      "/query" removal the canvas flushes just before it) and is sent as
//      `paper-slash-insert` {type, afterId} only after that batch is acknowledged,
//      carrying a request id and the acknowledged if_rev — the server path
//      "+ Add block" uses, which stores the block.
//   2. REFUSAL: a refused insert settles, reports the server's own message and
//      releases the queue; the next canvas batch still sends.
//   3. FENCE COPY: a canvas batch refused by the Terminal / Stage fence
//      (outdated_terminal_canvas) shows the server's message, not the false
//      "This document changed elsewhere" banner text.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:widgets" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-widgets-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
    </div>
  </main>
`);
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const Hooks = window.BarkparkPaperEditorHooks;
const calls = [];
const replies = [];
const el = window.document.querySelector("#paper-canvas-widgets-run-0");
const canvas = el.querySelector("bp-paper-canvas");
canvas.acknowledgedSaves = true;
canvas.acknowledgeOps = () => {};
canvas.applyServerBlocks = () => {};
const hook = {
  ...Hooks.BarkparkPaperCanvas,
  el,
  handleEvent: () => {},
  pushEvent: (name, payload) => {
    if (!["paper-ops", "paper-slash-insert"].includes(name)) return Promise.resolve({});
    calls.push({ name, payload });
    return new Promise((resolve) => replies.push({ resolve, payload }));
  },
};
hook.mounted();
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const sent = (name) => calls.filter((c) => c.name === name);
const errors = [];
el.addEventListener("bp-error", (e) => errors.push(e.detail));

// ── 1. ORDER ────────────────────────────────────────────────────────────────
el.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "remove-block", id: "slash-line" }], seq: 1 },
}));
canvas.dispatchEvent(new window.CustomEvent("bp-server-insert", {
  bubbles: true,
  detail: { type: "terminal", after_id: "p-a" },
}));
assert.equal(calls.length, 1, "only the in-flight canvas batch is on the wire");
assert.equal(calls[0].name, "paper-ops");
replies.shift().resolve({ saved: true, request_id: calls[0].payload.request_id, rev: 8 });
await tick();
assert.equal(sent("paper-slash-insert").length, 1, "the insert follows the acknowledged batch");
const insert = sent("paper-slash-insert")[0].payload;
assert.equal(insert.type, "terminal");
assert.equal(insert.afterId, "p-a", "the anchor rides the server handler's afterId param");
assert.equal(insert.if_rev, 8, "the insert carries the acknowledged revision");
assert.match(insert.request_id, /^00000000-0000-4000-8000-/, "the insert carries a request id");
assert.equal("ops" in insert, false, "no canvas batch carries the terminal");
replies.shift().resolve({ saved: true, request_id: insert.request_id, rev: 9 });
await tick();
assert.equal(errors.length, 0, "an accepted insert reports nothing");

// A stage pick takes the same route.
canvas.dispatchEvent(new window.CustomEvent("bp-server-insert", {
  bubbles: true,
  detail: { type: "stage", after_id: "p-a" },
}));
const stage = sent("paper-slash-insert")[1].payload;
assert.equal(stage.type, "stage");
assert.equal(stage.if_rev, 9);
replies.shift().resolve({ saved: true, request_id: stage.request_id, rev: 10 });
await tick();

// An unknown type is ignored (only the two fenced widgets take this route).
canvas.dispatchEvent(new window.CustomEvent("bp-server-insert", {
  bubbles: true,
  detail: { type: "paragraph", after_id: "p-a" },
}));
await tick();
assert.equal(sent("paper-slash-insert").length, 2, "a non-widget type is not sent");

// ── 2. REFUSAL does not wedge later saves ───────────────────────────────────
canvas.dispatchEvent(new window.CustomEvent("bp-server-insert", {
  bubbles: true,
  detail: { type: "terminal", after_id: "p-gone" },
}));
const refused = sent("paper-slash-insert")[2].payload;
replies.shift().resolve({
  saved: false,
  request_id: refused.request_id,
  error: "That block is not allowed here.",
});
await tick();
assert.deepEqual(
  errors.map((e) => [e.code, e.error]),
  [["paper_slash_insert_refused", "That block is not allowed here."]],
  "the refusal reports the server's own message",
);
assert.equal(window.document.querySelector("[data-bp-paper-conflict]"), null, "no conflict banner");
el.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "patch-block", id: "p-a", patch: { text: "after" } }], seq: 2 },
}));
await tick();
const later = sent("paper-ops");
assert.equal(later.length, 2, "a later canvas batch still sends after a refused insert");
assert.equal(later[1].payload.if_rev, 10, "and it is based on the last acknowledged revision");
replies.shift().resolve({ saved: true, request_id: later[1].payload.request_id, rev: 11 });
await tick();

// ── 3. FENCE COPY ───────────────────────────────────────────────────────────
el.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "patch-block", id: "t-1", patch: { title: "x" } }], seq: 3 },
}));
await tick();
const fenced = sent("paper-ops")[2].payload;
const fenceMessage = "Reload the Paper editor before editing this Terminal. Your draft has not been saved.";
replies.shift().resolve({
  saved: false,
  request_id: fenced.request_id,
  rejected: "outdated_terminal_canvas",
  current_rev: 11,
  error: fenceMessage,
});
await tick();
const banner = window.document.querySelector("[data-bp-paper-conflict]");
assert.ok(banner, "the fence refusal still pauses the save with a banner");
const description = banner.querySelector(".bp-conflict-description").textContent;
assert.equal(description, fenceMessage, "the banner shows the server's refusal, not 'changed elsewhere'");

console.log("server insert queue: order, refusal release and fence copy all pass");
process.exit(0);
