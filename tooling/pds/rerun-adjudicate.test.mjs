#!/usr/bin/env node
// rerun-adjudicate.test.mjs — THE GATE.
//
// A SCRIPT, NOT A `node --test` GLOB, AND THAT IS THE WHOLE POINT. A bare
// `node --test tooling/pds/*.test.mjs` whose file is missing, renamed, or
// unreadable exits 0 and prints a spotless `# fail 0` — grip's own README:193
// documents that trap, and this epic has already watched a green that proved
// nothing get believed. So: this file counts its own checks, prints the count,
// and exits nonzero the moment one fails.
//
// ── ANTI-VACUITY IS THE CENTRAL OBLIGATION HERE ──────────────────────────────
//
// "The tests pass" is not the proof. "The harness REDS when I lie to it" is.
// For EVERY rerun class the instrument ships, section 6 MUTATES THE CLAIM while
// keeping the command BYTE-IDENTICAL and requires a red. That is the only
// experiment that can tell a real binding from a decorative one, and this epic
// has already proven one registry row vacuously green by exactly this method.
//
// Run: node tooling/pds/rerun-adjudicate.test.mjs

import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

import { forbiddenSpelling, FORBIDDEN_NAMES, LEGAL_SUBSTITUTES, SILENT_PREDICATES } from "./spellings.mjs";
import { varianceSet, overClaim, isUnknownVariance, CLAIM_CLASS, AXIS,
         countingSpelling, equalityGrade,
         BEHAVIOUR_HEADS, BEHAVIOUR_HEAD_PROBES, EXECUTOR_UNREACHABLE_BEHAVIOUR_HEADS } from "./variance.mjs";
// READ-ONLY import of grip's shipped screen. The lock in section 10 is only
// worth anything because it asks the LIVE executor, not a copy of its answer.
import { screenCommand } from "../grip/screen.mjs";
import { deriveLevel } from "../grip/level.mjs";
import { bindClaim, deriveTerms, TERM_KEYS } from "./binding.mjs";
import { loadCorpus, liveAdjudicated } from "./corpus.mjs";
import { adjudicateCorpus, estimateMs, toFact, PDS_VERDICT,
         storedRecipe, STORED_CLAIM_CLASS, STORED_ORIGIN, SIDECAR_ORIGIN } from "./adjudicate.mjs";
import { renderVerdict, bannedWordingIn } from "./verdict.mjs";
import { loadRecipes, DEFAULT_CORPUS, REPO_ROOT, main } from "./rerun-adjudicate.mjs";

let checks = 0;
const failures = [];
// The mutation ledger is PRINTED, not merely asserted. A reviewer must be able
// to read what lie was told and what the harness did about it without opening
// this file — "the tests pass" hides exactly that.
const mutationLedger = [];

function ok(label, cond, detail = "") {
  checks++;
  if (!cond) failures.push(`${label}${detail ? ` — ${detail}` : ""}`);
}
function eq(label, actual, expected) {
  ok(label, Object.is(actual, expected), `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

const corpus = loadCorpus(DEFAULT_CORPUS);
const rows = liveAdjudicated(corpus);
const recipes = loadRecipes();
const RUN = { root: REPO_ROOT, budgetMs: 8000 };

// A real shell, used ONLY to re-derive the polarity claims this file makes
// about git's own behaviour. Its exit code is never a verdict about a fact —
// it is the datum the assertions below are about.
function sh(cmd) {
  try {
    const stdout = execFileSync("/bin/sh", ["-c", cmd], { cwd: REPO_ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return { exit: 0, stdout };
  } catch (err) {
    return { exit: err.status ?? -1, stdout: String(err.stdout ?? "") };
  }
}

// ── 1. THE FENCE ─────────────────────────────────────────────────────────────
{
  const gripDiff = sh("git diff --stat origin/main -- tooling/grip/").stdout.trim();
  eq("1.1 zero bytes changed under tooling/grip/", gripDiff, "");
  const scriptsDiff = sh("git diff --stat origin/main -- scripts/").stdout.trim();
  eq("1.2 scripts/pds-ledger-census.sh untouched by this slice", scriptsDiff, "");

  // No module under tooling/pds may reach for grip's command-line entry point:
  // consuming its rc would be this epic's own violation one level up.
  const names = ["adjudicate", "binding", "corpus", "spellings", "variance", "verdict", "rerun-adjudicate"];
  for (const n of names) {
    const src = readFileSync(fileURLToPath(new URL(`./${n}.mjs`, import.meta.url)), "utf8");
    ok(`1.3 ${n}.mjs never names grip's CLI module`, !src.includes("cli.mjs"));
  }
  // process.exit lives in exactly one place, and it is not a verdict path.
  for (const n of ["adjudicate", "binding", "corpus", "spellings", "variance", "verdict"]) {
    const src = readFileSync(fileURLToPath(new URL(`./${n}.mjs`, import.meta.url)), "utf8");
    ok(`1.4 ${n}.mjs contains no process.exit`, !src.includes("process.exit"));
  }
}

// ── 2. THE LIVE-CORPUS BASELINE ──────────────────────────────────────────────
{
  eq("2.1 the corpus is the 172 live adjudicated rows", rows.length, 172);

  // Admission alone, no recipes: this is the board as wave 27 left it.
  const bare = adjudicateCorpus(rows, [], RUN);
  eq("2.2 admission-only PROSE-ONLY count", bare.counts[PDS_VERDICT.PROSE_ONLY], 171);
  eq("2.3 admission-only MALFORMED count", bare.counts[PDS_VERDICT.MALFORMED], 1);
  const malformed = bare.rows.filter((r) => r.verdict === PDS_VERDICT.MALFORMED);
  eq("2.4 the single rejection is the pathless router.ex ref", malformed[0].doc_id, "pds-w11-router-export-comment-drift");
  ok("2.5 and its reason is PATHLESS-REF", malformed[0].reason.includes("PATHLESS-REF"), malformed[0].reason);
  eq("2.6 zero spurious conflicts with subject = pds/<doc_id>", bare.conflicts.length, 0);

  // The subject really is the discriminator: coarsen it and grip fires.
  const coarse = rows.slice(0, 3).map((r) => ({ ...toFact(r), subject: "pds/board" }));
  ok("2.7 a coarsened subject manufactures the CONFLICT the doc_id avoids",
    new Set(coarse.map((f) => f.subject)).size === 1);
}

// ── 3. THE FOUR FORBIDDEN SPELLINGS ──────────────────────────────────────────
{
  const cases = [
    ["GIT-DASH-C", "git -C /tmp show origin/main:README.md"],
    ["GIT-DASH-C", "git -C log push origin main"],
    ["GIT-DASH-C", "git -C/tmp show origin/main:README.md"],
    ["TEST-F", "test -f tooling/pds/adjudicate.mjs"],
    ["COMMAND-SUBSTITUTION", "git rev-list --count origin/main..$(git rev-parse HEAD) | grep -x 0"],
    ["MERGE-BASE-IS-ANCESTOR", "git merge-base --is-ancestor abc123 origin/main"],
  ];
  for (const [name, cmd] of cases) {
    const r = forbiddenSpelling(cmd);
    ok(`3.1 ${name} refused: ${cmd}`, r?.name === name, JSON.stringify(r));
    ok(`3.2 ${name} names a legal substitute`, /git (cat-file|grep|rev-list)/.test(r?.message ?? ""), r?.message);
  }
  eq("3.3 four named rules and no more", FORBIDDEN_NAMES.length, 4);

  // NEVER CRY WOLF. Each legal substitute must pass this layer untouched, or
  // the screen would push honest authors straight back into prose.
  for (const [k, v] of Object.entries(LEGAL_SUBSTITUTES)) {
    ok(`3.4 legal substitute ${k} is not refused`, forbiddenSpelling(v) === null, v);
  }
  // `git show -C` is a diff copy-detection flag, NOT a chdir. Over-refusing it
  // would cost honest reads for nothing.
  ok("3.5 `git show -C` (copy detection) is not swept in", forbiddenSpelling("git show -C origin/main") === null);
}

// ── 3b. THE MIRROR LOCK: ONE COMMITTED SPELLING LIST, TWO SCREENS ────────────
//
// pds-w28-bl-two-rerun-screens-drift. Wave 28 shipped this file AND the Elixir
// write seam (api/lib/barkpark/tasks/stage.ex @forbidden_rerun_shapes) as two
// hand-maintained answers to one question, and nothing re-derived that they
// agreed. They already disagreed on four measured spellings and on the ORDER of
// two arms. The fix is not a third copy of the expectations: it is ONE file,
// fixtures/rerun-spellings.json, that both suites read and assert their own
// column of. The Elixir half is api/test/barkpark/tasks/rerun_spelling_mirror_test.exs.
//
// THE EXTRACTOR REFUSES AN EMPTY READ. A lock that can go quiet is not a lock,
// and this epic has already watched a spotless `# fail 0` prove nothing.
{
  // THE ONE LIST LIVES UNDER api/, ON PURPOSE. scripts/elixir-path-escape-check.sh
  // forbids the Elixir suite from reading a repo-root path elixir.yml does not
  // dispatch on, and tooling/pds/** is not dispatched — a fixture here would be
  // read by an Elixir suite CI never re-runs when it changes. So this gate
  // reaches INTO api/ instead. Still one file; only this direction is guarded.
  const fixturePath = fileURLToPath(new URL("../../api/test/fixtures/rerun-spellings.json", import.meta.url));

  function loadSpellings(path) {
    const raw = readFileSync(path, "utf8"); // throws on a missing fixture
    if (raw.trim() === "") throw new Error(`rerun-spellings.json is EMPTY: ${path}`);
    const data = JSON.parse(raw);
    if (!Array.isArray(data.cases) || data.cases.length === 0) {
      throw new Error("rerun-spellings.json carries no cases — the mirror lock would pass vacuously");
    }
    return data;
  }

  // The anti-vacuity arm, RUN rather than trusted: the loader must throw on
  // exactly the two shapes that would otherwise turn every case below green.
  let refusedEmpty = false;
  let refusedNoCases = false;
  try {
    const tmp = fileURLToPath(new URL("../../api/test/fixtures/.mirror-lock-probe.json", import.meta.url));
    writeFileSync(tmp, "");
    try { loadSpellings(tmp); } catch { refusedEmpty = true; }
    writeFileSync(tmp, '{"cases":[]}');
    try { loadSpellings(tmp); } catch { refusedNoCases = true; }
    unlinkSync(tmp);
  } catch (err) {
    ok("3b.0 anti-vacuity probe ran", false, String(err));
  }
  ok("3b.1 the extractor REFUSES an empty fixture read", refusedEmpty);
  ok("3b.2 the extractor REFUSES a zero-case fixture", refusedNoCases);

  const fx = loadSpellings(fixturePath);
  ok("3b.3 the shared fixture is substantive", fx.cases.length >= 15, `${fx.cases.length} cases`);

  // Column 1: this screen's verdict on every case.
  let drift = 0;
  for (const c of fx.cases) {
    const got = forbiddenSpelling(c.command)?.name ?? null;
    if (got !== c.js) drift++;
    ok(`3b.4 ${JSON.stringify(c.command)} → ${c.js}`, got === c.js,
      `fixture ${c.js}, measured ${got} — ${c.why}`);
  }
  eq("3b.5 zero drift between this screen and the shared list", drift, 0);

  // Column 2: the ORDER. A fixture pinning only the value set is blind to two
  // arms transposed — the admit/refuse verdict is identical, the NAMED remedy
  // is not, and that is precisely how wave 28 shipped.
  ok("3b.6 the fixture's js precedence IS this file's RULES order",
    JSON.stringify(fx.precedence.js) === JSON.stringify([...FORBIDDEN_NAMES]),
    `fixture ${JSON.stringify(fx.precedence.js)} vs shipped ${JSON.stringify([...FORBIDDEN_NAMES])}`);

  const multi = fx.cases.filter((c) => Array.isArray(c.multi_breach));
  ok("3b.7 at least one multi-breach case pins the arm order", multi.length > 0);
  for (const c of multi) {
    // CONTROL: a multi-breach case only tests precedence if the other classes
    // really fire on it. Map each declared elixir class to its js name and
    // require the winner to be the FIRST one in this file's order.
    const names = c.multi_breach.map((k) => fx.class_map[k]).filter(Boolean);
    const first = FORBIDDEN_NAMES.find((n) => names.includes(n));
    const got = forbiddenSpelling(c.command)?.name ?? null;
    ok(`3b.8 ${JSON.stringify(c.command)} reports the first-listed of ${names.join("/")}`,
      got === first, `expected ${first}, got ${got}`);
  }

  // Column 3: every case where the two seams differ carries a WRITTEN reason.
  // A disagreement is allowed; an undocumented one is the original defect.
  for (const c of fx.cases) {
    const mirrored = c.elixir ? fx.class_map[c.elixir] : null;
    const documented = typeof c.divergence === "string" && c.divergence.trim() !== "";
    if (mirrored !== c.js) {
      ok(`3b.9 divergence on ${JSON.stringify(c.command)} is written down`, documented,
        `elixir ${c.elixir} mirrors to ${mirrored}, js ${c.js}, no divergence sentence`);
    } else {
      ok(`3b.10 ${JSON.stringify(c.command)} agrees and claims no divergence`, !documented);
    }
  }
}

// ── 4. VARIANCE-SKIP, NOT STRICT POLARITY ────────────────────────────────────
{
  // PIPE-MASKED-RC, RE-DERIVED FROM THE SHELL RATHER THAN ASSUMED.
  const bareShow = sh("git show origin/main:no/such/path.md");
  const pipedShow = sh("git show origin/main:no/such/path.md | sed -n '1p'");
  eq("4.1 bare `git show` on a missing path exits 128", bareShow.exit, 128);
  eq("4.2 the SAME read piped to `sed -n 1p` exits 0", pipedShow.exit, 0);
  const masked = varianceSet("git show origin/main:no/such/path.md | sed -n '1p'");
  eq("4.3 and the classifier names that shape PIPE-MASKED-RC", masked.masked, "PIPE-MASKED-RC");

  const counted = varianceSet("git grep -n hzResDone origin/main -- internal/cli | wc -l");
  eq("4.4 a `| wc -l` tail is UNCOMPARED-COUNT", counted.masked, "UNCOMPARED-COUNT");
  const ungraded = varianceSet("git rev-list --count origin/main..abc123");
  eq("4.5 an ungraded `--count` is UNCOMPARED-COUNT too", ungraded.masked, "UNCOMPARED-COUNT");

  // The over-claim: content asserted over an existence-only command.
  const showVar = varianceSet("git show origin/main:api/lib/router.ex");
  const over = overClaim(CLAIM_CLASS.CONTENT, showVar);
  eq("4.6 content-over-existence is VARIANCE-SKIP", over?.reason, "VARIANCE-SKIP");
  ok("4.7 and an existence claim over the same command is NOT refused",
    overClaim(CLAIM_CLASS.EXISTENCE, showVar) === null);

  // UNKNOWN DEMOTES, NEVER REJECTS (truth-grip D3).
  const unknown = varianceSet("ls -la tooling/pds");
  ok("4.8 an unclassified command is UNKNOWN", isUnknownVariance(unknown));
  ok("4.9 and UNKNOWN is not an over-claim", overClaim(CLAIM_CLASS.CONTENT, unknown) === null);

  // A strict-polarity screen would refuse the honest majority; this one does not.
  const honest = [
    "git grep -n hzResDone origin/main -- internal/cli",
    "git cat-file -t origin/main:scripts/pds-pull-proof.sh",
    "git rev-list --count origin/main..abc123 | grep -x 0",
  ];
  for (const cmd of honest) {
    ok(`4.10 honest rerun not refused: ${cmd}`, overClaim(CLAIM_CLASS.EXISTENCE, varianceSet(cmd)) === null || overClaim(CLAIM_CLASS.ANCESTRY, varianceSet(cmd)) === null);
  }
}

// ── 5. ABSENCE CLAIMS ARE FIRST-CLASS, AND THE PREDICATES ARE POLARISED ──────
{
  // The absence recipe's command legitimately exits 1 BECAUSE the claim holds.
  //
  // READ FROM THE RECIPE, NEVER RETYPED. Until 2026-09-12 this line carried its
  // own hand-copied spelling of the command, and that is exactly how the drift
  // this section exists to catch stayed invisible: the recipe's command moved
  // out from under the screen (#13481 refused a sub-verb's own `-c`, #17224 then
  // refused the ungraded count) while 5.1 went on probing a string nothing
  // adjudicated. A probe that does not read the artefact cannot witness it.
  const ABSENCE_ID = "pds-bl-export-close-delimited-silent-truncation";
  const absenceRecipe = recipes.find((r) => r.doc_id === ABSENCE_ID);
  ok("5.0 the absence recipe is the one this section probes", Boolean(absenceRecipe), ABSENCE_ID);
  const abs = sh(absenceRecipe.command);
  eq("5.1 the absence rerun exits 1 (a genuine no-match)", abs.exit, 1);
  ok("5.1b and its command carries no ungraded counting stage — the screen would refuse it",
    countingSpelling(absenceRecipe.command) === null, String(countingSpelling(absenceRecipe.command)));
  const exists = sh("git cat-file -t origin/main:internal/cli/export_cmd.go");
  eq("5.2 while the file it reads is present", exists.exit, 0);

  const report = adjudicateCorpus(rows, recipes, RUN);
  const absRow = report.rows.find((r) => r.doc_id === ABSENCE_ID);
  eq("5.3 a nonzero-exit absence is RE-DERIVED, not REFUTED", absRow.verdict, PDS_VERDICT.RE_DERIVED);
  eq("5.4 via grip's admitsAbsenceClaim, not `verdict == ADMITTED`", absRow.reason, "ABSENCE-ADMITTED");

  // Existence predicate, both directions, re-derived from the shell.
  eq("5.5 `git cat-file -t` on a present path exits 0", sh("git cat-file -t origin/main:scripts/pds-pull-proof.sh").exit, 0);
  eq("5.6 and on an absent path exits 128", sh("git cat-file -t origin/main:no/such/file.sh").exit, 128);

  // Ancestry predicate, both directions.
  eq("5.7 ancestry TRUE  (main~1 is an ancestor of main)", sh("git rev-list --count origin/main..origin/main~1 | grep -x 0").exit, 0);
  eq("5.8 ancestry FALSE (main is NOT an ancestor of main~1)", sh("git rev-list --count origin/main~1..origin/main | grep -x 0").exit, 1);

  // The two spellings the brief named are polarised AND silent — and grip's
  // silence rule discards them. Pinned so the advice cannot quietly regress.
  eq("5.9 `git cat-file -e` is polarised at the shell", sh("git cat-file -e origin/main:no/such/file.sh").exit, 128);
  eq("5.10 two silent predicates are named for authors", SILENT_PREDICATES.length, 2);
}

// ── 6. ANTI-VACUITY: MUTATE THE CLAIM, KEEP THE COMMAND BYTE-IDENTICAL ───────
//
// One red per rerun class. In every case below the `command` string is
// UNCHANGED from the shipping recipe; only the claim moves. If the harness
// stayed green, the binding would be decoration and the whole instrument would
// be the vacuous green it was built to end.
{
  const byId = new Map(recipes.map((r) => [r.doc_id, r]));
  const MUTATIONS = [
    ["existence", "pds-bl-harness-not-relocatable",
      (r) => ({ ...r, claim: r.claim.replace("scripts/pds-pull-proof.sh", "scripts/pds-crown-launch.sh") })],
    ["content-token", "pds-bl-hzresdone-registry-row-vacuous",
      (r) => ({ ...r, claim: r.claim.replace("hzResDone", "hzResGone") })],
    ["ancestry", "pds-bl-census-count-true-total-assertion",
      (r) => ({ ...r, claim: r.claim.replace("6e53d27824206c5cbda4eb8916795921064165e9", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef") })],
    ["absence", "pds-bl-export-close-delimited-silent-truncation",
      // replaceAll, not replace: the claim names the token TWICE and a
      // first-occurrence swap leaves the binding intact — the mutation would
      // then prove nothing, which is the failure mode this section exists for.
      (r) => ({ ...r, claim: r.claim.replaceAll("completeness", "ContentLength") })],
    ["behaviour", "pds-bl-go-literal-selftest-false-red-macos",
      (r) => ({ ...r, claim: r.claim.replace("scripts/go-literal-check.sh", "scripts/pds-secret-scan.sh") })],
  ];

  for (const [cls, docId, mutate] of MUTATIONS) {
    const original = byId.get(docId);
    ok(`6.0 ${cls}: a shipping recipe exists for ${docId}`, Boolean(original));
    if (!original) continue;

    const clean = adjudicateCorpus(rows, [original], RUN).rows.find((r) => r.doc_id === docId);
    const mutated = mutate(original);
    eq(`6.1 ${cls}: the command is BYTE-IDENTICAL across the mutation`, mutated.command, original.command);
    ok(`6.2 ${cls}: the claim really changed`, mutated.claim !== original.claim);

    const red = adjudicateCorpus(rows, [mutated], RUN).rows.find((r) => r.doc_id === docId);
    mutationLedger.push({
      cls, docId,
      lie: diffOneTerm(original.claim, mutated.claim),
      clean: `${clean.verdict}/${clean.reason}`,
      red: `${red.verdict}/${red.reason}`,
      command: original.command,
    });
    eq(`6.3 ${cls}: MUTATED CLAIM REDS to REFUSED`, red.verdict, PDS_VERDICT.REFUSED);
    ok(`6.4 ${cls}: and reds with UNBOUND-CLAIM`, red.reason === "UNBOUND-CLAIM", red.reason);
    ok(`6.5 ${cls}: the unmutated recipe does NOT red with UNBOUND-CLAIM`, clean.reason !== "UNBOUND-CLAIM", clean.reason);
  }

  // AND A RED THAT COMES FROM EXECUTION, NOT FROM BINDING. Flip the absence
  // recipe's CLASS to a presence claim, command byte-identical: the command
  // exits 1, so the presence claim is REFUTED by the run itself.
  const absence = byId.get("pds-bl-export-close-delimited-silent-truncation");
  const flipped = { ...absence, claim_class: CLAIM_CLASS.CONTENT };
  eq("6.6 polarity flip keeps the command byte-identical", flipped.command, absence.command);
  const flippedRow = adjudicateCorpus(rows, [flipped], RUN).rows.find((r) => r.doc_id === absence.doc_id);
  mutationLedger.push({
    cls: "absence→presence (polarity flip)", docId: absence.doc_id,
    lie: `claim_class "${absence.claim_class}" → "${flipped.claim_class}"`,
    clean: "RE-DERIVED/ABSENCE-ADMITTED",
    red: `${flippedRow.verdict}/${flippedRow.reason}`,
    command: absence.command,
  });
  eq("6.7 a presence claim over an absence read is REFUTED by EXECUTION", flippedRow.verdict, PDS_VERDICT.REFUTED);
  ok("6.8 and the refutation is not a binding artefact", flippedRow.reason === "PASS-CONTRADICTED", flippedRow.reason);

  // Binding also catches a claim bound to nothing at all.
  const naked = bindClaim({ doc_id: "x", claim_class: "existence", claim: "a file exists", command: "git cat-file -t origin/main:a", terms: {} });
  ok("6.9 a recipe with no terms is MISSING-TERMS", naked.rejections.some((r) => r.reason === "MISSING-TERMS"));
  const bogus = bindClaim({ doc_id: "x", claim_class: "existence", claim: "a file exists", command: "git cat-file -t origin/main:a", terms: { nonsense: "a" } });
  ok("6.10 an unrecognised term key is UNKNOWN-TERM, never silently dropped", bogus.rejections.some((r) => r.reason === "UNKNOWN-TERM"));
}

// ── 7. THE EXECUTION BUDGET REFUSES TO START ─────────────────────────────────
{
  const estimate = estimateMs(recipes.filter((r) => !forbiddenSpelling(r.command)));
  ok("7.1 the estimate is a positive number of ms", estimate > 0, String(estimate));

  const refused = adjudicateCorpus(rows, recipes, { root: REPO_ROOT, budgetMs: estimate - 1 });
  eq("7.2 a budget below the estimate REFUSES TO START", refused.status, "REFUSED-TO-START");
  eq("7.3 and nothing ran", refused.elapsedMs, 0);
  eq("7.4 and no row is reported at all", refused.rows.length, 0);
  ok("7.5 the refusal says it refused rather than truncated", refused.message.includes("Refusing to START"));

  const completed = adjudicateCorpus(rows, recipes, { root: REPO_ROOT, budgetMs: estimate + 10000 });
  eq("7.6 a budget above the estimate COMPLETES", completed.status, "COMPLETE");
  eq("7.7 and every live row is accounted for", completed.rows.length, rows.length);
}

// ── 8. THE VERDICT LINE IS STRICTLY MORE HONEST THAN TODAY'S GREEN ───────────
{
  const report = adjudicateCorpus(rows, recipes, RUN);
  const text = renderVerdict(report, { source: "test" });

  eq("8.1 no banned wording ('these reasons are true' and kin)", bannedWordingIn(text).join(","), "");
  ok("8.2 it states how many carry a rerun and at what level", /carry a rerun command \(\d+ at L\d\)/.test(text), text.slice(0, 400));
  ok("8.3 it states how many re-derived at HEAD", /re-derived at HEAD just now/.test(text));
  ok("8.4 it states how many are REFUTED", /\d+ REFUTED —/.test(text));
  ok("8.5 it names the prose-only remainder rather than summarising it", text.includes("PROSE-ONLY, L6, ASSERTED BY NOBODY"));

  const proseOnly = report.rows.filter((r) => r.verdict === PDS_VERDICT.PROSE_ONLY);
  ok("8.6 and EVERY prose-only row id appears by name", proseOnly.every((r) => text.includes(r.doc_id)), `${proseOnly.length} rows`);
  ok("8.7 the remainder is the bulk of the board, and says so", proseOnly.length > 100, String(proseOnly.length));

  // The four shipping executions land where they should.
  eq("8.8 four rows RE-DERIVED at HEAD", report.counts[PDS_VERDICT.RE_DERIVED], 4);
  eq("8.9 one row REFUSED (the behaviour class, refused at grip's screen)", report.counts[PDS_VERDICT.REFUSED], 1);
  const behaviour = report.rows.find((r) => r.claim_class === "behaviour");
  ok("8.10 the un-re-derivable behaviour class is NAMED, not hidden", behaviour.note.includes("arbitrary script"), behaviour.note);
}

// ── 9. THE CLI RETURNS A VALUE; THE VERDICT NEVER RIDES ON AN rc ─────────────
{
  const report = adjudicateCorpus(rows, recipes, RUN);
  const refuted = report.rows.filter((r) => r.verdict === PDS_VERDICT.REFUTED);
  eq("9.1 the live board carries no REFUTED row today", refuted.length, 0);

  // A REFUTED ruling is READABLE from the structured report while this process's
  // exitCode is untouched — the whole point of importing the engine.
  const before = process.exitCode;
  const flipped = { ...recipes.find((r) => r.claim_class === "absence"), claim_class: CLAIM_CLASS.CONTENT };
  const bad = adjudicateCorpus(rows, [flipped], RUN);
  const badRow = bad.rows.find((r) => r.verdict === PDS_VERDICT.REFUTED);
  ok("9.2 a REFUTED ruling is readable as data", Boolean(badRow), JSON.stringify(bad.counts));
  eq("9.3 and reading it did not touch process.exitCode", process.exitCode, before);
  ok("9.4 the CLI entry point is a function that RETURNS an rc", typeof main === "function");
}

// ── 10. THE ADVERTISED BEHAVIOUR HEADS vs WHAT THE EXECUTOR ALLOWS ───────────
//
// A MIRROR NEEDS A LOCK, NOT TWO HAND-WRITTEN COPIES. variance.mjs advertises
// nine heads as paying for a BEHAVIOUR claim; grip's screen refuses most of
// them. That divergence is fine — the two answer different questions — but it
// is only HONEST while the README says so and says so ACCURATELY. All three
// surfaces are compared here against the live screen, so drift in ANY of them
// (a head added to variance, a head un-refused in grip, a stale README) reds.
{
  // 10.1 the probes really are behaviour commands — otherwise the lock below
  // would pass over a list of harmless greps and prove nothing.
  for (const head of BEHAVIOUR_HEADS) {
    const probe = BEHAVIOUR_HEAD_PROBES[head];
    const v = varianceSet(probe);
    ok(`10.1 ${head}: the probe classifies onto BEHAVIOUR`,
      v.axes.includes(AXIS.BEHAVIOUR), `${probe} → ${JSON.stringify(v.axes)}`);
  }

  // 10.2 MEASURE, do not assume: hand each probe to the live screen.
  const refused = [];
  const admitted = [];
  const reasons = [];
  for (const head of BEHAVIOUR_HEADS) {
    const probe = BEHAVIOUR_HEAD_PROBES[head];
    const screened = screenCommand(probe);
    (screened.ok ? admitted : refused).push(head);
    reasons.push(`      ${screened.ok ? "ADMIT " : "REFUSE"}  ${head.padEnd(8)}$ ${probe}\n                  ${screened.reason}`);
  }
  refused.sort();

  eq("10.2 the measured refused set is exactly variance.mjs's stated limit",
    refused.join(" "), [...EXECUTOR_UNREACHABLE_BEHAVIOUR_HEADS].sort().join(" "));
  ok("10.3 at least one head IS reachable — a lock over an all-refused list is vacuous",
    admitted.length > 0, `admitted: ${JSON.stringify(admitted)}`);

  // 10.4 the README's stated-limit line is the third copy, and it is parsed,
  // never eyeballed. `an absence is never caught by inspection`.
  const readme = readFileSync(fileURLToPath(new URL("./README.md", import.meta.url)), "utf8");
  const m = /<!--\s*pds-stated-limit:\s*executor-unreachable-behaviour-heads\s*=\s*([^>]*?)-->/.exec(readme);
  ok("10.4 README.md carries the pds-stated-limit line", Boolean(m));
  eq("10.5 README's stated limit names exactly the measured refused heads",
    m ? m[1].trim().split(/\s+/).sort().join(" ") : "(absent)",
    refused.join(" "));

  process.stdout.write("\n  EXECUTOR REACHABILITY OF THE ADVERTISED BEHAVIOUR HEADS (live screenCommand)\n");
  for (const line of reasons) process.stdout.write(`${line}\n`);
}

// ── 11. THE ROW'S OWN STORED RERUN IS READ, AND IT IS SCREENED THE SAME WAY ──
//
// WAVE 28 SHIPPED BOTH HALVES OF THIS INSTRUMENT AND NEVER JOINED THEM.
// `bp task stage --rerun` writes `content.disposition_rerun`; corpus.mjs has
// normalised that field off every row since day one; and `toFact()` sourced
// `rerun` from the recipes.json sidecar and NOTHING ELSE. A row carrying a
// stored rerun was therefore reported PROSE-ONLY / NO-RERUN — "asserted by
// nobody" — which is FALSE about that row: somebody asserted it, in the field
// built for it, and the instrument printed the opposite.
//
// This section is the JOIN, and it is proven on REAL ROWS. The shipped 172-row
// snapshot carries ZERO stored reruns, so it can only prove the ABSENCE; the
// three rows that DO carry one were read verbatim off the live board on
// 2026-09-10 into fixtures/stored-rerun-rows-2026-09-10.json.
{
  const bare = adjudicateCorpus(rows, [], RUN);
  eq("11.1 the shipped snapshot carries ZERO stored reruns — the disconnect's baseline",
    bare.storedRerun.rows, 0);
  ok("11.2 and the census PRINTS that zero rather than assuming it",
    /stored rerun\s+0 of 172 row\(s\) carry a stored disposition_rerun/.test(renderVerdict(bare, { source: "test" })),
    renderVerdict(bare, { source: "test" }).split("\n").filter((l) => l.includes("stored rerun")).join(""));

  const stored = liveAdjudicated(loadCorpus(
    fileURLToPath(new URL("./fixtures/stored-rerun-rows-2026-09-10.json", import.meta.url))));
  eq("11.3 the live fixture is the three rows that carry one", stored.length, 3);
  eq("11.4 and the census counts all three", adjudicateCorpus(stored, [], RUN).storedRerun.rows, 3);

  // ── THE BUG, REPRODUCED AND QUOTED, ON A REAL ROW ─────────────────────────
  // Strip the field and you have EXACTLY what origin/main's adjudicator saw.
  const real = stored.find((r) => r.doc_id === "pds-bl-remaining-os-create-sinks");
  const blinded = adjudicateCorpus([{ ...real, disposition_rerun: "" }], [], RUN).rows[0];
  eq("11.5 BEFORE (the field unread): a stored rerun adjudicates PROSE-ONLY", blinded.verdict, PDS_VERDICT.PROSE_ONLY);
  eq("11.6 ...with reason NO-RERUN", blinded.reason, "NO-RERUN");
  ok("11.7 ...and the note says 'asserted by nobody' about a row somebody asserted",
    blinded.note.includes("asserted by nobody"), blinded.note);

  const report = adjudicateCorpus(stored, [], RUN);
  const byId = new Map(report.rows.map((r) => [r.doc_id, r]));
  const pass = byId.get("pds-bl-remaining-os-create-sinks");

  // ── THE PASSING REAL ROW ──────────────────────────────────────────────────
  // $ git grep -n os.Create origin/main -- internal/cli/context_render.go
  // The derived term `os.Create` occurs LITERALLY in the row's own title, the
  // command's rc moves on CONTENT, and it re-derives at HEAD.
  eq("11.8 AFTER: the same real row RE-DERIVES from its own stored rerun", pass.verdict, PDS_VERDICT.RE_DERIVED);
  eq("11.9 and the verdict names the row as its source, not the sidecar", pass.origin, STORED_ORIGIN);
  eq("11.10 the stored rerun's command is the row's, byte for byte", pass.command, real.disposition_rerun);
  eq("11.11 it is levelled by grip exactly like a sidecar recipe",
    pass.level, deriveLevel(real.disposition_rerun));
  eq("11.11b and that level is L3 — a lock over a value nobody pinned proves nothing", pass.level, "L3");
  eq("11.12 at the FLOOR claim class, because no author declared one", pass.claim_class, STORED_CLAIM_CLASS);
  eq("11.13 and the floor is `existence`, never `absence` — polarity is never guessed", STORED_CLAIM_CLASS, "existence");
  ok("11.14 the derived term really is the one bound", deriveTerms(real.disposition_rerun).token === "os.Create",
    JSON.stringify(deriveTerms(real.disposition_rerun)));
  ok("11.15 and it occurs literally in the row's own title — a real binding, not a manufactured one",
    real.title.includes("os.Create"), real.title);

  // ── THE REFUSED REAL ROWS ─────────────────────────────────────────────────
  // Both grep for an expression the row's TITLE never names. That is a genuine
  // UNBOUND-CLAIM: the command may well be about the reason prose, but grip is
  // handed the title as the claim, and this instrument may not silently admit a
  // command bound to a sentence it was never checked against.
  for (const id of ["pds-bl-stray-keys-on-acceptance-criteria", "pds-w12-crown-climb-preconditions"]) {
    const r = byId.get(id);
    eq(`11.16 ${id} is REFUSED, not quietly admitted`, r.verdict, PDS_VERDICT.REFUSED);
    eq(`11.17 ${id} refuses at the BINDING screen`, r.reason, "UNBOUND-CLAIM");
    ok(`11.18 ${id} names the term that failed to bind`,
      r.note.includes("does not occur in the claim prose"), r.note);
  }
  eq("11.19 one of the three real stored reruns re-derives; two refuse — a measured number",
    `${report.counts[PDS_VERDICT.RE_DERIVED] ?? 0}/${report.counts[PDS_VERDICT.REFUSED] ?? 0}`, "1/2");

  // ── EVERY SCREEN A SIDECAR RECIPE FACES, A STORED RERUN FACES TOO ─────────
  // Same real row each time; ONLY the stored command moves.
  const host = rows.find((r) => r.doc_id === "pds-bl-secret-scan-invisible-tables");
  ok("11.20 the screen host is a real snapshot row whose title names a file",
    host.title.includes("pds-secret-scan.sh"), host.title);
  const screened = (command) => adjudicateCorpus([{ ...host, disposition_rerun: command }], [], RUN).rows[0];

  const spelled = screened("git -C /tmp cat-file -t origin/main:scripts/pds-secret-scan.sh");
  eq("11.21 SPELLING screen: a forbidden spelling in a stored rerun is REFUSED", spelled.verdict, PDS_VERDICT.REFUSED);
  eq("11.22 ...by name", spelled.reason, "GIT-DASH-C");

  const counted = screened("git rev-list --count origin/main..HEAD -- scripts/pds-secret-scan.sh");
  eq("11.23 VARIANCE screen: an uncompared count is REFUSED", counted.verdict, PDS_VERDICT.REFUSED);
  eq("11.24 ...by name", counted.reason, "UNCOMPARED-COUNT");

  const skipped = screened("git rev-list --count origin/main..HEAD -- scripts/pds-secret-scan.sh | grep -qx 0");
  eq("11.25 VARIANCE screen: an ANCESTRY rc cannot pay for the floor class", skipped.verdict, PDS_VERDICT.REFUSED);
  eq("11.26 ...by name", skipped.reason, "VARIANCE-SKIP");

  const untermed = screened("bash scripts/pds-secret-scan.sh --selftest");
  eq("11.27 FAIL-CLOSED: a command whose subject cannot be named is REFUSED", untermed.verdict, PDS_VERDICT.REFUSED);
  eq("11.28 ...by name, never silently admitted unbound", untermed.reason, "MISSING-TERMS");

  const admitted = screened("git cat-file -t origin/main:scripts/pds-secret-scan.sh");
  eq("11.29 and a stored rerun that PASSES all three screens re-derives", admitted.verdict, PDS_VERDICT.RE_DERIVED);
  eq("11.30 ...at the level its command earns",
    admitted.level, deriveLevel("git cat-file -t origin/main:scripts/pds-secret-scan.sh"));
  eq("11.30b ...which is L3", admitted.level, "L3");

  // ── PREFERENCE: THE ROW WINS, THE SIDECAR IS THE EXPLICIT FALLBACK ────────
  const sidecarRow = rows.find((r) => r.doc_id === "pds-bl-harness-not-relocatable");
  const sidecarOnly = adjudicateCorpus([sidecarRow], recipes, RUN);
  eq("11.31 FALLBACK: a row with no stored rerun still uses its recipes.json recipe",
    sidecarOnly.rows[0].origin, SIDECAR_ORIGIN);
  eq("11.32 ...and the census says so", sidecarOnly.storedRerun.fromSidecar, 1);

  const both = adjudicateCorpus(
    [{ ...sidecarRow, disposition_rerun: "git cat-file -t origin/main:scripts/pds-pull-proof.sh" }],
    recipes, RUN);
  eq("11.33 PREFERENCE: when both exist, the ROW's stored rerun is the one adjudicated",
    both.rows[0].origin, STORED_ORIGIN);
  eq("11.34 ...and the shadowed sidecar recipe is reported BY NAME, never silently dropped",
    both.storedRerun.shadowedRecipes.join(","), "pds-bl-harness-not-relocatable");
  ok("11.35 ...and the rendered census names it too",
    renderVerdict(both, { source: "test" }).includes("SHADOWED by the row's own"));

  eq("11.36 storedRecipe() returns null for a row with no stored rerun", storedRecipe(sidecarRow), null);

  process.stdout.write("\n  STORED RERUNS ON THE LIVE BOARD (fixtures/stored-rerun-rows-2026-09-10.json)\n");
  for (const r of report.rows) {
    process.stdout.write(`      ${r.verdict.padEnd(11)} ${r.reason.padEnd(18)} ${r.doc_id}\n`);
    process.stdout.write(`                  $ ${r.command}\n`);
  }
}

// ── 12. A COUNT NOBODY GRADED, AND A NUMBER NOBODY BOUND ─────────────────────
//
// NEW SECTION, ADDED AFTER §11 (task pds-w29-bl-grip-count-uncompared).
//
// THE HOLE, AS WAVE 29'S OWN FIELD REPORT FOUND IT. `variance.mjs` named
// UNCOMPARED-COUNT for exactly two shapes — a `| wc` tail and an ungraded
// `git rev-list --count` — and the `git grep` branch returned
// `axes=[EXISTENCE, CONTENT]` BEFORE any tail rule could fire, so `git grep -c`
// PAID IN FULL for a content-token claim. Meanwhile `TERM_KEYS` had no place
// for a quantity, so the NUMBER in a claim bound to nothing and was structurally
// immune to §6's mutation method.
//
// THE ASYMMETRY WAS THE DAMNING PART: the same population claim spelled
// `| wc -l` was REFUSED and spelled `grep -c` was RUBBER-STAMPED, for the same
// unasserted number. The screen refused the honest author and admitted the other
// one.
//
// EVERY ASSERTION BELOW IS EITHER A PURE CLASSIFICATION OR A REAL EXECUTION AT
// HEAD. The true count is MEASURED from the shell in this process, never typed
// in, so this section cannot go stale into a false green when the tree moves.
{
  const countLedger = [];

  // ── 12.0 THE HOLE, REPRODUCED ON LIVE CODE ───────────────────────────────
  //
  // Not a story about origin/main: the reproduction is run HERE, by declaring
  // the recipe THE WAY ORIGIN/MAIN COULD DECLARE IT — with no `quantity` term,
  // because there was no such term key to declare. The command is byte-identical
  // across the two claims and only the number moves.
  const N = sh("git grep -l hzResDone origin/main -- internal/cli | wc -l | tr -d ' '").stdout.trim();
  ok("12.0 the true count is MEASURED from the shell, not typed into this file", /^\d+$/.test(N) && Number(N) > 0, N);

  const gradedCmd = `git grep -l hzResDone origin/main -- internal/cli | wc -l | tr -d " " | grep -x ${N}`;
  const hostRow = { ...rows[0], doc_id: "pds-w29-count-probe", title: "a synthetic host row for the count screen" };
  const trueClaim = `hzResDone appears in exactly ${N} file(s) under internal/cli in origin/main.`;
  const lieClaim = "hzResDone appears in exactly 9999 file(s) under internal/cli in origin/main.";
  const adjudicate1 = (recipe) =>
    adjudicateCorpus([hostRow], [{ ...recipe, doc_id: hostRow.doc_id }], RUN).rows[0];

  // The origin/main recipe shape: terms WITHOUT a quantity.
  const unbound = { claim_class: CLAIM_CLASS.QUANTITY, terms: { token: "hzResDone" }, command: gradedCmd };
  const beforeTrue = adjudicate1({ ...unbound, claim: trueClaim });
  const beforeLie = adjudicate1({ ...unbound, claim: lieClaim });
  eq("12.1 BEFORE (no quantity term): the command is byte-identical across the two claims",
    beforeTrue.command, beforeLie.command);
  eq("12.2 BEFORE: the TRUE count and the FABRICATED count reach the IDENTICAL verdict",
    `${beforeTrue.verdict}/${beforeTrue.reason}`, `${beforeLie.verdict}/${beforeLie.reason}`);
  eq("12.3 BEFORE: and that identical verdict is the strongest one this instrument has",
    beforeLie.verdict, PDS_VERDICT.RE_DERIVED);
  eq("12.4 BEFORE: quoted — PASS-ADMITTED over a number nobody asserted", beforeLie.reason, "PASS-ADMITTED");
  countLedger.push({
    what: "the number rides free when nothing binds it",
    command: gradedCmd,
    a: `claim says ${N} (true)  → ${beforeTrue.verdict}/${beforeTrue.reason}`,
    b: `claim says 9999 (false) → ${beforeLie.verdict}/${beforeLie.reason}`,
  });

  // AND THE OTHER HALF OF THE HOLE: `-c` was invisible to the classifier.
  // grip's `gitVerb` reads the same verb with and without it, so the git branch
  // returned CONTENT axes and a content-token claim was paid in full.
  const withC = "git grep -c hzResDone origin/main -- internal/cli";
  const withoutC = "git grep -n hzResDone origin/main -- internal/cli";
  eq("12.5 the classifier's own verb split cannot see `-c` — the same verb either way",
    varianceSet(withoutC).axes.join(","), "EXISTENCE,CONTENT");
  ok("12.6 BEFORE: that axis set PAYS IN FULL for a content-token claim",
    overClaim(CLAIM_CLASS.CONTENT, { axes: [AXIS.EXISTENCE, AXIS.CONTENT], masked: null, why: "origin/main's literal return for a `git grep` source" }) === null);

  // THE FILING'S HEADLINE VERDICT IS STALE, AND SAYING SO IS PART OF THE FIX.
  // It reports RE-DERIVED / PASS-ADMITTED for `git grep -c`, measured on
  // origin/main 0f28d541e. RE-MEASURED against origin/main 61f1afcea by running
  // that tree's own adjudicator: `git grep -c …` lands REFUSED /
  // REJECTED:UNSAFE-RERUN, because grip's caller-boundary screen parses the `-c`
  // as git's GLOBAL `-c key=value` flag and refuses ("git -c hzResDone is not a
  // key=value pair"). That is an ACCIDENT in a tree PDS does not own
  // (tooling/grip/**, PDS-D386) and it is not a count screen: the plain-grep
  // spellings of the same act sail straight past it. So the durable half of the
  // finding — the one asserted above and closed below — is that the VARIANCE
  // SCREEN pays in full for a command that asserts no number, whatever the
  // runtime happens to do with it afterwards.

  // ── 12.7 THE RULE: A COUNTING STAGE IS UNCOMPARED UNLESS GRADED ──────────
  //
  // Stated on the ACT, not on a list of spellings — an enumeration is a
  // snapshot and a predicate is a rule, and a two-item list is exactly how
  // `grep -c` walked past this screen for a wave.
  const UNGRADED = [
    ["wc", "git grep -n hzResDone origin/main -- internal/cli | wc -l"],
    ["git grep -c", withC],
    ["grep -c", "grep -c hzResDone internal/cli/hetzner_lb_cmd.go"],
    ["grep -vc", "git grep -n hzResDone origin/main -- internal/cli | grep -vc 'func hzResDone'"],
    ["git rev-list --count", "git rev-list --count origin/main..abc123"],
  ];
  for (const [name, cmd] of UNGRADED) {
    const v = varianceSet(cmd);
    eq(`12.7 ${name}: an ungraded counting stage is UNCOMPARED-COUNT`, v.masked, "UNCOMPARED-COUNT");
    eq(`12.8 ${name}: it pays for NO axis at all`, v.axes.length, 0);
    ok(`12.9 ${name}: and the refusal NAMES ITS SUBSTITUTE rather than only saying no`,
      v.why.includes("SUBSTITUTE:") && v.why.includes("grep -qx"), v.why);
    eq(`12.10 ${name}: the counting act is named by the predicate, not guessed`,
      typeof countingSpelling(cmd.split("|").pop().trim()) === "string" || countingSpelling(cmd.split("|")[0].trim()) !== null, true);
  }

  // AND THE REFUSAL REACHES THE VERDICT, not just the classifier.
  const refusedRow = adjudicate1({ claim_class: CLAIM_CLASS.CONTENT, claim: "hzResDone still occurs under internal/cli", terms: { token: "hzResDone" }, command: withC });
  eq("12.11 END TO END: the `git grep -c` recipe that used to PASS-ADMIT is now REFUSED", refusedRow.verdict, PDS_VERDICT.REFUSED);
  eq("12.12 ...by name", refusedRow.reason, "UNCOMPARED-COUNT");
  ok("12.13 ...and the refusal note carries the substitute an author can act on",
    refusedRow.note.includes("SUBSTITUTE:"), refusedRow.note);
  // AND THE SPELLINGS GRIP'S SCREEN DOES ADMIT — where the hole was live at
  // HEAD, not merely at the filing's commit. RE-MEASURED against origin/main
  // 61f1afcea with that tree's own adjudicator:
  //   grep -c  …                     INCONCLUSIVE / NULL-READ   (a count, admitted)
  //   … | grep -vc 'func hzResDone'  REFUTED / PASS-CONTRADICTED (a TRUE claim
  //                                  called false, off a count nobody graded)
  // Both now refuse by name instead.
  const plainC = adjudicate1({ claim_class: CLAIM_CLASS.CONTENT, claim: "hzResDone still occurs under internal/cli", terms: { token: "hzResDone" }, command: "grep -c hzResDone internal/cli/hetzner_lb_cmd.go" });
  eq("12.13b the plain `grep -c` spelling grip DOES admit is refused at the count screen", plainC.reason, "UNCOMPARED-COUNT");
  const vcRow = adjudicate1({ claim_class: CLAIM_CLASS.CONTENT, claim: "hzResDone still occurs under internal/cli", terms: { token: "hzResDone" }, command: "git grep -n hzResDone origin/main -- internal/cli | grep -vc 'func hzResDone'" });
  eq("12.13c and so is the `grep -vc` tail that used to REFUTE a true claim", vcRow.reason, "UNCOMPARED-COUNT");

  countLedger.push({
    what: "counting shapes for a content claim — every one paid in full at the variance screen",
    command: `${withC}   |   grep -c …   |   … | grep -vc …`,
    a: `BEFORE  overClaim(content-token, [EXISTENCE,CONTENT]) === null  — the screen charged nothing`,
    b: `AFTER   ${refusedRow.reason} / ${plainC.reason} / ${vcRow.reason}`,
  });

  // ── 12.14 NO OVER-REFUSAL: AN HONEST GRADED COUNT STILL RE-DERIVES ───────
  const honest = { claim_class: CLAIM_CLASS.QUANTITY, claim: trueClaim, terms: { token: "hzResDone", quantity: N }, command: gradedCmd };
  const honestRow = adjudicate1(honest);
  eq(`12.14 an equality-graded count (\`| grep -x ${N}\`) still RE-DERIVES`, honestRow.verdict, PDS_VERDICT.RE_DERIVED);
  eq("12.15 ...by execution at HEAD, not by a binding artefact", honestRow.reason, "PASS-ADMITTED");
  eq("12.16 the grade is read as an equality against an integer literal", equalityGrade(`grep -x ${N}`), N);
  ok("12.17 a grade without `-x` is NOT an equality grade — `5` would match `15`",
    equalityGrade("grep -q 5") === null);
  eq("12.18 a graded count pays on the QUANTITY axis and on nothing borrowed",
    varianceSet(gradedCmd).axes.join(","), AXIS.QUANTITY);

  // ── 12.19 THE QUANTITY TERM BINDS, AND THE MUTATION REDS ─────────────────
  ok("12.19 `quantity` is a declarable term key", TERM_KEYS.includes("quantity"));
  const mutated = { ...honest, claim: lieClaim };
  eq("12.20 MUTATION: the command is BYTE-IDENTICAL across the lie", mutated.command, honest.command);
  ok("12.21 ...and only the number moved", mutated.claim !== honest.claim && mutated.claim.includes("9999"));
  const mutatedRow = adjudicate1(mutated);
  eq("12.22 MUTATED NUMBER REDS to REFUSED", mutatedRow.verdict, PDS_VERDICT.REFUSED);
  eq("12.23 ...with UNBOUND-CLAIM — the number is bound to something now", mutatedRow.reason, "UNBOUND-CLAIM");
  ok("12.24 ...and the note names the quantity term that failed to bind",
    mutatedRow.note.includes('term quantity="' + N + '"'), mutatedRow.note);
  ok("12.25 CONTROL: the honest recipe does NOT red with UNBOUND-CLAIM", honestRow.reason !== "UNBOUND-CLAIM", honestRow.reason);
  countLedger.push({
    what: "the same lie, with the quantity term declared",
    command: gradedCmd,
    a: `claim says ${N} (true)  → ${honestRow.verdict}/${honestRow.reason}`,
    b: `claim says 9999 (false) → ${mutatedRow.verdict}/${mutatedRow.reason}   <-- RED`,
  });

  // A number that binds must bind in the COMMAND too, not only in the prose.
  const proseOnlyNumber = bindClaim({ doc_id: "x", claim_class: "quantity", claim: "exactly 50 call sites", command: withC, terms: { quantity: "50" } });
  ok("12.26 a quantity that occurs only in the prose is UNBOUND-CLAIM",
    proseOnlyNumber.rejections.some((r) => r.reason === "UNBOUND-CLAIM"));
  ok("12.27 CONTROL: `quantity` is not rejected as an unrecognised key",
    !proseOnlyNumber.rejections.some((r) => r.reason === "UNKNOWN-TERM"),
    JSON.stringify(proseOnlyNumber.rejections));

  // ── 12.28 THE ASYMMETRY IS CLOSED IN THE REPORTED DIRECTION ──────────────
  //
  // The reported direction is a POPULATION claim spelled two ways. Before this
  // change `wc` was REFUSED and `grep -c` was ADMITTED. Both spellings must now
  // reach the SAME verdict — refused while ungraded, admitted once graded.
  const popClaim = `hzResDone appears in exactly ${N} file(s) under internal/cli in origin/main.`;
  const wcUngraded = "git grep -l hzResDone origin/main -- internal/cli | wc -l";
  const grepCUngraded = "git grep -c hzResDone origin/main -- internal/cli";
  const wcRow = adjudicate1({ claim_class: CLAIM_CLASS.QUANTITY, claim: popClaim, terms: { token: "hzResDone" }, command: wcUngraded });
  const grepCRow = adjudicate1({ claim_class: CLAIM_CLASS.QUANTITY, claim: popClaim, terms: { token: "hzResDone" }, command: grepCUngraded });
  eq("12.28 the `wc` spelling and the `grep -c` spelling of ONE population claim reach the SAME verdict",
    `${wcRow.verdict}/${wcRow.reason}`, `${grepCRow.verdict}/${grepCRow.reason}`);
  eq("12.29 ...and that shared verdict is the refusal, not the rubber stamp", grepCRow.reason, "UNCOMPARED-COUNT");
  countLedger.push({
    what: "the asymmetry, closed",
    command: `${wcUngraded}   vs   ${grepCUngraded}`,
    a: `wc      → ${wcRow.verdict}/${wcRow.reason}`,
    b: `grep -c → ${grepCRow.verdict}/${grepCRow.reason}   (was RE-DERIVED/PASS-ADMITTED)`,
  });

  // Graded, the two spellings agree on the axis as well as on the verdict.
  eq("12.30 graded, both spellings classify onto the SAME axis set",
    varianceSet(`${wcUngraded} | tr -d " " | grep -x ${N}`).axes.join(","),
    varianceSet(`${grepCUngraded} | grep -x ${N}`).axes.join(","));

  // ── 12.31 THE RULE DOES NOT EAT THE REST OF THE TABLE ────────────────────
  // Controls: shapes that carry no counting stage must be untouched by it.
  eq("12.31 CONTROL: a plain `git grep` is still EXISTENCE,CONTENT",
    varianceSet(withoutC).masked, null);
  eq("12.32 CONTROL: a masked pipe is still PIPE-MASKED-RC, not renamed to a count",
    varianceSet("git show origin/main:no/such/path.md | sed -n '1p'").masked, "PIPE-MASKED-RC");
  eq("12.33 CONTROL: a graded `rev-list --count` still pays for ANCESTRY",
    overClaim(CLAIM_CLASS.ANCESTRY, varianceSet("git rev-list --count origin/main..abc123 | grep -x 0")), null);
  ok("12.34 CONTROL: an unclassified command still DEMOTES rather than refusing",
    isUnknownVariance(varianceSet("ls -la tooling/pds")));
  eq("12.35 CONTROL: `git -c user.name=x grep -n tok origin/main` is a global flag, not a count",
    countingSpelling("git -c user.name=x grep -n tok origin/main"), null);
  eq("12.36 CONTROL: `git grep -C 3` is context, not `--count`",
    countingSpelling("git grep -C 3 tok origin/main"), null);

  process.stdout.write("\n  THE COUNT SCREEN — the command held still, the number moved\n");
  for (const e of countLedger) {
    process.stdout.write(`      ${e.what}\n`);
    process.stdout.write(`        $ ${e.command}\n`);
    process.stdout.write(`          ${e.a}\n`);
    process.stdout.write(`          ${e.b}\n`);
  }
}

/** The one term that moved between two claim strings, for the printed ledger. */
function diffOneTerm(before, after) {
  const b = before.split(/\s+/);
  const a = after.split(/\s+/);
  for (let i = 0; i < Math.max(b.length, a.length); i++) {
    if (b[i] !== a[i]) return `"${b[i] ?? "(nothing)"}" → "${a[i] ?? "(nothing)"}"`;
  }
  return "(no textual change)";
}

// ── REPORT ───────────────────────────────────────────────────────────────────
process.stdout.write("\nMUTATION LEDGER — the claim moved, the command did not\n");
for (const m of mutationLedger) {
  process.stdout.write(`  ${m.cls}  ${m.docId}\n`);
  process.stdout.write(`      lie      ${m.lie}\n`);
  process.stdout.write(`      command  $ ${m.command}   (byte-identical in both runs)\n`);
  process.stdout.write(`      honest   ${m.clean}\n`);
  process.stdout.write(`      mutated  ${m.red}   <-- RED\n`);
}

process.stdout.write(`\npds/rerun-adjudicate: ${checks} checks, ${failures.length} failed\n`);
if (failures.length > 0) {
  for (const f of failures) process.stdout.write(`  FAIL  ${f}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write("  all green\n");
}
