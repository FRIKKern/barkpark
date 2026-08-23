#!/usr/bin/env node
// Proof for the rerun EXECUTOR — tooling/grip/rerun.mjs.
//
//   node --test tooling/grip/test/rerun.test.mjs
//
// HERMETIC BY CONSTRUCTION. Every assertion below runs with no external network
// and no ssh credentials, because a gate whose own proof needs the world to be
// up is exactly the failure mode this module exists to prevent. The four
// measured (code, exit) pairs from prod are asserted against the PURE
// classifier; the live-network variants are opt-in behind GRIP_LIVE=1.
//
// The crux under test: a wrong route, a downed host, an unrunnable probe and an
// empty read are FOUR different things, and only some of them may become a fact.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  runRerun, classifyHttp, classifySafety, classifyScope, mixEnvOf, isBuildWarm, probeHttp,
  blankQuotedSpans, classifyFamily, classifySilence,
  admitsPassClaim, admitsAbsenceClaim, assertAbsenceClaim,
  VERDICT, SCOPE, FAMILY, GripError,
} from "../rerun.mjs";

// ── INVOCATION-AGNOSTIC BY CONSTRUCTION ──────────────────────────────────────
// rerun.mjs's shell() spawns `/bin/sh -c` with NO cwd, so every command below
// inherits whatever directory `node --test` was invoked from. Repo-root-relative
// literals therefore made the suite report 29/30 from the root and 27/30 from
// inside tooling/grip/ — a tally that moves with the caller is not a proof.
// Everything cwd-sensitive resolves off THIS FILE instead, and interpolates
// through JSON.stringify so a path with a space or a quote cannot re-parse.
const RERUN_MJS = JSON.stringify(fileURLToPath(new URL("../rerun.mjs", import.meta.url)));
const REPO_ROOT = JSON.stringify(fileURLToPath(new URL("../../../", import.meta.url)));

// ── 1. REACHABILITY KEYS ON THE PAIR, NEVER THE CODE ALONE ───────────────────
// Measured live from this worktree on 2026-07-20 — all four reproduced:
//   http://89.167.28.206/api/schemas       code=200 exit=0
//   http://89.167.28.206/api/health        code=404 exit=0   REACHABLE, WRONG ROUTE
//   https://api.barkpark.cloud/api/schemas code=404 exit=0   reachable, wrong plane
//   http://10.255.255.1/api/schemas        code=000 exit=28  HOST UNREACHABLE

test("the four measured (code, exit) pairs land on four distinct verdicts", () => {
  assert.deepEqual(classifyHttp(200, 0), { verdict: VERDICT.OK, reachable: true });
  assert.deepEqual(classifyHttp(404, 0), { verdict: VERDICT.WRONG_ROUTE, reachable: true });
  assert.deepEqual(classifyHttp(0, 28), { verdict: VERDICT.UNREACHABLE, reachable: false });
  assert.deepEqual(classifyHttp(0, 7), { verdict: VERDICT.UNREACHABLE, reachable: false });
});

test("404-reachable and 000-unreachable are NOT merged into 'non-200'", () => {
  // If these ever collapse, an outage can forge a pass-shaped absence claim.
  const wrongRoute = classifyHttp(404, 0);
  const worldDown = classifyHttp(0, 28);
  assert.notEqual(wrongRoute.verdict, worldDown.verdict);
  assert.equal(wrongRoute.reachable, true);
  assert.equal(worldDown.reachable, false);
});

test("a 404 from a LIVE host may support an absence claim; a downed host may NOT", () => {
  // The host answered 404 — the route genuinely is not there.
  assert.equal(admitsAbsenceClaim({ verdict: VERDICT.WRONG_ROUTE }), true);
  // The host said nothing at all — this is the outage-forges-absence hole.
  assert.equal(admitsAbsenceClaim({ verdict: VERDICT.UNREACHABLE }), false);
});

test("code, exit and reachable come back as SEPARATE fields (live, loopback only)", () => {
  const r = runRerun("curl -s http://127.0.0.1:1/definitely-not-a-real-endpoint");
  assert.equal(r.verdict, VERDICT.UNREACHABLE);
  assert.equal(r.code, 0);          // no HTTP status was ever received
  assert.ok(r.exit === 7 || r.exit === 28, `expected curl transport failure, got exit ${r.exit}`);
  assert.equal(r.reachable, false); // tri-state, not folded into code
  assert.equal(r.admits.pass, false);
  assert.equal(r.admits.absence, false);
});

test("a downed host reads HOST-UNREACHABLE, never ASYNC-DEFERRED", () => {
  // Regression: the literal `curl` carries no --max-time, so running it FIRST
  // let an unroutable host block until the sync ceiling and come back as "too
  // expensive" when the truth was "the world is down". The bounded probe now
  // runs first, so the verdict names the real reason and returns promptly.
  const r = runRerun("curl -s http://127.0.0.1:1/definitely-not-a-real-endpoint", { timeoutMs: 2000 });
  assert.equal(r.verdict, VERDICT.UNREACHABLE);
  assert.notEqual(r.verdict, VERDICT.ASYNC_DEFERRED);
  assert.ok(r.ms < 1500, `should fail fast on a refused connection, took ${r.ms}ms`);
});

test("reachable is TRI-STATE — null when the command is not an HTTP probe", () => {
  const r = runRerun("git rev-parse --show-toplevel");
  assert.equal(r.reachable, null); // NOT false — unknown must never impersonate down
});

// ── 1b. THE PROBE URL IS UNTRUSTED INPUT, AND NO SHELL PARSES IT ─────────────
// probeHttp once built a `/bin/sh -c` string with the URL double-quoted, and
// double quotes do NOT stop `$( )`. Proven live in this worktree before the fix:
// probing `http://localhost:1/$(echo INJECTED > /tmp/INJMARK)` CREATED the file
// while curl itself failed exit 7 — the substitution ran before curl did, so the
// request never had to succeed. HTTP_URL (the regex that harvests the URL out of
// a rerun command) excludes whitespace, quotes, pipe and angle brackets but
// permits `$ ( ) `` — and it is deliberately NOT tightened here, because a
// denylist on an injection sink is the failure this epic exists to name.
//
// These assertions are shape-sensitive by construction: they pass ONLY while the
// spawn is an argument vector. Restore the shell-string form and the marker gets
// created, failing the first test — the mutation was run, not assumed.

test("a command substitution in the probe URL does NOT execute — argv, not a shell string", () => {
  const marker = join(mkdtempSync(join(tmpdir(), "grip-inj-")), "INJMARK");
  // The payload is a WRITE, so the filesystem itself is the witness.
  const probe = probeHttp(`http://127.0.0.1:1/$(echo INJECTED > ${JSON.stringify(marker).slice(1, -1)})`, 2000);
  assert.equal(existsSync(marker), false, "a shell expanded the URL — the substitution ran");
  // curl received the metacharacters as inert data and rejected the literal URL
  // (exit 3 = URL malformed). Under the shell form curl never saw them at all.
  assert.notEqual(probe.exit, 0, "a malformed literal URL must not report success");
  assert.equal(probe.code, 0, "no HTTP status was ever received");
});

test("backticks and `;` in the probe URL are inert data too", () => {
  const marker = join(mkdtempSync(join(tmpdir(), "grip-inj-")), "TICKMARK");
  const lit = JSON.stringify(marker).slice(1, -1);
  probeHttp(`http://127.0.0.1:1/\`echo T > ${lit}\``, 2000);
  probeHttp(`http://127.0.0.1:1/;echo T > ${lit}`, 2000);
  assert.equal(existsSync(marker), false, "a shell parsed the URL");
});

test("classifySafety rates the INJECTION safe — which is why argv, not the gate, is the fix", () => {
  // This is the tell, pinned so nobody re-solves the sink with a better denylist.
  // The identical injection reads UNSAFE only when its payload happens to be a
  // WRITE_SHAPES name; swap in a verb the list does not carry and it goes safe.
  assert.equal(classifySafety("curl -s http://localhost/$(touch /tmp/x)").safe, false);
  assert.equal(classifySafety("curl -s http://localhost/$(reboot)").safe, true);
});

// ── 2. UNAVAILABLE — neither a pass nor a rejection ──────────────────────────
// ssh is ambient HOST state. Measured 2026-07-20: `ssh root@89.167.28.206 true`
// exits 0 from this laptop with the operator's key; the same command is denied
// from a machine without it, and CI has neither. So availability is PROBED, and
// the test uses hosts that deny everywhere rather than hardcoding a prod truth.

test("an ssh probe that cannot authenticate yields UNAVAILABLE", () => {
  const r = runRerun("ssh -o BatchMode=yes -o ConnectTimeout=1 nobody@127.0.0.1 true");
  assert.equal(r.verdict, VERDICT.UNAVAILABLE);
  assert.equal(r.admits.pass, false, "UNAVAILABLE must never read as a pass");
  assert.equal(r.admits.absence, false, "UNAVAILABLE must never read as a rejection");
});

test("an ssh probe to an unresolvable host yields UNAVAILABLE, not a failure", () => {
  const r = runRerun("ssh -o BatchMode=yes -o ConnectTimeout=1 root@no-such-host.invalid true");
  assert.equal(r.verdict, VERDICT.UNAVAILABLE);
  assert.notEqual(r.verdict, VERDICT.FAILED);
});

test("a missing binary yields UNAVAILABLE rather than a refutation", () => {
  const r = runRerun("__no_such_binary_xyz_9f3a --version");
  assert.equal(r.verdict, VERDICT.UNAVAILABLE);
  assert.equal(r.exit, 127);
  assert.equal(r.admits.absence, false);
});

// ── 3. NULL-READ — an empty read may NEVER become an absence claim ───────────
// A surveyor reported a fixture as 0 bytes. It is 2693 bytes in the working
// tree, 2693 on origin/main, and 2693 in all 993 worktree copies. No 0-byte
// artifact existed anywhere — a read returned empty and became a fact.

test("exit 0 with empty stdout is NULL-READ, not success", () => {
  const r = runRerun("true");
  assert.equal(r.verdict, VERDICT.NULL_READ);
  assert.equal(r.stdoutBytes, 0);
  assert.equal(r.admits.pass, false);
});

test("assertAbsenceClaim REFUSES to promote a NULL-READ into an absence claim", () => {
  const r = runRerun("true");
  assert.equal(admitsAbsenceClaim(r), false);
  assert.throws(
    () => assertAbsenceClaim(r, "the fixture is 0 bytes"),
    (e) => e instanceof GripError && /REFUSED: NULL-READ/.test(e.message),
  );
});

test("grep's exit 1 is a REAL no-match, not a NULL-READ", () => {
  // The one tool whose empty output is a genuine read. Conflating it with
  // NULL-READ would make the gate reject every legitimate absence proof.
  const r = runRerun(`grep 'zzz_no_such_string_9f3a' ${RERUN_MJS}`);
  assert.equal(r.exit, 1);
  assert.equal(r.verdict, VERDICT.FAILED);
  assert.equal(admitsAbsenceClaim(r), true);
});

test("a real read comes back OK with bytes", () => {
  const r = runRerun(`grep -c 'VERDICT' ${RERUN_MJS}`);
  assert.equal(r.verdict, VERDICT.OK);
  assert.ok(r.stdoutBytes > 0);
  assert.equal(admitsPassClaim(r), true);
});

// ── 3b. SILENCE IS CLASSIFIED BY TOOL FAMILY FIRST, EXIT CODE SECOND (D50) ───
//
// The pre-family rule protected grep BY NAME and nothing else. Reproduced by
// running the shipped module on 2026-07-21, from this worktree:
//
//   diff README.md NOPE.mjs  → exit 2, 0 bytes, FAILED, admits.absence = TRUE
//   grep -n zzz NOPE.mjs     → exit 2, 0 bytes, NULL-READ, admits.absence = false
//
// One tool error; two opposite rulings. For everything that is not grep, a
// missing operand MANUFACTURED an absence claim — strictly worse than dropping
// a true answer, and the D6 failure class one tool from where D6 was patched.
//
// There is no flat repair. grep's rc1 is "no match" (an ABSENCE) while diff's
// rc1 is "differences found" — measured at 33,609 bytes of real content in the
// probe below. "Any rc1 is a real read" would let a diff that FOUND something be
// cited as proof that something is MISSING: a polarity inversion, not a fix.

const ADJUDICATE_MJS = JSON.stringify(fileURLToPath(new URL("../adjudicate.mjs", import.meta.url)));

test("FAIL-BEFORE: a differ that could not open its operand may NOT claim absence", () => {
  // THE DEFECT. Pre-fix this returned verdict=FAILED with admits.absence=true:
  // a tool error laundered into "the thing is not there".
  const r = runRerun(`diff ${RERUN_MJS} /no/such/path/NOPE_9f3a.mjs`);
  assert.equal(r.exit, 2, "diff exits 2 when it cannot open an operand");
  assert.equal(r.stdoutBytes, 0, "it compared nothing, so it read nothing");
  assert.equal(r.verdict, VERDICT.NULL_READ, `a tool error is a null read, got ${r.verdict}: ${r.reason}`);
  assert.equal(admitsAbsenceClaim(r), false, "THE BUG: this must never support an absence claim");
  assert.equal(admitsPassClaim(r), false);
  assert.throws(() => assertAbsenceClaim(r, "the file is absent"), GripError);
});

test("the differ's rc1 is a DIFFERENCE with content, never an absence", () => {
  // The polarity trap. This ran, answered decisively and carries bytes — so it
  // is NOT a null read — yet "these two files differ" is not evidence that
  // anything is missing. Measured on this host: 33,609 bytes.
  const r = runRerun(`diff ${RERUN_MJS} ${ADJUDICATE_MJS}`);
  assert.equal(r.exit, 1);
  assert.equal(r.family, FAMILY.DIFFER);
  assert.ok(r.stdoutBytes > 1000, `differences carry content, got ${r.stdoutBytes} bytes`);
  assert.notEqual(r.verdict, VERDICT.NULL_READ, "a run that produced 33kB is not a null read");
  assert.equal(admitsAbsenceClaim(r), false, "differences-found is a PRESENCE answer");
});

test("grep's two exit codes did not regress — rc1 admits, rc2 does not", () => {
  // The one family that was already correct. A fix that broke it would trade one
  // false claim for a fleet of discarded true ones.
  const noMatch = runRerun(`grep 'zzz_no_such_string_9f3a' ${RERUN_MJS}`);
  assert.equal(noMatch.exit, 1);
  assert.equal(noMatch.family, FAMILY.MATCHER);
  assert.equal(admitsAbsenceClaim(noMatch), true, "rc1 is a genuine no-match");

  const toolError = runRerun("grep -n zzz_9f3a /no/such/path/NOPE_9f3a.mjs");
  assert.ok(toolError.exit >= 2, `expected a matcher tool error, got exit ${toolError.exit}`);
  assert.equal(toolError.verdict, VERDICT.NULL_READ);
  assert.equal(admitsAbsenceClaim(toolError), false);
});

test("the two rc1s are OPPOSITE, and the table keeps them opposite", () => {
  // The single assertion that a blanket "rc1 means absence" cannot satisfy.
  const grepRc1 = runRerun(`grep 'zzz_no_such_string_9f3a' ${RERUN_MJS}`);
  const diffRc1 = runRerun(`diff ${RERUN_MJS} ${ADJUDICATE_MJS}`);
  assert.equal(grepRc1.exit, 1);
  assert.equal(diffRc1.exit, 1);
  assert.equal(admitsAbsenceClaim(grepRc1), true);
  assert.equal(admitsAbsenceClaim(diffRc1), false);
});

test("a QUERY-LISTER's rc0 with no rows is an EMPTY SET, not a discarded read", () => {
  // 12 non-grep silent-PASS specimens — including a clean `go vet`, the
  // canonical green — were thrown away as NULL-READ. rc0 + empty is the ANSWER.
  const noCommits = runRerun(`git -C ${REPO_ROOT} log --oneline --grep=zzz_no_such_commit_9f3a`);
  assert.equal(noCommits.exit, 0);
  assert.equal(noCommits.family, FAMILY.QUERY_LISTER);
  assert.equal(noCommits.verdict, VERDICT.OK, `an empty set is an answer, got ${noCommits.reason}`);
  assert.equal(admitsPassClaim(noCommits), true);

  const noFiles = runRerun(`git -C ${REPO_ROOT} ls-files -- tooling/grip/NOPE_9f3a.mjs`);
  assert.equal(noFiles.exit, 0);
  assert.equal(noFiles.verdict, VERDICT.OK);

  // The canonical green, ruled on purely — no Go toolchain required to prove it.
  const goVet = classifySilence("go vet ./...", { exit: 0, stdout: "", stderr: "" });
  assert.equal(goVet.family, FAMILY.QUERY_LISTER);
  assert.equal(goVet.verdict, VERDICT.OK);
});

test("a PREDICATE answers with its exit code alone, and silence is the answer", () => {
  const isAncestor = runRerun("git merge-base --is-ancestor HEAD HEAD");
  assert.equal(isAncestor.family, FAMILY.PREDICATE);
  assert.equal(isAncestor.exit, 0);
  assert.equal(isAncestor.stdoutBytes, 0, "a predicate prints nothing by design");
  assert.equal(isAncestor.verdict, VERDICT.OK, `silence IS the answer here, got ${isAncestor.reason}`);
  // …and the false arm is a real refutation, not a null read.
  assert.equal(classifySilence("test -f /nope", { exit: 1 }).verdict, VERDICT.FAILED);
  assert.equal(classifySilence("test -f /nope", { exit: 2 }).verdict, VERDICT.NULL_READ);
});

// ── 3c. FOUR SEMANTICS SHARE EXIT 128 — the discriminator is STDERR ──────────
// Keying decay on rc128 alone lets a worktree that never fetched `origin`
// report the ENTIRE ledger as decayed: an outage forging a decay wave. All
// three wordings below were captured from this host's git on 2026-07-21.

test("CONTENT-FETCH rc128 'does not exist in' is PATH-GONE — real, admissible decay", () => {
  const r = runRerun(`git -C ${REPO_ROOT} show HEAD:tooling/grip/NOPE_9f3a.mjs`);
  assert.equal(r.exit, 128);
  assert.equal(r.family, FAMILY.CONTENT_FETCH);
  assert.match(r.stderr, /does not exist in/);
  assert.equal(r.verdict, VERDICT.FAILED, "the ref RESOLVED and the path is genuinely not in it");
  assert.equal(admitsAbsenceClaim(r), true);
});

test("CONTENT-FETCH rc128 'invalid object name' is REF-GONE — an environment fault", () => {
  // Same exit code, opposite meaning: the ref never resolved, so the read never
  // happened. Admitting this is how an unfetched worktree forges a decay wave.
  const r = runRerun(`git -C ${REPO_ROOT} show no_such_ref_9f3a:README.md`);
  assert.equal(r.exit, 128);
  assert.match(r.stderr, /invalid object name/);
  assert.equal(r.verdict, VERDICT.UNAVAILABLE);
  assert.equal(admitsAbsenceClaim(r), false, "an unresolvable ref may NEVER be reported as decay");
  assert.equal(admitsPassClaim(r), false);
});

test("CONTENT-FETCH rc128 'not a git repository' is WRONG-CWD — an environment fault", () => {
  const outside = mkdtempSync(join(tmpdir(), "grip-nogit-"));
  try {
    const r = runRerun(`git -C ${JSON.stringify(outside)} show HEAD:README.md`);
    assert.equal(r.exit, 128);
    assert.match(r.stderr, /not a git repository/);
    assert.equal(r.verdict, VERDICT.UNAVAILABLE);
    assert.equal(admitsAbsenceClaim(r), false, "running in the wrong directory proves nothing");
  } finally { rmSync(outside, { recursive: true, force: true }); }
});

test("the three rc128 semantics are ruled apart by MESSAGE, never by the code", () => {
  // Asserting the VERDICT alone is not enough to hold this rule: three of the
  // four cases end in UNAVAILABLE, so deleting the ref-gone branch entirely
  // leaves a verdict-only test green (verified by mutation). Each branch must be
  // pinned by the REASON it gives, or the discriminator is untested.
  const at = (stderr) => classifySilence("git show REF:path", { exit: 128, stdout: "", stderr });

  const pathGone = at("fatal: path 'x' does not exist in 'HEAD'");
  assert.equal(pathGone.verdict, VERDICT.FAILED);
  assert.match(pathGone.reason, /the ref resolved and the path is NOT in it/);
  assert.equal(at("fatal: path 'x' exists on disk, but not in 'HEAD'").verdict, VERDICT.FAILED);

  const refGone = at("fatal: invalid object name 'origin/main'.");
  assert.equal(refGone.verdict, VERDICT.UNAVAILABLE);
  assert.match(refGone.reason, /the ref could not be resolved here/,
    "an unfetched origin must be named as an environment fault, not left to the catch-all");

  const wrongCwd = at("fatal: not a git repository (or any of the parent directories): .git");
  assert.equal(wrongCwd.verdict, VERDICT.UNAVAILABLE);
  assert.match(wrongCwd.reason, /not a git repository here/);

  // An unrecognised 128 fails CLOSED: inadmissible, never decay.
  const unknown = at("fatal: something nobody has seen before");
  assert.equal(unknown.verdict, VERDICT.UNAVAILABLE);
  assert.match(unknown.reason, /unrecognised/);

  // THE DEFECT THIS RULE EXISTS FOR: if rc128 alone decided, every one of these
  // would be decay, and one unfetched worktree would forge a whole decay wave.
  const decayed = [pathGone, refGone, wrongCwd, unknown]
    .filter((r) => admitsAbsenceClaim({ ...r, absenceEligible: r.absenceEligible }));
  assert.equal(decayed.length, 1, "exactly ONE of the four rc128 shapes may be read as decay");
});

// ── 3d. the family is read from the HEAD TOKEN of the last pipeline stage ────

test("family dispatch keys on the head token, not on a loose word match", () => {
  assert.equal(classifyFamily("grep -n foo x.md"), FAMILY.MATCHER);
  assert.equal(classifyFamily("LC_ALL=C /usr/bin/grep -n foo x.md"), FAMILY.MATCHER);
  // THE NEAR MISS: `--grep=` contains "grep". Read as a MATCHER, a clean commit
  // search (rc0, empty) would be graded "exited 0 yet printed nothing".
  assert.equal(classifyFamily("git log --oneline --grep=zzz"), FAMILY.QUERY_LISTER);
  assert.equal(classifySilence("git log --oneline --grep=zzz", { exit: 0, stdout: "" }).verdict, VERDICT.OK);
  // git's global options must not hide the subcommand.
  assert.equal(classifyFamily("git -C /tmp show HEAD:x.md"), FAMILY.CONTENT_FETCH);
  assert.equal(classifyFamily("git -c core.pager=cat diff --quiet -- x"), FAMILY.DIFFER);
  assert.equal(classifyFamily("git diff -- x"), FAMILY.QUERY_LISTER);
  // cmp -s answers with its exit code; bare cmp prints the first difference.
  assert.equal(classifyFamily("cmp -s a b"), FAMILY.PREDICATE);
  assert.equal(classifyFamily("cmp a b"), FAMILY.DIFFER);
});

test("a pipeline is classified by its LAST stage, because that owns the exit code", () => {
  assert.equal(classifyFamily("git show HEAD:notes.md | grep -c NEEDLE"), FAMILY.MATCHER);
  assert.equal(classifyFamily("ls -la | wc -l"), FAMILY.UNKNOWN);
  // A quoted pipe is DATA, not a pipeline.
  assert.equal(classifyFamily(`grep -n 'a | b' x.md`), FAMILY.MATCHER);
});

test("an && / || / ; list keeps the conservative UNKNOWN default", () => {
  // For `a || b` the exit code belongs to a when a SUCCEEDS and to b when it
  // does not, so the provenance is genuinely ambiguous — guessing a family here
  // would attach one tool's grammar to another tool's exit code.
  assert.equal(classifyFamily("go vet ./... || true"), FAMILY.UNKNOWN);
  assert.equal(classifyFamily("cd x && grep -n foo y.md"), FAMILY.UNKNOWN);
  assert.equal(classifySilence("go vet ./... || true", { exit: 0, stdout: "" }).verdict, VERDICT.NULL_READ);
});

test("an unrecognised tool keeps the pre-family behaviour EXACTLY", () => {
  // The table must not quietly widen what counts as an answer. Anything it does
  // not recognise still falls to "exit 0 with no output is a NULL-READ".
  const r = runRerun("true");
  assert.equal(r.family, FAMILY.UNKNOWN);
  assert.equal(r.verdict, VERDICT.NULL_READ);
  assert.equal(classifySilence("some-unknown-tool --x", { exit: 0, stdout: "" }).verdict, VERDICT.NULL_READ);
  assert.equal(classifySilence("some-unknown-tool --x", { exit: 3, stderr: "boom" }).verdict, VERDICT.FAILED);
});

test("a bare {verdict} object still rules exactly as it did before the table", () => {
  // admitsAbsenceClaim gained a second input (absenceEligible). Callers that
  // pass a bare verdict — including this suite's own section 1 — must be unmoved.
  assert.equal(admitsAbsenceClaim({ verdict: VERDICT.FAILED }), true);
  assert.equal(admitsAbsenceClaim({ verdict: VERDICT.WRONG_ROUTE }), true);
  assert.equal(admitsAbsenceClaim({ verdict: VERDICT.NULL_READ }), false);
  // …and the veto only bites when a family has PROVEN the answer is not absence.
  assert.equal(admitsAbsenceClaim({ verdict: VERDICT.FAILED, absenceEligible: false }), false);
});

// ── 4. SCOPE + BUILD WARMTH ──────────────────────────────────────────────────
// Measured: git show 94-337ms, scoped grep 149ms, curl 264-633ms (SYNC) vs
// corpus acceptance 39.3s, coverage scan 28.7s, CI mix test 605s (ASYNC). Build
// warmth is the third input: a targeted mix test is ~4s warm, 81.74s cold.

test("bounded lookups are SYNC-ADMISSIBLE", () => {
  assert.equal(classifyScope("git show origin/main:README.md").scope, SCOPE.SYNC);
  assert.equal(classifyScope("grep -n foo tooling/grip/rerun.mjs").scope, SCOPE.SYNC);
  assert.equal(classifyScope("curl -s http://127.0.0.1:4000/api/schemas").scope, SCOPE.SYNC);
});

test("measured-heavy commands are ASYNC-DEFERRED", () => {
  assert.equal(classifyScope("node tooling/doc-truth/acceptance.mjs").scope, SCOPE.ASYNC);
  assert.equal(classifyScope("node tooling/research-coverage/coverage.mjs scan").scope, SCOPE.ASYNC);
  assert.equal(classifyScope("make rebuild").scope, SCOPE.ASYNC);
});

test("an Elixir command is ASYNC-DEFERRED on a COLD build", () => {
  const cold = mkdtempSync(join(tmpdir(), "grip-cold-"));
  try {
    const c = classifyScope("mix test api/test/foo_test.exs", cold);
    assert.equal(c.scope, SCOPE.ASYNC);
    assert.match(c.reason, /api\/_build\/test\/lib\/barkpark absent/);
  } finally { rmSync(cold, { recursive: true, force: true }); }
});

test("the SAME Elixir command is SYNC-ADMISSIBLE once api/_build/<env>/lib/barkpark exists", () => {
  // Warmth, not the tool, flips the classification — this is the whole point of
  // D8: "scope decides, not tool" is insufficient for Elixir.
  const warm = mkdtempSync(join(tmpdir(), "grip-warm-"));
  try {
    mkdirSync(join(warm, "api", "_build", "test", "lib", "barkpark"), { recursive: true });
    assert.equal(isBuildWarm("mix test api/test/foo_test.exs", warm), true);
    assert.equal(classifyScope("mix test api/test/foo_test.exs", warm).scope, SCOPE.SYNC);
    // ...and still ASYNC for an env whose build is cold.
    assert.equal(classifyScope("MIX_ENV=dev mix compile", warm).scope, SCOPE.ASYNC);
  } finally { rmSync(warm, { recursive: true, force: true }); }
});

test("mixEnvOf reads the env the command will actually build against", () => {
  assert.equal(mixEnvOf("mix test foo"), "test");
  assert.equal(mixEnvOf("mix compile"), "dev");
  assert.equal(mixEnvOf("MIX_ENV=prod mix compile"), "prod");
});

test("a command that outruns the sync ceiling is ASYNC-DEFERRED, never a failure", () => {
  const r = runRerun("sleep 5", { timeoutMs: 300 });
  assert.equal(r.verdict, VERDICT.ASYNC_DEFERRED);
  assert.equal(r.admits.pass, false);
  assert.equal(r.admits.absence, false, "a timeout must not refute anything");
});

// ── 5. IT ACTUALLY EXECUTES ──────────────────────────────────────────────────
// doc-truth's verifyCommand (verify-docs.mjs:883-897) returns "confirmed" when
// the binary resolves on PATH, so it confirmed all four of these. Each must now
// come back as something other than a pass.

test("the four commands doc-truth falsely 'confirmed' are no longer confirmed", () => {
  const bogusGit = runRerun("git show origin/main:api/THIS_FILE_DOES_NOT_EXIST.ex");
  assert.equal(bogusGit.verdict, VERDICT.FAILED);
  assert.equal(bogusGit.exit, 128);
  assert.equal(admitsPassClaim(bogusGit), false, "PATH-resolution is not execution");
  // A tool that RAN and answered 'no' is a genuine refutation.
  assert.equal(admitsAbsenceClaim(bogusGit), true);

  const deadPort = runRerun("curl -s http://127.0.0.1:1/definitely-not-a-real-endpoint");
  assert.equal(admitsPassClaim(deadPort), false);

  const coldMix = runRerun("mix test --only nonexistent_tag_xyz", { root: mkdtempSync(join(tmpdir(), "grip-mix-")) });
  assert.equal(coldMix.verdict, VERDICT.ASYNC_DEFERRED);
  assert.equal(admitsPassClaim(coldMix), false);
});

test("a command that genuinely succeeds still reads OK — the gate is not just strict", () => {
  // WAS VACUOUS. This accepted `[OK, FAILED].includes(verdict) && ran && ms >= 0`
  // over an unanchored `git show HEAD:tooling/grip/rerun.mjs`. Run from a
  // directory with no git repository at all it returns
  // {verdict: FAILED, exit: 128, stdoutBytes: 0} — and PASSED. A test that
  // passes whether or not the tool found anything proves nothing about the tool.
  //
  // Now: the file is KNOWN to be committed, so a real read is the only
  // acceptable answer — exit 0 with bytes. `git -C <repo root>` anchors the
  // read to the repo instead of the caller's cwd, so the assertion can be this
  // strict without becoming a statement about where `node --test` was invoked.
  const r = runRerun(`git -C ${REPO_ROOT} show HEAD:tooling/grip/rerun.mjs`);
  assert.equal(r.verdict, VERDICT.OK, `got ${r.verdict}: ${r.reason}`);
  assert.equal(r.exit, 0, "a committed file must read back cleanly, not merely 'decisively'");
  assert.ok(r.stdoutBytes > 0, `a real read has bytes, got ${r.stdoutBytes}`);
  assert.equal(r.ran, true);
  assert.ok(r.ms >= 0);
});

// ── 6. SAFETY — refused BEFORE execution ─────────────────────────────────────

test("a --write command is refused UNSAFE-RERUN without executing", () => {
  const r = runRerun("node tooling/doc-truth/remake.mjs --write");
  assert.equal(r.verdict, VERDICT.UNSAFE_RERUN);
  assert.equal(r.ran, false, "must refuse BEFORE execution, not after");
  assert.equal(r.exit, null);
  assert.match(r.reason, /--write/);
  assert.equal(r.admits.pass, false);
});

test("write-shaped verbs are refused across the surface", () => {
  for (const cmd of [
    "rm -rf api/_build",
    "git push origin main",
    "git commit -m x",
    "curl -X POST http://127.0.0.1:4000/v1/data/mutate",
    "curl -s -d '{}' http://127.0.0.1:4000/v1/x",
    "bp doc publish task foo",
    "psql -c 'DROP TABLE docs'",
    "sed -i '' s/a/b/ README.md",
    "node x.mjs > out.json",
  ]) {
    assert.equal(classifySafety(cmd).safe, false, `should refuse: ${cmd}`);
  }
});

test("a 'read-only' COMMENT is not evidence — coverage.mjs scan is refused anyway", () => {
  // coverage.mjs documents `scan` as "(read-only)" at line 8 and writes
  // coverage-report.json at line 75. The classifier trusts the read, not the doc.
  const s = classifySafety("node tooling/research-coverage/coverage.mjs scan");
  assert.equal(s.safe, false);
  assert.match(s.reason, /known writer/);
});

test("genuinely read-only commands are NOT refused", () => {
  for (const cmd of [
    "git show origin/main:README.md",
    "grep -n foo tooling/grip/rerun.mjs",
    "curl -s http://127.0.0.1:4000/api/schemas",
    "ls -la api/_build",
    "node x.mjs 2>/dev/null",
  ]) {
    assert.equal(classifySafety(cmd).safe, true, `should allow: ${cmd}`);
  }
});

// ── 6b. QUOTE AWARENESS — a write VERB is not a write ────────────────────────
//
// The safety regexes describe SHELL SYNTAX. Scanned raw they also matched the
// same characters sitting inside a quoted ARGUMENT, so these five read-only
// commands were all refused UNSAFE-RERUN. That is D3's failure mode inside the
// gate: punish honest work and the honest path gets routed around.

test("a write verb or a '>' INSIDE a quoted argument no longer refuses a pure read", () => {
  for (const cmd of [
    `grep -n "a > b" README.md`,
    `grep -rn "npm publish instructions" docs/README.md`,
    `git log --grep="publish flow"`,
    `git show HEAD:docs/notes.md | grep "must mutate state before publish"`,
    `grep -n "chmod 644 is required" docs/setup.md`,
    `grep -n 'rm -rf is destructive' docs/setup.md`,
  ]) {
    const s = classifySafety(cmd);
    assert.equal(s.safe, true, `should allow (reads nothing but text): ${cmd} — got ${s.reason}`);
  }
});

test("blanking is 1:1 and touches ONLY quoted spans, so unquoted syntax survives", () => {
  // Offsets preserved: a reported match still lines up with the original.
  const cmd = `grep -n "a > b" x.md > out.json`;
  const blanked = blankQuotedSpans(cmd);
  assert.equal(blanked.length, cmd.length, "blanking must be length-preserving");
  assert.equal(blanked, `grep -n         x.md > out.json`);
  // …and the surviving, genuinely-unquoted redirect is still caught.
  assert.equal(classifySafety(cmd).safe, false);
  assert.match(classifySafety(cmd).reason, /output redirection/);
});

test("an UNTERMINATED quote falls back to the raw scan rather than blanking a tail", () => {
  // Blanking to end-of-string would hide everything after a stray quote.
  assert.equal(blankQuotedSpans(`grep 'oops > out.json`), null);
  assert.equal(classifySafety(`grep 'oops > out.json`).safe, false);
});

test("QUOTED CODE IS STILL CODE — an interpreter's quoted argument is scanned RAW", () => {
  // The trap inside the fix: for these, the quoted string is not data being
  // read, it is the program being executed. Naive blanking makes every one of
  // them falsely safe.
  for (const cmd of [
    `sh -c 'rm -rf /tmp/y'`,
    `/bin/sh -c "rm -rf /tmp/y"`,
    `bash -e -c 'git push origin main'`,
    `psql -c 'DROP TABLE docs'`,
    `psql -U bp -d barkpark -c "DELETE FROM documents"`,
    `sqlite3 db.sqlite -e 'DROP TABLE t'`,
    `node -e 'require("fs").rmSync("/tmp/y")'`,
    `python3 -c 'import os; os.remove("/tmp/y")'`,
    `perl -e 'rm -rf y'`,
    `awk '{system("rm -rf /tmp/y")}' f.txt`,
    `eval 'rm -rf /tmp/y'`,
    `xargs -I{} rm -rf {}`,
    `ssh host 'rm -rf /tmp/y'`,
  ]) {
    assert.equal(classifySafety(cmd).safe, false, `quoted code must stay refused: ${cmd}`);
  }
});

test("the quote fix did not reopen any shape section 6 already refused", () => {
  // Fail-before/pass-after on the pre-existing denylist: every one of these was
  // refused before quote awareness and must still be refused after it.
  for (const cmd of [
    "rm -rf api/_build",
    "git push origin main",
    "git commit -m x",
    "curl -X POST http://127.0.0.1:4000/v1/data/mutate",
    "curl -s -d '{}' http://127.0.0.1:4000/v1/x",
    "bp doc publish task foo",
    "psql -c 'DROP TABLE docs'",
    "sed -i '' s/a/b/ README.md",
    "node x.mjs > out.json",
    "node tooling/research-coverage/coverage.mjs scan",
  ]) {
    assert.equal(classifySafety(cmd).safe, false, `must stay refused: ${cmd}`);
  }
});

// ── 6c. THE MERGE-BASE CARVE-OUT — the one widening, and its fence ───────────
//
// `\bmerge\b` matched inside `merge-base`, so `git merge-base --is-ancestor A B`
// was refused UNSAFE-RERUN: the epic's own D40 merge-by-content rule and every
// stranded-branch ancestry check could not be re-run by its own instrument
// (11 of 652 corpus commands, 1.7%). The fix is `merge(?!-base)`, and it sits
// INSIDE the safety allowlist — so the protective half matters more than the
// fix. A widening no one fenced is how "fixing safety" becomes weakening it.

test("git merge-base --is-ancestor is re-runnable — the epic can check its own merge proof", () => {
  const s = classifySafety("git merge-base --is-ancestor abc123 origin/main");
  assert.equal(s.safe, true, `should allow a pure ancestry read — refused as ${s.reason}`);
  assert.equal(classifySafety("git merge-base HEAD origin/main").safe, true);
  // …and it actually runs, rather than merely classifying.
  const r = runRerun("git merge-base --is-ancestor HEAD HEAD");
  assert.notEqual(r.verdict, VERDICT.UNSAFE_RERUN);
  assert.equal(r.exit, 0);
});

test("PROTECTIVE: every real git merge is STILL refused after the carve-out", () => {
  // The lookahead is five characters wide. If it ever widens to `merge.*` or the
  // entry is dropped, every line here goes green and this module starts running
  // commands that rewrite the working tree.
  for (const cmd of [
    "git merge",
    "git merge --abort",
    "git merge --continue",
    "git merge origin/main",
    "git merge --no-ff feature/x",
    "git -C /tmp/repo merge origin/main",
    "git merge -s ours origin/main",
    "git mergetool",
  ]) {
    const s = classifySafety(cmd);
    assert.equal(s.safe, false, `MUST STAY REFUSED: ${cmd}`);
    assert.match(s.reason, /git write verb|write-shaped/, `refused for the right reason: ${cmd}`);
  }
  // The rest of the git denylist is untouched by the carve-out.
  for (const cmd of [
    "git push origin main", "git commit -m x", "git checkout main", "git switch main",
    "git reset --hard origin/main", "git rebase origin/main", "git clean -fd",
    "git apply p.patch", "git am p.patch", "git tag v1", "git stash",
  ]) {
    assert.equal(classifySafety(cmd).safe, false, `MUST STAY REFUSED: ${cmd}`);
  }
});

test("a git GLOBAL OPTION no longer hides the write verb behind it", () => {
  // FOUND BY WRITING THE PROTECTIVE TEST ABOVE, and verified against
  // origin/main's own module on 2026-07-21: every one of these classified SAFE
  // there, and runRerun would have EXECUTED it. `git -C <path>` is precisely how
  // an agent reaches ANOTHER worktree, so the blast radius was other people's
  // working trees. This is a TIGHTENING; nothing about it widens the gate.
  for (const cmd of [
    "git -C /tmp/repo push origin main",
    "git -C /tmp/repo commit -m x",
    "git -C /tmp/repo merge origin/main",
    "git -C /tmp/repo reset --hard origin/main",
    "git --no-pager reset --hard origin/main",
    "git -c user.name=x commit -m y",
    "git --git-dir=/tmp/r/.git checkout main",
  ]) {
    assert.equal(classifySafety(cmd).safe, false, `a global option must not launder a write verb: ${cmd}`);
  }
  // …while the same global options in front of a READ still pass. Tightening
  // the gate must not cost the honest path (D3).
  for (const cmd of [
    "git -C /tmp merge-base --is-ancestor A B",
    "git -C /tmp show HEAD:README.md",
    "git --no-pager diff --stat",
    "git -c core.pager=cat log --oneline",
  ]) {
    const s = classifySafety(cmd);
    assert.equal(s.safe, true, `MUST ALLOW: ${cmd} — refused as ${s.reason}`);
  }
});

test("a SEPARATED-VALUE git global no longer launders the write verb behind it", () => {
  // Wave-11 verification measured this against origin/main's own module
  // (re-verified at head 2260a0efb7 on 2026-08-23): the alternation consumed
  // `-c`/`-C` <value> pairs and attached `--flag=value` forms, but a SEPARATED
  // `--git-dir <value>` left its value token standing between the globals and
  // the verb, so the verb never matched — classifySafety returned
  // {safe:true, reason:"no write shape detected"} for all seven globals below
  // across every write verb, and runRerun gates on classifySafety ALONE
  // (rerun.mjs runRerun step 1), so it would have EXECUTED the write. 7×12=84
  // of the 108 cells in the nine-globals × twelve-verbs matrix laundered.
  // screenCommand refuses all 108 (dropValueGlobals, PR #12180) — but that is
  // the OTHER module; the executing gate was blind. This is a TIGHTENING.
  const SEPARATED_LAUNDER_GLOBALS = [
    "--git-dir", "--work-tree", "--namespace", "--exec-path",
    "--super-prefix", "--attr-source", "--config-env",
  ];
  const WRITE_VERBS = [
    "push", "commit", "checkout", "switch", "reset", "rebase",
    "mergetool", "merge", "clean", "apply", "am", "tag",
  ];
  for (const g of SEPARATED_LAUNDER_GLOBALS) {
    for (const v of WRITE_VERBS) {
      const cmd = `git ${g} VAL ${v} x`;
      const s = classifySafety(cmd);
      assert.equal(s.safe, false, `laundered shape MUST be refused: ${cmd} — got safe:true (${s.reason})`);
    }
  }
  // The two the old alternation already consumed stay refused, and `stash`
  // (13th denylist verb) is covered through a separated global too.
  assert.equal(classifySafety("git -C /tmp/repo push origin main").safe, false);
  assert.equal(classifySafety("git -c user.name=x commit -m y").safe, false);
  assert.equal(classifySafety("git --git-dir /tmp/r/.git stash").safe, false);
});

test("separated-value globals in front of a READ stay admitted — the permit arm", () => {
  // Tightening the gate must not cost the honest path (D3). Each of these
  // rulings was ADMIT at head before the fix and must stay ADMIT after it.
  for (const cmd of [
    "git -C /tmp/repo log -1",
    "git -C /Volumes/SATECHI/github/barkpark status",
    "git --git-dir /tmp/repo/.git log -1",
    "git --work-tree /tmp/repo status",
    "git --config-env GIT_PAGER=P log --oneline",
    "git --no-pager log -1",
  ]) {
    const s = classifySafety(cmd);
    assert.equal(s.safe, true, `MUST ADMIT: ${cmd} — refused as ${s.reason}`);
  }
});

test("opts.root IS the execution cwd — a rerun's verdict must not depend on where the caller was invoked", () => {
  // Measured live during the tgw11 build: the full grip suite red/greened purely
  // by invocation directory — seal.test.mjs's polarity specimen
  // `diff tooling/grip/record.mjs tooling/grip/provenance.mjs` ruled NULL-READ
  // from a tooling/grip cwd and FAILED from the repo root, because runRerun
  // spawned /bin/sh -c with NO cwd and only used opts.root for scope/warmth.
  // Every caller already passes root believing it scopes execution
  // (adjudicateCriterion, adjudicate.mjs, seal.mjs — which papers over the gap
  // by chdir-ing in main(), a fix the LIBRARY path never got). A verdict that
  // depends on invocation cwd eventually produces a confident wrong answer.
  const repoRoot = fileURLToPath(new URL("../../..", import.meta.url));
  const scratch = mkdtempSync(join(tmpdir(), "grip-cwd-"));
  const prev = process.cwd();
  process.chdir(scratch);
  try {
    // A repo-relative read that EXISTS under root and not under the scratch cwd.
    const r = runRerun("grep -c classifySafety tooling/grip/rerun.mjs", { root: repoRoot });
    assert.equal(r.ran, true);
    assert.equal(r.exit, 0, `repo-relative rerun must execute under opts.root, not the caller's cwd — exited ${r.exit}: ${r.stderr}`);
    // And the same command WITHOUT root still runs in the caller's cwd (the
    // default is unchanged): from the scratch dir the file does not exist.
    const local = runRerun("grep -c classifySafety tooling/grip/rerun.mjs");
    assert.notEqual(local.exit, 0, "without opts.root the caller's cwd must still govern — the default contract is unchanged");
  } finally {
    process.chdir(prev);
    rmSync(scratch, { recursive: true, force: true });
  }
});

// ── 7. the module boundary ───────────────────────────────────────────────────

test("rerun.mjs does not import level.mjs", async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("../rerun.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(src, /from\s+["'][^"']*level\.mjs["']/,
    "the executor must stay independent of the authority-level grammar");
});

// ── 7b. the probe's authority is NOT the literal command's authority ─────────
//
// REGRESSION. The HTTP branch ruled on the reachability probe alone and threw
// the literal command's exit away, so `curl <live 200 host> | grep -c NEEDLE`
// came back verdict=OK with admits.pass=true even when the needle was ABSENT —
// the probe's authority laundered onto the command's result, inside the module
// built to make laundering impossible. Hermetic: the "live host" is a loopback
// server this test starts, so nothing here depends on the world being up.

// The server MUST live in a child process: runRerun uses spawnSync, which
// blocks this thread, so an in-process http server would never accept the
// connection and every probe would read HOST-UNREACHABLE — a fake red that
// looks exactly like the real one.
// `status` is a parameter, not a constant: the whole point of the 404 plant
// below is that a REACHABLE host answering a wrong route is a different fact
// from an unreachable one, and a server that can only answer 200 cannot express
// it. Default 200 so every existing caller is unchanged.
async function withLocalServer(body, fn, { status = 200 } = {}) {
  const { spawn } = await import("node:child_process");
  const src = `const http=require("http");const s=http.createServer((q,r)=>{r.writeHead(${JSON.stringify(status)},{"content-type":"text/plain"});r.end(${JSON.stringify(body)})});s.listen(0,"127.0.0.1",()=>console.log(s.address().port));`;
  const child = spawn(process.execPath, ["-e", src], { stdio: ["ignore", "pipe", "ignore"] });
  try {
    const port = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("local server did not report a port in 5s")), 5000);
      child.stdout.once("data", (d) => { clearTimeout(timer); resolve(Number(String(d).trim())); });
      child.once("error", reject);
    });
    return await fn(port);
  } finally {
    child.kill("SIGKILL");
  }
}

test("a piped curl whose filter finds NOTHING is not laundered into a pass", async () => {
  await withLocalServer("hello grip\n", (port) => {
    const r = runRerun(`curl -s http://127.0.0.1:${port}/ | grep -c NEEDLE_THAT_IS_ABSENT`, { timeoutMs: 5000 });
    // The host DID answer — reachability is real and must be reported as such.
    assert.equal(r.code, 200);
    assert.equal(r.reachable, true);
    // …but the command said no, so the verdict follows the command, not the probe.
    assert.equal(r.verdict, VERDICT.FAILED);
    assert.equal(r.literalExit, 1);
    assert.equal(admitsPassClaim(r), false, "a filter that matched nothing may never support a pass claim");
    // A live host answering + a real read that found nothing IS a valid absence.
    assert.equal(admitsAbsenceClaim(r), true);
  });
});

test("a piped curl whose filter DOES match still reads OK — the fix is not blanket strictness", async () => {
  await withLocalServer("hello grip\n", (port) => {
    const r = runRerun(`curl -s http://127.0.0.1:${port}/ | grep -c hello`, { timeoutMs: 5000 });
    assert.equal(r.verdict, VERDICT.OK);
    assert.equal(r.literalExit, 0);
    assert.equal(admitsPassClaim(r), true);
  });
});

test("an UNPIPED curl that discards stdout is not falsely NULL-READ", async () => {
  await withLocalServer("hello grip\n", (port) => {
    const r = runRerun(`curl -s -o /dev/null http://127.0.0.1:${port}/`, { timeoutMs: 5000 });
    assert.notEqual(r.verdict, VERDICT.NULL_READ,
      "the response IS the read; the probe measured it, so emptiness of stdout proves nothing");
    assert.equal(r.verdict, VERDICT.OK);
  });
});

// ── 7c. REACHABLE-WRONG-ROUTE, EXECUTED — hermetically, never against prod ───
//
// Of the ten verdict classes this was the only one with no EXECUTED plant
// anywhere: the classifier half is pinned pure at :49 and its never-cry-wolf
// twin at :53 ("404-reachable and 000-unreachable are NOT merged"), but the
// only end-to-end demonstration lived in the GRIP_LIVE=1 test below, which
// curls prod. A plant that needs a production box to be UP is the
// outage-forges-a-verdict shape this module exists to abolish — and it cannot
// run in the gate at all.
//
// So the plant is driven through the REAL runRerun against a loopback server
// that answers 404. Same code path, same verdict, no world required.

test("EXECUTED PLANT: a live host answering 404 reads REACHABLE-WRONG-ROUTE (loopback, no prod)", async () => {
  await withLocalServer("not found\n", (port) => {
    const r = runRerun(`curl -s http://127.0.0.1:${port}/definitely-not-a-route`, { timeoutMs: 5000 });
    assert.equal(r.verdict, VERDICT.WRONG_ROUTE);
    assert.equal(r.code, 404);
    assert.equal(r.reachable, true, "the host ANSWERED — this is not an outage");
    // The absence seam: a live host saying 404 is a real read, so it may support
    // an absence claim, and may never support a pass claim.
    assert.equal(admitsAbsenceClaim(r), true);
    assert.equal(admitsPassClaim(r), false);
  }, { status: 404 });
});

test("NEVER CRY WOLF: the same loopback answering 200 is NOT REACHABLE-WRONG-ROUTE", async () => {
  // The executed half of the :53 distinction. If the 404 plant above passed
  // against a server that answers 200 too, it would be measuring "a server
  // exists", not "the route is wrong".
  await withLocalServer("here\n", (port) => {
    const r = runRerun(`curl -s http://127.0.0.1:${port}/definitely-not-a-route`, { timeoutMs: 5000 });
    assert.notEqual(r.verdict, VERDICT.WRONG_ROUTE);
    assert.equal(r.verdict, VERDICT.OK);
    assert.equal(r.code, 200);
  });
});

// ── 8. opt-in live probes against prod (GRIP_LIVE=1) ─────────────────────────
// Skipped by default so the gate never depends on the world being up.

test("live: prod distinguishes right-route from wrong-route", { skip: process.env.GRIP_LIVE !== "1" }, () => {
  const right = runRerun("curl -s http://89.167.28.206/api/schemas");
  const wrong = runRerun("curl -s http://89.167.28.206/api/health");
  assert.equal(right.verdict, VERDICT.OK);
  assert.equal(right.code, 200);
  assert.equal(wrong.verdict, VERDICT.WRONG_ROUTE);
  assert.equal(wrong.code, 404);
  assert.equal(wrong.reachable, true);
});

// ── the shape rule: a name denylist can never be complete ────────────────────
//
// Review found four LIVE bypasses opened by quote-blanking: `su -c`, `watch`,
// `elixir -e` and `iex -e` each classified `rm -rf /tmp/y` as SAFE once the
// payload was quoted, because no named interpreter shape matched and the
// quoted span was blanked away. Every one is a command this module would then
// have EXECUTED. The fix keys on SHAPE — an unknown head handed a quoted
// argument through -c/-e/--eval/--command/--exec is assumed to execute it —
// with a small allowlist of heads whose -c/-e takes DATA (grep -e is a pattern,
// sed -e an expression, git -c a config assignment).
//
// The error direction is the whole point and it is inverted from the denylist
// it backstops: a wrong allowlist entry costs a false REFUSAL, visible at once
// in the verdict message. A wrong denylist costs a false PERMISSION on a
// command about to run.

test("quoted payloads handed to an UNKNOWN head are refused, not blanked", () => {
  const mustRefuse = [
    "su -c 'rm -rf /tmp/y'",
    "watch 'rm -rf /tmp/y'",
    "elixir -e 'File.rm!(\"/tmp/y\")'",
    "iex -e 'File.rm_rf(\"/tmp/y\")'",
    "elixir -e 'Repo.delete_all(Doc)'",
    "someexotic-runner -c 'rm -rf /tmp/y'",
    "env sh -c 'rm -rf /tmp/y'",
    "timeout 5 sh -c 'rm -rf /tmp/y'",
    "node -e 'require(\"fs\").rmSync(\"/tmp/y\")'",
    "psql -c 'DROP TABLE docs'",
  ];
  for (const cmd of mustRefuse) {
    assert.equal(classifySafety(cmd).safe, false, `MUST REFUSE: ${cmd}`);
  }
});

test("the shape rule does NOT re-refuse honest reads whose -c/-e takes data", () => {
  const mustAllow = [
    "grep -e 'npm publish' README.md",
    "rg -e 'chmod 644' docs/",
    "sed -n -e '1,5p' README.md",
    "git -c core.pager=cat log --grep='publish flow'",
    "grep -n 'a > b' README.md",
    "grep -rn 'npm publish instructions' docs/",
    "git log --grep='publish flow'",
    "grep -n 'File.rm! is dangerous' docs/x.md",
  ];
  for (const cmd of mustAllow) {
    const v = classifySafety(cmd);
    assert.equal(v.safe, true, `MUST ALLOW: ${cmd} — refused as ${v.reason}`);
  }
});

test("an Elixir/Erlang inline program cannot write through its own stdlib", () => {
  // This repo's primary runtime, so `elixir -e` is a realistic rerun shape here
  // in a way `perl -e` is not. File.rm! has no trailing space, so the shell-verb
  // `\brm\s` rule never saw it.
  for (const cmd of [
    "elixir -e 'File.write!(\"/tmp/y\", \"x\")'",
    "elixir -e 'File.cp_r(\"a\", \"b\")'",
    "iex -e 'file:delete(\"/tmp/y\")'",
  ]) {
    assert.equal(classifySafety(cmd).safe, false, `MUST REFUSE: ${cmd}`);
  }
});
