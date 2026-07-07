// __tasklist.test.mjs — pure-Node unit test for the LIVE-DATA task-list WIDGET: a
// `task-list` block carrying a `query` map rides the canvas as an EDITABLE-QUERY +
// server-painted-ROWS ATOM (`bpTaskList`). The QUERY is the sole authored datum and
// emits ONE patch-block{query}; the rows are a server-painted projection (never on
// the node). A snapshot-only task-list (no query) is the LEGACY author-pinned form
// and routes to the READ-ONLY bpFleet atom — the additive presence-of-query
// discriminant (mirrors task_resolver.ex:139).
//
// Pure by construction: imports ONLY the DOM-free projector/diff from run-convert.js
// (used verbatim by the live WC) + the node NAMES from task-list-node.js /
// embed-node.js (the Node.create schema loads in plain Node; its NodeView factory —
// the only `document` toucher — never runs here). No TipTap editor, no browser.
// Run: node src/canvas/__tasklist.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { runToTiptap, runToOps, docToBlocks, reconcileServerEcho } from "./run-convert.js";
import { BP_TASK_LIST_NODE_NAME } from "./task-list-node.js";
import { BP_FLEET_NODE_NAME } from "./embed-node.js";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const clone = (v) => JSON.parse(JSON.stringify(v));

// Fixtures. A LIVE task-list (query + title), a live task-list whose selector lives in
// parent_id/status (NOT label — the verbatim-carry case), and a LEGACY snapshot-only
// task-list (author-pinned, no query → bpFleet).
const LIVE = { id: "t1", type: "task-list", query: { label: "proj:x" }, title: "Plan" };
const LIVE_MULTI = {
  id: "t2",
  type: "task-list",
  query: { parent_id: "epic-7", status: "open", label: "proj:x" },
};
const LEGACY_SNAP = {
  id: "t3",
  type: "task-list",
  snapshot: [{ title: "Pinned", status: "open" }],
};

const para = (id, text = "hi") => ({
  id,
  type: "paragraph",
  content: [{ type: "text", text }],
});

// ── a) PROJECTION + DISCRIMINANT ──────────────────────────────────────────────

check("runToTiptap: a query-carrying task-list projects to a bpTaskList widget (query+title on attrs, NO snapshot)", () => {
  const node = runToTiptap([LIVE]).content[0];
  assert.equal(node.type, BP_TASK_LIST_NODE_NAME, "node type is bpTaskList");
  assert.equal(node.attrs.bpId, "t1");
  assert.equal(node.attrs.bpType, "task-list");
  assert.deepEqual(node.attrs.query, { label: "proj:x" }, "query carried");
  assert.equal(node.attrs.title, "Plan", "title carried");
  assert.equal("snapshot" in node.attrs, false, "NO snapshot on the node");
  // Deep-cloned query — mutating the node's query must not touch source.
  node.attrs.query.__poke = 1;
  assert.equal(LIVE.query.__poke, undefined, "query is a deep clone");
});

check("runToTiptap: a snapshot-only task-list routes to the READ-ONLY bpFleet atom (NOT bpTaskList)", () => {
  const node = runToTiptap([LEGACY_SNAP]).content[0];
  assert.equal(node.type, BP_FLEET_NODE_NAME, "snapshot-only → bpFleet (read-only)");
  assert.notEqual(node.type, BP_TASK_LIST_NODE_NAME);
  // The WHOLE legacy block rides verbatim on bpBlock (the read-only carry).
  assert.deepEqual(node.attrs.bpBlock, LEGACY_SNAP, "legacy block carried verbatim");
});

// ── b) IDENTITY ROUND-TRIP ─────────────────────────────────────────────────────

check("docToBlocks: reconstructs a live task-list byte-identically (title present, no snapshot)", () => {
  const round = docToBlocks(runToTiptap([LIVE, LIVE_MULTI]));
  assert.deepEqual(round, [LIVE, LIVE_MULTI]);
  assert.equal("snapshot" in round[0], false, "no stray snapshot");
});

check("docToBlocks: a title-less live task-list gains NO title key", () => {
  const bare = { id: "t9", type: "task-list", query: { label: "proj:z" } };
  const round = docToBlocks(runToTiptap([bare]));
  assert.deepEqual(round, [bare]);
  assert.equal("title" in round[0], false, "no stray title key");
});

// ── c) NO-OP (D3) ────────────────────────────────────────────────────────────────

check("runToOps: an unedited run of task-lists + prose emits ZERO ops (D3 byte-stability)", () => {
  const blocks = [para("p0"), LIVE, LIVE_MULTI, LEGACY_SNAP, para("p1")];
  const ops = runToOps(blocks, runToTiptap(blocks));
  assert.deepEqual(ops, []);
});

// ── d) QUERY IS ACTUALLY EDITABLE ─────────────────────────────────────────────────

check("runToOps: editing query.label (proj:x → proj:y) emits EXACTLY one patch-block{query} and nothing else", () => {
  const prev = [LIVE];
  const doc = runToTiptap([LIVE]);
  doc.content[0].attrs.query = { label: "proj:y" };
  const ops = runToOps(prev, doc);
  assert.deepEqual(ops, [{ op: "patch-block", id: "t1", patch: { query: { label: "proj:y" } } }]);
  // No snapshot/rows op rode along.
  assert.ok(!ops.some((o) => "snapshot" in o || "content" in o), "no snapshot/content op");
});

check("runToOps: editing query.label on a MULTI-key query carries the OTHER keys VERBATIM (parent_id/status kept)", () => {
  const prev = [LIVE_MULTI];
  const doc = runToTiptap([LIVE_MULTI]);
  // The v1 label control edits ONLY label; the node-view builds {...prev, label}.
  doc.content[0].attrs.query = { parent_id: "epic-7", status: "open", label: "proj:NEW" };
  const ops = runToOps(prev, doc);
  assert.equal(ops.length, 1, "exactly one op");
  assert.deepEqual(ops[0].patch.query, {
    parent_id: "epic-7",
    status: "open",
    label: "proj:NEW",
  }, "non-label keys round-trip verbatim");
});

check("runToOps: clearing query.label DROPS the label key but keeps sibling keys (empty label → drop, not {})", () => {
  const prev = [LIVE_MULTI];
  const doc = runToTiptap([LIVE_MULTI]);
  // The node-view drops the label key when the input empties.
  doc.content[0].attrs.query = { parent_id: "epic-7", status: "open" };
  const ops = runToOps(prev, doc);
  assert.deepEqual(ops[0].patch.query, { parent_id: "epic-7", status: "open" });
});

check("runToOps: emptying the WHOLE query → patch carries query:null (the configure-me empty state)", () => {
  const prev = [LIVE];
  const doc = runToTiptap([LIVE]);
  doc.content[0].attrs.query = null; // node-view: last key dropped → null
  const ops = runToOps(prev, doc);
  assert.deepEqual(ops, [{ op: "patch-block", id: "t1", patch: { query: null } }]);
});

// ── e) TITLE + CONFIG ─────────────────────────────────────────────────────────────

check("runToOps: clearing the title emits patch carrying title:\"\" (shallow-merge overwrite of a stale title)", () => {
  const prev = [LIVE];
  const doc = runToTiptap([LIVE]);
  doc.content[0].attrs.title = null; // node-view maps "" → null
  const ops = runToOps(prev, doc);
  assert.equal(ops.length, 1);
  assert.equal(ops[0].patch.title, "", 'cleared title rides as "" so the merge overwrites');
  // query still present (patch-block always carries the query).
  assert.deepEqual(ops[0].patch.query, { label: "proj:x" });
});

check("config round-trips VERBATIM and only rides the patch when it changed", () => {
  const withCfg = {
    id: "t5",
    type: "task-list",
    query: { label: "proj:x" },
    config: { limit: 10, fields: ["title", "status"] },
  };
  // round-trip identity
  assert.deepEqual(docToBlocks(runToTiptap([withCfg])), [withCfg]);
  // unedited → zero ops
  assert.deepEqual(runToOps([withCfg], runToTiptap([withCfg])), []);
  // editing config → patch carries the new config
  const doc = runToTiptap([withCfg]);
  doc.content[0].attrs.config = { limit: 25, fields: ["title"] };
  const ops = runToOps([withCfg], doc);
  assert.equal(ops.length, 1);
  assert.deepEqual(ops[0].patch.config, { limit: 25, fields: ["title"] });
  // editing ONLY the query must NOT drag a config key into the patch.
  const doc2 = runToTiptap([withCfg]);
  doc2.content[0].attrs.query = { label: "proj:y" };
  const ops2 = runToOps([withCfg], doc2);
  assert.equal("config" in ops2[0].patch, false, "unchanged config stays out of the patch");
});

// ── f) STRUCTURAL ────────────────────────────────────────────────────────────────

check("runToOps: removing a task-list emits remove-block (structural, id-keyed)", () => {
  const prev = [para("p0"), LIVE, para("p1")];
  const nextDoc = runToTiptap([para("p0"), para("p1")]);
  const ops = runToOps(prev, nextDoc);
  assert.deepEqual(
    ops.filter((o) => o.op === "remove-block"),
    [{ op: "remove-block", id: "t1" }],
  );
});

check("runToOps: inserting a live task-list carries the query under a minted id (no snapshot)", () => {
  const prev = [para("p0")];
  const newTL = {
    type: BP_TASK_LIST_NODE_NAME,
    attrs: { bpId: null, bpType: "task-list", query: { label: "proj:new" }, title: null, config: null },
  };
  const nextDoc = { type: "doc", content: [runToTiptap([para("p0")]).content[0], newTL] };
  const ops = runToOps(prev, nextDoc);
  const insert = ops.find((o) => o.op === "insert-after" || o.op === "append-block");
  assert.ok(insert, "an insert op is emitted");
  assert.equal(insert.block.type, "task-list");
  assert.deepEqual(insert.block.query, { label: "proj:new" }, "query rides the insert");
  assert.ok(insert.block.id && insert.block.id !== "", "minted id present");
  assert.equal("snapshot" in insert.block, false, "no snapshot on an inserted live task-list");
  assert.equal("title" in insert.block, false, "no stray title on a title-less insert");
});

check("runToOps: a pure reorder emits move-block only, never a query patch", () => {
  const p0 = runToTiptap([para("p0")]).content[0];
  const tlNode = runToTiptap([LIVE]).content[0];
  const reordered = { type: "doc", content: [tlNode, p0] };
  const moveOps = runToOps([para("p0"), LIVE], reordered);
  assert.ok(moveOps.some((o) => o.op === "move-block"), "a move-block is emitted");
  assert.ok(!moveOps.some((o) => o.op === "patch-block"), "no patch on a pure reorder");
});

// ── g) ECHO ──────────────────────────────────────────────────────────────────────

check("reconcileServerEcho: an unchanged task-list run is an own echo", () => {
  const server = [LIVE, LIVE_MULTI];
  const live = runToTiptap(server).content;
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.deepEqual(idWrites, []);
});

check("reconcileServerEcho: a just-minted task-list (bpId:null) own-echoes with an id write", () => {
  const server = [LIVE];
  const live = runToTiptap(server).content;
  live[0].attrs.bpId = null;
  const { ownEcho, idWrites } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, true);
  assert.equal(idWrites.length, 1);
  assert.equal(idWrites[0].id, "t1");
});

check("reconcileServerEcho: a REAL query change is NOT an own echo (falls to the external path)", () => {
  const server = [LIVE];
  const live = clone(runToTiptap(server).content);
  live[0].attrs.query = { label: "external-edit" };
  const { ownEcho } = reconcileServerEcho(server, live);
  assert.equal(ownEcho, false);
});

if (failures > 0) {
  console.log(`\n${failures} check(s) FAILED`);
  process.exit(1);
}
console.log("\nall live-data task-list checks passed");
