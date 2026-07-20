// level.test.mjs — the real-invocation corpus for the authority-level grammar.
//
// The corpus is REAL flag-bearing invocations lifted from this repo's own
// evidence trails, not invented tidy ones. The acceptance bar that matters is
// ZERO FALSE DEMOTIONS of honest L1/L2 commands — a gate that punishes honest
// evidence gets routed around within a wave.
//
//   node --test tooling/grip/test/level.test.mjs

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
import { admitFact, findRefs, FACT_FIELDS } from "../record.mjs";

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

// --- L4 ----------------------------------------------------------------------

test("a read whose target is a known generated artifact derives L4", () => {
  assert.equal(deriveLevel("cat docs/openapi.json"), "L4");
  assert.equal(deriveLevel("jq '.paths | keys' docs/openapi.json"), "L4");
  assert.equal(deriveLevel("grep -c route tooling/quality/quality-report.json"), "L4");
  assert.equal(deriveLevel("diff a.golden.json b.golden.json"), "L4");
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

// --- the ceiling -------------------------------------------------------------

test("a claim above the derived level is REJECTED with LEVEL-SKIP naming both levels", () => {
  const verdict = checkCeiling("L1", "L3");
  assert.equal(verdict.ok, false);
  assert.equal(verdict.reason, "LEVEL-SKIP");
  assert.equal(verdict.claimed, "L1");
  assert.equal(verdict.derived, "L3");
  assert.match(verdict.message, /LEVEL-SKIP/);
  assert.match(verdict.message, /L1/);
  assert.match(verdict.message, /L3/);
});

test("a claim equal to the derived level is accepted", () => {
  assert.equal(checkCeiling("L3", "L3").ok, true);
});

test("an under-claim (below the ceiling) is accepted — honest modesty is kept", () => {
  assert.equal(checkCeiling("L4", "L3").ok, true);
  assert.equal(checkCeiling("L6", "L1").ok, true);
});

test("admitFact rejects a fact whose claimed level outranks its rerun command", () => {
  const rejected = admitFact({
    subject: "PLATFORM_ADMIN_EMAILS on prod",
    claim: "prod resolves platform admin emails",
    rerun: "grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex",
    level: "L1",
  });
  assert.equal(rejected.ok, false);
  const skip = rejected.rejections.find((r) => r.reason === "LEVEL-SKIP");
  assert.ok(skip, "expected a LEVEL-SKIP rejection");
  assert.equal(skip.claimed, "L1");
  assert.equal(skip.derived, "L3");
});

test("admitFact keeps an honest under-claim", () => {
  const admitted = admitFact({
    subject: "prod schemas endpoint",
    claim: "the deployed build serves /api/schemas",
    rerun: "curl -s -o /dev/null -w '%{http_code}' -m 10 http://89.167.28.206/api/schemas",
    level: "L3",
  });
  assert.equal(admitted.ok, true);
  assert.equal(admitted.fact.level, "L3");
});

// --- PATHLESS-REF (D9) -------------------------------------------------------

test("a path-less line reference is REJECTED with PATHLESS-REF", () => {
  const verdict = classifyRef("notifications.ex:389-397");
  assert.equal(verdict.ok, false);
  assert.equal(verdict.reason, "PATHLESS-REF");
  assert.match(verdict.message, /PATHLESS-REF/);
});

test("a directory-bearing reference is accepted with parsed lines", () => {
  const verdict = classifyRef("cloud/lib/barkpark_cloud/notifications.ex:389-397");
  assert.equal(verdict.ok, true);
  assert.equal(verdict.path, "cloud/lib/barkpark_cloud/notifications.ex");
  assert.deepEqual(verdict.lines, { start: 389, end: 397 });
});

test("admitFact rejects a fact whose claim addresses code through a path-less ref", () => {
  const rejected = admitFact({
    subject: "notification admin gate",
    claim: "the admin gate lives at notifications.ex:389-397",
    rerun: "grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex",
  });
  assert.equal(rejected.ok, false);
  assert.equal(rejected.rejections[0].reason, "PATHLESS-REF");
});

test("findRefs never reads the evidence field through admitFact", () => {
  // The same path-less ref in EVIDENCE prose is inert — evidence is not parsed.
  const admitted = admitFact({
    subject: "notification admin gate",
    claim: "the admin gate checks PLATFORM_ADMIN_EMAILS",
    evidence: "saw it around notifications.ex:389-397 somewhere",
    rerun: "grep -n 'def platform_admin_emails' cloud/lib/barkpark_cloud/notifications.ex",
  });
  assert.equal(admitted.ok, true);
});

// --- INADMISSIBLE-CONTINUOUS (D7) --------------------------------------------

test("a discrete observable is admissible", () => {
  assert.equal(isDiscretePredicate("http_code=200"), true);
  assert.equal(isDiscretePredicate("count=42 documents"), true);
});

test("a continuous measurement without a predicate is not discrete", () => {
  assert.equal(isDiscretePredicate("t_total 0.116"), false);
  assert.equal(isDiscretePredicate("latency was 0.135 seconds"), false);
});

test("a declared threshold collapses a continuous measurement to a discrete predicate", () => {
  assert.equal(isDiscretePredicate("t_total 0.116, admissible as t_total < 0.5"), true);
  assert.equal(isDiscretePredicate("response under 2.0 seconds"), true);
});

test("admitFact flags a predicate-less continuous quantity INADMISSIBLE-CONTINUOUS", () => {
  const rejected = admitFact({
    subject: "prod schemas endpoint latency",
    quantity: "t_total 0.116",
    claim: "the endpoint is fast",
    rerun: "curl -s -o /dev/null -w '%{time_total}' -m 10 http://89.167.28.206/api/schemas",
  });
  assert.equal(rejected.ok, false);
  assert.equal(rejected.rejections[0].reason, "INADMISSIBLE-CONTINUOUS");

  const admitted = admitFact({
    subject: "prod schemas endpoint latency",
    quantity: "t_total 0.116, predicate: t_total < 2.0",
    claim: "the endpoint answers within the budget",
    rerun: "curl -s -o /dev/null -w '%{time_total}' -m 10 http://89.167.28.206/api/schemas",
  });
  assert.equal(admitted.ok, true);
});

// --- the record itself -------------------------------------------------------

test("admitFact returns the full fact record with defaults applied", () => {
  const admitted = admitFact({
    subject: "doc-gates workflow on origin/main",
    claim: "doc-gates triggers on .ex/.go/.exs/.ts",
    rerun: "git show origin/main:.github/workflows/doc-gates.yml",
  });
  assert.equal(admitted.ok, true);
  const { fact } = admitted;
  assert.equal(fact.level, "L2");
  assert.deepEqual(fact.deps, []);
  assert.equal(typeof fact.observed_at, "string");
  assert.ok(!Number.isNaN(Date.parse(fact.observed_at)));
  for (const field of FACT_FIELDS) assert.ok(field in fact, `fact carries ${field}`);
});

test("admitFact rejects a subject-less or claim-less record with named reasons", () => {
  const rejected = admitFact({ rerun: "cat Makefile" });
  assert.equal(rejected.ok, false);
  const reasons = rejected.rejections.map((r) => r.reason).sort();
  assert.deepEqual(reasons, ["MISSING-CLAIM", "MISSING-SUBJECT"]);
});
