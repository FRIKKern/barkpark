#!/usr/bin/env node
// THE REPO-WIDE GREP MUST NOT WALK NESTED WORKTREES — tooling/grip/trial-leads-vs-grep.mjs.
//
//   node --test tooling/grip/test/trial-leads-worktree-exclude.test.mjs
//
// WHY THIS FILE EXISTS. `scoreQuery` runs ONE repo-wide `grep -rIn … .`, and
// agents nest full checkouts of this repo under `.claude/worktrees/`. With
// `.claude` missing from REPO_WIDE_EXCLUDES that single grep walked the tree
// once per worktree: caught LIVE as PID 17091, `grep -rIn --exclude-dir=.git …`,
// cwd /Volumes/SATECHI/github/barkpark, ELAPSED 38:30 AND STILL RUNNING, a
// descendant of another agent's `node --test tooling/grip/test/*.test.mjs`,
// against 9 SECONDS for the same file from a clean worktree.
//
// WHY IT INSPECTS ARGV AND A BOUNDED CORPUS, NEVER A CLOCK. A timing assertion
// passes on any machine that happens to carry no worktrees — which is every CI
// runner and every reader who has just pruned. Such a green would read as "the
// gap does not exist" when it means "this filesystem does not have one today".
// So: (a) the constructed argv is read directly, and (b) the exclusion is
// exercised against a temp corpus this test PLANTS, so the subject is always
// present.
//
// AND IT PINS THE SPELLING. Measured on this host: BSD grep (/usr/bin/grep)
// matches --exclude-dir against the directory BASENAME only, so the obvious
// spelling `--exclude-dir=.claude/worktrees` skips NOTHING there. A fix that
// shipped the path form would have been a comment-shaped no-op on the very grep
// most likely to run, and no timing test on this machine (where `grep` is
// ugrep, which DOES honour the path form) would have caught it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_WIDE_EXCLUDES, grepFlags, runGrepCount } from "../trial-leads-vs-grep.mjs";

const TERM = "worktreeExcludeProbeToken";

/** A corpus with a nested worktree-shaped subtree, and the term in BOTH halves. */
function plantCorpus() {
  const root = mkdtempSync(join(tmpdir(), "grip-worktree-exclude-"));
  mkdirSync(join(root, "src"), { recursive: true });
  writeFileSync(join(root, "src", "real.txt"), `${TERM}\n`);
  mkdirSync(join(root, ".claude", "worktrees", "peer", "src"), { recursive: true });
  writeFileSync(join(root, ".claude", "worktrees", "peer", "src", "copy.txt"), `${TERM}\n${TERM}\n`);
  return root;
}

test("REPO_WIDE_EXCLUDES bounds the walk at .claude, where nested worktrees live", () => {
  assert.ok(REPO_WIDE_EXCLUDES.includes(".claude"),
    "REPO_WIDE_EXCLUDES must exclude .claude — PID 17091 ran 38:30 without it");
  assert.ok(REPO_WIDE_EXCLUDES.includes("worktrees"),
    "and `worktrees` as the portable catch for a worktree root parked outside .claude");
  assert.ok(REPO_WIDE_EXCLUDES.includes(".git"),
    "CONTROL: the pre-existing entries must still be there — this is an addition, not a replacement");
});

test("the CONSTRUCTED ARGV carries the exclusion — not a comment, a flag", () => {
  const argv = grepFlags(REPO_WIDE_EXCLUDES);
  assert.ok(argv.includes("--exclude-dir=.claude"),
    `the repo-wide grep argv must carry the exclusion: ${argv.join(" ")}`);
  assert.ok(argv.includes("--exclude-dir=worktrees"), `argv: ${argv.join(" ")}`);
  assert.equal(argv[0], "-rIn", "CONTROL: the argv builder still produces the command the report DEFINES");
});

test("BASENAME, NOT PATH: the path spelling must not be what ships", () => {
  // BSD grep matches --exclude-dir against the basename, so `.claude/worktrees`
  // is a no-op there. If a later edit 'clarifies' the entry to the path form,
  // this reds instead of silently restoring the 38:30.
  for (const entry of REPO_WIDE_EXCLUDES) {
    assert.ok(!entry.includes("/"),
      `--exclude-dir matches a BASENAME on BSD grep; "${entry}" would skip nothing there`);
  }
});

test("the exclusion is APPLIED: a planted nested worktree is not counted", () => {
  const root = plantCorpus();
  try {
    const withExcludes = runGrepCount(TERM, root, { excludeDirs: REPO_WIDE_EXCLUDES });
    const without = runGrepCount(TERM, root, { excludeDirs: [] });
    // CONTROL FIRST: the corpus really does contain the extra matches, so an
    // equal-count result below cannot be "there was nothing to exclude".
    assert.equal(without.count, 3, `the planted corpus must hold 3 matching lines, saw ${without.count}`);
    assert.equal(withExcludes.count, 1,
      `only src/real.txt may be counted; the .claude/worktrees copy leaked (${withExcludes.count})`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
