#!/usr/bin/env node
// Proof for the REDUCED read path — tooling/grip/leads.mjs — and for the
// `prescreen` rehearsal verb that ships alongside it.
//
//   node --test tooling/grip/test/leads.test.mjs
//
// FIVE OBLIGATIONS, and the suite is shaped around them rather than around the
// module's function list:
//
//   1. NO VALUE CAN REACH THE SCREEN, EVEN FROM A FORGED FILE. Proven by
//      forging one: a run file is hand-written with `value` on every row and
//      folded, and both the JSON and the human render are searched for it. A
//      test that only asserted "leads.mjs never writes a value key" would prove
//      the author's intent, not the schema's guarantee.
//
//   2. THE THREE CUTS STAY CUT (charter D43). No staleness band, no ranking, no
//      RIVAL-METHOD flag — each asserted on rendered output, because a cut that
//      lives only in a comment grows back.
//
//   3. THE FILTER IS CASE-INSENSITIVE, FAIL-FIRST (D44). The measured specimen
//      is used, and the same corpus is run through a deliberately
//      case-SENSITIVE mutant in the same test, which must return 0. Without the
//      mutant half, the assertion passes against a filter that never folded
//      case at all — the query "completion" would still match if the corpus
//      happened to be lowercase.
//
//   4. THE LEVEL IS RE-DERIVED, NOT READ. A row is stored with a deliberately
//      WRONG `derived_level` and the render must contradict it.
//
//   5. PRESCREEN WRITES NOTHING, AND READS `.ok`. The store is byte-compared
//      across a real spawn over a facts file that contains refused commands.
//      The `.ok` shape is pinned separately because reading `.safe` fails as
//      its own opposite: undefined is falsy, so every row scores refused, while
//      the reason string carried alongside still reads "admitted".

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  CMD_SUBJECT_PREFIX, NO_VALUE_FOOTER, STRUCTURAL_MISSES,
  censusIndex, isCommandShapeSubject, matchesQuery, renderLeads, selectLeads,
} from "../leads.mjs";
import { foldLedger, DEFAULT_LEDGER_DIR } from "../ledger.mjs";
import { screenCommand } from "../screen.mjs";

const LEDGER_CLI = fileURLToPath(new URL("../ledger.mjs", import.meta.url));
const LEADS_SRC = readFileSync(fileURLToPath(new URL("../leads.mjs", import.meta.url)), "utf8");
const LEDGER_SRC = readFileSync(LEDGER_CLI, "utf8");

// ── helpers ──────────────────────────────────────────────────────────────────

function tempStore(rows, { run_id = "grip-20260721T000000Z" } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "grip-leads-"));
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${run_id}-test.json`), `${JSON.stringify({ run_id, recipes: rows }, null, 2)}\n`);
  return dir;
}

function row(subject, quantity, rerun, extra = {}) {
  return {
    subject, quantity, rerun,
    derived_level: "L3",
    deps: [subject],
    observed_at: "2026-07-21T03:46:16Z",
    ...extra,
  };
}

function runCli(args) {
  try {
    return { stdout: execFileSync("node", [LEDGER_CLI, ...args], { encoding: "utf8" }), status: 0 };
  } catch (err) {
    return { stdout: `${err.stdout ?? ""}${err.stderr ?? ""}`, status: err.status ?? 1 };
  }
}

function storeFingerprint(dir) {
  return readdirSync(dir).sort().map((f) => `${f}\n${readFileSync(join(dir, f), "utf8")}`).join("\n");
}

// ── 1. leads hand over METHOD, never a value ─────────────────────────────────

test("a FORGED run file carrying `value` on every row cannot put that value on the screen", () => {
  // Hand-written on disk, bypassing admitRecipe entirely — the write-path
  // rejection (VALUE-STORED) is not what is under test here. What is under test
  // is that the READ path is structurally incapable of surfacing it, because
  // foldLedger's projection rebuilds each recipe from six NAMED fields.
  const dir = tempStore([
    { ...row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex"), value: 544 },
    { ...row("api/lib/y.ex", "wc:-l", "wc -l api/lib/y.ex"), observed_value: "42 modules", answer: "yes" },
  ]);
  const result = selectLeads(foldLedger(dir), "api/lib");
  assert.equal(result.rows.length, 2);
  for (const r of result.rows) {
    assert.ok(!Object.hasOwn(r, "value"), "no row may carry a value field");
    assert.ok(!Object.hasOwn(r, "observed_value"));
    assert.ok(!Object.hasOwn(r, "answer"));
  }
  const rendered = renderLeads(result);
  assert.ok(!rendered.includes("544"), "the forged value must not reach the human render");
  assert.ok(!rendered.includes("42 modules"));
  assert.ok(!JSON.stringify(result).includes("544"), "nor the machine render");
});

test("the no-value guarantee is stated out loud in the footer, on hits and on the honest empty alike", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]);
  const folded = foldLedger(dir);
  assert.ok(renderLeads(selectLeads(folded, "api")).includes(NO_VALUE_FOOTER));
  assert.ok(renderLeads(selectLeads(folded, "nothing-matches-this")).includes(NO_VALUE_FOOTER));
});

test("leads executes nothing — no spawn call appears in the module at all", () => {
  for (const forbidden of ["execFileSync", "execSync", "spawnSync", "child_process"]) {
    assert.ok(!LEADS_SRC.includes(forbidden), `leads.mjs must not reference ${forbidden}: executing a recipe would surface an ANSWER`);
  }
});

// ── 2. the filter IS the feature, and it narrows ─────────────────────────────

test("the rerun substring narrows a multi-row bucket — real numbers, before and after", () => {
  const bucket = [
    row("internal/cli", "go:test", "go test ./internal/cli/"),
    row("internal/cli", "go:vet", "go vet ./internal/cli/"),
    row("internal/cli", "go:build", "go build ./internal/cli/"),
    row("internal/cli", "grep:-c", "grep -c 'func ' internal/cli/task_cmd.go"),
    row("internal/cli", "grep:-n", "grep -n 'bp task' internal/cli/task_cmd.go"),
    row("internal/cli", "wc:-l", "wc -l internal/cli/task_cmd.go"),
  ];
  const folded = foldLedger(tempStore(bucket));
  const all = selectLeads(folded, "internal/cli");
  const narrowed = selectLeads(folded, "grep");
  assert.equal(all.rows.length, 6, "the unfiltered bucket");
  assert.equal(narrowed.rows.length, 2, "the same bucket narrowed by the rerun substring `grep`");
  assert.equal(selectLeads(folded, "go vet").rows.length, 1, "narrower still");
  // …and the substring is honestly DUMB: `go` matches every row here, because
  // five of the six commands name a `.go` path. The filter is a substring over
  // subject+rerun and nothing more; a reader who expects token matching would
  // misread this count, so it is asserted rather than left to be discovered.
  assert.equal(selectLeads(folded, "go").rows.length, 6);
});

test("THE FILTER IS CASE-INSENSITIVE — the measured `completion` specimen, with a case-SENSITIVE mutant that must return 0", () => {
  // The measured defect verbatim: this command lives in a real bucket, and a
  // case-sensitive filter answers 0 for "completion" — a FALSE honest empty,
  // which against this epic's bar is worse than no filter at all.
  const specimen = "go test -run TestCompletionNounsCoverAllDispatchedBuiltins ./internal/cli/";
  const folded = foldLedger(tempStore([row("internal/cli", "go:test", specimen)]));

  const shipped = selectLeads(folded, "completion");
  assert.equal(shipped.rows.length, 1, "the shipped filter folds case and finds it");
  assert.equal(shipped.rows[0].rerun, specimen);

  // THE FAIL-FIRST HALF. Same corpus, same query, one behaviour changed.
  const caseSensitive = folded.entries.flatMap((e) => e.recipes.filter((r) => `${e.subject} ${r.rerun}`.includes("completion")));
  assert.equal(caseSensitive.length, 0, "a case-sensitive implementation answers 0 — this is what the shipped filter must beat");

  // …and the matcher itself, at the unit, in both directions.
  assert.equal(matchesQuery({ subject: "internal/cli" }, { rerun: specimen }, "completion"), true);
  assert.equal(matchesQuery({ subject: "INTERNAL/CLI" }, { rerun: "" }, "internal/cli"), true);
  assert.equal(matchesQuery({ subject: "internal/cli" }, { rerun: specimen }, ""), false, "an empty needle matches nothing, never everything");
});

test("a needle cannot match ACROSS the subject/rerun boundary and invent a hit", () => {
  // Joined by NUL, the one byte a typed query cannot carry. Without a separator
  // that cannot be typed, "internal/cliwc" would match `internal/cli` + `wc -l …`
  // — a hit assembled out of two strings that never touched.
  assert.equal(matchesQuery({ subject: "internal/cli" }, { rerun: "wc -l internal/cli/x.go" }, "internal/cliwc"), false);
  assert.equal(matchesQuery({ subject: "internal/cli" }, { rerun: "wc -l internal/cli/x.go" }, "internal/cli"), true);
});

// ── 3. observed_at: three states, no band ────────────────────────────────────

test("state 1 — the RAW observed_at is rendered, and no staleness band is computed from it", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex", { observed_at: "2024-01-02T03:04:05Z" })]);
  const rendered = renderLeads(selectLeads(foldLedger(dir), "api"));
  assert.ok(rendered.includes("2024-01-02T03:04:05Z"), "the raw instant, not a band");
  for (const banned of ["STALE", "stale", "aging", "fresh", "days old", "ago"]) {
    assert.ok(!rendered.includes(banned), `charter D43 cut the staleness band — "${banned}" must not appear`);
  }
});

test("state 2 — the CENSUS VERDICT is rendered when one exists for that exact command", () => {
  const rerun = "wc -l api/lib/x.ex";
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", rerun)]);
  const census = censusIndex({
    rows: [{ command: rerun, outcome: "STILL-ANSWERING", answering: true, decayed: false, admissible: true }],
  });
  const rendered = renderLeads(selectLeads(foldLedger(dir), "api", { census }));
  assert.ok(rendered.includes("census STILL-ANSWERING"), rendered);
  assert.ok(!rendered.includes("never re-checked"));
});

test("state 3 — `never re-checked` when no census verdict exists, which is the normal case (census.mjs stores nothing)", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]);
  // No census at all…
  assert.ok(renderLeads(selectLeads(foldLedger(dir), "api")).includes("never re-checked"));
  // …and a census that simply does not carry THIS command is the same state,
  // never a silently blank column.
  const census = censusIndex({ rows: [{ command: "wc -l some/other/file.ex", outcome: "STILL-ANSWERING", admissible: true }] });
  assert.ok(renderLeads(selectLeads(foldLedger(dir), "api", { census })).includes("never re-checked"));
});

test("an INADMISSIBLE census verdict says so — it measured this host, not the ledger", () => {
  const rerun = "wc -l api/lib/x.ex";
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", rerun)]);
  const census = censusIndex({ rows: [{ command: rerun, outcome: "WRONG-CWD", decayed: false, admissible: false }] });
  assert.match(renderLeads(selectLeads(foldLedger(dir), "api", { census })), /census WRONG-CWD \(inadmissible/);
});

// ── 4. no ranking, no rival-method flag ──────────────────────────────────────

test("NO RANKING — the order is a deterministic (subject, observed_at desc) sort, stable across two runs", () => {
  const dir = tempStore([
    row("b/two.ex", "wc:-l", "wc -l b/two.ex", { observed_at: "2026-07-21T03:00:00Z" }),
    row("a/one.ex", "wc:-l", "wc -l a/one.ex", { observed_at: "2026-07-20T03:00:00Z" }),
    row("a/one.ex", "grep:-c", "grep -c x a/one.ex", { observed_at: "2026-07-21T03:00:00Z" }),
  ]);
  const folded = foldLedger(dir);
  const once = selectLeads(folded, ".ex").rows.map((r) => r.rerun);
  const twice = selectLeads(foldLedger(dir), ".ex").rows.map((r) => r.rerun);
  assert.deepEqual(once, twice, "two runs, identical order");
  assert.deepEqual(once, [
    "grep -c x a/one.ex",   // a/ first; newest of a/'s two rows first
    "wc -l a/one.ex",
    "wc -l b/two.ex",
  ]);
  const rendered = renderLeads(selectLeads(folded, ".ex"));
  for (const banned of ["rank", "Rank", "score", "best match", "top match"]) {
    assert.ok(!rendered.includes(banned), `charter D43 cut the ranking — "${banned}" must not appear`);
  }
});

test("the CLI renders byte-identically across two invocations", () => {
  const dir = tempStore([
    row("a/one.ex", "wc:-l", "wc -l a/one.ex"),
    row("a/one.ex", "grep:-c", "grep -c x a/one.ex"),
  ]);
  const a = runCli(["leads", ".ex", "--dir", dir]);
  const b = runCli(["leads", ".ex", "--dir", dir]);
  assert.equal(a.status, 0);
  assert.equal(a.stdout, b.stdout);
});

test("NO RIVAL-METHOD FLAG — the row count carries the message instead", () => {
  const dir = tempStore([
    row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex"),
    row("api/lib/x.ex", "wc:-l", "wc -l /abs/api/lib/x.ex"),
  ]);
  const folded = foldLedger(dir);
  assert.equal(folded.rival_methods.length, 1, "the FOLD still flags it — this test is about the RENDER");
  const rendered = renderLeads(selectLeads(folded, "api/lib"));
  assert.ok(!rendered.includes("RIVAL-METHOD"), "the literal string must not appear in leads output");
  assert.ok(rendered.includes("(2 methods on this key — run all 2 and compare)"), rendered);
});

test("the methods count describes the KEY, not the filtered slice", () => {
  const dir = tempStore([
    row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex"),
    row("api/lib/x.ex", "wc:-l", "wc -l /abs/api/lib/x.ex"),
  ]);
  // A query that matches only ONE of the two rows still reports 2 methods:
  // the message is "this key has two cheap checks", and a count that shrank
  // with the query would be describing the query instead.
  const result = selectLeads(foldLedger(dir), "/abs/");
  assert.equal(result.rows.length, 1);
  assert.equal(result.rows[0].methods_on_key, 2);
});

// ── 5. the D45 exclusion, and the null state that names it ───────────────────

test("cmd:<head> subjects are EXCLUDED from the index (charter D45), and counted", () => {
  const dir = tempStore([
    row("cmd:bp", "bp:task", "bp task ready"),
    row("cmd:bp", "bp:doc", "bp doc ls task"),
    row("cmd:git", "git:status", "git status"),
    row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex"),
  ]);
  const result = selectLeads(foldLedger(dir), "bp");
  assert.equal(result.rows.length, 0, "a cmd: dumping ground is not a subject, so `bp` finds nothing");
  assert.equal(result.hidden_cmd_subjects, 3);
  assert.equal(result.hidden_cmd_recipes, 3);
  assert.equal(result.indexed_subjects, 1);
  assert.equal(isCommandShapeSubject(`${CMD_SUBJECT_PREFIX}bp`), true);
  assert.equal(isCommandShapeSubject("api/lib/x.ex"), false);
});

test("the null state NAMES the three structural misses, on exact output text", () => {
  const rendered = renderLeads(selectLeads(foldLedger(tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")])), "task-abc123"));
  assert.ok(rendered.includes("HONEST EMPTY"), "an empty is an ANSWER, never a blank or an error");
  assert.ok(!rendered.includes("[]"), "never print []");
  for (const miss of STRUCTURAL_MISSES) assert.ok(rendered.includes(miss), `missing structural miss: ${miss}`);
  assert.ok(rendered.includes("the ledger indexes repo PATHS — it cannot index bp task ids"));
  assert.ok(rendered.includes("it cannot answer judgment questions"));
});

test("the null state states HOW MANY subjects the D45 exclusion hid — the count, not just that some are hidden", () => {
  const dir = tempStore([
    row("cmd:bp", "bp:task", "bp task ready"),
    row("cmd:bp", "bp:doc", "bp doc ls task"),
    row("cmd:curl", "curl:-s", "curl -s http://localhost:4000/api/schemas"),
    row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex"),
  ]);
  const rendered = renderLeads(selectLeads(foldLedger(dir), "no-such-thing"));
  assert.ok(
    rendered.includes("Hidden by the charter-D45 exclusion: 3 cmd:<head> subjects (3 recipes) are not"),
    rendered,
  );
  // An exclusion nobody can count is indistinguishable from an empty store.
  assert.ok(!/Hidden by the charter-D45 exclusion: some/.test(rendered));
});

// ── 6. the level is RE-DERIVED at render time ────────────────────────────────

test("a deliberately STALE stored derived_level is contradicted, not printed", () => {
  // `curl https://prod/health` reaches a running system: L1. The stored field
  // claims L3, and foldLedger carries the stored value through untouched
  // (tgw2-fold-reread-derived-level). leads must not inherit that.
  const rerun = "curl -s https://api.barkpark.cloud/api/schemas";
  const dir = tempStore([row("cmd-free/subject.mjs", "curl:-s", rerun, { derived_level: "L3" })]);
  const result = selectLeads(foldLedger(dir), "curl");
  assert.equal(result.rows.length, 1);
  assert.equal(result.rows[0].stored_level, "L3", "the stored value is carried, so the disagreement is visible");
  assert.notEqual(result.rows[0].derived_level, "L3", "…and it is NOT what gets rendered as the level");
  assert.equal(result.rows[0].level_restated, true);
  const rendered = renderLeads(result);
  assert.match(rendered, /stored L3, NOT trusted: re-derived from the command/);
});

test("leads never reads the stored derived_level as the rendered level", () => {
  assert.ok(LEADS_SRC.includes("deriveLevel(rerun)"), "the level is derived from the command");
  assert.ok(!/derived_level:\s*(recipe|row)\?\.derived_level/.test(LEADS_SRC), "…never copied from storage");
});

// ── 7. prescreen: writes nothing, and reads `.ok` ────────────────────────────

test("`prescreen` reports a per-row verdict and WRITES NOTHING — the real store is byte-identical afterwards", () => {
  const facts = join(mkdtempSync(join(tmpdir(), "grip-prescreen-")), "facts.json");
  writeFileSync(facts, JSON.stringify({
    facts: [
      { claim: "leads.mjs line count", evidence: "…", rerun: "wc -l tooling/grip/leads.mjs" },
      { claim: "the unit is down", evidence: "…", rerun: "systemctl stop bp-crux-parent" },
      { claim: "the releases are gone", evidence: "…", rerun: "rm -rf /opt/barkpark/releases" },
    ],
  }, null, 2));

  const before = storeFingerprint(DEFAULT_LEDGER_DIR);
  const res = runCli(["prescreen", facts]);
  const after = storeFingerprint(DEFAULT_LEDGER_DIR);

  assert.equal(before, after, "the ledger store must be byte-identical after a prescreen");
  assert.equal(res.status, 1, "a file `write` would refuse exits nonzero, so a script can gate on it");
  assert.match(res.stdout, /WRITES NOTHING/);
  assert.match(res.stdout, /screen admits\s+1/);
  assert.match(res.stdout, /screen refuses\s+2/);
  assert.match(res.stdout, /REFUSE \[1\]/);
  assert.match(res.stdout, /write` WOULD REFUSE THIS FILE and store nothing/);
});

test("`prescreen` over an all-clean facts file exits 0 and still writes nothing", () => {
  const facts = join(mkdtempSync(join(tmpdir(), "grip-prescreen-ok-")), "facts.json");
  writeFileSync(facts, JSON.stringify([{ claim: "x", evidence: "y", rerun: "wc -l tooling/grip/leads.mjs" }]));
  const before = storeFingerprint(DEFAULT_LEDGER_DIR);
  const res = runCli(["prescreen", facts]);
  assert.equal(storeFingerprint(DEFAULT_LEDGER_DIR), before);
  assert.equal(res.status, 0);
  assert.match(res.stdout, /all 1 rows pass the screen/);
  assert.match(res.stdout, /Nothing was stored by this run/);
});

test("PINNED — screenCommand returns `.ok`, NOT `.safe`; reading `.safe` fails as its own opposite", () => {
  const admitted = screenCommand("wc -l tooling/grip/leads.mjs");
  assert.equal(admitted.ok, true);
  assert.equal(admitted.safe, undefined, "there is no `.safe` key — reading it yields undefined");
  assert.ok(!Object.hasOwn(admitted, "safe"));
  // THE TRAP, DEMONSTRATED. Under `.safe`, an ADMITTED row scores refused while
  // the reason string it carries still says "admitted" — the mistake renders as
  // its own opposite, which is why a verifier scored 0 of 40 and believed the
  // screen, not the bug.
  assert.equal(Boolean(admitted.safe), false);
  assert.match(admitted.reason, /^admitted/);

  const refused = screenCommand("systemctl stop bp-crux-parent");
  assert.equal(refused.ok, false);
  assert.equal(refused.safe, undefined);
});

test("the prescreen implementation reads `.ok` and never `.safe`", () => {
  // Comment lines are dropped before the scan: this file DOCUMENTS the `.safe`
  // trap at length, and a grep that could not tell the warning from the defect
  // would force the warning to be deleted to stay green.
  const code = (src) => src.split("\n").filter((l) => !l.trim().startsWith("//") && !l.trim().startsWith("*")).join("\n");
  assert.ok(LEDGER_SRC.includes("screened.ok === true"), "the verdict is read off `.ok`");
  assert.ok(!/\w\.safe\b/.test(code(LEDGER_SRC)), "ledger.mjs must not read a `.safe` key in code");
  assert.ok(!/\w\.safe\b/.test(code(LEADS_SRC)), "nor may leads.mjs");
});

// ── 8. the CLI seam ──────────────────────────────────────────────────────────

test("`leads` with no substring is a DIAGNOSIS naming the fix, not an empty result", () => {
  const res = runCli(["leads"]);
  assert.equal(res.status, 2);
  assert.match(res.stdout, /leads needs a substring/);
  assert.match(res.stdout, /case-insensitively over the subject and the rerun/);
});

test("both new verbs are on the dispatch chain, and the usage string names them", () => {
  const usage = runCli(["no-such-verb"]);
  assert.equal(usage.status, 2);
  assert.match(usage.stdout, /leads <substring>/);
  assert.match(usage.stdout, /prescreen <facts.json>/);
  assert.match(usage.stdout, /write <facts.json>/);
  assert.match(usage.stdout, /fold \[dir\]/);
});

test("`leads --json` is the machine render of exactly what the human render showed", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]);
  const res = runCli(["leads", "api", "--json", "--dir", dir]);
  assert.equal(res.status, 0);
  const parsed = JSON.parse(res.stdout);
  assert.equal(parsed.query, "api");
  assert.equal(parsed.rows.length, 1);
  assert.equal(parsed.rows[0].rerun, "wc -l api/lib/x.ex");
  assert.ok(!Object.hasOwn(parsed.rows[0], "value"));
});

test("an honest empty exits 0 — `nobody has checked this yet` is an answer, not a failure", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]);
  const res = runCli(["leads", "nothing-matches", "--dir", dir]);
  assert.equal(res.status, 0);
  assert.match(res.stdout, /HONEST EMPTY/);
});

test("a bad --census path is a named refusal, never a silently verdict-less render", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]);
  const res = runCli(["leads", "api", "--dir", dir, "--census", join(dir, "no-such-report.json")]);
  assert.equal(res.status, 2);
  assert.match(res.stdout, /is not a readable census --json report/);
});
