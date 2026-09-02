// tooling/research-coverage — the COMMITTED ledger form, and the refusal.
//
//   node --test tooling/research-coverage/test/canonical-form.test.mjs
//
// THE DEFECT THESE GUARD. research-ledger.json was gitignored, so it existed on
// exactly one laptop. The identical command at the identical commit reported a
// real figure there and a flat zero on a clean worktree, because loadLedger
// found no file, returned an empty default, and classify() then honestly
// counted every file as never-researched. Nothing in the output separated
// "nothing researched yet" from "the instrument is not on this machine".
//
// Two things had to change and both are asserted here:
//
//   1. A COMMITTABLE FORM. Pretty JSON is ~9 lines per entry, so the diff
//      tracks the file count rather than the research activity and a full
//      record() rewrites every line. The canonical form is one line per entry,
//      sorted by path, with a key order fixed by the serialiser rather than by
//      object insertion order — so serialise(parse(x)) is x byte for byte, and
//      re-recording one file touches one line.
//
//   2. A REFUSAL. With no ledger at all, scan exits non-zero naming
//      LEDGER_ABSENT instead of printing a percentage. MUTATION-PROVEN: delete
//      the `refuseWithoutLedger("print a coverage percentage")` call from
//      coverage.mjs's scan arm and "scan REFUSES by name..." goes red with
//      `exit 0` and a `research coverage  0%` line — the original defect,
//      reproduced by the test that forbids it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, cpSync, rmSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  serializeCanonical, parseCanonical, readCanonicalLedger, writeCanonicalAtomic,
  emptyLedger, CANONICAL_ENTRY_KEYS,
} from "../ledger-io.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "..");                       // tooling/research-coverage
const tmp = () => mkdtempSync(join(tmpdir(), "bp-canonical-"));

const entry = (h, extra = {}) => ({
  hash: h, researchedAt: "2026-01-01T00:00:00.000Z",
  score: 3, role: "r", description: "d", whatBreaks: "w", tier: "agent", ...extra,
});

// The same throwaway-repo harness write-path.test.mjs uses: a real git repo
// carrying its own copy of the tool, so the commands under test are the real
// child processes rather than a re-implementation of them.
function makeRepo(nfiles = 20) {
  const root = mkdtempSync(join(tmpdir(), "bp-canonical-repo-"));
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
    canonical: join(cd, "research-ledger.jsonl"),
    cache: join(cd, "research-ledger.json"),
    // coverage.mjs reports on stderr; both streams come back joined, and the
    // status comes back too because a refusal is a non-zero exit.
    run: (cmd) => {
      const p = spawnSync(process.execPath, [join(cd, "coverage.mjs"), cmd], { cwd: root, encoding: "utf8" });
      return { status: p.status, out: `${p.stdout}${p.stderr}` };
    },
    mustRun: (cmd) => {
      const p = spawnSync(process.execPath, [join(cd, "coverage.mjs"), cmd], { cwd: root, encoding: "utf8" });
      if (p.status !== 0) throw new Error(`coverage.mjs ${cmd} exited ${p.status}\n${p.stdout}\n${p.stderr}`);
      return `${p.stdout}${p.stderr}`;
    },
    results: (name, arr) => writeFileSync(join(cd, "results", name), JSON.stringify(arr)),
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  };
}

// ===========================================================================
// 1 — the canonical form round-trips
// ===========================================================================

test("load -> write is byte-identical", () => {
  const dir = tmp(), p = join(dir, "research-ledger.jsonl");
  const ledger = {
    meta: { schema: 1, createdAt: "2026-01-01T00:00:00.000Z", lastFullResearch: null, seededFrom: "importance-run" },
    files: { "b.txt": entry("bbbb"), "a.txt": entry("aaaa"), "c/d.txt": entry("cccc") },
  };
  writeCanonicalAtomic(p, ledger);
  const first = readFileSync(p, "utf8");

  // The real round-trip: read the file back through the parser and re-serialise
  // it. A serialiser whose order came from object insertion order would drift
  // here the moment the parser rebuilt the object in a different order.
  const second = serializeCanonical(parseCanonical(first));
  assert.equal(second, first, "serialise(parse(x)) must be x byte for byte");

  // And once more through the on-disk path, which is what record() actually does.
  writeCanonicalAtomic(p, readCanonicalLedger(p));
  assert.equal(readFileSync(p, "utf8"), first, "a write of what was just read changed the file");
  rmSync(dir, { recursive: true, force: true });
});

test("a scrambled key and entry order serialises to the SAME bytes", () => {
  // Without this the round-trip test above could pass on a serialiser that
  // merely preserves whatever order it was handed — which is exactly the
  // property that makes a diff non-local.
  const a = { meta: { schema: 1, createdAt: "x", lastFullResearch: null },
              files: { "a.txt": entry("aaaa"), "b.txt": entry("bbbb") } };
  const shuffled = { tier: "agent", whatBreaks: "w", description: "d", role: "r",
                     score: 3, researchedAt: "2026-01-01T00:00:00.000Z", hash: "bbbb" };
  const b = { meta: { lastFullResearch: null, createdAt: "x", schema: 1 },
              files: { "b.txt": shuffled, "a.txt": entry("aaaa") } };
  assert.equal(serializeCanonical(b), serializeCanonical(a));
});

test("one line per entry, sorted by path, `path` first", () => {
  const ledger = { meta: { schema: 1 },
    files: { "z.txt": entry("z"), "a.txt": entry("a"), "m/n.txt": entry("m") } };
  const lines = serializeCanonical(ledger).split("\n").filter(Boolean);

  assert.equal(lines.length, 4, "1 header + 1 line per entry");
  assert.equal(JSON.parse(lines[0]).path, undefined, "the header must carry no `path` — it is the discriminator");
  assert.ok(JSON.parse(lines[0]).meta, "the header must carry meta");

  const paths = lines.slice(1).map((l) => JSON.parse(l).path);
  assert.deepEqual(paths, ["a.txt", "m/n.txt", "z.txt"], "entries must be sorted by path");
  for (const l of lines.slice(1)) {
    assert.equal(Object.keys(JSON.parse(l))[0], "path", "`path` must lead every entry line");
    assert.equal(l.includes("\n"), false, "an entry must occupy exactly one line");
  }
  assert.ok(serializeCanonical(ledger).endsWith("\n"), "the file must end with a newline");
});

test("an unknown key survives the canonical round-trip, after the canonical seven", () => {
  const ledger = { meta: { schema: 1, futureMetaKey: 7 }, topLevelFuture: { deep: 1 },
    files: { "a.txt": entry("aaaa", { evidenceLevel: "L2-PROBE", aFutureKey: { deep: 2 } }) } };
  const back = parseCanonical(serializeCanonical(ledger));
  assert.equal(back.files["a.txt"].evidenceLevel, "L2-PROBE");
  assert.deepEqual(back.files["a.txt"].aFutureKey, { deep: 2 });
  assert.equal(back.meta.futureMetaKey, 7, "an unknown meta key must survive");
  assert.deepEqual(back.topLevelFuture, { deep: 1 }, "an unknown top-level key must survive");

  const keys = Object.keys(JSON.parse(serializeCanonical(ledger).split("\n")[1]));
  assert.deepEqual(keys, ["path", ...CANONICAL_ENTRY_KEYS, "aFutureKey", "evidenceLevel"],
    "canonical fields keep their declared order; preserved unknowns follow, sorted");
});

test("a line that is not the header and carries no path is refused, not silently dropped", () => {
  assert.throws(() => parseCanonical('{"meta":{}}\n{"hash":"h"}\n'), /carries no string `path`/);
  assert.throws(() => parseCanonical('{"path":"a.txt","hash":"h"}\n'), /first line must be the header/);
  assert.deepEqual(parseCanonical("").files, emptyLedger().files);
});

// ===========================================================================
// 2 — a real record writes the committed form, and the diff is line-local
// ===========================================================================

test("record writes the canonical ledger and mirrors the derived cache", () => {
  const r = makeRepo(20);
  r.results("batch-000.json", [{ path: "src/f1.txt", role: "r", description: "d", score: 1 }]);
  r.mustRun("record");

  assert.ok(existsSync(r.canonical), "record did not write the committed ledger");
  assert.ok(existsSync(r.cache), "record did not refresh the derived pretty cache");
  const canon = readCanonicalLedger(r.canonical);
  const cache = JSON.parse(readFileSync(r.cache, "utf8"));
  assert.deepEqual(canon.files, cache.files, "the committed form and its cache disagree");
  assert.equal(canon.files["src/f1.txt"].role, "r");
  r.cleanup();
});

test("re-recording ONE file rewrites one line, not the whole ledger", () => {
  // The storage half of the decision: churn has to be proportional to research
  // activity, not to the file count. Pretty JSON spends ~9 lines per entry, so
  // this same edit rewrote a nine-line block there and a full record rewrote
  // every line in the file.
  const r = makeRepo(20);
  const all = [];
  for (let i = 1; i <= 20; i++) all.push({ path: `src/f${i}.txt`, role: "r", description: "d", score: 1 });
  r.results("batch-000.json", all);
  r.mustRun("record");
  const before = readFileSync(r.canonical, "utf8").split("\n");

  r.results("batch-000.json", [{ path: "src/f7.txt", role: "CHANGED", description: "d", score: 9 }]);
  r.mustRun("record");
  const after = readFileSync(r.canonical, "utf8").split("\n");

  assert.equal(after.length, before.length, "the line count moved for a same-set re-record");
  const moved = before.map((l, i) => (l === after[i] ? null : i)).filter((i) => i !== null);
  // The header line always moves: it carries meta.rev and meta.updatedAt. Every
  // OTHER moved line must be the one entry that was re-recorded.
  // Derived, not hardcoded: entries are sorted by path, and "src/f7.txt" does
  // not sit at index 7 under a string sort (f1, f10..f19, f2, f20, f3..f9).
  const expected = 1 + before.slice(1).findIndex((l) => JSON.parse(l).path === "src/f7.txt");
  assert.deepEqual(moved, [0, expected],
    `expected the header plus src/f7.txt's line only, got line(s) ${moved.join(",")}`);
  assert.equal(JSON.parse(after[expected]).path, "src/f7.txt");
  assert.equal(JSON.parse(after[expected]).role, "CHANGED");
  r.cleanup();
});

test("a checkout holding ONLY the old pretty cache reads the same ledger", () => {
  // The migration path. A laptop that still has just the gitignored JSON must
  // keep working, and must agree with the committed form built from it.
  const r = makeRepo(20);
  r.results("batch-000.json", [{ path: "src/f1.txt", role: "r", description: "d", score: 1 }]);
  r.mustRun("record");

  // coverage-report.json is itself an untracked file in this throwaway repo, so
  // the FIRST scan enumerates a repo the SECOND one no longer sees. Clear it
  // before each run, or the comparison measures the harness instead of the
  // fallback.
  const report = join(r.cd, "coverage-report.json");
  const scan = () => { rmSync(report, { force: true }); return r.mustRun("scan"); };

  const fromBoth = scan();
  rmSync(r.canonical);
  const fromCacheOnly = scan();
  assert.equal(fromCacheOnly, fromBoth, "the cache fallback disagreed with the committed form");
  r.cleanup();
});

// ===========================================================================
// 3 — an absent ledger REFUSES rather than reporting zero
// ===========================================================================

test("scan REFUSES by name when no ledger exists, instead of reporting zero", () => {
  const r = makeRepo(20);
  assert.equal(existsSync(r.canonical), false);
  assert.equal(existsSync(r.cache), false);

  const { status, out } = r.run("scan");
  assert.notEqual(status, 0, "scan exited 0 with no ledger — a clean checkout gets a fake measurement");
  assert.equal(status, 3, "the refusal must use its own exit code, so a caller can branch on it");
  assert.match(out, /LEDGER_ABSENT/, "the refusal must be named, not a bare stack trace");
  assert.equal(/research coverage\s+[\d.]+%/.test(out), false,
    "a percentage was printed against a ledger that is not there");
  assert.match(out, /coverage\.mjs seed/, "the refusal must name the command that re-derives the ledger");

  // And it must not leave a report behind for the four tools that read one.
  assert.equal(existsSync(join(r.cd, "coverage-report.json")), false,
    "the refusal still wrote a coverage report, so a stale reader would see the fake zero anyway");
  r.cleanup();
});

test("batches REFUSES too, rather than fanning the whole repo out to agents", () => {
  const r = makeRepo(20);
  const { status, out } = r.run("batches");
  assert.equal(status, 3);
  assert.match(out, /LEDGER_ABSENT/);
  assert.equal(existsSync(join(r.cd, "batches")), false, "a missing ledger queued research anyway");
  r.cleanup();
});

test("an EMPTY ledger is still a real zero — only an ABSENT one refuses", () => {
  // The distinction the refusal exists to make. Without this the fix could have
  // been "refuse whenever coverage is low", which would hide a true zero.
  const r = makeRepo(20);
  writeCanonicalAtomic(r.canonical, emptyLedger());
  const { status, out } = r.run("scan");
  assert.equal(status, 0, "a present-but-empty ledger must still report");
  assert.match(out, /research coverage\s+0%/, "an empty ledger is a measured zero and must print as one");
  r.cleanup();
});

// ===========================================================================
// 4 — no coverage NUMBER is stored as a durable fact
// ===========================================================================

test("nothing tracked under research-coverage carries a coverage percentage", () => {
  // The corpus rule: the only durable fact about coverage is the command that
  // re-derives it. coverage-report.json holds the number and is gitignored;
  // this asserts no COMMITTED file in the directory states one.
  // From the repo ROOT, not from SRC: `git ls-files <pathspec>` resolves the
  // pathspec against the cwd, so running this from inside the directory it names
  // matches nothing and the census would pass by finding zero files.
  const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: SRC, encoding: "utf8" }).trim();
  const tracked = execFileSync("git", ["ls-files", "tooling/research-coverage/"],
    { cwd: root, encoding: "utf8" }).split("\n").filter(Boolean);
  assert.ok(tracked.length >= 6, `expected the tracked set, got ${tracked.length} file(s)`);
  assert.ok(tracked.includes("tooling/research-coverage/research-ledger.jsonl"),
    "the canonical ledger is not tracked — the whole point is that a clean checkout has it");
  assert.equal(tracked.includes("tooling/research-coverage/research-ledger.json"), false,
    "the derived pretty cache must stay gitignored");
  assert.equal(tracked.includes("tooling/research-coverage/coverage-report.json"), false,
    "coverage-report.json holds the percentage and must stay gitignored");

  const found = [];
  for (const f of tracked) {
    if (f.endsWith("research-ledger.jsonl")) continue;   // data: hashes and scores, no figure
    if (f.endsWith(".test.mjs")) continue;               // asserts ABOUT output, stores nothing
    const text = readFileSync(join(root, f), "utf8");
    // A coverage claim reads as a number immediately followed by a percent sign.
    for (const m of text.matchAll(/\b\d+(?:\.\d+)?\s?%/g)) found.push(`${f}: ${m[0]}`);
  }
  // PINNED EXACTLY, not an allowlist that can grow. Every surviving occurrence
  // is coverage.mjs's own completion message and the usage lines describing it —
  // a format string printed only when the LIVE computation says so, never a
  // recorded figure. A new percentage anywhere in the tracked set reds this.
  assert.deepEqual(found.sort(), [
    "tooling/research-coverage/coverage.mjs: 100%",
    "tooling/research-coverage/coverage.mjs: 100%",
    "tooling/research-coverage/coverage.mjs: 100%",
  ], `the tracked set's percentage census moved: ${found.join(" | ")}`);
});

test("the committed ledger stores no percentage either — hashes, not figures", () => {
  const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: SRC, encoding: "utf8" }).trim();
  const p = join(root, "tooling", "research-coverage", "research-ledger.jsonl");
  const ledger = readCanonicalLedger(p);
  const n = Object.keys(ledger.files).length;
  assert.ok(n > 0, "the committed ledger is empty — a clean checkout would learn nothing from it");
  assert.equal(ledger.meta.pct, undefined, "a coverage percentage was persisted into the ledger meta");
  assert.equal(ledger.meta.covered, undefined, "a covered count was persisted into the ledger meta");
  for (const [path, e] of Object.entries(ledger.files)) {
    assert.equal(typeof e.hash, "string", `${path} has no content hash, so it can never be re-checked`);
  }
});
