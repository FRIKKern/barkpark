#!/usr/bin/env bash
#
# landed-open-report-schedule.sh — the CONSUMER for scripts/landed-open-report.sh.
#
# THE DEFECT (task-f5be1a6dbf914096). The reader shipped in #16616 and NOTHING
# RAN IT against the ledger. Its hermetic `--selftest` and its mutation harness
# do ride shell-harnesses.yml, so the CODE is guarded — but a guarded reader
# that never reads is the same shape as the gap it was built to close: a
# facility nobody consumes. This script is the thing that consumes it, and it
# lives in scripts/ rather than inside a YAML `run:` block for the reason
# task-lease-renew.yml already wrote down: a predicate that only exists in a
# `run:` block is a predicate no harness can reach, which is how pr-task-gate
# silently dropped every backtick-wrapped trailer for weeks. Its harness is
# scripts/landed-open-report-schedule.test.sh.
#
# THE EXIT CONTRACT IT WRAPS, and must not undo:
#   reader 0  the walk succeeded (live rows, or an honest clean zero)  -> 0
#   reader 2  CANNOT READ — short walk, bad page, 401/403, or a labelled
#             population under the floor                               -> 1, RED
#   reader 3  only with --exit-on-findings, which this consumer does NOT pass.
#
# WHY NOT --exit-on-findings. A live row is a REPORT, not a defect in this
# repo: the reader's two measured false-positive classes ([PARENT], [GATE?])
# are flagged, not filtered, precisely because the list needs a human to read
# it. A scheduled job that reds on every finding reds every single day, and a
# workflow that is always red is a workflow everybody learns to ignore — which
# is how the ledger got a reader nobody runs in the first place. So: a FAILED
# READ is the only red, the findings go into $GITHUB_STEP_SUMMARY verbatim with
# their flags intact, and a non-empty list also raises a ::warning annotation so
# the run surface says the list is non-empty without claiming the job failed.
#
# THE FLOOR IS A POSITIVE CONTROL, not a threshold. Landed labels are only ever
# ADDED (scripts/landed-mark.sh never removes one), so the labelled population
# cannot shrink. 439 rows carried the label when the row was filed; 444 on
# 2026-09-07. A floor of 400 therefore cannot be tripped by the ledger going
# clean — only by this job reading the wrong ledger, or reading nothing at all
# while printing a tidy empty list.
#
# ENV
#   BARKPARK_TOKEN                 required; the ledger read credential
#   BARKPARK_SERVER                the ledger base (bp's own env name)
#   LANDED_REPORT_BP               the bp binary (passed through to the reader)
#   LANDED_SCHEDULE_MIN_POPULATION the floor (default 400)
#   GITHUB_STEP_SUMMARY            where the flagged report is published

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READER="$ROOT/scripts/landed-open-report.sh"
MIN_POP="${LANDED_SCHEDULE_MIN_POPULATION:-400}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# A MISSING CREDENTIAL IS A FAILURE, NEVER A SKIP — the landed-mark.yml stance.
# A job that shrugs at an unset secret becomes a permanent silent no-op wearing
# a green tick, which is strictly worse than the script nobody ran.
if [ -z "${BARKPARK_TOKEN:-}" ]; then
  {
    echo "::error title=landed-open-report cannot read — BARKPARK_TASK_TOKEN is not set::No ledger token on this run, so this job read NOTHING. An unread ledger is not a clean ledger: rows whose work landed on main stay open and unstamped, unseen. Provision the secret (see docs/ops/merge-gates.md)."
  } | tee -a "$SUMMARY"
  exit 1
fi

[ -f "$READER" ] || {
  echo "::error title=landed-open-report reader missing::$READER is not in this checkout." | tee -a "$SUMMARY"
  exit 1
}

# The reader's exit code, read from the command itself. NOTHING IS PIPED: under
# pipefail a pipeline reports the last stage, and the whole point of this job is
# that a 2 from the reader reaches the runner intact.
out="$(bash "$READER" --min-population "$MIN_POP" 2>&1)"
rc=$?

# The report goes to the log AND to the step summary, fenced so the fixed-width
# table — and with it the [PARENT] / [GATE?] flags — survives markdown.
printf '%s\n' "$out"
{
  echo "### landed-open-report"
  echo ""
  echo '```'
  printf '%s\n' "$out"
  echo '```'
} >> "$SUMMARY"

case "$rc" in
  0)
    # A clean zero and a list of findings are BOTH a successful read. Only the
    # non-empty case raises an annotation, and it names the flags so nobody
    # reads a [PARENT] contribution row as a discharged one.
    live="$(printf '%s\n' "$out" | sed -n 's/^walked .* \([0-9][0-9]*\) live$/\1/p' | tail -1)"
    case "$live" in
      ''|0) : ;;
      *) echo "::warning title=Landed work still open::$live task rows carry landed-on-main and are still open or in_progress. The list is in this run's step summary; rows tagged [PARENT] (a contribution, not a discharge) and [GATE?] (a human gate nobody has looked at) are expected false positives and are NOT filtered." ;;
    esac
    exit 0
    ;;
  2)
    # THE ONE RED. The reader already printed its own CANNOT READ line into
    # "$out" above, so it is in the log and the summary; this names it as the
    # job's verdict so the run surface does not read as "nothing to do".
    echo "::error title=landed-open-report CANNOT READ the ledger::The walk failed or came back below its population floor, so this run learned NOTHING about landed-but-open rows. The reader's own CANNOT READ line is in the log and the step summary above. A refused read is a RED, never an empty list." | tee -a "$SUMMARY"
    exit 1
    ;;
  *)
    echo "::error title=landed-open-report exited $rc::An exit this consumer does not model. Treated as a failed read." | tee -a "$SUMMARY"
    exit 1
    ;;
esac
