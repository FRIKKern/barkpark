#!/usr/bin/env bash
#
# run-instrument.sh — the ONE place a CI step reads an instrument's exit code
# as a VOCABULARY rather than as a boolean.
#
#     bash scripts/run-instrument.sh <slug> -- <command> [args…]
#
# The house three-code vocabulary, which `cloud-path-escape-check.sh`,
# `migration-version-collision-check.sh`, `failure-copy-scrub-order-check.sh`
# and `cli-dns-step-vocabulary-check.sh` all declare in their own headers:
#
#     0   MEASURED-CLEAN   it measured, and found nothing wrong
#     1   MEASURED-DEFECT  it measured, and found a defect
#     2   REFUSED          it could NOT measure — it makes NO claim in either
#                          direction. Not a clean bill and not an accusation.
#     *   UNKNOWN          any other code: a crash, a signal, an interpreter
#                          that never started. Treated as a refusal, because
#                          the one thing we know is that no verdict was reached.
#
# WHAT IT DOES WITH THAT
#   * Writes `verdict=<WORD>` and `refusals=<slug…>` to $GITHUB_OUTPUT, so the
#     enclosing job can publish `outputs.verdict` and the workflow's aggregator
#     can name the refusal on the CHECK-RUN, which is the only surface a human
#     at the merge button reads.
#   * Emits a `::error title=… REFUSED::` annotation that says, in the line
#     itself, that NO claim was made — the failure mode this whole channel
#     exists to stop is a refusal being read as either verdict.
#   * STILL EXITS NON-ZERO on a refusal. A refusal is not a pass; only a fix or
#     a re-run turns it green. The channel changes what the red MEANS, never
#     whether it is red. (console-harness.yml's aggregator states the same
#     rule: "a refusal is not a pass".)
#
# HOW A JOB'S VERDICT IS ASSEMBLED, and why it is not a `||` chain.
# `steps.a.outputs.verdict || steps.b.outputs.verdict` returns the FIRST
# non-empty one, so a job whose first instrument measured clean and whose
# second REFUSED would publish MEASURED-CLEAN and lose the refusal — the exact
# failure this channel exists to stop, rebuilt one layer up. Instead every call
# appends `BP_STEP_VERDICT` to $GITHUB_ENV, which GitHub hands to every LATER
# step in the same job, and each call COMBINES worst-first (REFUSED/UNKNOWN >
# MEASURED-DEFECT > MEASURED-CLEAN) with what it inherits. A final
# `if: always()` step in the job copies that env var into the one step output
# the job's `outputs.verdict` reads. The prior verdict is read from the
# $GITHUB_ENV FILE as well as the environment, so repeated calls inside ONE
# step combine too (the environment only refreshes between steps).
#
# EXIT CODES (its own): 0 the instrument measured clean · 1 anything else ·
# 2 this wrapper could not run at all (no slug, no `--`, no command).

set -uo pipefail

SLUG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -*) echo "CANNOT READ: unknown argument $1" >&2
        echo "usage: $0 <slug> -- <command> [args…]" >&2; exit 2 ;;
    *)  if [ -z "$SLUG" ]; then SLUG="$1"; shift; else break; fi ;;
  esac
done
[ -n "$SLUG" ] || { echo "CANNOT READ: no instrument slug" >&2; exit 2; }
[ "$#" -gt 0 ] || { echo "CANNOT READ: no command after --" >&2; exit 2; }

"$@"
rc=$?

case "$rc" in
  0) verdict="MEASURED-CLEAN" ;;
  1) verdict="MEASURED-DEFECT" ;;
  2) verdict="REFUSED" ;;
  *) verdict="UNKNOWN" ;;
esac

echo "instrument ${SLUG}: exit ${rc} -> ${verdict}"

# ── combine, worst-first, so a second call in the same step cannot erase a
#    refusal recorded by the first.
prior="${BP_STEP_VERDICT:-}"
if [ -n "${GITHUB_ENV:-}" ] && [ -r "${GITHUB_ENV:-/dev/null}" ]; then
  # within-step repeats: the environment does not refresh until the next step
  from_file="$(awk -F= '$1 == "BP_STEP_VERDICT" { v = $2 } END { print v }' "$GITHUB_ENV")"
  [ -n "$from_file" ] && prior="$from_file"
fi
rank() { case "$1" in REFUSED) echo 3 ;; UNKNOWN) echo 3 ;; MEASURED-DEFECT) echo 2 ;; MEASURED-CLEAN) echo 1 ;; *) echo 0 ;; esac; }
combined="$verdict"
if [ -n "$prior" ] && [ "$(rank "$prior")" -ge "$(rank "$verdict")" ]; then combined="$prior"; fi
export BP_STEP_VERDICT="$combined"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "verdict=${combined}" >> "$GITHUB_OUTPUT"
  if [ "$verdict" = "REFUSED" ] || [ "$verdict" = "UNKNOWN" ]; then
    echo "refused=${SLUG}" >> "$GITHUB_OUTPUT"
  fi
fi
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "BP_STEP_VERDICT=${combined}" >> "$GITHUB_ENV"
  if [ "$verdict" = "REFUSED" ] || [ "$verdict" = "UNKNOWN" ]; then
    echo "BP_REFUSALS=${BP_REFUSALS:+${BP_REFUSALS}, }${SLUG}" >> "$GITHUB_ENV"
  fi
fi

case "$verdict" in
  MEASURED-CLEAN) exit 0 ;;
  MEASURED-DEFECT) exit 1 ;;
  REFUSED)
    echo "::error title=${SLUG} REFUSED TO MEASURE::The instrument exited 2: it COULD NOT MEASURE and makes NO claim in either direction — nothing here says this tree is clean and nothing here says it is broken. exit 2 is ONE code over MANY causes and this wrapper measured none of them: READ THE INSTRUMENT'S OWN LINE ABOVE, which prints the cause by name (an unknown set or path name, an unrecognised argument, a missing or unreadable input, a base ref that does not resolve, a database or service that never came up). Do NOT assume the runner is at fault — several of those causes are committed files in this repo. This step is RED on purpose: a refusal is not a pass."
    exit 1 ;;
  *)
    echo "::error title=${SLUG} exited ${rc} — NO VERDICT::The instrument exited ${rc}, which is outside its declared vocabulary (0 clean / 1 measured defect / 2 refusal). A crash, a signal, or an interpreter that never started. It reached no verdict, so this is treated as a refusal: no claim is being made about what it was pointed at. RED on purpose."
    exit 1 ;;
esac
