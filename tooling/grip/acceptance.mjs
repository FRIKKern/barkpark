#!/usr/bin/env node
// acceptance.mjs — the ratified level-skip specimens, fired at the REAL adjudicator.
//
//   node tooling/grip/acceptance.mjs           # human report, exit 1 on failure
//   node tooling/grip/acceptance.mjs --json    # machine-readable
//
// WHAT THIS IS FOR. Every other suite in tooling/grip tests a module against
// what its author believed. This one tests the SUBSTRATE against the six real
// wrong answers this project actually produced — the specimens ratified in
// /papers/survey-once-build-forever. It is the only check that can fail because
// the doctrine and the code drifted apart rather than because a function broke.
//
// THE CHECK THIS IS NOT. `harvest.mjs --selftest` validates harvest's OWN
// handling of the `caught_by` field. That is a different check and easy to
// mistake for this one: it proves harvest reads the label correctly, never that
// the label is TRUE. Nothing before this file ever ran a specimen through
// adjudicate.mjs.
//
// ─────────────────────────────────────────────────────────────────────────────
// `caught_by` IS A HYPOTHESIS, AND THIS FILE IS WHERE IT GETS FALSIFIED
// ─────────────────────────────────────────────────────────────────────────────
//
// The fixture says so itself, in `_meta.caught_by_is_a_hypothesis`: "a specimen
// labelled R1 that R1 does not actually catch passes [the fixture gate] and
// fails only in [the acceptance suite]". The fixture's own gate checks its
// STRUCTURE. This one checks its SEMANTICS.
//
// So this file never trusts a label. It computes what adjudicate.mjs ACTUALLY
// does, compares that against the label, and reports every divergence by name.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY THE SPECIMEN'S OWN `rerun` IS NOT THE COMMAND WE ADJUDICATE
// ─────────────────────────────────────────────────────────────────────────────
//
// This is the subtlety that makes a naive version of this file silently
// worthless, so it is stated at length.
//
// Each specimen's `rerun` field is the HONEST COUNTERPART — the command that
// re-derives the fact at the level the claim needed. It is the FIX, not the
// sin. Feeding it to adjudicate models the fact AFTER correction, which is
// admissible by construction. Measured, before this file was written:
// specimens 1, 2 and 3 all come back ADMITTED that way, which reads as "the
// grammar misses three ratified level-skips" and is an artefact of the
// modelling, not a finding.
//
// The SINFUL fact is the one the agent actually produced: read at the level in
// `level_skip`'s "read at Lx" clause, claimed at its "claimed at Ly" clause. To
// adjudicate it we need a command that DERIVES Lx. The specimen rarely carries
// one — the sin was frequently committed with no command at all.
//
// So the read level is modelled with a PROBE command from the table below, and
// the modelling is not taken on faith: every probe is asserted against
// deriveLevel() at startup, and a probe that stops deriving its level fails the
// run under PROBE-DRIFT before a single specimen is judged. The claim being
// tested is therefore exactly R1's: "a fact whose command derives Lx, quoted at
// Ly above Lx, is REJECTED" — with (Lx, Ly) supplied by the ratified specimen.
//
// ─────────────────────────────────────────────────────────────────────────────
// L5 HAS NO PROBE, ON PURPOSE
// ─────────────────────────────────────────────────────────────────────────────
//
// level.mjs:18 — "L5 charters / docs — never derived here". Reading a doc
// locally IS a local file read, so the grammar answers L3 and is right to.
// There is no command that derives L5, so no probe can exist. Specimen 5 is the
// only one that reads at L5 and its own prose already writes this as "L5/L3";
// the L3 reading is used, and RECORDED as a modelling note rather than passed
// over.
//
// Pure and hermetic: `execute: false` throughout. Nothing here touches the
// network, the box, or the clock. A specimen's rerun is never run — several of
// them ssh to production.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE SPECIMEN'S OWN `rerun` IS SCREENED, NEVER RUN (charter D116)
// ─────────────────────────────────────────────────────────────────────────────
//
// The paragraphs above explain why the specimen's `rerun` is not the command we
// ADJUDICATE. It is still an artefact worth pinning, and there is exactly one
// safe way to pin it: put it through `screenCommand` and freeze the `{ok,
// reason}` it comes back with.
//
// The tempting alternative — "put every specimen's rerun through `runRerun`" —
// wears the vocabulary of safety while removing the refusal. `runRerun` does
// NOT gate on `screenCommand`; its step 1 is `classifySafety` (rerun.mjs:676),
// which returns `{safe: true, reason: "no write shape detected"}` for ALL SIX
// ratified specimens — including specimen 1's `ssh … root@157.180.90.121` and
// specimen 6's arbitrary-JS `node`. adjudicate.mjs:90-96 calls that path, left
// to itself, "a default-on RCE". Implementing it literally would ssh to
// production from the acceptance suite.
//
// `screenCommand` refuses three of the six, and THE REFUSALS ARE THE ASSERTION.
// screen.mjs has zero imports and executes nothing, so `execute: false`
// hermeticity (stated at :69-71) survives intact, and the fixture becomes a
// screen-DRIFT tripwire nothing else in the repo asserts.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { adjudicate, VERDICTS } from "./adjudicate.mjs";
import { deriveLevel } from "./level.mjs";
// PURE — screen.mjs has zero imports and runs nothing. Screening a command is a
// string judgement, not an execution.
import { screenCommand } from "./screen.mjs";
// Used ONLY inside the isMain block below, and only against stderr (D78).
import { emitProvenance } from "./provenance.mjs";

const FIXTURE = fileURLToPath(new URL("./fixtures/level-skip-specimens.json", import.meta.url));

// ── the read-level probes ────────────────────────────────────────────────────
//
// One command per derivable level. Each is verified against deriveLevel before
// use, so this table cannot rot into a set of assumptions.
const READ_LEVEL_PROBES = Object.freeze({
  L1: "ssh -o BatchMode=yes -i ~/.ssh/barkpark_indx root@157.180.90.121 'cat /etc/hostname'",
  L2: "git show origin/main:README.md",
  L3: "git rev-parse --short HEAD",
  L4: "cat docs/openapi.json",
  // L5: none exists — see the header.
  L6: "", // no command at all; the grammar's own definition of L6
});

// Levels the grammar cannot derive, with the reason. A specimen reading at one
// of these is remapped to the level the grammar DOES answer, and the remap is
// reported, never silent.
const UNDERIVABLE = Object.freeze({
  L5: {
    fallback: "L3",
    why: "level.mjs:18 — L5 (charters/docs) is never derived; reading a doc locally is a local file read and answers L3",
  },
});

// ── the expected adjudication, per specimen ──────────────────────────────────
//
// The precise verdict and reason set adjudicate.mjs must produce for each
// sinful fact. This is the falsifiable core: any change in the adjudicator's
// behaviour against a ratified specimen turns this file red by name.
//
// NOTE these are expectations about THE ADJUDICATOR, derived by running it —
// not restatements of the fixture's labels. Where the two disagree, the
// disagreement is declared below and reported as a FINDING.
const EXPECTED = Object.freeze({
  1: { verdict: VERDICTS.REJECTED, reasons: ["LEVEL-SKIP"] },
  2: { verdict: VERDICTS.REJECTED, reasons: ["LEVEL-SKIP"] },
  3: { verdict: VERDICTS.REJECTED, reasons: ["LEVEL-SKIP"] },
  4: { verdict: VERDICTS.ADMITTED, reasons: [] },
  5: { verdict: VERDICTS.REJECTED, reasons: ["LEVEL-SKIP"] },
  6: { verdict: VERDICTS.REJECTED, reasons: ["LEVEL-SKIP"] },
});

// ── the frozen SCREEN of each specimen's own rerun ───────────────────────────
//
// One row per ratified specimen: exactly what `screenCommand(specimen.rerun)`
// answers, `{ok, reason}`, VERBATIM. The reason strings are the tripwire — an
// `ok: false` frozen without its reason would stay green through a screen that
// started refusing the same command for an entirely different rule.
//
// THE THREE REFUSALS ARE NOT ONE CLASS, and collapsing them under a single
// "refused" label would throw away the distinction this table exists to hold:
//
//   * specimens 1 and 4 are HOST-BOUND refusals — the command leaves this box
//     (`ssh`, `barkpark.cloud`). The bound is about WHERE it would run.
//   * specimen 6 is a HEAD-ALLOWLIST refusal — `node` is not an allowlisted
//     head at all (screen.mjs:1096, "node executes arbitrary JavaScript
//     (including fs writes)"). The bound is about WHAT it would run, and it
//     holds even for a command that never leaves the loopback.
//
// That second rule is also this slice's own evidence ceiling: every command in
// this file's gate starts with `node`, so grip refuses to screen its own
// execution and the facts here are L3 with no L2 route (D96).
const SCREEN_EXPECTED = Object.freeze({
  1: { ok: false, reason: "host bound: names ssh (remote execution)" },
  2: { ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" },
  3: { ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" },
  4: { ok: false, reason: "host bound: names barkpark.cloud" },
  5: { ok: true, reason: "admitted: within the host bound, allowlisted head and sub-verb, no write shape" },
  6: { ok: false, reason: "not allowlisted: node executes arbitrary JavaScript (including fs writes)" },
});

// ── declared divergences between the fixture's label and measured reality ────
//
// A divergence is a REAL FINDING about the fixture, not a test to be relaxed.
// Declaring it keeps the suite green on a known, documented gap while any NEW
// divergence fails the run — the fixture's labels stay under test, and the
// known gap stays visible in every report instead of decaying into folklore.
//
// Each entry must be paid off by a filed task, named here.
//
// EMPTY IS THE HONEST STATE, AND IT IS NOT THE SAME AS DISARMED. The one entry
// this table ever held was specimen 5's `labelled R3 / actually R1`. That is
// paid off: the fixture's label now names the rule that actually fires
// (LEVEL-SKIP, R1), the R3 content is kept there as an OBSERVATION rather than
// as a catch, and the R3 gap it stood for is recorded in the fixture's own
// `_meta.r3_has_no_check_on_the_fact_path` and given a standing negative
// control in specimen 103 — an R3 violation with HONEST levels, which R1
// structurally cannot reach and the adjudicator therefore ADMITS.
//
// So nothing is silenced here any more, and the silencer still bites: the
// module-scope shape guard below is proven fatal against a SYNTHETIC entry
// inserted into this empty table, and relabelling specimen 5 back to R3 now
// fails the run under UNDECLARED-DIVERGENCE. Both are asserted in
// test/acceptance.test.mjs. An empty escape hatch whose guard cannot be shown
// to fire would be the vacuous control this module exists to refuse.
const DECLARED_DIVERGENCES = Object.freeze({});

// THE ESCAPE HATCH HAS TO COST SOMETHING (added in review).
//
// "Each entry must be paid off by a filed task, named here" was a COMMENT, and
// nothing read it. An entry with `filed_as: ""`, a typo'd key, or no task at all
// silenced a divergence just as well as an honest one — a guard whose only
// enforcement is the prose above it. This module's own thesis is that a control
// which cannot fire is not a control, so the shape is checked at module scope
// and the failure is FATAL on import, exactly like PROBE-DRIFT: a malformed
// declaration must never be discovered by reading a report that says PASS.
//
// It still cannot prove the task EXISTS — that needs the network, and this
// module is hermetic by design. It proves the declaration was WRITTEN as a
// payoff rather than as a shrug, which is the half a local check can hold.
const TASK_SLUG = /^[a-z][a-z0-9-]{6,}$/;
for (const [id, d] of Object.entries(DECLARED_DIVERGENCES)) {
  const bad = (what) => {
    throw new Error(
      `DECLARED_DIVERGENCES[${id}] is malformed: ${what}. A declaration silences a real ` +
      "finding, so it must name the label, what actually fires, why, and the task that pays " +
      "it off. Fix the declaration or delete it and let the divergence fail the run.",
    );
  };
  for (const key of ["labelled", "actually", "finding", "filed_as"]) {
    if (typeof d?.[key] !== "string" || d[key].trim() === "") bad(`\`${key}\` is missing or empty`);
  }
  if (d.labelled === d.actually) bad("`labelled` equals `actually` — that is not a divergence");
  if (!TASK_SLUG.test(d.filed_as)) bad(`\`filed_as\` (${JSON.stringify(d.filed_as)}) is not a task slug`);
  if (d.finding.trim().length < 80) bad("`finding` is too short to be an explanation");
}

// ─────────────────────────────────────────────────────────────────────────────

/** The "read at Lx" / "claimed at Ly" clauses, from the specimen's own prose. */
export function parseLevelSkip(prose = "") {
  const text = String(prose);
  const read = /read at (L\d)(?:\/(L\d))?/.exec(text);
  const claimed = /claimed at (L\d)(?:\/(L\d))?/.exec(text);
  return {
    // The alternates matter: "L5/L3" and "L2/L3" are the fixture's own way of
    // saying the read straddles two rungs.
    read: read ? [read[1], read[2]].filter(Boolean) : [],
    claimed: claimed ? [claimed[1], claimed[2]].filter(Boolean) : [],
  };
}

/**
 * Choose a read level the grammar can actually model, reporting any remap.
 *
 * Candidates are walked IN THE ORDER the specimen's prose lists them, because
 * the first one is what the specimen means and any later alternate is the
 * fixture already conceding the grammar's answer. Landing on an alternate is
 * therefore still a REMAP and is reported as one — "L5/L3" resolving to L3
 * silently would hide that no L5 read is expressible at all, which is the one
 * thing about specimen 5's modelling a reader needs to know.
 */
function resolveReadLevel(candidates) {
  let skipped = null;
  for (const level of candidates) {
    if (Object.hasOwn(READ_LEVEL_PROBES, level)) {
      return { level, remap: skipped ? { from: skipped.level, to: level, why: skipped.why } : null };
    }
    if (UNDERIVABLE[level] && skipped === null) skipped = { level, why: UNDERIVABLE[level].why };
  }
  // No listed alternate is derivable — fall back to the declared fallback.
  if (skipped) {
    const fallback = UNDERIVABLE[skipped.level].fallback;
    return { level: fallback, remap: { from: skipped.level, to: fallback, why: skipped.why } };
  }
  return { level: null, remap: null };
}

/** Verify every probe still derives the level it is filed under. */
export function checkProbes() {
  const drift = [];
  for (const [level, command] of Object.entries(READ_LEVEL_PROBES)) {
    const derived = deriveLevel(command);
    if (derived !== level) drift.push({ level, command, derived });
  }
  return drift;
}

/**
 * Model ONE specimen as the sinful fact the agent actually produced.
 *
 * Read level from the specimen's own "read at Lx" clause (via a PROBE command
 * that derives Lx — never the specimen's `rerun`, which is the FIX; see the
 * header), claimed level from its "claimed at Ly" clause.
 *
 * Exported because the fixture holds specimens `runAcceptance` deliberately
 * does NOT judge — the UNRATIFIED negative controls, which are not in the
 * ratified table and must never be counted as rows of it. Those still have to
 * be modelled EXACTLY as a ratified one is, or a claim about what the
 * adjudicator does to them is a claim about a different fact. One modelling,
 * two consumers.
 */
export function factFromSpecimen(specimen) {
  const parsed = parseLevelSkip(specimen.level_skip);
  const { level: readLevel, remap } = resolveReadLevel(parsed.read);
  const claimedLevel = parsed.claimed[0] ?? undefined;

  // The SINFUL fact: the level the agent read at, quoted at the level it
  // claimed. `wrong_evidence` is the claim the specimen records verbatim.
  const fact = {
    subject: specimen.title,
    quantity: specimen.wrong_evidence,
    claim: specimen.wrong_evidence,
    evidence: specimen.wrong_evidence,
    rerun: readLevel === null ? "" : READ_LEVEL_PROBES[readLevel],
    level: claimedLevel,
    observed_at: "2026-07-20T12:00:00Z",
  };

  return { fact, readLevel, claimedLevel, remap };
}

/**
 * Run every ratified specimen through the real adjudicator.
 *
 * @returns {{ok: boolean, probe_drift: [], results: [], findings: []}}
 */
export function runAcceptance(fixturePath = FIXTURE) {
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
  const specimens = (fixture.specimens ?? []).filter((s) => s.ratified === true);

  const probe_drift = checkProbes();
  const results = [];
  const findings = [];

  // PROBE-DRIFT is fatal and checked FIRST. If a probe no longer derives its
  // level, every judgement below is being made against a fact that does not
  // model the specimen — the suite would still go green or red, but about the
  // wrong question. That is the vacuous green this epic exists to abolish, so
  // it stops here rather than reporting confidently on a broken model.
  if (probe_drift.length > 0) {
    return { ok: false, probe_drift, results, findings, specimen_count: specimens.length };
  }

  // The ratified table has SIX rows (fixture _meta.row_count_provenance,
  // re-derived from the durable paper). A fixture that grew or lost a ratified
  // specimen without this file being revisited is itself a finding.
  if (specimens.length !== 6) {
    findings.push({
      kind: "SPECIMEN-COUNT",
      detail: `expected 6 ratified specimens (the ratified table's row count), found ${specimens.length}`,
    });
  }

  for (const specimen of specimens) {
    const { fact, readLevel, claimedLevel, remap } = factFromSpecimen(specimen);

    const ruling = adjudicate(fact, { execute: false });
    const reasons = [...ruling.reasons].sort();

    const expected = EXPECTED[specimen.id];
    const caught = ruling.verdict === VERDICTS.REJECTED;
    const labelledCaught = specimen.caught_by !== "UNCAUGHT";

    // The specimen's OWN rerun, screened and never run (D116). Pure string
    // judgement — screen.mjs imports nothing and executes nothing.
    const screened = screenCommand(specimen.rerun ?? "");
    const screen = { ok: screened.ok === true, reason: String(screened.reason ?? "") };

    const row = {
      id: specimen.id,
      title: specimen.title,
      caught_by: specimen.caught_by,
      modelled: { read: readLevel, claimed: claimedLevel ?? null, remap },
      verdict: ruling.verdict,
      reasons,
      caught,
      labelled_caught: labelledCaught,
      screen,
      failures: [],
    };

    // (0) THE SCREEN IS FROZEN, refusals included. A rerun that starts being
    // admitted — or starts being refused for a different rule — is drift in the
    // one instrument that stands between this fixture and a production ssh, and
    // it must be discovered here rather than by a command that runs.
    const wantScreen = SCREEN_EXPECTED[specimen.id];
    if (!wantScreen) {
      row.failures.push({
        kind: "NO-SCREEN-EXPECTATION",
        detail: `specimen ${specimen.id} has no entry in SCREEN_EXPECTED — its rerun was screened but nothing pins the answer`,
      });
    } else if (screen.ok !== wantScreen.ok || screen.reason !== wantScreen.reason) {
      row.failures.push({
        kind: "SCREEN-DRIFT",
        detail:
          `screenCommand now answers {ok: ${screen.ok}, reason: ${JSON.stringify(screen.reason)}}, ` +
          `frozen as {ok: ${wantScreen.ok}, reason: ${JSON.stringify(wantScreen.reason)}}. ` +
          "Either the screen moved or the specimen's rerun did — never relax this row to match; " +
          "re-derive the screen and say which rule changed.",
      });
    }

    // (a) The adjudicator's behaviour against this specimen, exactly.
    if (!expected) {
      row.failures.push({ kind: "NO-EXPECTATION", detail: `specimen ${specimen.id} has no entry in EXPECTED` });
    } else {
      if (ruling.verdict !== expected.verdict) {
        row.failures.push({
          kind: "VERDICT",
          detail: `expected ${expected.verdict}, got ${ruling.verdict}`,
        });
      }
      const wantReasons = [...expected.reasons].sort();
      if (JSON.stringify(reasons) !== JSON.stringify(wantReasons)) {
        row.failures.push({
          kind: "REASONS",
          detail: `expected [${wantReasons.join("+") || "none"}], got [${reasons.join("+") || "none"}]`,
        });
      }
    }

    // (b) THE HYPOTHESIS — is the specimen caught at all? This is the SAFETY
    // half and is never waived by a declared divergence.
    if (caught !== labelledCaught) {
      row.failures.push({
        kind: "CAUGHT-BY",
        detail: labelledCaught
          ? `labelled caught_by ${specimen.caught_by} but the adjudicator ADMITTED it`
          : `labelled UNCAUGHT but the adjudicator REJECTED it (${reasons.join("+")})`,
      });
    }

    // (c) THE HYPOTHESIS — is it caught by the rule the label names? This is
    // the DIAGNOSIS half, and it is where declared divergences live.
    if (caught && labelledCaught) {
      const byLabelledRule = specimen.caught_by === "R1" && reasons.includes("LEVEL-SKIP");
      const declared = DECLARED_DIVERGENCES[specimen.id];
      if (!byLabelledRule) {
        if (declared) {
          findings.push({
            kind: "DECLARED-DIVERGENCE",
            id: specimen.id,
            labelled: declared.labelled,
            actually: declared.actually,
            detail: declared.finding,
            filed_as: declared.filed_as,
          });
          row.divergence = declared;
        } else {
          row.failures.push({
            kind: "UNDECLARED-DIVERGENCE",
            detail:
              `labelled caught_by ${specimen.caught_by}, but the adjudicator rejected it under ` +
              `[${reasons.join("+")}]. The specimen is caught by a DIFFERENT rule than its label ` +
              "claims. Either the label is wrong or the grammar moved — declare it in " +
              "DECLARED_DIVERGENCES with a filed task, or fix the fixture.",
          });
        }
      }
    }

    results.push(row);
  }

  const ok = results.every((r) => r.failures.length === 0) && findings.every((f) => f.kind === "DECLARED-DIVERGENCE");
  return { ok, probe_drift, results, findings, specimen_count: specimens.length };
}

// ── report ───────────────────────────────────────────────────────────────────

function report(outcome) {
  const lines = [];
  lines.push("LEVEL-SKIP ACCEPTANCE — the ratified specimens vs. the real adjudicator");
  lines.push("");

  if (outcome.probe_drift.length > 0) {
    lines.push("PROBE-DRIFT — the read-level model is broken; no specimen was judged.");
    for (const d of outcome.probe_drift) {
      lines.push(`  ${d.level} probe now derives ${d.derived}: ${d.command || "(empty command)"}`);
    }
    return lines.join("\n");
  }

  for (const r of outcome.results) {
    const mark = r.failures.length === 0 ? (r.divergence ? "~" : "✓") : "✗";
    const model = `read ${r.modelled.read}${r.modelled.remap ? ` (${r.modelled.remap.from}→${r.modelled.remap.to})` : ""} → claimed ${r.modelled.claimed ?? "none"}`;
    lines.push(`${mark} [${r.id}] ${r.title}`);
    lines.push(`    ${model}`);
    lines.push(`    labelled ${r.caught_by} · verdict ${r.verdict}${r.reasons.length ? ` (${r.reasons.join("+")})` : ""}`);
    lines.push(`    screen ${r.screen.ok ? "ADMITTED" : "REFUSED "} · ${r.screen.reason}`);
    for (const f of r.failures) lines.push(`    FAIL ${f.kind}: ${f.detail}`);
    if (r.modelled.remap) lines.push(`    note: ${r.modelled.remap.why}`);
  }

  const declared = outcome.findings.filter((f) => f.kind === "DECLARED-DIVERGENCE");
  if (declared.length > 0) {
    lines.push("");
    lines.push("FINDINGS — labels that do not match what the adjudicator actually does:");
    for (const f of declared) {
      lines.push(`  [${f.id}] labelled ${f.labelled}, caught by ${f.actually} · filed as ${f.filed_as}`);
      lines.push(`      ${f.detail}`);
    }
  }

  for (const f of outcome.findings.filter((x) => x.kind !== "DECLARED-DIVERGENCE")) {
    lines.push(`  FAIL ${f.kind}: ${f.detail}`);
  }

  lines.push("");
  const passing = outcome.results.filter((r) => r.failures.length === 0).length;
  const refused = outcome.results.filter((r) => !r.screen.ok).length;
  lines.push(`${passing}/${outcome.results.length} ratified specimens adjudicate as expected · ${declared.length} declared divergence(s)`);
  lines.push(`${refused}/${outcome.results.length} specimen reruns are REFUSED by the screen, frozen verbatim — none was executed`);
  lines.push(outcome.ok ? "ACCEPTANCE: PASS" : "ACCEPTANCE: FAIL");
  return lines.join("\n");
}

const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  // FIRST ACT (D78). "ACCEPTANCE: PASS" is the most laundering-prone line grip
  // prints — a pass from a 200-commit-stale tree looks identical to a pass from
  // main. The banner is what tells those two apart.
  emitProvenance();

  const outcome = runAcceptance();
  if (process.argv.includes("--json")) {
    console.log(JSON.stringify(outcome, null, 2));
  } else {
    console.log(report(outcome));
  }
  // NO process.exit HERE (charter D92). The report above is this epic's own
  // evidence, and process.exit() drops any of it still queued for an
  // asynchronous pipe — so `acceptance.mjs --json | jq` could hand back a
  // JSON.parse error, and `| tee` a report ending mid-line, while the same run
  // redirected to a file was whole. exitCode keeps the exit STATUS identical
  // (0 on PASS, 1 on FAIL) and lets stdout drain on the natural exit.
  process.exitCode = outcome.ok ? 0 : 1;
}

export { READ_LEVEL_PROBES, EXPECTED, SCREEN_EXPECTED, DECLARED_DIVERGENCES, FIXTURE, report };
