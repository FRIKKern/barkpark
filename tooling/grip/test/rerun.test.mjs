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
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  runRerun, classifyHttp, classifySafety, classifyScope, mixEnvOf, isBuildWarm,
  blankQuotedSpans,
  admitsPassClaim, admitsAbsenceClaim, assertAbsenceClaim,
  VERDICT, SCOPE, GripError,
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
async function withLocalServer(body, fn) {
  const { spawn } = await import("node:child_process");
  const src = `const http=require("http");const s=http.createServer((q,r)=>{r.writeHead(200,{"content-type":"text/plain"});r.end(${JSON.stringify(body)})});s.listen(0,"127.0.0.1",()=>console.log(s.address().port));`;
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
