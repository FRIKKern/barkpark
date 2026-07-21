#!/usr/bin/env node
// census.mjs — re-execute stored recipes and report whether they STILL ANSWER.
//
//   node tooling/grip/census.mjs                 human render over the frozen corpus
//   node tooling/grip/census.mjs --json          machine render
//   node tooling/grip/census.mjs --limit 40      bound the run while iterating
//   node tooling/grip/census.mjs --include-test-runners
//   node tooling/grip/census.mjs --help
//
// WHY THIS EXISTS. The epic stores RECIPES rather than values on the theory that
// a recipe survives what a value cannot. That is a claim, and until this module
// ran it was an unmeasured one. The census is the epic measuring itself.
//
// ── D47 — THIS MODULE OWNS THE SCREEN COMPOSITION ────────────────────────────
//
// census.mjs calls `screenCommand` from ./screen.mjs itself and executes only
// what passes. It does NOT route through runRerun and it does NOT modify
// rerun.mjs's gate. Composing at the call site keeps screen.mjs importing
// nothing from rerun.mjs (D29) and keeps the blast radius off the only gate
// currently running on main.
//
// The safety bound is screenCommand and NOTHING ELSE. Never classifySafety.
// Measured, not hypothetical: classifySafety admits 22 of 22 named outage
// probes (reboot, `systemctl stop`, `mix ecto.drop`, `bash site-deploy.sh`,
// `kill -9`, `pkill`, `cp` into api/lib/) where screenCommand admits 0 of 22.
// Over the frozen corpus classifySafety admits 87.9% against screenCommand's
// 36.9% — the older gate is 2.4x more permissive. A census wired to it would
// have executed `systemctl stop bp-crux-parent`.
//
// ── D50 — SILENCE IS AN ANSWER, AND THE PREDICATE IS PER-FAMILY ──────────────
//
// A flat `rc === 0 && stdout non-empty` predicate does not merely miss answers,
// it INVERTS them. Measured on the shipped code:
//
//   git diff <unchanged path>   rc 0,    0 bytes  → a BYTE-IDENTITY answer
//   grep, no match              rc 1,    0 bytes  → an ABSENCE answer
//   diff, files differ          rc 1, 7357 bytes  → a PRESENCE answer
//
// The two rc-1 rows carry OPPOSITE polarity. There is no flat rule to write,
// because exit-code semantics are a property of the tool, not of the shell. So
// this module dispatches on FAMILY first and exit code second.
//
// THE FAMILY IS READ OFF THE LAST PIPELINE SEGMENT. `sh -c 'a | b'` exits with
// b's status, so `git ls-tree … | grep -i scaffy` is a MATCHER, not a lister —
// keying on the head would read grep's rc 1 through the lister's table and turn
// a legitimate absence into a failure.
//
// ── rc 128 IS A PRECONDITION, NOT A VERDICT ──────────────────────────────────
//
// For CONTENT-FETCH, git's rc 128 is only NECESSARY for decay. The stderr line
// carries the actual finding:
//
//   "does not exist in"        → PATH-GONE      real decay, admissible
//   "invalid object name"      → REF-GONE       ENVIRONMENT FAULT, inadmissible
//   "not a git repository"     → WRONG-CWD      ENVIRONMENT FAULT, inadmissible
//
// Key on the exit code alone and a census run in a worktree that has not
// fetched origin reports the ENTIRE ledger as decayed — an outage forging a
// decay wave. Inadmissible rows leave the denominator; they measure this host,
// not the ledger.
//
// ── WHAT THIS MODULE DOES NOT CLAIM ──────────────────────────────────────────
//
// STILL-ANSWERING IS NOT STILL-CORRECT. A recipe can run clean and return a
// different answer than the one recorded beside it. The canonical specimen:
// `git ls-tree -r origin/main --name-only | grep -i "internal/scaffy"` was
// recorded as an absence and today returns 58 files. It still ANSWERS. Its
// stored answer is wrong. Answer-DRIFT is out of scope for this wave and is
// deliberately absent from every render here — the 154/221 figure circulating
// in earlier notes is a TRUNCATION BOUND (only 200 chars of stdout were ever
// captured), and a bound quoted as a rate is the level-skip this epic exists
// to prevent.
//
// THE CENSUS NEVER WRITES. It may RUN over the frozen corpus as measurement,
// but bulk-importing 652 unverified historical strings into tooling/grip/ledger
// would store volume where the charter demands trust. This module imports no
// writer and contains no write call.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { screenCommand } from "./screen.mjs";
import { deriveLevel, looksLikeProse } from "./level.mjs";
// The constant only — importing runRerun would put a second, differently-gated
// execution path inside the census.
import { SYNC_TIMEOUT_MS } from "./rerun.mjs";

// ─────────────────────────────────────────────────────────────────────────────
// TIMEOUT — generous on purpose
// ─────────────────────────────────────────────────────────────────────────────
//
// Slowness must never be scored as decay. A recipe that answers in 6 seconds
// answers; a census that calls it dead has manufactured a finding. The floor is
// tied to rerun's synchronous budget so the two cannot silently diverge.

export const TIMEOUT_FLOOR_MULTIPLE = 4;
export const CENSUS_TIMEOUT_MS = SYNC_TIMEOUT_MS * TIMEOUT_FLOOR_MULTIPLE; // 8000ms
export const CENSUS_TIMEOUT_FLOOR_MS = 8000;

// ─────────────────────────────────────────────────────────────────────────────
// FAMILIES
// ─────────────────────────────────────────────────────────────────────────────

export const FAMILY = Object.freeze({
  MATCHER: "MATCHER",
  DIFFER: "DIFFER",
  PREDICATE: "PREDICATE",
  QUERY_LISTER: "QUERY-LISTER",
  CONTENT_FETCH: "CONTENT-FETCH",
  UNKNOWN: "UNKNOWN",
});

/** Tools whose empty output at rc 1 is a legitimate ABSENCE. */
const MATCHER_HEADS = new Set(["grep", "egrep", "fgrep", "rg", "ag", "ack"]);
/** Tools that exit 1 to mean "they differ" — the opposite polarity to grep. */
const DIFFER_HEADS = new Set(["diff", "colordiff", "cmp"]);
/** Tools whose rc IS the answer and whose silence at rc 0 is the green. */
const PREDICATE_HEADS = new Set(["test", "[", "shellcheck", "eslint", "tsc", "vet"]);
/** Tools that enumerate — rc 0 with nothing found is an EMPTY SET, not a null read. */
const LISTER_HEADS = new Set(["ls", "find", "wc", "ps", "du", "gh", "bp", "which", "type", "stat", "env", "printenv"]);
/** Tools that hand back bytes — a missing target is the decay signal. */
const FETCH_HEADS = new Set(["cat", "head", "tail", "sed", "awk", "jq", "node", "readlink", "basename", "dirname"]);

/** git sub-verbs, split by what their exit code MEANS. */
const GIT_MATCHER = new Set(["grep"]);
const GIT_DIFFER = new Set(["diff"]);
const GIT_FETCH = new Set(["show", "cat-file"]);
const GIT_LISTER = new Set([
  "ls-tree", "ls-files", "ls-remote", "log", "branch", "tag", "status",
  "rev-parse", "rev-list", "describe", "shortlog", "config", "remote", "blame",
]);

/**
 * The family of a command, read off the LAST pipeline segment.
 *
 * `sh -c 'a | b'` exits with b's status (no pipefail), so the tool that
 * produced the exit code being classified is the tail, not the head.
 */
export function classifyFamily(command) {
  const raw = String(command ?? "").trim();
  if (!raw) return FAMILY.UNKNOWN;

  // Quote-masked split so a pipe inside a quoted argument is not a segment
  // boundary. screen.mjs has already refused anything with `;`, `&&` or a
  // subshell, so the tail of a pipeline is the whole story here.
  const masked = raw.replace(/'[^']*'|"[^"]*"/g, (m) => " ".repeat(m.length));
  const bounds = [];
  for (let i = 0; i < masked.length; i += 1) if (masked[i] === "|" && masked[i + 1] !== "|") bounds.push(i);
  const tail = bounds.length ? raw.slice(bounds[bounds.length - 1] + 1) : raw;

  // ENV-VAR PREFIXES ARE NOT THE HEAD. `CC=clang go vet ./...` is a go vet, and
  // reading `CC=clang` as the head drops it into UNKNOWN — where its clean rc 0
  // with no output becomes an AMBIGUOUS-SILENCE instead of the PASS it is. This
  // is not hypothetical: 5 of the 6 admitted `go vet` rows in the frozen corpus
  // carry a `CC=` prefix (the cc-alias gotcha), so without this the census
  // discards the canonical green on every specimen it actually has.
  const tokens = tail.trim().split(/\s+/).filter(Boolean);
  while (tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[0])) tokens.shift();
  if (!tokens.length) return FAMILY.UNKNOWN;
  const head = tokens[0].replace(/^.*\//, "");

  if (head === "git") {
    const verb = tokens.slice(1).find((t) => !t.startsWith("-"));
    if (GIT_MATCHER.has(verb)) return FAMILY.MATCHER;
    // `git diff --quiet` and `git diff --exit-code` are still differs: rc 1
    // means "they differ", which is an ANSWER whether or not bytes came back.
    if (GIT_DIFFER.has(verb)) return FAMILY.DIFFER;
    if (GIT_FETCH.has(verb)) return FAMILY.CONTENT_FETCH;
    if (GIT_LISTER.has(verb)) return FAMILY.QUERY_LISTER;
    return FAMILY.UNKNOWN;
  }

  // `go vet ./...` and `mix format --check-formatted` are the canonical greens:
  // rc 0 with zero bytes is a PASS, and the naive predicate throws it away.
  if (head === "go" && tokens[1] === "vet") return FAMILY.PREDICATE;
  if (head === "go" && (tokens[1] === "build" || tokens[1] === "list")) return FAMILY.PREDICATE;
  if (head === "gofmt" || head === "mix") return FAMILY.PREDICATE;
  if (head === "node" && tokens.includes("--test")) return FAMILY.PREDICATE;

  if (MATCHER_HEADS.has(head)) return FAMILY.MATCHER;
  if (DIFFER_HEADS.has(head)) return FAMILY.DIFFER;
  if (PREDICATE_HEADS.has(head)) return FAMILY.PREDICATE;
  if (LISTER_HEADS.has(head)) return FAMILY.QUERY_LISTER;
  if (FETCH_HEADS.has(head)) return FAMILY.CONTENT_FETCH;
  return FAMILY.UNKNOWN;
}

// ─────────────────────────────────────────────────────────────────────────────
// OUTCOMES
// ─────────────────────────────────────────────────────────────────────────────
//
// `answering` and `admissible` are SEPARATE fields and are never fused into a
// pass/fail. A row can be inadmissible (this host is broken) without being
// either an answer or a decay — collapsing the two is exactly how a fetch
// failure becomes a fabricated decay wave.

export const OUTCOME = Object.freeze({
  // answers
  ANSWERED: "ANSWERED",
  PRESENT: "PRESENT",
  ABSENT: "ABSENT",
  IDENTICAL: "IDENTICAL",
  DIFFERENT: "DIFFERENT",
  EMPTY_SET: "EMPTY-SET",
  PASS: "PASS",
  FAIL: "FAIL",
  // decay
  PATH_GONE: "PATH-GONE",
  RAN_AND_FAILED: "RAN-AND-FAILED",
  TOOL_ERROR: "TOOL-ERROR",
  // neither — the census does not know, and says so
  AMBIGUOUS_SILENCE: "AMBIGUOUS-SILENCE",
  ANOMALOUS_SILENCE: "ANOMALOUS-SILENCE",
  REF_GONE: "REF-GONE",
  WRONG_CWD: "WRONG-CWD",
  UNCLASSIFIED_128: "UNCLASSIFIED-128",
  TIMEOUT: "TIMEOUT",
  SPAWN_ERROR: "SPAWN-ERROR",
  // never executed
  REFUSED: "REFUSED",
  NOT_A_COMMAND: "NOT-A-COMMAND",
  SKIPPED_TEST_RUNNER: "SKIPPED-TEST-RUNNER",
});

const ANSWERING = new Set([
  OUTCOME.ANSWERED, OUTCOME.PRESENT, OUTCOME.ABSENT, OUTCOME.IDENTICAL,
  OUTCOME.DIFFERENT, OUTCOME.EMPTY_SET, OUTCOME.PASS, OUTCOME.FAIL,
]);
const DECAYED = new Set([OUTCOME.PATH_GONE, OUTCOME.RAN_AND_FAILED, OUTCOME.TOOL_ERROR]);

export const isAnswering = (outcome) => ANSWERING.has(outcome);
export const isDecayed = (outcome) => DECAYED.has(outcome);

// Environment faults. Each one says something about THIS HOST and nothing about
// the stored recipe, so each one leaves the denominator.
const ENV_FAULT = [
  [/not a git repository/i, OUTCOME.WRONG_CWD, "not a git repository — this host is not where the recipe was recorded"],
  [/invalid object name|unknown revision or path not in the working tree|bad revision|ambiguous argument '[^']*'/i,
    OUTCOME.REF_GONE, "the ref is unavailable here — an unfetched worktree, not a gone path"],
  [/could not read from remote|permission denied \(publickey\)|host key verification failed|network is unreachable|could not resolve host/i,
    OUTCOME.SPAWN_ERROR, "the network or a credential failed — nothing was measured"],
];

// A path that is genuinely gone. Distinguished from the env faults above by
// naming a PATH rather than a ref or a repository.
const PATH_GONE_RE = /does not exist in|no such file or directory|did not match any file|pathspec '[^']*' did not match|cannot find module|matched no packages/i;

const envFault = (stderr) => {
  for (const [re, outcome, why] of ENV_FAULT) if (re.test(stderr)) return { outcome, why };
  return null;
};

/**
 * Classify one executed row: FAMILY first, exit code second.
 *
 * @param {string} command
 * @param {{exit:number|null, stdout:string, stderr:string, timedOut?:boolean, spawnError?:string|null}} run
 */
export function classifyOutcome(command, run) {
  const family = classifyFamily(command);
  const out = String(run?.stdout ?? "");
  const err = String(run?.stderr ?? "");
  const rc = run?.exit;
  const hasOutput = out.trim() !== "";
  const row = (outcome, why) => ({
    family,
    outcome,
    why,
    answering: ANSWERING.has(outcome),
    decayed: DECAYED.has(outcome),
    admissible: ANSWERING.has(outcome) || DECAYED.has(outcome),
  });

  if (run?.timedOut) {
    return row(OUTCOME.TIMEOUT, `exceeded ${CENSUS_TIMEOUT_MS}ms — slowness is not decay, so this row is not counted as either`);
  }
  if (run?.spawnError) return row(OUTCOME.SPAWN_ERROR, `the shell could not start the command (${run.spawnError})`);
  if (rc === null || rc === undefined) return row(OUTCOME.SPAWN_ERROR, "no exit status — nothing was measured");
  if (rc === 127) return row(OUTCOME.PATH_GONE, "command not found — the tool the recipe depends on is gone");
  if (rc === 126) return row(OUTCOME.SPAWN_ERROR, "found but not executable — a permission fault on this host");

  const fault = envFault(err);
  // An env fault only overrides on a NONZERO exit; a warning on stderr beside a
  // clean run is not a fault.
  if (fault && rc !== 0) return row(fault.outcome, fault.why);

  switch (family) {
    case FAMILY.MATCHER:
      if (rc === 0 && hasOutput) return row(OUTCOME.PRESENT, "matched — the recorded presence still holds");
      if (rc === 0) return row(OUTCOME.ANOMALOUS_SILENCE, "grep exited 0 (matched) yet printed nothing — the read contradicts itself and is not counted");
      // THE SPECIMEN. rc 1 with zero bytes is grep saying "I ran, I found
      // nothing" — an ANSWER. The naive predicate scores it decayed.
      if (rc === 1) return row(OUTCOME.ABSENT, "no match — an absence is an answer, not a failure to answer");
      if (PATH_GONE_RE.test(err)) return row(OUTCOME.PATH_GONE, "the searched path is gone");
      return row(OUTCOME.TOOL_ERROR, `the matcher errored (exit ${rc})`);

    case FAMILY.DIFFER:
      // rc 0 with zero bytes is a BYTE-IDENTITY PROOF, the strongest answer a
      // differ gives. rc 1 is "they differ" — the opposite polarity to grep's
      // rc 1, which is why family must be read before exit code.
      if (rc === 0) return row(OUTCOME.IDENTICAL, "no differences — byte identity is an answer, and it is silent by design");
      if (rc === 1) return row(OUTCOME.DIFFERENT, "the inputs differ — an answer, whether or not bytes came back");
      if (PATH_GONE_RE.test(err)) return row(OUTCOME.PATH_GONE, "an input to the diff is gone");
      return row(OUTCOME.TOOL_ERROR, `the differ errored (exit ${rc})`);

    case FAMILY.PREDICATE:
      // A clean `go vet` is rc 0 with zero bytes. It is the canonical green and
      // the naive predicate discards it.
      if (rc === 0) return row(OUTCOME.PASS, "the predicate held — silence at exit 0 IS the answer for this family");
      if (PATH_GONE_RE.test(err) || PATH_GONE_RE.test(out)) {
        return row(OUTCOME.PATH_GONE, "the predicate's target is gone — it did not answer, it had nothing to answer about");
      }
      return row(OUTCOME.FAIL, `the predicate answered no (exit ${rc}) — a negative answer is still an answer`);

    case FAMILY.QUERY_LISTER:
      if (rc === 0 && hasOutput) return row(OUTCOME.ANSWERED, "the query returned rows");
      // An empty result set is a finding. Reading it as a null read is how a
      // real "nothing matches" gets thrown away.
      if (rc === 0) return row(OUTCOME.EMPTY_SET, "the query ran and matched nothing — an empty set is an answer, not a null read");
      if (PATH_GONE_RE.test(err)) return row(OUTCOME.PATH_GONE, "the queried path is gone");
      return row(OUTCOME.RAN_AND_FAILED, `the query failed (exit ${rc})`);

    case FAMILY.CONTENT_FETCH:
      if (rc === 0) {
        return hasOutput
          ? row(OUTCOME.ANSWERED, "the content came back")
          : row(OUTCOME.ANSWERED, "the target exists and is empty — an answer about its contents");
      }
      // rc 128 is a PRECONDITION for decay, never the verdict. The stderr line
      // decides, and two of the three readings are faults on this host.
      if (rc === 128 || rc === 1) {
        if (PATH_GONE_RE.test(err)) return row(OUTCOME.PATH_GONE, "the path the recipe reads does not exist any more — real decay");
        if (rc === 128) return row(OUTCOME.UNCLASSIFIED_128, "exit 128 with an unrecognised stderr — not classified rather than guessed");
      }
      return row(OUTCOME.RAN_AND_FAILED, `the fetch failed (exit ${rc})`);

    default:
      if (rc === 0 && hasOutput) return row(OUTCOME.ANSWERED, "exit 0 with output");
      // THE HONEST GAP. 246 of 652 corpus commands sit in a family whose silent
      // zero could be either a green or a null read. Guessing here is how the
      // census would start manufacturing its own numbers.
      if (rc === 0) return row(OUTCOME.AMBIGUOUS_SILENCE, "exit 0 with no output in an unclassified family — the census cannot tell an answer from a null read here, and does not guess");
      if (PATH_GONE_RE.test(err)) return row(OUTCOME.PATH_GONE, "a path the command depends on is gone");
      return row(OUTCOME.RAN_AND_FAILED, `exit ${rc}`);
  }
}

/**
 * The predicate this module replaces, kept executable so the fix stays PROVABLE.
 *
 * A check that cannot be shown to fail proves nothing. Every silence-as-answer
 * test runs its specimen through BOTH classifiers and asserts they disagree —
 * if a future edit made classifyOutcome behave like this again, those tests go
 * red instead of staying vacuously green.
 */
export function naiveOutcome(run) {
  const rc = run?.exit;
  const hasOutput = String(run?.stdout ?? "").trim() !== "";
  return rc === 0 && hasOutput ? OUTCOME.ANSWERED : "NULL-READ";
}

// ─────────────────────────────────────────────────────────────────────────────
// EXECUTION
// ─────────────────────────────────────────────────────────────────────────────

/** `go test` / `mix test` run repo code the screen never examined. Excluded by default. */
export function isTestRunner(command) {
  return /\b(go\s+test|mix\s+test|npm\s+test|pytest)\b/.test(String(command ?? ""));
}

export const REPO_ROOT = fileURLToPath(new URL("../../", import.meta.url));

function shell(cmd, { cwd = REPO_ROOT, timeoutMs = CENSUS_TIMEOUT_MS } = {}) {
  const started = Date.now();
  const r = spawnSync("/bin/sh", ["-c", cmd], {
    cwd,
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 8 * 1024 * 1024,
  });
  return {
    exit: r.status,
    signal: r.signal,
    timedOut: r.error?.code === "ETIMEDOUT" || (r.status === null && r.signal === "SIGTERM"),
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
    ms: Date.now() - started,
    spawnError: r.error && r.error.code !== "ETIMEDOUT" ? String(r.error.code) : null,
  };
}

/**
 * Screen one command and execute it ONLY if the screen admits it.
 *
 * The gate is `screenCommand` and it is not injectable. `exec` is injectable so
 * a test can prove the refusal path never reaches a spawn; the GATE is not, so
 * no caller can pass a permissive one.
 */
export function censusOne(command, { exec = shell, timeoutMs = CENSUS_TIMEOUT_MS, includeTestRunners = false } = {}) {
  const cmd = String(command ?? "").trim();
  const base = { command: cmd, level: deriveLevel(cmd) };

  // (a) THE SCREEN. Before anything is spawned, and its own reason is carried
  // through verbatim rather than restated — a paraphrased refusal reason is a
  // second, unproven claim about why.
  const screened = screenCommand(cmd);
  if (!screened.ok) {
    return { ...base, screened: false, executed: false, outcome: OUTCOME.REFUSED, why: screened.reason, family: null, answering: false, decayed: false, admissible: false };
  }

  // (b) NOT-A-COMMAND is a first-class finding about the corpus, not an error.
  // A meaningful slice of what was stored as evidence is English prose or a
  // command carrying a parenthetical annotation no shell can parse.
  if (looksLikeProse(cmd)) {
    return { ...base, screened: true, executed: false, outcome: OUTCOME.NOT_A_COMMAND, why: "prose or a placeholder, not an executable command — a finding about the corpus", family: classifyFamily(cmd), answering: false, decayed: false, admissible: false };
  }

  // (c) Test runners execute repo code the screen never examined. Excluded by
  // default and COUNTED, so the exclusion is visible rather than silent.
  if (!includeTestRunners && isTestRunner(cmd)) {
    return { ...base, screened: true, executed: false, outcome: OUTCOME.SKIPPED_TEST_RUNNER, why: "a test runner executes repo code the screen never examined — excluded by default", family: classifyFamily(cmd), answering: false, decayed: false, admissible: false };
  }

  const run = exec(cmd, { timeoutMs });
  const verdict = classifyOutcome(cmd, run);
  return { ...base, screened: true, executed: true, exit: run.exit, ms: run.ms, bytes: String(run.stdout ?? "").length, ...verdict };
}

const PREDICTION = Object.freeze({
  id: 3,
  text: "decay materially below wave 3's 22.4% floor on fresh rows",
  floorPct: 22.4,
  note: "Predeclared before this run. A null or contrary result is a real result and is reported as one.",
});

/**
 * Run the census over a command set.
 *
 * `corpusName` is required in the render: a statistic derived over the admitted
 * subset describes THAT SUBSET. Restating it as covering the whole set would be
 * the level-skip this epic exists to prevent.
 */
export function censusRun(commands, opts = {}) {
  const { corpusName = "(unnamed command set)", onProgress = null } = opts;
  const distinct = [...new Set((commands ?? []).filter((c) => typeof c === "string" && c.trim()))];
  const rows = [];
  for (const [i, cmd] of distinct.entries()) {
    rows.push(censusOne(cmd, opts));
    if (onProgress) onProgress(i + 1, distinct.length);
  }
  return summarise(rows, { corpusName, includeTestRunners: !!opts.includeTestRunners });
}

/** Which runner each excluded row is, so the exclusion is auditable rather than a bare count. */
function testRunnerHeads(rows) {
  const by = {};
  for (const r of rows) {
    if (r.outcome !== OUTCOME.SKIPPED_TEST_RUNNER) continue;
    const m = String(r.command).match(/\b(go\s+test|mix\s+test|npm\s+test|pytest)\b/);
    const key = m ? m[1].replace(/\s+/g, " ") : "other";
    by[key] = (by[key] || 0) + 1;
  }
  return by;
}

export function summarise(rows, { corpusName = "(unnamed command set)", includeTestRunners = false } = {}) {
  const count = (pred) => rows.filter(pred).length;
  const screened = rows.filter((r) => r.screened);
  const executed = rows.filter((r) => r.executed);
  const admissible = executed.filter((r) => r.admissible);
  const answering = admissible.filter((r) => r.answering);
  const decayed = admissible.filter((r) => r.decayed);

  const byOutcome = new Map();
  for (const r of rows) byOutcome.set(r.outcome, (byOutcome.get(r.outcome) || 0) + 1);
  const byFamily = new Map();
  for (const r of executed) byFamily.set(r.family, (byFamily.get(r.family) || 0) + 1);
  const byLevel = new Map();
  for (const r of rows) byLevel.set(r.level, (byLevel.get(r.level) || 0) + 1);

  const pct = (n, d) => (d ? (n / d) * 100 : 0);
  const decayPct = pct(decayed.length, admissible.length);

  return {
    corpusName,
    includeTestRunners,
    timeoutMs: CENSUS_TIMEOUT_MS,
    total: rows.length,
    // REACH — the census's honest bound, printed, never hidden.
    reach: {
      distinct: rows.length,
      admitted: screened.length,
      refused: rows.length - screened.length,
      admissionPct: pct(screened.length, rows.length),
      executed: executed.length,
      notACommand: count((r) => r.outcome === OUTCOME.NOT_A_COMMAND),
      testRunnersSkipped: count((r) => r.outcome === OUTCOME.SKIPPED_TEST_RUNNER),
      // COUNTED, not asserted. An earlier brief put this at 5 of 240; measuring
      // it over the same corpus gives 58 (15 `go test`, 43 `mix test`). The
      // census reports what it counted and lets the discrepancy be visible —
      // quoting the smaller inherited number would be the level-skip.
      testRunnerHeads: testRunnerHeads(rows),
    },
    // DECISIVE — executed rows that said something about the LEDGER rather than
    // about this host.
    decisive: {
      admissible: admissible.length,
      answering: answering.length,
      decayed: decayed.length,
      answeringPct: pct(answering.length, admissible.length),
      decayPct,
      inadmissible: executed.length - admissible.length,
    },
    prediction: {
      ...PREDICTION,
      measuredPct: decayPct,
      verdict: admissible.length === 0
        ? "NO RESULT — nothing admissible was measured, so the prediction was not tested"
        : decayPct < PREDICTION.floorPct
          ? `CONSISTENT — measured ${decayPct.toFixed(1)}% is below the ${PREDICTION.floorPct}% floor`
          : `CONTRARY — measured ${decayPct.toFixed(1)}% is at or above the ${PREDICTION.floorPct}% floor, and that is reported as the result it is`,
    },
    byOutcome,
    byFamily,
    byLevel,
    rows,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// RENDER
// ─────────────────────────────────────────────────────────────────────────────

/** True when a distribution is effectively a constant — a null result, said plainly. */
export function isNullDistribution(map) {
  const values = [...map.values()];
  if (values.length <= 1) return true;
  const total = values.reduce((a, b) => a + b, 0);
  return total > 0 && Math.max(...values) / total >= 0.99;
}

const bar = (n, total, width = 24) => "█".repeat(Math.round((total ? n / total : 0) * width)).padEnd(width, "·");

export function renderHuman(report) {
  const L = [];
  const { reach, decisive } = report;

  // ONE-LINE VERDICT BANNER, before any detail.
  L.push(
    decisive.admissible === 0
      ? `CENSUS — no admissible rows: nothing was measured, and no rate is reported.`
      : `CENSUS — ${decisive.answeringPct.toFixed(1)}% of ${decisive.admissible} decisive recipes STILL ANSWER; ${decisive.decayPct.toFixed(1)}% decayed.`,
  );
  L.push("");
  L.push(`corpus          ${report.corpusName}`);
  L.push(`timeout         ${report.timeoutMs}ms (${TIMEOUT_FLOOR_MULTIPLE}x rerun's ${SYNC_TIMEOUT_MS}ms — slowness is never scored as decay)`);
  const runnerSplit = Object.entries(reach.testRunnerHeads ?? {}).map(([k, n]) => `${n} ${k}`).join(", ");
  L.push(`test runners    ${report.includeTestRunners
    ? "INCLUDED — they execute repo code the screen never examined"
    : `EXCLUDED (${reach.testRunnersSkipped} rows${runnerSplit ? `: ${runnerSplit}` : ""}) — they execute repo code the screen never examined`}`);
  L.push("");

  L.push("REACH — what this census could legitimately touch");
  L.push(`  distinct commands   ${reach.distinct}`);
  L.push(`  admitted by screen  ${reach.admitted}  (${reach.admissionPct.toFixed(1)}%)`);
  L.push(`  refused by screen   ${reach.refused}`);
  L.push(`  not a command       ${reach.notACommand}  (${(reach.admitted ? (reach.notACommand / reach.admitted) * 100 : 0).toFixed(1)}% of the screened set — English or an unparseable annotation, a finding about the corpus)`);
  L.push(`  executed            ${reach.executed}`);
  L.push("");
  L.push(`  Every rate below describes THESE ${decisive.admissible} decisive rows.`);
  L.push(`  It is not a statement about all ${reach.distinct} commands in this corpus:`);
  L.push(`  ${report.corpusName}`);
  L.push(`  The refused ones were never measured, and they are not a random sample —`);
  L.push(`  a command the screen turns away is systematically MORE decay-prone, not less.`);
  L.push("");

  if (decisive.admissible === 0) {
    L.push("NULL STATE — no row was admissible. Either the screen admitted nothing or every");
    L.push("execution hit an environment fault. No answering rate and no decay rate exist");
    L.push("for this run; reporting one would be inventing it.");
    return L.join("\n");
  }

  L.push("STILL ANSWERING vs DECAYED");
  L.push(`  answering   ${String(decisive.answering).padStart(4)}  ${bar(decisive.answering, decisive.admissible)}  ${decisive.answeringPct.toFixed(1)}%`);
  L.push(`  decayed     ${String(decisive.decayed).padStart(4)}  ${bar(decisive.decayed, decisive.admissible)}  ${decisive.decayPct.toFixed(1)}%`);
  L.push(`  inadmissible ${String(decisive.inadmissible).padStart(3)}  environment faults and ambiguous silences — excluded from BOTH rates,`);
  L.push(`                     because they measure this host, not the ledger.`);
  L.push("");

  L.push("STILL ANSWERING IS NOT STILL CORRECT.");
  L.push("  A recipe counted above ran cleanly and returned something. Whether it returned");
  L.push("  the SAME something that was recorded beside it is NOT measured here. The known");
  L.push("  specimen: `git ls-tree -r origin/main --name-only | grep -i internal/scaffy` was");
  L.push("  stored as an absence and today returns 58 files. It still answers. Its stored");
  L.push("  answer is wrong. Answer-drift is out of scope for this wave and no drift rate is");
  L.push("  reported anywhere in this output.");
  L.push("");

  L.push("OUTCOMES");
  const outcomes = [...report.byOutcome].sort((a, b) => b[1] - a[1]);
  for (const [outcome, n] of outcomes) L.push(`  ${String(n).padStart(4)}  ${outcome}`);
  if (isNullDistribution(report.byOutcome)) {
    L.push("  NULL RESULT — this distribution has no variance. One outcome accounts for");
    L.push("  essentially everything, so there is no signal here to read. Saying so is the");
    L.push("  finding; dressing a near-constant as a distribution would not be.");
  }
  L.push("");

  L.push("FAMILY — the dispatch that makes silence readable");
  for (const [family, n] of [...report.byFamily].sort((a, b) => b[1] - a[1])) L.push(`  ${String(n).padStart(4)}  ${family}`);
  L.push("");

  L.push("AUTHORITY LEVEL of the recipes measured");
  for (const [level, n] of [...report.byLevel].sort()) L.push(`  ${String(n).padStart(4)}  ${level}`);
  L.push("");

  L.push(`PREDICTION ${report.prediction.id} — "${report.prediction.text}"`);
  L.push(`  ${report.prediction.verdict}`);
  L.push(`  ${report.prediction.note}`);
  L.push("");
  L.push("  Wave 3's 22.4% is a FLOOR, not the corpus rate: the commands the screen refuses");
  L.push("  are systematically more decay-prone than the ones it admits, so the true rate");
  L.push("  over everything ever stored is higher than any number on this page.");

  return L.join("\n");
}

export function toJson(report) {
  return {
    corpus: report.corpusName,
    timeout_ms: report.timeoutMs,
    include_test_runners: report.includeTestRunners,
    reach: report.reach,
    decisive: report.decisive,
    prediction: { ...report.prediction },
    by_outcome: Object.fromEntries(report.byOutcome),
    by_family: Object.fromEntries(report.byFamily),
    by_level: Object.fromEntries(report.byLevel),
    caveats: [
      "Every rate describes the admitted subset only and may not be restated as covering the whole command set.",
      "STILL-ANSWERING is not STILL-CORRECT — answer drift is unmeasured and out of scope for this wave.",
      "Inadmissible rows (environment faults, ambiguous silences) are excluded from both rates.",
      "The census writes nothing: no row here was stored in tooling/grip/ledger/.",
    ],
    rows: report.rows.map((r) => ({
      command: r.command, family: r.family, outcome: r.outcome, level: r.level,
      answering: r.answering, decayed: r.decayed, admissible: r.admissible,
      exit: r.exit ?? null, ms: r.ms ?? null, bytes: r.bytes ?? null, why: r.why,
    })),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// CORPUS + CLI
// ─────────────────────────────────────────────────────────────────────────────

export const CORPUS_PATH = fileURLToPath(new URL("./fixtures/evidence-corpus.json", import.meta.url));
export const CORPUS_NAME = "the frozen evidence corpus (tooling/grip/fixtures/evidence-corpus.json, proofs[].command)";

export function loadCorpusCommands(path = CORPUS_PATH) {
  const corpus = JSON.parse(readFileSync(path, "utf8"));
  return (corpus.proofs ?? []).map((p) => p?.command).filter((c) => typeof c === "string" && c.trim());
}

const HELP = `census.mjs — re-execute stored recipes and report whether they still ANSWER.

  node tooling/grip/census.mjs [--json] [--limit N] [--include-test-runners]

  --json                   machine render
  --limit N                bound the run while iterating
  --include-test-runners   also run go test / mix test (off by default: they
                           execute repo code the screen never examined)

Safety: every command is screened by tooling/grip/screen.mjs before any spawn.
The census never writes to tooling/grip/ledger/.`;

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  const argv = process.argv.slice(2);
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(HELP);
    process.exit(0);
  }
  const limitAt = argv.indexOf("--limit");
  const limit = limitAt >= 0 ? Number.parseInt(argv[limitAt + 1], 10) : Infinity;
  const commands = loadCorpusCommands().slice(0, Number.isFinite(limit) ? limit : undefined);
  const report = censusRun(commands, {
    corpusName: CORPUS_NAME,
    includeTestRunners: argv.includes("--include-test-runners"),
    onProgress: (i, n) => { if (i % 25 === 0 || i === n) process.stderr.write(`\r  screening/running ${i}/${n}   `); },
  });
  process.stderr.write("\r" + " ".repeat(40) + "\r");
  console.log(argv.includes("--json") ? JSON.stringify(toJson(report), null, 2) : renderHuman(report));
}
