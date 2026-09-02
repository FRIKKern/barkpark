#!/usr/bin/env node
// trial-leads-vs-grep.mjs — the COMMITTED, re-runnable head-to-head between the
// grip `leads` index and the SCOPED grep an agent types, over ONE store handed
// in by `--store <dir>`.
//
//   node tooling/grip/trial-leads-vs-grep.mjs --store <ledger dir> [--json]
//
// ── WHY THIS FILE EXISTS, AND WHY IT IS COMMITTED (charter D23/D37/D52) ───────
//
// The wave-6 wish was two halves: "fix leads' precision, THEN measure whether
// leads beats grep." Round 1 fixed it (D80 shipped the subject-default) and
// never measured it. D79 measured the head-to-head ONCE — precision 29.2%,
// leads 8-of-10 vs the scoped grep, 3-of-20 corrected for precision — but every
// one of those numbers was taken against the pre-D80 haystack that hayed
// `subject + "\0" + rerun`. D80 REMOVED that haystack: the command text is now
// opt-in behind `--cmd`, so the precision denominator moved under the whole
// comparison. Quoting D79's 3-of-20 after D80 shipped is exactly the
// stale-figure class the charter retired three times over (D23's 676/24%,
// D37's entropy 1.118, D52's 26-of-31). So D79 is CITED BY NUMBER AS RETIRED
// (see RETIRED_PRIOR below) and re-derived here by an instrument anyone can run.
//
// ── ONE INSTRUMENT, ONE VARIABLE: `--store` (D23 discipline) ─────────────────
//
// The same binary measures the PRE-BACKFILL store (62 rows at e8bbba5919,
// 2026-07-21) and the post-backfill store. The ONLY input that changes between
// those two runs is the directory `--store`
// names — the query list, the grep target, the metric, and the predictions are
// all frozen in this file. So a delta between the two runs is attributable to
// VOLUME, never to whoever ran it or to a term list assembled after seeing the
// numbers. A term list shopped for a favourable reading is the failure this
// epic exists to abolish; the list below is committed BEFORE any decisive run.
//
// ── THE COMPETITOR IS THE SCOPED GREP, NOT A REPO-WIDE ONE (D79's framing) ───
//
// D79 drew the line that matters: against a repo-wide `grep -rn <term> .` leads
// won 10 of 10, but against the SCOPED grep an agent types once it knows where
// to look it won 8 of 10 with one outright loss. In the ledger's own domain the
// SCOPED grep is `grep -rIn <term> <store dir>` and the REPO-WIDE grep is
// `grep -rIn <term> .` — "scoped" means scoped to the store the recipe actually
// lives in, versus the whole tree. The store IS `--store`, so the scoped grep
// grows WITH volume exactly as leads does: this is the fair test of whether
// leads' index advantage SURVIVES 4x volume, and it keeps volume the sole
// variable. Both grep readings are reported per query and never conflated —
// D79's own two readings disagreed precisely for want of this distinction.
//
// The metric is lines-to-answer, and it is SYMMETRIC: for both leads and the
// scoped grep it is the 1-based line index of the first output line that hands
// the reader a re-runnable command (leads' first on-subject `$` line; grep's
// first `"rerun"`-bearing match line). leads pairs subject→rerun and sorts
// deterministically; grep returns unpaired JSON fragments in file order — the
// gap between those two is the whole thing under test. Both scan the SAME store,
// so a delta is volume, not instrument.
//
// ── CAPTURE BY REDIRECT, NEVER BY PIPE (charter D92) ─────────────────────────
//
// Measured on this tree: `leads internal --dir <store> --json` is 512 bytes
// through a pipe and 6558 bytes redirected to a file — leads' main() can exit
// before a piped stdout buffer flushes, so a piped capture reads a TRUNCATED
// document and `JSON.parse` throws on a half-object. Every capture here goes
// through `captureToFile`, which hands the child an open file DESCRIPTOR as its
// stdout and reads the file back after the process has exited. The test proves
// the redirected JSON parses. (S3 also fixes the flush in ledger.mjs; this
// harness does not DEPEND on that fix having merged — redirecting is correct
// against any leads, flushed or not.)
//
// ── THE BUILDER DOES NOT STAMP THE VERDICT (task acceptance, D40) ────────────
//
// Volume must precede the trial: the decisive reading is against the MERGED
// post-backfill store, which does not exist until S1 lands on origin/main. So
// this harness SELF-TESTS against a fixture and against whatever store `--store`
// names — it quotes no volume of its own, because the one its first draft
// quoted went stale sixteen seconds before it merged: the +167-row backfill
// landed at 87221bfa55 (2026-07-21 22:13:01 +0200) and this file at 50ee37bcbe
// (22:13:17), so "the current 62-row store" described a store that had already
// ceased to exist on main. It pre-registers W1-W7, but its report marks the
// leads-wins/loses verdict PENDING-REVIEW. A Review action re-runs it on the
// integrated tree and writes
// the closing verdict from THAT run. A builder stamping the verdict here would
// be measuring the old, low-volume store — a number that describes nothing that
// ships (D40's "proven by content on origin/main").
//
// node: builtins only. It spawns `node ledger.mjs leads …` and `grep`; it reads
// no module state and imports nothing from the grip layer, so it cannot inherit
// a fold bug into its own headline.

import { spawnSync } from "node:child_process";
import { openSync, closeSync, readSync, readFileSync, rmSync, mkdtempSync, statSync } from "node:fs";
import { constants as bufferConstants } from "node:buffer";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const LEDGER_CLI = fileURLToPath(new URL("./ledger.mjs", import.meta.url));

// ── the retired prior, cited by number so it can never be quoted as live ─────
//
// D79's three headline readings, RETIRED and named. They were measured against
// the pre-D80 concatenated `subject + "\0" + rerun` haystack that D80 removed,
// so they describe a leads that no longer ships. This block exists so a reader
// meets the retirement, not the number.
export const RETIRED_PRIOR = Object.freeze({
  decision: "D79",
  retired_by: "D80",
  readings: Object.freeze([
    "precision 29.2% (92 of 130 returned rows were not under the queried subsystem)",
    "leads 8 of 10 vs the SCOPED grep, with one outright loss",
    "3 of 20 corrected for precision",
  ]),
  why:
    "measured against the pre-D80 subject+\\0+rerun haystack that no longer ships (D80 made the "
    + "command text opt-in behind --cmd), so the precision denominator moved under the whole "
    + "comparison; quoting them after D80 is the D23/D37/D52 stale-figure class.",
});

// D59 established that an honest-empty rate is meaningless without a stated
// query granularity, and that its own three decisive readings do NOT reproduce
// on the shipping store (D79 retired them into the D23 class). This harness
// therefore reports BOTH granularities and re-derives its own numbers; it never
// re-quotes those three dead readings. The rule is carried as data so the
// selftest can assert the harness obeys its own discipline.
export const D59_GRANULARITY_RULE =
  "an honest-empty rate is meaningless without a stated query granularity — reported at BOTH "
  + "subsystem grain and file-path grain, and published whichever way it falls (D21).";

// ── the pre-declared predictions W1-W7 (committed BEFORE any decisive run) ────
//
// Verbatim from the wave-8 paper's pre-declared-predictions callout, carrying
// the two re-basings the paper records: W1 re-based on the measured +167 (not
// the survey's 120-170 guess), and W4 pinned to internal/cli=20. A prediction
// edited after seeing the result is shopping for a number; freezing them in the
// committed harness is how the shopping is made impossible.
export const PREDICTIONS = Object.freeze([
  Object.freeze({
    id: "W1",
    text:
      "the backfill mints +167 rows (re-based on the measured backfill, not the survey's 120-170 "
      + "guess); the post-backfill store lands ~229 total.",
  }),
  Object.freeze({
    id: "W2",
    text: "at EXACT-key grain the union singleton share is above 80%.",
  }),
  Object.freeze({
    id: "W3",
    text:
      "at rollup grain under the pinned all-ancestor-prefix match-count rule, keys in the 3-20 "
      + "band go from 15 to at least 30.",
  }),
  Object.freeze({
    id: "W4",
    text: "`leads internal/cli` returns 20 rows on the post-backfill store (pinned), against 11 today.",
  }),
  Object.freeze({
    id: "W5",
    text:
      "post-fix precision (fraction of returned rows genuinely under the queried subsystem) is "
      + "above 80%, against D79's retired 29.2% and post-#5441's 74.4%.",
  }),
  Object.freeze({
    id: "W6",
    text:
      "THE HEADLINE, and the one we expect to be uncomfortable: on lines-to-answer against a SCOPED "
      + "grep, over the pre-declared subsystem queries on the post-backfill store, leads wins FEWER "
      + "THAN HALF. If it lands the other way, say so; if as predicted, record what leads is for.",
  }),
  Object.freeze({
    id: "W7",
    text:
      "THE SAFETY VERDICT: after S6, a marker probe through `node tooling/grip/cli.mjs <facts.json>` "
      + "with no flags REFUSES to materialise the marker (today it writes a 358-byte file).",
  }),
]);

// This harness measures W5 and W6 directly (precision + lines-to-answer) and
// reports the inputs to W4 (the internal/cli bucket size). W1/W2/W3 are volume
// and rollup predictions owned by other slices' instruments; W7 is the safety
// probe. Named so the report states its own coverage rather than implying it
// settles all seven.
export const MEASURED_HERE = Object.freeze(["W4", "W5", "W6"]);

// ── the pre-declared subsystem query list, and where it came from ────────────
//
// PROVENANCE (this is the D59 obligation to state where the terms came from):
// the terms are the repo's own top-level subsystem boundaries as named in the
// router table of CLAUDE.md and the charter — NOT tokens eyeballed out of the
// store. `prefix` is the on-subject test (a returned row is on-subject when its
// subject starts with `prefix`). The scoped grep targets the `--store` dir (see
// the header) so it grows with volume exactly as leads does; `term` is what the
// agent hands to both leads and grep.
export const SUBSYSTEM_QUERIES = Object.freeze([
  Object.freeze({ term: "internal/cli", prefix: "internal/cli" }),
  Object.freeze({ term: "api/lib", prefix: "api/lib" }),
  Object.freeze({ term: "js/packages", prefix: "js/packages" }),
  Object.freeze({ term: "cloud/lib", prefix: "cloud/lib" }),
  Object.freeze({ term: ".github/workflows", prefix: ".github/workflows" }),
  Object.freeze({ term: "docs/ops", prefix: "docs/ops" }),
  Object.freeze({ term: "tooling/grip", prefix: "tooling/grip" }),
  Object.freeze({ term: "scripts/pds", prefix: "scripts/pds" }),
  Object.freeze({ term: "web/", prefix: "web/" }),
  Object.freeze({ term: "templates", prefix: "templates" }),
  Object.freeze({ term: ".claude/workflows", prefix: ".claude/workflows" }),
  Object.freeze({ term: "internal/pdrender", prefix: "internal/pdrender" }),
]);

// ── the pre-declared FILE-PATH query list (D59's second granularity) ──────────
//
// PROVENANCE: exact tracked file paths, one per subsystem above, chosen
// INDEPENDENTLY of the store (they are landmark files of the repo, not rows
// pulled from the ledger). The on-subject test at this grain is EXACT-path
// equality: a returned row counts only if its subject IS the path. This is the
// grain D59's 75% honest-empty came from — a store-coverage reading, reported
// beside the subsystem grain and never averaged into it.
export const FILEPATH_QUERIES = Object.freeze([
  "internal/cli/cli.go",
  "api/lib/barkpark/application.ex",
  "js/packages/core/package.json",
  "cloud/lib/barkpark_cloud/notifications.ex",
  ".github/workflows/ci.yml",
  "docs/ops/PROD_OPS.md",
  "tooling/grip/ledger.mjs",
  "scripts/pds-crown-launch.sh",
  "web/package.json",
  "templates/astro-search-starter/package.json",
  ".claude/workflows/bp-epic-cycle.workflow.js",
  "internal/pdrender/testdata",
]);

// The bucket bands, named once (D46's measured 3-20 advantage band). A key
// outside the band is not a leads-vs-grep contest — it is reported in its own
// list and never averaged into the head-to-head.
export const SINGLETON_MAX = 1; // a 1-row key: nothing to index, grep ties trivially
export const LARGE_BUCKET_MIN = 21; // > 20 rows: a dump, leads' precision is the story not its win

// ── the V8 string ceiling, named once ────────────────────────────────────────
//
// A JavaScript string cannot exceed `buffer.constants.MAX_STRING_LENGTH`
// (0x1fffffe8 = 536,870,888 on 64-bit V8). `readFileSync(path, "utf8")` on a
// larger file throws ERR_STRING_TOO_LONG BEFORE the caller sees a single byte.
// This is not a hypothetical: a repo-wide `grep -rIn` here emits HUNDREDS of
// megabytes — a handful of multi-megabyte single-line JSON files supply most of
// the bytes off comparatively few matching lines, so the byte total tracks the
// working tree's contents, not its match count. On a working checkout carrying
// agent/session state it crossed the ceiling and took the repo-wide arm of
// scoreQuery down with it. Growth, not a code change, moved it past.
//
// The rule that follows: a capture whose SIZE is unbounded is never read as a
// string. It is either consumed as bytes (`captureLineCountToFile` below) or,
// where the body is genuinely needed, read as a string behind a size guard that
// fails with a message naming this ceiling instead of an opaque V8 error.
export const MAX_STRING_LENGTH = bufferConstants.MAX_STRING_LENGTH;

// Count newline BYTES in the first `end` bytes of a buffer. Pure, exported, and
// the single place the line arithmetic lives — so the guard that proves this
// path survives an over-ceiling capture can drive it directly on a synthetic
// buffer instead of manufacturing half a gigabyte of grep output.
export function countNewlinesInBuffer(buf, end = buf.length) {
  let n = 0;
  for (let i = 0; i < end; i += 1) if (buf[i] === 0x0a) n += 1;
  return n;
}

// Count the lines of a file WITHOUT materialising it as a string: a fixed-size
// buffer is refilled until EOF, so peak memory is `chunkSize`, not file size.
// For `grep -n` output — every line non-empty and newline-terminated — the
// newline count IS the line count, which is exactly what `out.split("\n")
// .filter((l) => l !== "").length` used to compute out of a whole-file string.
export function countLinesInFile(path, { chunkSize = 1 << 20 } = {}) {
  const fd = openSync(path, "r");
  const buf = Buffer.allocUnsafe(chunkSize);
  let lines = 0;
  try {
    for (;;) {
      const n = readSync(fd, buf, 0, chunkSize, null);
      if (n === 0) break;
      lines += countNewlinesInBuffer(buf, n);
    }
  } finally {
    closeSync(fd);
  }
  return lines;
}

// ── the D92-critical capture: a child stdout redirected to a real file ────────
//
// The child writes straight to an open descriptor, so there is no pipe buffer to
// truncate and no flush race. Returns the full captured text plus the child's
// status, and always cleans up its temp file.
//
// The redirect makes the capture UNBOUNDED, which is the point — and the reason
// the string read is guarded. A caller that only needs a line count must use
// `captureLineCountToFile`, which never builds the string at all.
function captureToFile(cmd, args, { cwd } = {}) {
  return withCaptureFile(cmd, args, { cwd }, (outPath) => {
    const { size } = statSync(outPath);
    if (size > MAX_STRING_LENGTH) {
      throw new Error(
        `capture of \`${cmd}\` is ${size} bytes, past V8's ${MAX_STRING_LENGTH}-byte string ceiling — `
        + "read it as bytes (see countLinesInFile) rather than as a string",
      );
    }
    return readFileSync(outPath, "utf8");
  });
}

// The same D92 redirect, but the capture is consumed as BYTES and only a line
// count comes back. Size-independent: a 400 MB or a 4 GB capture costs one
// 1 MiB buffer and never touches the string ceiling.
function captureLineCountToFile(cmd, args, { cwd } = {}) {
  const { out: lines, status, error } = withCaptureFile(cmd, args, { cwd }, countLinesInFile);
  return { lines, status, error };
}

// Spawn with stdout redirected to a temp file, hand the closed file to `consume`,
// and always clean up. The `stdio: ["ignore", fd, "ignore"]` shape is D92 itself:
// the child's stdout IS the descriptor, never a pipe.
function withCaptureFile(cmd, args, { cwd }, consume) {
  const dir = mkdtempSync(join(tmpdir(), "grip-trial-"));
  const outPath = join(dir, "out");
  const fd = openSync(outPath, "w");
  let status = null;
  let error = null;
  try {
    const res = spawnSync(cmd, args, { stdio: ["ignore", fd, "ignore"], cwd });
    status = res.status;
    error = res.error ?? null;
  } finally {
    closeSync(fd);
  }
  try {
    return { out: consume(outPath), status, error };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Run `leads <term> --dir <store> --json` and return the parsed result. The
// redirect (never a pipe) is the whole point — see captureToFile / D92.
export function runLeadsJson(term, storeDir) {
  const { out, status, error } = captureToFile("node", [
    LEDGER_CLI, "leads", term, "--dir", storeDir, "--json",
  ]);
  if (error) throw error;
  return { result: JSON.parse(out), status, bytes: out.length };
}

// Run `leads <term> --dir <store>` (the HUMAN render) and return its lines. This
// is what a reader actually reads, so lines-to-answer is counted here, not
// modelled off the JSON.
export function runLeadsRender(term, storeDir) {
  const { out, status } = captureToFile("node", [
    LEDGER_CLI, "leads", term, "--dir", storeDir,
  ]);
  return { lines: out.split("\n"), status, bytes: out.length };
}

// The scoped grep an agent types: `grep -rIn <term> <dir>`. grep exits 1 on a
// clean no-match (not an error) and 2 on a real error (e.g. missing dir); both
// are handled as "no answer here" rather than thrown, because a subsystem the
// store does not cover is a legitimate ZERO-COVERAGE reading, not a crash.
export function runGrep(term, dir, { excludeDirs = [] } = {}) {
  const { out, status } = captureToFile("grep", [...grepFlags(excludeDirs), "--", term, dir]);
  const lines = status === 0 ? out.split("\n").filter((l) => l !== "") : [];
  return { lines, count: lines.length, status };
}

// The same grep, counted rather than read. Callers that scan the WHOLE TREE take
// this path: the repo-wide output is hundreds of megabytes on this tree and its
// BODY is never used — only `count` reaches the report — so materialising it as
// a string buys nothing and costs an ERR_STRING_TOO_LONG the moment the tree
// crosses V8's ceiling. Same command, same definition of a line, same number.
export function runGrepCount(term, dir, { excludeDirs = [] } = {}) {
  const { lines, status } = captureLineCountToFile("grep", [...grepFlags(excludeDirs), "--", term, dir]);
  return { count: status === 0 ? lines : 0, status };
}

function grepFlags(excludeDirs) {
  return ["-rIn", ...excludeDirs.map((d) => `--exclude-dir=${d}`)];
}

// lines-to-answer for LEADS: the 1-based line index, in the human render, of the
// first `$ ` command line belonging to an ON-SUBJECT row. Rows render
// subject-header then `$ rerun`, so the first on-subject `$` line is the first
// re-runnable command a reader reaches. null when no on-subject command exists —
// which is leads' ZERO-COVERAGE, a distinct outcome from "a command far down".
function leadsLinesToAnswer(renderLines, prefix, exact = false) {
  let currentSubject = null;
  for (let i = 0; i < renderLines.length; i += 1) {
    const line = renderLines[i];
    // A subject header line is indented two spaces then the subject then the
    // quantity; the render never indents it further. We read the subject off the
    // command line's own context instead of parsing the header, by tracking the
    // last `deps` — but the cheapest reliable signal is the `$ ` command line,
    // whose text contains the subject path when the subject is a path. To stay
    // robust we test on-subject at the command line using the header captured
    // just above it.
    const header = line.match(/^ {2}(\S.*?)\s{2,}\S/);
    if (header) currentSubject = header[1].trim();
    const isCommand = /^\s{4,}\$ /.test(line);
    if (isCommand && currentSubject !== null) {
      const on = exact ? currentSubject === prefix : currentSubject.startsWith(prefix);
      if (on) return i + 1;
    }
  }
  return null;
}

// lines-to-answer for the SCOPED GREP: the 1-based index, in grep's output, of
// the first line that reveals a `"rerun"` command (the answer an agent extracts
// from the store). grep loses the subject-to-rerun pairing that leads preserves,
// so this counts the reader's scan to the first rerun-bearing line; null when
// grep surfaces no rerun line at all.
function grepLinesToAnswer(grepLines) {
  for (let i = 0; i < grepLines.length; i += 1) {
    if (grepLines[i].includes('"rerun"')) return i + 1;
  }
  return null;
}

// ── `grep -c` was measured as a faster equivalent, and REJECTED on the data ──
//
// The obvious optimisation is to let grep do the counting (`-rIc`, one
// `path:count` line per file) so the capture is kilobytes instead of hundreds of
// megabytes. It IS exactly equivalent — measured with the real /usr/bin/grep
// (BSD grep 2.6.0), never an interactive shell's, across six corpora and every
// term tried, including the pathological one where a handful of multi-megabyte
// single-line JSON files turn 5,819 matching lines into 340 MB of `-n` output:
// zero divergence, every time.
//
// It is also NOT FASTER, which is why this still runs `-rIn`. On a clean
// checkout the two forms are 1183 ms and 1187 ms — 1.00x. grep must read every
// byte of every file either way; the output form is not where the time goes.
// Adopting `-c` would therefore trade the command that DEFINES
// `repo_wide_grep_lines` for a different one and buy nothing measurable.
//
// The runtime that motivated the question is a property of the TREE, not of this
// harness: a clean checkout scans in ~1.2 s, and only a working checkout carrying
// hundreds of megabytes of untracked agent state takes minutes. That is why the
// test below bounds its own corpus instead.

// The heavy directories a repo-wide grep must NOT count: vendored trees and
// build output are not "the codebase an agent searches", and scanning them is
// both noise and the run's slowest step. Named once.
export const REPO_WIDE_EXCLUDES = Object.freeze([
  ".git", "node_modules", "_build", "deps", ".turbo", "dist", "build",
]);

// Score one query at one granularity against one store. The scoped grep targets
// the STORE dir (so it grows with volume just as leads does); the repo-wide grep
// targets the whole tree, as the context number leads trivially beats. `repoWide`
// defaults on for the CLI; tests pass it off to skip the whole-tree scan.
export function scoreQuery({ term, prefix }, storeDir, { exact = false, repoWide = true, repoWideDir = "." } = {}) {
  const { result } = runLeadsJson(term, storeDir);
  const { lines: renderLines } = runLeadsRender(term, storeDir);
  const rows = Array.isArray(result.rows) ? result.rows : [];
  const onSubject = rows.filter((r) => (exact ? r.subject === prefix : String(r.subject ?? "").startsWith(prefix)));
  const bucket = rows.length;

  const scopedGrep = runGrep(term, storeDir);
  // COUNTED, not read: the repo-wide body is never consumed, and its SIZE is
  // unbounded — see MAX_STRING_LENGTH for the read this replaces. `repoWideDir`
  // is "." for the CLI (the whole tree, which is the metric) and is overridable
  // so a test can bound its own corpus rather than scan a developer's working
  // checkout, where untracked state makes the same call take minutes.
  const repoWideGrep = repoWide
    ? runGrepCount(term, repoWideDir, { excludeDirs: REPO_WIDE_EXCLUDES })
    : { count: null };

  const leadsAnswer = leadsLinesToAnswer(renderLines, prefix, exact);
  const grepAnswer = grepLinesToAnswer(scopedGrep.lines);
  const leadsScan = renderLines.filter((l) => l !== "").length;
  const grepScan = scopedGrep.count;

  // classification — mutually exclusive, and NONE of it is averaged with the
  // rest. ZERO-COVERAGE dominates: if leads returns no on-subject command, there
  // is nothing to race, whatever the bucket size.
  let bucketClass;
  if (onSubject.length === 0) bucketClass = "zero-coverage";
  else if (bucket <= SINGLETON_MAX) bucketClass = "singleton";
  else if (bucket >= LARGE_BUCKET_MIN) bucketClass = "large-bucket";
  else bucketClass = "scorable";

  // TWO readings, because the choice of reading IS the choice of winner and that
  // is Review's call, not the builder's:
  //   · first-command: line index of the first re-runnable command each surfaces.
  //     This FLATTERS grep — grep's first `"rerun"` line is UNPAIRED (the reader
  //     cannot tell which subject it belongs to without reading the surrounding
  //     JSON), while leads' first on-subject command is the paired, sorted answer.
  //   · full-scan: the total lines a reader scans to be sure they have seen every
  //     candidate. This FLATTERS leads — a dense render vs raw grep fragments.
  // The true cost sits between them; shipping both, unaveraged, is the honesty.
  const winnerOn = (a, b) => (a === null && b === null ? "n/a"
    : a === null ? "grep" : b === null ? "leads"
    : a < b ? "leads" : a > b ? "grep" : "tie");
  const contestable = bucketClass === "scorable";
  const winnerFirst = contestable ? winnerOn(leadsAnswer, grepAnswer) : "n/a";
  const winnerScan = contestable ? winnerOn(leadsScan, grepScan) : "n/a";

  return {
    term,
    prefix,
    grain: exact ? "file-path" : "subsystem",
    leads_rows: bucket,
    leads_on_subject: onSubject.length,
    precision: bucket === 0 ? null : onSubject.length / bucket,
    leads_lines_to_answer: leadsAnswer,
    leads_total_render_lines: leadsScan,
    scoped_grep_lines: grepScan,
    scoped_grep_lines_to_answer: grepAnswer,
    repo_wide_grep_lines: repoWideGrep.count,
    bucket_class: bucketClass,
    winner_first_command: winnerFirst,
    winner_full_scan: winnerScan,
  };
}

// honest-empty rate at ONE granularity: the fraction of queries for which leads
// returned zero on-subject rows. Reported for both grains and never merged.
export function honestEmptyRate(scored) {
  const total = scored.length;
  const empty = scored.filter((s) => s.leads_on_subject === 0).length;
  return { total, empty, rate: total === 0 ? null : empty / total };
}

// ── the report ────────────────────────────────────────────────────────────────

// `subsystemQueries` / `filepathQueries` default to the frozen sets (the CLI path)
// and are overridable so the test can drive a small subset fast; `repoWide`
// toggles the whole-tree context grep, which the test turns off.
export function buildReport(storeDir, {
  subsystemQueries = SUBSYSTEM_QUERIES,
  filepathQueries = FILEPATH_QUERIES,
  repoWide = true,
  repoWideDir = ".",
} = {}) {
  const subsystem = subsystemQueries.map((q) => scoreQuery(q, storeDir, { exact: false, repoWide, repoWideDir }));
  const filepath = filepathQueries.map((p) => scoreQuery({ term: p, prefix: p }, storeDir, { exact: true, repoWide, repoWideDir }));

  const scorable = subsystem.filter((s) => s.bucket_class === "scorable");
  const singletons = subsystem.filter((s) => s.bucket_class === "singleton");
  const large = subsystem.filter((s) => s.bucket_class === "large-bucket");
  const zeroCoverage = subsystem.filter((s) => s.bucket_class === "zero-coverage");

  const tally = (key) => {
    const contested = scorable.filter((s) => s[key] !== "n/a").length;
    const leadsWins = scorable.filter((s) => s[key] === "leads").length;
    return { contested, leads_wins: leadsWins, leads_win_share: contested === 0 ? null : leadsWins / contested };
  };
  const firstTally = tally("winner_first_command");
  const scanTally = tally("winner_full_scan");

  // precision over the queries that returned anything at all (W5's metric),
  // reported at subsystem grain.
  const withRows = subsystem.filter((s) => s.leads_rows > 0);
  const precisionNum = withRows.reduce((n, s) => n + s.leads_on_subject, 0);
  const precisionDen = withRows.reduce((n, s) => n + s.leads_rows, 0);

  const internalCli = subsystem.find((s) => s.term === "internal/cli");

  return {
    store: storeDir,
    generated_at_note: "no timestamp is stored — this report is a pure function of --store and the frozen inputs",
    predictions: PREDICTIONS,
    measured_here: MEASURED_HERE,
    retired_prior: RETIRED_PRIOR,
    granularity_rule: D59_GRANULARITY_RULE,
    subsystem_grain: {
      queries: subsystem,
      honest_empty: honestEmptyRate(subsystem),
      // the three off-band classes, reported SEPARATELY and never averaged in
      singletons: singletons.map((s) => s.term),
      large_buckets: large.map((s) => ({ term: s.term, rows: s.leads_rows })),
      zero_coverage: zeroCoverage.map((s) => s.term),
      scorable_count: scorable.length,
    },
    filepath_grain: {
      queries: filepath,
      honest_empty: honestEmptyRate(filepath),
    },
    // W5: precision on the shipping subject-default store
    precision: {
      numerator: precisionNum,
      denominator: precisionDen,
      value: precisionDen === 0 ? null : precisionNum / precisionDen,
      note: "fraction of returned rows genuinely under the queried subsystem (W5); D79's 29.2% is retired",
    },
    // W4 input: the internal/cli bucket size on this store (pinned prediction 20)
    w4_internal_cli_rows: internalCli ? internalCli.leads_rows : null,
    // W6: the head-to-head, computed but NOT stamped — the builder does not
    // declare the verdict; a Review run against the merged post-backfill store
    // does. TWO tallies, unaveraged: which one is the headline is Review's call.
    w6_head_to_head: {
      first_command: firstTally,
      full_scan: scanTally,
      caveat:
        "first_command flatters grep (its first `\"rerun\"` line is unpaired); full_scan flatters "
        + "leads (dense render vs raw fragments). Both are shipped so the metric choice is visible.",
      prediction: "leads wins FEWER THAN HALF (W6)",
      verdict: "PENDING-REVIEW",
      verdict_note:
        "the builder does NOT stamp leads-wins/loses — volume must precede the trial (D40). "
        + "The decisive reading is a Review run against the MERGED post-backfill store; this run is "
        + "against the current low-volume store and is a self-test of the instrument only.",
    },
  };
}

// ── the human render ──────────────────────────────────────────────────────────

function pct(x) {
  return x === null ? "n/a" : `${(x * 100).toFixed(1)}%`;
}

export function renderReport(report) {
  const out = [];
  const o = (l = "") => out.push(l);
  const rule = "─".repeat(76);

  o(`trial: leads vs the SCOPED grep — store ${JSON.stringify(report.store)}`);
  o(`  ${report.generated_at_note}`);
  o();
  o("PRE-DECLARED PREDICTIONS (frozen in this file BEFORE any decisive run):");
  for (const p of report.predictions) o(`  ${p.id}: ${p.text}`);
  o(`  measured by THIS harness: ${report.measured_here.join(", ")} (the rest belong to other slices)`);
  o();
  o(`RETIRED PRIOR — ${report.retired_prior.decision} (retired by ${report.retired_prior.retired_by}):`);
  for (const r of report.retired_prior.readings) o(`  · ${r}`);
  o(`  why retired: ${report.retired_prior.why}`);
  o();
  o(`GRANULARITY RULE (D59): ${report.granularity_rule}`);
  o(rule);

  const sub = report.subsystem_grain;
  o("SUBSYSTEM GRAIN");
  o(`  honest-empty: ${sub.honest_empty.empty}/${sub.honest_empty.total} = ${pct(sub.honest_empty.rate)}`);
  o(`  scorable (in the 3-20 band, has answers): ${sub.scorable_count}`);
  o(`  singletons (reported separately, never averaged): ${sub.singletons.length ? sub.singletons.join(", ") : "none"}`);
  o(`  >20-buckets (reported separately): ${sub.large_buckets.length ? sub.large_buckets.map((b) => `${b.term}(${b.rows})`).join(", ") : "none"}`);
  o(`  zero-coverage (reported separately): ${sub.zero_coverage.length ? sub.zero_coverage.join(", ") : "none"}`);
  o();
  o("  columns: rows · on-subj · precision | first-command lines (leads/scoped-grep) | full-scan lines (leads/scoped-grep) | repo-wide grep | class | winners(first,scan)");
  for (const q of sub.queries) {
    o(`    ${q.term.padEnd(20)}  r=${String(q.leads_rows).padStart(3)} on=${String(q.leads_on_subject).padStart(3)} `
      + `prec=${pct(q.precision).padStart(6)} | 1st ${String(q.leads_lines_to_answer ?? "—").padStart(3)}/${String(q.scoped_grep_lines_to_answer ?? "—").padStart(3)} `
      + `| scan ${String(q.leads_total_render_lines).padStart(3)}/${String(q.scoped_grep_lines).padStart(4)} `
      + `| repo=${String(q.repo_wide_grep_lines ?? "—").padStart(5)} [${q.bucket_class}] ${q.winner_first_command}/${q.winner_full_scan}`);
  }
  o(rule);

  const fp = report.filepath_grain;
  o("FILE-PATH GRAIN (D59's second reading — a store-COVERAGE reading, never averaged with the above)");
  o(`  honest-empty: ${fp.honest_empty.empty}/${fp.honest_empty.total} = ${pct(fp.honest_empty.rate)}`);
  o(rule);

  o(`W5 precision (subject-default store): ${report.precision.numerator}/${report.precision.denominator} = ${pct(report.precision.value)}`);
  o(`W4 input — leads internal/cli rows on this store: ${report.w4_internal_cli_rows} (prediction: 20 post-backfill)`);
  o();
  const h = report.w6_head_to_head;
  o(`W6 HEAD-TO-HEAD (prediction: ${h.prediction}):`);
  o(`  first-command reading: leads wins ${h.first_command.leads_wins}/${h.first_command.contested} (${pct(h.first_command.leads_win_share)})`);
  o(`  full-scan   reading: leads wins ${h.full_scan.leads_wins}/${h.full_scan.contested} (${pct(h.full_scan.leads_win_share)})`);
  o(`  caveat: ${h.caveat}`);
  o(`  VERDICT: ${h.verdict}`);
  o(`  ${h.verdict_note}`);
  return `${out.join("\n")}\n`;
}

// ── the CLI ────────────────────────────────────────────────────────────────────

export function parseArgs(argv) {
  const args = [...argv];
  const takeFlag = (name) => {
    const i = args.indexOf(name);
    if (i < 0) return null;
    const value = args[i + 1];
    args.splice(i, value === undefined ? 1 : 2);
    return value ?? null;
  };
  const json = args.includes("--json");
  const selftest = args.includes("--selftest");
  const store = takeFlag("--store");
  return { store, json, selftest };
}

const USAGE =
  "usage: node tooling/grip/trial-leads-vs-grep.mjs --store <ledger dir> [--json]\n"
  + "  --store <dir>   the ledger directory to measure (the SAME instrument reads the pre-backfill\n"
  + "                  and post-backfill stores; the delta is attributable to volume, never to the runner).\n"
  + "  --json          emit the structured report instead of the human render.\n";

function main(argv) {
  const { store, json, selftest } = parseArgs(argv);

  if (selftest) {
    // A guard the reader can watch fail: assert the frozen inputs are intact.
    const ids = PREDICTIONS.map((p) => p.id).join(",");
    if (ids !== "W1,W2,W3,W4,W5,W6,W7") {
      process.stderr.write(`selftest FAIL: predictions are not W1-W7 (got ${ids})\n`);
      return 1;
    }
    if (!PREDICTIONS.find((p) => p.id === "W6").text.includes("FEWER THAN HALF")) {
      process.stderr.write("selftest FAIL: W6 headline lost its 'FEWER THAN HALF' claim\n");
      return 1;
    }
    if (RETIRED_PRIOR.decision !== "D79") {
      process.stderr.write("selftest FAIL: the retired prior must be cited by number (D79)\n");
      return 1;
    }
    process.stdout.write("selftest OK: W1-W7 frozen, W6 headline intact, D79 cited as retired\n");
    return 0;
  }

  if (!store) {
    process.stderr.write(USAGE);
    return 2;
  }

  const report = buildReport(store);
  process.stdout.write(json ? `${JSON.stringify(report, null, 2)}\n` : renderReport(report));
  return 0;
}

// Only run when invoked directly, so the test can import the pure functions
// without spawning the CLI.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  // NO process.exit HERE (charter D92). main() writes the whole report — the
  // `--json` document included — to stdout on the line before it returns, and
  // Node writes a PIPE asynchronously: process.exit() discards whatever the
  // kernel has not taken yet, so `--json | jq` gets a JSON.parse error the
  // caller blames on this tool's format while `--json > file` is whole. The
  // exit STATUS is unchanged in every arm (0 clean or selftest OK, 1 selftest
  // FAIL, 2 no --store).
  process.exitCode = main(process.argv.slice(2));
}
