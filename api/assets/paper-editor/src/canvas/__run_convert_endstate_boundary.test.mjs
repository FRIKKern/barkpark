import assert from "node:assert/strict";
import * as root from "./run-convert.js";

const ROOT_EXPORTS = [
  "blockParents", "docToBlocks", "hasOverlappingOps", "holdsNodeIds",
  "idCarriesKind", "nodeContentEqual", "opsRebaseSafe", "pendingUploadIndexes",
  "reconcileServerEcho", "runToOps", "runToTiptap", "withObjectOverrides",
];
const ROOT_ARITIES = {
  blockParents: 1, docToBlocks: 1, hasOverlappingOps: 3, holdsNodeIds: 1,
  idCarriesKind: 2, nodeContentEqual: 2, opsRebaseSafe: 3, pendingUploadIndexes: 2,
  reconcileServerEcho: 2, runToOps: 2, runToTiptap: 1, withObjectOverrides: 2,
};

assert.deepEqual(Object.keys(root), ROOT_EXPORTS, "run-convert public namespace stays exact");
for (const name of ROOT_EXPORTS) {
  assert.equal(typeof root[name], "function", `${name} stays a function`);
  assert.equal(root[name].name, name, `${name} keeps its function name`);
  assert.equal(root[name].length, ROOT_ARITIES[name], `${name} keeps its arity`);
}

const text = (value) => [{ type: "text", value }];
const paragraph = (id, value) => ({ id, type: "paragraph", content: text(value) });
const baseline = [paragraph("p1", "one"), paragraph("p2", "two")];
const projected = root.runToTiptap(baseline);
assert.deepEqual(root.docToBlocks(projected), baseline, "projection reconstructs the original blocks");
assert.deepEqual(root.runToOps(baseline, projected), [], "an unchanged projection emits no ops");

const edited = structuredClone(projected);
edited.content[1].content[0].text = "TWO";
assert.deepEqual(root.runToOps(baseline, edited), [{
  op: "patch-block", id: "p2", patch: { content: text("TWO") },
}], "an edited projection emits the expected patch");

const tree = [{
  id: "section", type: "section", blocks: [
    { id: "child", type: "paragraph", content: text("child") },
    { id: "steps", type: "steps", steps: [{ id: "step", type: "step", blocks: [] }] },
    { id: "tabs", type: "tabs", tabs: [{ id: "tab", type: "tab", children: [] }] },
  ],
}];
assert.deepEqual([...root.blockParents(tree)].map(([id, parents]) => [id, [...parents]]), [
  ["section", [null]], ["child", ["section"]], ["steps", ["section"]],
  ["step", ["steps"]], ["tabs", ["section"]], ["tab", ["tabs"]],
], "all nested block collections preserve parent identity");
assert.equal(root.holdsNodeIds({ type: "bpSection", content: [] }), true);
assert.equal(root.holdsNodeIds({ type: "bpStep", content: [] }), true);
assert.equal(root.holdsNodeIds({ type: "paragraph", content: [] }), false);

assert.equal(root.idCarriesKind(paragraph("same", "a"), paragraph("same", "b")), true);
assert.equal(root.idCarriesKind(paragraph("same", "a"), { id: "same", type: "heading", text: "b" }), true);
assert.equal(root.idCarriesKind(paragraph("same", "a"), { id: "same", type: "image", src: "/x" }), false);

const mine = [{ op: "patch-block", id: "p2", patch: { content: text("TWO") } }];
const peerOther = [paragraph("p1", "ONE"), paragraph("p2", "two")];
const peerSame = [paragraph("p1", "one"), paragraph("p2", "peer")];
assert.equal(root.hasOverlappingOps(mine, baseline, peerOther), false);
assert.equal(root.hasOverlappingOps(mine, baseline, peerSame), true);
assert.equal(root.opsRebaseSafe(mine, baseline, peerOther), true);
assert.equal(root.opsRebaseSafe(mine, baseline, peerSame), false);
assert.equal(root.opsRebaseSafe(mine, baseline, [baseline[1], baseline[0]]), false);

const uploadDoc = { type: "doc", content: [
  { type: "bpImage", attrs: { bpId: null, src: null, uploading: true } },
  { type: "bpImage", attrs: { bpId: "known", src: null, uploadError: "failed" } },
  { type: "bpImage", attrs: { bpId: null, src: "/ready.png", uploading: true } },
] };
assert.deepEqual([...root.pendingUploadIndexes(uploadDoc, [{ id: "known", type: "image" }])], [0]);

const echo = root.reconcileServerEcho(baseline, projected.content);
assert.deepEqual(echo, { ownEcho: true, idWrites: [] });
const mintedEcho = structuredClone(projected.content);
mintedEcho[0].attrs.bpId = null;
assert.deepEqual(root.reconcileServerEcho(baseline, mintedEcho), {
  ownEcho: true, idWrites: [{ index: 0, id: "p1", bpType: undefined }],
});
assert.equal(root.nodeContentEqual(projected.content[0], structuredClone(projected.content[0])), true);
assert.equal(root.nodeContentEqual(projected.content[0], edited.content[1]), false);

const overridden = root.withObjectOverrides(new Set(["paragraph"]), () => {
  const outer = root.runToTiptap([paragraph("outer", "opaque")]).content[0];
  const inner = root.withObjectOverrides(new Set(["heading"]), () =>
    root.runToTiptap([paragraph("inner", "editable")]).content[0]);
  const restored = root.runToTiptap([paragraph("restored", "opaque")]).content[0];
  return { outer, inner, restored };
});
assert.equal(overridden.outer.type, "bpOpaque");
assert.equal(overridden.inner.type, "paragraph");
assert.equal(overridden.restored.type, "bpOpaque");
assert.throws(() => root.withObjectOverrides(new Set(["paragraph"]), () => {
  throw new Error("boundary throw");
}), /boundary throw/);
assert.equal(root.runToTiptap([paragraph("after", "editable")]).content[0].type, "paragraph",
  "throw restores the prior override scope");

console.log("run-convert endstate public lock passed");

try {
  await Promise.all([
    import("./run-project.js"),
    import("./run-node-core.js"),
    import("./run-container-codecs.js"),
    import("./run-diff-utils.js"),
    import("./run-reverse-echo.js"),
    import("./run-ops.js"),
  ]);
} catch (error) {
  if (error && error.code === "ERR_MODULE_NOT_FOUND") {
    console.log("run-convert endstate leaves missing");
    process.exit(1);
  }
  throw error;
}
assert.fail("run-convert endstate leaves unexpectedly exist before extraction");
