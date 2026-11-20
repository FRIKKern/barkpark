// What "Keep mine" sends after one key in the rich editor (task-7a92f596371dc4c1).
//
// The real canvas runs under the real page hooks (bp-paper-editor-hooks.js). One
// key goes into block 1 of rich_one_key_batch.json; the server refuses the batch
// because another session saved first; the conflict banner opens and "Keep mine"
// is pressed. The test checks that the editor sent the fixture's ops, and that
// Keep mine resends exactly those ops on the revision the refusal named.
//
// paper_keep_mine_stale_block_test.exs replays the same ops against the server,
// after another editor changed block 4. So the two tests together run what the
// browser does: when the batch the editor sends changes, this test fails until
// the fixture is rewritten, and the server test then runs the new batch.
// Run: node src/canvas/__keep_mine_batch.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { clone, window } from "./source-flush-mounted-harness.mjs";

const fixturePath = fileURLToPath(new URL(
  "../../../../test/support/fixtures/paper-editor/rich_one_key_batch.json", import.meta.url,
));
const hooksPath = fileURLToPath(new URL(
  "../../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url,
));
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
vm.runInContext(readFileSync(hooksPath, "utf8"), vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: window.customElements,
}));

const main = window.document.createElement("main");
main.dataset.paperDocKey = "production:paper:keep-mine";
main.dataset.paperRev = "7";
const editor = window.document.createElement("div");
editor.className = "bp-paper-editor";
const host = window.document.createElement("div");
host.id = "paper-canvas-keep-mine-run-0";
host.setAttribute("phx-hook", "BarkparkPaperCanvas");
host.dataset.canvasBlocks = JSON.stringify(clone(fixture.blocks));
host.appendChild(window.document.createElement("bp-paper-canvas"));
editor.appendChild(host);
main.appendChild(editor);
window.document.body.appendChild(main);

const calls = [];
const replies = [];
const hook = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
  el: host,
  handleEvent: () => {},
  pushEvent: (name, payload) => {
    if (name !== "paper-ops") return Promise.resolve({});
    calls.push(clone(payload));
    return new Promise((resolve) => replies.push(resolve));
  },
};
hook.mounted();
await tick(350);
const canvas = host.querySelector("bp-paper-canvas");

try {
  assert.equal(calls.length, 0, "opening the Paper sends nothing");
  canvas._editor.commands.insertContentAt(fixture.typed.at, fixture.typed.key);
  canvas.flushPendingChanges();
  await tick(50);
  assert.equal(calls.length, 1, "one key sends one batch");
  assert.equal(calls[0].if_rev, 7, "the batch goes on the revision the Paper opened at");
  assert.deepEqual(calls[0].ops, fixture.ops, "the editor sends the fixture's ops for that key");

  // Another session saved first: the server refuses the batch on revision 7.
  replies.shift()({ saved: false, request_id: calls[0].request_id, conflict: true, current_rev: 8 });
  await tick();
  const banner = window.document.querySelector("[data-bp-paper-conflict]");
  assert.ok(banner, "the refusal opens the conflict banner");
  assert.equal(calls.length, 1, "nothing is resent before Keep mine");

  banner.querySelector('[data-action="keep"]').click();
  await tick();
  assert.equal(calls.length, 2, "Keep mine resends the batch");
  assert.equal(calls[1].if_rev, 8, "Keep mine targets the revision the refusal named");
  assert.notEqual(calls[1].request_id, calls[0].request_id, "Keep mine is a new request");
  assert.deepEqual(calls[1].ops, fixture.ops, "Keep mine resends the same ops");

  replies.shift()({ saved: true, request_id: calls[1].request_id, rev: 9 });
  await tick();
  assert.equal(window.document.querySelector("[data-bp-paper-conflict]"), null, "the banner closes");
  console.log(`keep mine batch: ${fixture.ops.map((op) => `${op.op} ${op.id}`).join(", ")}: passed`);
} finally {
  hook.destroyed?.();
  canvas.remove();
}
process.exit(0);
