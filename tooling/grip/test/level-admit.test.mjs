// level-admit.test.mjs — the authority-level grammar tests for
// the ceiling and admitFact: LEVEL-SKIP, PATHLESS-REF (D9),
// INADMISSIBLE-CONTINUOUS (D7), the record itself.
//
// One of the level-*.test.mjs files the single level suite was split into by
// subject (task-f5ca1c7505824cc4). The tests moved unchanged.
//
//   node --test tooling/grip/test/level-admit.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  checkCeiling,
  classifyRef,
  isDiscretePredicate,
} from "../level.mjs";
import { admitFact, findRefs, FACT_FIELDS } from "../record.mjs";

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
