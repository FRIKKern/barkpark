// Paper masters (task-3b6e562e916c8ce4) — the BarkparkPaperCanvas hook's half of
// a slash-menu master pick.
//
//   1. ORDER: bp-master-insert queues BEHIND a canvas batch already in flight
//      (the "/query" removal the canvas flushes just before it) and is sent as
//      `paper-insert-master` only after that batch is acknowledged, carrying a
//      request id and the acknowledged if_rev.
//   2. REFUSAL: a server refusal (master gone / outside the paper's scope) settles
//      the insert and releases the queue — the next canvas batch still sends.
//      Without the terminal-refusal arms the coordinator would pause every
//      later save behind the refused insert (mutation-checked).
//   2b. LINKED: a linked pick forwards `mode: "linked"` (task-59be65118320fa0e).
//   3. SAVE: bp-save-master pushes `paper-save-master` {block_id}.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:masters" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-masters-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
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
const el = window.document.querySelector("#paper-canvas-masters-run-0");
const canvas = el.querySelector("bp-paper-canvas");
canvas.acknowledgedSaves = true;
canvas.acknowledgeOps = () => {};
canvas.applyServerBlocks = () => {};
const hook = {
  ...Hooks.BarkparkPaperCanvas,
  el,
  handleEvent: () => {},
  pushEvent: (name, payload, onReply) => {
    if (!["paper-ops", "paper-insert-master", "paper-save-master"].includes(name)) {
      return Promise.resolve({});
    }
    calls.push({ name, payload });
    if (name === "paper-save-master") {
      onReply?.({ saved: true, master: { id: "m-1", title: "Pricing" } });
      return Promise.resolve({});
    }
    return new Promise((resolve) => replies.push({ resolve, payload }));
  },
};
hook.mounted();
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const sent = (name) => calls.filter((c) => c.name === name);

// ── 1. ORDER ────────────────────────────────────────────────────────────────
el.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "remove-block", id: "slash-line" }], seq: 1 },
}));
canvas.dispatchEvent(new window.CustomEvent("bp-master-insert", {
  bubbles: true,
  detail: { master_id: "m-1", after_id: "p-a" },
}));
assert.equal(calls.length, 1, "only the in-flight canvas batch is on the wire");
assert.equal(calls[0].name, "paper-ops");
replies.shift().resolve({ saved: true, request_id: calls[0].payload.request_id, rev: 8 });
await tick();
assert.equal(sent("paper-insert-master").length, 1, "the insert follows the acknowledged batch");
const insert = sent("paper-insert-master")[0].payload;
assert.equal(insert.master_id, "m-1");
assert.equal(insert.after_id, "p-a");
assert.equal(insert.if_rev, 8, "the insert carries the acknowledged revision");
assert.match(insert.request_id, /^00000000-0000-4000-8000-/, "the insert carries a request id");
replies.shift().resolve({ saved: true, request_id: insert.request_id, rev: 9 });
await tick();

// ── 2. REFUSAL does not wedge later saves ───────────────────────────────────
canvas.dispatchEvent(new window.CustomEvent("bp-master-insert", {
  bubbles: true,
  detail: { master_id: "m-gone", after_id: "p-a" },
}));
const refused = sent("paper-insert-master")[1].payload;
const errors = [];
el.addEventListener("bp-error", (e) => errors.push(e.detail.code));
replies.shift().resolve({ saved: false, request_id: refused.request_id, rejected: "master_not_found" });
await tick();
assert.equal(JSON.stringify(errors), '["paper_master_insert_refused"]', "the refusal is reported");
el.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "patch-block", id: "p-a", patch: { text: "after" } }], seq: 2 },
}));
await tick();
const later = sent("paper-ops");
assert.equal(later.length, 2, "a later canvas batch still sends after a refused insert");
assert.equal(later[1].payload.if_rev, 9, "and it is based on the last acknowledged revision");
replies.shift().resolve({ saved: true, request_id: later[1].payload.request_id, rev: 10 });
await tick();

// ── 2b. LINKED (task-59be65118320fa0e item 3) ───────────────────────────────
// A "linked" pick forwards `mode: "linked"`, so the server inserts a
// `master-ref` instead of a detached copy; a detached pick sends no mode.
assert.equal("mode" in insert, false, "a detached insert carries no mode");
canvas.dispatchEvent(new window.CustomEvent("bp-master-insert", {
  bubbles: true,
  detail: { master_id: "m-1", after_id: "p-a", mode: "linked" },
}));
await tick();
const linked = sent("paper-insert-master")[2].payload;
assert.equal(linked.mode, "linked", "the linked pick is forwarded as mode: linked");
assert.equal(linked.master_id, "m-1");
replies.shift().resolve({ saved: true, request_id: linked.request_id, rev: 11 });
await tick();

// ── 3. SAVE ─────────────────────────────────────────────────────────────────
canvas.dispatchEvent(new window.CustomEvent("bp-save-master", {
  bubbles: true,
  detail: { block_id: "p-a" },
}));
assert.equal(JSON.stringify(sent("paper-save-master").map((c) => c.payload)), '[{"block_id":"p-a"}]');

console.log("master insert queue: order, refusal release and save all pass");
process.exit(0);
