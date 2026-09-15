// design/check-selftest.mjs — the negative half of design/check.mjs.
//
// Run it as `node design/check.mjs --selftest`; this module is the body behind
// that switch. It exists because design/check.mjs spent its whole life with
// NOTHING exercising it, and produced two defect rows in one day, both in its
// ok-summary reporting and both proven with a harness the builder then threw
// away: task-6a265c12a8589702 (a part printed `ok` beside its own FAIL lines) and
// task-60500d9c1893efb8 (Part B suppressed a TRUE `ok`). Opposite signs, same
// class — nobody could ask the gate "can you still fail?".
//
// WHAT IT ASSERTS, and why it is these two directions and not one. An ok-summary
// is a claim about ONE part, so it has two ways to lie:
//
//   FALSE REASSURANCE  a part that FAILED still prints its ok.
//   FALSE SILENCE      a part that PASSED withholds its ok because something
//                      EARLIER in the run failed. The exit code is right either
//                      way, so nothing ships wrongly — but a reader debugging a
//                      red run cannot tell "this part passed and was suppressed"
//                      from "this part never ran", and a diagnostic that reads
//                      the same for two different states is not a diagnostic.
//
// A selftest that only drives the healthy path re-creates exactly the blind spot
// it is meant to close, so every arm below is a run in which SOMETHING fails.
//
// HOW IT FORCES A FAILURE WITHOUT TOUCHING THE REPO. design/check.mjs reads
// BP_DESIGN_CHECK_FAULT — a comma-separated set of part letters, each of which
// makes that part record ONE EXTRA failure at the point it records its own. The
// hook can only ADD a failure, never suppress one, so no value of that variable
// can mute a real drift; the worst a stray setting in CI does is red the gate.
// Nothing is written anywhere: each arm is one ~0.3s subprocess against the real
// tree, so the arms also prove the gate still parses and still runs end to end.
//
// PROVEN ABLE TO FAIL, both directions, measured before it was trusted:
//   • give Part B back its old `if (!failed)` (no snapshot) and the fault=A arm
//     reds, naming Part B — that is the false-silence defect reproducing;
//   • delete Part B's snapshot gate so the ok is unconditional, or neuter Part
//     B's or Part D's failure path, and the fault=B / fault=D arms red, naming
//     the part. Relaxing an assertion here to match reality deletes the test.

import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DESIGN_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(DESIGN_DIR, "..");
const CHECK = join(DESIGN_DIR, "check.mjs");

// The ok-summary line each part prints when IT passed. Matched on a stable
// phrase, never on a line number or a count, so a new lifecycle state or a new
// provider does not silently stop this selftest from finding the line it is
// asserting about — an ok line that moved would read as an ok line that vanished.
const OK_LINE = {
  B: "lifecycle states agree across Go + CSS + Studio",
  D: "provider marks agree across CSS + Go + tokens",
};

// What the injected failure prints, per part. Asserting this is the PRECONDITION
// check: without it, "Part B's ok did not print" could equally mean the fault
// never landed and Part B never ran at all.
const FAULT_LINE = {
  A: "FAIL Part A: injected fault (--selftest)",
  B: "§6 FAIL Part B: injected fault (--selftest)",
  D: "Part D FAIL: injected fault (--selftest)",
};

/** One run of the real gate. `faults` is the array of part letters to force. */
function runGate(faults) {
  const env = { ...process.env };
  if (faults.length) env.BP_DESIGN_CHECK_FAULT = faults.join(",");
  else delete env.BP_DESIGN_CHECK_FAULT;
  const r = spawnSync(process.execPath, [CHECK], {
    cwd: REPO_ROOT,
    env,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) throw new Error(`could not run ${CHECK}: ${r.error.message}`);
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

export async function selftest() {
  const checks = [];
  const check = (name, fn) => checks.push({ name, fn });

  // Every arm asserts the subprocess REACHED the parts it is judging. A missing
  // ok line and a gate that crashed in Part 0 look identical otherwise.
  const ran = (r, what) => {
    if (!r.stdout.includes("Part A: per-surface byte parity")) {
      throw new Error(`${what}: the gate never reached Part A — it printed:\n${r.stdout}\n${r.stderr}`);
    }
  };
  const landed = (r, part, what) => {
    if (!r.stderr.includes(FAULT_LINE[part])) {
      throw new Error(`${what}: the injected Part ${part} fault did not land — expected ${JSON.stringify(FAULT_LINE[part])} on stderr`);
    }
  };
  const hasOk = (r, part, what) => {
    if (!r.stdout.includes(OK_LINE[part])) throw new Error(`${what}: Part ${part} did NOT print its ok line and should have`);
  };
  const noOk = (r, part, what) => {
    if (r.stdout.includes(OK_LINE[part])) throw new Error(`${what}: Part ${part} printed its ok line while Part ${part} itself failed`);
  };
  const red = (r, what) => {
    if (r.status === 0) throw new Error(`${what}: the gate exited 0 with a forced failure in it`);
  };

  // --- the control: a healthy run, so a missing ok line below means something --
  check("healthy tree: the gate exits 0 and Parts B and D both print their ok", () => {
    const r = runGate([]);
    ran(r, "healthy");
    if (r.status !== 0) throw new Error(`healthy: the gate exited ${r.status} on an unmutated tree:\n${r.stderr}`);
    if (r.stdout.includes("injected fault") || r.stderr.includes("injected fault")) {
      throw new Error("healthy: an injected fault appeared with BP_DESIGN_CHECK_FAULT unset — the hook is not off by default");
    }
    hasOk(r, "B", "healthy");
    hasOk(r, "D", "healthy");
  });

  // --- direction 1: a part that FAILED must withhold its own ok ---------------
  check("Part B fails: its ok is withheld, and Part D's ok still prints", () => {
    const r = runGate(["B"]);
    ran(r, "fault=B");
    landed(r, "B", "fault=B");
    red(r, "fault=B");
    noOk(r, "B", "fault=B");
    hasOk(r, "D", "fault=B");
  });

  check("Part D fails: its ok is withheld, and Part B's ok still prints", () => {
    const r = runGate(["D"]);
    ran(r, "fault=D");
    landed(r, "D", "fault=D");
    red(r, "fault=D");
    noOk(r, "D", "fault=D");
    hasOk(r, "B", "fault=D");
  });

  // --- direction 2: a part that PASSED must print its ok anyway ---------------
  // This is the arm that reds on the pre-fix tree. Part A fails, Parts B and D
  // pass; with Part B reading the run-wide `failed` its TRUE ok vanished here.
  check("an EARLIER part fails: Parts B and D still print their ok (false silence)", () => {
    const r = runGate(["A"]);
    ran(r, "fault=A");
    landed(r, "A", "fault=A");
    red(r, "fault=A");
    hasOk(r, "B", "fault=A");
    hasOk(r, "D", "fault=A");
  });

  // --- and both at once, so neither arm is passing by accident of ordering ----
  check("Parts A and B both fail: Part B withholds its ok, Part D keeps its own", () => {
    const r = runGate(["A", "B"]);
    ran(r, "fault=A,B");
    landed(r, "A", "fault=A,B");
    landed(r, "B", "fault=A,B");
    red(r, "fault=A,B");
    noOk(r, "B", "fault=A,B");
    hasOk(r, "D", "fault=A,B");
  });

  let passed = 0;
  for (const c of checks) {
    try {
      c.fn();
    } catch (e) {
      console.error(`FAIL ${c.name}\n     ${e.message}`);
      console.error(`\ndesign/check.mjs --selftest: FAILED — ${passed}/${checks.length} passed before this one.`);
      return false;
    }
    passed += 1;
    console.log(`ok   ${c.name}`);
  }
  console.log(`design/check.mjs --selftest: ${passed}/${checks.length} passed — the ok-summary gating still fails in both directions.`);
  return true;
}
