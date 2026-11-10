// level-compound.test.mjs — the authority-level grammar tests for
// compound commands (D30), bp and gh as remote-API reads, bp scaffy local
// verbs.
//
// One of the level-*.test.mjs files the single level suite was split into by
// subject (task-f5ca1c7505824cc4). The tests moved unchanged.
//
//   node --test tooling/grip/test/level-compound.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  deriveLevel,
  checkCeiling,
  L3_HEADS,
} from "../level.mjs";

// =============================================================================
// COMPOUND COMMANDS — the blind spot (charter D30)
// =============================================================================
//
// Everything above this line tests a SINGLE command. The suite had ZERO `&&`
// tests, so a green run proved nothing about the shape that dominates real
// evidence: `cd <path> && <command>`. That gap is why the Digest's three-word
// recommendation — add `bp`, `gh`, `cd` to L3_HEADS — read as safe.
//
// It was not. `deriveLevel` short-circuited on the FIRST head token, so
// blessing `cd` would have made `cd /opt/barkpark && curl https://prod/health`
// derive L3 — LOCAL-CHECKOUT authority for a command that reaches production,
// a two-level skip with no test able to see it. The fix walks every segment of
// the compound instead, and no wrapper is ever blessed with a level.

test("L3_HEADS blesses no wrapper — cd, for and env are NOT local-read heads", () => {
  // The naive fix, pinned as absent. If a future edit adds `cd` here, the
  // compound tests below are what will catch what it costs.
  assert.equal(L3_HEADS.has("cd"), false, "cd is navigation, not a read");
  assert.equal(L3_HEADS.has("for"), false, "for is a loop, not a read");
  assert.equal(L3_HEADS.has("env"), false, "env is a prefix wrapper, not a read");
  assert.equal(L3_HEADS.has("bp"), false, "bp is a remote-API client — L2, not L3");
  assert.equal(L3_HEADS.has("gh"), false, "gh is a remote-API client — L2, not L3");
});

test("cd + curl to a non-loopback host derives L1, not L3 and not L6", () => {
  // Pre-fix this was L6 (safe by accident: the head was `cd`). The naive
  // L3_HEADS fix would have made it L3 — authority INFLATION on a command that
  // provably reaches production. Neither is right: the compound touches a
  // running system, so its ceiling is L1.
  const level = deriveLevel("cd /opt/barkpark && curl https://guerrilla.barkpark.cloud/health");
  assert.equal(level, "L1");
  assert.equal(deriveLevel("cd api && curl -s -o /dev/null -w '%{http_code}' http://89.167.28.206/api/schemas"), "L1");
});

test("cd + wget to a non-loopback host derives L1", () => {
  assert.equal(deriveLevel("cd /opt/barkpark && wget -qO- https://guerrilla.barkpark.cloud/health"), "L1");
});

test("cd + LOOPBACK curl stays L3 — the local dev server is a checkout property", () => {
  assert.equal(deriveLevel("cd /opt/barkpark && curl -s http://localhost:4000/v1/capabilities"), "L3");
  assert.equal(deriveLevel("cd api && curl -s http://[::1]:4000/api/schemas"), "L3");
});

test("cd + ssh derives L1", () => {
  assert.equal(
    deriveLevel("cd /opt/barkpark && ssh -o BatchMode=yes root@157.180.90.121 'systemctl is-active barkpark'"),
    "L1",
  );
});

test("cd + gh api derives L2", () => {
  assert.equal(
    deriveLevel("cd /Volumes/SATECHI/github/barkpark && gh api repos/FRIKKern/barkpark/pulls/4294 --jq .state"),
    "L2",
  );
});

test("cd + bp derives L2", () => {
  assert.equal(
    deriveLevel('cd /Volumes/SATECHI/github/barkpark && bp search query "research coverage ledger"'),
    "L2",
  );
});

test("cd + a local test run derives L3 — the head is found PAST the wrapper", () => {
  assert.equal(
    deriveLevel("cd /Volumes/SATECHI/github/barkpark/api && CC=clang mix test test/barkpark_web/live/studio/connectors_live_test.exs 2>&1 | tail -20"),
    "L3",
  );
  assert.equal(deriveLevel("cd js && pnpm --filter @barkpark/react test"), "L3");
});

test("an env-assignment prefix does not hide the head", () => {
  assert.equal(deriveLevel("CC=clang MIX_ENV=test mix test test/barkpark/content/validation_test.exs"), "L3");
  assert.equal(deriveLevel("HCLOUD_TOKEN=fake curl -s https://api.hetzner.cloud/v1/servers"), "L1");
  assert.equal(deriveLevel("BARKPARK_TOKEN=bogus bp task get foo -o json"), "L2");
});

test("a for-loop wrapper does not hide the head — the `do` segment is levelled", () => {
  assert.equal(
    deriveLevel("for pr in 4566 4567; do gh pr view $pr --json number,state,mergedAt; done"),
    "L2",
  );
  assert.equal(
    deriveLevel('for f in internal/chat/testdata/*.json; do grep -c workflow_agent "$f"; done'),
    "L3",
  );
  assert.equal(
    deriveLevel("for host in a b; do curl -s https://guerrilla.barkpark.cloud/health; done"),
    "L1",
  );
});

test("the STRONGEST segment sets the ceiling — a pipe consumer never demotes a remote read", () => {
  // The standing bar is ZERO false demotions of honest L1/L2 commands. If the
  // weakest segment won, `curl <prod> | jq .` would derive L3 off `jq` and the
  // gate would start rejecting honest L1 claims — the fastest way to get a
  // gate routed around.
  assert.equal(deriveLevel("curl -s https://guerrilla.barkpark.cloud/v1/capabilities | jq .ok"), "L1");
  assert.equal(deriveLevel("gh pr list --state open --json number | jq length"), "L2");
  assert.equal(deriveLevel("cat Makefile && gh api repos/FRIKKern/barkpark --jq .name"), "L2");
});

test("an artifact read piped into a local consumer stays L4", () => {
  // L4 is a statement about the read's TARGET, not a rung competing with L1-L3.
  assert.equal(deriveLevel("cat docs/openapi.json | jq '.paths | keys'"), "L4");
  assert.equal(deriveLevel("cd /opt && cat docs/openapi.json | wc -l"), "L4");
  // ...but it never caps a remote read standing beside it.
  assert.equal(deriveLevel("cat docs/openapi.json && curl -s https://guerrilla.barkpark.cloud/health"), "L1");
});

test("a quoted operator does not split a segment, and a quoted URL is not a curl target", () => {
  // Quote-masking is what keeps the refuted prose scanner's failure mode dead:
  // a MENTIONED url can never reach the curl branch.
  assert.equal(deriveLevel("grep -n 'a && b' src/main.ts"), "L3");
  assert.equal(deriveLevel("grep -rn 'https://guerrilla.barkpark.cloud' api/lib/"), "L3");
  // A genuinely QUOTED curl target still counts — quotes on a real target are
  // ordinary shell hygiene, not a mention.
  assert.equal(deriveLevel("curl -s 'https://guerrilla.barkpark.cloud/v1/capabilities'"), "L1");
});

// =============================================================================
// bp and gh are REMOTE-API READS — L2 (charter D30 (c))
// =============================================================================

test("bp derives L2 — it reads the configured remote content server", () => {
  assert.equal(deriveLevel("bp task get foo -o json"), "L2");
  assert.equal(deriveLevel("bp doc ls tag -o json"), "L2");
  assert.equal(deriveLevel("bp search query 'scaffy engine reanchor' -o json"), "L2");
});

test("non-api gh derives L2, the level gh api already held", () => {
  assert.equal(deriveLevel("gh pr view 4159 --json state,mergeCommit,mergedAt"), "L2");
  assert.equal(deriveLevel("gh pr list --state open"), "L2");
  assert.equal(deriveLevel("gh run list --workflow elixir.yml --branch main --limit 5"), "L2");
  assert.equal(deriveLevel("gh issue view 1598 --json title,body"), "L2");
});

test("bp and gh are NOT L1 — they are not ssh and not a read of served bytes", () => {
  assert.notEqual(deriveLevel("bp task get foo -o json"), "L1");
  assert.notEqual(deriveLevel("gh pr view 4159 --json state"), "L1");
});

test("bp pointed at a LOOPBACK server is a local read: L3, mirroring loopback curl", () => {
  assert.equal(deriveLevel("bp -s http://localhost:4001 --token bp_admin_x cloud workspace export default"), "L3");
  assert.equal(deriveLevel("bp -s http://127.0.0.1:4077 task ready -o json"), "L3");
  // An EXPLICIT remote server is still L2, not a promotion.
  assert.equal(deriveLevel("bp -s https://guerrilla.barkpark.cloud task ready -o json"), "L2");
});

// =============================================================================
// bp scaffy LOCAL verbs are L3, not L2 — anchored to the SUBCOMMAND (tgw13-s1)
// =============================================================================
//
// `bp` heads to the remote content server, so it derives L2 — UNLESS the URL is
// loopback (already tested above). But five scaffy verbs are PURE LOCAL:
// scaffy_cmd.go's header says so verbatim ("no network, no auth, no manifest —
// this file never touches the server"), and the engine (internal/scaffy)
// parses/formats/applies .scaffy files against the cwd tree. Their fact is
// re-derived from the LOCAL CHECKOUT, so the honest ceiling is L3. Filing them
// L2 let checkCeiling accept an L2 claim on a local-only fact — a level-skip.
//
// The demotion is anchored to the SUBCOMMAND position (level.mjs
// isLocalScaffyInvocation): `scaffy` must be the first token after `bp` that is
// not a global flag or the value a value-taking global consumed — NOT a bare
// indexOf("scaffy") anywhere in the stream. A bare indexOf over-refused a whole
// class of genuine remote reads that merely carry 'scaffy' as an argument.

test("URL-free local bp scaffy verbs derive L3 — they touch only the cwd tree", () => {
  assert.equal(deriveLevel("bp scaffy validate x.scaffy"), "L3");
  assert.equal(deriveLevel("bp scaffy fmt --check f.scaffy"), "L3");
  assert.equal(deriveLevel("bp scaffy run x.scaffy"), "L3");
  assert.equal(deriveLevel("bp scaffy discover --since HEAD~5"), "L3");
  // `remove` is the fifth pure-local verb per scaffy_cmd.go's header — same class.
  assert.equal(deriveLevel("bp scaffy remove x.scaffy"), "L3");
  // --var flags after the verb do not change the verb classification.
  assert.equal(deriveLevel("bp scaffy run make-command.scaffy --var Name=Foo"), "L3");
  // A value-taking global BEFORE the subcommand (`-o json`) must be skipped
  // WITH its value or the anchor lands on `json` and fails to demote. `--json`
  // is boolean and must NOT eat the following `scaffy`. Both are load-bearing:
  // getting either arity wrong reopens the OPPOSITE over-refusal (tgw3).
  assert.equal(deriveLevel("bp -o json scaffy validate x.scaffy"), "L3");
  assert.equal(deriveLevel("bp --json scaffy validate x.scaffy"), "L3");
  assert.equal(deriveLevel("bp -w main scaffy run x.scaffy"), "L3");
});

test("the ceiling now REJECTS an L2 claim on a local scaffy verb", () => {
  // The bug this slice fixes: checkCeiling('L2', deriveLevel('bp scaffy validate …'))
  // returned ok:true because the verb derived L2. It now derives L3, so an L2
  // claim is a LEVEL-SKIP.
  const verdict = checkCeiling("L2", deriveLevel("bp scaffy validate x.scaffy"));
  assert.equal(verdict.ok, false);
  assert.equal(verdict.reason, "LEVEL-SKIP");
  assert.equal(verdict.claimed, "L2");
  assert.equal(verdict.derived, "L3");
  // An honest L3 claim is accepted.
  assert.equal(checkCeiling("L3", deriveLevel("bp scaffy validate x.scaffy")).ok, true);
});

test("the demotion is SUBCOMMAND-scoped — remote scaffy verbs and other bp verbs stay L2", () => {
  // `pull` and `ls --remote` live in scaffy_remote_cmd.go, carry a Server and
  // hit /v1/data/query — they are genuine remote reads and must keep L2.
  assert.equal(deriveLevel("bp scaffy ls --remote"), "L2");
  assert.equal(deriveLevel("bp scaffy pull post"), "L2");
  // A local verb with an EXPLICIT remote server still reaches the server on -s,
  // so the URL keeps it at L2 — the demotion is URL-free only.
  assert.equal(deriveLevel("bp scaffy pull note -s https://guerrilla.barkpark.cloud"), "L2");
  assert.equal(deriveLevel("bp scaffy validate x.scaffy -s https://guerrilla.barkpark.cloud"), "L2");
  // Every OTHER bp verb is unaffected — bp still heads to the remote server.
  assert.equal(deriveLevel("bp search query x -o json"), "L2");
  assert.equal(deriveLevel("bp task get foo -o json"), "L2");
  assert.equal(deriveLevel("bp doc ls tag -o json"), "L2");
  // DURABLE GUARD — the over-refusal this slice closes. A remote bp read that
  // carries 'scaffy' as an ARGUMENT (not the subcommand) must stay L2. A bare
  // indexOf("scaffy") demoted these L2→L3 and made checkCeiling refuse an
  // honest L2 claim; the subcommand anchor keeps them L2. Do not remove.
  assert.equal(deriveLevel("bp task get scaffy validate x.scaffy"), "L2");
  assert.equal(deriveLevel("bp search query scaffy validate -o json"), "L2");
  // And the ceiling must ACCEPT an L2 claim on these — the anchor's whole point.
  assert.equal(checkCeiling("L2", deriveLevel("bp task get scaffy validate x.scaffy")).ok, true);
  assert.equal(checkCeiling("L2", deriveLevel("bp search query scaffy validate -o json")).ok, true);
});

test("a loopback-server local scaffy verb stays L3 by the loopback rule, not the carve-out", () => {
  // Belt and braces: the loopback branch already returns L3, and the carve-out
  // must not disturb it.
  assert.equal(deriveLevel("bp -s http://localhost:4001 scaffy validate x.scaffy"), "L3");
  assert.equal(deriveLevel("cd /Volumes/SATECHI/github/barkpark && bp scaffy fmt --check f.scaffy"), "L3");
});
