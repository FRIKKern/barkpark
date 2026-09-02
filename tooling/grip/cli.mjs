#!/usr/bin/env node
// cli.mjs — the grip gate's command-line face.
//
//   node tooling/grip/cli.mjs <facts.json>   adjudicate a file of facts
//   node tooling/grip/cli.mjs --selftest     prove the guard can still fail
//   node tooling/grip/cli.mjs --help
//
// EXIT CODES — three outcome classes, not two (charter D18):
//
//   0  clean. Every fact stands, or every control fired exactly as designed.
//   1  a GUARD FAILURE. A planted bad fact was admitted, a verdict was
//      mis-named, or (in adjudicate mode) a fact did not stand.
//   2  usage / IO — nothing was adjudicated. Never confused with a verdict.
//   3  CONTROL DID NOT BEHAVE AS A CONTROL. The control's own precondition
//      broke, so its result proves NOTHING and must never be absorbed into a
//      normal pass. This is the DEMOTED idea applied to the test harness.
//
// The distinction 1-vs-3 is the whole point: exit 1 says "the guard is broken",
// exit 3 says "we do not know whether the guard is broken, because the
// experiment was invalid". A harness that cannot say the second one reports
// green when its own fixtures rot.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { adjudicate, adjudicateAll, VERDICTS, stands } from "./adjudicate.mjs";
import { deriveLevel } from "./level.mjs";
import { VERDICT } from "./rerun.mjs";
// Used ONLY inside the isMain block below, and only against stderr (D78).
import { emitProvenance } from "./provenance.mjs";

const EXIT = { OK: 0, GUARD_FAILURE: 1, USAGE: 2, CONTROL_INVALID: 3 };

// ── selftest fixtures ────────────────────────────────────────────────────────
//
// Every planted-defect control is a matched PAIR: a clean fact and its poisoned
// twin, differing in exactly one field. The clean twin is the control's
// precondition — if IT stops being admitted, the poisoned twin's rejection
// proves nothing (it could be rejecting for the shared reason), and the run
// exits 3 rather than reporting a pass.

const CLEAN = Object.freeze({
  subject: "tooling/grip/record.mjs admitFact",
  quantity: "8 named rejection reasons",
  claim: "admitFact emits exactly 8 distinct rejection reasons",
  evidence: "read the source and counted the rejections.push sites",
  rerun: "grep -c 'reason:' tooling/grip/record.mjs",
  level: "L3",
});

const withField = (patch) => ({ ...CLEAN, ...patch });

const PLANTED = [
  {
    name: "LEVEL-SKIP — an L1 claim over an L2 command",
    clean: withField({ rerun: "git show origin/main:tooling/grip/record.mjs", level: "L2" }),
    poisoned: withField({ rerun: "git show origin/main:tooling/grip/record.mjs", level: "L1" }),
    expectReason: "LEVEL-SKIP",
    // The control only tests a level SKIP if the command really derives L2.
    precondition: (c) => deriveLevel(c.clean.rerun) === "L2",
    preconditionWhy: "the clean twin's command must derive L2 for an L1 claim to be a skip",
  },
  {
    name: "PATHLESS-REF — a bare filename:line in the subject",
    clean: withField({ subject: "cloud/lib/barkpark_cloud/notifications.ex:389-397 delivery log" }),
    poisoned: withField({ subject: "notifications.ex:389-397 delivery log" }),
    expectReason: "PATHLESS-REF",
    precondition: () => true,
    preconditionWhy: "",
  },
  {
    name: "INADMISSIBLE-CONTINUOUS — a float+unit quantity with no predicate",
    clean: withField({ quantity: "t_total < 2s", claim: "the query returns under the 2s ceiling" }),
    poisoned: withField({ quantity: "t_total 1.84s", claim: "the query took 1.84s" }),
    expectReason: "INADMISSIBLE-CONTINUOUS",
    precondition: () => true,
    preconditionWhy: "",
  },
  {
    name: "MISSING-SUBJECT — a fact that names nothing",
    clean: withField({}),
    poisoned: withField({ subject: "   " }),
    expectReason: "MISSING-SUBJECT",
    precondition: () => true,
    preconditionWhy: "",
  },
  {
    name: "MISSING-CLAIM — a fact that asserts nothing",
    clean: withField({}),
    poisoned: withField({ claim: "" }),
    expectReason: "MISSING-CLAIM",
    precondition: () => true,
    preconditionWhy: "",
  },
];

// Verdict pass-through controls. A stub runner stands in for real execution so
// the MAPPING is provable without a network, a host, or a clock. The stub also
// COUNTS its invocations: a mapping control whose runner was never called did
// not test the mapping, and that is an exit-3 condition, never a pass.
//
// EACH ROW NOW CARRIES BOTH HALVES (charter D127). A plant alone proves the
// mapping can FIRE; it cannot distinguish a live mapping from one that returns
// its verdict unconditionally. So every row also names a NEIGHBOUR executor
// verdict that must NOT produce this row's verdict — the never-cry-wolf half.
//
// This is a PROJECTION, not new coverage: six of these seven already have both
// halves under test (DEMOTED adjudicate.test.mjs:128/:136 + :144; FAILED
// rerun.test.mjs:292 + :152; HOST-UNREACHABLE :49 + :79; UNAVAILABLE
// adjudicate.test.mjs:188 + :190; NULL-READ rerun.test.mjs:167 + :183;
// ASYNC-DEFERRED :430 + :86). What was missing is that `--selftest` — the
// surface the acceptance criterion actually reads — showed only the plants.
const PASSTHROUGH = [
  { name: "FAILED is not REJECTED", executorVerdict: VERDICT.FAILED, expect: VERDICTS.FAILED, neighbour: VERDICT.WRONG_ROUTE },
  { name: "REACHABLE-WRONG-ROUTE passes through", executorVerdict: VERDICT.WRONG_ROUTE, expect: VERDICTS.WRONG_ROUTE, neighbour: VERDICT.UNREACHABLE },
  { name: "HOST-UNREACHABLE passes through", executorVerdict: VERDICT.UNREACHABLE, expect: VERDICTS.UNREACHABLE, neighbour: VERDICT.WRONG_ROUTE },
  { name: "UNAVAILABLE passes through", executorVerdict: VERDICT.UNAVAILABLE, expect: VERDICTS.UNAVAILABLE, neighbour: VERDICT.ASYNC_DEFERRED },
  { name: "NULL-READ passes through", executorVerdict: VERDICT.NULL_READ, expect: VERDICTS.NULL_READ, neighbour: VERDICT.FAILED },
  { name: "ASYNC-DEFERRED passes through", executorVerdict: VERDICT.ASYNC_DEFERRED, expect: VERDICTS.ASYNC_DEFERRED, neighbour: VERDICT.UNAVAILABLE },
  { name: "UNSAFE-RERUN is REJECTED, not FAILED", executorVerdict: VERDICT.UNSAFE_RERUN, expect: VERDICTS.REJECTED, neighbour: VERDICT.FAILED },
];

// The DEMOTED control, which had no half at all in this selftest.
//
// The discriminator is whether the COMMAND classifies, never whether the author
// asked for a low level. `frobnicate --all` derives L6, so the fact stands but
// is DEMOTED. The near-miss is the honest UNDER-claim: L6 claimed over a command
// that DOES classify is ADMITTED at L6 and must never be reported as a demotion,
// or every modest author gets accused of losing authority they never claimed.
const DEMOTION = {
  name: "DEMOTED — an unclassifiable command demotes; an honest UNDER-claim does not",
  plant: () => withField({ rerun: "frobnicate --all", level: "L6" }),
  nearMiss: () => withField({ level: "L6" }),
};

function stubRunner(verdict, counter) {
  return (command) => {
    counter.calls += 1;
    return { command, verdict, ms: 0, reason: `stubbed ${verdict}`, ran: verdict !== VERDICT.UNAVAILABLE };
  };
}

// ── selftest ─────────────────────────────────────────────────────────────────

function selftest() {
  const failures = [];  // guard is broken           → exit 1
  const invalid = [];   // control is not a control  → exit 3
  const lines = [];
  const ok = (name, detail) => lines.push(`  ok    ${name}${detail ? ` — ${detail}` : ""}`);
  const bad = (name, detail) => { lines.push(`  FAIL  ${name} — ${detail}`); failures.push(`${name}: ${detail}`); };
  const void_ = (name, detail) => { lines.push(`  VOID  ${name} — ${detail}`); invalid.push(`${name}: ${detail}`); };

  lines.push("planted-defect controls (each a clean/poisoned pair):");
  for (const c of PLANTED) {
    if (!c.precondition(c)) {
      void_(c.name, `precondition broke — ${c.preconditionWhy}`);
      continue;
    }
    const cleanRuling = adjudicate(c.clean, { execute: false });
    if (!stands(cleanRuling.verdict)) {
      void_(c.name, `the CLEAN twin was ${cleanRuling.label}, so the poisoned twin's rejection proves nothing`);
      continue;
    }
    const ruling = adjudicate(c.poisoned, { execute: false });
    if (ruling.verdict !== VERDICTS.REJECTED) {
      bad(c.name, `planted defect was ${ruling.label}, expected REJECTED:${c.expectReason}`);
    } else if (!ruling.reasons.includes(c.expectReason)) {
      bad(c.name, `rejected as ${ruling.label} — the right outcome for the wrong reason, expected ${c.expectReason}`);
    } else {
      ok(c.name, ruling.label);
    }
  }

  lines.push("verdict pass-through controls (stubbed executor; each a plant + a never-cry-wolf neighbour):");
  for (const c of PASSTHROUGH) {
    const counter = { calls: 0 };
    const ruling = adjudicate(CLEAN, { run: stubRunner(c.executorVerdict, counter) });
    if (counter.calls === 0) {
      void_(c.name, "the stub executor was never invoked — this control tested nothing");
      continue;
    }

    // The NEVER-CRY-WOLF half. A mapping that returned its verdict whatever the
    // executor said would pass the plant above and be indistinguishable from a
    // live one, so the same control is driven with a NEIGHBOUR verdict and must
    // NOT answer this row's verdict.
    const nearCounter = { calls: 0 };
    const near = adjudicate(CLEAN, { run: stubRunner(c.neighbour, nearCounter) });
    if (nearCounter.calls === 0) {
      void_(c.name, "the near-miss stub executor was never invoked — the never-cry-wolf half tested nothing");
      continue;
    }

    if (ruling.verdict !== c.expect) {
      bad(c.name, `executor said ${c.executorVerdict}, engine ruled ${ruling.label}, expected ${c.expect}`);
    } else if (near.verdict === c.expect) {
      bad(c.name, `CRIES WOLF: the neighbour ${c.neighbour} ALSO ruled ${c.expect} — the mapping is unconditional, not a mapping`);
    } else {
      ok(c.name, `${c.executorVerdict} → ${ruling.label} · neighbour ${c.neighbour} → ${near.label}, not ${c.expect}`);
    }
  }

  lines.push("demotion control (plant + near-miss):");
  {
    const planted = adjudicate(DEMOTION.plant(), { execute: false });
    const nearMiss = adjudicate(DEMOTION.nearMiss(), { execute: false });
    if (!stands(nearMiss.verdict)) {
      void_(DEMOTION.name, `the UNDER-claim twin was ${nearMiss.label}, so the demotion below proves nothing about demotion`);
    } else if (planted.verdict !== VERDICTS.DEMOTED) {
      bad(DEMOTION.name, `an unclassifiable command ruled ${planted.label}, expected ${VERDICTS.DEMOTED}`);
    } else if (nearMiss.verdict === VERDICTS.DEMOTED) {
      bad(DEMOTION.name, "CRIES WOLF: an honest UNDER-claim over a classifying command was reported as a demotion");
    } else {
      ok(DEMOTION.name, `${planted.label} at ${planted.level} · under-claim → ${nearMiss.label} at ${nearMiss.level}`);
    }
  }

  lines.push("CONFLICT control (hand-built fixtures; not wired into any live flow):");
  const rivalA = withField({ claim: "the delivery log carries 12 rows", rerun: "grep -c row tooling/grip/record.mjs" });
  const rivalB = withField({ claim: "the delivery log carries 9 rows", rerun: "grep -c row tooling/grip/record.mjs" });
  const soloPre = [rivalA, rivalB].map((f) => adjudicate(f, { execute: false }));
  if (!soloPre.every((r) => r.verdict === VERDICTS.ADMITTED)) {
    void_("CONFLICT", `a rival fixture did not admit on its own (${soloPre.map((r) => r.label).join(", ")}) — a conflict between non-facts proves nothing`);
  } else {
    const { rulings, conflicts } = adjudicateAll([rivalA, rivalB], { execute: false });
    if (conflicts.length !== 2) {
      bad("CONFLICT flags BOTH facts", `${conflicts.length} flagged, expected 2`);
    } else if (!rulings.every((r) => r.fact !== null)) {
      bad("CONFLICT keeps BOTH facts", "a conflicting fact was dropped — write order must never resolve a conflict");
    } else {
      ok("CONFLICT flags and keeps both", rulings.map((r) => r.underlying).join(" + "));
    }
    // Corroboration must NOT be flagged, or every agreement becomes noise.
    const corroborated = adjudicateAll([rivalA, { ...rivalA }], { execute: false });
    if (corroborated.conflicts.length !== 0) {
      bad("identical claims are CORROBORATION", `${corroborated.conflicts.length} flagged, expected 0`);
    } else {
      ok("identical claims are CORROBORATION, not CONFLICT", "0 flagged");
    }
  }

  lines.push("vocabulary control:");
  const names = Object.values(VERDICTS);
  if (names.length !== 10 || new Set(names).size !== 10) {
    bad("the vocabulary is ten distinct names", `found ${names.length} (${new Set(names).size} distinct): ${names.join(", ")}`);
  } else {
    ok("ten distinct verdict names", names.join(" "));
  }

  const banner = invalid.length > 0
    ? "CONTROL DID NOT BEHAVE AS A CONTROL"
    : failures.length > 0
      ? "GUARD FAILURE"
      : "clean";

  process.stdout.write(`grip --selftest — ${banner}\n${lines.join("\n")}\n`);

  if (invalid.length > 0) {
    process.stdout.write(
      `\nCONTROL DID NOT BEHAVE AS A CONTROL (${invalid.length}):\n` +
      invalid.map((s) => `  - ${s}`).join("\n") +
      "\nThese controls' preconditions broke, so their results prove NOTHING. This is not a pass and not a\n" +
      "guard failure — the experiment was invalid. Repair the fixture before trusting any verdict here.\n"
    );
    return EXIT.CONTROL_INVALID;
  }
  if (failures.length > 0) {
    process.stdout.write(
      `\nGUARD FAILURE (${failures.length}):\n` + failures.map((s) => `  - ${s}`).join("\n") + "\n"
    );
    return EXIT.GUARD_FAILURE;
  }
  process.stdout.write(`\nall ${lines.filter((l) => l.startsWith("  ok")).length} controls fired as designed.\n`);
  return EXIT.OK;
}

// ── adjudicate mode ──────────────────────────────────────────────────────────

function adjudicateFile(path, { execute }) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (err) {
    process.stderr.write(`grip: cannot read ${path} — ${err.message}\n`);
    return EXIT.USAGE;
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    process.stderr.write(`grip: ${path} is not valid JSON — ${err.message}\n`);
    return EXIT.USAGE;
  }

  const facts = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.facts) ? parsed.facts : null;
  if (facts === null) {
    process.stderr.write(`grip: ${path} must be a JSON array of facts, or an object with a "facts" array\n`);
    return EXIT.USAGE;
  }
  if (facts.length === 0) {
    process.stdout.write(`grip: ${path} carries no facts — nothing to adjudicate.\n`);
    return EXIT.OK;
  }

  const { rulings, counts } = adjudicateAll(facts, { execute });

  for (const [i, r] of rulings.entries()) {
    const subject = (r.fact?.subject ?? facts[i]?.subject ?? "(no subject)").toString().slice(0, 72);
    process.stdout.write(`${String(i + 1).padStart(3)}  ${r.label.padEnd(28)} ${subject}\n`);
    if (r.note) process.stdout.write(`     ${r.note}\n`);
  }

  const summary = Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(", ");
  const notStanding = rulings.filter((r) => !stands(r.verdict)).length;
  process.stdout.write(`\n${rulings.length} facts — ${summary}\n`);
  if (!execute) process.stdout.write("(admission only — no command was re-run in this pass)\n");

  return notStanding > 0 ? EXIT.GUARD_FAILURE : EXIT.OK;
}

// ── entry ────────────────────────────────────────────────────────────────────

const HELP = `grip — adjudicate source-of-truth facts

  node tooling/grip/cli.mjs <facts.json> [--no-execute]
  node tooling/grip/cli.mjs --selftest
  node tooling/grip/cli.mjs --help

Verdicts: ${Object.values(VERDICTS).join(" ")}

A verdict certifies RE-DERIVABILITY — that the recorded command, run again,
answers at the recorded level. It never certifies that the author ran it.

Exit: 0 clean · 1 guard failure · 2 usage/IO · 3 control did not behave as a control
`;

function main(argv) {
  const args = argv.slice(2);
  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    process.stdout.write(HELP);
    return args.length === 0 ? EXIT.USAGE : EXIT.OK;
  }
  if (args.includes("--selftest")) return selftest();

  const execute = !args.includes("--no-execute");
  const path = args.find((a) => !a.startsWith("-"));
  if (!path) {
    process.stderr.write("grip: no facts file given\n" + HELP);
    return EXIT.USAGE;
  }
  return adjudicateFile(path, { execute });
}

// THE ENTRY GUARD, AND THE DEFECT IT CLOSES.
//
// This file used to end with a BARE `process.exit(main(process.argv))` at module
// scope — the only runnable script in tooling/grip without a main-module test.
// Proven live before the fix: `node -e "import('./tooling/grip/cli.mjs').then(…)"`
// printed the HELP text and exited 2, so the importer's own `.then()`/`.catch()`
// never ran. cli.mjs could be SPAWNED but never IMPORTED — anything that wanted
// to reuse a function from here got a help screen and a dead process instead.
//
// The test is the `resolve()` form census.mjs uses, not the URL string-compare:
// comparing `file://${process.argv[1]}` against `import.meta.url` differs for
// any character the URL encodes (a space, a `#`), and the failure is SILENT —
// the CLI becomes a no-op that exits 0 having adjudicated nothing, which reads
// exactly like a clean run. That is this epic's own defect class.
const isMain = process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  // FIRST ACT (D78) — before a single verdict is printed, say which tree is
  // doing the adjudicating. STDERR only; stdout carries the verdicts.
  emitProvenance();
  // NO process.exit HERE (charter D92, the ruling ledger.mjs's entry guard
  // already applies). main() writes the HELP screen and every adjudication
  // verdict to stdout, and Node writes a PIPE asynchronously: process.exit()
  // throws away whatever has not yet reached the kernel, so `grip facts.json |
  // less` can hand back a report that stops mid-verdict while the same run
  // redirected to a file is whole — and a truncated verdict list reads like a
  // shorter adjudication, not like a failure. exitCode leaves the STATUS
  // identical in every arm (EXIT.OK, EXIT.USAGE, whatever adjudicateFile or
  // selftest returns) and lets the event loop drain stdout on the natural exit.
  // exit-race.test.mjs is the pin.
  process.exitCode = main(process.argv);
}

// Exported so this module is USABLE by an importer, which is the whole point of
// the guard above. Importing must never adjudicate anything by itself.
export { main, HELP, EXIT, selftest, adjudicateFile };
