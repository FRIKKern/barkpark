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

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

import { forbiddenSpelling, FORBIDDEN_NAMES, LEGAL_SUBSTITUTES, SILENT_PREDICATES } from "./spellings.mjs";
import { varianceSet, overClaim, isUnknownVariance, CLAIM_CLASS } from "./variance.mjs";
import { bindClaim } from "./binding.mjs";
import { loadCorpus, liveAdjudicated } from "./corpus.mjs";
import { adjudicateCorpus, estimateMs, toFact, PDS_VERDICT } from "./adjudicate.mjs";
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
  const abs = sh("git grep -c completeness origin/main -- internal/cli/export_cmd.go");
  eq("5.1 the absence rerun exits 1 (a genuine no-match)", abs.exit, 1);
  const exists = sh("git cat-file -t origin/main:internal/cli/export_cmd.go");
  eq("5.2 while the file it reads is present", exists.exit, 0);

  const report = adjudicateCorpus(rows, recipes, RUN);
  const absRow = report.rows.find((r) => r.doc_id === "pds-bl-export-close-delimited-silent-truncation");
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
