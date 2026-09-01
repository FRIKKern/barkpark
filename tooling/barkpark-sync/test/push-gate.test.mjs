#!/usr/bin/env node
// Proof that push.mjs REFUSES — end to end, as a real process.
//
//   node --test tooling/barkpark-sync/test/push-gate.test.mjs
//
// provenance.test.mjs proves the predicate. This file proves the predicate is
// WIRED: that push.mjs consults it, that the refusal is a real non-zero process
// exit and not a printed warning, and that it happens before the first write.
// The distinction matters because the earlier guard in this same file — the
// `--dataset production` refusal — was once verified through a pipe, and a pipe
// eats node's exit code. Nothing here pipes.
//
// HERMETIC: --host points at a closed port and every case exits before any
// fetch. --dry-run additionally forbids the write phases outright.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { bareNode, priorNode, agentNode, intentionNode, wrap } from "./fixture.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const PUSH = join(HERE, "..", "push.mjs");
// A port nothing listens on. If the gate ever let a case through to the network
// the test would fail loudly on a connection error rather than quietly passing.
const DEAD_HOST = "http://127.0.0.1:9";

/** Run push.mjs over a fixture corpus. Never piped — the exit code is the point. */
function runPush(nodes, extra = []) {
  const dir = mkdtempSync(join(tmpdir(), "bp-sync-gate-"));
  try {
    const path = join(dir, "nodes.json");
    writeFileSync(path, JSON.stringify(wrap(nodes)), "utf8");
    const r = spawnSync(process.execPath, [PUSH, "--host", DEAD_HOST, "--nodes", path, "--dry-run", ...extra], {
      encoding: "utf8", cwd: HERE, timeout: 60_000,
      env: { ...process.env, BARKPARK_API_URL: DEAD_HOST },
    });
    return { code: r.status, out: (r.stdout || "") + (r.stderr || ""), signal: r.signal };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("(a) a node lacking tier provenance refuses with exit 2 and a named reason", () => {
  const r = runPush([bareNode()]);
  assert.equal(r.signal, null, `push.mjs was killed (${r.signal}) instead of exiting — ${r.out.slice(-400)}`);
  assert.equal(r.code, 2, `expected exit 2, got ${r.code}\n${r.out.slice(-800)}`);
  assert.match(r.out, /REFUSING to publish/, "the refusal must say so in words");
  assert.match(r.out, /missing-provenance/, "the reason must be named, not summarised");
  assert.match(r.out, /api\/lib\/barkpark\/accounts\.ex/, "the refusal must name the file");
  assert.doesNotMatch(r.out, /created |published |ingested/, "nothing may be written on a refusal");
});

test("the refusal fires before the first mutation, not after a partial write", () => {
  const r = runPush([agentNode(), bareNode()]);
  assert.equal(r.code, 2);
  assert.doesNotMatch(r.out, /registered paper schema/,
    "the gate must precede the schema register, or a refused corpus still touches the server");
});

test("(b) a labelled corpus passes the gate and renders the marker in the body", () => {
  const r = runPush([agentNode(), priorNode({ id: "b", path: "b.ex" }), intentionNode()]);
  assert.equal(r.code, 0, `expected a clean dry run, got ${r.code}\n${r.out.slice(-800)}`);
  assert.match(r.out, /provenance gate: 3 node\(s\) labelled/);
  assert.match(r.out, /AGENT JUDGMENT \(L6\)/, "the marker must reach the rendered body");
  assert.match(r.out, /tier agent/);
  assert.match(r.out, /0 written to/, "--dry-run must write nothing");
});

test("(c) a prior-based corpus never renders the word importance", () => {
  const r = runPush([priorNode()]);
  assert.equal(r.code, 0, r.out.slice(-800));
  const sample = r.out.split("sample body")[1] || "";
  assert.ok(sample.length, "the dry run must print a sample body to inspect");
  assert.match(sample, /prior 58/);
  assert.doesNotMatch(sample, /importance/i,
    "a deterministic prior rendered under the name importance is the defect this gate exists for");
});

test("the --dataset production refusal still stands, and still exits 2", () => {
  const r = runPush([agentNode()], ["--dataset", "production"]);
  assert.equal(r.code, 2, `expected exit 2, got ${r.code}\n${r.out.slice(-400)}`);
  assert.match(r.out, /refusing to publish code papers into 'production'/);
});

test("the gate does not fire on a corpus it should accept — the refusal discriminates", () => {
  // A gate that refuses everything is as useless as one that refuses nothing.
  // This is the non-vacuity check: the SAME runner, the SAME flags, green.
  const r = runPush([agentNode()]);
  assert.equal(r.code, 0, r.out.slice(-800));
  assert.doesNotMatch(r.out, /REFUSING/);
});
