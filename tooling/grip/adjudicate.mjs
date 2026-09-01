// adjudicate.mjs — THE VERDICT ENGINE. It COMPOSES; it does not re-decide.
//
// Two halves already exist and this module owns neither of them:
//
//   record.mjs  admitFact()  — write-time admission. Emits LEVEL-SKIP,
//               PATHLESS-REF (with field= attribution), INADMISSIBLE-CONTINUOUS,
//               MISSING-SUBJECT, MISSING-CLAIM, BAD-DEPS, UNKNOWN-LEVEL, and
//               demote-to-L6-on-missing-rerun. Rejections ACCUMULATE.
//   rerun.mjs   runRerun()   — actual re-execution, with a verdict enum whose
//               names UNAVAILABLE / NULL-READ / ASYNC-DEFERRED are already
//               byte-identical to this layer's. Zero translation.
//
// Re-implementing either half here would make a SIXTH hand-copy of the
// authority grammar — this epic's own defect class (charter D24). Everything
// below is a mapping, a join, or a rendering.
//
// THE VOCABULARY IS TEN NAMES (D24):
//
//   ADMITTED               the fact stands at its derived level
//   DEMOTED                stands, but at L6 — no classifiable rerun (D3)
//   REJECTED(:reason)      MALFORMED. The reasons come from admitFact verbatim.
//   FAILED                 the command RAN and genuinely REFUTES the claim
//   REACHABLE-WRONG-ROUTE  the world is up, the route is wrong
//   HOST-UNREACHABLE       the world is down — says nothing about the route
//   UNAVAILABLE            the probe could not run here at all
//   NULL-READ              the read came back empty — NOT an absence
//   ASYNC-DEFERRED         too costly to re-run inline
//   CONFLICT               two facts, one (subject, quantity), rival claims
//
// FAILED is the one that must never be folded into REJECTED. REJECTED means
// "your fact is MALFORMED"; FAILED means "your fact is FALSE". Collapsing them
// is exactly the distinction rerun.mjs's enum exists to prevent.
//
// WHAT A VERDICT CERTIFIES (D4): re-derivability, and nothing else. The wording
// throughout is "re-derived just now", and never any phrasing that implies the
// author was observed reading — that phrasing is banned repo-wide in
// tooling/grip and the ban is enforced by a grep in the test suite, so this
// comment states the rule without spelling the banned words. A syntactically
// perfect curl the author never ran passes this engine, and that is correct:
// authorship is outside the tool's jurisdiction.
//
// Pure apart from the injectable runner. ESM named exports only.

import { admitFact } from "./record.mjs";
import { deriveLevel } from "./level.mjs";
import { runRerun, VERDICT } from "./rerun.mjs";
import { screenCommand } from "./screen.mjs";

// The ten names. Frozen so a caller cannot grow the vocabulary by assignment.
export const VERDICTS = Object.freeze({
  ADMITTED: "ADMITTED",
  DEMOTED: "DEMOTED",
  REJECTED: "REJECTED",
  FAILED: "FAILED",
  WRONG_ROUTE: "REACHABLE-WRONG-ROUTE",
  UNREACHABLE: "HOST-UNREACHABLE",
  UNAVAILABLE: "UNAVAILABLE",
  NULL_READ: "NULL-READ",
  ASYNC_DEFERRED: "ASYNC-DEFERRED",
  CONFLICT: "CONFLICT",
});

// Execution verdict → adjudication verdict. A PASS-THROUGH for six of the
// seven: the executor already named them correctly and renaming would only
// create drift. UNSAFE-RERUN is the sole translation — a write-shaped rerun is
// a MALFORMED fact (refused before execution, so it says nothing about truth),
// which is REJECTED, not FAILED.
const EXECUTION_MAP = Object.freeze({
  [VERDICT.OK]: null, // null = "keeps its admission verdict" (ADMITTED / DEMOTED)
  [VERDICT.FAILED]: VERDICTS.FAILED,
  [VERDICT.WRONG_ROUTE]: VERDICTS.WRONG_ROUTE,
  [VERDICT.UNREACHABLE]: VERDICTS.UNREACHABLE,
  [VERDICT.UNAVAILABLE]: VERDICTS.UNAVAILABLE,
  [VERDICT.NULL_READ]: VERDICTS.NULL_READ,
  [VERDICT.ASYNC_DEFERRED]: VERDICTS.ASYNC_DEFERRED,
  [VERDICT.UNSAFE_RERUN]: VERDICTS.REJECTED,
});

// Verdicts under which the fact STANDS as a durable record.
const STANDING = new Set([VERDICTS.ADMITTED, VERDICTS.DEMOTED]);

/** Does this verdict leave the fact standing? CONFLICT does — both facts are kept. */
export function stands(verdict) {
  return STANDING.has(verdict) || verdict === VERDICTS.CONFLICT;
}

// ── THE CALLER-BOUNDARY SAFETY WIRE (Design B, charter D88) ──────────────────
//
// THE HOLE THIS CLOSES. The cli → adjudicate → runRerun path re-EXECUTES a
// fact's `rerun` command by default (execute: true, no injected runner). Left
// to itself, `runRerun` gates only on `classifySafety` before handing the
// survivor to `spawnSync("/bin/sh", ["-c", cmd])` in `shell` (rerun.mjs).
// Both were cited BY LINE here until 2026-09-01, and both had drifted — by 20
// and 41 lines — while still reading plausibly. Symbols now: grep the name.
// And `classifySafety` is a
// denylist that admits 22 of 22 named outage probes (systemctl stop, reboot,
// `mix ecto.drop`, `kill -9`, `pkill`, a bare `cp` into api/lib/, …) and 51 of
// the 53-command DANGER_SET, versus `screenCommand`'s 0. So a facts.json whose
// rerun is `cp /etc/hosts /tmp/grip-marker`, adjudicated with NO flags,
// MATERIALISED the file — a default-on RCE.
//
// WHY THE WIRE LIVES HERE, NOT IN screen.mjs OR rerun.mjs (D29, D47, D88):
//   - screen.mjs must import NOTHING from rerun.mjs (D29). It does not; this
//     module imports BOTH, which is the allowed direction.
//   - `classifySafety`'s grammar is NOT rewritten and `runRerun`'s internal
//     gate at rerun.mjs:676 is NOT swapped (D88). `runRerun`'s own 35 direct
//     callers in rerun.test.mjs keep their exact behaviour — this is a boundary
//     wire, not a grammar change, so it carries zero test-flip cost there.
//   - The seam is the DEFAULT RUNNER. `screenCommand` decides first; only a
//     command it admits is handed to `runRerun` to execute. A refusal returns an
//     UNSAFE-RERUN result BEFORE any spawnSync is reached, which the engine maps
//     to REJECTED ("rejected before execution"). An injected runner (tests, the
//     census, any caller passing opts.run) bypasses this by design — the screen
//     guards the path that would otherwise execute an arbitrary corpus command.
//
// COVERAGE BOUNDARY — STATED, DELIBERATELY NOT EXPANDED (D88). The caller screen
// inherits screen.mjs's current shape verbatim: it also refuses commands that
// are safe reads. A fact whose rerun is `git merge-base --is-ancestor <a> <b>`
// (the D40 merge proof) or `git -C <path> show …` is REFUSED through cli.mjs,
// because screen.mjs carries the `git -C` parse defect and the merge-base
// refusal until tgw4-screen-git-global-option-audit and tgw4-rerun-silence-fixes
// land. That is an over-refusal on the read side, not an RCE: it fails CLOSED.
// The RCE close is NOT deferred for it — this slice does not touch screen.mjs's
// grammar to fix those reads; it wires the existing screen at the boundary.
export function screenedRerun(command, opts = {}) {
  const screened = screenCommand(command);
  if (!screened.ok) {
    // Shaped to travel EXECUTION_MAP as UNSAFE-RERUN → REJECTED. Nothing ran.
    return {
      command: String(command ?? "").trim(),
      verdict: VERDICT.UNSAFE_RERUN,
      scope: null,
      ran: false,
      ms: 0,
      reason: `refused at the caller boundary before execution — ${screened.reason}`,
    };
  }
  return runRerun(command, opts);
}

/**
 * adjudicate(input, opts) → ruling
 *
 * ruling = {
 *   verdict,     one of the ten names
 *   label,       the rendered name — "REJECTED:LEVEL-SKIP+PATHLESS-REF" etc.
 *   reasons[],   named reasons, from admitFact / rerun verbatim
 *   rejections[],the full admitFact rejection objects (field= attribution kept)
 *   fact,        the admitted fact, or null when REJECTED
 *   level,       the admitted level, or null
 *   rerun,       the runRerun result, or null when not executed
 *   note,        one honest human line — "re-derived just now", never stronger
 * }
 *
 * @param {object} input  a fact-shaped record (record.mjs FACT_FIELDS)
 * @param {{execute?: boolean, run?: Function, root?: string, timeoutMs?: number}} [opts]
 *   execute — re-run the command (default true). false adjudicates admission alone.
 *   run     — injectable runner, defaults to screenedRerun (the caller-boundary
 *             safety wire, D88): screenCommand decides, runRerun executes only
 *             what it admits. Tests pass a stub so the verdict mapping is
 *             provable without touching the network — and injecting `run` is
 *             also how a caller deliberately bypasses the screen.
 */
export function adjudicate(input = {}, opts = {}) {
  // DEFAULT RUNNER IS THE SCREENED WIRE (D88), never bare runRerun. Any caller
  // may still inject `run` (tests, the census) to bypass the screen deliberately.
  const { execute = true, run = screenedRerun, root, timeoutMs } = opts;

  const admission = admitFact(input);

  if (!admission.ok) {
    const reasons = admission.rejections.map((r) => r.reason);
    return ruling({
      verdict: VERDICTS.REJECTED,
      reasons,
      rejections: admission.rejections,
      note: `rejected on admission: ${admission.rejections.map((r) => r.message).join(" | ")}`,
    });
  }

  const fact = admission.fact;
  // DEMOTED, not "downgraded from what the author asked for": the discriminator
  // is whether the COMMAND classifies. An author who honestly claims L6 over an
  // L3 command is under-claiming (record.mjs keeps it) and is ADMITTED at L6 —
  // that is not a demotion and must not be reported as one.
  const demoted = deriveLevel(fact.rerun) === "L6";
  const admittedVerdict = demoted ? VERDICTS.DEMOTED : VERDICTS.ADMITTED;

  if (!execute || fact.rerun === "") {
    return ruling({
      verdict: admittedVerdict,
      fact,
      level: fact.level,
      note: fact.rerun === ""
        ? `stands at ${fact.level} — no rerun command, so nothing was re-derived (D3: demoted, never rejected)`
        : `stands at ${fact.level} — admission only, the command was not re-run in this pass`,
    });
  }

  const result = run(fact.rerun, { root, timeoutMs });
  // Own-property lookup ONLY. A plain `EXECUTION_MAP[verdict]` inherits from
  // Object.prototype, so an executor returning "toString" / "constructor" /
  // "__proto__" would resolve to a function or {} — sailing past both the
  // `undefined` and the `null` branch below and emitting a ruling whose verdict
  // is not one of the ten names. That is the vocabulary-integrity guarantee
  // failing open in the exact guard written to hold it closed.
  const key = typeof result?.verdict === "string" ? result.verdict : null;
  const mapped = key !== null && Object.hasOwn(EXECUTION_MAP, key)
    ? EXECUTION_MAP[key]
    : undefined;

  if (mapped === undefined) {
    // An enum name this engine does not know. Never absorb it into a pass —
    // an unrecognised verdict is precisely a probe that said nothing usable.
    return ruling({
      verdict: VERDICTS.UNAVAILABLE,
      reasons: ["UNKNOWN-VERDICT"],
      fact,
      level: fact.level,
      rerun: result ?? null,
      note: `the executor returned ${JSON.stringify(result?.verdict ?? null)}, which this engine cannot rule on — treated as UNAVAILABLE, never as a pass`,
    });
  }

  if (mapped === null) {
    return ruling({
      verdict: admittedVerdict,
      fact,
      level: fact.level,
      rerun: result,
      note: `re-derived just now at ${fact.level} (${result.ms}ms) — the command reproduces; this certifies re-derivability, not that the author ran it`,
    });
  }

  if (mapped === VERDICTS.REJECTED) {
    return ruling({
      verdict: VERDICTS.REJECTED,
      reasons: [result.verdict],
      fact: null,
      level: null,
      rerun: result,
      note: `rejected before execution: ${result.reason}`,
    });
  }

  return ruling({
    verdict: mapped,
    reasons: [mapped],
    fact,
    level: fact.level,
    rerun: result,
    note: `re-derived just now and returned ${mapped}: ${result.reason || "(no reason recorded)"}`,
  });
}

function ruling({ verdict, label, reasons = [], rejections = [], fact = null, level = null, rerun = null, note = "" }) {
  return {
    verdict,
    label: label ?? renderLabel(verdict, reasons),
    reasons,
    rejections,
    fact,
    level,
    rerun,
    note,
    conflict: null,
  };
}

// REJECTED(:reason) — the parenthesised half of the vocabulary. Multiple
// reasons are joined rather than truncated, because admitFact ACCUMULATES and
// showing only the first would hide three quarters of a poisoned fact.
export function renderLabel(verdict, reasons = []) {
  if (verdict !== VERDICTS.REJECTED || reasons.length === 0) return verdict;
  return `${VERDICTS.REJECTED}:${reasons.join("+")}`;
}

// ── CONFLICT ─────────────────────────────────────────────────────────────────
//
// NOT WIRED INTO THE LIVE FACT FLOW, DELIBERATELY (charter D25).
//
// This engine keys conflict on (subject, quantity). NO LIVE CALLER POPULATES
// THOSE FIELDS: `subject` and `quantity` have zero occurrences in the workflow's
// SURVEY_SCHEMA, VERIFY_SCHEMA and FACT_ITEMS, so nothing upstream can produce a
// pair for this function to collide. It ships unit-tested against hand-built
// fixtures and MUST NOT be described as running in production. Claiming
// otherwise would itself be the level-skip this epic exists to stop.
//
// The measurement behind that decision, on the real 1,902-entry corpus: 0.05%
// collision at exact-claim grain, 2.4% at full path:line — and all 37 colliding
// groups were CORROBORATION between compatible facts, not rival values.
// Coarsening the key to basename raises it to 61% only by conflating exactly
// what a real subject field must separate.
//
// Two rules, both deliberate:
//   - BOTH facts are kept. Never resolved by write order — "last write wins" is
//     how a wrong value silently replaces a right one.
//   - Identical claims on one key are CORROBORATION, not conflict. Agreement is
//     not a defect, and flagging it would bury the real collisions in noise.

/** The collision key. Absent quantity is a real key value (∅), not a wildcard. */
export function conflictKey(fact) {
  const subject = typeof fact?.subject === "string" ? fact.subject.trim() : "";
  const q = fact?.quantity;
  const quantity = q === null || q === undefined ? "" : String(q).trim();
  return JSON.stringify([subject, quantity]);
}

/**
 * detectConflicts(rulings) → rulings (mutated in place, and returned)
 *
 * Groups standing facts by (subject, quantity). A group whose members carry two
 * or more DISTINCT claims is a conflict: every member is flagged CONFLICT and
 * every member is KEPT, with `underlying` preserving the verdict it would have
 * had alone so nothing is lost by the flagging.
 */
export function detectConflicts(rulings = []) {
  const groups = new Map();
  for (const r of rulings) {
    if (!r?.fact || !STANDING.has(r.verdict)) continue;
    const key = conflictKey(r.fact);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }

  for (const [key, members] of groups) {
    if (members.length < 2) continue;
    const claims = [...new Set(members.map((r) => r.fact.claim.trim()))];
    if (claims.length < 2) continue; // corroboration, not conflict

    for (const r of members) {
      r.underlying = r.verdict;
      r.verdict = VERDICTS.CONFLICT;
      r.label = VERDICTS.CONFLICT;
      r.conflict = { key, claims, count: members.length, rivals: claims.filter((c) => c !== r.fact.claim.trim()) };
      r.note = `CONFLICT on ${key}: ${members.length} facts carry ${claims.length} rival claims — all kept, none resolved by write order`;
    }
  }

  return rulings;
}

/**
 * adjudicateAll(inputs, opts) → { rulings, conflicts, counts }
 * The whole pass: rule on each fact, then look across them for collisions.
 */
export function adjudicateAll(inputs = [], opts = {}) {
  const rulings = inputs.map((input) => adjudicate(input, opts));
  detectConflicts(rulings);

  const counts = {};
  for (const r of rulings) counts[r.verdict] = (counts[r.verdict] ?? 0) + 1;

  const conflicts = rulings.filter((r) => r.conflict !== null);
  return { rulings, conflicts, counts };
}
