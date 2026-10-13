// task-e0987185b4de61e3 follow-up — tab A never blurs. It keeps typing in its
// paragraph through round after round while another session saves a DIFFERENT
// paragraph, some of those saves landing while A's own batch is in flight. A
// focused canvas shows the peer's paragraph only on release, so its live doc
// holds the OLD copy of that paragraph the whole time: if any of A's batches
// carried that stale copy, it would silently revert the peer's save.
//
// The real hook, coordinator and canvas, against a fake server that stores
// id-keyed ops, refuses a stale revision with `conflict` and echoes the stored
// run (as PaperCanvasConcurrentEditsTest pins for the LiveView side). Both
// edits must persist, A must never see a conflict, and A's typing must survive
// the release that finally paints the peer's paragraph.
// Run: node src/canvas/__paper_focused_typing_peer_saves_mounted.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node",
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
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });

await import("./index.js");
const { TextSelection } = await import("@tiptap/pm/state");
const { DEBOUNCE_MS } = await import("../contract.js");

vm.runInContext(
  readFileSync(new URL("../../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  vm.createContext({ window, document, customElements, CustomEvent, FormData: window.FormData,
    setTimeout, clearTimeout }),
);
const Hooks = window.BarkparkPaperEditorHooks;

const sleep = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const clone = (value) => JSON.parse(JSON.stringify(value));
const para = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });
const textOf = (blocks, id) => blocks.find((b) => b.id === id)?.content?.[0]?.value;

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${error.message}`);
  }
}

// ── the fake server: one stored run, a revision, id-keyed patches ──────────────
const server = { rev: 7, blocks: [para("p1", "one"), para("p2", "two"), para("p3", "three")] };
const handlers = new Map();
const sent = [];
const echo = (requestId) =>
  handlers.get("bp:canvas-update")?.({
    rev: server.rev,
    request_id: requestId,
    runs: [{ run_id: "focus-run-0", blocks: clone(server.blocks) }],
  });
function store(ops) {
  for (const op of ops) {
    assert.equal(op.op, "patch-block", `A only edits text, got ${op.op}`);
    const block = server.blocks.find((b) => b.id === op.id);
    assert.ok(block, `patch for a stored block ${op.id}`);
    Object.assign(block, clone(op.patch));
  }
  server.rev += 1;
}
let peerSaves = 0;
function peerSave() {
  peerSaves += 1;
  server.blocks.find((b) => b.id === "p3").content = [{ type: "text", value: `three B${peerSaves}` }];
  server.rev += 1;
  echo(null);
}
// A peer save that lands between A's send and the server reading A's batch.
let raceNext = false;

const main = document.createElement("main");
main.dataset.paperDocKey = "production:paper:focus";
main.dataset.paperRev = String(server.rev);
main.innerHTML = `<div class="bp-paper-editor"><div id="paper-canvas-focus-run-0" phx-hook="BarkparkPaperCanvas"><bp-paper-canvas></bp-paper-canvas></div></div>`;
const wrapper = main.querySelector("[phx-hook]");
wrapper.dataset.paperDocKey = main.dataset.paperDocKey;
wrapper.dataset.paperRev = main.dataset.paperRev;
wrapper.dataset.canvasBlocks = JSON.stringify(server.blocks);
wrapper.dataset.canvasDataset = "production";
document.body.appendChild(main);
const canvas = wrapper.querySelector("bp-paper-canvas");
const hook = {
  ...Hooks.BarkparkPaperCanvas,
  el: wrapper,
  handleEvent: (name, fn) => handlers.set(name, fn),
  pushEvent: (name, payload) => {
    if (name !== "paper-ops") return Promise.resolve({});
    sent.push(clone(payload));
    if (raceNext) {
      raceNext = false;
      peerSave();
    }
    return sleep(5).then(() => {
      const requestId = payload.request_id;
      if (payload.if_rev !== server.rev) {
        echo(requestId);
        return { saved: false, conflict: true, current_rev: server.rev, request_id: requestId };
      }
      store(payload.ops);
      echo(requestId);
      return { saved: true, rev: server.rev, request_id: requestId };
    });
  },
};
hook.mounted();
await sleep(350);

const editor = canvas._editor;
const banner = () => document.querySelector("[data-bp-paper-conflict]");
function typeInFirst(text) {
  let end = 0;
  editor.state.doc.forEach((node, offset, index) => { if (index === 0) end = offset + node.nodeSize - 1; });
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, end)));
  editor.view.dispatch(editor.state.tr.insertText(text));
}
async function settle() {
  for (let i = 0; i < 200; i++) {
    await sleep(10);
    if (canvas._debounceTimer == null && !canvas._inflightOps && !canvas._dirtyWhileInflight &&
        canvas._awaitingOwnEchoes.length === 0) {
      await sleep(20);
      return true;
    }
  }
  return false;
}

try {
  editor.commands.focus();
  await sleep(20);

  // Twenty rounds of typing without a blur. The peer saves before A's debounce
  // fires on even rounds (A then sends on a stale revision), and on every third
  // round while A's own batch is in flight.
  let typed = "";
  let sawFocusLoss = false;
  for (let round = 0; round < 20; round++) {
    const ch = String.fromCharCode(97 + round);
    typeInFirst(ch);
    typed += ch;
    if (round % 2 === 0) peerSave();
    if (round % 3 === 0) raceNext = true;
    await sleep(DEBOUNCE_MS + 40);
    if (!editor.isFocused) sawFocusLoss = true;
  }
  raceNext = false;
  const settled = await settle();

  await check("every one of A's saves landed; none is held back", () => {
    assert.equal(settled, true, "A's canvas still holds unsaved or unacknowledged edits");
  });

  await check("tab A stayed focused for every round", () => {
    assert.equal(sawFocusLoss, false);
    assert.equal(editor.isFocused, true);
  });

  await check("A sent its paragraph and never a stale copy of the peer's", () => {
    assert.ok(sent.length >= 10, `A saved as it typed (${sent.length} sends)`);
    const touched = new Set(sent.flatMap((s) => s.ops.map((op) => op.id)));
    assert.deepEqual([...touched], ["p1"], `A's ops touched ${[...touched].join(", ")}`);
  });

  await check("A's stale sends were rebased with no conflict shown", () => {
    assert.ok(sent.some((s, i) => i > 0 && s.if_rev !== sent[i - 1].if_rev),
      "at least one send was refused and resent");
    assert.equal(banner(), null);
  });

  await check("both edits persist on the server", () => {
    assert.equal(textOf(server.blocks, "p1"), `one${typed}`);
    assert.equal(textOf(server.blocks, "p3"), `three B${peerSaves}`);
    assert.equal(textOf(server.blocks, "p2"), "two");
  });

  await check("while focused, A's canvas keeps every character A typed", () => {
    assert.ok(editor.state.doc.textContent.includes(`one${typed}`), editor.state.doc.textContent);
  });

  const sendsBeforeRelease = sent.length;
  editor.commands.blur();
  await sleep(DEBOUNCE_MS + 100);
  await settle();

  await check("on release A shows the peer's paragraph beside its own", () => {
    const text = editor.state.doc.textContent;
    assert.ok(text.includes(`one${typed}`), text);
    assert.ok(text.includes(`three B${peerSaves}`), text);
  });

  await check("the release sends nothing that reverts either edit", () => {
    for (const s of sent.slice(sendsBeforeRelease)) {
      for (const op of s.ops) assert.equal(op.id, "p1", `release sent ${op.op} ${op.id}`);
    }
    assert.equal(textOf(server.blocks, "p1"), `one${typed}`);
    assert.equal(textOf(server.blocks, "p3"), `three B${peerSaves}`);
    assert.equal(banner(), null);
  });
} catch (error) {
  failures += 1;
  console.log(`FAIL  harness: ${error.stack}`);
}

hook.destroyed?.();
if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall focused-typing peer-save checks passed");
process.exit(0);
