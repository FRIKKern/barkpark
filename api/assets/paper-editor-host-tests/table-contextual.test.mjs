// table-contextual.test.mjs — real LiveView hook sequencing for contextual Tables.
//
// Portable conversion, projection, admission, and editor behavior remain in
// src/__table_contextual.test.mjs.
//
// Run: node ../paper-editor-host-tests/table-contextual.test.mjs

import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "FormData", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperEditor } = await import("../paper-editor/src/index.js");

const clone = (value) => JSON.parse(JSON.stringify(value));
const projection = {
  id: "table-1",
  type: "table",
  shape: {
    v: 1,
    head: { state: "row", row: { kind: "array", cells: ["inline-array", "inline-array"] } },
    rows: [
      { kind: "array", cells: ["inline-array", "inline-array"] },
      { kind: "array", cells: ["inline-array", "inline-array"] },
    ],
  },
  head: [
    [{ type: "strong", children: [{ type: "text", value: "Name" }] }],
    [{ type: "text", value: "Role" }],
  ],
  rows: [
    [[{ type: "text", value: "Ada" }], [{ type: "text", value: "Writer" }]],
    [[{ type: "text", value: "Bob" }], [{ type: "text", value: "Editor" }]],
  ],
};

const metadataProjection = {
  id: "table-metadata",
  type: "table",
  shape: {
    v: 2,
    head: { state: "absent" },
    rows: [{
      kind: "array",
      cells: [
        {
          kind: "inline-array",
          inline: { v: 1, anchors: ["text"], opaque: ["text"] },
        },
        {
          kind: "content-map",
          inline: { v: 1, anchors: ["link", "text"], opaque: ["link", "text"] },
        },
        "inline-array",
      ],
    }],
  },
  head: null,
  rows: [[
    [{ type: "text", value: "Beta" }],
    [{
      type: "link",
      href: "/papers/source",
      children: [{ type: "text", value: "Source" }],
    }],
    [{ type: "strong", children: [{ type: "text", value: "Canonical" }] }],
  ]],
};

function mounted(value = projection) {
  const editor = document.createElement("bp-paper-editor");
  assert.ok(editor instanceof BpPaperEditor);
  editor.setAttribute("data-editor-mode", "table");
  editor.block = clone(value);
  const ops = [];
  const errors = [];
  editor.addEventListener("bp-op", (event) => ops.push(clone(event.detail)));
  editor.addEventListener("bp-error", (event) => errors.push(clone(event.detail)));
  document.body.appendChild(editor);
  return { editor, ops, errors };
}

function editCell(editor, area, row, column, text) {
  const doc = clone(editor._editor.getJSON());
  const offset = projection.head == null ? 0 : 1;
  const rowIndex = area === "head" ? 0 : row + offset;
  doc.content[0].content[rowIndex].content[column].content = text == null
    ? [] : [{ type: "text", text }];
  assert.equal(editor._editor.commands.setContent(doc, { emitUpdate: true }), true);
}

function bubbleNativeInput(editor) {
  editor.querySelector(".ProseMirror").dispatchEvent(new Event("input", { bubbles: true }));
}

try {
  await import("../../priv/static/assets/bp-paper-editor-hooks.js?table-contextual");
  const wrapper = document.createElement("div");
  wrapper.id = "paper-ed-table-hook";
  wrapper.setAttribute("phx-hook", "BarkparkPaperEditor");
  wrapper.innerHTML = `<bp-paper-editor data-editor-mode="table"></bp-paper-editor>`;
  const main = document.createElement("main");
  main.dataset.paperDocKey = "drafts:table-hook";
  main.dataset.paperRev = "4";
  main.appendChild(wrapper);
  document.body.appendChild(main);
  const hookedEditor = wrapper.querySelector("bp-paper-editor");
  hookedEditor.block = { ...clone(projection), id: "table-hook" };
  const handlers = new Map();
  const replies = [];
  const hook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditor,
    el: wrapper,
    handleEvent: (name, handler) => handlers.set(name, handler),
    pushEvent: (_name, payload) => new Promise((resolve) => replies.push({ payload, resolve })),
  };
  hook.mounted();
  const wrongNestedInbound = { ...clone(projection), id: "other-table" };
  handlers.get("bp:block-update")({
    block_id: "table-hook",
    block: { id: "table-hook", type: "table", rows: "raw" },
    table_projection: wrongNestedInbound,
  });
  assert.equal(hookedEditor.block.id, "table-hook");
  assert.equal(hookedEditor._sourceBlock.id, "table-hook");
  assert.equal(hookedEditor._blockId, "table-hook",
    "an external envelope cannot redirect the editor through a mismatched nested projection id");
  const inbound = { ...clone(projection), id: "table-hook" };
  inbound.rows[0][1] = [{ type: "text", value: "Projection echo" }];
  handlers.get("bp:block-update")({
    block_id: "table-hook",
    block: { id: "table-hook", type: "table", rows: "raw-authority-not-for-wc" },
    table_projection: inbound,
  });
  assert.match(hookedEditor._editor.getText(), /Projection echo/,
    "the hook routes the server-owned Table projection, not the raw authored carrier");

  editCell(hookedEditor, "body", 0, 1, "Transient");
  bubbleNativeInput(hookedEditor);
  const obsoleteToken = hookedEditor._tableDirtyToken;
  editCell(hookedEditor, "body", 0, 1, "Projection echo");
  bubbleNativeInput(hookedEditor);
  wrapper.dispatchEvent(new CustomEvent("bp-noop", {
    bubbles: true,
    detail: { token: obsoleteToken },
  }));
  assert.equal(hook._exitCoordinator.hasUnsaved(), true,
    "an older no-op token cannot settle a newer Table edit");
  assert.equal(hookedEditor.flushPendingChanges(), false);
  assert.equal(hook._exitCoordinator.hasUnsaved(), false,
    "edit then revert settles the exact local token and cannot strand a false dirty exit guard");
  editCell(hookedEditor, "body", 0, 1, "Transient again");
  bubbleNativeInput(hookedEditor);
  editCell(hookedEditor, "body", 0, 1, "Projection echo");
  bubbleNativeInput(hookedEditor);
  assert.equal(hookedEditor.flushPendingChanges(), false);
  assert.equal(hook._exitCoordinator.hasUnsaved(), false,
    "repeated same-debounce revert cycles settle independently");

  editCell(hookedEditor, "body", 0, 0, "Cell before structure");
  assert.equal(hookedEditor._requestTableStructure("add-row"), true);
  assert.equal(replies.length, 1);
  let drainSettled = false;
  let drainPromise = null;
  wrapper.dispatchEvent(new CustomEvent("bp-flush-pending", {
    detail: { waitUntil(promise) { drainPromise = promise; } },
  }));
  drainPromise.then(() => { drainSettled = true; });
  const cellPayload = clone(replies[0].payload);
  assert.equal(cellPayload.id, "table-hook");
  const hookedCellAck = clone(inbound);
  hookedCellAck.rows[0][0] = clone(cellPayload.cells[0].content);
  replies[0].resolve({
    saved: true,
    request_id: cellPayload.request_id,
    rev: 5,
    table_projection: hookedCellAck,
    table_projection_rev: 5,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(replies.length, 2,
    "the authoritative cell receipt releases the positional action without a push echo");
  assert.equal(drainSettled, false, "the exit remains fenced through the structural save");
  handlers.get("bp:block-update")({
    block_id: "table-hook",
    block: { id: "table-hook", type: "table", rows: "raw" },
    table_projection: hookedCellAck,
    request_id: cellPayload.request_id,
    rev: 5,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(replies.length, 2);
  assert.equal(hookedEditor._tableAwaitingCells.length, 0,
    "a duplicate push after the receipt is idempotent");
  assert.equal(replies[1].payload.op, "patch-table-structure");
  assert.equal(drainSettled, false,
    "an exit drain dynamically includes the structure save released by the cell echo");
  const hookedStructureAck = clone(hookedCellAck);
  hookedStructureAck.shape.rows.push({
    kind: "array", cells: ["inline-array", "inline-array"],
  });
  hookedStructureAck.rows.push([[], []]);
  replies[1].resolve({
    saved: true,
    request_id: replies[1].payload.request_id,
    rev: 6,
    table_projection: hookedStructureAck,
    table_projection_rev: 6,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(await drainPromise, true,
    "the exact structural receipt settles exit even when its push echo is dropped");
  handlers.get("bp:block-update")({
    block_id: "table-hook",
    block: { id: "table-hook", type: "table", rows: "raw" },
    table_projection: hookedStructureAck,
    request_id: replies[1].payload.request_id,
    rev: 6,
  });
  assert.equal(hookedEditor._editor.isEditable, true,
    "a duplicate structural push cannot reapply or relock the settled action");

  wrapper.dispatchEvent(new CustomEvent("bp-op", {
    bubbles: true,
    detail: {
      op: "patch-table-structure",
      id: "table-hook",
      shape: clone(projection.shape),
      action: "down-row:0",
    },
  }));
  assert.equal(replies.length, 3);
  const firstPayload = clone(replies[2].payload);
  replies[2].resolve(null);
  await new Promise((resolve) => setTimeout(resolve, 0));
  wrapper.dispatchEvent(new CustomEvent("bp-flush-pending", {
    detail: { waitUntil() {} },
  }));
  assert.equal(replies.length, 4);
  assert.deepEqual(replies[3].payload, firstPayload,
    "a failed Table structure transport retries the immutable action, shape, revision, and UUID");
  replies[3].resolve({
    saved: false,
    request_id: replies[3].payload.request_id,
    conflict: true,
    current_rev: 5,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const conflict = document.querySelector("[data-bp-paper-conflict]");
  assert.equal(conflict.querySelector('[data-action="keep"]').disabled, true,
    "Table structure is classified as positional and cannot be rebased with Keep mine");
  conflict.querySelector('[data-action="review"]').click();
  assert.match(conflict.textContent, /positional collections/i);
  hook.destroyed();
  main.remove();

  const queueWrapper = document.createElement("div");
  queueWrapper.id = "paper-ed-table-protected-queue";
  queueWrapper.setAttribute("phx-hook", "BarkparkPaperEditor");
  queueWrapper.innerHTML = `<bp-paper-editor data-editor-mode="table"></bp-paper-editor>`;
  const queueMain = document.createElement("main");
  queueMain.dataset.paperDocKey = "drafts:table-protected-queue";
  queueMain.dataset.paperRev = "10";
  queueMain.appendChild(queueWrapper);
  document.body.appendChild(queueMain);
  const queueEditor = queueWrapper.querySelector("bp-paper-editor");
  const queueProjection = { ...clone(metadataProjection), id: "table-protected-queue" };
  queueEditor.block = queueProjection;
  const queueReplies = [];
  const queueHandlers = new Map();
  const queueHook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditor,
    el: queueWrapper,
    handleEvent: (name, handler) => queueHandlers.set(name, handler),
    pushEvent: (_name, payload) => new Promise((resolve) =>
      queueReplies.push({ payload: clone(payload), resolve })),
  };
  queueHook.mounted();

  const queuedFormat = clone(queueEditor._editor.getJSON());
  queuedFormat.content[0].content[0].content[0].content[0].marks = [{ type: "bold" }];
  queueEditor._editor.commands.setContent(queuedFormat, { emitUpdate: true });
  assert.equal(queueEditor.flushPendingChanges(), true);
  assert.equal(queueReplies.length, 1);
  assert.equal(queueReplies[0].payload.if_rev, 10);
  assert.deepEqual(queueReplies[0].payload.shape, queueProjection.shape);

  const queuedType = clone(queueEditor._editor.getJSON());
  queuedType.content[0].content[0].content[0].content[0].text = "Beta after format";
  queueEditor._editor.commands.setContent(queuedType, { emitUpdate: true });
  assert.equal(queueEditor.flushPendingChanges(), true);
  assert.equal(queueReplies.length, 1,
    "the second old-base operation waits behind the active mutation");
  assert.equal(queueEditor._tableAwaitingCells.length, 2);

  const firstQueuePayload = clone(queueReplies[0].payload);
  queueReplies[0].resolve(null);
  await new Promise((resolve) => setTimeout(resolve, 0));
  queueWrapper.dispatchEvent(new CustomEvent("bp-flush-pending", {
    detail: { waitUntil() {} },
  }));
  assert.equal(queueReplies.length, 2);
  assert.deepEqual(queueReplies[1].payload, firstQueuePayload,
    "transport retry preserves the first protected operation, revision, shape, and request id");

  const firstQueueAck = clone(queueProjection);
  firstQueueAck.rows[0][0] = clone(firstQueuePayload.cells[0].content);
  queueReplies[1].resolve({
    saved: true,
    request_id: firstQueuePayload.request_id,
    rev: 11,
    table_projection: firstQueueAck,
    table_projection_rev: 11,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(queueEditor._tableAwaitingCells.length, 1,
    "the exact first receipt retires only the FIFO head");
  assert.equal(queueReplies.length, 3);
  assert.equal(queueReplies[2].payload.if_rev, 11,
    "the second protected operation sends on the acknowledged revision");
  assert.deepEqual(queueReplies[2].payload.shape, queueProjection.shape,
    "metadata-free formatting does not churn the anchored v2 shape");
  assert.deepEqual(queueReplies[2].payload.cells[0].content, [{
    type: "strong",
    children: [{ type: "text", value: "Beta after format" }],
  }]);

  const secondQueueAck = clone(firstQueueAck);
  secondQueueAck.rows[0][0] = clone(queueReplies[2].payload.cells[0].content);
  queueReplies[2].resolve({
    saved: true,
    request_id: queueReplies[2].payload.request_id,
    rev: 12,
    table_projection: secondQueueAck,
    table_projection_rev: 12,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(queueEditor._tableAwaitingCells.length, 0);
  assert.equal(queueHook._exitCoordinator.hasUnsaved(), false);
  queueHook.destroyed();
  queueMain.remove();

  const conflictWrapper = document.createElement("div");
  conflictWrapper.id = "paper-ed-table-external-conflict";
  conflictWrapper.setAttribute("phx-hook", "BarkparkPaperEditor");
  conflictWrapper.innerHTML = `<bp-paper-editor data-editor-mode="table"></bp-paper-editor>`;
  const conflictMain = document.createElement("main");
  conflictMain.dataset.paperDocKey = "drafts:table-external-conflict";
  conflictMain.dataset.paperRev = "10";
  conflictMain.appendChild(conflictWrapper);
  document.body.appendChild(conflictMain);
  const conflictEditor = conflictWrapper.querySelector("bp-paper-editor");
  const conflictProjection = { ...clone(metadataProjection), id: "table-external-conflict" };
  conflictEditor.block = conflictProjection;
  const conflictReplies = [];
  const conflictHandlers = new Map();
  const conflictHook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditor,
    el: conflictWrapper,
    handleEvent: (name, handler) => conflictHandlers.set(name, handler),
    pushEvent: (_name, payload) => new Promise((resolve) =>
      conflictReplies.push({ payload: clone(payload), resolve })),
  };
  conflictHook.mounted();
  const conflictDraft = clone(conflictEditor._editor.getJSON());
  conflictDraft.content[0].content[0].content[0].content[0].text = "Local pending source";
  conflictEditor._editor.commands.setContent(conflictDraft, { emitUpdate: true });
  assert.equal(conflictEditor.flushPendingChanges(), true);
  assert.equal(conflictReplies[0].payload.if_rev, 10);
  const retainedConflictDraft = JSON.stringify(conflictEditor._editor.getJSON());
  conflictHandlers.get("bp:block-update")({
    block_id: "table-external-conflict",
    block: { id: "table-external-conflict", type: "table", rows: "raw metadata echo" },
    table_projection: clone(conflictProjection),
    rev: 11,
  });
  assert.equal(conflictEditor._tableAwaitingCells.length, 1);
  assert.equal(JSON.stringify(conflictEditor._editor.getJSON()), retainedConflictDraft);
  assert.equal(conflictHook._exitCoordinator.hasUnsaved(), true,
    "an external rev 11 echo cannot retire a local if_rev 10 mutation");
  conflictReplies[0].resolve({
    saved: false,
    request_id: conflictReplies[0].payload.request_id,
    conflict: true,
    current_rev: 11,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(conflictMain.querySelector("[data-bp-paper-conflict]"));
  assert.equal(conflictHook._exitCoordinator.hasUnsaved(), true,
    "the distinct conflict sequence retains its local Table draft and exit fence");
  conflictHook.destroyed();
  conflictMain.remove();

  const interleaveWrapper = document.createElement("div");
  interleaveWrapper.id = "paper-ed-table-sibling-interleave";
  interleaveWrapper.setAttribute("phx-hook", "BarkparkPaperEditor");
  interleaveWrapper.innerHTML = `<bp-paper-editor data-editor-mode="table"></bp-paper-editor>`;
  const siblingForm = document.createElement("form");
  siblingForm.id = "paper-caption-sibling";
  siblingForm.className = "bp-paper-edit-form";
  siblingForm.setAttribute("phx-change", "paper-block-autosave");
  siblingForm.setAttribute("phx-debounce", "0");
  siblingForm.innerHTML = `
    <input type="hidden" name="block_id" value="caption-sibling">
    <textarea name="text">Caption before</textarea>
  `;
  const interleaveMain = document.createElement("main");
  interleaveMain.dataset.paperDocKey = "drafts:table-sibling-interleave";
  interleaveMain.dataset.paperRev = "30";
  interleaveMain.append(interleaveWrapper, siblingForm);
  document.body.appendChild(interleaveMain);
  const interleaveEditor = interleaveWrapper.querySelector("bp-paper-editor");
  const interleaveProjection = { ...clone(metadataProjection), id: "table-sibling-interleave" };
  interleaveEditor.block = interleaveProjection;
  const interleaveCalls = [];
  const recordInterleave = (kind, event, payload) => new Promise((resolve) =>
    interleaveCalls.push({ kind, event, payload: clone(payload), resolve }));
  const interleaveHook = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperEditor,
    el: interleaveWrapper,
    handleEvent() {},
    pushEvent: (event, payload) => recordInterleave("table", event, payload),
    pushEventTo: (_target, event, payload) => recordInterleave("form", event, payload),
  };
  interleaveHook.mounted();
  const firstInterleaveDraft = clone(interleaveEditor._editor.getJSON());
  firstInterleaveDraft.content[0].content[0].content[0].content[0].text = "Table first";
  interleaveEditor._editor.commands.setContent(firstInterleaveDraft, { emitUpdate: true });
  assert.equal(interleaveEditor.flushPendingChanges(), true);
  assert.equal(interleaveCalls.length, 1);
  assert.equal(interleaveCalls[0].kind, "table");
  assert.equal(interleaveCalls[0].payload.if_rev, 30);
  const siblingText = siblingForm.querySelector("textarea");
  siblingText.value = "Caption queued";
  siblingText.dispatchEvent(new Event("input", { bubbles: true }));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(interleaveCalls.length, 1,
    "a sibling fallback form serializes behind the active Table mutation");
  const firstInterleaveAck = clone(interleaveProjection);
  firstInterleaveAck.rows[0][0] = clone(interleaveCalls[0].payload.cells[0].content);
  interleaveCalls[0].resolve({
    saved: true,
    request_id: interleaveCalls[0].payload.request_id,
    rev: 31,
    table_projection: firstInterleaveAck,
    table_projection_rev: 31,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(interleaveCalls.length, 2);
  assert.equal(interleaveCalls[1].kind, "form");
  assert.equal(interleaveCalls[1].event, "paper-block-autosave");
  assert.equal(interleaveCalls[1].payload.if_rev, 31,
    "the sibling form inherits the Table acknowledgement revision");
  const secondInterleaveDraft = clone(interleaveEditor._editor.getJSON());
  secondInterleaveDraft.content[0].content[0].content[0].content[0].text = "Table second";
  interleaveEditor._editor.commands.setContent(secondInterleaveDraft, { emitUpdate: true });
  assert.equal(interleaveEditor.flushPendingChanges(), true);
  assert.equal(interleaveCalls.length, 2,
    "later Table work waits behind the active sibling form save");
  interleaveCalls[1].resolve([{
    status: "fulfilled",
    value: { reply: {
      saved: true,
      request_id: interleaveCalls[1].payload.request_id,
      rev: 32,
    } },
  }]);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(interleaveCalls.length, 3);
  assert.equal(interleaveCalls[2].kind, "table");
  assert.equal(interleaveCalls[2].payload.if_rev, 32,
    "the second Table mutation inherits the sibling form acknowledgement revision");
  const secondInterleaveAck = clone(firstInterleaveAck);
  secondInterleaveAck.rows[0][0] = clone(interleaveCalls[2].payload.cells[0].content);
  interleaveCalls[2].resolve({
    saved: true,
    request_id: interleaveCalls[2].payload.request_id,
    rev: 33,
    table_projection: secondInterleaveAck,
    table_projection_rev: 33,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const cleanExit = new Event("beforeunload", { cancelable: true });
  window.dispatchEvent(cleanExit);
  assert.equal(cleanExit.defaultPrevented, false);
  assert.equal(interleaveHook._exitCoordinator.hasUnsaved(), false,
    "Table and sibling form settlement release the shared document exit fence");
  interleaveHook.destroyed();
  interleaveMain.remove();

  for (const badReceipt of ["missing", "malformed", "wrong-id"]) {
    const badWrapper = document.createElement("div");
    badWrapper.id = `paper-ed-table-${badReceipt}`;
    badWrapper.setAttribute("phx-hook", "BarkparkPaperEditor");
    badWrapper.innerHTML = `<bp-paper-editor data-editor-mode="table"></bp-paper-editor>`;
    const badMain = document.createElement("main");
    badMain.dataset.paperDocKey = `drafts:table-${badReceipt}`;
    badMain.dataset.paperRev = "1";
    badMain.appendChild(badWrapper);
    document.body.appendChild(badMain);
    const badEditor = badWrapper.querySelector("bp-paper-editor");
    badEditor.block = { ...clone(projection), id: `table-${badReceipt}` };
    const badReplies = [];
    const badErrors = [];
    badWrapper.addEventListener("bp-error", (event) => badErrors.push(event.detail));
    const badHook = {
      ...window.BarkparkPaperEditorHooks.BarkparkPaperEditor,
      el: badWrapper,
      handleEvent() {},
      pushEvent: (_name, payload) => new Promise((resolve) =>
        badReplies.push({ payload, resolve })),
    };
    badHook.mounted();
    editCell(badEditor, "body", 0, 0, `Draft retained after ${badReceipt} receipt`);
    const draft = JSON.stringify(badEditor._editor.getJSON());
    assert.equal(badEditor.flushPendingChanges(), true);
    const result = {
      saved: true,
      request_id: badReplies[0].payload.request_id,
      rev: 2,
      ...(badReceipt !== "missing" ? {
        table_projection: badReceipt === "malformed"
          ? { ...clone(projection), id: `table-${badReceipt}`, shape: null }
          : { ...clone(projection), id: "other-table" },
        table_projection_rev: 2,
      } : {}),
    };
    badReplies[0].resolve(result);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(JSON.stringify(badEditor._editor.getJSON()), draft,
      "an unverifiable saved receipt retains the exact local Table draft");
    assert.equal(badHook._exitCoordinator.hasUnsaved(), true,
      "an unverifiable saved receipt remains truthfully dirty and blocks navigation");
    assert.equal(badErrors.at(-1).code, "table_projection_receipt_invalid");
    assert.equal(badEditor.block.id, `table-${badReceipt}`);
    assert.equal(badEditor._sourceBlock.id, `table-${badReceipt}`);
    assert.equal(badEditor._blockId, `table-${badReceipt}`,
      "an invalid own receipt cannot redirect the next Table operation");
    badHook.destroyed();
    badMain.remove();
  }

  console.log("PASS  contextual Table projection, editing, sequencing, echo, and fail-closed boundary");
} catch (error) {
  console.error("FAIL  contextual Table projection, editing, sequencing, echo, and fail-closed boundary");
  console.error(error);
  process.exitCode = 1;
} finally {
  document.body.innerHTML = "";
  window.close();
}
