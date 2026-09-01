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
  CMD_SUBJECT_PREFIX, MATCH_RULE, NO_VALUE_FOOTER, STRUCTURAL_MISSES, SUBSYSTEM_BAND,
  ancestorPrefixCount, censusIndex, childBreakdown, isCommandShapeSubject, matchesQuery,
  renderLeads, selectLeads, subjectSegmentMatch, subsystemBand,
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

// ── THE ARMING THESE FIXTURES ARE FOLDED UNDER ──────────────────────────────
//
// `foldLedger` DEFAULTS its screen on (see its ARMING header): a library read
// and the `fold` CLI read of one store now return the same counts. leads is a
// FILTER OVER entries[], and three fixtures below deliberately carry commands
// screenCommand refuses — `go build` (it writes artifacts) and `git grep -c …`
// (the screen reads git's `-c` as its config flag and refuses what it cannot
// bound). Neither refusal is what those tests measure, so they fold under the
// EXPLICIT opt-out and say so, rather than being quietly re-specimened to dodge
// the screen. `UNSCREENED` is that opt-out with a name on it.
const UNSCREENED = { screen: null };

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
  // Hand-written on disk, bypassing admitRecipe. Post tgw5 the READ path
  // (foldLedger) re-admits what the write path admits, so these rows are now
  // REJECTED at the fold (VALUE-STORED / UNKNOWN-FIELD) and never reach an
  // entry — and leads is a filter over entries[], so it surfaces nothing. That
  // is the FIRST of two layers: even if a value row reached entries[],
  // foldLedger's twelve-field projection allowlist would still drop it (that
  // second layer is pinned in ledger.test.mjs's projection-guarantee test).
  const dir = tempStore([
    { ...row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex"), value: 544 },
    { ...row("api/lib/y.ex", "wc:-l", "wc -l api/lib/y.ex"), observed_value: "42 modules", answer: "yes" },
  ]);
  const folded = foldLedger(dir);
  assert.equal(folded.entries.length, 0, "forged rows are rejected at the fold, not folded with the value merely stripped");
  assert.ok(folded.unreadable.some((u) => u.reason === "VALUE-STORED"), "the value carrier is named VALUE-STORED, into unreadable[]");

  const result = selectLeads(folded, "api/lib");
  assert.equal(result.rows.length, 0, "no entry means no lead — the forged value cannot reach the screen");
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

test("the rerun substring narrows a multi-row bucket UNDER --cmd — real numbers, before and after", () => {
  const bucket = [
    row("internal/cli", "go:test", "go test ./internal/cli/"),
    row("internal/cli", "go:vet", "go vet ./internal/cli/"),
    row("internal/cli", "go:build", "go build ./internal/cli/"),
    row("internal/cli", "grep:-c", "grep -c 'func ' internal/cli/task_cmd.go"),
    row("internal/cli", "grep:-n", "grep -n 'bp task' internal/cli/task_cmd.go"),
    row("internal/cli", "wc:-l", "wc -l internal/cli/task_cmd.go"),
  ];
  const folded = foldLedger(tempStore(bucket), UNSCREENED);
  const cmd = { cmd: true };
  const all = selectLeads(folded, "internal/cli");
  const narrowed = selectLeads(folded, "grep", cmd);
  assert.equal(all.rows.length, 6, "the unfiltered bucket — the SUBJECT matches all six, no flag needed");
  assert.equal(narrowed.rows.length, 2, "the same bucket narrowed by the rerun substring `grep`");
  assert.equal(selectLeads(folded, "go vet", cmd).rows.length, 1, "narrower still");
  // …and the substring is honestly DUMB: `go` matches every row here, because
  // five of the six commands name a `.go` path. The filter is a substring and
  // nothing more; a reader who expects token matching would misread this count,
  // so it is asserted rather than left to be discovered.
  assert.equal(selectLeads(folded, "go", cmd).rows.length, 6);

  // AND THE SAME THREE QUERIES ANSWER 0 BY DEFAULT, because none of them is
  // about the subject `internal/cli` — they are about the command text. That is
  // the whole point of the mode split, asserted on the same corpus.
  for (const q of ["grep", "go vet", "go"]) {
    assert.equal(selectLeads(folded, q).rows.length, 0, `\`${q}\` is a command-text query, not a subject query`);
  }
});

test("THE FILTER IS CASE-INSENSITIVE — the measured `completion` specimen, with a case-SENSITIVE mutant that must return 0", () => {
  // The measured defect verbatim: this command lives in a real bucket, and a
  // case-sensitive filter answers 0 for "completion" — a FALSE honest empty,
  // which against this epic's bar is worse than no filter at all.
  const specimen = "go test -run TestCompletionNounsCoverAllDispatchedBuiltins ./internal/cli/";
  const folded = foldLedger(tempStore([row("internal/cli", "go:test", specimen)]));

  // `completion` is a COMMAND-TEXT query (the subject is `internal/cli`), so it
  // is asked under --cmd — the case-folding is what is under test here, not the
  // haystack width.
  const shipped = selectLeads(folded, "completion", { cmd: true });
  assert.equal(shipped.rows.length, 1, "the shipped filter folds case and finds it");
  assert.equal(shipped.rows[0].rerun, specimen);

  // THE FAIL-FIRST HALF. Same corpus, same query, one behaviour changed.
  const caseSensitive = folded.entries.flatMap((e) => e.recipes.filter((r) => `${e.subject} ${r.rerun}`.includes("completion")));
  assert.equal(caseSensitive.length, 0, "a case-sensitive implementation answers 0 — this is what the shipped filter must beat");

  // …and the matcher itself, at the unit, in both directions and both modes.
  assert.equal(matchesQuery({ subject: "internal/cli" }, { rerun: specimen }, "completion", { cmd: true }), true);
  assert.equal(matchesQuery({ subject: "INTERNAL/CLI" }, { rerun: "" }, "internal/cli"), true, "the SUBJECT folds case with no flag at all");
  assert.equal(matchesQuery({ subject: "internal/cli" }, { rerun: specimen }, "", { cmd: true }), false, "an empty needle matches nothing, never everything");
});

// ── 2b. THE SUBJECT IS THE DEFAULT HAYSTACK; --cmd IS THE OPT-IN ─────────────
//
// The measured defect this section exists for: the haystack used to be
// subject+rerun unconditionally, so `leads origin/main` returned 51 of the real
// store's 62 recipes (82%) with ZERO subject matches — D45's `cmd:<head>`
// dumping ground reappearing through the RERUN half of the haystack.

test("matchesQuery matches the SUBJECT ALONE by default — the command text is not searched without --cmd", () => {
  const entry = { subject: "tooling/grip/leads.mjs" };
  const recipe = { rerun: "git show origin/main:tooling/grip/leads.mjs | wc -l" };

  // The subject half: identical in both modes.
  assert.equal(matchesQuery(entry, recipe, "tooling/grip"), true);
  assert.equal(matchesQuery(entry, recipe, "tooling/grip", { cmd: true }), true);

  // The command half: ONLY under --cmd. This one assertion is the whole slice.
  assert.equal(matchesQuery(entry, recipe, "origin/main"), false, "the command text is NOT the subject");
  assert.equal(matchesQuery(entry, recipe, "origin/main", { cmd: true }), true, "…and --cmd puts it back");

  // A missing options object, an empty one and an explicit false are the same
  // mode — the default must not depend on how the caller spelled it.
  for (const opts of [undefined, {}, { cmd: false }]) {
    assert.equal(matchesQuery(entry, recipe, "origin/main", opts), false);
  }
});

test("THE MEASURED SPECIMEN — `origin/main` returns ZERO by default, and --cmd returns every one of them", () => {
  // Four recipes shaped exactly like the real store's: repo paths as subjects,
  // `origin/main` living only in the command text.
  const folded = foldLedger(tempStore([
    row("tooling/grip/leads.mjs", "wc:-l", "git show origin/main:tooling/grip/leads.mjs | wc -l"),
    row("api/lib/barkpark.ex", "wc:-l", "git show origin/main:api/lib/barkpark.ex | wc -l"),
    row("internal/cli", "grep:-c", "git grep -c 'func ' origin/main -- internal/cli"),
    row("js/packages/core", "ls-tree", "git ls-tree origin/main js/packages/core"),
  ]), UNSCREENED);

  // FAIL-FIRST: the OLD concatenated haystack, re-implemented here, over the
  // same corpus. It returns all four — that is the behaviour being fixed, and
  // without this half the assertion below would pass against a filter that
  // simply found nothing.
  const oldHaystack = folded.entries.flatMap((e) => e.recipes.filter(
    (r) => `${e.subject}${r.rerun}`.toLowerCase().includes("origin/main"),
  ));
  assert.equal(oldHaystack.length, 4, "precondition: the concatenated haystack returns the whole corpus");

  const shipped = selectLeads(folded, "origin/main");
  assert.equal(shipped.rows.length, 0, "the shipped default returns ZERO — none of these subjects is origin/main");
  assert.equal(shipped.match_mode, "subject");
  assert.equal(shipped.cmd_only_recipes, 4, "…and it knows exactly how many it did not return");

  const wide = selectLeads(folded, "origin/main", { cmd: true });
  assert.equal(wide.rows.length, 4, "--cmd restores the previous behaviour");
  assert.equal(wide.match_mode, "subject+command");
  assert.deepEqual(
    wide.rows.map((r) => r.rerun).sort(),
    oldHaystack.map((r) => r.rerun).sort(),
    "--cmd returns EXACTLY the old concatenated-haystack result, row for row",
  );
});

test("THE HONEST EMPTY CARRIES THE NUMBER — how many --cmd would return, and the flag's name", () => {
  const folded = foldLedger(tempStore([
    row("tooling/grip/leads.mjs", "wc:-l", "git show origin/main:tooling/grip/leads.mjs | wc -l"),
    row("api/lib/barkpark.ex", "wc:-l", "git show origin/main:api/lib/barkpark.ex | wc -l"),
    row("internal/cli", "grep:-c", "git grep -c 'func ' origin/main -- internal/cli"),
  ]), UNSCREENED);
  const rendered = renderLeads(selectLeads(folded, "origin/main"));

  assert.ok(rendered.includes("HONEST EMPTY"), "still an ANSWER, not a blank");
  assert.ok(
    rendered.includes("3 indexed recipe(s) carry that substring in their RERUN COMMAND rather than in a subject."),
    rendered,
  );
  assert.ok(rendered.includes("`--cmd` widens the search"), "the flag is NAMED, not hinted at");
  // The count is what makes this a precision fix rather than a recall cut: an
  // exclusion nobody can count is indistinguishable from an empty store.
  assert.match(rendered, /^  \d+ indexed recipe\(s\) carry that substring/m, "a NUMBER, never a vague quantifier");
  for (const vague of ["some indexed recipe", "several recipes", "a number of recipes"]) {
    assert.ok(!rendered.includes(vague), `must not hedge the count: ${vague}`);
  }
});

test("the honest empty says `--cmd` returns 0 TOO when it would — an empty for the whole store, not for one mode", () => {
  const folded = foldLedger(tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]));
  const result = selectLeads(folded, "no-such-needle-anywhere");
  assert.equal(result.cmd_only_recipes, 0);
  const rendered = renderLeads(result);
  assert.ok(rendered.includes("No indexed recipe carries it in its RERUN COMMAND either, so `--cmd` returns 0 as well"), rendered);
  assert.ok(rendered.includes("this empty is the whole store's answer, not one mode's"));
});

test("the empty state is a STATEMENT, never an exhortation to widen and re-run until the number improves", () => {
  const folded = foldLedger(tempStore([
    row("tooling/grip/leads.mjs", "wc:-l", "git show origin/main:tooling/grip/leads.mjs | wc -l"),
  ]));
  const rendered = renderLeads(selectLeads(folded, "origin/main"));
  // Shopping for a bigger number is the exact failure this epic exists to
  // abolish, so the empty may state what --cmd WOULD return and must not
  // suggest going and getting it.
  for (const nudge of [
    /try again/i, /keep trying/i, /you (may|might|should|could) want/i,
    /consider (adding|widening|using)/i, /did you mean/i, /no results\?/i,
    /re-?run (this|the|your) (search|query|lookup) with/i, /broaden/i, /instead, use/i,
  ]) {
    assert.ok(!nudge.test(rendered), `the empty must not nudge: ${nudge}`);
  }
});

test("THE MATCHING RULE IS PRINTED VERBATIM ON EVERY RENDER (charter D44) — hits and empty alike", () => {
  // One sentence. A reader who has to infer the rule from the results cannot
  // judge whether an empty was honest.
  assert.equal(MATCH_RULE.split(". ").length, 1, "the rule is ONE sentence");
  assert.ok(MATCH_RULE.includes("SUBJECT") && MATCH_RULE.includes("--cmd") && MATCH_RULE.includes("RERUN COMMAND"));

  const folded = foldLedger(tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]));
  assert.ok(renderLeads(selectLeads(folded, "api")).includes(MATCH_RULE), "on a hit");
  assert.ok(renderLeads(selectLeads(folded, "zzz")).includes(MATCH_RULE), "and on the empty");
  // The header states which haystack actually ran, so two runs are diffable.
  assert.match(renderLeads(selectLeads(folded, "api")), /case-insensitive, over the SUBJECT\)/);
  assert.match(renderLeads(selectLeads(folded, "api", { cmd: true })), /over the SUBJECT and the RERUN COMMAND \(--cmd\)/);
});

test("the hit list states how many rows came from command text, in BOTH modes", () => {
  const folded = foldLedger(tempStore([
    row("tooling/grip/leads.mjs", "wc:-l", "wc -l tooling/grip/leads.mjs"),
    row("api/lib/x.ex", "wc:-l", "git show origin/main:api/lib/x.ex | wc -l"),
  ]));
  // Default mode, one subject hit: the OTHER row is one flag away, and the
  // reader is told so with a number rather than left to wonder. `tooling` is a
  // LEADING path-segment prefix of `tooling/grip/leads.mjs` (D91) — `grip` alone
  // would NOT match it, because `grip` is a middle segment there.
  const narrow = renderLeads(selectLeads(folded, "tooling"));
  assert.ok(narrow.includes("tooling/grip/leads.mjs"), narrow);
  const wideResult = selectLeads(folded, "origin/main", { cmd: true });
  assert.equal(wideResult.rows.length, 1);
  assert.ok(
    renderLeads(wideResult).includes("1 of these 1 recipes matched on RERUN COMMAND TEXT, not on the subject (--cmd is on)"),
    renderLeads(wideResult),
  );
});

test("SUBSYSTEM-BOUNDARY MATCHING closes the `leads js` noise (charter D91) — segment prefix, not substring", () => {
  // FAIL-BEFORE / PASS-AFTER of the live 25-of-30 defect, on the same corpus
  // shape that produced it. Before D91, `leads js` matched all three by raw
  // substring: `.mjs` ENDS in "js" and `package.json` CONTAINS it via ".json".
  // After D91 the needle is compared to path SEGMENTS, so only the subject that
  // actually sits UNDER js/ matches.
  const folded = foldLedger(tempStore([
    row("js/packages/core/package.json", "wc:-l", "wc -l js/packages/core/package.json"),
    row("tooling/grip/leads.mjs", "wc:-l", "wc -l tooling/grip/leads.mjs"),
    row("web/package.json", "wc:-l", "wc -l web/package.json"),
    row(".claude/workflows/x.workflow.js", "wc:-l", "wc -l .claude/workflows/x.workflow.js"),
  ]));

  // FAIL-FIRST: the OLD raw-substring subject filter, re-implemented over the
  // same corpus. It returns all four — the noise D91 abolishes — and without
  // this half the assertion below would pass against a filter that found nothing.
  const oldSubstring = folded.entries.flatMap((e) => e.recipes.filter(
    () => e.subject.toLowerCase().includes("js"),
  ));
  assert.equal(oldSubstring.length, 4, "precondition: raw substring matches all four (the defect)");

  const result = selectLeads(folded, "js");
  assert.equal(result.rows.length, 1, "only the subject UNDER js/ survives the segment rule");
  assert.equal(result.rows[0].subject, "js/packages/core/package.json");
  // The 3 noise rows do not vanish silently: their COMMANDS literally contain
  // the string "js" (`wc -l web/package.json`), so they are demoted to
  // command-text-only matches — counted honestly, surfaced only under --cmd,
  // never in the default subject view. That is the precision fix: the subject
  // index is clean, the recall is behind a named, counted flag.
  assert.equal(result.cmd_only_recipes, 3, "the noise is command-text-only now, not a subject match");
  assert.equal(selectLeads(folded, "js", { cmd: true }).rows.length, 4, "--cmd restores the wide substring behaviour");

  // The three noise mechanisms, each pinned at the unit so none can regrow:
  assert.equal(subjectSegmentMatch("js/packages/core/package.json", "js"), true, "leading segment prefix matches");
  assert.equal(subjectSegmentMatch("web/package.json", "js"), false, "`json` must NOT match `js` via substring");
  assert.equal(subjectSegmentMatch(".claude/workflows/x.workflow.js", "js"), false, "a file extension must NOT match a segment query");
  assert.equal(subjectSegmentMatch("js/x", "js"), true);
  assert.equal(subjectSegmentMatch("js", "js"), true, "an exact whole-subject match is a match");
  assert.equal(subjectSegmentMatch("jscramble/x", "js"), false, "a segment that merely STARTS with the needle is not a segment match");
});

test("under --cmd a needle cannot match ACROSS the subject/rerun boundary and invent a hit", () => {
  // Joined by NUL, the one byte a typed query cannot carry. Without a separator
  // that cannot be typed, "internal/cliwc" would match `internal/cli` + `wc -l …`
  // — a hit assembled out of two strings that never touched. The join survives
  // the mode split: it is the OPT-IN mode's haystack, and its reasoning is
  // unchanged.
  const entry = { subject: "internal/cli" };
  const recipe = { rerun: "wc -l internal/cli/x.go" };
  assert.equal(matchesQuery(entry, recipe, "internal/cliwc", { cmd: true }), false);
  assert.equal(matchesQuery(entry, recipe, "internal/cli", { cmd: true }), true);
});

test("the NUL separator is written as the ESCAPE, never as a raw byte (charter D67)", () => {
  // A literal NUL makes git treat the source as binary and stop diffing it, and
  // a read path nobody can review is its own defect. Asserted on the bytes.
  assert.ok(!LEADS_SRC.includes(String.fromCharCode(0)), "leads.mjs must contain no raw NUL byte");
  assert.ok(LEADS_SRC.includes("\\u0000"), "…and the join must still be spelled with the escape");
});

// ── 3. observed_at: three states, no band ────────────────────────────────────

test("state 1 — the RAW observed_at is rendered (--full), and no staleness band is computed from it", () => {
  // observed_at lives in the --full block; the dense default carries only
  // subject/quantity/binding. Either way, no band is ever computed.
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex", { observed_at: "2024-01-02T03:04:05Z" })]);
  const rendered = renderLeads(selectLeads(foldLedger(dir), "api"), { full: true });
  assert.ok(rendered.includes("2024-01-02T03:04:05Z"), "the raw instant, not a band");
  assert.ok(!renderLeads(selectLeads(foldLedger(dir), "api")).includes("2024-01-02T03:04:05Z"), "and the dense default omits it");
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
  const rendered = renderLeads(selectLeads(foldLedger(dir), "api", { census }), { full: true });
  assert.ok(rendered.includes("census STILL-ANSWERING"), rendered);
  assert.ok(!rendered.includes("never re-checked"));
});

test("state 3 — `never re-checked` when no census verdict exists, which is the normal case (census.mjs stores nothing)", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]);
  // No census at all… (the verdict column lives in the --full block)
  assert.ok(renderLeads(selectLeads(foldLedger(dir), "api"), { full: true }).includes("never re-checked"));
  // …and a census that simply does not carry THIS command is the same state,
  // never a silently blank column.
  const census = censusIndex({ rows: [{ command: "wc -l some/other/file.ex", outcome: "STILL-ANSWERING", admissible: true }] });
  assert.ok(renderLeads(selectLeads(foldLedger(dir), "api", { census }), { full: true }).includes("never re-checked"));
});

test("an INADMISSIBLE census verdict says so — it measured this host, not the ledger", () => {
  const rerun = "wc -l api/lib/x.ex";
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", rerun)]);
  const census = censusIndex({ rows: [{ command: rerun, outcome: "WRONG-CWD", decayed: false, admissible: false }] });
  assert.match(renderLeads(selectLeads(foldLedger(dir), "api", { census }), { full: true }), /census WRONG-CWD \(inadmissible/);
});

// ── 4. no ranking, no rival-method flag ──────────────────────────────────────

test("NO RANKING — the order is a deterministic (subject, observed_at desc) sort, stable across two runs", () => {
  const dir = tempStore([
    row("src/b/two.ex", "wc:-l", "wc -l src/b/two.ex", { observed_at: "2026-07-21T03:00:00Z" }),
    row("src/a/one.ex", "wc:-l", "wc -l src/a/one.ex", { observed_at: "2026-07-20T03:00:00Z" }),
    row("src/a/one.ex", "grep:-c", "grep -c x src/a/one.ex", { observed_at: "2026-07-21T03:00:00Z" }),
  ]);
  const folded = foldLedger(dir);
  // `src` is a leading path-segment prefix of all three subjects (D91).
  const once = selectLeads(folded, "src").rows.map((r) => r.rerun);
  const twice = selectLeads(foldLedger(dir), "src").rows.map((r) => r.rerun);
  assert.deepEqual(once, twice, "two runs, identical order");
  assert.deepEqual(once, [
    "grep -c x src/a/one.ex",   // src/a/ first; newest of a/'s two rows first
    "wc -l src/a/one.ex",
    "wc -l src/b/two.ex",
  ]);
  const rendered = renderLeads(selectLeads(folded, "src"));
  for (const banned of ["rank", "Rank", "score", "best match", "top match"]) {
    assert.ok(!rendered.includes(banned), `charter D43 cut the ranking — "${banned}" must not appear`);
  }
});

test("the CLI renders byte-identically across two invocations", () => {
  const dir = tempStore([
    row("src/one.ex", "wc:-l", "wc -l src/one.ex"),
    row("src/one.ex", "grep:-c", "grep -c x src/one.ex"),
  ]);
  const a = runCli(["leads", "src", "--dir", dir]);
  const b = runCli(["leads", "src", "--dir", dir]);
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
  // `/abs/` lives only in one of the two COMMANDS, so it is asked under --cmd.
  const result = selectLeads(foldLedger(dir), "/abs/", { cmd: true });
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
  // `curl` is a command-text query against this subject, so --cmd is how it is
  // reached — the re-derivation under test is unaffected by the haystack width.
  // UNSCREENED for the same reason the arming note above gives: the L1 command
  // that makes this test meaningful (it reaches a running system) is exactly
  // what the screen's host bound refuses, so a screened fold would reject the
  // row before leads ever saw it. The subject here is the LEVEL, not admission.
  const result = selectLeads(foldLedger(dir, UNSCREENED), "curl", { cmd: true });
  assert.equal(result.rows.length, 1);
  assert.equal(result.rows[0].stored_level, "L3", "the stored value is carried, so the disagreement is visible");
  assert.notEqual(result.rows[0].derived_level, "L3", "…and it is NOT what gets rendered as the level");
  assert.equal(result.rows[0].level_restated, true);
  // The level column and its drift marker live in the --full block.
  const rendered = renderLeads(result, { full: true });
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
  // The usage names the DEFAULT haystack and the flag that widens it, so a
  // caller never has to discover the mode split from a surprising row count.
  assert.match(res.stdout, /case-insensitively over the SUBJECT; add --cmd to search the rerun command too/);
  assert.match(res.stdout, /\[--cmd\]/);
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

test("`--cmd` reaches the CLI, and `leads --json` STILL parses with JSON.parse(stdout) in both modes", () => {
  // The regression that bites: --json must stay a lone JSON document on stdout.
  // The new fields are additive, and the flag must not leak into the query.
  const dir = tempStore([
    row("tooling/grip/leads.mjs", "wc:-l", "wc -l tooling/grip/leads.mjs"),
    row("api/lib/x.ex", "wc:-l", "git show origin/main:api/lib/x.ex | wc -l"),
  ]);

  const narrow = runCli(["leads", "origin/main", "--json", "--dir", dir]);
  assert.equal(narrow.status, 0, "an honest empty is still exit 0");
  const narrowParsed = JSON.parse(narrow.stdout);
  assert.equal(narrowParsed.query, "origin/main", "--cmd must not leak into the query string");
  assert.equal(narrowParsed.rows.length, 0);
  assert.equal(narrowParsed.match_mode, "subject");
  assert.equal(narrowParsed.cmd_only_recipes, 1);

  const wide = runCli(["leads", "origin/main", "--cmd", "--json", "--dir", dir]);
  assert.equal(wide.status, 0);
  const wideParsed = JSON.parse(wide.stdout);
  assert.equal(wideParsed.query, "origin/main", "the flag is stripped from the query, not joined into it");
  assert.equal(wideParsed.match_mode, "subject+command");
  assert.equal(wideParsed.rows.length, 1);
  assert.equal(wideParsed.rows[0].rerun, "git show origin/main:api/lib/x.ex | wc -l");
  assert.ok(!Object.hasOwn(wideParsed.rows[0], "value"), "no value, in either mode");

  // Flag ORDER must not matter — `--cmd` before or after the query.
  const flipped = JSON.parse(runCli(["leads", "--cmd", "origin/main", "--json", "--dir", dir]).stdout);
  assert.deepEqual(flipped.rows.map((r) => r.rerun), wideParsed.rows.map((r) => r.rerun));
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

// ── 9. A PARTIALLY-UNREADABLE STORE IS NOT A SMALLER CLEAN ONE ───────────────
//
// `foldLedger` reports every run file and row it could not use in
// `unreadable[]`, and the fold CLI exits 1 on it. A filter that reads only
// `entries[]` inherits the exact defect the fold's own header warns about, one
// layer up: rows that were never READ render as rows that do not EXIST. The
// empty state is where that is most dangerous, because a hidden read failure is
// then indistinguishable from a real absence — D6's rule at the read layer.

test("an unreadable run file is SURFACED, not silently dropped, on hits AND on the empty", () => {
  const dir = tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")]);
  writeFileSync(join(dir, "grip-20260721T000001Z-rotten.json"), "{ this is not json");

  const folded = foldLedger(dir);
  assert.ok(folded.unreadable.length > 0, "precondition: the fold sees the rotten file");

  // On a HIT.
  const hit = selectLeads(folded, "api/lib");
  assert.equal(hit.rows.length, 1);
  assert.equal(hit.unreadable, folded.unreadable.length);
  const hitRender = renderLeads(hit);
  assert.match(hitRender, /PARTIALLY UNREADABLE/, "a hit list over a rotten store must say so");
  assert.match(hitRender, /rotten\.json/, "and must name the file, so it can be re-derived");

  // On the EMPTY — the case that would otherwise read as a confident absence.
  const empty = selectLeads(folded, "nothing-matches-this-needle");
  assert.equal(empty.rows.length, 0);
  const emptyRender = renderLeads(empty);
  assert.match(emptyRender, /PARTIALLY UNREADABLE/);
  assert.ok(
    !emptyRender.includes("This is an answer, not a blank."),
    "an empty over a partially-unread store may NOT claim to be a clean answer",
  );
  assert.match(emptyRender, /this empty is NOT clean/);
});

test("CONTROL: a clean store says nothing about unreadability and keeps the honest-empty wording", () => {
  const clean = selectLeads(foldLedger(tempStore([row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex")])), "zzz-no-match");
  assert.equal(clean.unreadable, 0);
  const rendered = renderLeads(clean);
  assert.ok(!rendered.includes("PARTIALLY UNREADABLE"), "a clean store must not cry wolf");
  assert.match(rendered, /This is an answer, not a blank\./);
});

// ── 10. DENSE by default; --full restores the block (charter D-render) ────────

test("DENSE by default — ONE line per recipe (subject + quantity + binding); --full restores the block", () => {
  const rows = [];
  for (let i = 0; i < 5; i += 1) rows.push(row("internal/cli", `wc:-l:${i}`, `wc -l internal/cli/f${i}.go`));
  const folded = foldLedger(tempStore(rows));
  const result = selectLeads(folded, "internal/cli");
  const dense = renderLeads(result);
  const full = renderLeads(result, { full: true });

  // ONE physical line per recipe, carrying subject + quantity + binding + the
  // re-runnable command — nothing to scroll past.
  const denseRowLines = dense.split("\n").filter((l) => l.includes("$ wc -l internal/cli"));
  assert.equal(denseRowLines.length, 5, "five recipes → five dense lines");
  // the fold re-derives the quantity from the command (D77), so these are five
  // rival methods on one key; the dense line carries subject, quantity, binding.
  assert.match(dense, /internal\/cli\s+wc:-l\s+cwd-bound\s+\$ wc -l internal\/cli\/f0\.go/);
  assert.ok(!dense.includes("2026-07-21T03:46:16Z"), "the dense line omits the observed_at value (block-only)");
  assert.ok(!/level        L\d/.test(dense), "…and the level provenance block");

  // --full is materially taller — a multi-line block per row.
  assert.ok(full.split("\n").length > dense.split("\n").length * 2, `--full block is much taller (${full.split("\n").length} vs ${dense.split("\n").length})`);
  assert.match(full, /observed_at/);
  assert.match(full, /binding      cwd-bound · portable to this cwd/);

  // And the CLI honours --full through argv (leadsCommand strips it from the
  // query, but the render still sees it).
  const denseCli = runCli(["leads", "internal/cli", "--dir", tempStore(rows)]);
  assert.ok(!denseCli.stdout.includes("2026-07-21T03:46:16Z"), "CLI dense default omits the block");
  const fullCli = runCli(["leads", "internal/cli", "--full", "--dir", tempStore(rows)]);
  assert.match(fullCli.stdout, /observed_at  2026-07-21T03:46:16Z/, "CLI --full restores the block");
});

// ── 11. subsystem rollup: ALL-ANCESTOR-PREFIX MATCH-COUNT (charter D87) ───────

test("SUBSYSTEM ROLLUP is ALL-ANCESTOR-PREFIX MATCH-COUNT, not a greedy partition (charter D87)", () => {
  const entries = [
    { subject: "api/lib/a.ex", recipes: [{}] },
    { subject: "api/lib/b.ex", recipes: [{}] },
    { subject: "api/lib/c.ex", recipes: [{}] },
    { subject: "api/test/x.ex", recipes: [{}] },
  ];
  // A recipe under api/lib counts toward BOTH `api` and `api/lib` — the
  // all-ancestor rule. A greedy disjoint partition assigns each recipe to one.
  assert.equal(ancestorPrefixCount(entries, "api"), 4);
  assert.equal(ancestorPrefixCount(entries, "api/lib"), 3);
  assert.equal(ancestorPrefixCount(entries, "api/test"), 1);
  assert.equal(ancestorPrefixCount(entries, "ap"), 0, "matched at a SEGMENT boundary — `ap` never absorbs `api/*`");

  const band = subsystemBand(entries);
  assert.deepEqual(band, ["api", "api/lib"], "`api`(4) and `api/lib`(3) are in [3,20]; `api/test`(1) is below it");
  // OVERLAP is the signature of all-ancestor: the band keys sum to MORE than the
  // 4 recipes, because each nested recipe is counted at every depth. A greedy
  // partition would sum to exactly 4.
  const sum = band.reduce((n, P) => n + ancestorPrefixCount(entries, P), 0);
  assert.equal(sum, 7, "4 + 3 — the overlap a greedy partition (sum 4) cannot produce");
  assert.equal(SUBSYSTEM_BAND.min, 3);
  assert.equal(SUBSYSTEM_BAND.max, 20);
});

test("a key whose all-ancestor count EXCEEDS the band renders the CHILD BREAKDOWN, not a per-recipe dump (D87)", () => {
  const rows = [];
  for (let i = 0; i < 15; i += 1) rows.push(row(`api/lib/f${i}.ex`, "wc:-l", `wc -l api/lib/f${i}.ex`));
  for (let i = 0; i < 10; i += 1) rows.push(row(`api/test/t${i}.ex`, "wc:-l", `wc -l api/test/t${i}.ex`));
  const folded = foldLedger(tempStore(rows));
  const result = selectLeads(folded, "api");
  assert.equal(result.rows.length, 25, "25 recipes match the api subsystem — over the band");

  const rendered = renderLeads(result);
  assert.match(rendered, /api → 25 recipes/, "the rollup names the subsystem and its size");
  assert.match(rendered, /api\/lib\s+15/, "and the child counts");
  assert.match(rendered, /api\/test\s+10/);
  assert.match(rendered, /leads api\/lib/, "it names the narrower query to run");
  assert.equal((rendered.match(/\$ wc -l/g) || []).length, 0, "the breakdown REPLACES the per-recipe dump");

  // childBreakdown at the unit: the child counts use the same all-ancestor rule.
  const bd = childBreakdown(result.rows, "api");
  assert.deepEqual(bd.children.map((c) => [c.path, c.count]), [["api/lib", 15], ["api/test", 10]]);
  assert.equal(bd.exact, 0, "no recipe sits exactly at `api`");

  // A key INSIDE the band (11 recipes, like the live internal/cli) is NOT rolled
  // up — it lists densely.
  const inBand = [];
  for (let i = 0; i < 11; i += 1) inBand.push(row("internal/cli", `q${i}`, `wc -l internal/cli/f${i}.go`));
  const banded = renderLeads(selectLeads(foldLedger(tempStore(inBand)), "internal/cli"));
  assert.ok(!banded.includes("→ 11 recipes — over"), "11 is in-band: no rollup");
  assert.equal((banded.match(/\$ wc -l/g) || []).length, 11, "…it lists all 11 densely");
});

test("the rollup band EXCLUDES cmd:<head> subjects, so the reader's number matches the tool's (charter D45/D87)", () => {
  const withCmd = [
    { subject: "api/lib/a.ex", recipes: [{}] },
    { subject: "api/lib/b.ex", recipes: [{}] },
    { subject: "api/lib/c.ex", recipes: [{}] },
    { subject: "cmd:bp", recipes: [{}, {}, {}, {}] },   // a big dumping ground
    { subject: "cmd:git", recipes: [{}, {}] },
  ];
  const band = subsystemBand(withCmd);
  assert.ok(!band.some((k) => k.startsWith("cmd")), "no cmd:<head> key ever enters the band");
  assert.deepEqual(band, ["api", "api/lib"], "the band is computed over LEADS-INDEXED subjects only");
  // A store of ONLY cmd: subjects yields an empty band, never a `cmd` bucket —
  // exactly so the band count matches what `leads` will actually show.
  assert.deepEqual(subsystemBand([{ subject: "cmd:bp", recipes: [{}, {}, {}, {}, {}] }]), []);
});

// ── 12. per-row binding, imported from binding.mjs (charter D73/D74) ──────────

test("EVERY row declares its binding class, IMPORTED from binding.mjs and never re-derived here", () => {
  // The import itself: a second regex in leads.mjs would be the
  // copy-paste-the-grammar defect this whole epic abolishes.
  assert.ok(/from "\.\/binding\.mjs"/.test(LEADS_SRC), "leads.mjs imports the binding grammar");
  assert.ok(LEADS_SRC.includes("classifyBinding(rerun)"), "…and calls it per recipe, on the command");

  const dir = tempStore([
    row("api/lib/x.ex", "wc:-l", "wc -l api/lib/x.ex"),                        // cwd-bound
    row("api/lib/y.ex", "wc:-l", "git show origin/main:api/lib/y.ex | wc -l"), // shared-ref
  ]);
  const result = selectLeads(foldLedger(dir), "api");
  const byRerun = Object.fromEntries(result.rows.map((r) => [r.rerun, r]));
  assert.equal(byRerun["wc -l api/lib/x.ex"].binding_class, "cwd-bound");
  assert.equal(byRerun["wc -l api/lib/x.ex"].portable_scope, "this cwd");
  assert.equal(byRerun["git show origin/main:api/lib/y.ex | wc -l"].binding_class, "shared-ref");
  assert.equal(byRerun["git show origin/main:api/lib/y.ex | wc -l"].portable_scope, "any worktree of this clone");

  // The dense line carries the class; --json carries class + scope on every row.
  assert.match(renderLeads(result), /api\/lib\/x\.ex\s+wc:-l\s+cwd-bound/);
  const parsed = JSON.parse(runCli(["leads", "api", "--json", "--dir", dir]).stdout);
  assert.ok(
    parsed.rows.every((r) => typeof r.binding_class === "string" && typeof r.portable_scope === "string"),
    "--json carries binding_class + portable_scope per row",
  );
});
