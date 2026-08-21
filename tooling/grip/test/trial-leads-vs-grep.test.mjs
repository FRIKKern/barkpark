// trial-leads-vs-grep.test.mjs — the harness self-test.
//
// It proves the instrument, not a verdict: that `--store` is parsed, that leads
// output is captured by REDIRECT and parses (charter D92, the load-bearing one),
// that the frozen predictions and the retired-prior citation are intact, that
// the three off-band classes are reported SEPARATELY, that both granularities
// carry an honest-empty rate (D59), and that the report REFUSES to stamp a
// leads-wins/loses verdict (it marks itself PENDING-REVIEW). The decisive
// leads-vs-grep reading is a REVIEW action against the merged post-backfill
// store — never asserted here.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync,
  openSync, ftruncateSync, writeSync, closeSync, statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  parseArgs,
  PREDICTIONS,
  MEASURED_HERE,
  RETIRED_PRIOR,
  D59_GRANULARITY_RULE,
  SUBSYSTEM_QUERIES,
  FILEPATH_QUERIES,
  runLeadsJson,
  runGrep,
  runGrepCount,
  REPO_WIDE_EXCLUDES,
  countNewlinesInBuffer,
  countLinesInFile,
  MAX_STRING_LENGTH,
  scoreQuery,
  honestEmptyRate,
  buildReport,
  renderReport,
  SINGLETON_MAX,
  LARGE_BUCKET_MIN,
} from "../trial-leads-vs-grep.mjs";

// The bucket taxonomy is a PURE function of leads_on_subject — the same rule the
// harness applies at line ~354. Re-derived here so the self-test can assert
// COHERENCE at any store volume rather than pinning a specific outcome that the
// backfill (tgw5-corpus-backfill) flips the moment it lands in the same dir.
function expectedBucketClass(onSubject) {
  if (onSubject === 0) return "zero-coverage";
  if (onSubject <= SINGLETON_MAX) return "singleton";
  if (onSubject >= LARGE_BUCKET_MIN) return "large-bucket";
  return "scorable";
}

const HARNESS_SRC = readFileSync(fileURLToPath(new URL("../trial-leads-vs-grep.mjs", import.meta.url)), "utf8");
const REAL_STORE = fileURLToPath(new URL("../ledger", import.meta.url));

// A tiny fixture store: two run files with recipes under subsystems the frozen
// query list actually asks about, so buildReport has non-trivial coverage. Built
// in a temp dir — no new committed files (the slice ships exactly two files).
function makeFixtureStore() {
  const dir = mkdtempSync(join(tmpdir(), "grip-trial-fixture-"));
  const runA = {
    run_id: "grip-20260101T000000Z",
    recipes: [
      {
        subject: "internal/cli/cli.go",
        quantity: "grep:-c:func",
        rerun: "git show origin/main:internal/cli/cli.go | grep -c 'func '",
        derived_level: "L2",
        deps: ["internal/cli/cli.go"],
        observed_at: "2026-01-01T00:00:00Z",
      },
      {
        subject: "internal/cli/builtins.go",
        quantity: "wc:-l",
        rerun: "git show origin/main:internal/cli/builtins.go | wc -l",
        derived_level: "L2",
        deps: ["internal/cli/builtins.go"],
        observed_at: "2026-01-01T00:00:00Z",
      },
      {
        subject: "internal/cli/tasks_next_cmd.go",
        quantity: "grep:-c:func",
        rerun: "git show origin/main:internal/cli/tasks_next_cmd.go | grep -c 'func '",
        derived_level: "L2",
        deps: ["internal/cli/tasks_next_cmd.go"],
        observed_at: "2026-01-01T00:00:00Z",
      },
    ],
  };
  const runB = {
    run_id: "grip-20260101T000001Z",
    recipes: [
      {
        subject: "js/packages/core/package.json",
        quantity: "grep:-c:version",
        rerun: "git show origin/main:js/packages/core/package.json | grep -c 'version'",
        derived_level: "L2",
        deps: ["js/packages/core/package.json"],
        observed_at: "2026-01-01T00:00:01Z",
      },
    ],
  };
  writeFileSync(join(dir, "grip-20260101T000000Z-aaaa.json"), JSON.stringify(runA, null, 2));
  writeFileSync(join(dir, "grip-20260101T000001Z-bbbb.json"), JSON.stringify(runB, null, 2));
  return dir;
}

// ── the arg contract ─────────────────────────────────────────────────────────

test("parseArgs extracts --store and the flags", () => {
  assert.deepEqual(parseArgs(["--store", "some/dir"]), { store: "some/dir", json: false, selftest: false });
  assert.equal(parseArgs(["--store", "d", "--json"]).json, true);
  assert.equal(parseArgs(["--selftest"]).selftest, true);
  assert.equal(parseArgs([]).store, null);
});

// ── D92: capture by REDIRECT, never by pipe ──────────────────────────────────

test("D92: leads --json captured by redirect parses, and is NOT the 512-byte truncated pipe read", () => {
  // Against the real 62-row store, `leads internal --json` is thousands of bytes.
  // A piped capture truncates it near 512 bytes and JSON.parse throws on the
  // half-object; the redirect in runLeadsJson reads the whole document.
  const { result, bytes } = runLeadsJson("internal", REAL_STORE);
  assert.ok(Array.isArray(result.rows), "the redirected JSON parsed into an object with rows[]");
  assert.ok(bytes > 512, `captured ${bytes} bytes — a pipe would have truncated near 512`);
  // parsing did not throw = the document was complete
  assert.equal(typeof result.indexed_subjects, "number");
});

test("D92: the harness source captures leads via a file descriptor, not a pipe", () => {
  // The proof the discipline is STRUCTURAL, not incidental: captureToFile opens a
  // real file and hands the child its fd as stdout. No `spawnSync(... encoding)`
  // pipe capture of leads exists anywhere in the file.
  assert.ok(HARNESS_SRC.includes("openSync"), "captures through an open file descriptor");
  assert.ok(HARNESS_SRC.includes('stdio: ["ignore", fd, "ignore"]'), "child stdout is the fd, not a pipe");
});

// ── the frozen predictions W1-W7 ─────────────────────────────────────────────

test("W1-W7 are frozen and carry the paper's re-basings", () => {
  assert.deepEqual(PREDICTIONS.map((p) => p.id), ["W1", "W2", "W3", "W4", "W5", "W6", "W7"]);
  const byId = Object.fromEntries(PREDICTIONS.map((p) => [p.id, p.text]));
  assert.ok(byId.W1.includes("+167"), "W1 re-based on the measured +167");
  assert.ok(byId.W4.includes("internal/cli") && byId.W4.includes("20"), "W4 pinned to internal/cli=20");
  assert.ok(byId.W6.includes("FEWER THAN HALF"), "W6 headline is 'leads wins fewer than half'");
  // frozen: the array and its members are immutable
  assert.throws(() => { PREDICTIONS.push({ id: "W8" }); });
  assert.throws(() => { PREDICTIONS[0].id = "X"; });
});

test("the harness names which predictions it measures rather than implying all seven", () => {
  assert.deepEqual([...MEASURED_HERE], ["W4", "W5", "W6"]);
});

// ── D79 cited by number as retired; D59's three dead readings not re-quoted ───

test("D79 is cited BY NUMBER as retired, replaced by D80", () => {
  assert.equal(RETIRED_PRIOR.decision, "D79");
  assert.equal(RETIRED_PRIOR.retired_by, "D80");
  assert.ok(RETIRED_PRIOR.readings.some((r) => r.includes("29.2%")), "the retired 29.2% is named as retired");
  assert.ok(RETIRED_PRIOR.readings.some((r) => r.includes("3 of 20")), "the retired 3-of-20 is named as retired");
  assert.ok(RETIRED_PRIOR.why.includes("D80"), "states it was retired because D80 removed the haystack");
});

test("D59's three DEAD readings (mix test=35, api/lib=26, internal/cli=12) are NOT re-quoted", () => {
  // These are the readings D79 retired into the D23/D37/D52 class. The harness may
  // USE api/lib and internal/cli as query TERMS, but must never re-state the dead
  // recall numbers. Guard on the phrasings that would re-quote them.
  assert.ok(!HARNESS_SRC.includes("mix test"), "never names the retired mix-test reading");
  for (const dead of ["→ 35", "→ 26", "→ 12", "35 subjects", "26 subjects", "12 subjects"]) {
    assert.ok(!HARNESS_SRC.includes(dead), `does not re-quote D59 dead reading: ${dead}`);
  }
});

test("the query lists are frozen and pre-declared at both grains", () => {
  assert.ok(SUBSYSTEM_QUERIES.length >= 10, "a real subsystem sweep, not a token or two");
  assert.ok(FILEPATH_QUERIES.length >= 10, "a real file-path sweep for the second grain");
  // pre-declared from the router vocabulary, not eyeballed from the store
  assert.ok(SUBSYSTEM_QUERIES.some((q) => q.term === "internal/cli"));
  assert.ok(SUBSYSTEM_QUERIES.some((q) => q.term === "api/lib"));
  assert.throws(() => { SUBSYSTEM_QUERIES.push({ term: "x" }); }, "the list is frozen so it cannot be shopped after a run");
  assert.throws(() => { FILEPATH_QUERIES.push("x"); });
});

test("the granularity rule (D59) is carried and names both grains", () => {
  assert.ok(D59_GRANULARITY_RULE.includes("subsystem"));
  assert.ok(D59_GRANULARITY_RULE.includes("file-path"));
});

// ── grep helper handles the honest no-match / missing-dir cases ──────────────

test("runGrep treats no-match and missing-dir as empty, never as a throw", () => {
  const none = runGrep("zzz-no-such-token-anywhere-zzz", REAL_STORE);
  assert.equal(none.count, 0);
  const missing = runGrep("anything", join(tmpdir(), "grip-no-such-dir-zzzz"));
  assert.equal(missing.count, 0);
});

// ── the capture must not die on V8's string ceiling ──────────────────────────
//
// The repo-wide grep emits hundreds of megabytes on this tree. Reading that back
// with `readFileSync(path, "utf8")` throws ERR_STRING_TOO_LONG once it crosses
// MAX_STRING_LENGTH (0x1fffffe8) — which is exactly how this suite went red: the
// repo-wide arm failed on the READ, never on the measurement. These arms pin the
// byte-counting path that replaced it.

test("countNewlinesInBuffer counts newline bytes, honours the end bound, ignores everything else", () => {
  assert.equal(countNewlinesInBuffer(Buffer.from("")), 0);
  assert.equal(countNewlinesInBuffer(Buffer.from("a\nb\nc\n")), 3);
  assert.equal(countNewlinesInBuffer(Buffer.from("no newline here")), 0);
  // NUL bytes and CR are not newlines; only 0x0a is
  assert.equal(countNewlinesInBuffer(Buffer.from([0x00, 0x0d, 0x0a, 0x00])), 1);
  // the bound is respected — bytes past `end` are stale buffer content, not data
  const buf = Buffer.from("x\ny\nZZZZ\n\n\n");
  assert.equal(countNewlinesInBuffer(buf, 4), 2, "only the first 4 bytes are read");
});

test("countLinesInFile matches a whole-file string read, across chunk boundaries", () => {
  const dir = mkdtempSync(join(tmpdir(), "grip-count-"));
  try {
    const path = join(dir, "out");
    // 5000 grep-shaped lines — far more than one 64-byte chunk, so a counter that
    // loses the bytes straddling a chunk edge cannot pass.
    const text = Array.from({ length: 5000 }, (_, i) => `some/file.ex:${i}:a match`).join("\n") + "\n";
    writeFileSync(path, text);
    const viaString = readFileSync(path, "utf8").split("\n").filter((l) => l !== "").length;
    assert.equal(viaString, 5000);
    assert.equal(countLinesInFile(path), 5000, "default chunk size");
    assert.equal(countLinesInFile(path, { chunkSize: 64 }), 5000, "a chunk size that splits lines");
    assert.equal(countLinesInFile(path, { chunkSize: 1 }), 5000, "one byte at a time");

    // A FINAL PARTIAL CHUNK, chosen so the read buffer's unwritten tail holds
    // newline bytes left over from the previous chunk: 8 bytes read 3 + 3 + 2
    // leaves one stale "\n" past the end of the last read. A counter that walks
    // the whole buffer instead of stopping at the bytes actually read counts 5.
    const partial = join(dir, "partial");
    writeFileSync(partial, "a\nb\nc\nd\n");
    assert.equal(countLinesInFile(partial, { chunkSize: 3 }), 4, "stale bytes past the read length are not data");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("countLinesInFile survives a capture LARGER than V8's max string length", () => {
  // The fixture is sparse: ftruncate reserves the length without writing blocks,
  // so this costs ~4 KB of disk and no measurable time while still being a real
  // file past the ceiling. Seven newlines are written PAST the ceiling offset, so
  // a counter that quietly stops early returns the wrong number rather than a
  // lucky zero.
  const dir = mkdtempSync(join(tmpdir(), "grip-huge-"));
  try {
    const path = join(dir, "out");
    const fd = openSync(path, "w");
    try {
      ftruncateSync(fd, MAX_STRING_LENGTH + 1024);
      const tail = Buffer.from("\n".repeat(7));
      writeSync(fd, tail, 0, tail.length, MAX_STRING_LENGTH + 1024);
    } finally {
      closeSync(fd);
    }

    // The fixture must actually be past the ceiling — otherwise this arm proves
    // nothing and would keep passing after the fix regressed. Assert the ceiling
    // is real by watching the OLD read shape fail on this very file.
    assert.ok(statSync(path).size > MAX_STRING_LENGTH, "the fixture exceeds MAX_STRING_LENGTH");
    assert.throws(
      () => readFileSync(path, "utf8"),
      (err) => err.code === "ERR_STRING_TOO_LONG",
      "reading this capture as a string is exactly what used to throw",
    );

    // and the counting path returns the right number without ever building one
    assert.equal(countLinesInFile(path), 7);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("runGrepCount returns the same number as runGrep's count, and the same honest zeros", () => {
  // Same command, same definition of a line — the counted path is a swap, not a
  // new metric. Proved against the real store rather than a fixture.
  const read = runGrep("internal", REAL_STORE);
  const counted = runGrepCount("internal", REAL_STORE);
  assert.ok(read.count > 0, "the real store matches this term, so the comparison is not 0 === 0");
  assert.equal(counted.count, read.count);
  assert.equal(counted.status, read.status);
  // no-match and missing-dir stay honest zeros, never throws
  assert.equal(runGrepCount("zzz-no-such-token-anywhere-zzz", REAL_STORE).count, 0);
  assert.equal(runGrepCount("anything", join(tmpdir(), "grip-no-such-dir-zzzz")).count, 0);
});

// ── scoreQuery classifies and never averages the off-band classes ────────────

test("scoreQuery reports the two readings and a bucket class, never a single baked winner", () => {
  const dir = makeFixtureStore();
  try {
    const s = scoreQuery({ term: "internal/cli", prefix: "internal/cli" }, dir, { exact: false, repoWide: false });
    assert.equal(s.leads_on_subject, 3);
    assert.equal(s.precision, 1); // subject-default → all returned rows on-subject (D80)
    assert.equal(s.bucket_class, "scorable");
    // two independent readings exist; neither is presented as THE verdict
    assert.ok(["leads", "grep", "tie", "n/a"].includes(s.winner_first_command));
    assert.ok(["leads", "grep", "tie", "n/a"].includes(s.winner_full_scan));
    assert.equal(typeof s.leads_total_render_lines, "number");
    // repoWide off → the context grep is skipped and reported as null, never faked
    assert.equal(s.repo_wide_grep_lines, null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── the repo-wide arm: EXCLUSION is the claim, so exclusion is what is asserted ─
//
// The test this replaces was named "counts the tree but EXCLUDES vendored/build
// dirs" and asserted only `typeof === "number"` and `> 0`. Mutation-proven
// vacuous on its own headline: gutting REPO_WIDE_EXCLUDES to `[]` left all 21
// tests passing. It also scanned the whole working checkout, which on a tree
// carrying untracked agent state took ~11 minutes — paying eleven minutes for an
// assertion that the number was a number.
//
// Both problems have the same fix: scan a fixture whose contents are KNOWN, so
// the exact count is predictable and the exclusion becomes checkable.

// The probe term. It is NOT absent from the repo — this very file contains the
// literal — and that is exactly why every assertion below scans the FIXTURE it
// just built and never ".". A test that plants a sentinel and then searches the
// whole tree for it is counting its own source. (Proof that the distinction is
// live: making scoreQuery ignore repoWideDir and scan "." returns 1 — this file.)
const EXCLUDE_PROBE = "ZZQ_GRIP_REPOWIDE_EXCLUDE_PROBE_ZZQ";

// The exclusion set, pinned by SET-EQUALITY rather than a floor. Adding a
// directory to REPO_WIDE_EXCLUDES without extending this fixture reds here,
// which is the point: a new exclude that nothing plants a file in is an exclude
// nothing tests.
const EXPECTED_EXCLUDES = [".git", "node_modules", "_build", "deps", ".turbo", "dist", "build"];

// One file per excluded directory carrying ONE match, plus a kept directory
// carrying TWO. Correct answer: 2. Un-excluded answer: 9.
function makeExcludeFixture() {
  const root = mkdtempSync(join(tmpdir(), "grip-repowide-"));
  mkdirSync(join(root, "kept"), { recursive: true });
  writeFileSync(join(root, "kept", "counted.txt"), `${EXCLUDE_PROBE}\nnoise\n${EXCLUDE_PROBE}\n`);
  for (const d of EXPECTED_EXCLUDES) {
    mkdirSync(join(root, d), { recursive: true });
    writeFileSync(join(root, d, "vendored.txt"), `${EXCLUDE_PROBE}\n`);
  }
  return root;
}

test("REPO_WIDE_EXCLUDES is exactly the vendored/build set the fixture plants files in", () => {
  assert.deepEqual([...REPO_WIDE_EXCLUDES].sort(), [...EXPECTED_EXCLUDES].sort());
});

test("the repo-wide grep counts kept files and EXCLUDES every vendored/build dir", () => {
  const root = makeExcludeFixture();
  try {
    // the exclusion is real: 9 matches exist, 7 of them inside excluded dirs
    const excluded = runGrepCount(EXCLUDE_PROBE, root, { excludeDirs: REPO_WIDE_EXCLUDES });
    assert.equal(excluded.count, 2, "only the two matches under kept/ are counted");

    // the CONTROL that makes the number above mean something: without the
    // exclude list the same corpus yields 9, so a count of 2 is the excludes
    // working, not the fixture being empty or the probe being unfindable.
    const unfiltered = runGrepCount(EXCLUDE_PROBE, root, { excludeDirs: [] });
    assert.equal(unfiltered.count, 9, "all 9 planted matches are reachable when nothing is excluded");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("scoreQuery threads REPO_WIDE_EXCLUDES into its repo-wide count", () => {
  // proves the WIRING, not just the helper: scoreQuery must pass the exclude set
  // through, and must scan the directory it was handed.
  const dir = makeFixtureStore();
  const root = makeExcludeFixture();
  try {
    const s = scoreQuery({ term: EXCLUDE_PROBE, prefix: "internal/cli" }, dir,
      { exact: false, repoWide: true, repoWideDir: root });
    assert.equal(typeof s.repo_wide_grep_lines, "number");
    assert.equal(s.repo_wide_grep_lines, 2, "scoreQuery's repo-wide count honours the exclude set");
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(root, { recursive: true, force: true });
  }
});

test("a query with no on-subject rows is ZERO-COVERAGE, not a leads loss", () => {
  const dir = makeFixtureStore();
  try {
    const s = scoreQuery({ term: "cloud/lib", prefix: "cloud/lib" }, dir, { exact: false, repoWide: false });
    assert.equal(s.leads_on_subject, 0);
    assert.equal(s.bucket_class, "zero-coverage");
    assert.equal(s.winner_first_command, "n/a");
    assert.equal(s.winner_full_scan, "n/a");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("honestEmptyRate is a fraction over the queries, not an average of anything", () => {
  const r = honestEmptyRate([
    { leads_on_subject: 0 }, { leads_on_subject: 3 }, { leads_on_subject: 0 }, { leads_on_subject: 1 },
  ]);
  assert.deepEqual(r, { total: 4, empty: 2, rate: 0.5 });
  assert.deepEqual(honestEmptyRate([]), { total: 0, empty: 0, rate: null });
});

// ── buildReport over the fixture: structure, both grains, off-band separation ─

const FAST = {
  subsystemQueries: [
    { term: "internal/cli", prefix: "internal/cli" }, // 3 rows → scorable
    { term: "cloud/lib", prefix: "cloud/lib" },       // 0 rows → zero-coverage
    { term: "js/packages", prefix: "js/packages" },   // 1 row  → singleton
  ],
  filepathQueries: ["internal/cli/cli.go", "cloud/lib/x.ex"],
  repoWide: false,
};

test("buildReport separates singletons / >20-buckets / zero-coverage and reports BOTH grains", () => {
  const dir = makeFixtureStore();
  try {
    const rep = buildReport(dir, FAST);
    const sg = rep.subsystem_grain;
    // the three off-band classes are present as their OWN lists (never averaged)
    assert.ok(Array.isArray(sg.singletons));
    assert.ok(Array.isArray(sg.large_buckets));
    assert.ok(Array.isArray(sg.zero_coverage));
    // internal/cli has 3 rows in the fixture → scorable, not singleton
    assert.ok(!sg.singletons.includes("internal/cli"));
    // both granularities carry an honest-empty rate (D59)
    assert.equal(typeof sg.honest_empty.rate, "number");
    assert.equal(typeof rep.filepath_grain.honest_empty.rate, "number");
    assert.notEqual(sg.honest_empty, rep.filepath_grain.honest_empty); // distinct readings
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── the builder does NOT stamp the verdict ───────────────────────────────────

test("the report REFUSES a leads-wins/loses verdict — it is PENDING-REVIEW", () => {
  const dir = makeFixtureStore();
  try {
    const rep = buildReport(dir, FAST);
    assert.equal(rep.w6_head_to_head.verdict, "PENDING-REVIEW");
    assert.ok(rep.w6_head_to_head.verdict_note.includes("does NOT stamp"));
    assert.ok(rep.w6_head_to_head.verdict_note.includes("post-backfill"));
    // two tallies, both present, neither promoted to THE answer
    assert.ok(rep.w6_head_to_head.first_command);
    assert.ok(rep.w6_head_to_head.full_scan);
    // the render surfaces the pending verdict where a reader sees it
    const text = renderReport(rep);
    assert.ok(text.includes("PENDING-REVIEW"));
    assert.ok(text.includes("RETIRED PRIOR — D79"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── the self-test against the REAL 62-row store (task obligation) ────────────

test("buildReport self-tests against the REAL 62-row store and produces a coherent baseline", () => {
  // A subset of the frozen queries against the actual shipping store (the task's
  // "self-test against the 62-row store" obligation), kept small so the suite
  // stays fast; the FULL frozen run is the gate's own harness invocation.
  const rep = buildReport(REAL_STORE, {
    subsystemQueries: [
      { term: "internal/cli", prefix: "internal/cli" },
      { term: "api/lib", prefix: "api/lib" },
    ],
    filepathQueries: ["tooling/grip/ledger.mjs"],
    repoWide: false,
  });
  assert.equal(rep.store, REAL_STORE);
  // internal/cli is genuinely covered in the shipping store at any volume it has
  // carried (11 pre-backfill, 20+ post-backfill) — a real coverage reading.
  const cli = rep.subsystem_grain.queries.find((q) => q.term === "internal/cli");
  assert.ok(cli.leads_on_subject > 0, "internal/cli is covered in the shipping store");
  // COHERENCE, not a pinned outcome: the store is a LIVE, growing artifact —
  // tgw5-corpus-backfill lands +167 rows into this very dir, which flips api/lib
  // from zero-coverage (62-row store) to large-bucket. A self-test pinned to one
  // volume is a stale-figure trap (D23/D37/D52). So assert the classifier is
  // internally coherent — every query's bucket_class is exactly the pure function
  // of its own leads_on_subject — which holds at 62 rows and at 229.
  for (const q of rep.subsystem_grain.queries) {
    assert.equal(
      q.bucket_class,
      expectedBucketClass(q.leads_on_subject),
      `bucket_class for ${q.term} must be the pure function of leads_on_subject=${q.leads_on_subject}`,
    );
  }
  // W5 precision is measured and is a real fraction (D80's subject-default lifted
  // it well off D79's retired 29.2%); the value is reported, never a verdict.
  assert.ok(rep.precision.value === null || (rep.precision.value >= 0 && rep.precision.value <= 1));
  assert.equal(typeof rep.w4_internal_cli_rows, "number");
  // still pending — a builder run against the low-volume store is a self-test only
  assert.equal(rep.w6_head_to_head.verdict, "PENDING-REVIEW");
});
