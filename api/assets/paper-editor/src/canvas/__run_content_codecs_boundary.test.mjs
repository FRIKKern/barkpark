import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as root from "./run-convert.js";
import * as codecs from "./run-content-codecs.js";

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

const CODEC_EXPORTS = [
  "calloutBlockToNode",
  "calloutNodeChanged",
  "calloutNodeToBlock",
  "calloutNodeToPatch",
  "cardBlockEditable",
  "cardBlockToNode",
  "cardNodeChanged",
  "cardNodeToBlock",
  "cardNodeToPatch",
  "noteBlockToNode",
  "noteNodeChanged",
  "noteNodeToBlock",
  "noteNodeToPatch",
  "stableNoteKey",
];
assert.deepEqual(Object.keys(codecs), CODEC_EXPORTS, "codec leaf namespace stays exact");

const DECLARATIONS = [
  "calloutBodyInline", "calloutBlockToNode", "calloutNodeToBlock", "calloutNodeToPatch",
  "calloutNodeChanged", "stableCalloutKey", "noteScalarText", "noteNoRichShadow",
  "noteInlineTerminal", "noteFieldState", "noteState", "flattenInlineText",
  "flattenInlineNode", "noteNodeBodyText", "noteBlockToNode", "noteNodeToBlock",
  "noteNodeToPatch", "noteNodeChanged", "stableNoteKey", "cardBodyInline", "cardTitle",
  "cardMedia", "cardAction", "optionalCardText", "cardSlotSupported",
  "cardBodyContentSupported", "cardBlockEditable", "cardBlockToNode", "cardNodeSlotOverlay",
  "cardNodeToSlots", "cardNodeToBlock", "cardNodeToPatch", "cardNodeChanged", "stableCardKey",
];
const here = dirname(fileURLToPath(import.meta.url));
const rootPath = resolve(here, "run-convert.js");
const leafPath = resolve(here, "run-content-codecs.js");
const rootSource = readFileSync(rootPath, "utf8");
const leafSource = readFileSync(leafPath, "utf8");
assert.ok(rootSource.split("\n").length - 1 < 800, "endstate run-convert facade stays below 800 physical lines");

const endstatePaths = [
  "run-project.js",
  "run-node-core.js",
  "run-container-codecs.js",
  "run-diff-utils.js",
  "run-reverse-echo.js",
  "run-ops.js",
];
const endstateSources = Object.fromEntries(endstatePaths.map((path) => [path, readFileSync(resolve(here, path), "utf8")]));
for (const name of DECLARATIONS) {
  const pattern = new RegExp(`\\bfunction\\s+${name}\\s*\\(`, "g");
  assert.equal([...leafSource.matchAll(pattern)].length, 1, `${name} is defined exactly once in the leaf`);
  for (const [owner, source] of [["run-convert.js", rootSource], ...Object.entries(endstateSources)]) {
    assert.equal([...source.matchAll(pattern)].length, 0, `${name} is absent from ${owner}`);
  }
}

const importSpecifiers = source => [...source.matchAll(
  /(?:^|\n)\s*(?:import|export)\s+(?:[^"'\n]*?\s+from\s+)?["']([^"']+)["']/g,
)].map(match => match[1]);
assert.deepEqual(importSpecifiers(leafSource), ["../convert.js", "./projection-json.js", "./run-kinds.js"]);
const contentConsumers = new Set([
  "run-project.js", "run-container-codecs.js", "run-reverse-echo.js", "run-ops.js",
]);
for (const [owner, source] of [["run-convert.js", rootSource], ...Object.entries(endstateSources)]) {
  const count = (source.match(/from "\.\/run-content-codecs\.js"/g) || []).length;
  assert.equal(count, contentConsumers.has(owner) ? 1 : 0,
    `${owner} has its exact canonical content-codec import ownership`);
}
assert.doesNotMatch(leafSource, /from ["']\.\/run-convert\.js["']/,
  "codec leaf never imports the root");

const visiting = new Set();
const visited = new Set();
function walk(file) {
  assert.notEqual(file, rootPath, "codec dependency closure cannot reach run-convert");
  assert.ok(!visiting.has(file), `relative import cycle at ${file}`);
  if (visited.has(file)) return;
  visiting.add(file);
  const source = readFileSync(file, "utf8");
  for (const specifier of importSpecifiers(source)) {
    if (specifier.startsWith(".")) walk(resolve(dirname(file), specifier));
  }
  visiting.delete(file);
  visited.add(file);
}
walk(leafPath);

assert.ok(leafSource.split("\n").length - 1 < 800, "codec leaf stays below 800 physical lines");
assert.ok(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").length - 1 < 800,
  "boundary test stays below 800 physical lines");

console.log("run content codec public boundary passed");
