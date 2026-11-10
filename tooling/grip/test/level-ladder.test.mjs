// level-ladder.test.mjs — the authority-level grammar tests for
// the ladder itself: export shape, L1, L2, L3, L6, and the grammar never
// reading evidence prose.
//
// The corpus is REAL flag-bearing invocations lifted from this repo's own
// evidence trails, not invented tidy ones. The acceptance bar that matters is
// ZERO FALSE DEMOTIONS of honest L1/L2 commands — a gate that punishes honest
// evidence gets routed around within a wave.
//
// One of the level-*.test.mjs files the single level suite was split into by
// subject (task-f5ca1c7505824cc4). The tests moved unchanged.
//
//   node --test tooling/grip/test/level-ladder.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  deriveLevel,
  LEVELS,
  checkCeiling,
  classifyRef,
  isDiscretePredicate,
  GENERATED_ARTIFACT_PATTERNS,
} from "../level.mjs";
import { admitFact, FACT_FIELDS } from "../record.mjs";

// --- export shape ------------------------------------------------------------

test("level.mjs exposes the named export surface and a frozen ladder", () => {
  assert.equal(typeof deriveLevel, "function");
  assert.equal(typeof checkCeiling, "function");
  assert.equal(typeof classifyRef, "function");
  assert.equal(typeof isDiscretePredicate, "function");
  assert.ok(Object.isFrozen(LEVELS));
  assert.deepEqual(Object.keys(LEVELS), ["L1", "L2", "L3", "L4", "L5", "L6"]);
  assert.ok(Object.isFrozen(GENERATED_ARTIFACT_PATTERNS));
  assert.ok(Array.isArray(FACT_FIELDS) && FACT_FIELDS.includes("rerun"));
});

// --- L1: zero false demotions on honest flag-bearing invocations -------------

test("ssh with flags between ssh and user@host derives L1 (the false-demotion regression)", () => {
  assert.equal(
    deriveLevel("ssh -o BatchMode=yes -o ConnectTimeout=8 root@89.167.28.206 'echo ok'"),
    "L1",
  );
});

test("ssh with -i identity flag derives L1", () => {
  assert.equal(
    deriveLevel("ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl is-active barkpark'"),
    "L1",
  );
});

test("curl to a non-loopback IP with write-out and max-time flags derives L1", () => {
  assert.equal(
    deriveLevel("curl -s -o /dev/null -w '%{http_code}' -m 10 http://89.167.28.206/api/schemas"),
    "L1",
  );
});

test("curl to a public DNS host behind a timeout wrapper derives L1", () => {
  assert.equal(
    deriveLevel("timeout 10 curl -fsS https://api.barkpark.cloud/v1/capabilities"),
    "L1",
  );
});

test("loopback curl does NOT derive L1 — it is a read of the local dev system", () => {
  const level = deriveLevel("curl -s http://localhost:4000/v1/capabilities");
  assert.notEqual(level, "L1");
  assert.equal(level, "L3");
  assert.notEqual(deriveLevel("curl -s http://127.0.0.1:4000/api/schemas"), "L1");
  assert.notEqual(deriveLevel("curl -s http://0.0.0.0:4000/api/schemas"), "L1");
});

// REGRESSION: the original host extractor stopped at the first colon, so
// http://[::1]:4000 yielded the host "[" — which is not loopback — and the
// grammar promoted a local dev-server read to L1. A ceiling set too high is
// precisely the level-skip this module exists to make impossible, so the IPv6
// loopback form is pinned in both the bracketed-with-port and bare shapes.
test("IPv6 loopback curl does NOT derive L1, bracketed and with a port", () => {
  assert.equal(deriveLevel("curl -s http://[::1]:4000/api/schemas"), "L3");
  assert.equal(deriveLevel("curl -s http://[::1]/api/schemas"), "L3");
  assert.equal(deriveLevel("wget -qO- http://[::1]:4000/v1/capabilities"), "L3");
});

test("a bracketed NON-loopback IPv6 host still derives L1", () => {
  assert.equal(deriveLevel("curl -s http://[2a01:4f9:c010:1234::1]/api/schemas"), "L1");
});

// --- L2 ----------------------------------------------------------------------

test("git show against a remote ref derives L2", () => {
  assert.equal(deriveLevel("git show origin/main:.github/workflows/doc-gates.yml"), "L2");
  assert.equal(deriveLevel("git show refs/remotes/origin/main:Makefile"), "L2");
});

test("gh api derives L2", () => {
  assert.equal(deriveLevel("gh api repos/FRIKKern/barkpark/pulls/4294 --jq .state"), "L2");
});

test("git show of a LOCAL ref is a local-checkout read: L3, not L2", () => {
  assert.equal(deriveLevel("git show HEAD:Makefile"), "L3");
});

// --- L3 ----------------------------------------------------------------------

test("scoped grep of a source file derives L3", () => {
  assert.equal(
    deriveLevel("grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex"),
    "L3",
  );
});

test("node <script> derives L3 — a local run, even when the script EMITS artifacts", () => {
  assert.equal(deriveLevel("node design/emit.mjs"), "L3");
});

test("local test runs derive L3", () => {
  assert.equal(deriveLevel("go test ./internal/cli/..."), "L3");
  assert.equal(deriveLevel("node --test tooling/grip/test/level.test.mjs"), "L3");
});

// --- L6 ----------------------------------------------------------------------

test("no rerun command derives L6 — demoted, never rejected", () => {
  assert.equal(deriveLevel(""), "L6");
  assert.equal(deriveLevel("   "), "L6");
  assert.equal(deriveLevel(undefined), "L6");
  assert.equal(deriveLevel(null), "L6");
});

test("an unclassifiable command demotes to L6 rather than guessing", () => {
  assert.equal(deriveLevel("frobnicate --all --please"), "L6");
});

// --- the grammar never reads the evidence prose ------------------------------

test("evidence prose full of L1/L2 markers with an empty rerun derives L6", () => {
  // The refuted prose scanner stamped L1 on strings like these. The grammar
  // takes only the rerun command — the markers in the narrative are inert.
  const admitted = admitFact({
    subject: "prod schemas endpoint",
    claim: "the deployed build serves /api/schemas",
    evidence:
      "OPEN — requires a run against the deployed build; curl http://89.167.28.206/api/schemas " +
      "returned served bytes matching origin/main per https://api.barkpark.cloud",
    rerun: "",
  });
  assert.equal(admitted.ok, true);
  assert.equal(admitted.fact.level, "L6");
});

test("a mention of an https:// literal inside a locally-read file cannot raise a local read above L3", () => {
  // The prose scanner stamped L1 on a source read whose file merely CONTAINED
  // an https:// literal. Leveling the command, a grep is L3 regardless of what
  // the file contents mention.
  assert.equal(
    deriveLevel("grep -n 'https://api.anthropic.com/v1/messages' js/packages/client/src/http.ts"),
    "L3",
  );
});
