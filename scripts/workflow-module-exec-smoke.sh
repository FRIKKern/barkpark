#!/usr/bin/env bash
# workflow-module-exec-smoke.sh — the EXECUTION gate for
# .claude/workflows/*.workflow.js. It is the deliberate companion to
# workflow-module-smoke.sh, not its replacement.
#
# WHY THIS EXISTS
# ---------------
# Every gate this repo had for these engines PARSES them and stops. Both
# workflow-module-smoke.sh and workflow-portability-check.sh build an
# AsyncFunction from the source and never call it — their own headers say so
# ("Construction parses without executing"; "The compiled function is NEVER
# invoked; this is a syntax check, not a run"). That is correct for what they
# check, and it is structurally blind to an entire class of defect:
#
#   a module-scope TEMPORAL DEAD ZONE error is a RUNTIME ReferenceError.
#   Nothing that only parses can ever see one.
#
# Reproduced on main the day this script was written:
#
#   $ cat > mut.workflow.js
#   export const meta = { name: 'tdz-mutant', description: 'x', phases: [] }
#   const USES_IT = `${LATER_CONST}`        // TDZ: used before declaration
#   const LATER_CONST = 'defined after its use'
#
#   $ bash scripts/workflow-module-smoke.sh mut.workflow.js
#   MODULE-SCOPE-OK        exit=0          <- blind
#
# NOT HYPOTHETICAL: commit f8977af85c is "declare JOURNEY_FIELD/FABLE_STAMPS
# before first schema use — module-scope TDZ crash". The class has already taken
# this engine out once. The harness that caught it then executed module scope
# with stub globals and was never committed; this script is that harness, made
# permanent.
#
# A SECOND THING IT UNBLINDS, for free: these engines carry module-scope
# STRUCTURAL TRIPWIRES that `throw` (bp-epic-cycle.workflow.js has 13 of them —
# "declares required key '<k>' but does not define it in properties", and the
# JOURNEY_FIELD identity checks from #6086). Every one of them is dead code
# under a parse-only gate. Executing module scope is what arms them in CI.
#
# ────────────────────────────────────────────────────────────────────────────
# HOW IT STOPS BEFORE SPENDING MONEY — read this before touching STUBS
# ────────────────────────────────────────────────────────────────────────────
# These engines are NOT "declarations plus an exported entry point". They are
# linear scripts: module scope declares the schemas and then ORCHESTRATES, and
# `const strategist = await neverLose((m) => agent(...))` sits at top level.
# Running the whole body would spawn real agents and bill real money on a CI
# runner.
#
# So the run is FENCED at the first spend. `agent`, `parallel` and `pipeline`
# are stubbed to throw a private SENTINEL; reaching one means "module scope
# executed cleanly all the way to the first spend" and is the PASS. The
# announcement-only globals (`phase`, `log`) and the meter (`budget.spent()`)
# are inert stubs rather than sentinels, deliberately: sentinelling `phase`
# would stop the run at the first phase announcement and forfeit every
# declaration after it. Measured on the live corpus, the announcement-inert
# table executes each engine's ENTIRE declaration region — for
# bp-epic-cycle.workflow.js that is lines 1-~630, first `agent()` call, versus
# line 630 if `phase` were the fence.
#
# An UNKNOWN free global is a FAIL, never a skip (portability clause N: a blind
# check must never pass by looking away). The message names the identifier and
# tells you to add it to STUBS, so a new runner API lands as an actionable red
# rather than a mystery.
#
# WHAT THIS DOES NOT CLAIM. Reaching the first spend proves module scope LOADS.
# It does not execute any phase body, does not validate agent output, and does
# not prove the wave works. It is a load-bearing floor, not a verdict.
#
# MUTATION-PROVEN: scripts/workflow-module-exec-smoke.test.sh is the fail-before
# proof — a TDZ mutant and a schema-tripwire mutant that BOTH pass the
# parse-only gate and BOTH red here, plus controls.
#
# USAGE:
#   scripts/workflow-module-exec-smoke.sh                      # every engine
#   scripts/workflow-module-exec-smoke.sh path/to/one.js [...] # only the named
set -euo pipefail

cd "$(dirname "$0")/.."

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  while IFS= read -r f; do files+=("$f"); done < <(find .claude/workflows -maxdepth 1 -name '*.workflow.js' | sort)
fi

if [ ${#files[@]} -eq 0 ]; then
  echo "workflow-module-exec-smoke: no .claude/workflows/*.workflow.js found — nothing to check" >&2
  exit 1
fi

status=0
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL $f — no such file"
    status=1
    continue
  fi
  if err=$(node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8").replace(/^export\s+/gm, "")
    const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

    // The SENTINEL fence. Anything that spends throws this; catching it is the pass.
    const SENTINEL = Symbol("module-scope-reached-first-spend")
    const spendFence = (name) => function () {
      const e = new Error("reached " + name + "()")
      e[SENTINEL] = name
      throw e
    }

    // STUBS — the runner surface these engines close over at module scope.
    // Inert where the call only announces or meters; a fence where it spends.
    // Adding a global here is a deliberate act: see the header.
    const STUBS = {
      args: {
        wish: "workflow-module-exec-smoke: module-scope load check",
        charter_exists: false,
        charter_path: ".claude/workflows/bp-cloud-epic-charter.md",
        epic_task_id: null,
        lead_notes: "",
      },
      phase: () => undefined,
      log: () => undefined,
      budget: { spent: () => 0 },
      agent: spendFence("agent"),
      parallel: spendFence("parallel"),
      pipeline: spendFence("pipeline"),
    }

    const names = Object.keys(STUBS)
    let fn
    try {
      fn = new AsyncFunction(...names, src)
    } catch (e) {
      process.stderr.write("does not parse as a module body — " + e.message)
      process.exit(1)
    }

    fn(...names.map((n) => STUBS[n])).then(
      () => process.exit(0),          // no spend at all: still a clean load
      (e) => {
        if (e && e[SENTINEL]) process.exit(0)
        const msg = e && e.message ? e.message : String(e)
        const kind = e && e.constructor ? e.constructor.name : "Error"
        const undef = /^(\w+) is not defined$/.exec(msg)
        if (undef) {
          process.stderr.write(
            kind + ": " + msg + " — an unstubbed runner global. Add \"" + undef[1] +
            "\" to STUBS in scripts/workflow-module-exec-smoke.sh (inert if it only " +
            "announces, a spendFence if it spends).")
        } else {
          process.stderr.write(kind + ": " + msg)
        }
        process.exit(1)
      },
    )
  ' "$f" 2>&1 >/dev/null); then
    echo "MODULE-EXEC-OK $f"
  else
    echo "FAIL $f — ${err:-module scope threw}"
    status=1
  fi
done

exit $status
