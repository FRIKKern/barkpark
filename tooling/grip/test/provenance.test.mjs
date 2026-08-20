#!/usr/bin/env node
// Proof for grip's self-provenance — tooling/grip/provenance.mjs
//
//   node --test tooling/grip/test/provenance.test.mjs
//
// WHAT THIS FILE HAS TO PROVE, IN ORDER OF WHAT IT WOULD COST TO GET WRONG.
//
// 1. THE BANNER MUST NOT BREAK stdout. Charter D78 measured this: an
//    unconditional STDOUT banner breaks `leads --json` AND `fold`, both of which
//    `JSON.parse(stdout)` and both of which fail with
//    `Unexpected token 'g', "[grip-prove"... is not valid JSON`. So the tests
//    below spawn the real entry points and assert stdout PARSES — not that a
//    banner is absent from stdout by string search, which would pass against a
//    banner that merely spells itself differently.
//
// 2. IT MUST BE TOTAL. A diagnostic that throws is worse than no diagnostic,
//    because the crash gets attributed to the verb. Called outside a repo, in a
//    repo with no commits, and in a clone with no `origin/main` (which is every
//    single-ref CI checkout — D75, where git exits 128), it must return a
//    STATED verdict.
//
// 3. THE FALSE-NEGATIVE SIGNAL MUST ACTUALLY FIRE. The incident behind this
//    slice is a stale worktree answering `leads ledger` with the pre-`leads`
//    usage string, read by the lead as "the feature did not ship". So the test
//    that matters is a MUTATION: build a repo whose HEAD is deliberately behind
//    `origin/main` and assert `differs_from_origin === true` and that the
//    rendered line SAYS SO. Asserting `false` in this worktree would be a test
//    that cannot fail in the direction that hurt.
//
// HERMETIC. Every git fixture is a fresh `mkdtemp` repo with `-c user.*` set
// inline and `--no-gpg-sign`; nothing touches the real repo, no network, no
// fetch. The entry-point spawns are read-only verbs (`--help`, `--json`,
// `--limit 1`) that write nothing.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  treeProvenance,
  provenanceLine,
  emitProvenance,
  ancestryOf,
  isQuotable,
  ANCESTRY,
  ANCESTRIES,
  QUOTABLE_ANCESTRIES,
  PROVENANCE_PREFIX,
  PROVENANCE_STATE,
  FETCHED_PHRASE,
  FETCHED_NOTE,
  MODULE_TREE,
} from "../provenance.mjs";

const GRIP = dirname(dirname(fileURLToPath(import.meta.url)));
// REALPATH'd deliberately. `git rev-parse --show-toplevel` returns the resolved
// path, while this one is derived from `import.meta.url`; a checkout reached
// through a symlink makes the two differ and reds the banner assertions below
// with a failure shaped exactly like a real regression.
const REPO_ROOT = realpathSync(dirname(dirname(GRIP)));

/** A temp dir that is emphatically NOT inside any git repository. */
function withNonRepo(fn) {
  // `/tmp` on macOS is a symlink into /private/tmp; realpath so the assertions
  // compare the path git would actually see.
  const dir = realpathSync(mkdtempSync(join(realpathSync(tmpdir()), "grip-prov-bare-")));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function git(dir, ...args) {
  const r = spawnSync("git", ["-c", "user.email=grip@test", "-c", "user.name=grip", ...args], {
    cwd: dir,
    encoding: "utf8",
  });
  assert.equal(r.status, 0, `git ${args.join(" ")} failed: ${r.stderr}`);
  return (r.stdout ?? "").trim();
}

/**
 * A throwaway repo with TWO commits and a hand-set `refs/remotes/origin/main`,
 * so the test controls exactly how far behind HEAD is. No remote is ever
 * contacted — `update-ref` is the whole mechanism, which is also the point:
 * `origin/main` is a local ref that a clone inherits stale (D75).
 */
function withTempRepo(fn) {
  const dir = realpathSync(mkdtempSync(join(realpathSync(tmpdir()), "grip-prov-repo-")));
  try {
    git(dir, "init", "-q", "-b", "main");
    writeFileSync(join(dir, "a.txt"), "one\n");
    git(dir, "add", "a.txt");
    git(dir, "commit", "-q", "--no-gpg-sign", "-m", "one");
    const first = git(dir, "rev-parse", "HEAD");
    writeFileSync(join(dir, "a.txt"), "two\n");
    git(dir, "commit", "-q", "--no-gpg-sign", "-am", "two");
    const second = git(dir, "rev-parse", "HEAD");
    return fn({ dir, first, second });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Spawn a grip entry point and hand back its two streams, kept APART. */
function run(script, args = [], cwd = REPO_ROOT) {
  const r = spawnSync(process.execPath, [join(GRIP, script), ...args], { cwd, encoding: "utf8" });
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

// ─────────────────────────────────────────────────────────────────────────────
// TOTALITY — every world returns a stated verdict, none of them throws
// ─────────────────────────────────────────────────────────────────────────────

test("outside a git repo it returns a stated verdict and never throws", () => {
  withNonRepo((dir) => {
    let p;
    assert.doesNotThrow(() => { p = treeProvenance({ cwd: dir }); });
    assert.equal(p.in_repo, false);
    assert.equal(p.state, PROVENANCE_STATE.NOT_A_REPO);
    assert.equal(p.root, null);
    assert.equal(p.head, null);
    // The unknowables are NULL, never a plausible-looking default. `false` here
    // would read as "this tree is in sync", which is the lie the module exists
    // to prevent.
    assert.equal(p.differs_from_origin, null);
    assert.equal(p.dirty, null);
    assert.ok(p.reason && p.reason.length > 0, "a verdict without a reason is a shrug");

    const line = provenanceLine(p);
    assert.match(line, /NOT A GIT REPOSITORY/);
    assert.ok(line.includes(dir), `the line must name the cwd it could not place: ${line}`);
    assert.equal(line.includes("\n"), false, "the banner is exactly one line");
  });
});

test("a cwd that does not exist at all is still a verdict, not a throw", () => {
  const gone = join(realpathSync(tmpdir()), "grip-prov-definitely-not-here-9f3c1");
  let p;
  assert.doesNotThrow(() => { p = treeProvenance({ cwd: gone }); });
  assert.equal(p.in_repo, false);
  assert.equal(p.differs_from_origin, null);
  assert.ok(provenanceLine(p).startsWith(PROVENANCE_PREFIX));
});

test("a missing DIRECTORY is not blamed on a missing GIT — ENOENT is ambiguous and is disambiguated", () => {
  // Node raises the identical `{ code: "ENOENT", path: "git" }` for a missing
  // binary and a missing cwd. Reporting "git is not on PATH" to someone whose
  // worktree was pruned is a confidently wrong diagnosis, which is the one
  // failure mode a provenance banner cannot have.
  const gone = join(realpathSync(tmpdir()), "grip-prov-pruned-worktree-4b21e");
  const p = treeProvenance({ cwd: gone });
  assert.equal(p.state, PROVENANCE_STATE.NO_SUCH_CWD);
  assert.notEqual(p.state, PROVENANCE_STATE.GIT_UNAVAILABLE);
  assert.match(p.reason, /does not exist/);
  const line = provenanceLine(p);
  assert.match(line, /NO SUCH DIRECTORY/);
  assert.equal(/GIT UNAVAILABLE/.test(line), false, "git must not be accused of a filesystem fault");
  assert.equal(line.includes("\n"), false);

  // …and git is still named where git really is the fault: a real directory
  // that is not a repository must NOT be reported as a missing directory.
  withNonRepo((dir) => {
    assert.equal(treeProvenance({ cwd: dir }).state, PROVENANCE_STATE.NOT_A_REPO);
  });
});

test("provenanceLine survives being handed nothing", () => {
  for (const junk of [undefined, null, 42, "a string"]) {
    const line = provenanceLine(junk);
    assert.ok(line.startsWith(PROVENANCE_PREFIX), `${JSON.stringify(junk)} -> ${line}`);
    assert.equal(line.includes("\n"), false);
  }
});

test("a repo with no origin/main says it cannot compare — it does not claim in-sync", () => {
  withTempRepo(({ dir }) => {
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.in_repo, true);
    assert.equal(p.state, PROVENANCE_STATE.NO_ORIGIN_MAIN);
    assert.equal(p.origin_main, null);
    assert.equal(p.differs_from_origin, null, "no ref means UNKNOWN, never 'in sync'");
    const line = provenanceLine(p);
    assert.match(line, /cannot compare against origin\/main/);
    assert.match(line, new RegExp(FETCHED_PHRASE));
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// THE FALSE-NEGATIVE SIGNAL — a stale tree must LOOK stale
// ─────────────────────────────────────────────────────────────────────────────

test("HEAD behind origin/main reports differs_from_origin=true and the line says so", () => {
  withTempRepo(({ dir, first, second }) => {
    // origin/main = the newer commit; HEAD = the older one. This is exactly the
    // shape of the incident: a worktree parked behind main, answering anyway.
    git(dir, "update-ref", "refs/remotes/origin/main", second);
    git(dir, "checkout", "-q", first);

    const p = treeProvenance({ cwd: dir });
    assert.equal(p.state, PROVENANCE_STATE.MEASURED);
    assert.equal(p.head, first);
    assert.equal(p.origin_main, second);
    assert.equal(p.differs_from_origin, true);

    const line = provenanceLine(p);
    assert.match(line, /DIFFERS from origin\/main/);
    assert.ok(line.includes(p.origin_main_short), "the line names the ref it is behind");
    assert.match(line, new RegExp(FETCHED_PHRASE));
  });
});

test("HEAD at origin/main reports differs_from_origin=false — the signal is not stuck on", () => {
  withTempRepo(({ dir, second }) => {
    git(dir, "update-ref", "refs/remotes/origin/main", second);
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.differs_from_origin, false);
    assert.match(provenanceLine(p), /in sync with origin\/main/);
    assert.equal(/DIFFERS/.test(provenanceLine(p)), false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// THE RUNGS — three states that used to wear one boolean (W34 S2)
//
// `differs_from_origin` was `head !== origin_main`: true for a tree one commit
// behind AND for a tree 49 commits off main's history entirely, rendered with
// the same sentence. These tests pin each rung SEPARATELY, and pin that the two
// non-quotable rungs do not render as the quotable ones.
// ─────────────────────────────────────────────────────────────────────────────

test("the rung vocabulary is the one commit_distance.ex already ratified — no second one is minted", () => {
  // Parsed from the Elixir owner, not retyped: if that module ever renames a
  // rung, this fails instead of two vocabularies drifting apart in silence.
  const ex = readFileSync(join(REPO_ROOT, "cloud/lib/barkpark_cloud/github/commit_distance.ex"), "utf8");
  const m = ex.match(/def ancestries,\s*do:\s*~w\(([^)]*)\)/);
  assert.ok(m, "commit_distance.ex no longer declares ancestries/0 as a ~w() list");
  assert.deepStrictEqual([...ANCESTRIES], m[1].trim().split(/\s+/));
  assert.deepStrictEqual([...QUOTABLE_ANCESTRIES], ["current", "behind"]);
  for (const rung of ANCESTRIES) assert.equal(isQuotable(rung), ["current", "behind"].includes(rung));
});

test("HEAD at origin/main is `current`, distance 0, QUOTABLE", () => {
  withTempRepo(({ dir, second }) => {
    git(dir, "update-ref", "refs/remotes/origin/main", second);
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.ancestry, ANCESTRY.CURRENT);
    assert.equal(p.distance, 0);
    assert.equal(p.quotable, true);
    assert.match(provenanceLine(p), /ancestry current \(QUOTABLE\)/);
  });
});

test("HEAD behind origin/main is `behind` with the count of main's commits it lacks — QUOTABLE", () => {
  withTempRepo(({ dir, first, second }) => {
    git(dir, "update-ref", "refs/remotes/origin/main", second);
    git(dir, "checkout", "-q", first);
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.ancestry, ANCESTRY.BEHIND);
    assert.equal(p.distance, 1, "distance is commits of main this tree does not have");
    assert.equal(p.quotable, true);
    const line = provenanceLine(p);
    assert.match(line, /ancestry behind by 1 commit;/);
    assert.equal(/DIVERGED/.test(line), false, "a behind tree must not be accused of being off history");
  });
});

test("HEAD ahead of origin/main is `ahead_of_main`, distance 0, and NOT quotable", () => {
  withTempRepo(({ dir, first, second }) => {
    // origin/main parked at the older commit: this tree misses NONE of main's
    // commits and carries one main has never seen.
    git(dir, "update-ref", "refs/remotes/origin/main", first);
    void second;
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.ancestry, ANCESTRY.AHEAD_OF_MAIN);
    assert.equal(p.distance, 0);
    assert.equal(p.quotable, false, "code main has never seen cannot be quoted as what main ships");
    assert.match(provenanceLine(p), /ancestry ahead_of_main: .*\(NOT QUOTABLE\)/);
  });
});

test("a sibling off main's history is `diverged` — REFUSED, and it does not read as `behind`", () => {
  // The owner's own shape, in miniature: commits main will never have AND
  // commits of main it does not have. The old boolean rendered this identically
  // to one-commit-behind, which is the reading that invites "close enough".
  withTempRepo(({ dir, first, second }) => {
    git(dir, "update-ref", "refs/remotes/origin/main", second);
    git(dir, "checkout", "-q", "-b", "sibling", first);
    writeFileSync(join(dir, "b.txt"), "sibling\n");
    git(dir, "add", "b.txt");
    git(dir, "commit", "-q", "--no-gpg-sign", "-m", "sibling");

    const p = treeProvenance({ cwd: dir });
    assert.equal(p.ancestry, ANCESTRY.DIVERGED);
    assert.equal(p.distance, 1, "distance keeps its single meaning: main's commits this tree lacks");
    assert.equal(p.quotable, false);
    const line = provenanceLine(p);
    // Anchored on the SEMICOLON that ends the clause: a bare `.../ its commit/`
    // prefix matches "commit" and "commits" alike, so it could not tell a
    // pluralisation bug from a correct line.
    assert.match(line, /ancestry DIVERGED: off origin\/main's history AND missing 1 of its commits;/);
    assert.match(line, /a rebuild here reinstalls the same off-history code/);
    assert.equal(/ancestry behind by/.test(line), false, "diverged must not render as behind");
  });
});

test("an UNMETERED distance still reads as English on both rungs — the count is missing, not the sentence", () => {
  // `distance` is null whenever `rev-list --count` fails, and that branch reaches
  // an operator's screen exactly when something is already wrong — the worst
  // moment for the line to be unreadable. It shipped as "an unmetered number of
  // OF ITS commits" because the phrase already ended in "of" and the diverged
  // arm prefixed a second one; nothing exercised the null path, so nothing said
  // so. Both rungs are pinned here, and the doubled preposition is refuted by
  // name so the bug cannot come back silently.
  const base = {
    in_repo: true,
    state: "measured",
    root: "/tmp/x",
    head_short: "aaaaaaaa",
    origin_main_short: "bbbbbbbb",
    distance: null,
    dirty: false,
    dirty_files: 0,
    fetched_note: FETCHED_NOTE,
  };

  const diverged = provenanceLine({ ...base, ancestry: ANCESTRY.DIVERGED, quotable: false });
  assert.match(diverged, /missing an unmetered number of its commits;/);
  assert.equal(/number of of/.test(diverged), false, "the possessive must not double the preposition");

  const behind = provenanceLine({ ...base, ancestry: ANCESTRY.BEHIND, quotable: true });
  assert.match(behind, /behind by an unmetered number of commits;/);
  assert.equal(/number of of/.test(behind), false);

  // …and a metered SINGULAR still agrees with itself on both rungs.
  assert.match(provenanceLine({ ...base, ancestry: ANCESTRY.BEHIND, distance: 1 }), /behind by 1 commit;/);
  assert.match(
    provenanceLine({ ...base, ancestry: ANCESTRY.DIVERGED, distance: 1 }),
    /missing 1 of its commits;/,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// rc=128 — "I could not look" is not "no"
// ─────────────────────────────────────────────────────────────────────────────

test("an unknown sha exits 128 and routes to `unknown` WITH a reason — never to a confident refusal", () => {
  withTempRepo(({ dir, second }) => {
    git(dir, "update-ref", "refs/remotes/origin/main", second);
    const ghost = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

    // The measurement this test exists to pin, taken here rather than quoted:
    // --is-ancestor answers 128 for a sha it does not have, NOT 1.
    const probe = spawnSync("git", ["merge-base", "--is-ancestor", ghost, second], { cwd: dir, encoding: "utf8" });
    assert.equal(probe.status, 128, "the third outcome is gone — re-check the branch on r.code");

    const graded = ancestryOf({ head: ghost, origin_main: second, cwd: dir });
    assert.equal(graded.ancestry, ANCESTRY.UNKNOWN);
    assert.notEqual(graded.ancestry, ANCESTRY.DIVERGED, "128 collapsed into a refusal is a confidently wrong answer");
    assert.equal(graded.distance, null, "unmetered is null, never 0");
    assert.equal(graded.quotable, false, "unknown is refused fail-CLOSED");
    assert.match(graded.reason, /exit 128/);
    assert.match(graded.reason, /object database/);
  });
});

test("a SHALLOW clone — the real world that answers 128 — grades unknown, not diverged", () => {
  withTempRepo(({ dir, first, second }) => {
    const clone = join(dir, "..", `grip-prov-shallow-${Date.now()}`);
    const r = spawnSync("git", ["clone", "-q", "--depth", "1", `file://${dir}`, clone], { encoding: "utf8" });
    assert.equal(r.status, 0, `shallow clone failed: ${r.stderr}`);
    try {
      // `first` is outside the shallow boundary: the ref graph knows the tip and
      // nothing else, which is exactly a CI checkout's world.
      const graded = ancestryOf({ head: first, origin_main: second, cwd: clone });
      assert.equal(graded.ancestry, ANCESTRY.UNKNOWN);
      assert.equal(graded.quotable, false);
      assert.ok(graded.reason && graded.reason.length > 0, "a refusal without a reason is a shrug");
    } finally {
      rmSync(clone, { recursive: true, force: true });
    }
  });
});

test("ancestryOf is total over junk input and never claims a rung it did not measure", () => {
  for (const args of [
    { head: null, origin_main: null },
    { head: "abc", origin_main: null },
    { head: null, origin_main: "abc" },
    { head: "", origin_main: "" },
  ]) {
    let graded;
    assert.doesNotThrow(() => { graded = ancestryOf({ ...args, cwd: REPO_ROOT }); });
    assert.equal(graded.ancestry, ANCESTRY.UNKNOWN);
    assert.equal(graded.distance, null);
    assert.equal(graded.quotable, false);
  }
});

test("every not-in-a-repo world is REFUSED — the rung defaults to unknown, not to a plausible one", () => {
  withNonRepo((dir) => {
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.ancestry, ANCESTRY.UNKNOWN);
    assert.equal(p.quotable, false);
  });
  withTempRepo(({ dir }) => {
    // In a repo, but with no origin/main to compare against.
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.ancestry, ANCESTRY.UNKNOWN);
    assert.equal(p.quotable, false);
    assert.match(provenanceLine(p), /ancestry unknown, REFUSED/);
  });
});

test("a modified tracked file reads DIRTY; a clean tree reads clean", () => {
  withTempRepo(({ dir, second }) => {
    git(dir, "update-ref", "refs/remotes/origin/main", second);
    assert.equal(treeProvenance({ cwd: dir }).dirty, false);
    assert.match(provenanceLine(treeProvenance({ cwd: dir })), /· clean$/);

    writeFileSync(join(dir, "a.txt"), "three\n");
    const p = treeProvenance({ cwd: dir });
    assert.equal(p.dirty, true);
    assert.equal(p.dirty_files, 1);
    assert.match(provenanceLine(p), /DIRTY \(1 tracked file modified\)/);
  });
});

test("the root reported is the WORKTREE's own toplevel, not the primary checkout's", () => {
  withTempRepo(({ dir, second }) => {
    const wt = join(dir, "..", `wt-${Date.now()}`);
    git(dir, "worktree", "add", "-q", "--detach", wt, second);
    try {
      const p = treeProvenance({ cwd: wt });
      assert.equal(p.in_repo, true);
      assert.equal(realpathSync(p.root), realpathSync(wt),
        "`--git-common-dir` would have named the PRIMARY tree here — the exact wrong answer");
      assert.notEqual(realpathSync(p.root), realpathSync(dir));
    } finally {
      rmSync(wt, { recursive: true, force: true });
    }
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// NO FETCH, AND IT SAYS SO
// ─────────────────────────────────────────────────────────────────────────────

test("the module performs no fetch — no git subcommand it runs touches the network", () => {
  const src = readFileSync(join(GRIP, "provenance.mjs"), "utf8");
  // Every git invocation in this module is a `git([...], cwd)` call literal.
  const invocations = [...src.matchAll(/\bgit\(\[([^\]]*)\]/g)].map((m) => m[1]);
  assert.ok(invocations.length >= 4, `expected the four measured calls, found ${invocations.length}`);
  for (const inv of invocations) {
    for (const networked of ["fetch", "pull", "remote", "ls-remote", "clone", "push"]) {
      assert.equal(inv.includes(`"${networked}"`), false,
        `provenance.mjs must never run \`git ${networked}\` — found: git([${inv}])`);
    }
  }
});

test("the rendered line says 'as of last fetch' whenever it compares against origin/main", () => {
  withTempRepo(({ dir, first, second }) => {
    git(dir, "update-ref", "refs/remotes/origin/main", second);

    const inSync = provenanceLine(treeProvenance({ cwd: dir }));
    assert.match(inSync, new RegExp(FETCHED_PHRASE), inSync);

    git(dir, "checkout", "-q", first);
    const behind = provenanceLine(treeProvenance({ cwd: dir }));
    assert.match(behind, new RegExp(FETCHED_PHRASE), behind);
  });
});

test("emitProvenance writes exactly one line to the stream it is given and returns the reading", () => {
  const chunks = [];
  const p = emitProvenance({ stream: { write: (s) => chunks.push(s) } });
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].endsWith("\n"), true);
  assert.equal(chunks[0].trimEnd().includes("\n"), false);
  assert.equal(chunks[0].trimEnd(), provenanceLine(p));
});

test("a broken stream never takes the verb down with it", () => {
  const explode = { write: () => { throw new Error("EPIPE"); } };
  let p;
  assert.doesNotThrow(() => { p = emitProvenance({ stream: explode }); });
  assert.ok(p && typeof p === "object", "the reading is still returned when the banner cannot be printed");
});

// ─────────────────────────────────────────────────────────────────────────────
// THE THREE WIRED ENTRY POINTS — banner on STDERR, stdout untouched
// ─────────────────────────────────────────────────────────────────────────────

test("census --ledger --json: the banner is on stderr and stdout still JSON.parses", () => {
  const r = run("census.mjs", ["--ledger", "--json", "--limit", "1"]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /^\[grip-provenance\] /m, "no banner on stderr");
  assert.equal(r.stdout.includes(PROVENANCE_PREFIX), false,
    "the banner reached STDOUT — this is the D78 defect that breaks `leads --json` and `fold`");
  // The assertion that matters: not "no banner string" but "stdout is still a
  // document". A banner spelled differently would slip past a string search.
  const json = JSON.parse(r.stdout);
  assert.ok(json.rows && json.reach, "census --json shape");
});

test("census --help: the banner is on stderr and stdout is the help text alone", () => {
  const r = run("census.mjs", ["--help"]);
  assert.equal(r.status, 0);
  assert.match(r.stderr, /^\[grip-provenance\] /m);
  assert.equal(r.stdout.includes(PROVENANCE_PREFIX), false);
  assert.match(r.stdout, /census\.mjs/);
});

test("acceptance --json: the banner is on stderr and stdout still JSON.parses", () => {
  const r = run("acceptance.mjs", ["--json"]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /^\[grip-provenance\] /m);
  assert.equal(r.stdout.includes(PROVENANCE_PREFIX), false);
  const json = JSON.parse(r.stdout);
  assert.equal(json.ok, true);
});

test("cli --help: the banner is on stderr and stdout is the help text alone", () => {
  const r = run("cli.mjs", ["--help"]);
  assert.equal(r.status, 0);
  assert.match(r.stderr, /^\[grip-provenance\] /m);
  assert.equal(r.stdout.includes(PROVENANCE_PREFIX), false);
  assert.match(r.stdout, /adjudicate source-of-truth facts/);
});

test("every banner names the tree root and states the origin/main comparison", () => {
  for (const [script, args] of [["census.mjs", ["--help"]], ["acceptance.mjs", ["--json"]], ["cli.mjs", ["--help"]]]) {
    const r = run(script, args);
    const banner = r.stderr.split("\n").find((l) => l.startsWith(PROVENANCE_PREFIX));
    assert.ok(banner, `${script} printed no banner`);
    assert.ok(banner.includes(REPO_ROOT), `${script} banner does not name the tree root: ${banner}`);
    assert.match(banner, /in sync with origin\/main|DIFFERS from origin\/main|cannot compare against origin\/main/,
      `${script} banner does not state the origin/main comparison: ${banner}`);
    assert.match(banner, new RegExp(FETCHED_PHRASE), `${script} banner omits '${FETCHED_PHRASE}': ${banner}`);
  }
});

test("the banner names the tree the CODE came from, not the cwd it was launched from", () => {
  // MODULE_TREE, not process.cwd(). The incident was about which FILE executed;
  // an operator who runs main's census.mjs from /tmp must be told about MAIN's
  // tree, not told there is no repository. Run from a directory that is
  // emphatically outside any repo and assert the banner still places the code.
  withNonRepo((outside) => {
    const r = run("cli.mjs", ["--help"], outside);
    const banner = r.stderr.split("\n").find((l) => l.startsWith(PROVENANCE_PREFIX));
    assert.ok(banner, "no banner when launched from outside a repo");
    assert.equal(banner.includes("NOT A GIT REPOSITORY"), false,
      `cwd-based provenance would have reported no repo here: ${banner}`);
    assert.ok(banner.includes(REPO_ROOT), `banner does not name the code's own tree: ${banner}`);
  });
});

test("MODULE_TREE is the grip directory, so its provenance is the grip tree's", () => {
  assert.equal(MODULE_TREE, GRIP);
  assert.equal(treeProvenance({ cwd: MODULE_TREE }).root, REPO_ROOT);
});

// ─────────────────────────────────────────────────────────────────────────────
// cli.mjs's ENTRY GUARD — proven by the mutation it fixes
// ─────────────────────────────────────────────────────────────────────────────

test("cli.mjs can be IMPORTED — before the entry guard it printed HELP and exited 2", () => {
  // Measured on the pre-fix file, quoted so the regression is legible:
  //   $ node -e "import('./tooling/grip/cli.mjs').then(...)"
  //   grip — adjudicate source-of-truth facts
  //   ...
  //   $ echo $?  ->  2
  // The importer's `.then()` never ran, because the module body called
  // `process.exit()` at load. cli.mjs could be spawned and never reused.
  const r = spawnSync(process.execPath, [
    "-e",
    `import(${JSON.stringify(join(GRIP, "cli.mjs"))})
       .then((m) => { process.stdout.write("RESOLVED:" + Object.keys(m).sort().join(",")); })
       .catch((e) => { process.stdout.write("REJECTED:" + e.message); })`,
  ], { cwd: REPO_ROOT, encoding: "utf8" });

  assert.equal(r.status, 0, `importing cli.mjs exited ${r.status}: ${r.stdout}${r.stderr}`);
  assert.match(r.stdout, /^RESOLVED:/, `importing cli.mjs did not resolve: ${r.stdout}${r.stderr}`);
  for (const name of ["main", "HELP", "EXIT"]) {
    assert.ok(r.stdout.includes(name), `cli.mjs should export ${name} once it is importable: ${r.stdout}`);
  }
  // And importing must adjudicate NOTHING — no help screen, no banner, no work.
  assert.equal(r.stdout.includes("adjudicate source-of-truth facts"), false,
    "importing cli.mjs still printed the help text");
  assert.equal(r.stderr.includes(PROVENANCE_PREFIX), false,
    "importing cli.mjs emitted the entry banner — the banner belongs to the ENTRY, not the module");
});

test("cli.mjs still RUNS when spawned — the guard did not turn the CLI into a no-op", () => {
  // The silent-failure mode of a main-module test: it is false when it should be
  // true, the script does nothing, and exit 0 reads exactly like a clean run.
  const missing = run("cli.mjs", [join(GRIP, "no-such-file.json")]);
  assert.equal(missing.status, 2, "a missing facts file is still usage-exit 2, not a silent 0");
  assert.match(missing.stderr, /cannot read/);
});
