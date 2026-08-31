#!/usr/bin/env node
// Proof for the assertion-density gate on the Tested dimension's presence
// PROXY (tooling/risk/test-proxy.mjs) — the fix for the "empty placeholder
// scores like a real suite" grader bug named in tooling/quality/GRADE-CRITIQUE.md.
//
//   node tooling/risk/test-proxy.test.mjs   (or: node --test)
//
// Four cases, per the task brief:
//   1. empty placeholder  — sibling exists, zero assertions   -> scores low, "proxy-unasserted"
//   2. dense suite        — sibling exists, real assertions   -> legacy 60-point bonus, "proxy"
//   3. refs-only, no sibling                                   -> refs component only, "proxy"
//   4. refs component is unchanged by this fix (same formula, with and without a sibling)

import { test } from "node:test";
import assert from "node:assert/strict";
import { scoreTestProxy, countAssertions } from "./test-proxy.mjs";

test("empty placeholder sibling scores materially below a real suite, reports proxy-unasserted", () => {
  const placeholder = `
    import { test } from "node:test";
    test.todo("fill this in");
  `;
  assert.equal(countAssertions(placeholder), 0, "no assertion sites in a placeholder");

  const { score, source } = scoreTestProxy(placeholder, 0);
  assert.equal(source, "proxy-unasserted");
  assert.ok(score < 60, `placeholder score (${score}) must be materially below the legacy 60-point bonus`);

  // MUTATION PROOF context: under the old flat `has ? 60 : 0` formula this
  // placeholder scored exactly 60 — indistinguishable from the dense suite
  // below. This assertion is what reds if the gate regresses to that formula.
});

test("a densely-asserted sibling keeps the legacy 60-point presence bonus, reports proxy", () => {
  const dense = `
    import { describe, it, expect } from "vitest";
    describe("paperTags", () => {
      it("dedupes tags", () => {
        expect(paperTags(["a", "a", "b"])).toEqual(["a", "b"]);
      });
      it("handles empty input", () => {
        expect(paperTags([])).toEqual([]);
        assert.equal(paperTags(undefined).length, 0);
      });
    });
  `;
  assert.ok(countAssertions(dense) >= 2, "dense suite has multiple assertion sites");

  const { score, source } = scoreTestProxy(dense, 0);
  assert.equal(source, "proxy");
  assert.equal(score, 60, "unchanged from the original has-sibling bonus when refs=0");
});

test("refs-only, no sibling test file at all — score is the refs component alone", () => {
  const { score, source } = scoreTestProxy(null, 3);
  assert.equal(source, "proxy");
  assert.equal(score, 24, "3 refs * 8 = 24, no presence bonus without a sibling");

  const capped = scoreTestProxy(undefined, 50);
  assert.equal(capped.score, 40, "refs component caps at 40 regardless of presence");
});

test("the refs component formula (8/ref, capped at 40) is unchanged by this fix", () => {
  const dense = `test("x", () => { expect(1).toBe(1); });`;

  // with a dense sibling: 60 + min(40, refs*8)
  assert.equal(scoreTestProxy(dense, 0).score, 60);
  assert.equal(scoreTestProxy(dense, 2).score, 60 + 16);
  assert.equal(scoreTestProxy(dense, 10).score, 100, "capped at 100 (60 + min(40, 80))");

  // without a sibling: min(40, refs*8), same multiplier as the dense case
  assert.equal(scoreTestProxy(null, 2).score, 16);
  assert.equal(scoreTestProxy(null, 10).score, 40, "refs component itself caps at 40");
});

test("countAssertions covers the dialects actually in use in this repo (expect/assert) plus the brief's named ones", () => {
  assert.equal(countAssertions("expect(x).toBe(1);"), 1);
  assert.equal(countAssertions("assert.equal(x, 1); assert.deepEqual(y, z);"), 2);
  assert.equal(countAssertions("assert(ok);"), 1);
  assert.equal(countAssertions("t.deepEqual(a, b);"), 1);
  assert.equal(countAssertions("foo.should.equal(1);"), 1);
  assert.equal(countAssertions(""), 0);
  assert.equal(countAssertions(null), 0);
});
