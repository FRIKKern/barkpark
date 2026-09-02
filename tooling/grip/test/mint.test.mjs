// test/mint.test.mjs — the transformer that lets a survey fact become a row.
//
// Every case here is a MEASURED failure, not an invented one. The four mint
// defects each get their own test because a literal reading of charter D32
// walks into all four, and each one degrades the index SILENTLY: the write
// still succeeds, the fold still folds, and the key is just quietly wrong.

import { deepStrictEqual, ok, strictEqual } from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { mintAll, mintRecipe, pathToken, quantityPhrase } from "../mint.mjs";
// NAMESPACE-IMPORTED ON PURPOSE, and not to be tidied into the named import
// above. A named import of a symbol the PREVIOUS mint.mjs does not export is a
// LINK error: swap the module back and the whole file reds with a SyntaxError
// before a single assertion runs, which proves nothing about the mint. Reached
// through the namespace, the fail-before tests red on what the mint DOES.
import * as mint from "../mint.mjs";
const cdRootOffset = (rerun) => mint.cdRootOffset(rerun);
import { admitRecipe, foldLedger, inScope, mintRunId, readLedgerRuns, writeLedgerRun } from "../ledger.mjs";
import { screenCommand } from "../screen.mjs";

const LEDGER = fileURLToPath(new URL("../ledger.mjs", import.meta.url));
const NOW = "2026-07-21T00:00:00Z";

const REPO = "/Volumes/SATECHI/github/barkpark";
const WORKTREE = `${REPO}/.claude/worktrees/wf_82b8ba6c-140-31`;

function subjectOf(rerun) {
  const m = mintRecipe({ rerun }, { observed_at: NOW });
  return m.ok ? m.recipe.subject : `!${m.reason}`;
}

function tmpDir() {
  return mkdtempSync(join(tmpdir(), "grip-mint-"));
}

// ── the transform itself ─────────────────────────────────────────────────────

test("a raw {claim, evidence, rerun} fact quadruple-rejects — this is why a transformer exists", () => {
  const raw = { claim: "the ledger is empty", evidence: "one path returned", rerun: `cd ${REPO} && git ls-tree origin/main --name-only tooling/grip/ledger/` };
  const verdict = admitRecipe(raw, { now: NOW });
  strictEqual(verdict.ok, false);
  const reasons = verdict.rejections.map((r) => r.reason).sort();
  deepStrictEqual(reasons, ["MISSING-OBSERVED-AT", "MISSING-QUANTITY", "MISSING-SUBJECT", "UNKNOWN-FIELD", "UNKNOWN-FIELD"]);
});

test("the minted row admits with ZERO rejections, and claim/evidence are DROPPED not passed through", () => {
  const raw = { claim: "the ledger is empty", evidence: "one path returned", rerun: `cd ${REPO} && git ls-tree origin/main --name-only tooling/grip/ledger/` };
  const minted = mintRecipe(raw, { observed_at: NOW });
  ok(minted.ok);
  ok(!("claim" in minted.recipe), "claim must not survive the mint");
  ok(!("evidence" in minted.recipe), "evidence must not survive the mint");
  const verdict = admitRecipe(minted.recipe, { now: NOW, screen: screenCommand });
  strictEqual(verdict.ok, true, JSON.stringify(verdict.rejections));
  strictEqual(verdict.recipe.subject, "tooling/grip/ledger");
  strictEqual(verdict.recipe.quantity, "git:ls-tree");
});

test("the row carries no value field — the transformer cannot smuggle one in", () => {
  const minted = mintRecipe({ claim: "544", value: 544, rerun: "wc -l tooling/grip/ledger.mjs" }, { observed_at: NOW });
  ok(minted.ok);
  ok(!("value" in minted.recipe));
  strictEqual(admitRecipe(minted.recipe, { now: NOW }).ok, true);
});

// ── defect 1: the repo root ──────────────────────────────────────────────────

test("defect 1 — a repo root is NOT a subject, and the scan CONTINUES past it", () => {
  strictEqual(subjectOf(`cd ${REPO} && wc -l tooling/grip/ledger.mjs`), "tooling/grip/ledger.mjs");
  strictEqual(subjectOf(`cd ${WORKTREE} && wc -l tooling/grip/ledger.mjs`), "tooling/grip/ledger.mjs");
  // absolute references to a file inside the repo normalise to the SAME key as
  // the relative one — otherwise one file is two subjects
  strictEqual(subjectOf(`wc -l ${REPO}/tooling/grip/ledger.mjs`), "tooling/grip/ledger.mjs");
  strictEqual(subjectOf(`wc -l ${WORKTREE}/tooling/grip/ledger.mjs`), "tooling/grip/ledger.mjs");
});

test("defect 1 — a bare `cd <repo root>` mints NOTHING rather than minting the root", () => {
  strictEqual(pathToken(REPO), null);
  strictEqual(pathToken(`${REPO}/`), null);
  strictEqual(pathToken(WORKTREE), null);
  strictEqual(subjectOf(`cd ${REPO}`), "!NO-SUBJECT");
});

// ── defect 2: revspecs and branch refs ───────────────────────────────────────

test("defect 2 — origin/main and loop-epic/* are slash-bearing and are NOT paths", () => {
  strictEqual(pathToken("origin/main"), null);
  strictEqual(pathToken("loop-epic/ship-the-write-verb-0"), null);
  strictEqual(pathToken("refs/heads/main"), null);
  // with no real path present the verb falls back rather than minting the ref
  strictEqual(subjectOf("git log --oneline -1 origin/main"), "cmd:git");
});

test("defect 2 — in `git show <ref>:<path>` the PATH is the subject, never the ref", () => {
  strictEqual(subjectOf("git show origin/main:tooling/grip/ledger/recipes.json"), "tooling/grip/ledger/recipes.json");
});

// ── defect 3: the trailing slash ─────────────────────────────────────────────

test("defect 3 — `tooling/grip/` and `tooling/grip` are ONE key, not two", () => {
  strictEqual(subjectOf("wc -l tooling/grip/"), subjectOf("wc -l tooling/grip"));
  strictEqual(subjectOf("wc -l tooling/grip/"), "tooling/grip");
});

// ── defect 4: grep anchors and quotes ────────────────────────────────────────

test("defect 4 — grep anchors and quotes are stripped, so the anchored form cannot split the index", () => {
  strictEqual(pathToken("'^tooling/grip/harvest.mjs'"), "tooling/grip/harvest.mjs");
  strictEqual(pathToken('"tooling/grip/harvest.mjs"'), "tooling/grip/harvest.mjs");
  strictEqual(subjectOf("grep -n '^tooling/grip/harvest.mjs' docs/index.md"), "tooling/grip/harvest.mjs");
  strictEqual(
    subjectOf("grep -n '^tooling/grip/harvest.mjs' docs/index.md"),
    subjectOf("grep -n tooling/grip/harvest.mjs docs/index.md"),
  );
});

// ── defect 5: the traversal guard, proven in BOTH directions ────────────────
//
// The guard `t.includes("..")` had NO test at all — grep for `traversal` or
// `etc/passwd` in this file returned nothing before this slice. An untested
// guard is indistinguishable from a deleted one, and defect 6 below relaxes
// exactly this line, so the guard has to be pinned first or the relaxation is
// a silent widening.

test("defect 5 — the traversal guard REFUSES escapes, and is proven by mutation not by inspection", () => {
  // a path that climbs out of the repo is never a subject
  strictEqual(pathToken("../../../etc/passwd"), null);
  strictEqual(pathToken("a/../../b"), null);
  strictEqual(pathToken("./x/../../../y"), null);
  strictEqual(pathToken("~/.claude/projects"), null);
  strictEqual(pathToken("tooling/grip/*.mjs"), null);
  // and the whole command falls back rather than minting the escape
  strictEqual(subjectOf("wc -l ../../../etc/passwd"), "cmd:wc");
  // THE OTHER DIRECTION — the guard must not be so wide it eats real paths.
  // `..` inside a SEGMENT name is not a traversal, and a dotfile is not one
  // either; if a "fix" widened the guard these would go null and the index
  // would lose them silently.
  strictEqual(pathToken("tooling/grip/mint.mjs"), "tooling/grip/mint.mjs");
  strictEqual(pathToken(".github/workflows/doc-gates.yml"), ".github/workflows/doc-gates.yml");
});

// ── defect 6: the Go package wildcard is unconditionally rejected ────────────

test("defect 6 — `./internal/cli/...` is a Go PACKAGE WILDCARD, not a traversal", () => {
  // the ellipsis tripped `t.includes("..")`, so Go's own idiom minted nothing
  strictEqual(pathToken("./internal/cli/..."), "internal/cli");
  strictEqual(pathToken("internal/cli/..."), "internal/cli");
  strictEqual(pathToken("./tooling/grip/..."), "tooling/grip");
  strictEqual(subjectOf("go test ./internal/cli/ -run TestFoo"), "internal/cli");
  strictEqual(subjectOf("go test -run TestCompletionNouns ./internal/cli/..."), "internal/cli");
  // the three-way normalisation of defect 3 still holds ACROSS the wildcard:
  // `internal/cli`, `internal/cli/` and `./internal/cli/...` are ONE subject
  strictEqual(subjectOf("go vet ./internal/cli/..."), subjectOf("wc -l internal/cli"));
  // a BARE `./...` names no directory, so there is nothing to extract
  strictEqual(pathToken("./..."), null);
  strictEqual(pathToken("..."), null);
  strictEqual(subjectOf("go build ./..."), "cmd:go");
  // and the relaxation is SUFFIX-only — an ellipsis mid-path is still refused
  strictEqual(pathToken("internal/.../cli"), null);
  strictEqual(pathToken("./internal/cli/.../x"), null);
});

// ── defect 7: a top-level directory is the coarsest subject an agent types ───

test("defect 7 — a single-segment top-level directory mints ITSELF, not `cmd:<head>`", () => {
  for (const dir of ["api", "js", "web", "docs", "deploy", "scaffy", "tooling", "internal"]) {
    strictEqual(pathToken(`${dir}/`), dir, `${dir}/ must mint ${dir}`);
    strictEqual(pathToken(`./${dir}`), dir, `./${dir} must mint ${dir}`);
    strictEqual(pathToken(`./${dir}/...`), dir, `./${dir}/... must mint ${dir}`);
  }
  strictEqual(subjectOf("mix test api/"), "api");
  // one directory, four spellings, ONE key — the defect-3 rule extended
  const spellings = new Set(["api/", "./api", "./api/", "./api/..."].map(pathToken));
  deepStrictEqual([...spellings], ["api"]);

  // GUARD — a bare word wearing no path marker is NOT a directory. The mint
  // has no repo listing and must not guess: `test`, `install` and `--help` are
  // verbs and flags, and inventing subjects out of them is worse than the
  // `cmd:` fallback it would replace.
  strictEqual(pathToken("test"), null);
  strictEqual(pathToken("install"), null);
  strictEqual(pathToken("--help"), null);
  strictEqual(pathToken("api"), null);
  strictEqual(subjectOf("npm install"), "cmd:npm");
});

test("defect 7's PRICE is pinned: a single-segment subject is a NAME, never a location", () => {
  // Enumerated over the frozen corpus in review: six extensionless
  // single-segment subjects are new here. Three are real top-level names, three
  // are RELATIVE — they arrive from a `cd api && … lib/`-shaped command, so
  // `lib` cannot be told apart from any other `lib/` in the tree.
  //
  // The conflation is ACCEPTED (separating them needs a repo listing the mint
  // deliberately does not hold) and pinned here so it is a stated property
  // rather than a surprise the first ambiguous lead teaches somebody.
  strictEqual(pathToken("lib/"), "lib");
  strictEqual(pathToken("src/"), "src");
  strictEqual(
    subjectOf("grep -rn 'defmodule' lib/"),
    subjectOf("grep -rn 'export' lib/"),
    "two different lib/ directories collapse to ONE subject — the accepted price",
  );
  // And it is still strictly more than the `cmd:` fallback it replaced, which
  // D45 excludes from leads entirely — i.e. no lead at all.
  ok(!subjectOf("grep -rn 'defmodule' lib/").startsWith("cmd:"));
});

// ── the key must CLUSTER: the whole reason subject is not minted from prose ──

test("the minted key is NOT injective — facts about one file share one subject", () => {
  const facts = [
    { claim: "ledger.mjs is 544 lines", evidence: "544", rerun: `cd ${REPO} && wc -l tooling/grip/ledger.mjs` },
    { claim: "ledger.mjs exports writeLedgerRun", evidence: "line 502", rerun: "grep -n 'export function writeLedgerRun' tooling/grip/ledger.mjs" },
    { claim: "ledger.mjs has no clock", evidence: "0 hits", rerun: "grep -c 'Date.now' tooling/grip/ledger.mjs" },
    { claim: "the ledger dir holds only a README", evidence: "1 path", rerun: "git ls-tree HEAD --name-only tooling/grip/ledger/" },
  ];
  const { recipes, yield: y } = mintAll(facts, { observed_at: NOW });
  strictEqual(recipes.length, 4);
  ok(y.distinct_subjects < recipes.length, `a clustering key must produce fewer subjects than facts (got ${y.distinct_subjects} of ${recipes.length})`);
  strictEqual(y.distinct_subjects, 2);
  // the CONTROL: a claim-derived subject over the same facts is injective —
  // a key that can never collide, in which nothing is ever a lead
  const claimDerived = new Set(facts.map((f) => f.claim));
  strictEqual(claimDerived.size, facts.length);
});

test("the same file reached three different ways is still one subject", () => {
  const ways = [
    "wc -l tooling/grip/ledger.mjs",
    `wc -l ${REPO}/tooling/grip/ledger.mjs`,
    "grep -c export './tooling/grip/ledger.mjs'",
  ];
  const subjects = new Set(ways.map(subjectOf));
  deepStrictEqual([...subjects], ["tooling/grip/ledger.mjs"]);
});

// ── quantity ─────────────────────────────────────────────────────────────────

test("quantity is the command's verb phrase, coarse and collidable on purpose", () => {
  strictEqual(quantityPhrase("wc -l tooling/grip/ledger.mjs"), "wc:-l");
  strictEqual(quantityPhrase("git ls-tree origin/main --name-only tooling/grip/"), "git:ls-tree");
  strictEqual(quantityPhrase(`cd ${REPO} && node tooling/grip/ledger.mjs --selftest`), "node:--selftest");
  // `cd` is stripped: doc-truth's matchPath reads token 0 and would answer `cd`
  ok(!quantityPhrase(`cd ${REPO} && wc -l x.mjs`).startsWith("cd"));
});

test("two rival ways to re-derive one property collide on the SAME key — RIVAL-METHOD can fire", () => {
  const a = mintRecipe({ rerun: "wc -l tooling/grip/ledger.mjs" }, { observed_at: NOW });
  const b = mintRecipe({ rerun: "wc -l ./tooling/grip/ledger.mjs" }, { observed_at: NOW });
  strictEqual(a.recipe.subject, b.recipe.subject);
  strictEqual(a.recipe.quantity, b.recipe.quantity);
});

// ── defect 8: the quantity minted the FLAG, not the PROPERTY ─────────────────
//
// RIVAL-METHOD (charter D32/D33) is the product: two independent recipes on one
// (subject, quantity) key mean "re-run both and compare what they answer NOW".
// The flag-grain quantity made that flag FABRICATED — over the frozen 652-proof
// corpus, 58 keys absorbed 261 rows (40%) and most of those groups answered
// DIFFERENT questions. A quantity is the PROPERTY being derived, which for a
// pipeline is decided by the LAST measuring stage and for a match count
// includes the PATTERN.

test("defect 8 — two greps counting DIFFERENT patterns are not rivals", () => {
  const a = quantityPhrase("grep -c 'needs_worktree' tooling/grip/screen.mjs");
  const b = quantityPhrase("grep -c 'isolation' tooling/grip/screen.mjs");
  ok(a !== b, `a match count is a count OF something; got ${a} for both`);
  // the pattern is what differs, so it is what the key must carry
  ok(a.includes("needs_worktree"), a);
  ok(b.includes("isolation"), b);
  // the same pattern quoted three ways is still ONE property
  strictEqual(quantityPhrase('grep -c "isolation" x.mjs'), b);
  strictEqual(quantityPhrase("grep -c isolation x.mjs"), b);
  // `-e` introduces the pattern rather than being one
  strictEqual(quantityPhrase("grep -c -e 'isolation' x.mjs"), quantityPhrase("grep -c 'isolation' x.mjs"));
  // an anchored regex is a DIFFERENT question from the unanchored one, so
  // unlike the SUBJECT (defect 4) the quantity keeps its anchors
  ok(quantityPhrase("grep -c '^isolation' x.mjs") !== b);
});

test("defect 8 — a line count and a match count over one file are not rivals", () => {
  const lines = quantityPhrase("git show origin/main:tooling/grip/mint.mjs | wc -l");
  const matches = quantityPhrase("git show origin/main:tooling/grip/mint.mjs | grep -c 'export'");
  ok(lines !== matches, `both minted ${lines}`);
  // the property is decided by the instrument that produces the NUMBER, which
  // is the last stage of the pipeline — not by `git show`, which only supplies
  // the bytes both stages read
  strictEqual(lines, "wc:-l");
  ok(matches.startsWith("grep:-c"), matches);
  // a `|` inside a quoted regex is NOT a pipeline boundary
  strictEqual(quantityPhrase("grep -c 'a|b' x.mjs"), "grep:-c:a|b");
  // `||` is a logical operator, not a pipe
  ok(quantityPhrase("test -f x.mjs || echo missing").startsWith("test"));
});

test("defect 8 — a pure FORMATTER at the end of a pipe is not the measurement", () => {
  // `head`/`sort`/`cat` reshape bytes, they do not derive a property, so the
  // scan walks back to the stage that does
  strictEqual(quantityPhrase("grep -c 'export' tooling/grip/mint.mjs | head -1"), quantityPhrase("grep -c 'export' tooling/grip/mint.mjs"));
  strictEqual(quantityPhrase("git log --oneline -20 | head -5"), "git:log");
  // but a formatter that is the WHOLE command is still the command — the scan
  // walks back only while there is an upstream stage to walk back TO
  strictEqual(quantityPhrase("head -20 tooling/grip/mint.mjs"), "head");
  strictEqual(quantityPhrase("cat tooling/grip/mint.mjs"), "cat");
});

test("defect 8 CONTROL — RIVAL-METHOD SURVIVES: genuinely different methods for ONE property still share a key", () => {
  // The trap: a quantity made unique per command destroys D32's signal instead
  // of repairing it, and would pass every test above. This is the control.
  // `wc -l F` and `cat F | wc -l` are DIFFERENT commands deriving the SAME
  // property — the line count of F — and MUST still collide.
  const direct = mintRecipe({ rerun: "wc -l tooling/grip/ledger.mjs" }, { observed_at: NOW });
  const piped = mintRecipe({ rerun: "cat tooling/grip/ledger.mjs | wc -l" }, { observed_at: NOW });
  strictEqual(direct.recipe.subject, piped.recipe.subject);
  strictEqual(direct.recipe.quantity, piped.recipe.quantity);
  ok(direct.recipe.rerun !== piped.recipe.rerun, "two distinct methods is what makes it a RIVAL");

  // and the fold must actually FIRE on them — the flag, not just the key
  const dir = tmpDir();
  const now = NOW.replace("00:00:00", "23:59:59");
  writeLedgerRun({ run_id: "run-direct", recipes: [direct.recipe], dir, now, screen: screenCommand });
  writeLedgerRun({ run_id: "run-piped", recipes: [{ ...piped.recipe, observed_at: "2026-07-21T00:00:01Z" }], dir, now, screen: screenCommand });
  const folded = foldLedger(dir);
  strictEqual(folded.entries.length, 1, "one property, one entry");
  strictEqual(folded.entries[0].recipes.length, 2, "BOTH methods are kept");
  strictEqual(folded.entries[0].rival_method, true, "the fold must still flag the rival");
  strictEqual(folded.rival_methods.length, 1);

  // the second control: the long spelling of a counting flag is the SAME
  // property, so `-c` and `--count` must not split one rival into two keys.
  // (Across TOOLS they still do — `rg --count` keys under `rg` — which is the
  // pre-existing behaviour this slice does not widen.)
  strictEqual(
    quantityPhrase("grep --count 'def ' api/lib/barkpark/plugin.ex"),
    quantityPhrase("grep -c 'def ' api/lib/barkpark/plugin.ex"),
  );
});

// ── deps — R2 ────────────────────────────────────────────────────────────────

test("deps carry every path the recipe reads through, not just the subject (R2)", () => {
  const m = mintRecipe({ rerun: "diff tooling/grip/mint.mjs tooling/grip/ledger.mjs" }, { observed_at: NOW });
  deepStrictEqual(m.recipe.deps, ["tooling/grip/mint.mjs", "tooling/grip/ledger.mjs"]);
});

// ── yield, reported honestly (D53) ───────────────────────────────────────────

test("path-token yield and fallback yield are reported SEPARATELY, never summed as coverage", () => {
  const facts = [
    { rerun: "wc -l tooling/grip/ledger.mjs" },
    { rerun: "grep -c export tooling/grip/mint.mjs" },
    { rerun: "git log --oneline -1 origin/main" },
    { rerun: "uname -a" },
  ];
  const { yield: y } = mintAll(facts, { observed_at: NOW });
  strictEqual(y.rerun_bearing, 4);
  strictEqual(y.path_token, 2);
  strictEqual(y.fallback, 2);
  strictEqual(y.path_token_pct, 50);
  strictEqual(y.fallback_pct, 50);
  // the two are distinct fields precisely so a caller cannot report their sum
  ok(y.path_token_pct < y.path_token_pct + y.fallback_pct);
});

test("a fact with no rerun is SKIPPED and named, never silently dropped", () => {
  const { recipes, skipped } = mintAll([{ claim: "prose only", evidence: "none" }], { observed_at: NOW });
  strictEqual(recipes.length, 0);
  deepStrictEqual(skipped, [{ index: 0, reason: "NO-RERUN" }]);
});

// ── run_id: the sanitisation is load-bearing ─────────────────────────────────

test("a raw `date -u` instant is REJECTED as a run_id — the colons violate RUN_ID", () => {
  const raw = "2026-07-21T00:00:00Z";
  const rejected = writeLedgerRun({ run_id: raw, recipes: [], dir: tmpDir() });
  strictEqual(rejected.ok, false);
  strictEqual(rejected.rejections[0].reason, "BAD-RUN-ID");
});

test("mintRunId sanitises that same instant into an id the store accepts", () => {
  strictEqual(mintRunId("2026-07-21T03:45:12Z"), "grip-20260721T034512Z");
  const dir = tmpDir();
  const row = mintRecipe({ rerun: "wc -l tooling/grip/ledger.mjs" }, { observed_at: "2026-07-21T03:45:12Z" }).recipe;
  const written = writeLedgerRun({ run_id: mintRunId("2026-07-21T03:45:12Z"), recipes: [row], dir, now: NOW.replace("00:00:00", "23:59:59") });
  strictEqual(written.ok, true, JSON.stringify(written.rejections));
});

// ── the CLI seam ─────────────────────────────────────────────────────────────

function runCli(args, { expectFail = false } = {}) {
  try {
    return execFileSync("node", [LEDGER, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    if (!expectFail) throw err;
    return `${err.stdout ?? ""}${err.stderr ?? ""}`;
  }
}

test("the write verb is shell-reachable and named in the usage line", () => {
  const usage = runCli(["--bogus-verb"], { expectFail: true });
  ok(usage.includes("write <facts.json>"), usage);
});

test("write mints, stores and folds back — round trip through the shell", () => {
  const dir = tmpDir();
  const facts = join(dir, "facts.json");
  writeFileSync(facts, JSON.stringify({ facts: [
    { claim: "ledger.mjs exports writeLedgerRun", evidence: "one hit", rerun: "grep -c 'export function writeLedgerRun' tooling/grip/ledger.mjs" },
  ] }));

  const out = runCli(["write", facts, dir]);
  ok(out.includes("subject from PATH"), out);
  ok(out.includes("read from `date -u`"), out);

  const files = readdirSync(dir).filter((f) => f.endsWith(".json") && f !== "facts.json");
  strictEqual(files.length, 1);
  ok(/^grip-\d{8}T\d{6}Z-[0-9a-f]{16}\.json$/.test(files[0]), files[0]);

  const folded = foldLedger(dir);
  strictEqual(folded.entries.length, 1);
  const entry = folded.entries[0];
  strictEqual(entry.subject, "tooling/grip/ledger.mjs");
  // the quantity carries the PATTERN, so this row can only ever be a rival of
  // another recipe counting THAT symbol — not of every `grep -c` in the store
  strictEqual(entry.quantity, "grep:-c:export function writeLedgerRun");
  ok(entry.recipes[0].rerun.includes("writeLedgerRun"));
  ok(entry.recipes[0].observed_at.endsWith("Z"));
  ok(entry.recipes[0].derived_level, "the fold must carry a derived level");
});

test("observed_at comes from the SHELL, and an observed_at in the input JSON is ignored", () => {
  const dir = tmpDir();
  const facts = join(dir, "facts.json");
  // a bare array, the other loader shape — and a forged 2087 timestamp
  writeFileSync(facts, JSON.stringify([
    { claim: "forged", evidence: "n/a", observed_at: "2087-01-01T00:00:00Z", rerun: "wc -l tooling/grip/mint.mjs" },
  ]));
  runCli(["write", facts, dir]);
  const stored = JSON.parse(readFileSync(join(dir, readdirSync(dir).find((f) => f.startsWith("grip-"))), "utf8"));
  ok(!stored.recipes[0].observed_at.startsWith("2087"), "the input's timestamp must not survive");
  ok(stored.recipes[0].observed_at.startsWith("20"), stored.recipes[0].observed_at);
});

test("an outage-capable command is REFUSED at the write seam, carrying the screen's OWN reason", () => {
  const dir = tmpDir();
  const facts = join(dir, "facts.json");
  writeFileSync(facts, JSON.stringify([
    { claim: "the parent restarts", evidence: "it came back", rerun: "systemctl stop bp-crux-parent" },
  ]));
  const out = runCli(["write", facts, dir], { expectFail: true });
  ok(out.includes("REFUSED-COMMAND"), out);
  strictEqual(readdirSync(dir).filter((f) => f.startsWith("grip-")).length, 0);
});

test("the real `now` bound is armed on the write path — a future row is refused FUTURE-OBSERVED-AT", () => {
  // The transformer cannot produce a future row (observed_at is the shell's
  // own reading), so this proves the BOUND rather than the transformer: hand a
  // forged row straight to the seam with the same now the CLI supplies.
  const dir = tmpDir();
  const now = execFileSync("date", ["-u", "+%Y-%m-%dT%H:%M:%SZ"], { encoding: "utf8" }).trim();
  const forged = { subject: "tooling/grip/ledger.mjs", quantity: "wc:-l", rerun: "wc -l tooling/grip/ledger.mjs", observed_at: "2087-01-01T00:00:00Z" };
  const result = writeLedgerRun({ run_id: mintRunId(now), recipes: [forged], dir, now, screen: screenCommand });
  strictEqual(result.ok, false);
  strictEqual(result.rejections[0].reason, "FUTURE-OBSERVED-AT");
  deepStrictEqual(readdirSync(dir).filter((f) => f.startsWith("grip-")), []);
});

test("a row carrying a value is refused VALUE-STORED at the same seam", () => {
  const dir = tmpDir();
  const now = execFileSync("date", ["-u", "+%Y-%m-%dT%H:%M:%SZ"], { encoding: "utf8" }).trim();
  const row = { subject: "tooling/grip/ledger.mjs", quantity: "wc:-l", rerun: "wc -l tooling/grip/ledger.mjs", observed_at: now, value: 544 };
  const result = writeLedgerRun({ run_id: mintRunId(now), recipes: [row], dir, now, screen: screenCommand });
  strictEqual(result.ok, false);
  ok(result.rejections.some((r) => r.reason === "VALUE-STORED"), JSON.stringify(result.rejections));
});

test("ALL-OR-NOTHING — one bad row in a batch writes no file at all", () => {
  const dir = tmpDir();
  const facts = join(dir, "facts.json");
  writeFileSync(facts, JSON.stringify([
    { claim: "good", evidence: "x", rerun: "wc -l tooling/grip/mint.mjs" },
    { claim: "bad", evidence: "x", rerun: "rm -rf tooling/grip/ledger/" },
  ]));
  runCli(["write", facts, dir], { expectFail: true });
  deepStrictEqual(readdirSync(dir).filter((f) => f.startsWith("grip-")), []);
});

// ── tgw6: mint future recipes bound to the CALLER's tree (charter D73/D74) ────
//
// A `cd <absolute checkout> && <cmd>` rerun bakes a hard path to ONE box into the
// stored recipe. mint STRIPS that leading cd — but ONLY when removing it provably
// cannot change the answer, and the arbiter of that is classifyBinding (imported,
// never restated): a ref-decided read (content-addressed / shared-ref) is invariant
// to the tree it runs in, while a per-worktree / cwd-bound / foreign-tree read is
// NOT and keeps its cd. The reason for either choice is recorded on the mint result.

test("tgw6 — the leading cd is stripped ONLY for a ref-decided remainder; kept otherwise, reason recorded", () => {
  const cases = [
    { klass: "content-addressed",   strip: true,  rerun: `cd ${REPO} && git show 1a2b3c4:tooling/grip/mint.mjs | wc -l` },
    { klass: "shared-ref",          strip: true,  rerun: `cd ${REPO} && git show origin/main:tooling/grip/mint.mjs | wc -l` },
    { klass: "per-worktree",        strip: false, rerun: `cd ${REPO} && git show HEAD:tooling/grip/mint.mjs | wc -l` },
    { klass: "cwd-bound",           strip: false, rerun: `cd ${REPO} && wc -l tooling/grip/mint.mjs` },
    { klass: "foreign-tree-pinned", strip: false, rerun: `cd ${REPO} && wc -l ${REPO}/tooling/grip/mint.mjs` },
  ];
  for (const c of cases) {
    const m = mintRecipe({ rerun: c.rerun }, { observed_at: NOW });
    ok(m.ok, c.rerun);
    strictEqual(m.binding.class, c.klass, `remainder class for: ${c.rerun}`);
    strictEqual(m.binding.rebound, c.strip, `rebound for: ${c.rerun}`);
    ok(m.binding.reason, "a reason is recorded either way");
    if (c.strip) {
      strictEqual(m.recipe.rerun, c.rerun.replace(/^cd \S+ && /, ""), "the cd prefix is gone, the remainder verbatim");
      ok(!m.recipe.rerun.startsWith("cd "), m.recipe.rerun);
      ok(m.binding.reason.startsWith("stripped"), m.binding.reason);
    } else {
      strictEqual(m.recipe.rerun, c.rerun, "the recipe keeps its cd prefix verbatim");
      ok(m.binding.reason.startsWith("kept"), m.binding.reason);
    }
  }
});

test("tgw6 — a relative cd is left alone (the invariance argument is about an ABSOLUTE pin)", () => {
  // `cd api && git show origin/main:x` would be ref-decided, but the narrow rule
  // this slice ships only touches an absolute prefix, by design.
  const m = mintRecipe({ rerun: "cd api && git show origin/main:tooling/grip/mint.mjs | wc -l" }, { observed_at: NOW });
  ok(m.ok);
  strictEqual(m.binding.rebound, false);
  strictEqual(m.binding.reason, null);
  ok(m.recipe.rerun.startsWith("cd api && "));
});

test("tgw6 — subject and deps are minted from the ORIGINAL command, so a strip never moves the index", () => {
  const withCd = mintRecipe({ rerun: `cd ${REPO} && git show origin/main:tooling/grip/mint.mjs | wc -l` }, { observed_at: NOW });
  const stripped = mintRecipe({ rerun: "git show origin/main:tooling/grip/mint.mjs | wc -l" }, { observed_at: NOW });
  strictEqual(withCd.recipe.subject, stripped.recipe.subject);
  deepStrictEqual(withCd.recipe.deps, stripped.recipe.deps);
  strictEqual(withCd.recipe.quantity, stripped.recipe.quantity);
  // the strip made the stored rerun identical to the natively-stripped one
  strictEqual(withCd.recipe.rerun, stripped.recipe.rerun);
});

// ── tgw11 defect 9: the `cd` that MOVED THE ROOT ─────────────────────────────
//
// Measured on the committed store, not invented. `grip-20260721T150000Z-v2-
// tickets-idor-fixshape.json` carries
//
//   rerun    cd <checkout>/api && CC=/usr/bin/clang mix test test/barkpark/plugins/tickets/keys_test.exs 2>&1 | tail -3
//   subject  api/test/barkpark/plugins/tickets/keys_test.exs      ← the human, repo-rooted
//   minted   test/barkpark/plugins/tickets/keys_test.exs          ← the mint, resolving to NOTHING
//
// The human is right: the store is repo-rooted, and `test/barkpark/plugins/…`
// does not exist at the repo root. Defect 1 taught the mint to strip a checkout
// ROOT; it never taught it that a `cd` into a SUBDIRECTORY moves the root the
// other way and the subject has to move with it.

test("tgw11 — `cd <checkout>/<subdir> &&` carries the subdir onto the subject AND the path-shaped deps", () => {
  const m = mintRecipe(
    { rerun: `cd ${REPO}/api && CC=/usr/bin/clang mix test test/barkpark/plugins/tickets/keys_test.exs 2>&1 | tail -3` },
    { observed_at: NOW },
  );
  ok(m.ok);
  strictEqual(m.recipe.subject, "api/test/barkpark/plugins/tickets/keys_test.exs");
  deepStrictEqual(m.recipe.deps, ["api/test/barkpark/plugins/tickets/keys_test.exs"]);
  // a worktree checkout is the same root, and the offset is read past it
  const w = mintRecipe({ rerun: `cd ${WORKTREE}/api && mix test test/support/data_case.ex` }, { observed_at: NOW });
  ok(w.ok);
  strictEqual(w.recipe.subject, "api/test/support/data_case.ex");
  // a multi-segment offset carries whole. The SUBJECT here is the cd target
  // itself — a multi-segment target survives stripRoots and is already the
  // first path token, which is behaviour this slice does not touch — but the
  // dep it moved into is now repo-rooted instead of naming a bare `src/`.
  const j = mintRecipe({ rerun: `cd ${REPO}/js/packages/react && wc -l src/index.ts` }, { observed_at: NOW });
  ok(j.ok);
  strictEqual(j.recipe.subject, "js/packages/react");
  deepStrictEqual(j.recipe.deps, ["js/packages/react", "js/packages/react/src/index.ts"]);
});

test("tgw11 — the offset is read ONLY off an absolute target that strips to a non-empty remainder", () => {
  // the target IS the checkout root: nothing moved, and defect 1 already handles it
  strictEqual(cdRootOffset(`cd ${REPO} && wc -l tooling/grip/mint.mjs`), null);
  strictEqual(cdRootOffset(`cd ${WORKTREE} && wc -l tooling/grip/mint.mjs`), null);
  // a BARE RELATIVE target: the cwd it was typed in is not recorded anywhere.
  // The live store's `cd barkpark && git grep … -- api/lib` is the counter-
  // example — the target is the REPO reached from its parent, and carrying it
  // would mint `barkpark/api/lib`, a directory that has never existed.
  strictEqual(cdRootOffset("cd api && grep -rn receive_timeout lib/"), null);
  strictEqual(subjectOf("cd barkpark && git grep -c DedupWall origin/main -- api/lib"), "api/lib");
  // a FOREIGN absolute target: the offset is unknowable, behaviour UNCHANGED —
  // the target mints nothing (PATH_SHAPED refuses an absolute) and every other
  // token mints bare, exactly as before this change.
  strictEqual(cdRootOffset("cd /Users/f/Documents/GitHub/barkpark/api && mix test test/y_test.exs"), null);
  strictEqual(subjectOf("cd /Users/f/Documents/GitHub/barkpark/api && mix test test/y_test.exs"), "test/y_test.exs");
  strictEqual(cdRootOffset("cd /tmp && wc -l probe.txt"), null);
  // no leading cd at all
  strictEqual(cdRootOffset("mix test test/y_test.exs"), null);
});

test("tgw11 — a token the `cd` cannot reach is NOT carried: absolute, and ref-qualified", () => {
  // ABSOLUTE — resolved by the filesystem; stripRoots already root-anchored it,
  // so a carry would double the prefix into `api/api/lib/z.ex`.
  strictEqual(subjectOf(`cd ${REPO}/api && wc -l ${REPO}/api/lib/z.ex`), "api/lib/z.ex");
  // REF-QUALIFIED — in `git show <rev>:<path>` a path not beginning `./` is
  // relative to the REPO ROOT, so git already answers root-relative.
  strictEqual(subjectOf(`cd ${REPO}/api && git show origin/main:api/lib/x.ex | wc -l`), "api/lib/x.ex");
  const mixed = mintRecipe(
    { rerun: `cd ${REPO}/api && diff <(git show origin/main:api/lib/x.ex) lib/x.ex` },
    { observed_at: NOW },
  );
  ok(mixed.ok);
  // one root-relative token from the ref, one cwd-relative token carried — both
  // land on the SAME repo-rooted key, which is the whole point of the carry
  deepStrictEqual(mixed.recipe.deps, ["api/lib/x.ex"]);
});

test("tgw11 — the carry does not touch quantity, binding, or a rerun with no leading cd", () => {
  const rerun = `cd ${REPO}/api && grep -c 'isolation' lib/barkpark/plugins/capabilities.ex`;
  const m = mintRecipe({ rerun }, { observed_at: NOW });
  ok(m.ok);
  strictEqual(m.recipe.subject, "api/lib/barkpark/plugins/capabilities.ex");
  strictEqual(m.recipe.quantity, "grep:-c:isolation");
  // cwd-bound remainder ⇒ classifyBinding keeps the cd, untouched by defect 9
  strictEqual(m.binding.rebound, false);
  strictEqual(m.recipe.rerun, rerun);
  // and the no-cd control still mints bare
  strictEqual(subjectOf("mix test test/barkpark/plugins/tickets/keys_test.exs"), "test/barkpark/plugins/tickets/keys_test.exs");
});

// ── REGRESSION FLOOR: the provable NO-OP over the committed corpus ────────────
//
// Re-minting every row THE WRITE PATH PRODUCED must leave its subject and deps
// unchanged (expected 0 moved) — apart from ONE named, shape-checked, frozen
// class, `LEGACY_CARRY_CEILING` below. This is what makes S1's data merge-order-
// independent of the tgw6 slice: THAT transform only rewrites the stored rerun,
// never the indexing keys.
//
// THE SCOPE IS A SHAPE, AND IT IS PRINTED ON PASS. `tooling/grip/ledger/` is a
// SHARED APPEND-ONLY commons (D118): four epics write into it, most of them by
// hand, and a hand-authored row never crossed `mintRecipe` at all. Re-minting
// one of those measures the distance between a human's subject line and the
// mint's — real, worth ruling on, and NOT a mint regression. The floor walks
// the WRITE-PATH-ATTESTED runs (`isAttestedRun`: the filename reproduces the
// digest of the file's own bytes, so `writeLedgerRun` demonstrably produced it),
// which is precisely the population whose invariance the mint promises.
//
// WHAT THIS SCOPE IS NOT: a pinned file list. Re-pointing this walk at
// binding.test.mjs's three CENSUS_RUN_FILES turns "307 of 631 rows moved" into
// "0 of 62" — a PASS over 9.8% of the rows carrying 0.0% of the drift — and it
// is INVISIBLE, because the counts only ever appeared inside the failure
// message while the test name still promised "every committed ledger row".
// Two things stop that recurring here: the walked scope is printed on PASS, and
// the floors below are GROWTH floors (`>=`, re-derived 2026-07-28 at 22 runs /
// 319 rows). An `===` on a file count would reintroduce the same staleness bug
// one level down.

const LEDGER_DIR = fileURLToPath(new URL("../ledger", import.meta.url));

// Re-derived 2026-07-28 in a clean git worktree at origin/main 072978af0:
// 78 files → 40 grip-owned runs, 22 of them write-path attested, 319 rows.
// GROWTH floors: every honestly-written run attests automatically, so this can
// only go up. A DROP means the scope stopped seeing runs it used to see.
const ATTESTED_RUNS_FLOOR = 22;
const ATTESTED_ROWS_FLOOR = 319;

// THE ONE DELIBERATE MOVE (tgw11, defect 9). The store is append-only, so the
// rows minted BEFORE the `cd`-root carry keep the subdirectory-relative keys
// the old mint derived. Re-minting them now restores the repo-rooted form, and
// that is the fix landing, not a regression — but it is not waved through
// either. Two things bound it, and neither is a filename:
//
//   1. A SHAPE, not an allowlist. `carriedOnly` demands that EVERY key in the
//      row either is unchanged or gains exactly the one `<offset>/` prefix that
//      `cdRootOffset` reads off that row's own rerun. A move of any other shape
//      — a different subject, a dropped dep, a reordering — still fails.
//   2. A CEILING THAT CANNOT GROW. Every row written from here on is minted by
//      the carrying code, so its stored subject already carries the offset and
//      re-minting it is a no-op: no NEW attested row can ever enter this class.
//      The set is frozen legacy, so `<=` is the honest direction. Re-derived
//      2026-09-02 at 5 rows over 342 (two run files, both `cd <checkout>/api`).
const LEGACY_CARRY_CEILING = 5;

// Every key either unchanged or exactly `<offset>/<key>`, with at least one
// actually carried. Anything else is a real regression and must still red.
function carriedOnly(row, minted) {
  const offset = cdRootOffset(row.rerun);
  if (offset === null) return false;
  const storedDeps = row.deps ?? [];
  if (minted.deps.length !== storedDeps.length) return false;
  let carried = 0;
  const keyOk = (from, to) => {
    if (to === from) return true;
    if (to === `${offset}/${from}`) { carried += 1; return true; }
    return false;
  };
  if (!keyOk(row.subject, minted.subject)) return false;
  for (let i = 0; i < storedDeps.length; i += 1) if (!keyOk(storedDeps[i], minted.deps[i])) return false;
  return carried > 0;
}

test("REGRESSION FLOOR — re-minting every committed ledger row leaves subject and deps unchanged", () => {
  const { runs, shape } = readLedgerRuns(LEDGER_DIR);
  const attested = runs.filter((run) => inScope(run, "attested"));
  ok(attested.length >= ATTESTED_RUNS_FLOOR, `the write-path-attested scope must not SHRINK: ${attested.length} run(s) < floor ${ATTESTED_RUNS_FLOOR}`);
  let rows = 0;
  const moved = [];
  const carried = [];
  const remint = (row) => {
    const re = mintRecipe({ rerun: row.rerun }, { observed_at: row.observed_at });
    if (!re.ok) return { rerun: row.rerun, reason: re.reason };
    const subjMoved = re.recipe.subject !== row.subject;
    const depsMoved = JSON.stringify(re.recipe.deps) !== JSON.stringify(row.deps ?? []);
    if (!subjMoved && !depsMoved) return null;
    return { rerun: row.rerun, from: [row.subject, row.deps], to: [re.recipe.subject, re.recipe.deps], carry: carriedOnly(row, re.recipe) };
  };
  for (const run of attested) {
    for (const row of run.recipes) {
      rows += 1;
      const drift = remint(row);
      if (!drift) continue;
      if (drift.carry) carried.push({ file: run.file, ...drift });
      else moved.push({ file: run.file, ...drift });
    }
  }
  ok(rows >= ATTESTED_ROWS_FLOOR, `the walked corpus must not SHRINK: ${rows} row(s) < floor ${ATTESTED_ROWS_FLOOR}`);
  strictEqual(moved.length, 0, `${moved.length} of ${rows} attested rows moved subject/deps OUTSIDE the tgw11 carry class: ${JSON.stringify(moved)}`);
  ok(
    carried.length <= LEGACY_CARRY_CEILING,
    `the frozen legacy tgw11 carry class must not GROW: ${carried.length} row(s) > ceiling ${LEGACY_CARRY_CEILING}. ` +
      `A new attested row here means the write path minted a subdir-relative subject again: ${JSON.stringify(carried)}`,
  );

  // The rows OUTSIDE the scope are counted and printed, never hidden. They are
  // the hand-authored runs, and their drift is a real, ruled-on number (99 rows
  // across 18 files at origin/main 072978af0, every one of them hand-written;
  // ZERO attested rows drift). Ruled in the PR body and owned by
  // `tgw11-bl-mint-path-root-relativity` for the one class that is a mint bug.
  const handAuthored = runs.filter((run) => inScope(run, "owned") && !inScope(run, "attested"));
  let handRows = 0;
  const handMoved = [];
  for (const run of handAuthored) {
    for (const row of run.recipes) {
      handRows += 1;
      if (remint(row)) handMoved.push(run.file);
    }
  }
  console.log(
    `\n  [floor] scope=attested — ${rows} row(s) over ${attested.length} run file(s), 0 moved outside the carry class` +
      `\n  [floor] tgw11 legacy cd-root carry: ${carried.length} row(s) over ${new Set(carried.map((c) => c.file)).size} file(s) (ceiling ${LEGACY_CARRY_CEILING}, frozen)` +
      `\n  [floor] declined: ${handAuthored.length} hand-authored grip run file(s) (${handRows} rows, ${handMoved.length} drifting over ${new Set(handMoved).size} files), ` +
      `${shape.foreign} foreign run file(s), ${shape.not_a_run} NOT-A-RUN document(s)\n`,
  );
});

// ── INVARIANCE: a stripped row answers identically from two different trees ───
//
// For a ref-decided remainder the four answers — original & stripped, each run
// from two separate worktrees of this clone — must all agree. That agreement is
// the proof that dropping the `cd` changed nothing. Tree B is a `--no-checkout`
// linked worktree: it never materialises files (fast, and read-only over the
// object DB is all `git show` needs).

test("INVARIANCE — original and stripped rerun give four identical answers from two trees", () => {
  const toplevel = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
  const original = `cd ${toplevel} && git show origin/main:internal/cli/tasks_next_cmd.go | wc -l`;
  const strippedCmd = "git show origin/main:internal/cli/tasks_next_cmd.go | wc -l";

  // the mint decides this row is stripped, and to exactly this remainder
  const minted = mintRecipe({ rerun: original }, { observed_at: NOW });
  ok(minted.ok);
  strictEqual(minted.binding.rebound, true);
  strictEqual(minted.recipe.rerun, strippedCmd);

  const treeB = mkdtempSync(join(tmpdir(), "grip-treeB-"));
  const run = (cmd, cwd) => execFileSync("sh", ["-c", cmd], { cwd, encoding: "utf8" }).trim();
  try {
    execFileSync("git", ["-C", toplevel, "worktree", "add", "--no-checkout", "--detach", treeB, "origin/main"], { stdio: "ignore" });
    const answers = [
      run(original, toplevel),      // original, tree A
      run(strippedCmd, toplevel),   // stripped, tree A
      run(original, treeB),         // original, tree B
      run(strippedCmd, treeB),      // stripped, tree B
    ];
    strictEqual(new Set(answers).size, 1, `four answers must agree: ${JSON.stringify(answers)}`);
    ok(Number(answers[0]) > 0, `the shared-ref file has a real line count: ${answers[0]}`);
  } finally {
    try { execFileSync("git", ["-C", toplevel, "worktree", "remove", "--force", treeB], { stdio: "ignore" }); } catch { /* prune below */ }
    try { execFileSync("git", ["-C", toplevel, "worktree", "prune"], { stdio: "ignore" }); } catch { /* best effort */ }
  }
});
