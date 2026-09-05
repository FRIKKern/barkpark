import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM, VirtualConsole } from "jsdom";

const virtualConsole = new VirtualConsole();
let reloads = 0;
virtualConsole.on("jsdomError", (error) => {
  if (/navigation \(except hash changes\)/i.test(error.message)) reloads += 1;
  else throw error;
});
const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:concurrency" data-paper-rev="7">
    <div class="bp-paper-editor">
      <div id="paper-canvas-concurrency-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
      <div id="paper-canvas-concurrency-run-1" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
      <div id="native-field" phx-hook="BarkparkFieldBlockBridge" data-block-id="native-1" data-field-type="field-boolean"><input type="checkbox"></div>
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

// A native source needs a reload to consume Use latest, but that reload must
// wait for unrelated retained work. A failed retained save remains retryable
// and guarded without navigating away from its local content.
checkbox.checked = false;
checkbox.dispatchEvent(new window.Event("change", { bubbles: true }));
const conflictedNative = nativeCalls.at(-1);
assert.equal(conflictedNative.payload.if_rev, 14);
edit(1, "retained-behind-native", 3);
assert.notEqual(calls.at(-1).payload.ops[0].id, "retained-behind-native",
  "the unrelated canvas edit waits behind the native write");
nativeReplies.shift()({
  saved: false,
  request_id: conflictedNative.payload.request_id,
  conflict: true,
  current_rev: 16,
});
await tick();
window.document.querySelector('[data-bp-paper-conflict] [data-action="latest"]').click();
const retainedBehindNative = calls.at(-1);
assert.equal(retainedBehindNative.payload.ops[0].id, "retained-behind-native");
assert.equal(retainedBehindNative.payload.if_rev, 16);
assert.equal(reloads, 0, "Use latest cannot reload while another source is unsaved");
replies.shift().resolve({ saved: false, request_id: retainedBehindNative.payload.request_id });
await tick();
const failedRetainedUnload = new window.Event("beforeunload", { cancelable: true });
window.dispatchEvent(failedRetainedUnload);
assert.equal(failedRetainedUnload.defaultPrevented, true,
  "a failed retained save keeps the exit guard active");
assert.equal(reloads, 0, "a retained save failure cannot trigger the deferred reload");
mounts[1].el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
  detail: { waitUntil() {} },
}));
const retriedBehindNative = calls.at(-1);
assert.equal(retriedBehindNative.payload.request_id, retainedBehindNative.payload.request_id);
assert.equal(retriedBehindNative.payload.if_rev, 16);
replies.shift().resolve({
  saved: true,
  request_id: retriedBehindNative.payload.request_id,
  rev: 17,
});
await tick();
assert.equal(reloads, 1, "the deferred reload runs only after all retained work is durable");

// An external N+1 echo may arrive before the reply for our N write. Once the
// matching own reply leaves the document clean, the newest quarantined external
// state must become the baseline instead of remaining stranded forever.
edit(0, "own-before-external", 3);
const beforeExternal = calls.at(-1);
assert.equal(beforeExternal.payload.if_rev, 17);
const canvasUpdate = handlers.get(`${mounts[0].el.id}:bp:canvas-update`);
canvasUpdate({ rev: 19, runs: [{
  run_id: "concurrency-run-0", blocks: [{ id: "external-after-own" }],
}] });
assert.notDeepEqual(mounts[0].canvas.applied, [{ id: "external-after-own" }]);
replies.shift().resolve({
  saved: true, request_id: beforeExternal.payload.request_id, rev: 18,
});
await tick();
assert.deepEqual(mounts[0].canvas.applied, [{ id: "external-after-own" }],
  "the newest external echo applies as soon as the own queue is clean");

// Use latest discards only the source in conflict. A later edit from another
// source remains queued, guarded, and is explicitly refenced on the chosen
// authoritative revision.
edit(0, "conflicted-source-a", 4);
const conflictedA = calls.at(-1);
edit(1, "retained-source-b", 5);
assert.equal(calls.at(-1), conflictedA, "source B waits behind source A");
canvasUpdate({ rev: 20, runs: [{
  run_id: "concurrency-run-0", blocks: [{ id: "latest-source-a" }],
}] });
replies.shift().resolve({
  saved: false,
  request_id: conflictedA.payload.request_id,
  conflict: true,
  current_rev: 20,
});
await tick();
window.document.querySelector('[data-bp-paper-conflict] [data-action="latest"]').click();
assert.deepEqual(mounts[0].canvas.resolved, [{ id: "latest-source-a" }]);
const retainedB = calls.at(-1);
assert.equal(retainedB.payload.ops[0].id, "retained-source-b");
assert.equal(retainedB.payload.if_rev, 20, "source B is refenced only after Use latest");
const guardedUnload = new window.Event("beforeunload", { cancelable: true });
window.dispatchEvent(guardedUnload);
assert.equal(guardedUnload.defaultPrevented, true, "source B keeps the exit guard active");
replies.shift().resolve({ saved: true, request_id: retainedB.payload.request_id, rev: 21 });
await tick();

// External content is safe while clean, but is quarantined once local input is
// dirty. Choosing Use latest is the only path that intentionally discards it.
canvasUpdate({ rev: 22, runs: [{ run_id: "concurrency-run-0", blocks: [{ id: "external-clean" }] }] });
assert.deepEqual(mounts[0].canvas.applied, [{ id: "external-clean" }]);
mounts[0].el.dispatchEvent(new window.Event("input", { bubbles: true }));
canvasUpdate({ rev: 23, runs: [{ run_id: "concurrency-run-0", blocks: [{ id: "external-dirty" }] }] });
assert.notDeepEqual(mounts[0].canvas.resolved, [{ id: "external-dirty" }],
  "external content cannot overwrite dirty local state");
window.document.querySelector('[data-bp-paper-conflict] [data-action="latest"]').click();
assert.deepEqual(mounts[0].canvas.resolved, [{ id: "external-dirty" }]);

// LiveView can reuse one <main> while replacing paper A with paper B. A dirty A
// remains on its original base; once acknowledged, the already-mounted B adopts
// its own host revision instead of inheriting A's coordinator state.
edit(0, "last-edit-paper-a", 6);
const lastA = calls.at(-1);
assert.equal(lastA.payload.if_rev, 23);
const editorRoot = window.document.querySelector(".bp-paper-editor");
const paperBEl = window.document.createElement("div");
paperBEl.id = "paper-canvas-paper-b-run-0";
paperBEl.setAttribute("phx-hook", "BarkparkPaperCanvas");
paperBEl.setAttribute("data-paper-doc-key", "production:paper:paper-b");
paperBEl.setAttribute("data-paper-rev", "100");
paperBEl.dataset.canvasBlocks = "[]";
paperBEl.innerHTML = "<bp-paper-canvas></bp-paper-canvas>";
editorRoot.append(paperBEl);
const paperBCanvas = paperBEl.querySelector("bp-paper-canvas");
paperBCanvas.acknowledgeOps = () => {};
const paperBHook = {
  ...Hooks.BarkparkPaperCanvas,
  el: paperBEl,
  handleEvent() {},
  pushEvent: (name, payload) => {
    if (name !== "paper-ops") return Promise.resolve({});
    calls.push({ run: paperBEl.id, name, payload });
    return new Promise((resolve) => replies.push({ resolve, payload }));
  },
};
paperBHook.mounted();
paperBEl.dispatchEvent(new window.CustomEvent("bp-canvas-ops", {
  bubbles: true,
  detail: { ops: [{ op: "patch-block", id: "paper-b-edit", patch: {} }], seq: 7 },
}));
assert.equal(calls.at(-1), lastA, "mounting paper B does not drop dirty paper A");
replies.shift().resolve({ saved: true, request_id: lastA.payload.request_id, rev: 24 });
await tick();
const firstB = calls.at(-1);
assert.equal(firstB.payload.ops[0].id, "paper-b-edit");
assert.equal(firstB.payload.if_rev, 100, "clean identity rollover resets to paper B's host revision");
replies.shift().resolve({ saved: true, request_id: firstB.payload.request_id, rev: 101 });
await tick();

mounts.forEach(({ hook }) => hook.destroyed());
nativeHook.destroyed();
paperBHook.destroyed();
console.log("PASS shared mutation FIFO: immutable base, exact ack, retry, rebase, quarantine, recovery");
