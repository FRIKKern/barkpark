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
    cleanup: () => rmSync(root, { recursive: true, force: true }),
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
  // B is launched only once A's lock file EXISTS, so B's acquisition attempt
  // provably lands inside A's critical section. That is the exact shape that
  // destroyed 200 entries before the fix; here it must cost a wait and nothing
  // else.
  const shared = join(mkdtempSync(join(tmpdir(), "bp-coverage-shared-")), "research-ledger.json");
  const a = makeRepo(1500), b = makeRepo(1500);
  const mk = (from, to, tag) => {
    const arr = [];
    for (let i = from; i <= to; i++) arr.push({ path: `src/f${i}.txt`, role: tag, description: tag, score: 1 });
    return arr;
  };
  a.results("batch-A.json", mk(1, 200, "procA"));
  b.results("batch-B.json", mk(201, 400, "procB"));

  const script = join(dirname(shared), "both.sh");
  writeFileSync(script, [
    'set -u',
    'NODE="$1"; AROOT="$2"; ACD="$3"; BROOT="$4"; BCD="$5"; LEDGER="$6"; OUT="$7"',
    'export BP_RESEARCH_LEDGER="$LEDGER"',
    'ms() { "$NODE" -e "process.stdout.write(String(Date.now()))"; }',
    'nap() { "$NODE" -e "Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,$1)"; }',
    '( a0=$(ms); cd "$AROOT" && "$NODE" "$ACD/coverage.mjs" record >/dev/null 2>&1; rc=$?; ' +
      'echo "$a0 $(ms) $rc" > "$OUT/a.txt" ) &',
    'PA=$!',
    '# launch B only once A holds the lock, so B collides with A by construction',
    'i=0',
    'while [ ! -e "$LEDGER.lock" ] && [ "$i" -lt 400 ]; do nap 5; i=$((i+1)); done',
    '( b0=$(ms); cd "$BROOT" && "$NODE" "$BCD/coverage.mjs" record >/dev/null 2>&1; rc=$?; ' +
      'echo "$b0 $(ms) $rc" > "$OUT/b.txt" ) &',
    'PB=$!',
    'wait $PA; wait $PB',
  ].join("\n"));
  execFileSync("sh", [script, process.execPath, a.root, a.cd, b.root, b.cd, shared, dirname(shared)],
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
  rmSync(dirname(shared), { recursive: true, force: true });
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
  r.run("scan");
  const report = join(r.cd, "coverage-report.json");
  assert.ok(existsSync(report), "scan stopped emitting the report four other tools read");
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
