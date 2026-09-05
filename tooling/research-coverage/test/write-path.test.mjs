// tooling/research-coverage/coverage.mjs — the REAL commands, end to end.
//
//   node --test tooling/research-coverage/test/write-path.test.mjs
//
// ledger-io.test.mjs unit-tests the write path in isolation. This file runs
// `coverage.mjs record|prune|seed|scan` as actual child processes against a
// hermetic throwaway git repo, because the defects were in how those four
// commands USE the write path, not only in the write path itself. A unit test
// of foldEntry cannot notice that record() never calls it.
//
// The repo is built here (git init + N files + a copy of the tool) rather than
// pointed at the monorepo: the real corpus is ~7,100 files and one `record`
// takes ~11s, which is both slow and non-hermetic.
//
// PRE-FIX EVIDENCE these reproduce, from the same shape at 3,000 files:
//   record:  `evidenceLevel present: false`, entry keys back to the fixed seven
//   record:  `procA present: 1500/1500`, `procB present: 0/200`, both exit 0

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, cpSync, rmSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "..");                       // tooling/research-coverage
const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

// Removing a fixture tree can lose a race with the writers that just used it: a
// child that has exited may still have an unreaped git subprocess, or the OS may
// not have released a directory entry yet, and the recursive walk then throws
// ENOTEMPTY on `.git` — which is how run 33958978109 reddened main from the
// CLEANUP of test 32, not from any assertion in it.
//
// The retry is written out by hand rather than passed as `maxRetries`, because
// rmSync's own retry does NOT cover this case. Measured on node v22.22.0, with a
// sibling process creating entries under `.git` while the removal runs, 10 of 10
// attempts threw ENOTEMPTY with `{ maxRetries: 10, retryDelay: 100 }` — the same
// 10 of 10 as with no options at all — while re-entering rmSync from the top 12
// times, 100ms apart, went 10 of 10 green. maxRetries retries an individual
// syscall inside one walk; only a fresh walk re-reads a directory that has grown
// since. The concurrency test additionally waits for both children to CLOSE (not
// merely exit) before it gets here, so this is the second line of defence.
const rmDir = (d) => {
  let last = null;
  for (let i = 0; i < 12; i++) {
    try { rmSync(d, { recursive: true, force: true }); return; }
    catch (e) { last = e; Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100); }
  }
  throw last;
};

// A throwaway git repo carrying its own copy of the tool. `nfiles` sets the
// corpus size, which is what sets the width of record()'s critical section.
function makeRepo(nfiles = 400) {
  const root = mkdtempSync(join(tmpdir(), "bp-coverage-repo-"));
  const cd = join(root, "tooling", "research-coverage");
  mkdirSync(join(root, "src"), { recursive: true });
  mkdirSync(join(cd, "results"), { recursive: true });
  for (let i = 1; i <= nfiles; i++) writeFileSync(join(root, "src", `f${i}.txt`), `file ${i}\n`);
  for (const f of ["coverage.mjs", "ledger-io.mjs", "config.json"]) cpSync(join(SRC, f), join(cd, f));
  const git = (...a) => execFileSync("git", a, { cwd: root, encoding: "utf8" });
  git("init", "-q", ".");
  git("config", "user.email", "t@t");
  git("config", "user.name", "t");
  git("add", "-A");
  git("commit", "-qm", "init");
  return {
    root, cd,
    ledger: join(cd, "research-ledger.json"),
    // coverage.mjs reports on STDERR, so both streams come back joined.
    run: (cmd) => {
      const p = spawnSync(process.execPath, [join(cd, "coverage.mjs"), cmd], { cwd: root, encoding: "utf8" });
      if (p.status !== 0) throw new Error(`coverage.mjs ${cmd} exited ${p.status}\n${p.stdout}\n${p.stderr}`);
      return `${p.stdout}${p.stderr}`;
    },
    results: (name, arr) => writeFileSync(join(cd, "results", name), JSON.stringify(arr)),
    cleanup: () => rmDir(root),
  };
}

// ===========================================================================
// DEFECT 1 — record() silently stripped every unknown field
// ===========================================================================

test("record preserves a provenance key planted on the LEDGER entry", () => {
  const r = makeRepo(40);
  writeFileSync(r.ledger, JSON.stringify({
    meta: { lastFullResearch: null, createdAt: "2020-01-01T00:00:00.000Z", schema: 1 },
    files: { "src/f1.txt": { hash: "deadbeef", researchedAt: "2020-01-01T00:00:00.000Z",
      score: 1, role: "r", description: "d", whatBreaks: "w", tier: "agent", evidenceLevel: "L2-PROBE" } },
  }, null, 2));
  // A result that does NOT re-state the key: the ledger side must carry it.
  r.results("batch-000.json", [{ path: "src/f1.txt", role: "r2", description: "d2", score: 2 }]);
  r.run("record");

  const e = readJson(r.ledger).files["src/f1.txt"];
  assert.equal(e.evidenceLevel, "L2-PROBE", "record() dropped a key it did not recognise");
  assert.equal(e.role, "r2", "the canonical fields did not update");
  r.cleanup();
});

test("record accepts a provenance key arriving on the RESULT", () => {
  const r = makeRepo(40);
  r.results("batch-000.json", [{ path: "src/f2.txt", role: "r", description: "d",
    score: 1, what_breaks_if_wrong: "w", evidenceLevel: "L2-PROBE" }]);
  r.run("record");

  const e = readJson(r.ledger).files["src/f2.txt"];
  assert.equal(e.evidenceLevel, "L2-PROBE");
  assert.equal(e.whatBreaks, "w", "the canonical alias was not normalised");
  assert.equal(Object.prototype.hasOwnProperty.call(e, "path"), false,
    "the fix regressed into a blind spread: transport key `path` leaked into the ledger");
  assert.equal(Object.prototype.hasOwnProperty.call(e, "what_breaks_if_wrong"), false,
    "the fix regressed into a blind spread: `what_breaks_if_wrong` leaked next to whatBreaks");
  r.cleanup();
});

// ===========================================================================
// DEFECT 2 — two real `record` processes, disjoint results
// ===========================================================================

test("two concurrent `coverage.mjs record` runs with disjoint results BOTH survive", () => {
  // TWO REAL PROCESSES, GENUINELY DISJOINT INPUTS, ONE SHARED LEDGER.
  //
  // Each writer gets its own repo copy and therefore its own results/ dir, and
  // both are pointed at one shared ledger with BP_RESEARCH_LEDGER. That is what
  // makes the inputs disjoint WITHOUT a mid-run file swap: an earlier version of
  // this test deleted writer A's batch file out of a shared results/ while A was
  // still reading it, which is a race of the test's own making. One shared
  // ledger path also means one shared lock, so the serialisation under test is
  // the real one.
  //
  // BOTH WRITERS ARE SPAWNED IN THE SAME TICK, deliberately, onto repos of the
  // same size. An earlier version instead held B back until A's lock file
  // appeared, on the theory that this pinned B's acquisition inside A's critical
  // section. It did the opposite, twice over. `record` scans the whole repo
  // BEFORE it touches the lock, so a B launched at the sight of A's lock reaches
  // that lock a full scan AFTER A released it; and what overlap remained was A's
  // runtime minus a constant launch cost (a fork plus a whole `node -e` spent
  // reading a clock), so it shrank to nothing on a fast box. That is how run
  // 33581989226 reddened main: A's record took 183ms there against 374-3543ms
  // here, the constant ate the window, and the anti-vacuity guard below
  // correctly refused a run in which A had already finished before B started.
  // Starting together makes the overlap structural instead of incidental: equal
  // work begun at the same instant puts the two critical sections within
  // milliseconds of each other, and no box is fast enough to escape that.
  const shared = join(mkdtempSync(join(tmpdir(), "bp-coverage-shared-")), "research-ledger.json");
  const a = makeRepo(1500), b = makeRepo(1500);
  const mk = (from, to, tag) => {
    const arr = [];
    for (let i = from; i <= to; i++) arr.push({ path: `src/f${i}.txt`, role: tag, description: tag, score: 1 });
    return arr;
  };
  a.results("batch-A.json", mk(1, 200, "procA"));
  b.results("batch-B.json", mk(201, 400, "procB"));

  // One runner process, so each writer's bracket is taken around the child spawn
  // itself rather than around a separate clock-reading process.
  const runner = join(dirname(shared), "both.mjs");
  writeFileSync(runner, [
    'import { spawn } from "node:child_process";',
    'import { writeFileSync } from "node:fs";',
    'const [aRoot, aCd, bRoot, bCd, ledger, out] = process.argv.slice(2);',
    'const env = { ...process.env, BP_RESEARCH_LEDGER: ledger };',
    'const go = (root, cd, tag) => new Promise((done) => {',
    '  const t0 = Date.now();',
    '  const p = spawn(process.execPath, [cd + "/coverage.mjs", "record"], { cwd: root, env, stdio: "ignore" });',
    '  let code = 1;',
'  p.on("exit", (c) => { code = c ?? 1; });',
'  // close, not exit: it fires only once the child has exited AND every',
'  // stdio handle it owns is released, so nothing of it is still writing',
'  // into the fixture repo when the test tears that repo down.',
'  p.on("close", () => done([tag, t0, Date.now(), code]));',
    '});',
    'const rows = await Promise.all([go(aRoot, aCd, "a"), go(bRoot, bCd, "b")]);',
    'for (const [tag, t0, t1, code] of rows) writeFileSync(`${out}/${tag}.txt`, `${t0} ${t1} ${code}`);',
  ].join("\n"));
  execFileSync(process.execPath, [runner, a.root, a.cd, b.root, b.cd, shared, dirname(shared)],
    { encoding: "utf8" });

  const [aStart, aEnd, aRc] = readFileSync(join(dirname(shared), "a.txt"), "utf8").trim().split(/\s+/);
  const [bStart, bEnd, bRc] = readFileSync(join(dirname(shared), "b.txt"), "utf8").trim().split(/\s+/);
  assert.equal(aRc, "0", "writer A failed");
  assert.equal(bRc, "0", "writer B failed");

  // Anti-vacuity: the two processes must have been alive at the same time. A box
  // that serialised them would otherwise go green while proving nothing at all
  // about concurrent writers.
  assert.ok(Number(bStart) < Number(aEnd) && Number(aStart) < Number(bEnd),
    `the two record runs did not overlap (A ${aStart}-${aEnd}, B ${bStart}-${bEnd}); ` +
    `this run proves nothing about concurrent writers`);

  const files = readJson(shared).files;
  const nA = Object.values(files).filter(e => e.description === "procA").length;
  const nB = Object.values(files).filter(e => e.description === "procB").length;
  assert.equal(nA, 200, `writer A lost ${200 - nA} of 200 entries`);
  assert.equal(nB, 200, `writer B lost ${200 - nB} of 200 entries`);
  assert.equal(existsSync(`${shared}.lock`), false, "the lock outlived both writers");
  a.cleanup(); b.cleanup();
  rmDir(dirname(shared));
});

// ===========================================================================
// prune and seed share the identical read-modify-write shape
// ===========================================================================

test("prune drops only orphans and preserves unknown keys on everything else", () => {
  const r = makeRepo(40);
  writeFileSync(r.ledger, JSON.stringify({
    meta: { lastFullResearch: null, createdAt: "2020-01-01T00:00:00.000Z", schema: 1, futureMeta: "keep" },
    files: {
      "src/f1.txt": { hash: "h", tier: "agent", evidenceLevel: "L2-PROBE" },
      "src/deleted.txt": { hash: "h", tier: "agent" },   // not on disk -> orphan
    },
  }, null, 2));
  const out = r.run("prune");

  const l = readJson(r.ledger);
  assert.match(out, /removed 1 deleted file/);
  assert.equal(existsSync(join(r.cd, "research-ledger.json.lock")), false, "prune left its lock behind");
  assert.equal(Object.prototype.hasOwnProperty.call(l.files, "src/deleted.txt"), false);
  assert.equal(l.files["src/f1.txt"].evidenceLevel, "L2-PROBE", "prune stripped a bystander's unknown key");
  assert.equal(l.meta.futureMeta, "keep");
  r.cleanup();
});

test("seed preserves unknown keys already on a ledger entry", () => {
  const r = makeRepo(40);
  mkdirSync(join(r.root, "tooling", "file-importance"), { recursive: true });
  writeFileSync(join(r.root, "tooling", "file-importance", "file-signals.json"),
    JSON.stringify({ signals: [{ path: "src/f1.txt", prior: 5, autoDescription: "auto d" }] }));
  writeFileSync(r.ledger, JSON.stringify({
    meta: { lastFullResearch: null, createdAt: "2020-01-01T00:00:00.000Z", schema: 1 },
    files: { "src/f1.txt": { hash: "old", tier: "auto", evidenceLevel: "L2-PROBE" } },
  }, null, 2));
  r.run("seed");

  const e = readJson(r.ledger).files["src/f1.txt"];
  assert.equal(e.evidenceLevel, "L2-PROBE", "seed rebuilt the entry and dropped an unknown key");
  assert.equal(e.score, 5, "seed did not apply the signal");
  assert.equal(e.description, "auto d");
  assert.equal(readJson(r.ledger).meta.seededFrom, "importance-run");
  r.cleanup();
});

// ===========================================================================
// scan — the "(read-only)" claim
// ===========================================================================

test("scan writes coverage-report.json, and the header no longer calls it read-only", () => {
  const r = makeRepo(40);
  // A LEDGER HAS TO EXIST FIRST, and that is a real change of premise, not a
  // workaround. scan now refuses (LEDGER_ABSENT) rather than reporting a flat
  // zero when no ledger is on the machine, so this test used to reach the
  // reporting path only because the absent-ledger case silently produced one.
  // An empty `record` creates the ledger without researching anything, which
  // keeps what this test is actually about — that scan emits the report, and
  // that the header no longer calls itself read-only — unchanged.
  r.run("record");
  r.run("scan");
  const report = join(r.cd, "coverage-report.json");
  assert.ok(existsSync(report), "scan stopped emitting the report four other tools read");
  // Still exactly 43: the ledger `record` just created is excluded from its own
  // coverage by config.json, which is what stops a committed ledger from
  // re-staling itself on every write.
  assert.equal(readJson(report).total, 43, "43 = 40 src + coverage.mjs + ledger-io.mjs + config.json");

  // The row's cheap-and-related clause: a command documented "(read-only)" that
  // writes is a false claim in the one file an agent reads to decide whether a
  // re-derivation is safe to re-execute. The write is kept (quality.mjs,
  // cody.mjs, status.mjs and report.mjs all consume the file, and grip's rerun
  // classifier names it as a known writer); the CLAIM is what was wrong.
  const header = readFileSync(join(SRC, "coverage.mjs"), "utf8").split("\n").slice(0, 30).join("\n");
  assert.ok(/coverage\.mjs scan/.test(header), "the usage block no longer documents scan");
  assert.equal(/scan\s+→[^\n]*read-only/.test(header), false,
    "scan is still documented '(read-only)' while writing coverage-report.json");
  assert.ok(/NOT read-only/.test(header), "the header does not say scan writes");
  r.cleanup();
});

test("scan does not touch the ledger", () => {
  const r = makeRepo(40);
  r.results("batch-000.json", [{ path: "src/f1.txt", role: "r", description: "d", score: 1 }]);
  r.run("record");
  const before = readFileSync(r.ledger, "utf8");
  r.run("scan");
  assert.equal(readFileSync(r.ledger, "utf8"), before, "scan mutated research state");
  r.cleanup();
});
