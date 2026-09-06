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

await import("./index.js");
const { DEBOUNCE_MS } = await import("../contract.js");

const paragraph = (id, value) => ({
  id,
  type: "paragraph",
  content: [{ type: "text", value }],
});

const original = paragraph("left-column", "Old left text");
const canvas = document.createElement("bp-paper-canvas");
canvas.acknowledgedSaves = true;
canvas.blocks = [original];
const batches = [];
canvas.addEventListener("bp-canvas-ops", (event) => batches.push(event.detail));
document.body.appendChild(canvas);

const idleCanvas = document.createElement("bp-paper-canvas");
idleCanvas.acknowledgedSaves = true;
idleCanvas.blocks = [original];
const idleBatches = [];
idleCanvas.addEventListener("bp-canvas-ops", (event) => idleBatches.push(event.detail));
document.body.appendChild(idleCanvas);

const activeCanvas = document.createElement("bp-paper-canvas");
activeCanvas.acknowledgedSaves = true;
activeCanvas.blocks = [original, paragraph("same-length-sibling", "Old sibling")];
const activeBatches = [];
activeCanvas.addEventListener("bp-canvas-ops", (event) => activeBatches.push(event.detail));
document.body.appendChild(activeCanvas);

const foreignCanvas = document.createElement("bp-paper-canvas");
foreignCanvas.acknowledgedSaves = true;
foreignCanvas.blocks = [original];
const foreignBatches = [];
foreignCanvas.addEventListener("bp-canvas-ops", (event) => foreignBatches.push(event.detail));
document.body.appendChild(foreignCanvas);

const removedSiblingCanvas = document.createElement("bp-paper-canvas");
removedSiblingCanvas.acknowledgedSaves = true;
removedSiblingCanvas.blocks = [original, paragraph("removed-sibling", "Remove externally")];
const removedSiblingBatches = [];
removedSiblingCanvas.addEventListener("bp-canvas-ops", (event) => removedSiblingBatches.push(event.detail));
document.body.appendChild(removedSiblingCanvas);

const stalePendingCanvas = document.createElement("bp-paper-canvas");
stalePendingCanvas.acknowledgedSaves = true;
stalePendingCanvas.blocks = [original];
const stalePendingBatches = [];
stalePendingCanvas.addEventListener("bp-canvas-ops", (event) => stalePendingBatches.push(event.detail));
document.body.appendChild(stalePendingCanvas);

try {
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  canvas._editor.commands.focus("end");
  canvas._editor.view.dispatch(
    canvas._editor.state.tr.insertText(" — unsent local draft", canvas._editor.state.doc.content.size - 1),
  );
  canvas._editor.commands.blur();

  assert.equal(batches.length, 0, "the local draft is still inside its debounce window");
  assert.equal(canvas.hasPendingChanges(), true);

  // A different editor source saves the document. Its authoritative broadcast
  // includes this still-old run plus its new sibling and reaches the blurred
  // canvas before its debounce.
  const externalSibling = paragraph("grid-sibling", "Saved by another source");
  const olderAuthority = [original, externalSibling];
  canvas.applyServerBlocks(olderAuthority);
  assert.notEqual(canvas._debounceTimer, null, "the sibling echo must leave the local debounce armed");
  assert.match(
    canvas._editor.state.doc.textContent,
    /unsent local draft/,
    "a sibling-source echo must not overwrite the blurred debounced draft",
  );

  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  assert.equal(batches.length, 1);
  assert.equal(batches[0].ops[0].op, "patch-block");
  assert.match(batches[0].ops[0].patch.content[0].value, /unsent local draft/);
  assert.equal(canvas.identifyOpsRequest(batches[0].seq, "request-main"), true);

  canvas.applyServerBlocks(olderAuthority);
  assert.match(
    canvas._editor.state.doc.textContent,
    /unsent local draft/,
    "the older echo stays queued while the local save is in flight",
  );

  canvas.acknowledgeOps(batches[0].seq, true);
  const mergedAuthority = [
    paragraph("left-column", "Old left text — unsent local draft"),
    externalSibling,
  ];
  canvas.applyServerBlocks(mergedAuthority, { mode: "own", requestId: "request-main" });
  assert.match(canvas._editor.state.doc.textContent, /unsent local draft/);
  assert.match(canvas._editor.state.doc.textContent, /Saved by another source/);
  assert.deepEqual(canvas._blocks, mergedAuthority);
  assert.equal(canvas._pendingServerBlocks, null);
  assert.equal(canvas._awaitingOwnEchoes.length, 0);
  assert.equal(canvas.hasPendingChanges(), false);

  // A scheduled debounce can normalize to no operation (for example after a
  // transaction is undone locally). In that case no own save echo will arrive,
  // so the queued authoritative update must be released when the timer settles.
  const external = paragraph("left-column", "Authoritative sibling update");
  idleCanvas._scheduleEmit();
  idleCanvas.applyServerBlocks([external]);
  assert.equal(idleCanvas._editor.state.doc.textContent, "Old left text");
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  assert.equal(idleBatches.length, 0);
  assert.equal(idleCanvas._editor.state.doc.textContent, "Authoritative sibling update");
  assert.deepEqual(idleCanvas._blocks, [external]);
  assert.equal(idleCanvas.hasPendingChanges(), false);

  // Trusted request/revision correlation must also release an own result while
  // newer input remains active. The result changes a same-length non-target
  // sibling: that authority waits visibly, while the newer local diff contains
  // only its A patch and never reverts sibling B.
  activeCanvas._editor.commands.focus("end");
  activeCanvas._editor.view.dispatch(
    activeCanvas._editor.state.tr.insertText(" first", activeCanvas._editor.state.doc.child(0).nodeSize - 1),
  );
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  assert.equal(activeBatches.length, 1);
  assert.equal(activeCanvas.identifyOpsRequest(activeBatches[0].seq, "request-active-1"), true);
  activeCanvas._editor.view.dispatch(
    activeCanvas._editor.state.tr.insertText(" second", activeCanvas._editor.state.doc.child(0).nodeSize - 1),
  );
  activeCanvas.acknowledgeOps(activeBatches[0].seq, true);
  const firstCorrelated = [
    paragraph("left-column", "Old left text first"),
    paragraph("same-length-sibling", "Changed authoritative sibling"),
  ];
  activeCanvas.applyServerBlocks(firstCorrelated, {
    mode: "own",
    requestId: "request-active-1",
  });
  assert.match(activeCanvas._editor.state.doc.textContent, /second/);
  assert.doesNotMatch(activeCanvas._editor.state.doc.textContent, /Changed authoritative sibling/);
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  assert.equal(activeBatches.length, 2);
  assert.deepEqual(activeBatches[1].ops.map((op) => op.id), ["left-column"]);
  assert.equal(activeCanvas.identifyOpsRequest(activeBatches[1].seq, "request-active-2"), true);

  activeCanvas.acknowledgeOps(activeBatches[1].seq, true);
  const finalCorrelated = [
    paragraph("left-column", "Old left text first second"),
    paragraph("same-length-sibling", "Changed authoritative sibling"),
  ];
  activeCanvas.applyServerBlocks(finalCorrelated, {
    mode: "own",
    requestId: "request-active-2",
  });
  activeCanvas._editor.commands.blur();
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.match(activeCanvas._editor.state.doc.textContent, /first second/);
  assert.match(activeCanvas._editor.state.doc.textContent, /Changed authoritative sibling/);
  assert.deepEqual(activeCanvas._blocks, finalCorrelated);
  assert.equal(activeCanvas._pendingServerBlocks, null);
  assert.equal(activeCanvas._awaitingOwnEchoes.length, 0);
  assert.equal(activeCanvas.hasPendingChanges(), false);

  activeCanvas.applyServerBlocks(firstCorrelated, {
    mode: "own-stale",
    requestId: "request-active-1",
  });
  assert.deepEqual(activeCanvas._blocks, finalCorrelated);
  assert.match(activeCanvas._editor.state.doc.textContent, /first second/);
  assert.match(activeCanvas._editor.state.doc.textContent, /Changed authoritative sibling/);
  assert.equal(activeCanvas._pendingServerBlocks, null);

  // A document-wide own receipt for canvas A must not satisfy canvas B's local
  // batch: only the request id bound to B's exact emitted seq can do that.
  foreignCanvas._editor.commands.focus("end");
  foreignCanvas._editor.view.dispatch(
    foreignCanvas._editor.state.tr.insertText(" — canvas B draft", foreignCanvas._editor.state.doc.content.size - 1),
  );
  foreignCanvas._editor.commands.blur();
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  assert.equal(foreignBatches.length, 1);
  assert.equal(foreignCanvas.identifyOpsRequest(foreignBatches[0].seq, "request-canvas-b"), true);
  foreignCanvas.applyServerBlocks([paragraph("left-column", "Canvas A authority")], {
    mode: "own",
    requestId: "request-canvas-a",
  });
  assert.equal(foreignCanvas._inflightOps.echoSeen, false);
  assert.equal(foreignCanvas._inflightOps.confirmedBlocks, undefined);
  assert.match(foreignCanvas._editor.state.doc.textContent, /canvas B draft/);
  foreignCanvas.applyServerBlocks([
    paragraph("left-column", "Old left text — canvas B draft"),
  ], { mode: "own", requestId: "request-canvas-b" });
  foreignCanvas.acknowledgeOps(foreignBatches[0].seq, true);
  assert.equal(foreignCanvas.hasPendingChanges(), false);

  // The same request-correlated contract accepts a shorter canonical fold: a
  // non-target sibling removed elsewhere disappears after our retained A patch.
  removedSiblingCanvas._editor.commands.focus("end");
  removedSiblingCanvas._editor.view.dispatch(
    removedSiblingCanvas._editor.state.tr.insertText(" retained edit", removedSiblingCanvas._editor.state.doc.child(0).nodeSize - 1),
  );
  removedSiblingCanvas._editor.commands.blur();
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  assert.equal(removedSiblingBatches.length, 1);
  assert.equal(
    removedSiblingCanvas.identifyOpsRequest(removedSiblingBatches[0].seq, "request-remove-sibling"),
    true,
  );
  removedSiblingCanvas.acknowledgeOps(removedSiblingBatches[0].seq, true);
  const shorterAuthority = [paragraph("left-column", "Old left text retained edit")];
  removedSiblingCanvas.applyServerBlocks(shorterAuthority, {
    mode: "own",
    requestId: "request-remove-sibling",
  });
  assert.deepEqual(removedSiblingCanvas._blocks, shorterAuthority);
  assert.doesNotMatch(removedSiblingCanvas._editor.state.doc.textContent, /Remove externally/);
  assert.equal(removedSiblingCanvas._pendingServerBlocks, null);
  assert.equal(removedSiblingCanvas._awaitingOwnEchoes.length, 0);

  // An exact historical own-stale receipt may retire its matching snapshot, but
  // it cannot discard newer current authority that is waiting for focus release.
  stalePendingCanvas._editor.commands.focus("end");
  stalePendingCanvas._editor.view.dispatch(
    stalePendingCanvas._editor.state.tr.insertText(" historical save", stalePendingCanvas._editor.state.doc.content.size - 1),
  );
  await new Promise((resolve) => setTimeout(resolve, DEBOUNCE_MS + 50));
  assert.equal(stalePendingBatches.length, 1);
  assert.equal(
    stalePendingCanvas.identifyOpsRequest(stalePendingBatches[0].seq, "request-historical"),
    true,
  );
  stalePendingCanvas.acknowledgeOps(stalePendingBatches[0].seq, true);
  const newerCurrent = [
    paragraph("left-column", "Newer current authority"),
    paragraph("newer-sibling", "Must survive stale receipt"),
  ];
  stalePendingCanvas.applyServerBlocks(newerCurrent, { mode: "external", requestId: null });
  stalePendingCanvas._editor.commands.blur();
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.deepEqual(stalePendingCanvas._pendingServerBlocks, newerCurrent);
  stalePendingCanvas.applyServerBlocks([
    paragraph("left-column", "Old left text historical save"),
  ], { mode: "own-stale", requestId: "request-historical" });
  assert.equal(stalePendingCanvas._awaitingOwnEchoes.length, 0);
  assert.deepEqual(stalePendingCanvas._blocks, newerCurrent);
  assert.match(stalePendingCanvas._editor.state.doc.textContent, /Newer current authority/);
  assert.match(stalePendingCanvas._editor.state.doc.textContent, /Must survive stale receipt/);
  assert.equal(stalePendingCanvas._pendingServerBlocks, null);
} finally {
  canvas.remove();
  idleCanvas.remove();
  activeCanvas.remove();
  foreignCanvas.remove();
  removedSiblingCanvas.remove();
  stalePendingCanvas.remove();
  window.close();
}

console.log("cross-source echo preserves a blurred debounced canvas draft");
