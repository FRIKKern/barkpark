// task-e0987185b4de61e3 — two tabs on one paper: A edits the first paragraph and B
// the last at the same moment. The server took B's save first and refused A's on
// the old revision; A's canvas showed "Save paused" (or, with nothing queued yet,
// offered only Use latest, which threw A's paragraph away), so only B's edit lived.
//
// A batch whose id-keyed ops touch nothing the other session changed is now
// resent on the newer revision with no banner, and a peer's echo that leaves the
// local draft untouched raises no conflict. An edit to the SAME field of the SAME
// block is still held and shown (Keep mine / Use latest), and the resend is bounded.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM, VirtualConsole } from "jsdom";
import { opsRebaseSafe } from "./canvas/run-convert.js";

// ── opsRebaseSafe: the pure rule ────────────────────────────────────────────────
const para = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const base = [para("p1", "one"), para("p2", "two"), para("p3", "three")];
const mine = [{ op: "patch-block", id: "p3", patch: { content: [{ type: "text", value: "three!" }] } }];
const theirsOther = [para("p1", "ONE"), para("p2", "two"), para("p3", "three")];
const theirsSame = [para("p1", "one"), para("p2", "two"), para("p3", "THREE")];
const theirsInserted = [para("p1", "one"), para("pX", "new"), para("p2", "two"), para("p3", "three")];

assert.equal(opsRebaseSafe(mine, base, theirsOther), true, "different paragraphs rebase");
assert.equal(opsRebaseSafe(mine, base, theirsSame), false, "the same paragraph's text is a conflict");
assert.equal(opsRebaseSafe(mine, base, theirsInserted), false, "a peer insert in the run changes its shape");
assert.equal(
  opsRebaseSafe([{ op: "insert-after", afterId: "p2", block: para("p4", "four") }], base, theirsOther),
  true,
  "an insert anchored on a block the newer version still holds rebases",
);
assert.equal(
  opsRebaseSafe([{ op: "move-block", id: "p3", afterId: "p1" }], base, theirsOther),
  false,
  "a move is never rebased blind",
);
assert.equal(
  opsRebaseSafe([{ op: "remove-block", id: "p1" }], base, theirsOther),
  false,
  "removing a paragraph the peer just edited is a conflict",
);

// ── the coordinator: refused on the old revision, resent on the new one ─────────
const virtualConsole = new VirtualConsole();
virtualConsole.on("jsdomError", (error) => {
  if (!/navigation \(except hash changes\)/i.test(error.message)) throw error;
});
const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:rebase" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-rebase-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
    </div>
  </main>
`, { virtualConsole });
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
const handlers = new Map();
const el = window.document.querySelector("#paper-canvas-rebase-run-0");
const canvas = el.querySelector("bp-paper-canvas");
// The canvas side of the contract, over the REAL rule: the in-flight batch is
// whatever this test dispatched, diffed against `base`.
const inflight = new Map();
canvas.acknowledgedSaves = true;
canvas.acknowledgeOps = (seq, saved) => { if (saved) canvas.acknowledged = seq; };
canvas.applyServerBlocks = (blocks) => { canvas.applied = blocks; };
canvas.resolveConflictWithServerBlocks = (blocks) => { canvas.resolved = blocks; };
canvas.rebaseSafe = (seq, blocks) => opsRebaseSafe(inflight.get(seq), base, blocks);
canvas.localEditsRebaseSafe = (blocks) =>
  [...inflight.values()].every((ops) => opsRebaseSafe(ops, base, blocks));
const hook = {
  ...Hooks.BarkparkPaperCanvas,
  el,
  handleEvent: (name, handler) => handlers.set(name, handler),
  pushEvent: (name, payload) => {
    if (name !== "paper-ops") return Promise.resolve({});
    calls.push(payload);
    return new Promise((resolve) => replies.push({ resolve, payload }));
  },
};
hook.mounted();
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const banner = () => window.document.querySelector("[data-bp-paper-conflict]");
const dispatch = (seq, ops) => {
  inflight.set(seq, ops);
  el.dispatchEvent(new window.CustomEvent("bp-canvas-ops", { bubbles: true, detail: { ops, seq } }));
};
// The other session's save reaching this tab, then this tab's own refusal echo.
const echo = (rev, blocks, requestId = null) =>
  handlers.get("bp:canvas-update")({ rev, request_id: requestId, runs: [{ run_id: "rebase-run-0", blocks }] });

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

await check("a peer save to another paragraph raises no conflict while this edit travels", async () => {
  dispatch(1, mine);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].if_rev, 7);
  echo(8, theirsOther);
  await tick();
  assert.equal(banner(), null, "no Save paused for a paragraph the peer did not touch");
});

await check("the refused batch is resent on the newer revision, with no banner", async () => {
  const refusedId = calls[0].request_id;
  echo(8, theirsOther, refusedId);
  replies.shift().resolve({ saved: false, request_id: refusedId, conflict: true, current_rev: 8 });
  await tick();
  assert.equal(calls.length, 2, "resent once");
  assert.equal(calls[1].if_rev, 8, "on the revision the other session stored");
  assert.notEqual(calls[1].request_id, refusedId, "as a new mutation");
  assert.deepEqual(calls[1].ops, mine, "the same id-keyed ops");
  assert.equal(banner(), null);
  replies.shift().resolve({ saved: true, request_id: calls[1].request_id, rev: 9 });
  await tick();
  assert.equal(canvas.acknowledged, 1, "the canvas is told its batch saved");
  assert.equal(banner(), null);
  inflight.clear();
});

await check("the same paragraph is held and shown, never resent blind", async () => {
  dispatch(2, mine);
  const id = calls[2].request_id;
  echo(10, theirsSame, id);
  replies.shift().resolve({ saved: false, request_id: id, conflict: true, current_rev: 10 });
  await tick();
  assert.equal(calls.length, 3, "not resent");
  assert.ok(banner(), "Keep mine / Use latest is offered");
  assert.ok(banner().querySelector('[data-action="keep"]'));
  banner().querySelector('[data-action="keep"]').click();
  assert.equal(calls.length, 4);
  assert.equal(calls[3].if_rev, 10, "Keep mine still works");
  replies.shift().resolve({ saved: true, request_id: calls[3].request_id, rev: 11 });
  await tick();
  inflight.clear();
});

await check("an endless race is bounded: past three resends the author decides", async () => {
  dispatch(3, mine);
  let rev = 12;
  for (let round = 0; round < 4; round++) {
    const sent = calls[calls.length - 1];
    echo(rev, theirsOther, sent.request_id);
    replies.shift().resolve({ saved: false, request_id: sent.request_id, conflict: true, current_rev: rev });
    await tick();
    rev += 1;
  }
  assert.equal(calls.length, 4 + 1 + 3, "the first send and three resends");
  assert.ok(banner(), "then the conflict is shown");
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall concurrent rebase checks passed");
process.exit(0);
