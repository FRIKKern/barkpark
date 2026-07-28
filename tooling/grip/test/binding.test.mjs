// binding.test.mjs — the acceptance corpus for the binding grammar.
//
//   node --test tooling/grip/test/binding.test.mjs
//
// THE ACCEPTANCE CORPUS IS THE 652-PROOF FIXTURE, NOT THE 62-ROW STORE (D81).
// The store is 82% shared-ref; fixtures/evidence-corpus.json is its MIRROR. Five
// of the seven forms that resist a naive grammar — `git status`, `git diff`,
// bare `git log`, SHA-pinned reads, `stash` / `rev-parse HEAD` — have ZERO
// instances in the 62 rows, so a classifier gated only there CANNOT FAIL and
// ships green. Every one of those five is a named case below, and the 652 proofs
// are run in full.
//
// Two numbers are REPORTED rather than asserted, because they are the ones that
// tell a reviewer whether the grammar discriminates or merely absorbs:
//   * the share of verdicts arriving via a DEFAULT/else rule, and
//   * the share whose CLASS equals what a trivial always-cwd-bound classifier
//     would have said anyway.
// A low first number with a high second one means the rule names are carrying
// the signal, not the classes — which is exactly what a reader must be able to
// see. They are printed by the run.

import { test } from "node:test";
import assert from "node:assert/strict";

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  classifyBinding,
  classifyAll,
  isDefaultRule,
  BINDING_CLASSES,
  BINDING_RULES,
  PORTABLE_SCOPES,
  EXIT_MASK_RULES,
} from "../binding.mjs";
import { readLedgerRuns, inScope } from "../ledger.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const GRIP = resolve(HERE, "..");

// The three run files the D73 census was derived from. They are named rather
// than globbed ON PURPOSE: the store is append-only (wx/O_EXCL, no update verb,
// no delete verb), so a later wave's run file is a LATER corpus. Pinning these
// three keeps this a regression test instead of a number that drifts out from
// under the charter it encodes.
//
// READ THE SCOPE OF THAT SANCTION NARROWLY. It licenses a pin for a test that
// asserts FROZEN COUNTS over a frozen corpus, and nothing else. It does NOT
// license pinning a test whose name promises the whole store — re-pointing the
// mint REGRESSION FLOOR at this same list turns "307 of 631 rows moved" into
// "0 of 62" and passes, because these three files are 9.8% of the rows and
// carry 0.0% of the drift. That test walks by run SHAPE and prints what it
// walked; see mint.test.mjs.
const CENSUS_RUN_FILES = [
  "grip-20260721T034616Z-f6119a27ebcf62cf.json",
  "grip-20260721T054733Z-2dce8ffd806cfc3d.json",
  "grip-20260721T054846Z-56338e4f0a3543e5.json",
];

function ledgerRows(files) {
  const rows = [];
  for (const file of files) {
    const run = JSON.parse(readFileSync(resolve(GRIP, "ledger", file), "utf8"));
    rows.push(...run.recipes);
  }
  return rows;
}

function corpusProofs() {
  return JSON.parse(readFileSync(resolve(GRIP, "fixtures", "evidence-corpus.json"), "utf8")).proofs;
}

// --- export shape and purity -------------------------------------------------

test("binding.mjs exposes the named surface and freezes its tables", () => {
  assert.equal(typeof classifyBinding, "function");
  assert.equal(typeof classifyAll, "function");
  assert.equal(typeof isDefaultRule, "function");
  assert.ok(Object.isFrozen(BINDING_CLASSES));
  assert.ok(Object.isFrozen(PORTABLE_SCOPES));
  assert.ok(Object.isFrozen(BINDING_RULES));
  assert.ok(Object.isFrozen(EXIT_MASK_RULES));
});

test("there are exactly FIVE classes, in D73's most-portable-first order", () => {
  assert.deepEqual(BINDING_CLASSES, [
    "content-addressed",
    "shared-ref",
    "per-worktree",
    "cwd-bound",
    "foreign-tree-pinned",
  ]);
});

test("every registered rule names a real class, and every class has a rule", () => {
  const classesWithRules = new Set();
  for (const entry of BINDING_RULES) {
    if (entry.class === null) continue;
    assert.ok(BINDING_CLASSES.includes(entry.class), `${entry.rule} names an unknown class`);
    assert.equal(typeof entry.what, "string");
    assert.notEqual(entry.what, "");
    classesWithRules.add(entry.class);
  }
  assert.deepEqual([...classesWithRules].sort(), [...BINDING_CLASSES].sort());
});

// PURITY IS PROVEN MECHANICALLY, not promised in a comment. A classifier that
// shells out is a classifier whose verdict depends on the box it ran on — the
// exact defect this module exists to describe.
test("the module reads no file, spawns nothing, and reads no clock", () => {
  const source = readFileSync(resolve(GRIP, "binding.mjs"), "utf8");
  const imports = [...source.matchAll(/^import[^;]*?from\s+"([^"]+)"/gm)].map((m) => m[1]);
  assert.deepEqual(imports, ["./level.mjs"]);
  const code = source
    .split("\n")
    .filter((line) => !line.trim().startsWith("//"))
    .join("\n");
  for (const forbidden of ["node:fs", "node:child_process", "readFileSync", "spawnSync", "execSync", "Date.now", "new Date", "process.env"]) {
    assert.ok(!code.includes(forbidden), `binding.mjs must not reference ${forbidden}`);
  }
});

// --- the table: every class, every resisting form ---------------------------
//
// `rule` is asserted, never just `class`. A form that lands in the right bucket
// through an else branch is right by accident, and D81 measured that accident at
// 568 of 652 on the corpus below.

const TABLE = [
  // --- content-addressed: SHA-pinned. ZERO instances in the 62-row store, and
  // the form a 3-way split inverts into "answers about YOUR tree".
  ["git show 45c34d3d:tooling/grip/level.mjs | wc -l", "content-addressed", "SHA-PIN-REVISION", "45c34d3d"],
  ["git show --stat 45c34d3d", "content-addressed", "SHA-PIN-REVISION", "45c34d3d"],
  ["git log --oneline -1 15e057f83ba0c59a809364202e5eed91e1650fad", "content-addressed", "SHA-PIN-REVISION", "15e057f83ba0c59a809364202e5eed91e1650fad"],
  ["git show 3c7f5de1 --format=%B", "content-addressed", "SHA-PIN-REVISION", "3c7f5de1"],

  // --- shared-ref
  ["git show origin/main:tooling/grip/level.mjs | wc -l", "shared-ref", "REMOTE-TRACKING-REF", "origin/main"],
  ["git ls-tree -r origin/main --name-only .github/workflows/ | wc -l", "shared-ref", "REMOTE-TRACKING-REF", "origin/main"],
  ["git grep -n 'def upsert_paper' origin/main -- api/lib", "shared-ref", "REMOTE-TRACKING-REF", "origin/main"],
  ["git log --oneline d23b3e628..origin/main | wc -l", "shared-ref", "REMOTE-TRACKING-REF", "origin/main"],
  ["git show upstream/release:package.json", "shared-ref", "REMOTE-TRACKING-REF", "upstream/release"],
  ["git for-each-ref --contains 800fdb6a9 refs/remotes", "shared-ref", "REMOTE-TRACKING-REF", "refs/remotes"],
  ["git ls-remote origin 'refs/heads/*cf*'", "shared-ref", "GIT-REMOTE-SERVER-OP", "ls-remote"],

  // --- per-worktree, INCLUDING the index-bound family. Zero instances of
  // status / diff / stash / rev-parse HEAD / bare log in the 62-row store.
  ["git ls-files tooling/grip/ledger/", "per-worktree", "INDEX-BOUND-FAMILY", "ls-files"],
  ["git status --porcelain", "per-worktree", "INDEX-BOUND-FAMILY", "status"],
  ["git diff --stat", "per-worktree", "INDEX-BOUND-FAMILY", "diff"],
  ["git stash list", "per-worktree", "INDEX-BOUND-FAMILY", "stash"],
  ["git ls-tree HEAD --name-only tooling/grip/ledger/", "per-worktree", "WORKTREE-HEAD-REF", "HEAD"],
  ["git rev-parse HEAD", "per-worktree", "WORKTREE-HEAD-REF", "HEAD"],
  ["git log --oneline -5", "per-worktree", "BARE-GIT-LOCAL-STATE", null],
  ["git grep -n reveal_fields -- api/lib", "per-worktree", "WORKTREE-CONTENT-SCAN", "grep"],
  ["git merge-base --is-ancestor 57e3be94c18abb230724358be97111739093bb12 main", "per-worktree", "LOCAL-BRANCH-REF", "main"],

  // --- cwd-bound
  ["grep -c needs_worktree .claude/workflows/bp-epic-cycle.workflow.js", "cwd-bound", "RELATIVE-PATH-READ", null],
  ["wc -l tooling/grip/mint.mjs", "cwd-bound", "RELATIVE-PATH-READ", null],
  ["CC=/usr/bin/clang go test ./internal/cli/", "cwd-bound", "TOOLCHAIN-CWD-ROOTED", null],
  ["curl -s http://localhost:4000/api/schemas", "cwd-bound", "NETWORK-READ-NO-TREE", null],

  // --- foreign-tree-pinned
  ["grep -n 'D36' /Volumes/SATECHI/github/barkpark/.claude/worktrees/spill-janitor-wt/.claude/workflows/bp-truth-grip-charter.md", "foreign-tree-pinned", "ABS-PATH-EPHEMERAL-WORKTREE", "/Volumes/SATECHI/github/barkpark/.claude/worktrees/spill-janitor-wt/.claude/workflows/bp-truth-grip-charter.md"],
  ["grep -n GR83 /Volumes/SATECHI/github/barkpark/api/lib/barkpark/content/query.ex", "foreign-tree-pinned", "ABS-PATH-PINNED", "/Volumes/SATECHI/github/barkpark/api/lib/barkpark/content/query.ex"],
  ["wc -l /tmp/gotest_full.log", "foreign-tree-pinned", "ABS-PATH-SCRATCH", "/tmp/gotest_full.log"],
  ["ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl is-active barkpark'", "foreign-tree-pinned", "REMOTE-HOST-READ", "root@157.180.90.121"],
];

for (const [command, expectedClass, expectedRule, expectedAnchor] of TABLE) {
  test(`${expectedRule} → ${expectedClass}: ${command.slice(0, 64)}`, () => {
    const verdict = classifyBinding(command);
    assert.equal(verdict.binding_class, expectedClass);
    assert.equal(verdict.rule, expectedRule);
    assert.equal(verdict.anchor, expectedAnchor);
    assert.equal(verdict.portable_scope, PORTABLE_SCOPES[expectedClass]);
    assert.ok(verdict.reason.length > 20, "every verdict carries a reason in words");
    assert.ok(Object.isFrozen(verdict));
  });
}

test("the table covers every one of the five classes", () => {
  const covered = new Set(TABLE.map(([, cls]) => cls));
  assert.deepEqual([...covered].sort(), [...BINDING_CLASSES].sort());
});

// --- the verdict shape ------------------------------------------------------

test("a verdict carries the six contract keys plus cd_prefix and the mask severity", () => {
  const verdict = classifyBinding("cd /Volumes/SATECHI/github/barkpark && git show origin/main:x | wc -l");
  assert.deepEqual(Object.keys(verdict).sort(), [
    "anchor",
    "binding_class",
    "cd_prefix",
    "exit_mask_rule",
    "exit_masked",
    "portable_scope",
    "reason",
    "rule",
  ]);
});

// --- the cd prefix is INERT (D73's whole point) ------------------------------

test("a `cd <abs> &&` prefix does not decide the class — the REST does", () => {
  const bare = classifyBinding("git show origin/main:internal/cli/tasks_next_cmd.go | wc -l");
  const prefixed = classifyBinding(
    "cd /Volumes/SATECHI/github/barkpark && git show origin/main:internal/cli/tasks_next_cmd.go | wc -l",
  );
  assert.equal(prefixed.binding_class, bare.binding_class);
  assert.equal(prefixed.rule, bare.rule);
  assert.equal(prefixed.anchor, bare.anchor);
  assert.equal(prefixed.cd_prefix, "/Volumes/SATECHI/github/barkpark");
  assert.equal(bare.cd_prefix, null);
});

test("`git -C <path>` is the same statement as a cd prefix and is recorded the same way", () => {
  const verdict = classifyBinding(
    "git -C /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_e3a3a728-f3c-19 diff --cached -- api/lib/x.ex",
  );
  assert.equal(verdict.binding_class, "per-worktree");
  assert.equal(verdict.rule, "INDEX-BOUND-FAMILY");
  assert.equal(verdict.cd_prefix, "/Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_e3a3a728-f3c-19");
});

test("a QUOTED or substituted cd target is recorded whole, not as its first token", () => {
  // `cd "$(git rev-parse --show-toplevel)"` is this epic's own wave-gate line.
  // Tokenising it recorded the fragment `"$(git`, which then rendered verbatim
  // inside `reason` — a garbage string in the one field a reader is told to
  // read instead of the class.
  assert.equal(
    classifyBinding(`cd "$(git rev-parse --show-toplevel)" && node --test tooling/grip/test/binding.test.mjs`).cd_prefix,
    "$(git rev-parse --show-toplevel)",
  );
  assert.equal(
    classifyBinding(`cd '/Volumes/SATECHI/github/bark park' && git ls-files .`).cd_prefix,
    "/Volumes/SATECHI/github/bark park",
  );
});

test("an absolute path in the READ still pins, even under a cd prefix", () => {
  const verdict = classifyBinding(
    "cd /tmp && grep -n needs_worktree /Volumes/SATECHI/github/barkpark/.claude/workflows/bp-epic-cycle.workflow.js",
  );
  assert.equal(verdict.binding_class, "foreign-tree-pinned");
  assert.equal(verdict.cd_prefix, "/tmp");
});

// --- portable_scope: never "anywhere" for shared-ref (D75) -------------------

test("shared-ref reads 'any worktree of this clone' and the word 'anywhere' appears nowhere", () => {
  const verdict = classifyBinding("git show origin/main:tooling/grip/level.mjs | wc -l");
  assert.equal(verdict.binding_class, "shared-ref");
  assert.equal(verdict.portable_scope, "any worktree of this clone");
  for (const scope of Object.values(PORTABLE_SCOPES)) {
    assert.ok(!/anywhere/i.test(scope), `portable_scope "${scope}" must not promise anywhere`);
  }
  // D75, measured: a clone's refs/remotes/origin/* mirrors the SOURCE's
  // refs/heads/*, so source origin/main 515f14fdd resolves to a96aacce6 in the
  // clone — 41 commits and 69 files apart, and this very recipe answers 339 in
  // the clone against 615 in the primary, BOTH exit 0.
  assert.notEqual(verdict.portable_scope, PORTABLE_SCOPES["content-addressed"]);
});

test("only a SHA pin is allowed to claim 'any clone'", () => {
  assert.equal(PORTABLE_SCOPES["content-addressed"], "any clone");
  const claimants = Object.entries(PORTABLE_SCOPES).filter(([, scope]) => scope === "any clone");
  assert.deepEqual(claimants.map(([cls]) => cls), ["content-addressed"]);
});

// --- exit masking (D76), with the mechanism corrected -----------------------

test("exit_masked is TRUE piped and FALSE unpiped for the same read", () => {
  const piped = classifyBinding("git show origin/main:tooling/grip/level.mjs | wc -l");
  const unpiped = classifyBinding("git show origin/main:tooling/grip/level.mjs");
  assert.equal(piped.exit_masked, true);
  assert.equal(piped.exit_mask_rule, "MASK-PIPE-EXIT-AND-VALUE");
  assert.equal(unpiped.exit_masked, false);
  assert.equal(unpiped.exit_mask_rule, null);
  // Same class either way — masking is a SEPARATE axis from binding.
  assert.equal(piped.binding_class, unpiped.binding_class);
});

test("the three mask severities are distinguished, because D76's single bit hides them", () => {
  // Measured: `git show origin/main:nope.txt 2>/dev/null | …`
  //   wc -l   → prints 0, exits 0   (status AND value fabricated)
  //   grep -c → prints 0, exits 1   (value fabricated, status survives)
  //   grep -n → prints nothing, exits 1 (a failure that reads as a real absence)
  assert.equal(classifyBinding("git show origin/main:x | wc -l").exit_mask_rule, "MASK-PIPE-EXIT-AND-VALUE");
  assert.equal(classifyBinding("git show origin/main:x | grep -c func").exit_mask_rule, "MASK-PIPE-VALUE");
  assert.equal(classifyBinding("git show origin/main:x | grep -n func").exit_mask_rule, "MASK-PIPE-SILENT");
});

test("a `|` inside a QUOTED pattern is not a pipeline, and must not fabricate a mask warning", () => {
  // Regression: the pipeline split ran over the RAW statement while every other
  // scan ran over the quote-masked copy, so a grep alternation read as a pipe.
  // Measured over fixtures/evidence-corpus.json: 46 of 652 proofs (7.1%) were
  // reported exit_masked with no pipe anywhere in them. A module whose product
  // is honest warnings cannot ship a fabricated one on 7% of its input.
  for (const command of [
    `grep -nE "foo|bar" tooling/grip/leads.mjs`,
    `grep -n 'lifecycle\\|worker' scripts/pr-task-gate.sh`,
    `rg "a|b" tooling/grip/`,
  ]) {
    const verdict = classifyBinding(command);
    assert.equal(verdict.exit_masked, false, command);
    assert.equal(verdict.exit_mask_rule, null, command);
  }
  // …and a REAL pipe over a quoted alternation still masks.
  const piped = classifyBinding(`git show origin/main:x | grep -c "a|b"`);
  assert.equal(piped.exit_masked, true);
  assert.equal(piped.exit_mask_rule, "MASK-PIPE-VALUE");
});

test("`set -o pipefail` clears the mask — the read's failure reaches the caller", () => {
  const verdict = classifyBinding("set -o pipefail; git show origin/main:x | wc -l");
  assert.equal(verdict.exit_masked, false);
  assert.equal(verdict.binding_class, "shared-ref");
});

// --- quote masking ----------------------------------------------------------

test("a ref-shaped token inside a grep PATTERN does not forge a ref verdict", () => {
  const verdict = classifyBinding("grep -c 'origin/main' tooling/grip/level.mjs");
  assert.equal(verdict.binding_class, "cwd-bound");
  assert.equal(verdict.rule, "RELATIVE-PATH-READ");
});

test("a HEAD-shaped token inside a quoted pattern does not forge a per-worktree verdict", () => {
  const verdict = classifyBinding("git show origin/main:docs/x.md | grep -n 'HEAD of the deploy'");
  assert.equal(verdict.binding_class, "shared-ref");
  assert.equal(verdict.anchor, "origin/main");
});

// --- the floor rule ---------------------------------------------------------

test("a compound takes the LEAST portable of its reads", () => {
  const verdict = classifyBinding("git show origin/main:x > /tmp/a && grep -c foo tooling/grip/level.mjs");
  assert.equal(verdict.binding_class, "cwd-bound");
});

test("HEAD beats origin/main in the same statement — HEAD is what varies", () => {
  const verdict = classifyBinding("git rev-parse HEAD origin/main && git rev-list --left-right --count HEAD...origin/main");
  assert.equal(verdict.binding_class, "per-worktree");
  assert.equal(verdict.rule, "WORKTREE-HEAD-REF");
});

test("origin/main beats a SHA in the same statement — the moving end decides", () => {
  const verdict = classifyBinding("git merge-base --is-ancestor 790aeaf08 origin/main && echo YES");
  assert.equal(verdict.binding_class, "shared-ref");
  assert.equal(verdict.anchor, "origin/main");
});

test("an ELSE branch never outranks a rule that fired", () => {
  // `&& echo YES` is not a read. Letting its DEFAULT verdict into the floor
  // demoted 51 of the 652 corpus proofs from a real ref verdict to cwd-bound.
  const verdict = classifyBinding("git show origin/main:api/.sobelow-skips | grep -n -i quiz; echo exit:$?");
  assert.equal(verdict.binding_class, "shared-ref");
  assert.ok(!isDefaultRule(verdict.rule));
});

test("a migration timestamp is not an object id", () => {
  // 20260629160000 is 14 digits. A hex rule with no letter requirement mints
  // content-addressed out of a migration filename.
  const verdict = classifyBinding(
    "git show origin/main:api/priv/repo/migrations/20260629160000_data_keys_one_active_per_scope.exs",
  );
  assert.equal(verdict.binding_class, "shared-ref");
  assert.equal(verdict.rule, "REMOTE-TRACKING-REF");
});

// --- the missing-command floor ----------------------------------------------

test("a missing or prose rerun DEMOTES to unknown — it is never guessed at", () => {
  for (const input of ["", "   ", null, undefined, 42, "git checkout origin/main -- <55 files>"]) {
    const verdict = classifyBinding(input);
    assert.equal(verdict.binding_class, null);
    assert.equal(verdict.rule, "NO-COMMAND");
    assert.equal(verdict.portable_scope, "unknown");
  }
});

// --- (b) the real committed ledger: the ref-identity census -----------------

test("classifyAll over the 62 committed rows reproduces the D73 ref-identity census", () => {
  const rows = ledgerRows(CENSUS_RUN_FILES);
  assert.equal(rows.length, 62);
  const census = classifyAll(rows);

  // The FIVE-class census. `git ls-files` is per-worktree here BY RULE
  // (INDEX-BOUND-FAMILY), which is where D73's own five-class enumeration puts
  // it; D73's earlier THREE-way reading counted it under "working-tree" and so
  // reported 1 per-worktree rather than 2. Both readings are reproduced below,
  // and the reconciliation is the next assertion rather than a choice between
  // them.
  assert.deepEqual(census.by_class, {
    "content-addressed": 0,
    "shared-ref": 51,
    "per-worktree": 2,
    "cwd-bound": 7,
    "foreign-tree-pinned": 2,
  });
  assert.equal(census.unclassified, 0);
  assert.equal(census.default_rule.count, 0, "not one stored row reaches an else branch");

  // D73's three-way census, re-derived from the same verdicts:
  //   51 shared-ref | 1 per-worktree HEAD | 10 working-tree (2 absolute)
  const headBound = census.verdicts.filter((v) => v.rule === "WORKTREE-HEAD-REF").length;
  const workingTree = census.verdicts.filter(
    (v) => v.rule === "INDEX-BOUND-FAMILY" || v.binding_class === "cwd-bound" || v.binding_class === "foreign-tree-pinned",
  ).length;
  assert.equal(census.by_class["shared-ref"], 51);
  assert.equal(headBound, 1);
  assert.equal(workingTree, 10);
  assert.equal(census.by_class["foreign-tree-pinned"], 2);

  // The inversion, in one line: 44 rows carry an absolute checkout path AND
  // answer identically from any worktree of this clone.
  const absoluteSharedRef = census.verdicts.filter(
    (v) => v.binding_class === "shared-ref" && v.cd_prefix !== null,
  ).length;
  assert.equal(absoluteSharedRef, 44);

  console.log(
    `\n  [ledger census] 62 rows → ${JSON.stringify(census.by_class)}\n` +
      `  [ledger census] D73 three-way re-derivation: shared-ref 51 | per-worktree HEAD ${headBound} | working-tree ${workingTree} (of which foreign-tree-pinned 2)\n` +
      `  [ledger census] 44 shared-ref rows carry a cd prefix — a path screen would refuse all 44 and admit the 9 decided by cwd\n` +
      `  [ledger census] else-branch verdicts: ${census.default_rule.count}\n`,
  );
});

test("every row of the 62 carries exit_masked, and 49 of them mask their failure (D76)", () => {
  const census = classifyAll(ledgerRows(CENSUS_RUN_FILES));
  assert.equal(census.exit_masked, 49);
  // D76's COUNT reproduces; its MECHANISM does not. 44 rows end in a counter,
  // not 49 — the other 5 end in `grep -n`, which fabricates no quantity but
  // turns a failed read into an absence indistinguishable from a real no-match.
  assert.deepEqual(census.by_exit_mask_rule, {
    "MASK-PIPE-EXIT-AND-VALUE": 22,
    "MASK-PIPE-VALUE": 22,
    "MASK-PIPE-SILENT": 5,
  });
  console.log(
    `\n  [exit masking] 49 of 62 stored rows mask a failed read: ` +
      `22 × wc -l (prints 0, exits 0) | 22 × grep -c (prints 0, exits 1) | 5 × grep -n (empty, exits 1)\n` +
      `  [exit masking] 0 of 62 carry \`set -o pipefail\`\n`,
  );
});

test("the WHOLE ledger directory stays internally consistent, however many runs it grows to", () => {
  // Reads the directory rather than the three pinned files, so a later wave's
  // appended run is covered too. The assertions are the invariants that survive
  // growth — a class↔scope mismatch or an unregistered rule name is a defect in
  // any corpus — while the counts stay in the pinned test above, where they
  // cannot drift out from under the charter.
  //
  // WHY THIS WALKS `readLedgerRuns` AND NOT `readdirSync`. It used to do the
  // latter and `rows.push(...run.recipes)` at :57, which did not fail an
  // assertion — it CRASHED, `TypeError: run.recipes is not iterable`, the first
  // time a neighbouring epic parked a non-run JSON document in the shared
  // commons (D118: four epics write here and none may delete another's file).
  // The fix is the SHAPE predicate the ledger module already owns — a run is
  // `Array.isArray(recipes) && typeof run_id === "string"` — never a pinned
  // list of filenames. A pin would have made this green and blind: the store
  // grows, the pin does not, and nothing says so.
  const { runs, shape } = readLedgerRuns(resolve(GRIP, "ledger"));
  const owned = runs.filter((run) => inScope(run, "owned"));
  assert.ok(owned.length >= CENSUS_RUN_FILES.length, `the store must still hold at least the ${CENSUS_RUN_FILES.length} census runs — found ${owned.length}`);
  const registered = new Set(BINDING_RULES.map((entry) => entry.rule));
  const census = classifyAll(owned.flatMap((run) => run.recipes));
  for (const verdict of census.verdicts) {
    assert.ok(registered.has(verdict.rule), `unregistered rule ${verdict.rule}`);
    if (verdict.binding_class === null) {
      assert.equal(verdict.rule, "NO-COMMAND");
      continue;
    }
    assert.ok(BINDING_CLASSES.includes(verdict.binding_class));
    assert.equal(verdict.portable_scope, PORTABLE_SCOPES[verdict.binding_class]);
    assert.equal(typeof verdict.exit_masked, "boolean");
  }
  // THE WALKED SCOPE IS PRINTED ON PASS, not only inside a failure message.
  // What a green run declines to read is exactly as load-bearing as what it
  // reads, and a reviewer must be able to see the decline without editing the
  // test.
  console.log(
    `\n  [ledger dir] scope=owned — walked ${owned.length} of ${shape.runs} run file(s), ${census.total} rows → ${JSON.stringify(census.by_class)}` +
      `, unclassified ${census.unclassified}, else-branch ${census.default_rule.count}` +
      `\n  [ledger dir] declined: ${shape.foreign} foreign run file(s) with no run_id, ${shape.not_a_run} NOT-A-RUN document(s), ${shape.malformed_run} MALFORMED-RUN, ${shape.unparseable} UNPARSEABLE\n`,
  );
});

// --- (c) the 652-proof corpus, and the numbers that matter ------------------

test("classifyAll over the 652-proof corpus classifies every real command and REPORTS its else-branch share", () => {
  const proofs = corpusProofs();
  assert.equal(proofs.length, 652);
  const census = classifyAll(proofs);
  assert.equal(census.total, 652);

  // Every verdict is either one of the five classes or the honest NO-COMMAND
  // floor. Nothing silently falls out of the grammar.
  for (const verdict of census.verdicts) {
    if (verdict.binding_class === null) {
      assert.equal(verdict.rule, "NO-COMMAND");
      continue;
    }
    assert.ok(BINDING_CLASSES.includes(verdict.binding_class));
  }

  const defaultShare = census.default_rule.count / census.total;
  const trivialAgreement = census.by_class["cwd-bound"] / census.total;

  console.log(
    `\n  [corpus 652] by_class ${JSON.stringify(census.by_class)} + ${census.unclassified} prose/placeholder rows (NO-COMMAND)\n` +
      `  [corpus 652] DEFAULT/else verdicts: ${census.default_rule.count} of 652 = ${(defaultShare * 100).toFixed(1)}%\n` +
      `  [corpus 652] verdicts whose CLASS a trivial always-cwd-bound classifier would also have produced: ` +
      `${census.by_class["cwd-bound"]} of 652 = ${(trivialAgreement * 100).toFixed(1)}% — the rule names, not the class, carry the signal here\n` +
      `  [corpus 652] rules fired: ${JSON.stringify(census.by_rule)}\n` +
      `  [corpus 652] exit_masked: ${census.exit_masked}; cd/-C prefixed: ${census.cd_prefixed}\n`,
  );

  // Asserted as a CEILING, not as a score: if a future edit pushes the else
  // branch back above a fifth of the corpus, the grammar has stopped
  // discriminating and this test says so.
  assert.ok(defaultShare < 0.2, `else-branch share ${defaultShare} must stay under 20%`);
});

test("the five resisting forms are PRESENT in the 652-proof corpus and absent from the 62-row store", () => {
  // D81's reason the store cannot be the gate: five of the seven resisting
  // forms have ZERO instances there, so a grammar tuned to it cannot fail.
  const corpus = classifyAll(corpusProofs());
  const store = classifyAll(ledgerRows(CENSUS_RUN_FILES));

  const resisting = ["SHA-PIN-REVISION", "INDEX-BOUND-FAMILY", "BARE-GIT-LOCAL-STATE", "REMOTE-HOST-READ"];
  for (const rule of resisting) {
    assert.ok((corpus.by_rule[rule] ?? 0) > 0, `${rule} must have a specimen in the 652-proof corpus`);
  }
  // `git status` / `git diff` / bare `git log` / SHA pins / stash: the store has
  // exactly one index-bound row (`git ls-files`) and no SHA pin at all.
  assert.equal(store.by_rule["SHA-PIN-REVISION"] ?? 0, 0);
  assert.equal(store.by_rule["BARE-GIT-LOCAL-STATE"] ?? 0, 0);
  assert.equal(store.by_rule["INDEX-BOUND-FAMILY"] ?? 0, 1);
  console.log(
    `\n  [D81] resisting forms in the 652-proof corpus: ` +
      resisting.map((rule) => `${rule}=${corpus.by_rule[rule] ?? 0}`).join(" ") +
      `\n  [D81] the same forms in the 62-row store: SHA-PIN-REVISION=0 BARE-GIT-LOCAL-STATE=0 INDEX-BOUND-FAMILY=1 REMOTE-HOST-READ=0\n`,
  );
});

// --- (d) THE MUTATION PROOF: the classifier CAN fail ------------------------
//
// A deliberately naive 3-way rule, written exactly as the obvious version of
// this feature would be. It is the thing this slice exists to beat, and the
// assertions below show it losing on the two forms D73 names.

function naiveThreeWay(command) {
  if (/origin\//.test(command)) return "shared-ref";
  if (/HEAD/.test(command)) return "per-worktree";
  return "working-tree"; // the else branch
}

test("MUTATION: a SHA-pinned read is NOT cwd-bound — the naive rule says it is", () => {
  const command = "git show 45c34d3d:tooling/grip/level.mjs | wc -l";

  // The naive rule drops the MOST portable form into its else branch and calls
  // it "answers about YOUR tree". Shown failing, not described as failing.
  assert.equal(naiveThreeWay(command), "working-tree");
  assert.throws(
    () => assert.notEqual(naiveThreeWay(command), "working-tree"),
    /Expected "actual" to be strictly unequal/,
    "the naive rule must be shown getting this wrong",
  );

  const verdict = classifyBinding(command);
  assert.notEqual(verdict.binding_class, "cwd-bound");
  assert.notEqual(verdict.binding_class, "per-worktree");
  assert.equal(verdict.binding_class, "content-addressed");
  assert.equal(verdict.rule, "SHA-PIN-REVISION");
  assert.ok(!isDefaultRule(verdict.rule), "and it must not arrive via an else branch");
});

test("MUTATION: `git ls-files` is NOT cwd-bound, and is not right-by-accident either", () => {
  const command = "git ls-files tooling/grip/ledger/";

  assert.equal(naiveThreeWay(command), "working-tree");
  assert.throws(
    () => assert.notEqual(naiveThreeWay(command), "working-tree"),
    /Expected "actual" to be strictly unequal/,
  );

  const verdict = classifyBinding(command);
  assert.notEqual(verdict.binding_class, "cwd-bound");
  assert.equal(verdict.binding_class, "per-worktree");
  assert.equal(verdict.rule, "INDEX-BOUND-FAMILY");
  assert.ok(!isDefaultRule(verdict.rule));
  // Proven divergent INSIDE one tree: `git ls-files tooling/grip/ledger/`
  // returns 2 where `git ls-tree HEAD --name-only tooling/grip/ledger/`
  // returns 1. The index at .git/worktrees/<name>/index is not shared.
});

test("MUTATION: the naive rule's answers arrive overwhelmingly via its else branch", () => {
  const proofs = corpusProofs();
  const naive = proofs.map((proof) => naiveThreeWay(String(proof.command ?? "")));
  const elseCount = naive.filter((answer) => answer === "working-tree").length;
  const elseShare = elseCount / proofs.length;

  const census = classifyAll(proofs);
  const ourElseShare = census.default_rule.count / census.total;

  console.log(
    `\n  [mutation] naive 3-way: ${elseCount} of ${proofs.length} = ${(elseShare * 100).toFixed(1)}% of its answers come from the ELSE branch\n` +
      `  [mutation] this grammar: ${census.default_rule.count} of ${census.total} = ${(ourElseShare * 100).toFixed(1)}%\n`,
  );

  assert.ok(elseShare > 0.7, "the naive rule really is an else-branch machine");
  assert.ok(ourElseShare < elseShare / 4, "and this grammar must be materially better, not marginally");
});

test("MUTATION: a path-shape screen would refuse the 44 portable rows and admit the 9 that are not", () => {
  const rows = ledgerRows(CENSUS_RUN_FILES);
  const census = classifyAll(rows);

  const absolute = rows.filter((row) => /\s\/[A-Za-z]/.test(row.rerun) || /^cd\s+\//.test(row.rerun));
  const refusedButPortable = census.verdicts.filter(
    (verdict, i) => verdict.binding_class === "shared-ref" && absolute.includes(rows[i]),
  ).length;
  const admittedButNot = census.verdicts.filter(
    (verdict, i) => verdict.binding_class !== "shared-ref" && !absolute.includes(rows[i]),
  ).length;

  assert.equal(refusedButPortable, 44);
  assert.equal(admittedButNot, 9);
  console.log(
    `\n  [anti-signal] a screen on absolute paths would REFUSE ${refusedButPortable} rows that answer identically from any worktree\n` +
      `  [anti-signal] and ADMIT ${admittedButNot} rows whose answer is decided by cwd or by HEAD\n`,
  );
});

// --- classifyAll shape ------------------------------------------------------

test("classifyAll accepts strings, ledger rows and corpus proofs alike", () => {
  const census = classifyAll([
    "git show origin/main:x",
    { rerun: "git ls-files ." },
    { command: "grep -c foo bar.mjs" },
    { nothing: true },
  ]);
  assert.equal(census.total, 4);
  assert.equal(census.by_class["shared-ref"], 1);
  assert.equal(census.by_class["per-worktree"], 1);
  assert.equal(census.by_class["cwd-bound"], 1);
  assert.equal(census.unclassified, 1);
  assert.ok(Object.isFrozen(census));
  assert.ok(Object.isFrozen(census.by_class));
});

test("classifyAll over nothing is empty, not a crash", () => {
  const census = classifyAll([]);
  assert.equal(census.total, 0);
  assert.equal(census.default_rule.share, 0);
  assert.deepEqual(census.verdicts, []);
  assert.equal(classifyAll(null).total, 0);
});
