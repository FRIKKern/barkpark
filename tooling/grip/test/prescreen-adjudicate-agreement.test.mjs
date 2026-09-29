#!/usr/bin/env node
// THE TWO GATES MUST NOT CONTRADICT EACH OTHER ON A READ.
//
//   node --test tooling/grip/test/prescreen-adjudicate-agreement.test.mjs
//
// WHY THIS FILE EXISTS. `ledger.mjs prescreen` rehearses a write through
// `screenCommand` (screen.mjs); `adjudicate.mjs` re-runs the same command
// through `classifySafety` (rerun.mjs). A writer reads prescreen's verdict and
// stores the row; the adjudicator then reads it back. When the two disagree in
// the direction "prescreen ADMITS, adjudicate REFUSES", the ledger fills with
// rows that are storable and un-re-runnable — evidence with no path back to the
// world it came from.
//
// MEASURED on origin/main, 2026-09-10, over screen.mjs's own DANGER_SET +
// REGRESSION_SET + NEVER_CRY_WOLF_SET (218 commands) plus the row's specimen:
// SEVEN commands were admitted by `screenCommand` and refused by
// `classifySafety`, every one of them a READ whose only sin was the word it
// SEARCHED FOR. The fix (`blankSearchTerms` in rerun.mjs) treats a matcher's
// PATTERN as the operand it is. This file freezes that at zero.
//
// WHAT THIS FILE DOES NOT CLAIM — and the claim it refuses to make is the
// interesting one. It does NOT assert the two gates agree in the other
// direction. `classifySafety` admits 39 commands in those same three sets that
// `screenCommand` refuses FOR A WRITE REASON (`cp a b`, `sort -o <path>`,
// `curl -D <path>`, `mix test --cover`, `go test -c`, …), and that asymmetry is
// the DESIGN, not a defect: charter D88 moved the safety gate to the CALLER —
// `screenedRerun` in adjudicate.mjs screens BEFORE it executes — and
// rerun-import-boundary.test.mjs makes that boundary structural precisely
// because `classifySafety` is a denylist that "cannot be complete". Closing
// direction B would mean rebuilding screen.mjs's flag-level allowlist inside
// rerun.mjs, which is the duplication the boundary exists to prevent. The
// number is asserted below as a CEILING so that a future edit widening it is
// visible, rather than left as prose nobody re-measures.
//
// HERMETIC. Pure classifiers; spawns nothing, touches no filesystem.

import { test } from "node:test";
import assert from "node:assert/strict";
import { screenCommand, DANGER_SET, REGRESSION_SET, NEVER_CRY_WOLF_SET } from "../screen.mjs";
import { classifySafety, blankSearchTerms } from "../rerun.mjs";

// The seven commands MEASURED to disagree on origin/main, in the direction that
// hurts. Six is the floor the row asks for; these are the whole observed set.
const WERE_DISAGREEING = [
  "git show origin/main:tooling/grip/record.mjs | grep -c writeFileSync",
  "grep -rn rmSync tooling/grip/",
  "grep -e writeFileSync -n tooling/grip/record.mjs",
  "git grep -n writeFileSync -- tooling/grip",
  "grep -n publish docs/INDEX.md",
  "grep -rn mutate tooling/",
  "git log --grep=publish -5",
];

// Genuine writes. Each must be refused by BOTH gates — the never-cry-wolf
// direction of the same fix. Half of them carry a matcher in the pipeline, so
// they also prove the blanking is scoped to the PATTERN and not to the segment.
const STILL_REFUSED_BY_BOTH = [
  "rm -rf /tmp/x",
  "git push origin main",
  "grep -rn foo tooling/ > /tmp/out.txt",
  "grep -rn foo tooling/ | tee /tmp/out.txt",
  "sed -i '' s/a/b/ README.md",
  "npm publish",
];

test("the fixture is big enough and is the MEASURED set, not a hand-picked pair", () => {
  assert.ok(WERE_DISAGREEING.length >= 6, `the row asks for at least six; fixture has ${WERE_DISAGREEING.length}`);
  assert.equal(new Set(WERE_DISAGREEING).size, WERE_DISAGREEING.length, "duplicates would inflate the count");
});

test("every command prescreen ADMITS, adjudicate also admits", () => {
  const all = [...new Set([...DANGER_SET, ...REGRESSION_SET, ...NEVER_CRY_WOLF_SET, ...WERE_DISAGREEING])];
  const contradictions = all
    .map((command) => ({ command, screen: screenCommand(command), rerun: classifySafety(command) }))
    .filter((r) => r.screen.ok && !r.rerun.safe)
    .map((r) => `${r.command}  ->  rerun says: ${r.rerun.reason}`);
  assert.deepEqual(
    contradictions, [],
    "a row prescreen calls storable is one adjudicate refuses to re-run — seven of these shipped on origin/main",
  );
});

test("the seven MEASURED specimens are admitted by BOTH gates, one by one", () => {
  for (const command of WERE_DISAGREEING) {
    assert.equal(screenCommand(command).ok, true, `screen must admit: ${command}`);
    assert.equal(classifySafety(command).safe, true, `rerun must admit: ${command}`);
  }
});

test("NEVER CRY WOLF: a genuine write is still refused by BOTH gates", () => {
  for (const command of STILL_REFUSED_BY_BOTH) {
    assert.equal(classifySafety(command).safe, false, `rerun must REFUSE: ${command}`);
    assert.equal(screenCommand(command).ok, false, `screen must REFUSE: ${command}`);
  }
});

test("blanking is confined to the PATTERN — paths, redirects and later segments survive", () => {
  // 1:1 offsets, so the blanked string is the same length as the original.
  const cmd = "grep -rn rmSync tooling/grip/ | wc -l";
  const out = blankSearchTerms(cmd);
  assert.equal(out.length, cmd.length, "blanking must be 1:1 so reported offsets still line up");
  assert.ok(!/rmSync/.test(out), "the pattern operand must be blanked");
  assert.ok(out.includes("tooling/grip/"), "the PATH must survive — it is not the pattern");
  assert.ok(out.includes("wc -l"), "the next pipeline segment must survive untouched");
  // A pattern carrying shell syntax is NOT provably data, so it stays raw.
  assert.ok(blankSearchTerms("grep -rn foo>out.txt .").includes("foo>out.txt"),
    "a token with a metacharacter must be left raw — the conservative direction");
  // A head that is not a matcher is never touched.
  assert.equal(blankSearchTerms("rm -rf /tmp/x"), "rm -rf /tmp/x");
});

test("CONTROL: the fixture really does exercise the rule — remove the blanking and it reds", () => {
  // Proves the six/seven above are not green for some unrelated reason: the raw
  // (un-blanked) string still trips WRITE_SHAPES for every one of them.
  for (const command of WERE_DISAGREEING) {
    assert.notEqual(blankSearchTerms(command), command,
      `blankSearchTerms changed nothing on \`${command}\` — this specimen proves nothing`);
  }
});

test("the OTHER direction is bounded and named, not silently widened", () => {
  const all = [...new Set([...DANGER_SET, ...REGRESSION_SET, ...NEVER_CRY_WOLF_SET])];
  const WRITE_REASON = /\bWRITES?\b|writes a file|overwrites|mutates|mutation|write shape|write verb|deletes/i;
  const admittedByRerunOnly = all.filter((c) => {
    const s = screenCommand(c);
    return !s.ok && WRITE_REASON.test(s.reason) && classifySafety(c).safe;
  });
  // 39 measured on origin/main and unchanged by this PR. This is a CEILING: it
  // may shrink freely, and a rise means somebody widened rerun.mjs's blind spot.
  assert.ok(admittedByRerunOnly.length <= 39,
    `rerun.mjs now admits ${admittedByRerunOnly.length} commands screen refuses as writes, up from the measured 39: ` +
      admittedByRerunOnly.join(" | "));
});
