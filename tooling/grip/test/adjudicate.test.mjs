// adjudicate.test.mjs — the verdict engine.
//
// Two things this suite is built to prove, because they are the two ways this
// slice could ship as theatre:
//
//   1. The engine COMPOSES admitFact rather than re-deciding. Tested by feeding
//      a fact poisoned four ways and asserting all four named reasons arrive —
//      an engine that re-implemented the checks would abort on the first.
//   2. Every check can genuinely FAIL. The CONFLICT tests assert both the
//      positive (rival claims flag both) and the negative (identical claims
//      flag nothing), so a detector hard-wired to "always conflict" or "never
//      conflict" fails one of them.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";

import {
  adjudicate, adjudicateAll, detectConflicts, conflictKey, renderLabel, stands, VERDICTS,
  screenedRerun,
} from "../adjudicate.mjs";
import { VERDICT, classifySafety, classifySilence } from "../rerun.mjs";
import { screenCommand, DANGER_SET } from "../screen.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const GRIP = join(HERE, "..");

// A clean, admissible L3 fact. Every fixture below is this one, minus or plus
// exactly one field, so a failure names the field that caused it.
const CLEAN = Object.freeze({
  subject: "tooling/grip/record.mjs admitFact",
  quantity: "8 named rejection reasons",
  claim: "admitFact emits exactly 8 distinct rejection reasons",
  evidence: "counted the rejections.push sites in the source",
  rerun: "grep -c 'reason:' tooling/grip/record.mjs",
  level: "L3",
});
const withField = (patch) => ({ ...CLEAN, ...patch });

// An injectable executor. Counts calls so a test can prove the engine really
// went through re-execution rather than short-circuiting past it.
function stub(verdict, counter = { calls: 0 }) {
  const run = (command) => {
    counter.calls += 1;
    return { command, verdict, ms: 7, reason: `stubbed ${verdict}`, ran: true };
  };
  run.counter = counter;
  return run;
}

// ── the vocabulary ───────────────────────────────────────────────────────────

test("the vocabulary is exactly ten distinct names", () => {
  const names = Object.values(VERDICTS);
  assert.equal(names.length, 10);
  assert.equal(new Set(names).size, 10);
  assert.deepEqual(new Set(names), new Set([
    "ADMITTED", "DEMOTED", "REJECTED", "FAILED", "REACHABLE-WRONG-ROUTE",
    "HOST-UNREACHABLE", "UNAVAILABLE", "NULL-READ", "ASYNC-DEFERRED", "CONFLICT",
  ]));
});

test("VERDICTS is frozen — the vocabulary cannot be grown by assignment", () => {
  assert.throws(() => { "use strict"; VERDICTS.INVENTED = "INVENTED"; }, TypeError);
});

test("three names are spelled byte-identically to rerun.mjs's enum — zero translation", () => {
  assert.equal(VERDICTS.UNAVAILABLE, VERDICT.UNAVAILABLE);
  assert.equal(VERDICTS.NULL_READ, VERDICT.NULL_READ);
  assert.equal(VERDICTS.ASYNC_DEFERRED, VERDICT.ASYNC_DEFERRED);
});

// ── composition, not re-implementation ───────────────────────────────────────

test("adjudicate.mjs re-implements no rejection class — it imports admitFact", () => {
  const src = readFileSync(join(GRIP, "adjudicate.mjs"), "utf8");
  assert.match(src, /import \{ admitFact \} from "\.\/record\.mjs"/);
  // The rejection names may appear in prose (the header explains what it
  // composes) but never as an emitted string literal or a comparison.
  const code = src.split("\n").filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join("\n");
  for (const reason of ["LEVEL-SKIP", "PATHLESS-REF", "INADMISSIBLE-CONTINUOUS", "MISSING-SUBJECT", "MISSING-CLAIM", "BAD-DEPS", "UNKNOWN-LEVEL"]) {
    assert.equal(code.includes(reason), false, `adjudicate.mjs code re-states ${reason} — it must come from record.mjs`);
  }
});

test("rejections ACCUMULATE — a fact poisoned four ways reports all four reasons", () => {
  const ruling = adjudicate({
    subject: "notifications.ex:389-397",   // PATHLESS-REF
    quantity: "t_total 1.84s",             // INADMISSIBLE-CONTINUOUS
    claim: "",                             // MISSING-CLAIM
    rerun: "git show origin/main:x.ex",
    level: "L1",                           // LEVEL-SKIP over derived L2
  });
  assert.equal(ruling.verdict, VERDICTS.REJECTED);
  for (const reason of ["MISSING-CLAIM", "LEVEL-SKIP", "PATHLESS-REF", "INADMISSIBLE-CONTINUOUS"]) {
    assert.ok(ruling.reasons.includes(reason), `expected ${reason} in ${ruling.label}`);
  }
  assert.ok(ruling.reasons.length >= 4, "a first-failure abort would report one");
});

test("the PATHLESS-REF rejection keeps record.mjs's field= attribution", () => {
  const ruling = adjudicate(withField({ subject: "notifications.ex:389-397 delivery log" }));
  const pathless = ruling.rejections.find((r) => r.reason === "PATHLESS-REF");
  assert.ok(pathless, "expected a PATHLESS-REF rejection");
  assert.equal(pathless.field, "subject");
});

test("REJECTED renders as REJECTED:reason, joining accumulated reasons", () => {
  assert.equal(renderLabel(VERDICTS.REJECTED, ["LEVEL-SKIP"]), "REJECTED:LEVEL-SKIP");
  assert.equal(renderLabel(VERDICTS.REJECTED, ["LEVEL-SKIP", "PATHLESS-REF"]), "REJECTED:LEVEL-SKIP+PATHLESS-REF");
  assert.equal(renderLabel(VERDICTS.FAILED, ["FAILED"]), "FAILED", "only REJECTED carries a reason suffix");
});

// ── admission verdicts ───────────────────────────────────────────────────────

test("a clean fact whose command reproduces is ADMITTED at its derived level", () => {
  const ruling = adjudicate(CLEAN, { run: stub(VERDICT.OK) });
  assert.equal(ruling.verdict, VERDICTS.ADMITTED);
  assert.equal(ruling.level, "L3");
  assert.equal(ruling.fact.subject, CLEAN.subject);
});

test("no rerun command DEMOTES to L6 — it never rejects (D3)", () => {
  const ruling = adjudicate({ subject: "a thing", claim: "a discrete claim about 3 rows", rerun: "" });
  assert.equal(ruling.verdict, VERDICTS.DEMOTED);
  assert.equal(ruling.level, "L6");
  assert.ok(ruling.fact, "a demoted fact still stands");
  assert.ok(stands(ruling.verdict));
});

test("an unclassifiable command DEMOTES rather than rejecting", () => {
  const ruling = adjudicate(
    { subject: "a thing", claim: "a discrete claim about 3 rows", rerun: "frobnicate --all" },
    { execute: false },
  );
  assert.equal(ruling.verdict, VERDICTS.DEMOTED);
  assert.equal(ruling.level, "L6");
});

test("an honest UNDER-claim is ADMITTED, not reported as a demotion", () => {
  // L6 claimed over an L3 command: record.mjs keeps the under-claim, and the
  // command still classifies, so this is ADMITTED at L6 — not DEMOTED.
  const ruling = adjudicate(withField({ level: "L6" }), { execute: false });
  assert.equal(ruling.verdict, VERDICTS.ADMITTED);
  assert.equal(ruling.level, "L6");
});

// ── the three verdicts that must not collapse into REJECTED ──────────────────

test("FAILED is NOT reported as REJECTED — false is not malformed", () => {
  const run = stub(VERDICT.FAILED);
  const ruling = adjudicate(CLEAN, { run });
  assert.equal(ruling.verdict, VERDICTS.FAILED);
  assert.notEqual(ruling.verdict, VERDICTS.REJECTED);
  assert.equal(ruling.label, "FAILED", "no REJECTED: prefix may attach to a refutation");
  assert.equal(run.counter.calls, 1, "the engine must actually go through re-execution");
  assert.ok(ruling.fact, "a refuted fact is still a well-formed fact");
});

test("REACHABLE-WRONG-ROUTE and HOST-UNREACHABLE pass through unchanged", () => {
  assert.equal(adjudicate(CLEAN, { run: stub(VERDICT.WRONG_ROUTE) }).verdict, VERDICTS.WRONG_ROUTE);
  assert.equal(adjudicate(CLEAN, { run: stub(VERDICT.UNREACHABLE) }).verdict, VERDICTS.UNREACHABLE);
});

test("UNAVAILABLE, NULL-READ and ASYNC-DEFERRED pass through unchanged", () => {
  assert.equal(adjudicate(CLEAN, { run: stub(VERDICT.UNAVAILABLE) }).verdict, VERDICTS.UNAVAILABLE);
  assert.equal(adjudicate(CLEAN, { run: stub(VERDICT.NULL_READ) }).verdict, VERDICTS.NULL_READ);
  assert.equal(adjudicate(CLEAN, { run: stub(VERDICT.ASYNC_DEFERRED) }).verdict, VERDICTS.ASYNC_DEFERRED);
});

test("none of the six executor verdicts leaves the fact standing", () => {
  for (const v of [VERDICT.FAILED, VERDICT.WRONG_ROUTE, VERDICT.UNREACHABLE, VERDICT.UNAVAILABLE, VERDICT.NULL_READ, VERDICT.ASYNC_DEFERRED]) {
    assert.equal(stands(adjudicate(CLEAN, { run: stub(v) }).verdict), false, `${v} must not leave a fact standing`);
  }
});

test("a write-shaped rerun is REJECTED:UNSAFE-RERUN — malformed, not refuted", () => {
  const ruling = adjudicate(withField({ rerun: "bp doc publish task x --yes" }));
  assert.equal(ruling.verdict, VERDICTS.REJECTED);
  assert.ok(ruling.label.startsWith("REJECTED:"));
  assert.equal(ruling.fact, null);
});

test("an unrecognised executor verdict becomes UNAVAILABLE, never a pass", () => {
  const ruling = adjudicate(CLEAN, { run: () => ({ verdict: "SOMETHING-NEW", reason: "" }) });
  assert.equal(ruling.verdict, VERDICTS.UNAVAILABLE);
  assert.ok(ruling.reasons.includes("UNKNOWN-VERDICT"));
});

// A benign unknown name is the EASY half. The map is a plain object literal, so
// it inherits Object.prototype — the names below all resolve to something
// truthy through the prototype chain and, before the own-property guard, each
// produced a ruling whose verdict was a function or `{}`: outside the ten
// names entirely. Every ruling this engine emits must carry one of the ten,
// whatever an executor hands back.
const TEN = new Set(Object.values(VERDICTS));

test("an inherited-key verdict name is UNAVAILABLE too, not a prototype value", () => {
  for (const hostile of ["toString", "constructor", "valueOf", "hasOwnProperty", "__proto__", "isPrototypeOf"]) {
    const ruling = adjudicate(CLEAN, { run: () => ({ verdict: hostile, reason: "" }) });
    assert.equal(ruling.verdict, VERDICTS.UNAVAILABLE, `verdict "${hostile}" must be UNAVAILABLE`);
    assert.ok(ruling.reasons.includes("UNKNOWN-VERDICT"), `verdict "${hostile}" must name UNKNOWN-VERDICT`);
    assert.ok(TEN.has(ruling.verdict), `verdict "${hostile}" must stay inside the ten names`);
  }
});

test("a non-string verdict is UNAVAILABLE, and never leaves the ten names", () => {
  for (const hostile of [null, undefined, 0, 1, {}, [], true, Symbol.iterator]) {
    const ruling = adjudicate(CLEAN, { run: () => ({ verdict: hostile, reason: "" }) });
    assert.equal(ruling.verdict, VERDICTS.UNAVAILABLE, `verdict ${String(hostile)} must be UNAVAILABLE`);
    assert.ok(TEN.has(ruling.verdict));
  }
  // and a runner that returns nothing at all
  assert.equal(adjudicate(CLEAN, { run: () => undefined }).verdict, VERDICTS.UNAVAILABLE);
  assert.equal(adjudicate(CLEAN, { run: () => null }).verdict, VERDICTS.UNAVAILABLE);
});

// ── the ABSENCE VETO, promoted onto the ruling (D50) ─────────────────────────
//
// The trap this section exists for: FAILED is TWO answers wearing one name. A
// matcher that ran and matched nothing is a genuine "X is not there"; a DIFFER
// that exited 1 found differences, WITH content, and citing it as an absence
// inverts the polarity. rerun.mjs separates them on `absenceEligible`, and the
// engine promotes the answer as `ruling.admits_absence` so a consumer never has
// to reach into the nested raw result to find the veto.
//
// Both fixtures below come from classifySilence itself rather than from a
// hand-typed shape, so a fixture cannot drift away from the table it stands
// for — and each asserts its own `absenceEligible` first, which is the
// non-vacuity check: a pair that silently stopped being the veto cell and the
// eligible cell would still agree with a broken promotion.

/** A stub runner returning a REAL classifySilence result for (command, run). */
function silenceStub(command, run) {
  const s = classifySilence(command, run);
  return () => ({
    command,
    verdict: s.verdict,
    family: s.family,
    absenceEligible: s.absenceEligible,
    exit: run.exit,
    ran: true,
    ms: 3,
    reason: s.reason,
  });
}

test("a DIFFER rc1 ruling does NOT admit an absence claim — the veto is on the ruling", () => {
  const cmd = "diff -u a.txt b.txt";
  const raw = classifySilence(cmd, { exit: 1, stdout: "- old line\n+ new line\n" });
  assert.equal(raw.verdict, VERDICT.FAILED, "fixture must be the FAILED cell, or this proves nothing");
  assert.equal(raw.absenceEligible, false, "fixture must be the VETOED cell, or this proves nothing");

  const ruling = adjudicate(withField({ rerun: cmd }), {
    run: silenceStub(cmd, { exit: 1, stdout: "- old line\n+ new line\n" }),
  });
  assert.equal(ruling.verdict, VERDICTS.FAILED, "the verdict is unchanged — no eleventh name was minted");
  assert.equal(ruling.admits_absence, false, "differences found may never be cited as an absence");
});

test("a matcher rc1 ruling DOES admit an absence claim — same verdict, opposite veto", () => {
  const cmd = "grep -rn 'no-such-symbol' tooling/grip";
  const raw = classifySilence(cmd, { exit: 1, stdout: "" });
  assert.equal(raw.verdict, VERDICT.FAILED, "the positive control must share the DIFFER cell's verdict");
  assert.equal(raw.absenceEligible, true, "a genuine no-match is not vetoed");

  const ruling = adjudicate(withField({ rerun: cmd }), { run: silenceStub(cmd, { exit: 1, stdout: "" }) });
  assert.equal(ruling.verdict, VERDICTS.FAILED, "the discriminator is NOT the verdict — both cells are FAILED");
  assert.equal(ruling.admits_absence, true, "a matcher that ran and matched nothing IS an absence");
});

test("a tool error carries the veto too — an errored matcher is not an absence", () => {
  const cmd = "grep -rn 'x' tooling/grip";
  const ruling = adjudicate(withField({ rerun: cmd }), { run: silenceStub(cmd, { exit: 2, stderr: "no such file" }) });
  assert.equal(ruling.admits_absence, false, "a tool error may never support a negative claim");
});

test("a pass does not admit an absence claim — reproducing is not evidence of missing", () => {
  const ruling = adjudicate(CLEAN, { run: stub(VERDICT.OK) });
  assert.equal(ruling.verdict, VERDICTS.ADMITTED);
  assert.equal(ruling.admits_absence, false);
});

test("every branch that never executed carries admits_absence false", () => {
  // admission-only, empty rerun, unsafe rerun, unknown verdict, and a fact
  // rejected before it was ever a fact. Nothing ran in any of them, so none of
  // them may support "X is not there".
  const branches = {
    "admission only": adjudicate(CLEAN, { execute: false }),
    "no rerun command": adjudicate({ subject: "a thing", claim: "a discrete claim about 3 rows", rerun: "" }),
    "rejected on admission": adjudicate(withField({ claim: "" })),
    "unsafe rerun": adjudicate(withField({ rerun: "bp doc publish task x --yes" })),
    "unknown verdict": adjudicate(CLEAN, { run: () => ({ verdict: "SOMETHING-NEW", reason: "" }) }),
  };
  for (const [name, ruling] of Object.entries(branches)) {
    assert.equal(ruling.admits_absence, false, `${name} must not admit an absence claim`);
  }
});

test("the veto is DELEGATED to rerun.mjs, not re-implemented in adjudicate.mjs", () => {
  const src = readFileSync(join(GRIP, "adjudicate.mjs"), "utf8");
  assert.match(src, /import \{[^}]*admitsAbsenceClaim[^}]*\} from "\.\/rerun\.mjs"/);
  const code = src.split("\n").filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join("\n");
  assert.equal(code.includes("absenceEligible"), false,
    "a second copy of the veto predicate here is the hand-copied-authority defect this epic exists to stop");
});

// ── CONFLICT — unit-tested, NOT wired into any live flow (D25) ────────────────
//
// No live caller populates subject/quantity, so these fixtures are hand-built
// on purpose. That is the whole reason they must be able to fail: both the
// positive and the negative are asserted below.

test("conflictKey keys on (subject, quantity), and absent quantity is a real key", () => {
  assert.equal(conflictKey({ subject: "a", quantity: "b" }), conflictKey({ subject: " a ", quantity: "b " }));
  assert.notEqual(conflictKey({ subject: "a", quantity: "b" }), conflictKey({ subject: "a", quantity: "c" }));
  assert.equal(conflictKey({ subject: "a", quantity: null }), conflictKey({ subject: "a" }));
  assert.notEqual(conflictKey({ subject: "a", quantity: null }), conflictKey({ subject: "a", quantity: "0" }));
});

test("CONFLICT: rival claims on one (subject, quantity) flag BOTH and keep BOTH", () => {
  const a = withField({ claim: "the delivery log carries 12 rows" });
  const b = withField({ claim: "the delivery log carries 9 rows" });
  const { rulings, conflicts } = adjudicateAll([a, b], { execute: false });

  assert.equal(conflicts.length, 2, "both facts must be flagged, not just the loser");
  for (const r of rulings) {
    assert.equal(r.verdict, VERDICTS.CONFLICT);
    assert.ok(r.fact, "both facts are KEPT — write order never resolves a conflict");
    assert.equal(r.underlying, VERDICTS.ADMITTED, "the verdict it would have had alone is preserved");
    assert.equal(r.conflict.count, 2);
    assert.equal(r.conflict.rivals.length, 1);
  }
  assert.notEqual(rulings[0].fact.claim, rulings[1].fact.claim);
});

test("CONFLICT is order-independent — reversing the input flags the same pair", () => {
  const a = withField({ claim: "the delivery log carries 12 rows" });
  const b = withField({ claim: "the delivery log carries 9 rows" });
  const forward = adjudicateAll([a, b], { execute: false });
  const reverse = adjudicateAll([b, a], { execute: false });
  assert.equal(forward.conflicts.length, reverse.conflicts.length);
  assert.deepEqual(
    forward.rulings.map((r) => r.fact.claim).sort(),
    reverse.rulings.map((r) => r.fact.claim).sort(),
  );
});

test("identical claims on one key are CORROBORATION, not CONFLICT", () => {
  const a = withField({ claim: "the delivery log carries 12 rows" });
  const { conflicts, rulings } = adjudicateAll([a, { ...a }], { execute: false });
  assert.equal(conflicts.length, 0, "agreement is not a defect");
  assert.ok(rulings.every((r) => r.verdict === VERDICTS.ADMITTED));
});

test("different subjects never collide, however similar the claims", () => {
  const a = withField({ subject: "api/lib/a.ex rows", claim: "12 rows" });
  const b = withField({ subject: "api/lib/b.ex rows", claim: "9 rows" });
  assert.equal(adjudicateAll([a, b], { execute: false }).conflicts.length, 0);
});

test("a REJECTED fact never enters conflict detection", () => {
  const good = withField({ claim: "the delivery log carries 12 rows" });
  const poisoned = withField({ claim: "", quantity: CLEAN.quantity });
  const { conflicts } = adjudicateAll([good, poisoned], { execute: false });
  assert.equal(conflicts.length, 0, "a malformed fact cannot rival a well-formed one");
});

test("detectConflicts is a no-op on a single fact and on an empty list", () => {
  assert.deepEqual(detectConflicts([]), []);
  const one = [adjudicate(CLEAN, { execute: false })];
  assert.equal(detectConflicts(one)[0].verdict, VERDICTS.ADMITTED);
});

// ── D4 — the wording is jurisdiction, not style ──────────────────────────────

test("no file in tooling/grip uses the banned authorship wording (D4)", () => {
  // The needle is ASSEMBLED at runtime, never written as one literal: the
  // acceptance check is a literal `grep -rn ... tooling/grip/`, so a test that
  // spelled the banned phrase would match ITSELF and turn a real ban into a
  // permanent false positive. Same reason adjudicate.mjs's header describes
  // the rule instead of quoting it.
  const banned = ["verified", "read"].join(" ");
  const grep = spawnSync("grep", ["-rn", banned, GRIP], { encoding: "utf8" });
  assert.equal(grep.status, 1, `expected no matches, got:\n${grep.stdout}`);
});

test("an executed ruling says 're-derived just now', never anything stronger", () => {
  const ruling = adjudicate(CLEAN, { run: stub(VERDICT.OK) });
  assert.match(ruling.note, /re-derived just now/);
  assert.match(ruling.note, /not that the author ran it/);
});

// ── D25 — the honesty of the CONFLICT disclaimer is itself gated ─────────────

test("the code states plainly that no live caller populates subject/quantity", () => {
  const src = readFileSync(join(GRIP, "adjudicate.mjs"), "utf8");
  assert.match(src, /NOT WIRED INTO THE LIVE FACT FLOW/);
  assert.match(src, /NO LIVE CALLER POPULATES/);
});

// ── the CLI's three outcome classes (D18) ────────────────────────────────────

function cli(args) {
  return spawnSync(process.execPath, [join(GRIP, "cli.mjs"), ...args], { encoding: "utf8" });
}

test("--selftest exits 0 and every control fires", () => {
  const r = cli(["--selftest"]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /controls fired as designed/);
  assert.equal(r.stdout.includes("FAIL "), false);
  assert.equal(r.stdout.includes("VOID "), false);
});

test("the CLI names all three non-zero outcome classes in its help", () => {
  const r = cli(["--help"]);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /guard failure/);
  assert.match(r.stdout, /control did not behave as a control/);
  for (const name of Object.values(VERDICTS)) assert.ok(r.stdout.includes(name), `help omits ${name}`);
});

test("a missing facts file is exit 2 — usage, never a verdict", () => {
  const r = cli([join(GRIP, "no-such-file.json")]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /cannot read/);
});

// ── D88 — THE CALLER-BOUNDARY SAFETY WIRE ────────────────────────────────────
//
// The default execution runner is screenedRerun: screenCommand decides, and
// only what it admits is handed to runRerun to spawn. These tests would FAIL if
// the wire were reverted to bare runRerun — the marker probe writes a real file,
// so a bypass is observable, not a shape assertion.

// A DANGER-set shape classifySafety ADMITS and runRerun WOULD execute. The
// source exists; the write target is unique per-process so a leaked marker from
// a bypass cannot be confused with another run's.
const MARKER = join(tmpdir(), `grip-rce-marker-${process.pid}`);
const OUTAGE_CP = `cp ${join(GRIP, "record.mjs")} ${MARKER}`;

test("the default runner SCREENS: an outage `cp` is REJECTED before execution and writes NO file", () => {
  rmSync(MARKER, { force: true });
  // Precondition — this is a real bypass detector only while classifySafety
  // WOULD have admitted (and runRerun executed) this exact command.
  assert.equal(classifySafety(OUTAGE_CP).safe, true, "control invalid: classifySafety no longer admits the probe");

  const ruling = adjudicate({ subject: "marker probe", claim: "a discrete claim about the marker", rerun: OUTAGE_CP });

  assert.equal(ruling.verdict, VERDICTS.REJECTED, "an outage command must be REJECTED at the boundary");
  assert.equal(ruling.fact, null, "a refused command yields no standing fact");
  assert.match(ruling.note, /before execution/, "the refusal must be pre-execution");
  assert.equal(existsSync(MARKER), false, "THE SCREEN WAS BYPASSED — the rerun executed and wrote a file (RCE)");
  rmSync(MARKER, { force: true });
});

test("screenedRerun refuses without spawning, and delegates an ADMITTED read to runRerun", () => {
  rmSync(MARKER, { force: true });
  // (a) refusal — nothing ran, shaped to travel EXECUTION_MAP as UNSAFE-RERUN.
  const refused = screenedRerun(OUTAGE_CP);
  assert.equal(refused.verdict, VERDICT.UNSAFE_RERUN);
  assert.equal(refused.ran, false);
  assert.match(refused.reason, /caller boundary/);
  assert.equal(existsSync(MARKER), false, "screenedRerun must not spawn a refused command");
  // (b) delegation — an allowlisted read really executes through runRerun.
  const ran = screenedRerun("grep -c 'reason:' " + join(GRIP, "record.mjs"));
  assert.equal(ran.verdict, VERDICT.OK, `an admitted read should run and return OK, got ${ran.verdict}: ${ran.reason}`);
  assert.equal(ran.ran, true);
});

test("22 named outage probes: classifySafety admits 22/22, the boundary refuses 22/22", () => {
  // The pre-wave-4 named dangers — the shapes classifySafety rated SAFE and the
  // census would have spawned. The count is RE-DERIVED here, never remembered.
  const OUTAGE = DANGER_SET.filter((c) => classifySafety(c).safe).slice(0, 22);
  assert.equal(OUTAGE.length, 22, "expected 22 classifySafety-admitted outage probes");

  const csAdmits = OUTAGE.filter((c) => classifySafety(c).safe).length;
  const screenRefuses = OUTAGE.filter((c) => !screenCommand(c).ok).length;
  const boundaryRejects = OUTAGE.filter(
    (c) => adjudicate({ subject: "p", claim: "a discrete claim about it", rerun: c }).verdict === VERDICTS.REJECTED,
  ).length;

  assert.equal(csAdmits, 22, "classifySafety must admit all 22 (that is the hole)");
  assert.equal(screenRefuses, 22, "the screen must refuse all 22");
  assert.equal(boundaryRejects, 22, "adjudicate's default path must reject all 22 before execution");
});

test("an INJECTED runner still bypasses the screen — proving this is a boundary wire, not a grammar swap", () => {
  // A caller that injects `run` opts out of the screen deliberately (the census
  // owns its own screen; rerun.test.mjs's 35 direct runRerun calls keep their
  // behaviour). Here the stub returns OK for a command the screen WOULD refuse,
  // and the engine honours it — the screen sits on the DEFAULT path only.
  // No level claim, so admission passes (reboot derives L6 → DEMOTED); the stub
  // then stands in for execution. A screened default path would REJECT `reboot`
  // before ever calling a runner, so counter.calls===1 IS the bypass proof.
  const counter = { calls: 0 };
  const ruling = adjudicate({ subject: "power", claim: "a discrete claim about power", rerun: "reboot" }, { run: stub(VERDICT.OK, counter) });
  assert.equal(counter.calls, 1, "the injected runner must be the one consulted, not the screen");
  assert.ok(stands(ruling.verdict), "an injected OK leaves the fact standing — the screen was not consulted");
  assert.notEqual(ruling.verdict, VERDICTS.REJECTED, "the injected path is not screened");
});

test("the D88 caller-boundary: `git -C` read is now ADMITTED, merge-base write is still REFUSED", () => {
  // Split from a single over-refusal loop after tgw4 (GIT_VALUE_GLOBALS /
  // dropValueGlobals, screen.mjs) taught the screen to skip `git`'s value-taking
  // `-C <dir>` global and reach the real sub-verb. The wire inherits the screen
  // verbatim; it does NOT reach into screen.mjs's grammar itself.

  // READ half: `git -C tooling/grip show HEAD:README.md` is a safe read the
  // screen now correctly admits. Assert NOT-REJECTED (not a positive ADMITTED
  // check) so the assertion does not couple to filesystem/git state — only the
  // boundary decision is under test, not whether the read itself succeeds.
  // Reverting dropValueGlobals to identity re-breaks the parse and REDS this.
  const readCmd = "git -C tooling/grip show HEAD:README.md";
  assert.equal(screenCommand(readCmd).ok, true, `the boundary must now admit the safe read: ${readCmd}`);
  const readRuling = adjudicate({ subject: "p", claim: "a discrete claim about it", rerun: readCmd });
  assert.notEqual(readRuling.verdict, VERDICTS.REJECTED, `the admitted read must not be rejected at the boundary: ${readCmd}`);

  // WRITE half: `git merge-base --is-ancestor` still trips the broad \bmerge\b
  // write-verb regex — an intentional over-refusal not touched this wave, filed
  // separately as pds-bl-grip-screen-refuses-honest-read-commands. Permanently
  // pinned here as intended: dropping `merge` from the write-verb regex REDS this.
  const writeCmd = "git merge-base --is-ancestor HEAD origin/main";
  assert.equal(screenCommand(writeCmd).ok, false, `the boundary must still refuse the write shape: ${writeCmd}`);
  const writeRuling = adjudicate({ subject: "p", claim: "a discrete claim about it", rerun: writeCmd });
  assert.equal(writeRuling.verdict, VERDICTS.REJECTED, `over-refused (fails closed), not executed: ${writeCmd}`);
});
