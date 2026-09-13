#!/usr/bin/env bash
# breaker-capture.sh — the CAPTURE half of the main-red circuit breaker
# (task-2dbe8808f2a6f7b5, wiring the signature layer PR #15842 shipped inert).
#
# WHY THIS EXISTS. scripts/main-red-breaker.sh inherits a PR red from main only
# when the failing STEP NAME **and** a normalised FAILURE SIGNATURE both match.
# It runs as the LAST step of the job it judges, so the job's own log is not
# readable yet (`/actions/jobs/{id}/logs` 404s until the job is complete, and a
# check run's annotations are not final either) — the ONE source of this PR's
# side of the signature is a file a gate step wrote WHILE IT WAS FAILING. With
# no gate step writing it, every live verdict took the SIGNATURE-UNVERIFIED
# fallback and behaved exactly like the step-name-only v1.
#
# HOW A GATE STEP ARMS IT. One line, first in the step body, so the smallest
# possible hunk sits in the workflow and every gate step carries the same shape:
#
#   if [ -z "${BREAKER_CAPTURE_ARMED:-}" ] && [ -f "$GITHUB_WORKSPACE/scripts/breaker-capture.sh" ]; then exec bash "$GITHUB_WORKSPACE/scripts/breaker-capture.sh" "$0"; fi
#
# `$0` is the runner's own temp script for that step, so the step body is not
# rewritten or re-quoted — it is re-run verbatim under a tee. The env guard
# stops the recursion; the `-f` test makes a missing helper fall back to no
# capture (SIGNATURE-UNVERIFIED) instead of reddening 50 gate steps at once.
#
# THE INVARIANT. A capture wrapper that swallows a red is worse than no capture,
# so this script NEVER changes the step's exit code: the child runs under the
# same `bash -e <script>` the runner's default shell uses, and its status is
# taken from PIPESTATUS[0] (not the tee's) and re-raised verbatim. Only a
# FAILING step appends — a green step whose output happens to contain the word
# FAIL (several tripwire self-tests print exactly that) would otherwise poison
# the signature set and turn genuinely inherited reds into the author's.
#
# The capture is RAW: main-red-breaker.sh owns the normalising (timestamps,
# ANSI, `##[error]` prefixes, sha/digit erasure). Callers add nothing.
set -uo pipefail

STEP_SCRIPT="${1:-}"
[ -n "$STEP_SCRIPT" ] || { echo "breaker-capture: no step script given" >&2; exit 2; }

CAP="${BREAKER_ERROR_LOG:-${RUNNER_TEMP:-/tmp}/main-red-breaker-errors.txt}"
# The fence literals. main-red-breaker.sh greps for these EXACT strings; the
# drift guard in scripts/main-red-breaker.test.sh asserts both files agree.
BLOCK_BEGIN='##[breaker-block]begin '
BLOCK_END='##[breaker-block]end'
tmp="$(mktemp -t breaker-capture.XXXXXX)" || tmp=""

if [ -z "$tmp" ]; then
  # No scratch file: run the step plainly. Losing the capture costs a
  # SIGNATURE-UNVERIFIED notice; losing the exit code would cost a merge.
  BREAKER_CAPTURE_ARMED=1 exec bash -e "$STEP_SCRIPT"
fi
trap 'rm -f "$tmp"' EXIT

BREAKER_CAPTURE_ARMED=1 bash -e "$STEP_SCRIPT" 2>&1 | tee "$tmp"
rc="${PIPESTATUS[0]}"

# EACH FAILING STEP IS FENCED (task-501a3f6f34d5aa20). Before this, every
# failing step in a job appended into ONE flat file and the breaker compared the
# UNION of their output against main's. A union hides the thing that matters:
# whether the step that actually red carries any per-finding detail at all. In
# PR #17984 job 103556399633 the doc-byte-budget step's whole captured red was
#
#     check-doc-budgets --selftest: FAILED — the full gate did not pass with DOC_BUDGETS_SPAN_ONLY set
#
# — one line, byte-identical no matter WHICH doc is over cap or how many are —
# while a SIBLING step in the same job printed `FAIL: docs/evidence/….md …`.
# Union'd together the set looks richly detailed, so the subset test read
# "signature matched" and the red was waved through as inherited. Fenced, the
# breaker can see that ONE of the blocks names nothing and refuse.
#
# The fence carries the step's COMMAND, not its name: GitHub does not hand a
# step its own `name`, and inventing one by counting `##[group]Run` blocks is
# the positional guess main-red-breaker.sh already refutes elsewhere. The first
# meaningful line of the runner's temp script is a true, derived identifier.
# A capture written by an OLDER copy of this script has no fences; the breaker
# treats such a file as a single block and SAYS which shape it read.
step_cmd() { # -> the first non-blank, non-comment, non-`set` line of the step script
  awk 'NF == 0 { next }
       /^[[:space:]]*#/ { next }
       /^[[:space:]]*set[[:space:]]/ { next }
       { gsub(/\r$/, ""); print; exit }' "$STEP_SCRIPT" 2>/dev/null | cut -c1-200
}

if [ "$rc" -ne 0 ] && [ -s "$tmp" ]; then
  mkdir -p "$(dirname "$CAP")" 2>/dev/null || true
  { printf '%s%s\n' "$BLOCK_BEGIN" "$(step_cmd)"
    cat "$tmp"
    printf '%s\n' "$BLOCK_END"
  } >> "$CAP" 2>/dev/null || true
fi
exit "$rc"
