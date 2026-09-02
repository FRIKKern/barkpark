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

import { execFileSync, spawnSync } from "node:child_process";
import { accessSync, constants, readFileSync, statSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { screenCommand } from "./screen.mjs";
import { deriveLevel, looksLikeProse } from "./level.mjs";
// THE READER ONLY. `foldLedger` is a pure read over the ledger's run files; no
// writer crosses this boundary, and the census's proof of that is a byte
// comparison of the directory across a real run, not this comment.
import { foldLedger } from "./ledger.mjs";
// The constant only — importing runRerun would put a second, differently-gated
// execution path inside the census.
import { SYNC_TIMEOUT_MS } from "./rerun.mjs";
// WHICH TREE EACH ANSWER IS ABOUT. Pure, read-time grammar — no fs, no spawn,
// no clock. `classifyBinding` labels one recipe; `classifyAll` folds a corpus
// into a class distribution. A census that reports OUTCOME alone is blind to a
// recipe that still ANSWERS from the wrong tree (D73): the same tree-sensitive
// recipe, run from two cwds, scores an identical healthy ANSWERED both times.
// The binding class is the field that finally distinguishes them.
import { classifyBinding, classifyAll, BINDING_CLASSES, PORTABLE_SCOPES } from "./binding.mjs";
// `emitProvenance` runs on stderr as the isMain block's first act (D78).
// `treeProvenance` + `provenanceLine` are ALSO folded into the human render on
// stdout so the census STATES which tree it ran in beside its answers — a
// "9 recipes still answer" line means nothing until the reader knows whose tree
// those 9 were about.
import { emitProvenance, treeProvenance, provenanceLine } from "./provenance.mjs";

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
 * Split a command into its pipeline segments, quote-masked.
 *
 * Extracted so FAMILY (which reads the TAIL, because `sh -c 'a | b'` exits with
 * b's status) and NETWORK REACH (which must read EVERY segment, because
 * `bp task ls | grep foo` touches the network in the head and exits with grep's
 * status) can share one splitter instead of hand-copying it — this epic's own
 * defect class.
 */
export function pipelineSegments(command) {
  const raw = String(command ?? "").trim();
  if (!raw) return [];

  // Quote-masked split so a pipe inside a quoted argument is not a segment
  // boundary. screen.mjs has already refused anything with `;`, `&&` or a
  // subshell, so the tail of a pipeline is the whole story here.
  // D67 — THE MASK FILLER IS WRITTEN AS `\0`, NEVER AS A RAW 0x00 BYTE.
  // A literal NUL byte lived here (offset 8398) and made file(1) call this
  // source "binary data", so every grep wrapper that skips binaries returned
  // ZERO LINES AND EXIT 1 where /usr/bin/grep counted 7 hits for the screen
  // call. An agent grepping census internals got a clean empty result
  // indistinguishable from genuine absence — one verifier concluded from it
  // that the census never screens at all, the exact opposite of the truth.
  // This epic's own disease, inside this epic's own instrument. The escape is
  // byte-identical at runtime; this comment deliberately does not spell the
  // screened function's name, so the census's own hit count stays the 7 the
  // defect report quotes.
  const masked = raw.replace(/'[^']*'|"[^"]*"/g, (m) => "\0".repeat(m.length));
  const bounds = [];
  for (let i = 0; i < masked.length; i += 1) if (masked[i] === "|" && masked[i + 1] !== "|") bounds.push(i);
  const segments = [];
  let from = 0;
  for (const b of bounds) {
    segments.push(raw.slice(from, b));
    from = b + 1;
  }
  segments.push(raw.slice(from));
  return segments.map((s) => s.trim()).filter(Boolean);
}

/**
 * The tokens of one segment with any env-var prefix stripped.
 *
 * ENV-VAR PREFIXES ARE NOT THE HEAD. `CC=clang go vet ./...` is a go vet, and
 * reading `CC=clang` as the head drops it into UNKNOWN — where its clean rc 0
 * with no output becomes an AMBIGUOUS-SILENCE instead of the PASS it is. This
 * is not hypothetical: 5 of the 6 admitted `go vet` rows in the frozen corpus
 * carry a `CC=` prefix (the cc-alias gotcha), so without this the census
 * discards the canonical green on every specimen it actually has.
 */
export function segmentTokens(segment) {
  const tokens = String(segment ?? "").trim().split(/\s+/).filter(Boolean);
  while (tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[0])) tokens.shift();
  return tokens;
}

/** The head of a segment, path-stripped: `/usr/bin/grep -n x` → `grep`. */
export function segmentHead(segment) {
  const tokens = segmentTokens(segment);
  return tokens.length ? tokens[0].replace(/^.*\//, "") : "";
}

/** The head of the command that produced the exit code — the LAST segment's. */
export function commandHead(command) {
  const segments = pipelineSegments(command);
  return segments.length ? segmentHead(segments[segments.length - 1]) : "";
}

/**
 * The family of a command, read off the LAST pipeline segment.
 *
 * `sh -c 'a | b'` exits with b's status (no pipefail), so the tool that
 * produced the exit code being classified is the tail, not the head.
 */
export function classifyFamily(command) {
  const segments = pipelineSegments(command);
  if (!segments.length) return FAMILY.UNKNOWN;
  const tokens = segmentTokens(segments[segments.length - 1]);
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
  // A BINARY THIS HOST LACKS IS NOT A ROTTED RECIPE. rc 127 is the shell saying
  // "I could not find that command", which is a fact about the PATH in front of
  // this process — the same class as WRONG-CWD and REF-GONE, and governed by the
  // rule this module already states for those: an environment fault says
  // something about THIS HOST and nothing about the stored recipe, so it leaves
  // the denominator. Scoring it as decay lets an operator with a lean PATH
  // publish a decay wave that a `brew install` erases.
  TOOL_ABSENT: "TOOL-ABSENT",
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
  // ── D68 — THE CENSUS WAS NOT HERMETIC ────────────────────────────────────
  //
  // 38 of the admitted rows reach a live service (bp, gh, curl). (That 38 was
  // counted against the pre-D63 reach of 240; tgw5-screen-hardening widened the
  // screen to 254/651, so 240 is a historical denominator — do not re-quote it
  // as the live admitted count.) Every one of those tools is a QUERY-LISTER
  // head, and QUERY-LISTER's failure branch is
  // RAN-AND-FAILED, which is in the DECAYED set — so ONE guerrilla or GitHub
  // hiccup flipped up to 36 rows to DECAYED against a published 14.6%. That is
  // a single-cause spike wearing the costume of 36 independent decay events:
  // an outage forging a decay wave, which is the precise fabrication this
  // module's rc-128 handling already refuses for git.
  //
  // The captured strings the three regexes above did NOT match:
  //   bp → "dial tcp 127.0.0.1:1: connect: connection refused"
  //   bp → "lookup api.example.invalid: no such host"
  //   gh → "error connecting to api.github.com"
  //
  // THE FIX IS DELIBERATELY NARROW. Every alternative below names a TRANSPORT
  // failure — a socket that never carried a request. A tool that connected and
  // answered "no" (gh's 404, bp's not_found, a non-2xx body) matches none of
  // them and stays RAN-AND-FAILED. Widening this into "the environment did it"
  // would launder real decay, which is worse than the bug it fixes.
  [/connect: connection refused|connection refused|no such host|error connecting to|dial tcp .*: (connect|lookup)|couldn'?t connect to server|failed to connect to|connection reset by peer|no route to host|temporary failure in name resolution|name or service not known|i\/o timeout|tls handshake timeout/i,
    OUTCOME.SPAWN_ERROR, "the transport failed before the service answered — this row measures the network on this host, not the ledger"],
];

// ── THE RESIDUAL NO REGEX CAN REACH ──────────────────────────────────────────
//
// `curl -s` is 27 of the corpus's 34 curl commands, and -s SUPPRESSES curl's
// own "Failed to connect" text: stderr comes back EMPTY with exit 7. There is
// no string for a pattern to match, so this one is keyed BY EXIT CODE.
//
//   6 → could not resolve host
//   7 → could not connect to host
//
// Both are transport faults by curl's own documented contract. Everything else
// curl can exit with is left alone: 22 (--fail on an HTTP >=400) is the SERVICE
// ANSWERING, and scoring that as an environment fault would delete exactly the
// decay signal the census exists to find.
const CURL_TRANSPORT_EXITS = new Map([
  [6, "curl could not resolve the host (exit 6) — DNS on this host, not the recipe"],
  [7, "curl could not connect (exit 7) — the socket never opened, so nothing about the recipe was measured"],
]);

/**
 * Tools whose success depends on a live service somewhere off this checkout.
 *
 * Read over EVERY pipeline segment, not just the tail: `bp task ls | grep foo`
 * exits with grep's status but still reached the network, and a run that hides
 * that dependency is claiming a hermeticity it does not have.
 */
const NETWORK_HEADS = new Set(["bp", "gh", "curl", "wget", "ssh", "scp", "rsync", "http", "httpie"]);
/** git sub-verbs that talk to a remote. The rest of git is local. */
const GIT_NETWORK_VERBS = new Set(["ls-remote", "fetch", "pull", "push", "clone"]);

/**
 * Which live service this command reaches, or null when it stays on this box.
 * Names the TOOL rather than a boolean so the render can say bp=21, gh=15.
 */
export function networkTool(command) {
  for (const segment of pipelineSegments(command)) {
    const tokens = segmentTokens(segment);
    if (!tokens.length) continue;
    const head = tokens[0].replace(/^.*\//, "");
    if (NETWORK_HEADS.has(head)) return head;
    if (head === "git") {
      const verb = tokens.slice(1).find((t) => !t.startsWith("-"));
      if (GIT_NETWORK_VERBS.has(verb)) return `git ${verb}`;
    }
  }
  return null;
}

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
  if (rc === 127) {
    const head = commandHead(command);
    return row(
      OUTCOME.TOOL_ABSENT,
      `${head || "the command"} is not on this host's PATH (exit 127) — a missing binary measures THIS HOST, not the recipe, so it is in NEITHER rate`,
    );
  }
  if (rc === 126) return row(OUTCOME.SPAWN_ERROR, "found but not executable — a permission fault on this host");

  // BY EXIT CODE, NOT BY STDERR — `curl -s` leaves stderr empty, so no pattern
  // can reach this row. Checked before the stderr faults precisely because
  // there is nothing there to check.
  if (commandHead(command) === "curl" && CURL_TRANSPORT_EXITS.has(rc)) {
    return row(OUTCOME.SPAWN_ERROR, CURL_TRANSPORT_EXITS.get(rc));
  }

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
  // EVERY row carries its binding class, refused and prose rows included — the
  // class is a function of the command string alone (binding.mjs is pure), so it
  // is known before a single spawn and survives even when the row never runs.
  // This is what lets a still-ANSWERING row also say WHICH TREE it answered
  // about: `git ls-tree HEAD …` is per-worktree ("this worktree"), a SHA-pinned
  // `git show <oid>:…` is content-addressed ("any clone"). The outcome field
  // cannot tell those apart; the binding class is the whole point of this slice.
  const base = { command: cmd, level: deriveLevel(cmd), binding: classifyBinding(cmd) };

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
  // A RATE OVER A HANDFUL OF ROWS IS NOT A RESULT. Found in review: `--limit 12`
  // admits 3 decisive rows, measures 0.0% decay and printed "CONSISTENT — below
  // the 22.4% floor", which is a bounded iteration run wearing a full census's
  // authority. Zero admissible was already handled; too-few-to-say was not, and
  // an underpowered pass is exactly the vacuous green this epic exists to
  // retire. The floor is deliberately blunt — it is a refusal to speak, not an
  // estimate of power.
  minAdmissible: 30,
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
  // `provenance` is measured by the CALLER (the CLI) and threaded through, never
  // measured here: summarise stays a pure fold, and treeProvenance's git spawn
  // stays out of the code path every classifier test exercises.
  return summarise(rows, {
    corpusName,
    includeTestRunners: !!opts.includeTestRunners,
    provenance: opts.provenance ?? null,
  });
}

/**
 * How much of this run left the box, split by tool.
 *
 * Counted over EXECUTED rows only — a refused or prose row reached nothing.
 * This is the census's hermeticity bound, and it is printed rather than
 * assumed: the decay rate of a run with network reach describes THIS HOST AT
 * THIS TIME, and quoting it as a property of the ledger is the level-skip.
 */
export function networkReach(rows) {
  const byTool = {};
  let reaching = 0;
  for (const r of rows) {
    if (!r.executed) continue;
    const tool = networkTool(r.command);
    if (!tool) continue;
    reaching += 1;
    byTool[tool] = (byTool[tool] || 0) + 1;
  }
  return { executedReaching: reaching, byTool };
}

// ─────────────────────────────────────────────────────────────────────────────
// TOOL AVAILABILITY — PROBED, NEVER ASSUMED
// ─────────────────────────────────────────────────────────────────────────────
//
// A decay rate is only readable beside the list of tools the host actually had.
// Without it, `bp`, `gh` and `go` missing from one operator's PATH reads exactly
// like 37 recipes rotting: measured on the frozen corpus, stripping those heads
// moved the run from 20.2% decayed (CONSISTENT) to 31.0% (CONTRARY) with not one
// byte of the ledger changed. TOOL-ABSENT keeps those rows out of the numerator;
// this header is what tells the reader WHICH tools the number is conditional on,
// including on the runs where nothing is missing.
//
// THE PROBE SPAWNS NOTHING. It walks the same PATH string the child shells
// inherit and asks the filesystem for an executable file, which is a `command
// -v` by other means — a real read of this host, not an assumption, and not one
// more thing the census executes. The census's execution set stays exactly what
// screenCommand admitted (D47).

/** POSIX shell builtins. `/bin/sh -c 'cd x'` needs no binary, so PATH says nothing about them. */
const SHELL_BUILTINS = new Set([
  ":", ".", "alias", "bg", "break", "cd", "command", "continue", "echo", "eval", "exec",
  "exit", "export", "false", "fg", "getopts", "hash", "jobs", "kill", "local", "printf",
  "pwd", "read", "readonly", "return", "set", "shift", "source", "test", "[", "times",
  "trap", "true", "type", "ulimit", "umask", "unalias", "unset", "wait",
]);

/** True when `p` is a file this process may execute. Every throw is an absence. */
function canExecute(p) {
  try {
    accessSync(p, constants.X_OK);
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

/**
 * Every distinct command head this run EXECUTED, with how many rows use it.
 *
 * Read over EVERY pipeline segment, not just the tail: `bp task ls | grep foo`
 * exits with grep's status, so the tail alone would report a run as fully
 * tooled while its head was missing. Rows the screen refused are excluded —
 * they reached no shell, so their heads say nothing about the rates.
 */
export function toolHeads(rows) {
  const heads = new Map();
  for (const r of rows ?? []) {
    if (!r?.executed) continue;
    for (const head of new Set(rowHeads(r.command))) heads.set(head, (heads.get(head) || 0) + 1);
  }
  return heads;
}

/** The raw first token of each segment — NOT path-stripped, so `./x.sh` stays resolvable. */
function rowHeads(command) {
  const out = [];
  for (const segment of pipelineSegments(command)) {
    const tokens = segmentTokens(segment);
    if (tokens.length) out.push(tokens[0]);
  }
  return out;
}

/**
 * Where one head resolves on this host, or that it does not resolve at all.
 *
 * @param {string} head raw token, e.g. `bp`, `/usr/bin/grep`, `./scripts/x.sh`
 */
export function resolveTool(head, { pathEnv = process.env.PATH ?? "", cwd = REPO_ROOT, isExecutable = canExecute } = {}) {
  if (SHELL_BUILTINS.has(head)) return { head, present: true, kind: "shell-builtin", at: null };
  if (head.includes("/")) {
    const at = isAbsolute(head) ? head : join(cwd, head);
    return isExecutable(at)
      ? { head, present: true, kind: "path-literal", at }
      : { head, present: false, kind: "path-literal", at: null };
  }
  for (const dir of pathEnv.split(":").filter(Boolean)) {
    const at = join(dir, head);
    if (isExecutable(at)) return { head, present: true, kind: "on-path", at };
  }
  return { head, present: false, kind: "on-path", at: null };
}

/**
 * The tool-availability header's data: which command heads this host had.
 *
 * Pure of spawns and injectable end to end (`pathEnv`, `isExecutable`) so a test
 * can prove BOTH directions — a head that resolves and a head that does not —
 * without depending on what happens to be installed on the machine running it.
 */
export function probeToolAvailability(rows, { pathEnv = process.env.PATH ?? "", cwd = REPO_ROOT, isExecutable = canExecute } = {}) {
  const heads = toolHeads(rows);
  const ordered = [...heads].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const present = [];
  const absent = [];
  const absentHeads = new Set();
  for (const [head, rowCount] of ordered) {
    const r = resolveTool(head, { pathEnv, cwd, isExecutable });
    const entry = { head, rows: rowCount, kind: r.kind, at: r.at };
    if (r.present) present.push(entry);
    else {
      absent.push(entry);
      absentHeads.add(head);
    }
  }
  let rowsDependingOnAbsent = 0;
  for (const r of rows ?? []) {
    if (!r?.executed) continue;
    if (rowHeads(r.command).some((h) => absentHeads.has(h))) rowsDependingOnAbsent += 1;
  }
  return {
    probed: heads.size,
    pathEntries: pathEnv.split(":").filter(Boolean).length,
    present,
    absent,
    presentHeads: present.map((e) => e.head),
    absentHeads: absent.map((e) => e.head),
    rowsDependingOnAbsent,
  };
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

export function summarise(rows, opts = {}) {
  const { corpusName = "(unnamed command set)", includeTestRunners = false, provenance = null } = opts;
  const count = (pred) => rows.filter(pred).length;
  const screened = rows.filter((r) => r.screened);
  const executed = rows.filter((r) => r.executed);
  const admissible = executed.filter((r) => r.admissible);
  const answering = admissible.filter((r) => r.answering);
  const decayed = admissible.filter((r) => r.decayed);

  // TOOL AVAILABILITY. Computed here rather than threaded from the CLI because
  // the header is a PRECONDITION of printing a rate, not an optional extra: a
  // caller that forgot to supply it would otherwise get a fully-rendered decay
  // number with nothing qualifying it. Passing `tools: null` EXPLICITLY is the
  // one way to get a report without it, and the renders then withhold the rate
  // rather than printing one. The probe reads the filesystem; it spawns nothing.
  const tools = "tools" in opts ? opts.tools : probeToolAvailability(rows, opts);
  // ORDER MATTERS: the probe runs AFTER the folds above, so a caller who hands
  // this function a REPORT instead of a row array still crashes on
  // `rows.filter` — the loud, named failure that test pins — rather than on a
  // less recognisable iteration error inside the probe.

  const byOutcome = new Map();
  for (const r of rows) byOutcome.set(r.outcome, (byOutcome.get(r.outcome) || 0) + 1);
  const byFamily = new Map();
  for (const r of executed) byFamily.set(r.family, (byFamily.get(r.family) || 0) + 1);
  const byLevel = new Map();
  for (const r of rows) byLevel.set(r.level, (byLevel.get(r.level) || 0) + 1);

  const pct = (n, d) => (d ? (n / d) * 100 : 0);
  const decayPct = pct(decayed.length, admissible.length);

  // BINDING — which tree each measured answer is about, folded over the WHOLE
  // corpus (classifyAll reads each row's command string; it never touches the
  // outcome). This is the distribution the census was blind to: a corpus can be
  // 100% STILL-ANSWERING and still be answering from a tree that is not the
  // reader's. Computed from the command alone so synthetic test rows that carry
  // no `.binding` field classify identically to real ones.
  const binding = classifyAll(rows);

  return {
    corpusName,
    includeTestRunners,
    provenance,
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
      // ROWS THAT HIT A MISSING BINARY. In NEITHER rate, and counted so the
      // exclusion is visible instead of being a silently smaller denominator.
      toolAbsent: count((r) => r.outcome === OUTCOME.TOOL_ABSENT),
      // COUNTED, not asserted. An earlier brief put this at 5 (against the
      // pre-D63 admitted reach of 240, since widened to 254 by
      // tgw5-screen-hardening — that 240 is historical, not the live count);
      // measuring it over the same corpus gives 58 (15 `go test`, 43 `mix
      // test`). The census reports what it counted and lets the discrepancy be
      // visible — quoting the smaller inherited number would be the level-skip.
      testRunnerHeads: testRunnerHeads(rows),
      // HERMETICITY, named. Every row counted here depends on a service this
      // census does not control.
      network: networkReach(rows),
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
        : admissible.length < PREDICTION.minAdmissible
        ? `UNDERPOWERED — ${admissible.length} decisive rows is below the ${PREDICTION.minAdmissible}-row floor for saying anything about this prediction. Measured decay is ${decayPct.toFixed(1)}%, reported as an observation only, NOT as consistent or contrary.`
        : decayPct < PREDICTION.floorPct
          ? `CONSISTENT — measured ${decayPct.toFixed(1)}% is below the ${PREDICTION.floorPct}% floor`
          : `CONTRARY — measured ${decayPct.toFixed(1)}% is at or above the ${PREDICTION.floorPct}% floor, and that is reported as the result it is`,
    },
    byOutcome,
    byFamily,
    byLevel,
    binding,
    tools,
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
  // NO RATE WITHOUT THE TOOL-AVAILABILITY HEADER. The banner is the first place
  // a number could escape, so the refusal starts here rather than lower down.
  const tools = report.tools;
  L.push(
    decisive.admissible === 0
      ? `CENSUS — no admissible rows: nothing was measured, and no rate is reported.`
      : !tools
      ? `CENSUS — ${decisive.admissible} decisive rows measured; NO RATE IS REPORTED because this run has no tool-availability probe beside it.`
      : `CENSUS — ${decisive.answeringPct.toFixed(1)}% of ${decisive.admissible} decisive recipes STILL ANSWER; ${decisive.decayPct.toFixed(1)}% decayed.`,
  );
  // WHICH TREE THE CENSUS ITSELF RAN IN. Supplied by the caller so this render
  // stays pure; the same fact goes to stderr via emitProvenance at CLI start,
  // and here to stdout so a saved render carries it too. A rate over N recipes
  // is meaningless until the reader knows whose tree produced it.
  if (report.provenance) L.push(provenanceLine(report.provenance));
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

  // HERMETICITY — printed on every run, including the runs where it is zero,
  // because "this run touched nothing off the box" is itself the finding.
  const net = reach.network ?? { executedReaching: 0, byTool: {} };
  const netSplit = Object.entries(net.byTool).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}=${n}`).join(", ");
  L.push("NETWORK REACH — how much of this run was NOT hermetic");
  L.push(`  executed rows reaching a live service  ${net.executedReaching} of ${reach.executed}${netSplit ? `  (${netSplit})` : ""}`);
  if (net.executedReaching === 0) {
    L.push("  This run touched nothing off this checkout, so no service outage could have");
    L.push("  contributed to the rates below.");
  } else {
    L.push("  Those rows depend on services this census does not control. Every rate below");
    L.push("  therefore describes THIS HOST AT THIS TIME and is NOT a stable property of the");
    L.push("  corpus: re-run it during an outage and the same recipes read differently.");
    L.push("  Transport failures (connection refused, no such host, curl exit 6/7) are");
    L.push("  classified SPAWN-ERROR and leave BOTH rates — an outage must not publish");
    L.push("  itself as decay. A service that connected and answered 'no' still counts.");
  }
  L.push("");

  // TOOL AVAILABILITY — the header that makes the rates below readable. Printed
  // on every run, including the runs where nothing is missing, because "every
  // head this run needed was installed" is exactly the fact a decay rate is
  // conditional on. PROBED against this process's PATH, never assumed.
  if (tools) {
    const list = (entries, cap = 14) => {
      const names = entries.map((e) => `${e.head}${e.rows > 1 ? `(${e.rows})` : ""}`);
      return names.length <= cap ? names.join(", ") : `${names.slice(0, cap).join(", ")}, …and ${names.length - cap} more`;
    };
    L.push("TOOL AVAILABILITY ON THIS HOST — probed against this process's PATH, not assumed");
    L.push(`  command heads probed  ${tools.probed} distinct, over ${tools.pathEntries} PATH entries`);
    L.push(`  present               ${tools.present.length}${tools.present.length ? `  ${list(tools.present)}` : ""}`);
    L.push(`  ABSENT                ${tools.absent.length}${tools.absent.length ? `  ${list(tools.absent)}` : "  — every head this run executed resolves here"}`);
    L.push(`  rows hitting one      ${tools.rowsDependingOnAbsent}   scored TOOL-ABSENT: ${reach.toolAbsent ?? 0}`);
    if (tools.absent.length) {
      L.push("  A HEAD LISTED ABSENT IS A FACT ABOUT THIS BOX, NOT ABOUT THE LEDGER. Every row");
      L.push("  that hit one exits 127 and is classified TOOL-ABSENT, which is in NEITHER rate");
      L.push("  below — install the tool and those rows re-enter the measurement unchanged. The");
      L.push("  rates below are therefore conditional on this list: read them together or not");
      L.push("  at all.");
    } else {
      L.push("  Nothing the rates below rest on was missing, so no share of the decay figure is");
      L.push("  a missing binary wearing a rotted recipe's costume.");
    }
    L.push("");
  }

  // BINDING CLASS — the distribution this census was built blind to. Sourced
  // from binding.mjs, folded over the whole corpus. It answers a question the
  // outcome column cannot: not "did it answer" but "which TREE did it answer
  // about". A run can be 100% STILL-ANSWERING and every one of those answers be
  // about a tree that is not the reader's.
  const b = report.binding;
  if (b && b.total > 0) {
    L.push("BINDING CLASS — which tree each answer is about (from binding.mjs, most portable first)");
    for (const cls of BINDING_CLASSES) {
      const n = b.by_class[cls] ?? 0;
      L.push(`  ${String(n).padStart(4)}  ${cls.padEnd(20)}${PORTABLE_SCOPES[cls]}`);
    }
    if (b.unclassified > 0) {
      L.push(`  ${String(b.unclassified).padStart(4)}  ${"(unclassified)".padEnd(20)}prose or no command — there is no tree to name`);
    }
    L.push("");
    const anyClone = b.by_class["content-addressed"] ?? 0;
    const notYours = b.classified - anyClone;
    L.push(`  ${notYours} of ${b.classified} classified recipes answer about a tree that is NOT NECESSARILY`);
    L.push("  yours — only a content-addressed (SHA-pinned) read resolves identically in any");
    L.push("  clone. `git ls-tree HEAD …` answers about THIS worktree; `origin/main:…` about");
    L.push("  any worktree of THIS clone; a bare relative read about THIS cwd. Same healthy");
    L.push("  ANSWERED outcome, different trees — the binding class is the field that says so.");
    L.push("");
    // THE ONE GUARD THAT LOOKS LIKE COVERAGE AND IS NOT. Do not let a reader
    // credit WRONG-CWD with catching this class.
    L.push("  WRONG-CWD does NOT cover this class. It fires ONLY outside a git repository");
    L.push("  entirely (stderr 'not a git repository'), so it never fires inside any worktree");
    L.push("  of any clone — which is every tree this census ever runs in. A wrong-TREE answer");
    L.push("  is a clean ANSWERED, not a WRONG-CWD; the binding class is the only signal here.");
    L.push("");
  }

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

  if (!tools) {
    L.push("NO RATE — THE TOOL-AVAILABILITY PROBE DID NOT RUN.");
    L.push("  Without it this render cannot tell the reader what share of the rows below");
    L.push("  failed because a binary is missing on this host rather than because a recipe");
    L.push("  rotted — and a missing `bp`, `gh` or `go` alone has moved this corpus from");
    L.push("  CONSISTENT to CONTRARY. A decay rate published without that list beside it is a");
    L.push("  number claiming an authority it did not earn, so it is WITHHELD rather than");
    L.push("  printed with a disclaimer nobody reads.");
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
  const tools = report.tools;
  return {
    corpus: report.corpusName,
    timeout_ms: report.timeoutMs,
    include_test_runners: report.includeTestRunners,
    reach: report.reach,
    // THE SAME REFUSAL THE HUMAN RENDER MAKES. A machine consumer that reads
    // `decay_pct` out of this document is doing what the banner does, so the
    // rate is nulled here too when no probe ran — a JSON escape hatch around a
    // human-render guard is the guard not existing.
    decisive: tools
      ? report.decisive
      : {
          ...report.decisive,
          answeringPct: null,
          decayPct: null,
          rate_withheld: "no tool-availability probe ran, so a missing binary cannot be told from a rotted recipe — see tool_availability",
        },
    prediction: { ...report.prediction },
    by_outcome: Object.fromEntries(report.byOutcome),
    by_family: Object.fromEntries(report.byFamily),
    by_level: Object.fromEntries(report.byLevel),
    // WHICH TREE THE ANSWERS ARE ABOUT — the machine mirror of the render's
    // binding-class section. `provenance` names the tree the census RAN in;
    // `binding` names the tree each recipe's answer is ABOUT.
    provenance: report.provenance
      ? {
          tree: report.provenance.root ?? null,
          head: report.provenance.head_short ?? null,
          differs_from_origin_main: report.provenance.differs_from_origin ?? null,
          dirty: report.provenance.dirty ?? null,
        }
      : null,
    // WHICH TOOLS THIS HOST HAD. The machine mirror of the render's
    // tool-availability header; `absent` is the list every rate above is
    // conditional on.
    tool_availability: tools
      ? {
          probed: tools.probed,
          path_entries: tools.pathEntries,
          present: tools.present,
          absent: tools.absent,
          rows_hitting_an_absent_head: tools.rowsDependingOnAbsent,
          rows_scored_tool_absent: report.reach?.toolAbsent ?? 0,
        }
      : null,
    binding: report.binding
      ? {
          by_class: report.binding.by_class,
          by_portable_scope: report.binding.by_portable_scope,
          classified: report.binding.classified,
          unclassified: report.binding.unclassified,
          default_rule_share: report.binding.default_rule.share,
        }
      : null,
    caveats: [
      "Every rate describes the admitted subset only and may not be restated as covering the whole command set.",
      "A command head missing from this host's PATH exits 127 and is scored TOOL-ABSENT, which is in NEITHER rate: it measures this box, not the ledger. Read `tool_availability.absent` beside every rate above — the same corpus moved from 20.2% decayed to 31.0% on a host without bp, gh and go before that class existed.",
      "STILL-ANSWERING is not STILL-CORRECT — answer drift is unmeasured and out of scope for this wave.",
      "Inadmissible rows (environment faults, ambiguous silences) are excluded from both rates.",
      "The census writes nothing: no row here was stored in tooling/grip/ledger/.",
      "A recipe's binding class names WHICH TREE its answer is about; only content-addressed reads answer identically in any clone, and WRONG-CWD does not cover the wrong-tree class (it fires only outside a git repo entirely).",
    ],
    rows: report.rows.map((r) => ({
      command: r.command, family: r.family, outcome: r.outcome, level: r.level,
      binding_class: r.binding?.binding_class ?? null,
      portable_scope: r.binding?.portable_scope ?? null,
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

// ─────────────────────────────────────────────────────────────────────────────
// THE LEDGER AS A CORPUS — `--ledger`
// ─────────────────────────────────────────────────────────────────────────────
//
// The frozen fixture is a QUARRY: 1,902 historical strings harvested from
// everywhere, most of which nobody ever promised were re-derivable. The ledger
// is the PRODUCT: rows that passed admitRecipe's gate at write time. Censusing
// the product rather than the quarry is the only way the decay number describes
// what this epic actually ships.
//
// Nothing here writes. `foldLedger` is a pure read over the run files, and the
// census's no-mutation proof is a byte comparison of the directory across a
// real run, not a promise in a comment.

export const LEDGER_DIR = fileURLToPath(new URL("./ledger/", import.meta.url));
export const LEDGER_CORPUS_NAME = "the durable recipe ledger (tooling/grip/ledger/, entries[].recipes[].rerun)";

/**
 * Fold the ledger and flatten it to the flat string[] the engine takes.
 *
 * DEDUPED TO ONE RECIPE PER (subject, quantity) BY DEFAULT, because a key's
 * rival recipes re-derive THE SAME QUANTITY and running all of them buys
 * repetition rather than coverage. Measured at ee49d2b7f2 (2026-07-21) on a
 * synthetic 400-row store: 17,343ms over every recipe against 5,043ms
 * one-per-key — ~3.4x the wall clock for a 37% larger set. The ratio is the
 * durable claim; the corpus size is a stated snapshot, not the live store.
 *
 * BUT THE RIVALS ARE NOT SILENTLY DISCARDED. `summarise`'s report has no field
 * for `rival_methods` or `unreadable`, so flattening to a bare string[] would
 * drop both without a trace — a census whose input quietly shrank and never
 * said so. The counts ride back on the returned envelope and are printed above
 * the census proper.
 */
// THE READ-PATH BOUNDS, read from the shell exactly as ledger.mjs's write path
// reads them (`date -u`, UTC/Z-form). The library owns no clock and imports no
// screen (D19); the census is the caller, so IT supplies `date -u` and
// screenCommand to the fold. Without them, a FUTURE-OBSERVED-AT row (composed,
// not observed) and a REFUSED-COMMAND rerun (outage-capable) fold clean through
// the product read path while writeLedgerRun refuses both — the D66 read-path
// residual this closes.
function shellNow() {
  return execFileSync("date", ["-u", "+%Y-%m-%dT%H:%M:%SZ"], { encoding: "utf8" }).trim();
}

export function loadLedgerRecipes(dir = LEDGER_DIR, { allRivals = false } = {}) {
  const folded = foldLedger(dir, { now: shellNow(), screen: screenCommand });
  const commands = [];
  let skippedRivals = 0;
  for (const entry of folded.entries) {
    const distinct = [...new Set(entry.recipes.map((r) => String(r?.rerun ?? "").trim()).filter(Boolean))];
    if (allRivals) commands.push(...distinct);
    else {
      commands.push(...distinct.slice(0, 1));
      skippedRivals += Math.max(0, distinct.length - 1);
    }
  }
  return {
    dir,
    allRivals,
    commands,
    skippedRivals,
    stats: folded.stats,
    rivalMethods: folded.rival_methods,
    unreadable: folded.unreadable,
  };
}

/**
 * The pre-census block — the fold's own facts, before a single recipe runs.
 *
 * These four numbers exist NOWHERE in the census report. An operator who reads
 * only the census sees a rate over N commands and cannot tell whether rows were
 * unreadable or rivals were skipped to get there.
 */
export function renderLedgerPreamble(source) {
  const s = source.stats;
  const L = [];
  L.push("LEDGER — the store this census is pointed at, before anything ran");
  L.push(`  directory        ${source.dir}`);
  L.push(`  run files        ${s.runs}`);
  L.push(`  rows folded      ${s.rows}`);
  L.push(`  subjects         ${s.subjects}   one (subject, quantity) key each`);
  L.push(`  rival methods    ${s.rival_methods}   keys carrying more than one distinct recipe`);
  L.push(`  unreadable       ${s.unreadable}   rows or files the fold could not use — NOT counted as decay`);
  // THE DRIFT THE FOLD ABSORBED, SAID OUT LOUD. `foldLedger` re-derives the
  // quantity half of every key (and `derived_level`) from the command rather
  // than trusting the row, because the mint's grammar moved after the rows were
  // written and the store is immutable. Absorbing that silently would make the
  // clean "0 rival methods" above look like a property of the DATA when it is a
  // property of the READ — at e8bbba5919 (2026-07-21), 57 of the 62 committed
  // rows carried a stored key that commit's mint no longer produced. That is a
  // named past snapshot, not a live count: the store grows without touching this
  // file, so the figure is never restated with a fresh total (D102). A FALLBACK
  // is the one that bites: it is the only way the fold can still be keying on a
  // stale value, so it prints even at zero once any restatement happened.
  if (s.quantity_restated > 0 || s.level_restated > 0 || s.quantity_fallbacks > 0 || s.level_fallbacks > 0) {
    L.push(
      `  key re-derived   ${s.quantity_restated ?? 0} quantity, ${s.level_restated ?? 0} level` +
        `   stored value disagrees with what the command mints TODAY — the fold keys on the re-derivation`,
    );
    L.push(
      `  fell back        ${s.quantity_fallbacks ?? 0} quantity, ${s.level_fallbacks ?? 0} level` +
        `   re-derivation could not answer, so the STORED value is the key — never silent`,
    );
  }
  L.push(`  recipes censused ${source.commands.length}${source.allRivals
    ? "   --all-rivals: every distinct recipe, including rivals"
    : `   one per key by default; ${source.skippedRivals} rival recipe(s) NOT run (add --all-rivals)`}`);
  if (s.unreadable > 0) {
    L.push("");
    L.push("  UNREADABLE ROWS ARE A FINDING ABOUT THE STORE, NOT ABOUT DECAY. They never");
    L.push("  entered the census, so they are in neither rate below:");
    for (const u of source.unreadable.slice(0, 10)) L.push(`    ${u.message ?? `${u.reason} ${u.file ?? ""}`}`);
    if (source.unreadable.length > 10) L.push(`    …and ${source.unreadable.length - 10} more`);
  }
  if (s.rival_methods > 0 && !source.allRivals) {
    L.push("");
    L.push("  RIVAL METHODS ARE A FEATURE OF THE ROW, NOT A DEFECT. Each flagged key has");
    L.push("  more than one independent way to re-derive the same quantity. This run used");
    L.push("  ONE per key for wall-clock reasons and did not compare their answers:");
    for (const f of source.rivalMethods.slice(0, 5)) L.push(`    ${f.rivals.length} recipes for ${JSON.stringify(f.quantity)} of ${JSON.stringify(f.subject)}`);
    if (source.rivalMethods.length > 5) L.push(`    …and ${source.rivalMethods.length - 5} more`);
  }
  L.push("");
  return L.join("\n");
}

const HELP = `census.mjs — re-execute stored recipes and report whether they still ANSWER.

  node tooling/grip/census.mjs [--ledger] [--json] [--limit N]
                              [--include-test-runners] [--all-rivals]

  --ledger                 census the DURABLE LEDGER (tooling/grip/ledger/)
                           instead of the frozen evidence fixture. The fixture
                           is a quarry of historical strings; the ledger is what
                           this epic actually ships.
  --all-rivals             with --ledger, run every distinct recipe per key
                           instead of one (~3.4x the wall clock, no new coverage
                           — the rivals re-derive the same quantity)
  --json                   machine render
  --limit N                bound the run while iterating
  --include-test-runners   also run go test / mix test (off by default: they
                           execute repo code the screen never examined)

Unknown flags are REJECTED with exit 2. A flag silently ignored is the same
defect class as a bound that silently unbounds itself.

Safety: every command is screened by tooling/grip/screen.mjs before any spawn.
The census only ever READS tooling/grip/ledger/.`;

// A FLAG SILENTLY IGNORED IS A REQUEST SILENTLY DENIED. `--totally-bogus-flag`
// used to exit 0 having run the default census, which reads to an operator (and
// to a gate) exactly like the flag worked — the same class as the `--limit NaN`
// defect that turned a bounded run into a 651-command one. Named rejection,
// exit 2, and the valid set is printed.
export const KNOWN_FLAGS = Object.freeze([
  "--help", "-h", "--json", "--limit", "--include-test-runners", "--ledger", "--all-rivals",
]);

/**
 * @returns {{ok:true}|{ok:false, reason:string}}
 */
export function validateArgv(argv) {
  const known = new Set(KNOWN_FLAGS);
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--limit") { i += 1; continue; } // its value is checked separately
    if (known.has(token)) continue;
    return {
      ok: false,
      reason: token.startsWith("-")
        ? `unknown flag ${JSON.stringify(token)} — valid flags are ${KNOWN_FLAGS.join(" ")}`
        : `unexpected argument ${JSON.stringify(token)} — this CLI takes flags only, and ignoring it would look exactly like honouring it`,
    };
  }
  return { ok: true };
}

// Same main-module test the rest of tooling/grip uses. String-comparing
// `file://${argv[1]}` against import.meta.url is NOT equivalent: any character
// the URL encodes (a space, a `#`) makes the two differ, and the failure is
// SILENT — the CLI becomes a no-op that exits 0 having measured nothing, which
// reads exactly like a clean run.
const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  // FIRST ACT, BEFORE ANY ANSWER (D78). A census run that says "9 recipes"
  // means nothing until the operator knows WHICH tree's ledger it counted.
  // STDERR only — `--json` writes a document to stdout and a banner there
  // would break every `JSON.parse(stdout)` consumer.
  emitProvenance();

  const argv = process.argv.slice(2);
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(HELP);
    process.exit(0);
  }
  // A BOUND THAT SILENTLY UNBOUNDS ITSELF IS THE EPIC'S OWN DEFECT CLASS.
  // `--limit` with a missing or non-numeric value used to parse to NaN, fail
  // the isFinite test and run the ENTIRE 651-command corpus — the operator
  // asked for a bounded run and got an unbounded one with no signal. Named
  // rejection, nonzero exit.
  const valid = validateArgv(argv);
  if (!valid.ok) {
    process.stderr.write(`census: ${valid.reason}\n`);
    process.exit(2);
  }
  const limitAt = argv.indexOf("--limit");
  let limit = Infinity;
  if (limitAt >= 0) {
    limit = Number.parseInt(argv[limitAt + 1] ?? "", 10);
    if (!Number.isInteger(limit) || limit < 1) {
      process.stderr.write(`census: --limit needs a positive integer, got ${JSON.stringify(argv[limitAt + 1] ?? null)}\n`);
      process.exit(2);
    }
  }

  const useLedger = argv.includes("--ledger");
  if (!useLedger && argv.includes("--all-rivals")) {
    process.stderr.write("census: --all-rivals only means something with --ledger — the fixture has no (subject, quantity) keys to have rivals over\n");
    process.exit(2);
  }

  const ledgerSource = useLedger ? loadLedgerRecipes(LEDGER_DIR, { allRivals: argv.includes("--all-rivals") }) : null;
  const all = useLedger ? ledgerSource.commands : loadCorpusCommands();
  const commands = all.slice(0, Number.isFinite(limit) ? limit : undefined);

  // THE CALL SHAPE. `censusRun` is SYNCHRONOUS and calls `summarise` itself —
  // it hands back the finished report. Re-summarising its return throws
  // "rows.filter is not a function", which cost a verifier a crash.
  const report = censusRun(commands, {
    corpusName: useLedger ? `${LEDGER_CORPUS_NAME} at ${ledgerSource.dir}` : CORPUS_NAME,
    includeTestRunners: argv.includes("--include-test-runners"),
    // WHICH TREE THIS CENSUS RAN IN. REPO_ROOT is where census.mjs lives on disk
    // AND the default cwd shell() hands every recipe (D73's seam), so its
    // provenance is exactly the tree the answers are bound to. Measured here,
    // in the CLI, so summarise stays a pure fold with no git spawn.
    provenance: treeProvenance({ cwd: REPO_ROOT }),
    onProgress: (i, n) => { if (i % 25 === 0 || i === n) process.stderr.write(`\r  screening/running ${i}/${n}   `); },
  });
  process.stderr.write("\r" + " ".repeat(40) + "\r");

  if (argv.includes("--json")) {
    const json = toJson(report);
    if (useLedger) {
      json.ledger = {
        dir: ledgerSource.dir,
        all_rivals: ledgerSource.allRivals,
        recipes_censused: ledgerSource.commands.length,
        skipped_rival_recipes: ledgerSource.skippedRivals,
        ...ledgerSource.stats,
      };
    }
    console.log(JSON.stringify(json, null, 2));
  } else {
    if (useLedger) console.log(renderLedgerPreamble(ledgerSource));
    console.log(renderHuman(report));
  }
}
