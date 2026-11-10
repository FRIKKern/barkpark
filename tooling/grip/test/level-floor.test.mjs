// level-floor.test.mjs — the authority-level grammar tests for
// the parseability floor, purity of level.mjs, and mention-immunity for the
// blessed remote tokens.
//
// One of the level-*.test.mjs files the single level suite was split into by
// subject (task-f5ca1c7505824cc4). The tests moved unchanged.
//
//   node --test tooling/grip/test/level-floor.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";

import { readFileSync } from "node:fs";

import {
  deriveLevel,
  LEVELS,
  looksLikeProse,
} from "../level.mjs";
import { admitFact } from "../record.mjs";

// =============================================================================
// THE PARSEABILITY FLOOR — prose can never be graded as evidence (D30 (d))
// =============================================================================
//
// 13.3% of the frozen corpus's rerun strings are prose, not commands. The
// grammar reads a head token and never asked whether the string PARSES, so any
// prose carrying a blessed token inherited that token's authority. Each
// specimen below is REAL — lifted from tooling/grip/fixtures/evidence-corpus.json
// — and each would have derived L2 or L3 through the segment walk above.

test("real prose specimens from the frozen corpus are floored at L6", () => {
  const specimens = [
    // would derive L3 off `python3`
    "python3 confusion matrix (15 per PREDICTED class, so per-class precision is unbiased)",
    // would derive L2 off `bp`
    "bp sites -o json | python3 (count)",
    // would derive L3 off a `grep`-shaped head
    "grep/read api/lib/barkpark/content/papers/template.ex around lines 200-219",
    // would derive L2 off `bp`
    "bp doc patch … --dry-run",
    // would derive L2 off `bp` — an unfilled optional-flag slot
    "bp onramp gemini-cli/zed --write [--force] --server https://guerrilla.barkpark.cloud",
    // would derive L3 off `mix` — a HUMAN EDIT stands between the reader and the run
    "probe: add migration_lock: false to Ecto.Migrator.up/down; mix test codelist_issue_version_test.exs --include flaky",
    // would derive L2 off `gh` — shorthand for four commands, not one
    "gh pr view 4631/4632/4633 --json state,mergedAt,mergeCommit",
    // would derive L3 off `git checkout` — an unfilled template slot
    "git checkout origin/main -- <55 files>; mix compile; CC=/usr/bin/clang MIX_ENV=test mix test --seed 111",
  ];
  for (const specimen of specimens) {
    assert.equal(deriveLevel(specimen), "L6", `prose must floor at L6: ${specimen}`);
  }
});

test("the floor demotes a REAL command carrying an unrunnable prose annotation", () => {
  // Both are real corpus rows. As literal strings neither runs: the
  // parenthetical would be executed as a subshell. What the grammar certifies
  // is re-derivability of THIS string (D4), so L6 is the honest answer — and
  // the ten-second fix is to delete the aside.
  assert.equal(deriveLevel("curl -s https://guerrilla.barkpark.cloud/papers/x (no auth header) | grep vs-003"), "L6");
  assert.equal(deriveLevel("node grip-mutation.mjs (section F)"), "L6");
});

test("the floor NEVER fires on an honest command — the cry-wolf controls", () => {
  // Every shape the floor could plausibly mistake for prose, pinned. A floor
  // that cries wolf gets routed around within a wave.
  const honest = [
    ["curl -s http://[::1]:4000/api/schemas", "L3"],                    // [ is not [--
    ["grep -n '[0-9]\\{3\\}' api/lib/foo.ex", "L3"],                    // a glob class
    ["go test ./internal/cli/...", "L3"],                               // trailing ... is a Go wildcard
    ["cat Makefile 2>&1 | tail -20", "L3"],                             // > without a closing >
    ["bp task --help < /dev/null", "L2"],                               // < without a closing >
    ["sort < in.txt > out.txt", "L3"],                                  // BOTH redirects in one segment
    ["diff -rq <(cat a) <(cat b) > /tmp/d.txt", "L3"],                  // process substitution + redirect
    ["node -e \"console.log(1 < 2 && 3 > 2)\"", "L3"],                  // quoted angles
    ["(cd __preview__ && node smoke.mjs | tail -1)", "L3"],             // a real subshell
    ["diff <(cat a.txt) <(cat b.txt)", "L3"],                           // process substitution
    ["jq '.paths | keys' docs/openapi.json", "L4"],                     // a quoted pipe
    ["ps aux | grep 'bp login' | grep -v grep", "L3"],                  // a 3-token unknown-head segment WITH flags
    ["frobnicate --all --please", "L6"],                                // unknown head, but flags: not prose
    ["S=$(head -1 run.log|cut -d' ' -f1); echo $S", "L3"],              // command substitution
  ];
  for (const [command, expected] of honest) {
    assert.equal(deriveLevel(command), expected, `must NOT be floored: ${command}`);
  }
});

test("looksLikeProse is exported and explains a demotion rather than only applying it", () => {
  assert.equal(typeof looksLikeProse, "function");
  assert.equal(looksLikeProse("bp sites -o json | python3 (count)"), true);
  assert.equal(looksLikeProse("bp sites -o json | jq length"), false);
});

// =============================================================================
// PURITY — deriveLevel stays pure, synchronous and clock-free
// =============================================================================

test("level.mjs imports nothing, shells out to nothing and reads no clock", () => {
  // A grammar that shells out could not run inside the in-loop gate, and one
  // that reads a clock is non-deterministic — the same command would level
  // differently on two runs, which is the drift this epic exists to abolish.
  const source = readFileSync(new URL("../level.mjs", import.meta.url), "utf8");
  const code = source
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("//"))
    .join("\n");
  for (const forbidden of ["child_process", "execSync", "spawnSync", "Date.now", "new Date", "require(", "readFileSync", "await ", "async "]) {
    assert.equal(code.includes(forbidden), false, `level.mjs must not contain ${forbidden}`);
  }
  assert.equal(/^\s*import\s/m.test(code), false, "level.mjs must import nothing");
  // And it is deterministic: the same input levels the same twice.
  const command = "cd /opt/barkpark && curl https://guerrilla.barkpark.cloud/health";
  assert.equal(deriveLevel(command), deriveLevel(command));
});

test("deriveLevel never throws on hostile input", () => {
  for (const hostile of [null, undefined, 42, {}, [], "", "   ", "((((", "'unterminated", "&&&&", "|||", ";;;;", "<<<>>>", "\n\n\n"]) {
    const level = deriveLevel(hostile);
    assert.ok(Object.keys(LEVELS).includes(level), `${JSON.stringify(hostile)} → ${level}`);
  }
});

// ── THE PROSE FLOOR'S CRY-WOLF EDGE (added in review) ────────────────────────

test("a BACKSLASH-ESCAPED paren is a literal argument, not a prose aside", () => {
  // `find . \( -name a -o -name b \)` is an ordinary local read. The escaped
  // group read as a parenthetical whose first word (`-name`) is not a plausible
  // command head, so the floor demoted a good command L3 → L6.
  //
  // WHY THE MEASUREMENT COULD NOT SEE IT: zero occurrences in the 651-command
  // corpus, so the before/after distribution was bit-identical with the bug
  // present and with it fixed. That is the same blindness that hid the
  // `sort < in.txt > out.txt` cry-wolf. A corpus distribution is a LOWER BOUND
  // on cry-wolf; only probing the class by hand finds the rest.
  assert.equal(deriveLevel("find . \\( -name a -o -name b \\)"), "L3");
  assert.equal(deriveLevel("find api -type f \\( -name '*.ex' -o -name '*.exs' \\) -newer mix.exs"), "L3");

  // The floor must still fire on the shapes it exists for — the fix widens
  // nothing else. An UNESCAPED aside is still prose.
  assert.equal(deriveLevel("cd api && (Edit: add agent_state to the base map) && mix test"), "L6");
  assert.equal(deriveLevel("bp sites -o json | python3 (count)"), "L6");
  // …and a REAL subshell, opening on a known head, is still walked normally.
  assert.equal(deriveLevel("(cd __preview__ && node smoke.mjs)"), "L3");
});

test("the review's floor fix costs the corpus distribution nothing", () => {
  // The standing bar for any floor edit: it may not move a single one of the
  // 651 frozen commands. If a cry-wolf fix changes the distribution, it widened
  // the floor rather than narrowing it.
  const corpus = JSON.parse(readFileSync(new URL("../fixtures/evidence-corpus.json", import.meta.url), "utf8"));
  const commands = [...new Set(corpus.proofs.map((p) => p?.command).filter((c) => typeof c === "string" && c.trim()))];
  const dist = {};
  for (const c of commands) dist[deriveLevel(c)] = (dist[deriveLevel(c)] || 0) + 1;
  assert.equal(commands.length, 651);
  // tgw13-s1 moved exactly ONE frozen row: `bp scaffy run
  // classify-block-type.scaffy …` was over-promoted L2 (bp → remote server) and
  // is now L3 (pure-local scaffy verb, no url). That correction — L2 93→92,
  // L3 380→381 — is the fix landing on real evidence, not a floor regression.
  // The corpus is BLIND to the subcommand-anchor bug (the incidental-scaffy
  // class has zero corpus occurrences): buggy indexOf and the correct anchor
  // give a bit-identical distribution here, so this pin is NOT the merge
  // instrument — the hand-run bidirectional matrix is.
  assert.deepEqual(dist, { L1: 32, L2: 92, L3: 381, L6: 146 });
});

test("KNOWN L1 SHAPES: the ssh forms the corpus actually uses are never demoted", () => {
  // The standing bar is ZERO false demotions of honest L1/L2 commands, and the
  // floor is the thing most able to break it. Every ssh row in the frozen
  // corpus uses `root@<host>`, and all of them must survive the walk.
  for (const cmd of [
    "ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'journalctl -u barkpark.service -n 15'",
    "ssh -o ConnectTimeout=15 root@178.105.92.191 'docker ps'",
    "ssh root@157.180.90.121 \"cd /opt/barkpark && git log -1 --format='%H'\"",
  ]) {
    assert.equal(deriveLevel(cmd), "L1", cmd);
  }
  // KNOWN GAP, pre-existing and unchanged by this wave: a BARE host alias with
  // no `user@` does not match SSH_READ and derives L6. D2 ratifies the level as
  // `ssh <user>@<host>`, so widening it is a PROMOTION rule change — the unsafe
  // direction — and belongs in a ruling, not in a review. Filed as
  // tgw3-bl-ssh-bare-host-alias. Pinned here so the gap is visible, not silent.
  assert.equal(deriveLevel("ssh guerrilla systemctl status barkpark"), "L6");
});

// --- mention-immunity for the OTHER blessed remote tokens --------------------
// The curl/wget branch was deliberately head-gated (see the https:// mention
// test above). SSH_READ / GIT_SHOW_REMOTE / GH_API were not: they were tested
// against the RAW segment, so a local grep that merely QUOTES a production
// command was promoted to L1/L2 — and record.mjs's admitFact then ACCEPTED an
// author's false L1 claim, defeating the ceiling. These pin the symmetry.

test("MENTION-IMMUNITY: a grep quoting an ssh command is L3, not L1", () => {
  assert.equal(deriveLevel(`grep -rn "ssh root@89.167.28.206" docs/ops/PROD_OPS.md`), "L3");
  assert.equal(deriveLevel(`rg -n 'ssh root@prod' docs/`), "L3");
  // unquoted, too — quote-masking alone cannot see this one
  assert.equal(deriveLevel(`grep -rn ssh root@host docs/`), "L3");
});

test("MENTION-IMMUNITY: a grep quoting `gh api` or `git show origin/…` is L3, not L2", () => {
  assert.equal(deriveLevel(`grep -n "gh api repos/x/y/pulls" docs/ops/merge-gates.md`), "L3");
  assert.equal(deriveLevel(`grep -n "git show origin/main:api/lib/foo.ex" docs/cards/js-sdk.md`), "L3");
  assert.equal(deriveLevel(`rg -n "git show origin/main:" docs/`), "L3");
});

test("MENTION-IMMUNITY does not demote a real invocation", () => {
  // the standing zero-false-demotion bar, for exactly the shapes now gated
  assert.equal(deriveLevel(`ssh root@89.167.28.206 "cd /opt/barkpark && git pull"`), "L1");
  assert.equal(deriveLevel(`cd /opt && ssh root@h uptime`), "L1");
  assert.equal(deriveLevel(`timeout 30 ssh root@h uptime`), "L1");
  assert.equal(deriveLevel(`gh api repos/o/r/pulls --jq .`), "L2");
  assert.equal(deriveLevel(`git show origin/main:api/mix.exs | head -20`), "L2");
  // a reader head with a PROCESS SUBSTITUTION really does read origin — the
  // corpus contains this shape and it must keep its L2.
  assert.equal(deriveLevel(`diff <(git show origin/main:a.md) a.md`), "L2");
});

test("MENTION-IMMUNITY: a QUOTED destination is still a real invocation, not a mention", () => {
  // REVIEW ADDITION (wave 11). Reading these through the quote mask demoted
  // three live shapes — measured against origin/main 072978af0, `ssh
  // "root@host" uptime` went L1→L6 and `git show 'origin/main:…'` went L2→L3.
  // Quoting a HOST or a REF is quoting an argument, not naming a command
  // inside prose, and a false DEMOTION is as much a defect as a false
  // promotion: it makes an honest L1 claim unstampable.
  //
  // The rule is head-keyed: a segment headed by the command ITSELF reads its
  // raw bytes; every other head still reads the mask. `headToken` unwraps
  // PREFIX_WRAPPERS, so the `timeout` form is covered by the same line.
  assert.equal(deriveLevel(`ssh "root@89.167.28.206" uptime`), "L1");
  assert.equal(deriveLevel(`ssh 'root@89.167.28.206' systemctl is-active barkpark`), "L1");
  assert.equal(deriveLevel(`timeout 30 ssh "root@h" uptime`), "L1");
  assert.equal(deriveLevel(`git show "origin/main:api/mix.exs" | wc -l`), "L2");
  assert.equal(deriveLevel(`git show 'origin/main:api/mix.exs'`), "L2");
  assert.equal(deriveLevel(`gh api "repos/o/r/pulls" --jq .`), "L2");

  // …and the mask still governs every other head, so the mention stays demoted.
  assert.equal(deriveLevel(`echo "ssh root@89.167.28.206 uptime"`), "L6");
  assert.equal(deriveLevel(`echo "git show origin/main:api/mix.exs"`), "L6");

  // KNOWN RESIDUAL, pinned so it is visible rather than silent: an UNQUOTED
  // mention under a NON-reader head still promotes. Quote-masking cannot see it
  // and the READER_HEADS gate does not cover `echo`. Measured: ZERO of the 631
  // rerun-bearing committed ledger rows have this shape, and the QUOTED form is
  // correctly L6 — latent, not live, which is why the review did not widen the
  // head set inside this slice's fence (that is a rule change, not a bug fix).
  //
  // NOT FILED AS A TASK, and that is a fact rather than an omission: guerrilla's
  // /v1/data/mutate doc-CREATE was returning 500/timeout throughout the wave-11
  // review (request ids GMZYbJhOxSPzcsMACkxR, GMZYdmeCBah-FP4ACz6y), the same
  // fault tgw9-s1's builder hit. No id is cited here, because citing a task that
  // does not exist is the dangling pointer this epic refuses. This assertion IS
  // the pin: whoever fixes the rule gets a failing test that names the decision.
  assert.equal(deriveLevel(`echo ssh root@89.167.28.206`), "L1");
});

test("MENTION-IMMUNITY: the ceiling holds — admitFact rejects a false L1 on a quoting grep", () => {
  const admitted = admitFact({
    subject: "docs/ops/PROD_OPS.md",
    claim: "the documented prod deploy host appears at docs/ops/PROD_OPS.md:17",
    evidence: "read the doc",
    rerun: `grep -rn "ssh root@89.167.28.206" docs/ops/PROD_OPS.md`,
    level: "L1",
  });
  assert.equal(admitted.ok, false);
  assert.equal(admitted.rejections[0].reason, "LEVEL-SKIP");
});
