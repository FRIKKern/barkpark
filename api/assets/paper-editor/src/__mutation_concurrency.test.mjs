import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:concurrency" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-concurrency-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
      <div id="paper-canvas-concurrency-run-1" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
      <div id="native-field" phx-hook="BarkparkFieldBlockBridge" data-block-id="native-1" data-field-type="field-boolean"><input type="checkbox"></div>
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
const handlers = new Map();
const mounts = [...window.document.querySelectorAll('[phx-hook="BarkparkPaperCanvas"]')]
  .map((el) => {
    const canvas = el.querySelector("bp-paper-canvas");
    canvas.acknowledgedSaves = true;
    canvas.acknowledgeOps = () => {};
    canvas.applyServerBlocks = (blocks) => { canvas.applied = blocks; };
    canvas.resolveConflictWithServerBlocks = (blocks) => { canvas.resolved = blocks; };
    const hook = {
      ...Hooks.BarkparkPaperCanvas,
      el,
      handleEvent: (name, handler) => handlers.set(`${el.id}:${name}`, handler),
      pushEvent: (name, payload) => {
        if (name !== "paper-ops") return Promise.resolve({});
        calls.push({ run: el.id, name, payload });
        return new Promise((resolve) => replies.push({ resolve, payload }));
      },
    };
    hook.mounted();
    return { hook, el, canvas };
  });
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const edit = (index, id, seq) => mounts[index].el.dispatchEvent(new window.CustomEvent(
  "bp-canvas-ops",
  { bubbles: true, detail: { ops: [{ op: "patch-block", id, patch: { text: id } }], seq } },
));

edit(0, "first", 1);
edit(1, "second", 2);
assert.equal(calls.length, 1, "one document has one in-flight mutation");
assert.equal(calls[0].payload.if_rev, 7, "the first dirty revision is immutable");
const firstId = calls[0].payload.request_id;
replies.shift().resolve({ saved: true, request_id: firstId, rev: 8 });
await tick();
assert.equal(calls.length, 2, "the next run sends only after the matching ack");
assert.equal(calls[1].payload.if_rev, 8, "an own ack advances the next queued base");
assert.notEqual(calls[1].payload.request_id, firstId, "a new batch gets a new UUID");

const secondId = calls[1].payload.request_id;
replies.shift().resolve({ saved: true, request_id: firstId, rev: 9 });
await tick();
assert.equal(calls.length, 2, "a replayed old ack cannot advance another batch");
mounts[1].el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
  detail: { waitUntil() {} },
}));
assert.equal(calls.length, 3, "the mismatched batch remains retryable");
assert.equal(calls[2].payload.request_id, secondId, "transport retry retains UUID");
assert.equal(calls[2].payload.if_rev, 8, "transport retry retains its immutable base");

replies.shift().resolve({
  saved: false,
  request_id: secondId,
  conflict: true,
  current_rev: 12,
});
await tick();
const banner = window.document.querySelector("[data-bp-paper-conflict]");
assert.ok(banner, "a stale write exposes an explicit conflict UI");
assert.match(banner.textContent, /edits are still here/i);
banner.querySelector('[data-action="review"]').click();
assert.match(banner.querySelector("[data-conflict-detail]").textContent, /revision 12/i);
banner.querySelector('[data-action="keep"]').click();
assert.equal(calls.length, 4, "Keep mine explicitly rebases and retries");
assert.notEqual(calls[3].payload.request_id, secondId, "a rebase is a new mutation identity");
assert.equal(calls[3].payload.if_rev, 12, "the rebase targets the reviewed current revision");
const rebasedId = calls[3].payload.request_id;
replies.shift().resolve({ saved: true, request_id: rebasedId, rev: 13 });
await tick();
assert.equal(window.document.querySelector("[data-bp-paper-conflict]"), null);

const nativeEl = window.document.querySelector("#native-field");
const nativeCalls = [];
const nativeReplies = [];
const nativeHook = {
  ...Hooks.BarkparkFieldBlockBridge,
  el: nativeEl,
  pushEvent: (name, payload) => {
    nativeCalls.push({ name, payload });
    return new Promise((resolve) => nativeReplies.push(resolve));
  },
};
nativeHook.mounted();
const checkbox = nativeEl.querySelector("input");
checkbox.checked = true;
checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
assert.equal(nativeCalls[0].payload.if_rev, 13, "native controls join the same document revision lane");
const nativeId = nativeCalls[0].payload.request_id;
nativeReplies.shift()({ saved: true, request_id: nativeId, rev: 14 });
await tick();
const cleanUnload = new window.Event("beforeunload", { cancelable: true });
window.dispatchEvent(cleanUnload);
assert.equal(cleanUnload.defaultPrevented, false, "matching native acknowledgement clears dirty state");

// External content is safe while clean, but is quarantined once local input is
// dirty. Choosing Use latest is the only path that intentionally discards it.
const canvasUpdate = handlers.get(`${mounts[0].el.id}:bp:canvas-update`);
canvasUpdate({ rev: 15, runs: [{ run_id: "concurrency-run-0", blocks: [{ id: "external-clean" }] }] });
assert.deepEqual(mounts[0].canvas.applied, [{ id: "external-clean" }]);
mounts[0].el.dispatchEvent(new window.Event("input", { bubbles: true }));
canvasUpdate({ rev: 16, runs: [{ run_id: "concurrency-run-0", blocks: [{ id: "external-dirty" }] }] });
assert.equal(mounts[0].canvas.resolved, undefined, "external content cannot overwrite dirty local state");
window.document.querySelector('[data-bp-paper-conflict] [data-action="latest"]').click();
assert.deepEqual(mounts[0].canvas.resolved, [{ id: "external-dirty" }]);

mounts.forEach(({ hook }) => hook.destroyed());
nativeHook.destroyed();
console.log("PASS shared mutation FIFO: immutable base, exact ack, retry, rebase, quarantine, recovery");
