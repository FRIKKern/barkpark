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
]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.BP_PAPER_EDITOR_NO_INJECT = true;

const {
  tableProjection,
  tableTiptapDocSupported,
  buildTableCellsOp,
  tableProjectionMatchesAction,
} = await import("./convert.js");
const { BpPaperEditor } = await import("./index.js");

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

const freeLinkProjection = {
  id: "table-free-link",
  type: "table",
  shape: {
    v: 2,
    head: { state: "absent" },
    rows: [{
      kind: "array",
      cells: [{
        kind: "inline-array",
        inline: { v: 1, anchors: ["text"], opaque: ["text"] },
      }],
    }],
  },
  head: null,
  rows: [[[{
    type: "link",
    href: "/papers/old",
    children: [{ type: "text", value: "Linked protected text" }],
  }]]],
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
  assert.equal(editor._editor.commands.setContent(doc, true), true);
}

function bubbleNativeInput(editor) {
  editor.querySelector(".ProseMirror").dispatchEvent(new Event("input", { bubbles: true }));
}

try {
  const projected = tableProjection(projection);
  assert.equal(projected.editable, true);
  assert.equal(projected.doc.content.length, 1, "a contextual Table owns exactly one PM node");
  assert.deepEqual(projected.doc.content[0].content[0].content[0].content, [
    { type: "text", text: "Name", marks: [{ type: "bold" }] },
  ]);
  assert.equal(tableTiptapDocSupported(projected.doc, projection), true);
  assert.equal(buildTableCellsOp(projected.doc, projection), null, "mount emits no operation");

  const protectedProjection = tableProjection(metadataProjection);
  assert.equal(protectedProjection.editable, true,
    "shape v2 admits exact descriptors for cells whose hidden source metadata stays server-owned");
  assert.doesNotMatch(JSON.stringify(protectedProjection.doc), /qa|opaque|bpTableCellSource|bpTableSource/,
    "the client projection contains canonical visible inline only, never source metadata or PM tokens");
  assert.equal(tableTiptapDocSupported(protectedProjection.doc, metadataProjection), true);
  assert.equal(buildTableCellsOp(protectedProjection.doc, metadataProjection), null);

  const protectedTextEdit = clone(protectedProjection.doc);
  protectedTextEdit.content[0].content[0].content[0].content[0].text = "Beta edited";
  assert.deepEqual(buildTableCellsOp(protectedTextEdit, metadataProjection), {
    op: "patch-table-cells",
    id: "table-metadata",
    shape: metadataProjection.shape,
    cells: [{
      area: "body",
      row: 0,
      column: 0,
      content: [{ type: "text", value: "Beta edited" }],
    }],
  }, "typing may change the protected text value without importing its hidden metadata");

  const protectedWholeRunMark = clone(protectedProjection.doc);
  protectedWholeRunMark.content[0].content[0].content[0].content[0].marks = [{ type: "bold" }];
  assert.equal(tableTiptapDocSupported(protectedWholeRunMark, metadataProjection), true,
    "a metadata-free whole-run wrapper may be added around the one protected text role");
  assert.deepEqual(buildTableCellsOp(protectedWholeRunMark, metadataProjection).cells[0].content, [{
    type: "strong",
    children: [{ type: "text", value: "Beta" }],
  }]);

  const protectedLinkEdit = clone(protectedProjection.doc);
  protectedLinkEdit.content[0].content[0].content[1].content[0].text = "Source edited";
  assert.equal(tableTiptapDocSupported(protectedLinkEdit, metadataProjection), true);
  assert.deepEqual(buildTableCellsOp(protectedLinkEdit, metadataProjection).cells[0].content, [{
    type: "link",
    href: "/papers/source",
    children: [{ type: "text", value: "Source edited" }],
  }], "typing retains the unique protected link and text roles");

  for (const mutate of [
    (doc) => { doc.content[0].content[0].content[0].content = [
      { type: "text", text: "Be" }, { type: "text", text: "ta", marks: [{ type: "bold" }] },
    ]; },
    (doc) => { doc.content[0].content[0].content[0].content = []; },
    (doc) => { doc.content[0].content[0].content[0].content[0].marks = [{ type: "mystery" }]; },
    (doc) => { delete doc.content[0].content[0].content[1].content[0].marks; },
    (doc) => { doc.content[0].content[0].content[1].content[0].marks[0].attrs.href = "/changed"; },
    (doc) => { doc.content[0].content[0].content[0].attrs = {
      bpTableCellSource: { cell: [{ type: "text", value: "private" }] },
    }; },
  ]) {
    const unsafe = clone(protectedProjection.doc);
    mutate(unsafe);
    assert.equal(tableTiptapDocSupported(unsafe, metadataProjection), false,
      "splits, deletion, unknown roles, protected-wrapper changes, and PM source imports fail closed");
    assert.equal(buildTableCellsOp(unsafe, metadataProjection), null);
  }

  const unprotectedEdit = clone(protectedProjection.doc);
  delete unprotectedEdit.content[0].content[0].content[2].content[0].marks;
  assert.equal(tableTiptapDocSupported(unprotectedEdit, metadataProjection), true,
    "canonical v2 cells without descriptors retain the existing free inline editor");

  for (const shape of [
    { ...clone(metadataProjection.shape), v: 1 },
    { ...clone(metadataProjection.shape), rows: [{ kind: "array", cells: [
      { kind: "inline-array", inline: { v: 1, anchors: ["text"], opaque: [] } },
      "content-map", "inline-array",
    ] }] },
    { ...clone(metadataProjection.shape), rows: [{ kind: "array", cells: [
      { kind: "inline-array", inline: { v: 1, anchors: ["text", "text"], opaque: ["text"] } },
      "content-map", "inline-array",
    ] }] },
    { ...clone(metadataProjection.shape), rows: [{ kind: "array", cells: [
      { kind: "inline-array", inline: { v: 1, anchors: ["link"], opaque: ["link"] } },
      "content-map", "inline-array",
    ] }] },
    { ...clone(metadataProjection.shape), rows: [{ kind: "array", cells: [
      { kind: "inline-array", inline: {
        v: 1, anchors: ["mystery", "text"], opaque: ["mystery"], extra: true,
      } },
      "content-map", "inline-array",
    ] }] },
  ]) {
    assert.equal(tableProjection({ ...clone(metadataProjection), shape }).editable, false,
      "v2 descriptors are exact, ordered, unique, recognized, nonempty, and end in text");
  }

  const v2WithoutProtectedCell = clone(projection);
  v2WithoutProtectedCell.shape.v = 2;
  assert.equal(tableProjection(v2WithoutProtectedCell).editable, false,
    "shape v2 is reserved for Tables with at least one protected cell descriptor");

  const movedProtectedColumn = clone(metadataProjection);
  [movedProtectedColumn.rows[0][0], movedProtectedColumn.rows[0][1]] =
    [movedProtectedColumn.rows[0][1], movedProtectedColumn.rows[0][0]];
  [movedProtectedColumn.shape.rows[0].cells[0], movedProtectedColumn.shape.rows[0].cells[1]] =
    [movedProtectedColumn.shape.rows[0].cells[1], movedProtectedColumn.shape.rows[0].cells[0]];
  assert.equal(tableProjectionMatchesAction(
    metadataProjection,
    movedProtectedColumn,
    "right-column:0",
  ), true, "structural moves carry protected descriptors with their cells");

  const downgradeBefore = {
    id: "table-downgrade",
    type: "table",
    shape: {
      v: 2,
      head: { state: "absent" },
      rows: [{ kind: "array", cells: [
        { kind: "inline-array", inline: { v: 1, anchors: ["text"], opaque: ["text"] } },
        "inline-array",
      ] }],
    },
    head: null,
    rows: [[
      [{ type: "text", value: "Protected" }],
      [{ type: "text", value: "Keep" }],
    ]],
  };
  const downgradeAfter = {
    id: "table-downgrade",
    type: "table",
    shape: {
      v: 1,
      head: { state: "absent" },
      rows: [{ kind: "array", cells: ["inline-array"] }],
    },
    head: null,
    rows: [[[{ type: "text", value: "Keep" }]]],
  };
  assert.equal(tableProjectionMatchesAction(
    downgradeBefore,
    downgradeAfter,
    "remove-column:0",
  ), true, "deleting the last protected carrier deliberately downgrades shape v2 to v1");

  const underlinedProjection = {
    id: "table-underlined",
    type: "table",
    shape: {
      v: 1,
      head: { state: "absent" },
      rows: [{ kind: "array", cells: ["inline-array"] }],
    },
    head: null,
    rows: [[[{ type: "underline", children: [{ type: "text", value: "Kept" }] }]]],
  };
  const underlined = mounted(underlinedProjection);
  assert.deepEqual(underlined.editor._editor.getJSON().content[0].content[0].content[0].content, [
    { type: "text", text: "Kept", marks: [{ type: "underline" }] },
  ], "the contextual schema retains every inline mark admitted by the server lens");
  underlined.editor._scheduleEmit();
  assert.equal(underlined.editor.flushPendingChanges(), false);
  underlined.editor.remove();

  for (const [inline, marks] of [
    [
      { type: "strong", children: [{
        type: "underline", children: [{ type: "text", value: "Bold underline" }],
      }] },
      ["bold", "underline"],
    ],
    [
      { type: "em", children: [{
        type: "underline", children: [{ type: "text", value: "Italic underline" }],
      }] },
      ["italic", "underline"],
    ],
    [
      { type: "strong", children: [{ type: "em", children: [{
        type: "underline", children: [{ type: "text", value: "All three" }],
      }] }] },
      ["bold", "italic", "underline"],
    ],
    [
      { type: "link", href: "/papers/table", children: [{
        type: "strong", children: [{ type: "em", children: [{
          type: "underline", children: [{ type: "strikethrough", children: [{
            type: "code", value: "All formatting",
          }] }],
        }] }],
      }] },
      ["link", "bold", "italic", "underline", "strike", "code"],
    ],
  ]) {
    const combinedProjection = clone(underlinedProjection);
    combinedProjection.id = `table-${marks.join("-")}`;
    combinedProjection.rows = [[[inline]]];
    const combined = mounted(combinedProjection);
    const mountedDoc = combined.editor._editor.getJSON();
    const text = mountedDoc.content[0].content[0].content[0].content[0];
    assert.deepEqual(new Set(text.marks.map((mark) => mark.type)), new Set(marks),
      "ProseMirror retains every admitted mark even when schema rank changes array order");
    assert.equal(tableTiptapDocSupported(mountedDoc, combinedProjection), true,
      `admitted ${marks.join("+")} remains writable after ProseMirror canonicalization`);
    text.text += " edited";
    assert.equal(combined.editor._editor.commands.setContent(mountedDoc, true), true);
    assert.equal(combined.editor.flushPendingChanges(), true);
    const expected = clone(inline);
    let leaf = expected;
    while (Array.isArray(leaf.children)) leaf = leaf.children[0];
    leaf.value += " edited";
    assert.deepEqual(combined.ops[0].cells[0].content, [expected],
      "editing text retains the admitted mark nesting in the typed cell operation");
    combined.editor.remove();
  }

  const delta = clone(projected.doc);
  delta.content[0].content[0].content[1].content = [{ type: "text", text: "Job" }];
  delta.content[0].content[2].content[0].content = [{ type: "text", text: "Robert" }];
  assert.deepEqual(buildTableCellsOp(delta, projection), {
    op: "patch-table-cells",
    id: "table-1",
    shape: projection.shape,
    cells: [
      { area: "head", row: 0, column: 1, content: [{ type: "text", value: "Job" }] },
      { area: "body", row: 1, column: 0, content: [{ type: "text", value: "Robert" }] },
    ],
  }, "header and body edits form one ordered, shape-fenced delta");

  const invalidDocs = [
    { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "escape" }] }] },
    { type: "doc", content: [projected.doc.content[0], { type: "paragraph" }] },
    { ...projected.doc, content: [{ ...projected.doc.content[0], content: projected.doc.content[0].content.slice(1) }] },
  ];
  invalidDocs.forEach((doc) => assert.equal(tableTiptapDocSupported(doc, projection), false));
  for (const marks of [
    [{ type: "bold", attrs: { unknown: "silently-dropped" } }],
    [{ type: "link", attrs: {
      href: "/papers/table", target: "_self", rel: "noopener noreferrer nofollow", class: null,
    } }],
    [{ type: "bold" }, { type: "bold" }],
    [{ type: "code" }, { type: "tag", attrs: { name: "competing-leaf" } }],
  ]) {
    const lossy = clone(projected.doc);
    lossy.content[0].content[0].content[0].content[0].marks = marks;
    assert.equal(tableTiptapDocSupported(lossy, projection), false,
      "lossy attributes, repeated marks, and competing leaves fail closed");
    assert.equal(buildTableCellsOp(lossy, projection), null);
  }
  assert.equal(buildTableCellsOp({ type: "doc", content: [{ type: "bpTable", attrs: {
    bpId: "table-1", bpType: "table",
  }, content: [{ type: "bpTableRow", content: [{ type: "bpTableCell", content: [
    { type: "paragraph", content: [{ type: "text", text: "nested" }] },
  ] }] }] }] }, projection), null, "unsupported inline paste fails closed");

  const live = mounted();
  assert.equal(live.editor._editor.isEditable, true);
  assert.equal(live.ops.length, 0, "connecting the Table never writes");
  assert.equal(live.editor.querySelectorAll("table.bp-table").length, 1);
  assert.ok(live.editor.querySelector('[data-table-action="add-row"]'));
  assert.equal(
    live.editor.querySelector('[data-table-action="left-column:0"]').getAttribute("aria-label"),
    "Move column 1 left",
  );
  editCell(live.editor, "body", 0, 0, "Ada Lovelace");
  assert.equal(live.editor.hasPendingChanges(), true);
  assert.equal(live.editor.requestTableStructure("add-row"), true);
  assert.equal(live.ops.length, 1, "cell save is emitted before a structural action");
  assert.equal(live.ops[0].op, "patch-table-cells");
  assert.equal(live.editor.requestTableStructure("add-column"), false,
    "one positional intent remains immutable while waiting for authority");

  const cellAck = clone(projection);
  cellAck.rows[0][0] = clone(live.ops[0].cells[0].content);
  live.editor.block = cellAck;
  assert.equal(live.ops.length, 2, "the acknowledged cell echo releases the structure intent");
  assert.deepEqual(live.ops[1], {
    op: "patch-table-structure",
    id: "table-1",
    shape: projection.shape,
    action: "add-row",
  });
  assert.equal(live.editor._editor.isEditable, false,
    "cell coordinates stay frozen while the positional action awaits authority");

  const structureAck = clone(cellAck);
  structureAck.shape.rows.push({
    kind: "array", cells: ["inline-array", "inline-array"],
  });
  structureAck.rows.push([[], []]);
  live.editor.trackTableMutation(live.ops[1], "structure-1");
  assert.equal(live.editor.applyTableProjection(structureAck, { requestId: "wrong" }), false);
  assert.equal(live.editor._editor.isEditable, false,
    "an unrelated valid projection cannot unlock positional coordinates");
  live.editor.tableMutationResult(live.ops[1], true, { request_id: "structure-1" });
  assert.equal(live.editor._editor.isEditable, false,
    "a receipt without its exact resulting projection stays locked");
  live.editor.applyTableProjection(structureAck, { requestId: "structure-1" });
  assert.equal(live.editor._editor.isEditable, true);
  assert.equal(live.editor.requestTableStructure("remove-row:01"), false);
  assert.equal(live.editor.requestTableStructure("up-row:0"), false);
  assert.equal(live.editor.requestTableStructure("down-row:2"), false);
  assert.equal(live.editor.requestTableStructure("remove-column:9"), false);
  assert.equal(live.editor.requestTableStructure("add-header"), false,
    "header presence fences contradictory actions");
  assert.equal(live.editor.requestTableStructure("remove-header"), true);
  assert.equal(live.ops.at(-1).action, "remove-header");
  live.editor.remove();

  const compensation = mounted();
  editCell(compensation.editor, "body", 0, 0, "Queued B");
  compensation.editor.flushPendingChanges();
  editCell(compensation.editor, "body", 0, 0, "Ada");
  compensation.editor.flushPendingChanges();
  assert.equal(compensation.ops.length, 2, "A→B→A emits a coordinate-scoped compensation");
  assert.deepEqual(compensation.ops[1].cells, [{
    area: "body", row: 0, column: 0, content: [{ type: "text", value: "Ada" }],
  }]);
  const unrelated = clone(projection);
  unrelated.rows[1][1] = [{ type: "text", value: "Server authority" }];
  compensation.editor.block = unrelated;
  assert.equal(compensation.editor._tableAwaitingCells.length, 2,
    "an unrelated echo cannot retire or rebase queued cell payloads");
  compensation.editor.remove();

  const external = mounted();
  const changed = clone(projection);
  changed.rows[1][1] = [{ type: "text", value: "Externally updated" }];
  external.editor.block = changed;
  assert.match(external.editor._editor.getText(), /Externally updated/);
  external.editor.remove();

  const malformed = mounted();
  editCell(malformed.editor, "body", 1, 1, "Retain local draft");
  const retained = clone(malformed.editor._editor.getJSON());
  malformed.editor.block = null;
  assert.equal(JSON.stringify(malformed.editor._editor.getJSON()), JSON.stringify(retained));
  assert.equal(malformed.editor._editor.isEditable, false);
  assert.equal(malformed.errors.at(-1).code, "table_source_unsupported");
  assert.equal(malformed.editor.flushPendingChanges(), false);
  malformed.editor.resolveConflictWithServerBlock(null);
  assert.deepEqual(malformed.editor._editor.getJSON(), {
    type: "doc", content: [{ type: "paragraph" }],
  }, "explicit Use Latest may discard the retained draft into read-only fallback");
  malformed.editor.remove();

  const malformedShapeEcho = mounted();
  editCell(malformedShapeEcho.editor, "body", 1, 1, "Retain across bad shape echo");
  const retainedShapeDraft = clone(malformedShapeEcho.editor._editor.getJSON());
  malformedShapeEcho.editor.block = {
    ...clone(projection),
    shape: { ...clone(projection.shape), rows: ["not-a-row-shape"] },
  };
  assert.equal(JSON.stringify(malformedShapeEcho.editor._editor.getJSON()),
    JSON.stringify(retainedShapeDraft));
  assert.equal(malformedShapeEcho.editor._editor.isEditable, false,
    "a malformed server shape cannot re-enable an editor whose writes would be rejected");
  assert.equal(malformedShapeEcho.errors.at(-1).code, "table_source_unsupported");
  malformedShapeEcho.editor.remove();

  const veto = mounted();
  const beforeVeto = clone(veto.editor._editor.getJSON());
  veto.editor._editor.commands.setContent({ type: "doc", content: [{ type: "paragraph" }] }, true);
  assert.equal(JSON.stringify(veto.editor._editor.getJSON()), JSON.stringify(beforeVeto),
    "mixed paste and singleton escape are rejected before mutation");
  assert.equal(veto.ops.length, 0);
  veto.editor.remove();

  const protectedMounted = mounted(metadataProjection);
  const protectedStatus = protectedMounted.editor.querySelector("[data-table-edit-status]");
  assert.ok(protectedStatus);
  assert.equal(protectedStatus.getAttribute("role"), "status");
  assert.equal(protectedStatus.getAttribute("aria-live"), "polite");
  assert.equal(protectedStatus.hidden, true);
  const beforeProtectedRefusal = clone(protectedMounted.editor._editor.getJSON());
  const splitProtected = clone(beforeProtectedRefusal);
  splitProtected.content[0].content[0].content[0].content = [
    { type: "text", text: "Be" },
    { type: "text", text: "ta", marks: [{ type: "bold" }] },
  ];
  protectedMounted.editor._editor.commands.setContent(splitProtected, true);
  assert.equal(JSON.stringify(protectedMounted.editor._editor.getJSON()),
    JSON.stringify(beforeProtectedRefusal),
    "a protected split is refused before ProseMirror mutates the document");
  assert.equal(protectedStatus.hidden, false);
  assert.match(protectedStatus.textContent, /one non-empty text run/i);
  assert.equal(protectedMounted.editor.hasPendingChanges(), false);
  assert.equal(protectedMounted.editor._tableDirtyToken, null);
  assert.equal(protectedMounted.ops.length, 0,
    "refusal feedback never creates a dirty latch, debounce, or operation");
  const sameStatus = protectedStatus;
  protectedMounted.editor._editor.commands.setContent(splitProtected, true);
  assert.equal(protectedMounted.editor.querySelector("[data-table-edit-status]"), sameStatus,
    "repeated rejected transactions reuse one editor-local live region");

  const markedProtected = clone(beforeProtectedRefusal);
  markedProtected.content[0].content[0].content[0].content[0].marks = [{ type: "bold" }];
  protectedMounted.editor._editor.commands.setContent(markedProtected, true);
  const markedAndTyped = clone(protectedMounted.editor._editor.getJSON());
  markedAndTyped.content[0].content[0].content[0].content[0].text = "Beta queued";
  protectedMounted.editor._editor.commands.setContent(markedAndTyped, true);
  assert.equal(protectedStatus.hidden, true, "the next accepted edit clears stale refusal feedback");
  assert.equal(protectedMounted.editor._editor.commands.undo(), true);
  assert.equal(protectedMounted.editor._editor.getJSON().content[0].content[0]
    .content[0].content[0].text, "Beta");
  assert.equal(protectedMounted.editor._editor.commands.redo(), true);
  assert.equal(protectedMounted.editor._editor.getJSON().content[0].content[0]
    .content[0].content[0].text, "Beta queued");
  assert.equal(protectedMounted.editor.flushPendingChanges(), true);
  assert.equal(protectedMounted.ops.length, 1,
    "whole-run format then typing coalesces into one shape-stable operation before acknowledgement");
  assert.deepEqual(protectedMounted.ops[0].shape, metadataProjection.shape);
  assert.deepEqual(protectedMounted.ops[0].cells[0].content, [{
    type: "strong",
    children: [{ type: "text", value: "Beta queued" }],
  }]);
  const protectedAck = clone(metadataProjection);
  protectedAck.rows[0][0] = clone(protectedMounted.ops[0].cells[0].content);
  protectedMounted.editor.block = protectedAck;
  assert.equal(protectedMounted.editor._tableAwaitingCells.length, 0);
  assert.equal(protectedMounted.editor._editor.isEditable, true,
    "the exact source echo retires the queued topology-preserving edit");
  protectedMounted.editor.remove();

  const freeLinkMounted = mounted(freeLinkProjection);
  const retargeted = clone(freeLinkMounted.editor._editor.getJSON());
  retargeted.content[0].content[0].content[0].content[0].marks[0].attrs.href =
    "/papers/new";
  freeLinkMounted.editor._editor.commands.setContent(retargeted, true);
  const retargetedAndTyped = clone(freeLinkMounted.editor._editor.getJSON());
  retargetedAndTyped.content[0].content[0].content[0].content[0].text =
    "Retargeted and typed";
  freeLinkMounted.editor._editor.commands.setContent(retargetedAndTyped, true);
  assert.equal(freeLinkMounted.editor.flushPendingChanges(), true);
  assert.equal(freeLinkMounted.ops.length, 1,
    "metadata-free href then typing also coalesces without changing anchored shape");
  assert.deepEqual(freeLinkMounted.ops[0].shape, freeLinkProjection.shape);
  assert.deepEqual(freeLinkMounted.ops[0].cells[0].content, [{
    type: "link",
    href: "/papers/new",
    children: [{ type: "text", value: "Retargeted and typed" }],
  }]);
  freeLinkMounted.editor.remove();

  const incompatibleProtectedEcho = mounted(metadataProjection);
  const localProtectedDraft = clone(incompatibleProtectedEcho.editor._editor.getJSON());
  localProtectedDraft.content[0].content[0].content[1].content[0].text = "Local source";
  incompatibleProtectedEcho.editor._editor.commands.setContent(localProtectedDraft, true);
  const retainedProtectedDraft = JSON.stringify(incompatibleProtectedEcho.editor._editor.getJSON());
  const wrongProtectedAuthority = { ...clone(metadataProjection), id: "other-table" };
  assert.equal(incompatibleProtectedEcho.editor.applyTableProjection(wrongProtectedAuthority), false);
  assert.equal(JSON.stringify(incompatibleProtectedEcho.editor._editor.getJSON()),
    retainedProtectedDraft);
  assert.equal(incompatibleProtectedEcho.editor._editor.isEditable, true);
  assert.equal(incompatibleProtectedEcho.editor.hasPendingChanges(), true);
  assert.equal(incompatibleProtectedEcho.editor._sourceBlock.id, "table-metadata");
  assert.equal(incompatibleProtectedEcho.editor._blockId, "table-metadata",
    "a mismatched external projection preserves the draft, exit fence, and editor identity");
  assert.equal(incompatibleProtectedEcho.editor.resolveConflictWithServerBlock(
    wrongProtectedAuthority,
  ), false);
  assert.equal(JSON.stringify(incompatibleProtectedEcho.editor._editor.getJSON()),
    retainedProtectedDraft, "even an external-resync path cannot discard a draft for another id");
  const changedProtectedAuthority = clone(metadataProjection);
  changedProtectedAuthority.rows[0][1][0].href = "/papers/server-change";
  incompatibleProtectedEcho.editor.block = changedProtectedAuthority;
  assert.equal(JSON.stringify(incompatibleProtectedEcho.editor._editor.getJSON()),
    retainedProtectedDraft, "an incompatible protected source echo retains the local draft");
  assert.equal(incompatibleProtectedEcho.editor._editor.isEditable, false,
    "the incompatible draft freezes until explicit conflict resolution");
  assert.equal(incompatibleProtectedEcho.errors.at(-1).code, "table_draft_incompatible");
  assert.equal(incompatibleProtectedEcho.editor.flushPendingChanges(), false);
  incompatibleProtectedEcho.editor.resolveConflictWithServerBlock(changedProtectedAuthority);
  assert.doesNotMatch(incompatibleProtectedEcho.editor._editor.getText(), /Local source/);
  assert.match(incompatibleProtectedEcho.editor._editor.getText(), /Source/);
  assert.equal(incompatibleProtectedEcho.editor._editor.isEditable, true,
    "Use latest installs the compatible authoritative projection and reopens editing");
  incompatibleProtectedEcho.editor.remove();

  for (const invalid of [
    null,
    { ...projection, id: " table-1" },
    { ...projection, shape: null },
    { ...projection, shape: { ...projection.shape, v: 2 } },
    { ...projection, shape: { ...projection.shape, extra: true } },
    { ...projection, shape: { ...projection.shape, rows: [
      { kind: "opaque", cells: ["inline-array", "inline-array"] },
      projection.shape.rows[1],
    ] } },
    { ...projection, shape: { ...projection.shape, rows: [
      { kind: "array", cells: ["inline-array", "content-map"] },
    ] } },
    { ...projection, shape: { ...projection.shape, head: { state: "absent" } } },
    { ...projection, head: null },
    (() => {
      const withoutHead = { ...projection };
      delete withoutHead.head;
      return withoutHead;
    })(),
    { ...projection, rows: [] },
    { ...projection, rows: [[[]], [[], []]] },
    { ...projection, head: [[]] },
    { ...projection, rows: [[[{ type: "text", value: "x", unknown: true }]]] },
  ]) {
    const readonly = mounted(invalid);
    assert.equal(readonly.editor._editor.isEditable, false);
    assert.equal(readonly.editor.flushPendingChanges(), false);
    readonly.editor.remove();
  }

  await import("../../../priv/static/assets/bp-paper-editor-hooks.js?table-contextual");
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
  assert.equal(hookedEditor.requestTableStructure("add-row"), true);
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
  queueEditor._editor.commands.setContent(queuedFormat, true);
  assert.equal(queueEditor.flushPendingChanges(), true);
  assert.equal(queueReplies.length, 1);
  assert.equal(queueReplies[0].payload.if_rev, 10);
  assert.deepEqual(queueReplies[0].payload.shape, queueProjection.shape);

  const queuedType = clone(queueEditor._editor.getJSON());
  queuedType.content[0].content[0].content[0].content[0].text = "Beta after format";
  queueEditor._editor.commands.setContent(queuedType, true);
  assert.equal(queueEditor.flushPendingChanges(), true);
  assert.equal(queueReplies.length, 1,
    "the second old-base operation waits behind the active mutation");
  assert.equal(queueEditor._tableAwaitingCells.length, 2);
  queueHandlers.get("bp:block-update")({
    block_id: "table-protected-queue",
    block: { id: "table-protected-queue", type: "table", rows: "raw metadata echo" },
    table_projection: clone(queueProjection),
    rev: 11,
  });
  assert.equal(queueEditor._tableAwaitingCells.length, 2);
  assert.equal(queueHook._exitCoordinator.hasUnsaved(), true,
    "a metadata-only external echo with identical visible text cannot retire pending local work");

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
