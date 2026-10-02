// A canvas batch the server REFUSES with a lifecycle halt (the D3 hollow
// ratchet: "a published paper cannot be hollowed out") must not leave the
// author looking at a state storage never held (Run-4 Lane B). Repro: type five
// lines, Cmd+Z once — the local undo empties the body, the batch is refused,
// and before this the reply was a bare {saved:false}: the queue paused behind
// the refused batch, the canvas kept showing an empty paper, and a reload
// "brought the text back".
//
// Host contract pinned here (BarkparkPaperCanvas + the save coordinator):
//   1. a {saved:false, rejected:"halted"} reply SETTLES the batch — it is not
//      retried and does not pause the queue;
//   2. the refused batch is dropped from the canvas (discardInflightOps);
//   3. the run is put back on the STORED blocks the reply carries
//      (resolveConflictWithServerBlocks), unless the author already typed past
//      the refusal — those newer edits go out instead of being wiped;
//   4. the server's reason is surfaced as a bp-error.
// The server half (the reply shape) is pinned by
// api/test/barkpark_web/live/studio/paper_canvas_halt_resync_test.exs.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:halt" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-halt-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
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
const el = window.document.querySelector("#paper-canvas-halt-run-0");
const canvas = el.querySelector("bp-paper-canvas");
const log = [];
let pending = false;
canvas.acknowledgedSaves = true;
canvas.acknowledgeOps = (seq, saved) => log.push(["ack", seq, saved]);
canvas.discardInflightOps = (seq) => { log.push(["discard", seq]); return true; };
canvas.hasPendingChanges = () => pending;
canvas.applyServerBlocks = () => {};
canvas.resolveConflictWithServerBlocks = (blocks) => log.push(["resync", blocks]);
const errors = [];
el.addEventListener("bp-error", (event) => errors.push(event.detail));

const hook = {
  ...Hooks.BarkparkPaperCanvas,
  el,
  handleEvent: () => {},
  pushEvent: (name, payload) => {
    if (name !== "paper-ops") return Promise.resolve({});
    calls.push(payload);
    return new Promise((resolve) => replies.push(resolve));
  },
};
hook.mounted();

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const send = (id, seq) => el.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "patch-block", id, patch: { content: [] } }], seq },
}));

const REASON = "This edit would remove the last content block — a published paper cannot be hollowed out to title-only.";
const STORED = [{ id: "b-body", type: "paragraph", content: [{ type: "text", value: "Five lines." }] }];

// ── 1. The refused batch settles and the run goes back on storage ──────────
send("b-body", 1);
assert.equal(calls.length, 1, "the hollowing batch is sent");
replies.shift()({
  saved: false,
  request_id: calls[0].request_id,
  rejected: "halted",
  reason: REASON,
  current_rev: 7,
  runs: [
    { run_id: "some-other-run", blocks: [{ id: "x" }] },
    { run_id: "halt-run-0", blocks: STORED },
  ],
});
await tick();

assert.deepEqual(
  log.filter(([kind]) => kind !== "ack"),
  [["discard", 1], ["resync", STORED]],
  "the refused batch is dropped and THIS run is put back on the stored blocks",
);
assert.deepEqual(JSON.parse(JSON.stringify(errors)), [{ code: "paper_ops_halted", error: REASON }],
  "the server's reason is surfaced verbatim");

// The queue is not paused behind the refusal: the next edit goes out at once,
// with a NEW identity (the refused batch is never resent).
send("b-body", 2);
assert.equal(calls.length, 2, "a later edit is sent — the refusal did not pin the queue");
assert.notEqual(calls[1].request_id, calls[0].request_id);
replies.shift()({ saved: true, request_id: calls[1].request_id, rev: 8 });
await tick();

// ── 2. An author who typed past the refusal keeps those edits ───────────────
log.length = 0;
send("b-body", 3);
pending = true; // newer edits are in flight / debouncing in the canvas
replies.shift()({
  saved: false,
  request_id: calls[2].request_id,
  rejected: "halted",
  reason: REASON,
  runs: [{ run_id: "halt-run-0", blocks: STORED }],
});
await tick();
assert.deepEqual(
  log.filter(([kind]) => kind !== "ack"),
  [["discard", 3]],
  "with newer local edits pending the run is NOT reset under the author",
);

// ── 3. A plain failure keeps the existing retry contract ────────────────────
log.length = 0;
pending = false;
send("b-body", 4);
const plain = calls.at(-1);
replies.shift()({ saved: false, request_id: plain.request_id });
await tick();
assert.equal(log.some(([kind]) => kind === "resync" || kind === "discard"), false,
  "a non-halt failure is not treated as final");
el.dispatchEvent(new window.CustomEvent("bp-flush-pending", { detail: { waitUntil() {} } }));
assert.equal(calls.at(-1).request_id, plain.request_id, "it is retried with the same identity");

console.log("halt resync: ok");
