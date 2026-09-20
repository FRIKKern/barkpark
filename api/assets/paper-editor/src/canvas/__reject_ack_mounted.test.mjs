// Mounted regression for acknowledgeOps(seq, false): a REJECTED batch (a lifecycle
// veto such as "cannot hollow a published paper", or a failed request) must not pin
// the pipeline. Before this seam existed a rejection was a no-op, so the in-flight
// batch stayed in flight forever and every later edit queued behind it unsent.
//
// Contract: the rejection drops the in-flight batch WITHOUT advancing the saved
// baseline, so the next edit's diff carries the refused change along; edits typed
// while the refused batch was travelling emit at once (they already differ from it);
// an unchanged vetoed batch is never resent on its own.

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
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("../index.js");
const { BpPaperCanvas } = await import("./index.js");
assert.equal(customElements.get("bp-paper-canvas"), BpPaperCanvas);

const canvas = document.createElement("bp-paper-canvas");
canvas.acknowledgedSaves = true;
canvas.blocks = [{ id: "p-1", type: "paragraph", content: [{ type: "text", value: "Before" }] }];
document.body.appendChild(canvas);

const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail));
const type = (text) => {
  canvas._editor.commands.focus("end");
  canvas._editor.view.dispatch(canvas._editor.state.tr.insertText(text));
};
const patchText = (batch) => batch.ops.find((op) => op.op === "patch-block")?.patch.content.map((n) => n.value).join("");

try {
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;

  // 1. A batch goes out and is refused.
  type(" one");
  assert.equal(canvas.flushPendingChanges(), true, "the first edit emits a batch");
  assert.equal(batches.length, 1);
  const first = batches[0];
  assert.equal(typeof first.seq, "number", "acknowledged mode stamps a seq");
  assert.equal(canvas.hasPendingChanges(), true, "the batch is in flight");

  assert.equal(canvas.acknowledgeOps(first.seq, false), false, "a saved:false acknowledgement keeps the batch in flight (the Studio retry contract)");
  assert.equal(canvas.hasPendingChanges(), true, "still in flight");
  assert.equal(canvas.discardInflightOps(first.seq + 100), false, "an unknown seq is ignored");
  assert.equal(canvas.discardInflightOps(first.seq), true, "a discard of the in-flight batch is taken");
  assert.equal(canvas.hasPendingChanges(), false, "nothing is in flight after the discard");
  assert.equal(canvas.resendPendingOps(), true, "an explicit resend re-diffs against the saved baseline");
  assert.equal(batches.length, 2, "and emits the refused change as a fresh batch");
  assert.equal(patchText(batches[1]), "Before one");
  assert.equal(canvas.discardInflightOps(batches[1].seq), true);
  assert.equal(batches.length, 2, "an unchanged vetoed batch is not resent on its own after a discard");
  assert.equal(
    canvas._editor.getJSON().content[0].content[0].text, "Before one",
    "the author keeps what they see",
  );

  // 2. The next edit carries the refused change along: its diff is against the last SAVED baseline.
  type(" two");
  assert.equal(canvas.flushPendingChanges(), true);
  assert.equal(batches.length, 3);
  assert.equal(patchText(batches[2]), "Before one two", "the next batch includes the refused edit");
  assert.equal(canvas.acknowledgeOps(batches[2].seq, true), true, "and it saves normally");
  assert.equal(canvas.hasPendingChanges(), false);

  // 3. Typing while a batch travels, then a discard: the newer typing emits at once, as one diff
  //    from the saved baseline, so the refused change rides along with it.
  type(" three");
  assert.equal(canvas.flushPendingChanges(), true);
  assert.equal(batches.length, 4);
  type(" four");
  // The edit sits in the 300 ms debounce; when that fires with a batch in flight it is
  // marked dirty-while-inflight rather than emitted.
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.equal(batches.length, 4, "an edit during flight waits");
  assert.equal(canvas.discardInflightOps(batches[3].seq), true);
  assert.equal(batches.length, 5, "the edit made during flight emits right after the discard");
  assert.equal(patchText(batches[4]), "Before one two three four", "as one diff from the saved baseline");
  assert.equal(canvas.acknowledgeOps(batches[4].seq, true), true);

  // 4. A rejection never touches the saved baseline: a later revert to it emits no ops.
  assert.deepEqual(
    canvas.blocks.map((b) => b.content.map((n) => n.value).join("")), ["Before one two three four"],
    "the acknowledged baseline is the last SAVED state",
  );

  console.log("PASS a rejected acknowledgement frees the pipeline without losing the edit");
} finally {
  canvas.remove();
}
