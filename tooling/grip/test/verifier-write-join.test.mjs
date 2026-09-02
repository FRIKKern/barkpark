// verifier-write-join.test.mjs — the epic-cycle verifier prompt's ledger
// carve-out is RUNNABLE, not just granted.
//
//   node --test tooling/grip/test/verifier-write-join.test.mjs
//
// The prompt used to say "you may WRITE re-derivation recipe rows under
// tooling/grip/ledger/" and name no verb, no schema, no failure behaviour. The
// fix is prose, and prose drifts silently away from the module it describes.
// So this file does not read the prompt for reassurance — it EXTRACTS the two
// commands out of the workflow file's own text and RUNS them. Rename the verb
// in ledger.mjs, or reword it in the prompt, and only one of the two moves:
// the extracted command then hits the usage line and every case below reds.
//
// Every write here goes to a fresh mkdtemp directory. NOTHING in this file
// touches the committed tooling/grip/ledger/ store.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("../../../", import.meta.url));
const WORKFLOW = join(REPO_ROOT, ".claude/workflows/bp-epic-cycle.workflow.js");
const WORKFLOW_SRC = readFileSync(WORKFLOW, "utf8");

// ── extraction: the prompt's own text is the source of the command ──────────
//
// Deliberately loose about the backtick fencing (the workflow escapes them
// inside a template literal) and strict about the shape that matters: the
// script path and the verb, in the order the prompt tells a verifier to run
// them. A prompt that names a verb ledger.mjs does not dispatch is the defect
// this file exists to catch, so the verbs are NOT hard-coded here.
const NAMED = [...WORKFLOW_SRC.matchAll(/node\s+(tooling\/grip\/ledger\.mjs)\s+([a-z][a-z-]*)\s+<facts\.json>/g)]
  .map((m) => ({ script: m[1], verb: m[2] }));

/** The HOWTO block's own text, sliced out at its unescaped closing backtick. */
function howtoBlock(src) {
  const open = src.indexOf("const LEDGER_WRITE_HOWTO = `");
  if (open < 0) return null;
  let i = open + "const LEDGER_WRITE_HOWTO = `".length;
  for (; i < src.length; i += 1) {
    if (src[i] === "\\") { i += 1; continue; }
    if (src[i] === "`") break;
  }
  return src.slice(open, i);
}

const HOWTO = howtoBlock(WORKFLOW_SRC);
const WRITE_VERB = NAMED.find((n) => n.verb !== "prescreen")?.verb ?? "write";
const SCRIPT = NAMED[0]?.script ?? "tooling/grip/ledger.mjs";

// A FROZEN CLOCK. `write` reads its instant from `date -u` through PATH, and
// run_id is minted from that instant — so an unfrozen replay that straddles a
// second boundary lands a SECOND run file and the idempotence case would be
// testing the wall clock rather than the write path. Shadowing `date` makes
// "the identical write" actually identical.
const FROZEN = "2026-01-02T03:04:05Z";
function frozenEnv() {
  const bin = mkdtempSync(join(tmpdir(), "grip-join-bin-"));
  const stub = join(bin, "date");
  writeFileSync(stub, `#!/bin/sh\nprintf '%s\\n' '${FROZEN}'\n`);
  chmodSync(stub, 0o755);
  return { ...process.env, PATH: `${bin}:${process.env.PATH}` };
}
const ENV = frozenEnv();

const run = (args) => spawnSync("node", [SCRIPT, ...args], { cwd: REPO_ROOT, env: ENV, encoding: "utf8" });
const store = () => mkdtempSync(join(tmpdir(), "grip-join-store-"));
const factsFile = (facts) => {
  const path = join(mkdtempSync(join(tmpdir(), "grip-join-facts-")), "facts.json");
  writeFileSync(path, JSON.stringify(facts, null, 2));
  return path;
};

// A verifier-shaped fact: exactly the three keys the prompt names, and a rerun
// the screen admits.
const GOOD = {
  claim: "screen.mjs exports more than one function",
  evidence: "ran the grep below in the repo root and read the count",
  rerun: "grep -c 'export function' tooling/grip/screen.mjs",
};
// The refusal the prompt warns about: the screen refuses every `node` head.
const REFUSED = {
  claim: "the ledger suite passes",
  evidence: "ran the suite",
  rerun: "node --test tooling/grip/test/ledger.test.mjs",
};

// ── (a) the prompt names a REAL verb, and the drift detector is live ────────

test("the verifier prompt names the ledger write path, and names verbs ledger.mjs dispatches", () => {
  assert.ok(HOWTO !== null, "the workflow must carry a LEDGER_WRITE_HOWTO block — the carve-out with no HOW is the defect");
  assert.equal(NAMED.length, 2, `the prompt must name exactly two <facts.json> commands (rehearse, then write); found ${JSON.stringify(NAMED)}`);
  assert.equal(NAMED[0].verb, "prescreen", "the rehearsal must be named FIRST — the write is all-or-nothing, so a batch is cheap to lose and cheap to rehearse");
  assert.deepEqual(NAMED.map((n) => n.script), [SCRIPT, SCRIPT], "both commands must name the same module");

  // THE DRIFT DETECTOR. An unknown verb falls through main()'s dispatch to the
  // usage line; a real verb reaches its own argument error instead. So this
  // reds on a prompt that invents a verb, without hard-coding what the verb is.
  for (const { verb } of NAMED) {
    const r = spawnSync("node", [SCRIPT, verb], { cwd: REPO_ROOT, env: ENV, encoding: "utf8" });
    assert.ok(
      !/^usage: node ledger\.mjs/m.test(r.stderr),
      `the prompt names \`${verb}\`, which ledger.mjs does not dispatch — it answered with the usage line:\n${r.stderr}`,
    );
    assert.match(r.stderr, new RegExp(`ledger: ${verb} needs a facts file`), `\`${verb}\` must be the facts-taking verb the prompt implies`);
  }
});

test("the block states the schema, the scope fence and the failure behaviour, and is denied to worktree verifiers", () => {
  assert.match(HOWTO, /\{claim, evidence, rerun\}/, "the schema a verifier must materialise itself");
  assert.match(HOWTO, /never a .*value.*\/.*result.* key/, "the store indexes recipes, never values (D26)");
  assert.match(HOWTO, /tooling\/grip\/ledger\//, "the scope fence names the directory");
  assert.match(HOWTO, /one new .*<run_id>-<digest>\.json/, "the scope fence names one new file per write");
  assert.match(HOWTO, /REJECTED — nothing was written/, "the all-or-nothing failure line, verbatim");
  assert.match(HOWTO, /REFUSED-COMMAND/, "the reason class a verifier will actually hit");
  assert.match(HOWTO, /already recorded/, "the idempotent replay outcome");
  assert.match(HOWTO, /exits 1/, "the refusal exit code");
  assert.match(HOWTO, /exits 2/, "the usage/IO exit code");
  // The carve-out and its denial are one sentence apart; the HOW must inherit
  // the same denial, or a throwaway-worktree verifier is handed a runnable
  // recipe for a row Decide can never reach.
  assert.match(WORKFLOW_SRC, /q\.needs_worktree \? '' : LEDGER_WRITE_HOWTO/, "the HOWTO must be denied on the needs_worktree branch");
  assert.match(WORKFLOW_SRC, /you may WRITE re-derivation recipe rows under tooling\/grip\/ledger\//, "the carve-out itself must still be granted");
});

// ── (b) one fact → exactly one valid row, foldable ──────────────────────────

test("one verifier-shaped fact writes exactly one row file, and fold reads it back", () => {
  const dir = store();
  const w = run([WRITE_VERB, factsFile([GOOD]), dir]);
  assert.equal(w.status, 0, `write must exit 0; stderr:\n${w.stderr}`);
  assert.match(w.stdout, /^wrote {2}/m, `write must report the file it wrote; stdout:\n${w.stdout}`);

  const files = readdirSync(dir);
  assert.equal(files.length, 1, `exactly one new run file per write; got ${JSON.stringify(files)}`);
  assert.match(files[0], /^grip-\d{8}T\d{6}Z-[0-9a-f]{16}\.json$/, "the filename is <run_id>-<digest of its own bytes>.json — the attestation the fold's `attested` scope reads");

  const f = run(["fold", dir]);
  assert.equal(f.status, 0, `fold must read the store back cleanly; stderr:\n${f.stderr}`);
  const folded = JSON.parse(f.stdout);
  assert.equal(folded.entries.length, 1, "one fact in, one entry out");
  assert.equal(folded.unreadable.length, 0, "a row the fold cannot admit is a forged store");
  const row = JSON.parse(readFileSync(join(dir, files[0]), "utf8")).recipes[0];
  assert.deepEqual(Object.keys(row).sort(), ["deps", "derived_level", "observed_at", "quantity", "rerun", "subject"], "the frozen six-key allowlist");
  assert.equal(row.rerun, GOOD.rerun, "only `rerun` survives the mint — the prompt says so");
  assert.ok(!("claim" in row) && !("evidence" in row), "claim and evidence are DROPPED, exactly as the prompt states");
});

// ── (c) the replay is deterministic and corrupts nothing ────────────────────

test("the identical write replays as `already recorded` — one file, store and facts file intact", () => {
  const dir = store();
  const facts = factsFile([GOOD]);
  const before = readFileSync(facts, "utf8");

  const first = run([WRITE_VERB, facts, dir]);
  assert.equal(first.status, 0, `first write must exit 0; stderr:\n${first.stderr}`);
  assert.match(first.stdout, /^wrote {2}/m, "the first write stores the file");
  const afterFirst = readdirSync(dir);

  const replay = run([WRITE_VERB, facts, dir]);
  assert.equal(replay.status, 0, `the replay must exit 0, not error; stderr:\n${replay.stderr}`);
  assert.match(replay.stdout, /^already recorded {2}/m, `the replay must be idempotent, not a second row; stdout:\n${replay.stdout}`);
  assert.deepEqual(readdirSync(dir), afterFirst, "the replay adds no file and removes none");
  assert.equal(readFileSync(facts, "utf8"), before, "the write never rewrites the caller's facts.json");

  const f = run(["fold", dir]);
  assert.equal(f.status, 0, `the store must still fold after a replay; stderr:\n${f.stderr}`);
  assert.equal(JSON.parse(f.stdout).entries.length, 1, "the entry count is unchanged by the replay");
});

// ── (d) malformed input → the documented refusal and exit code ──────────────

test("a refused row stores nothing and exits 1; an unreadable facts file exits 2", () => {
  const dir = store();
  const seed = run([WRITE_VERB, factsFile([GOOD]), dir]);
  assert.equal(seed.status, 0, `seeding the store must succeed; stderr:\n${seed.stderr}`);
  const seeded = readdirSync(dir);
  assert.equal(seeded.length, 1, "one seed file");

  // ALL-OR-NOTHING: the good row rides in the same batch as the refused one and
  // is lost with it. A file holding only the survivors IS the silent-strip
  // defect at file granularity, which is why the prompt says never retry
  // unchanged.
  const mixed = run([WRITE_VERB, factsFile([{ ...GOOD, rerun: "wc -l tooling/grip/mint.mjs" }, REFUSED]), dir]);
  assert.equal(mixed.status, 1, `a refused row must exit 1; stderr:\n${mixed.stderr}`);
  assert.match(mixed.stderr, /REJECTED — nothing was written/, "the verbatim line the prompt quotes");
  assert.match(mixed.stderr, /REFUSED-COMMAND/, "the reason class the prompt names");
  assert.deepEqual(readdirSync(dir), seeded, "nothing was written — including the row that passed");

  // Not a facts file at all: usage/IO, exit 2, and the store is untouched.
  const badShape = join(mkdtempSync(join(tmpdir(), "grip-join-bad-")), "facts.json");
  writeFileSync(badShape, JSON.stringify({ nope: true }));
  const bad = run([WRITE_VERB, badShape, dir]);
  assert.equal(bad.status, 2, `a non-array facts file must exit 2; stderr:\n${bad.stderr}`);
  assert.match(bad.stderr, /must be a JSON array of facts, or an object with a "facts" array/, "the loader's own message");
  assert.deepEqual(readdirSync(dir), seeded, "a usage error stores nothing");

  const f = run(["fold", dir]);
  assert.equal(f.status, 0, `the store survives both refusals; stderr:\n${f.stderr}`);
  assert.equal(JSON.parse(f.stdout).entries.length, 1, "still exactly the seeded entry");
});
