#!/usr/bin/env bash
# main-gate-watch-route.sh — turn main-gate-watch.sh's rc into A JOB'S verdict,
# so that "main is red" and "this watch has no authority" red under DIFFERENT
# check-run names.
#
# WHY THIS FILE EXISTS (cch-w59-bl-main-gate-watch-has-no-notification-egress)
#
# scripts/main-gate-watch.sh defines four outcomes — 0 green, 1 scream, 2
# waiting, 3 CONFIGURATION FAULT. Until this split, .github/workflows/
# main-gate-watch.yml mapped BOTH 1 and 3 to `exit 1` inside ONE step of ONE job
# named `Main gate watch`. So "main's tip is red" and "this run could not read
# branch protection because BREAKGLASS_TOKEN was rotated" rendered as the SAME
# failing check run. They are different facts with different owners, and a fleet
# that sees the second often enough learns to read the first as noise.
#
# The split is a job split, never a `|| true`: a watch with no authority must
# never report success. Under a fault the WORKFLOW RUN still fails — the fault
# job carries the red — and the `Main gate watch` job is SKIPPED rather than
# green, because "unknown" must not render as "main is fine".
#
# WHY A SCRIPT AND NOT A `case` INLINE IN THE YAML
#
# A routing table living in two `run:` blocks cannot be driven by a harness: you
# cannot force rc=3 and rc=1 on a YAML expression without GitHub. Here, both
# jobs shell THIS file, and scripts/main-gate-watch.test.sh §14 runs it once per
# (role, rc) pair and asserts exactly which role reds — that is the mutation
# proof the row asks for, offline.
#
# CONTRACT
#   main-gate-watch-route.sh fault   <rc>   # the authority job's classifier
#   main-gate-watch-route.sh verdict <rc>   # the tip-greenness job's classifier
#
#   role=fault:    rc 3 -> exit 1 (CONFIGURATION FAULT). rc 0|1|2 -> exit 0:
#                  the read had authority, and whether main is GREEN is the
#                  sibling job's subject, not this one's.
#                  Any other rc -> exit 1: an rc main-gate-watch.sh does not
#                  define is a fault OF THE INSTRUMENT, which is this job's.
#   role=verdict:  rc 0 -> exit 0. rc 1 -> exit 1 (main's tip is not green).
#                  rc 2 -> exit 0 (WAITING; the next scheduled run decides).
#                  rc 3 -> exit 1 as a ROUTING ERROR — the workflow's job-level
#                  `if:` is supposed to SKIP this job on a fault, so reaching
#                  here means the wiring drifted. It reds rather than guessing.
#                  Empty/undefined rc -> exit 1 CANNOT READ, never a silent 0.
set -uo pipefail

usage() {
  echo "usage: main-gate-watch-route.sh <fault|verdict> <rc>" >&2
  echo "  rc is scripts/main-gate-watch.sh's exit code: 0 green, 1 scream, 2 waiting, 3 configuration fault" >&2
}

if [ "$#" -ne 2 ]; then
  echo "CANNOT READ: main-gate-watch-route.sh needs exactly two arguments, got $#" >&2
  usage
  exit 1
fi

role="$1"
rc="$2"

# An rc that is not a plain non-negative integer is never a verdict. `''` is the
# shape a missing `needs.<job>.outputs.rc` takes when the upstream job died
# before its step wrote GITHUB_OUTPUT — the one case where a blank must not read
# as a zero.
case "$rc" in
  ''|*[!0-9]*)
    echo "::error::CANNOT READ — main-gate-watch.sh's exit code did not reach this job (rc='$rc'). The upstream job died before it published one; this is not a verdict about main and is not a pass."
    exit 1
    ;;
esac

case "$role" in
  fault)
    case "$rc" in
      3)
        echo "::error::CONFIGURATION FAULT — this run could not read branch protection, or protection requires a context this watch has never classified in WATCHED_CONTEXTS / EXCLUDED_CONTEXTS. THIS IS NOT A STATEMENT ABOUT MAIN: the sibling check run 'Main gate watch' is SKIPPED for this run precisely because the watch had no authority to judge. Owner: whoever rotated BREAKGLASS_TOKEN or changed branch protection. Fix: restore the secret, or classify the new required context in scripts/main-gate-watch.sh. See docs/ops/merge-gates.md."
        exit 1
        ;;
      0|1|2)
        echo "the watch had authority (main-gate-watch.sh rc=$rc). Whether main's tip is GREEN is the 'Main gate watch' check run's subject, not this one's."
        exit 0
        ;;
      *)
        echo "::error::CONFIGURATION FAULT — main-gate-watch.sh exited $rc, which is not one of the four outcomes it defines (0 green, 1 scream, 2 waiting, 3 fault). An undefined rc is a fault of the instrument, so it reds HERE and not on the sibling."
        exit 1
        ;;
    esac
    ;;
  verdict)
    case "$rc" in
      0)
        echo "main's tip carries a green verdict on every watched required context."
        exit 0
        ;;
      1)
        echo "::error::MAIN'S TIP DOES NOT CARRY A GREEN VERDICT on every watched required context (RED, or MISSING — never judged). This run fails, and it will keep failing on every scheduled run (delivered every 2-5 h, see the schedule header) until the tip is green."
        exit 1
        ;;
      2)
        echo "::notice::WAITING — a watched context on main's tip is still running, or its row has not been created yet while a workflow run on the tip is still in flight. The next scheduled run decides."
        exit 0
        ;;
      3)
        echo "::error::ROUTING ERROR — rc=3 is a CONFIGURATION FAULT and this job's \`if:\` is supposed to SKIP it on one, leaving the scream to the 'Main gate watch configuration fault' check run. Reaching here means .github/workflows/main-gate-watch.yml's job wiring drifted from scripts/main-gate-watch.test.sh §14. Reds rather than reporting a verdict it does not have."
        exit 1
        ;;
      *)
        echo "::error::main-gate-watch.sh exited $rc, which is not a verdict it defines"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "CANNOT READ: unknown role '$role' — expected 'fault' or 'verdict'" >&2
    usage
    exit 1
    ;;
esac
