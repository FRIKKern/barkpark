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
import { admitRecipe, foldLedger, mintRunId, writeLedgerRun } from "../ledger.mjs";
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
  strictEqual(entry.quantity, "grep:-c");
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
