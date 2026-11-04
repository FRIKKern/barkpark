import assert from "node:assert/strict";
import * as root from "./run-convert.js";

const ROOT_EXPORTS = [
  "blockParents",
  "docToBlocks",
  "hasOverlappingOps",
  "holdsNodeIds",
  "idCarriesKind",
  "nodeContentEqual",
  "opsRebaseSafe",
  "pendingUploadIndexes",
  "reconcileServerEcho",
  "runToOps",
  "runToTiptap",
  "withObjectOverrides",
];

const ROOT_ARITIES = {
  blockParents: 1,
  docToBlocks: 1,
  hasOverlappingOps: 3,
  holdsNodeIds: 1,
  idCarriesKind: 2,
  nodeContentEqual: 2,
  opsRebaseSafe: 3,
  pendingUploadIndexes: 2,
  reconcileServerEcho: 2,
  runToOps: 2,
  runToTiptap: 1,
  withObjectOverrides: 2,
};

assert.deepEqual(Object.keys(root), ROOT_EXPORTS, "run-convert public namespace stays exact");
for (const name of ROOT_EXPORTS) {
  const descriptor = Object.getOwnPropertyDescriptor(root, name);
  assert.equal(typeof root[name], "function", `${name} stays a function`);
  assert.equal(root[name].name, name, `${name} keeps its function name`);
  assert.equal(root[name].length, ROOT_ARITIES[name], `${name} keeps its arity`);
  assert.deepEqual(
    { writable: descriptor.writable, enumerable: descriptor.enumerable, configurable: descriptor.configurable },
    { writable: true, enumerable: true, configurable: false },
    `${name} keeps its module descriptor`,
  );
}

const text = value => [{ type: "text", value }];

const callout = { id: "callout-1", type: "callout", tone: "warning", title: "Mind", content: text("Before") };
const calloutDoc = root.runToTiptap([callout]);
assert.deepEqual(calloutDoc.content[0], {
  type: "callout",
  attrs: { bpId: "callout-1", bpType: "callout", tone: "warning", title: "Mind" },
  content: [{ type: "text", text: "Before" }],
});
calloutDoc.content[0].content = [{ type: "text", text: "After" }];
assert.deepEqual(root.runToOps([callout], calloutDoc), [
  { op: "patch-block", id: "callout-1", patch: { content: text("After") } },
]);

const note = { id: "note-1", type: "note", label: "Fact", lead: "Lead", text: "Before" };
const noteDoc = root.runToTiptap([note]);
assert.deepEqual(noteDoc.content[0], {
  type: "note",
  attrs: { bpId: "note-1", bpType: "note", bpBlock: note, label: "Fact", lead: "Lead" },
  content: [{ type: "text", text: "Before" }],
});
noteDoc.content[0].content = [{ type: "text", text: "After" }];
assert.deepEqual(root.runToOps([note], noteDoc), [
  { op: "patch-block", id: "note-1", patch: { text: "After" } },
]);

const card = {
  id: "card-1",
  type: "card",
  tone: "accent",
  slots: {
    title: [{ type: "heading", text: "Card" }],
    body: [{ type: "paragraph", content: text("Before") }],
  },
};
const cardDoc = root.runToTiptap([card]);
assert.equal(cardDoc.content[0].type, "bpCard");
assert.deepEqual(cardDoc.content[0].attrs, {
  bpId: "card-1",
  bpType: "card",
  bpBlock: card,
  title: "Card",
  tone: "accent",
});
cardDoc.content[0].content = [{ type: "text", text: "After" }];
assert.deepEqual(root.runToOps([card], cardDoc), [{
  op: "patch-block",
  id: "card-1",
  patch: {
    slots: {
      title: [{ type: "heading", text: "Card" }],
      body: [{ type: "paragraph", content: text("After") }],
    },
  },
}]);

console.log("run content codec public boundary passed");
