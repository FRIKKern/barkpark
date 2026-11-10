// design/check/part-0.mjs — Part 0 of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { AUDIT_ACTIONS_PATH, auditActions } from "../emit.mjs";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part 0: the audit verb table's own shape (charter cch-w65) ────────────────
// cloud/priv/audit-actions.json is the SOLE authority for TWO vocabularies — the
// server's closed @actions allowlist (read at compile time by AuditEvent) and the
// console's ACTION_LABELS region emitted below. Its shape gate runs FIRST and
// exits immediately, because the ACTION_LABELS build() reads the table: a
// malformed row would otherwise surface as a stack trace from inside Part A
// instead of the one sentence that says which row is wrong and why. The predicate
// is auditActions() itself, so this gate and the emitter cannot disagree about
// what "well-formed" means.
//
// Its verdict is a HEADER line plus a separately-gated `ok` line, the same shape
// every Part below prints, rather than the one fused sentence it printed until
// r21d. The fusion made Part 0 the last Part the selftest could say nothing
// about: the selftest reads a Part's claim off its `  ok   ` lines, and a Part
// with none has nothing for a fault to withhold, so it was named UNEXERCISED on
// every green run. Splitting the sentence costs one line of output and buys the
// arm.
console.log(`design/check.mjs — Part 0: the audit verb table's own shape (${AUDIT_ACTIONS_PATH})`);
{
  const failedBefore0 = failed;
  let rows;
  try {
    rows = auditActions();
  } catch (e) {
    console.error(`design/check.mjs — Part 0 FAIL: ${e.message}`);
    console.error(`
  ${AUDIT_ACTIONS_PATH} is the ONE table both audit vocabularies read. Until it is
  well-formed nothing downstream can be trusted: the console's ACTION_LABELS region is
  built from it and AuditEvent's @actions allowlist is derived from it at compile time.
`);
    process.exit(1);
  }
  const nulls = rows.filter((r) => r.label === null);

  // Part 0's hook is the one that does NOT share the real failure path's exit.
  // A genuinely malformed table exits(1) right here, because everything below
  // reads it; an INJECTED fault must leave the run standing so the selftest can
  // still watch every later Part keep its own ok lines. So the hook records its
  // failure through `fail` — the verdict arm at the bottom still reds the gate on
  // the count — and asks exactly the question the arm is for: does Part 0's ok
  // line answer for Part 0's own failures? The exit path needs no hook: it
  // withholds this ok line by never reaching it.
  if (FAULT.has("0")) fail("  Part 0 FAIL: injected fault (--selftest)");
  if (failed === failedBefore0) {
    console.log(
      `  ok   ${AUDIT_ACTIONS_PATH} well-formed — ${rows.length} declared verbs, ` +
      `${rows.length - nulls.length} labelled, ${nulls.length} declared unlabelled WITH a reason.`,
    );
  }
}
