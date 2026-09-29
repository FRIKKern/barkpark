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
#
# WHICH COMMAND FAILED (task-2e11c7faa11c80d9). A step NAME is a label on a
# label. MEASURED on main 0542e9677: the `Doc budgets + anchors` job of
# .github/workflows/doc-gates.yml declares 42 steps (39 with a `run:` body) and
# those bodies run 69 checker invocations — 50 of them share a step with a
# sibling, so the step name cannot say which one reddened. The commonest shape
# is the worst one: `bash scripts/X.sh --selftest` immediately followed by
# `bash scripts/X.sh`, two DIFFERENT failures under one name (the abort-before-
# reporting case main-red-breaker.sh documents at its OPAQUE-RED verdict is
# exactly this pair). So this wrapper reports the command itself:
#
#   * the step runs under an ERR trap installed through BASH_ENV, so the shell
#     itself records the command that tripped `bash -e`. Nothing is enumerated
#     and nothing is hand-maintained — a command added to a step tomorrow is
#     named by the same mechanism, because the mechanism reads what RAN.
#   * on a red the wrapper prints that command, plus the step's ordered
#     invocation list derived from the step script, and emits a ::warning so
#     the name is legible from the checks page WITHOUT opening the log.
#   * the fence label carries the failing command too. It used to carry the
#     first meaningful line of the step script, which for EVERY armed step is
#     the identical `if [ -z "${BREAKER_CAPTURE_ARMED:-}" ]` preamble below —
#     so every block in every capture was labelled the same string, and
#     main-red-breaker.sh's OPAQUE-RED report named no step at all.
#
# NONE OF THIS ENTERS THE CAPTURE FILE. The diagnostic is written to the
# wrapper's own stdout AFTER the tee, never into $CAP: a line our side carries
# and main's log does not is precisely what `comm -23` reads as the PR's OWN
# red, so enriching the signature set would manufacture false accusations.
#
# AUTHORITY, stated with the fix: `Doc budgets + anchors` is ADVISORY. It is an
# S4 exclusion in .github/required-checks.json, whose required set is only
# `Cloud gate`, `Console gate`, `Elixir gate` and `PR references an active
# task`. This change makes an advisory red LEGIBLE; it claims no merge
# authority the job does not have, and changes no path filter.
set -uo pipefail

STEP_SCRIPT="${1:-}"
[ -n "$STEP_SCRIPT" ] || { echo "breaker-capture: no step script given" >&2; exit 2; }

CAP="${BREAKER_ERROR_LOG:-${RUNNER_TEMP:-/tmp}/main-red-breaker-errors.txt}"
# The fence literals. main-red-breaker.sh greps for these EXACT strings; the
# drift guard in scripts/main-red-breaker.test.sh asserts both files agree.
BLOCK_BEGIN='##[breaker-block]begin '
BLOCK_END='##[breaker-block]end'
tmp="$(mktemp -t breaker-capture.XXXXXX)" || tmp=""

# The ERR-trap side-channel. An ERR trap fires on the command that tripped
# `bash -e` and NOT on an EXIT-trap cleanup that succeeds afterwards, which is
# why it is an ERR trap and not a DEBUG trap: several gate steps end with
# `trap 'rm -rf "$tmp"' EXIT`, and a DEBUG trap would report the rm. `set -E`
# propagates it into functions and subshells. `unset BASH_ENV` stops the
# prelude from being re-sourced by every child shell the step invokes — without
# it a nested `bash scripts/foo.sh` would overwrite the record with ITS last
# failing line and the wrapper would name a line inside the checker instead of
# the invocation the reader has to re-run. Both files are best-effort: losing
# them costs a less specific message, never an exit code.
lastcmd="$(mktemp -t breaker-lastcmd.XXXXXX 2>/dev/null)" || lastcmd=""
prelude=""
if [ -n "$lastcmd" ]; then
  prelude="$(mktemp -t breaker-prelude.XXXXXX 2>/dev/null)" || prelude=""
fi
if [ -n "$prelude" ]; then
  cat > "$prelude" <<EOF || prelude=""
# sourced by the step shell via BASH_ENV; written by scripts/breaker-capture.sh
set -E
trap 'printf "%s\n" "\$BASH_COMMAND" > "$lastcmd" 2>/dev/null || :' ERR
unset BASH_ENV
EOF
fi

if [ -z "$tmp" ]; then
  # No scratch file: run the step plainly. Losing the capture costs a
  # SIGNATURE-UNVERIFIED notice; losing the exit code would cost a merge.
  BREAKER_CAPTURE_ARMED=1 exec bash -e "$STEP_SCRIPT"
fi
trap 'rm -f "$tmp" "$lastcmd" "$prelude"' EXIT

if [ -n "$prelude" ]; then
  BREAKER_CAPTURE_ARMED=1 BASH_ENV="$prelude" bash -e "$STEP_SCRIPT" 2>&1 | tee "$tmp"
else
  BREAKER_CAPTURE_ARMED=1 bash -e "$STEP_SCRIPT" 2>&1 | tee "$tmp"
fi
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
step_cmd() { # -> the first real command of the step script
  # The BREAKER_CAPTURE_ARMED preamble is skipped: it is byte-identical in every
  # armed step in every workflow, so keeping it made every fence label the same
  # string and main-red-breaker.sh's per-step OPAQUE report name nothing.
  awk 'NF == 0 { next }
       /^[[:space:]]*#/ { next }
       /^[[:space:]]*set[[:space:]]/ { next }
       /BREAKER_CAPTURE_ARMED/ { next }
       { gsub(/\r$/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit }' "$STEP_SCRIPT" 2>/dev/null | cut -c1-200
}

step_commands() { # -> the step's checker invocations, in source order, one per line
  # DERIVED, NOT ENUMERATED: read off the step script the runner actually wrote,
  # so a command added tomorrow appears here without anyone maintaining a list.
  awk '/^[[:space:]]*#/ { next }
       /BREAKER_CAPTURE_ARMED/ { next }
       { line = $0; gsub(/\r$/, "", line)
         probe = line; sub(/^[[:space:]]+/, "", probe)
         while (probe ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", probe)
         if (probe ~ /^(bash|sh|node|python3?|npx|pnpm|make)[[:space:]]/ || probe ~ /^go[[:space:]]+run[[:space:]]/) {
           sub(/[[:space:]]+$/, "", probe); print substr(probe, 1, 200)
         } }' "$STEP_SCRIPT" 2>/dev/null
}

failed_cmd=""
if [ -n "$lastcmd" ] && [ -s "$lastcmd" ]; then
  failed_cmd="$(tr '\n\r\t' '   ' < "$lastcmd" | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-300)"
fi

if [ "$rc" -ne 0 ]; then
  # THE SELF-DESCRIBING RED. Printed to the wrapper's stdout, so it lands in the
  # step log but NOT in $CAP — see the header on why enriching the signature set
  # would manufacture false "this PR's own red" verdicts.
  n_cmds="$(step_commands | grep -c . || :)"
  echo "breaker-capture: ── this step FAILED (exit ${rc}) ──────────────────────────"
  if [ -n "$failed_cmd" ]; then
    echo "breaker-capture: the command that failed, verbatim:"
    echo "breaker-capture:     ${failed_cmd}"
  else
    echo "breaker-capture: the step exited ${rc} without a command tripping 'bash -e'"
    echo "breaker-capture: (an explicit exit, or the ERR side-channel was unavailable)"
  fi
  if [ "${n_cmds:-0}" -gt 0 ]; then
    echo "breaker-capture: this step runs ${n_cmds} command(s); its NAME can point at only one."
    echo "breaker-capture: the full list, in source order:"
    step_commands | nl -ba -w4 -s'. ' | sed 's/^/breaker-capture:     /'
  fi
  # Legible from the checks page without opening the log. A warning, not an
  # error: ownership of this red belongs to the Decide step, and an error
  # annotation on an inherited red is the mislabel this breaker exists to stop.
  ann="${failed_cmd:-exit ${rc} with no failing command recorded}"
  ann="$(printf '%s' "$ann" | sed 's/%/%25/g')"
  echo "::warning title=Failing command::${ann}"
fi

if [ "$rc" -ne 0 ] && [ -s "$tmp" ]; then
  mkdir -p "$(dirname "$CAP")" 2>/dev/null || true
  { printf '%s%s\n' "$BLOCK_BEGIN" "${failed_cmd:-$(step_cmd)}"
    cat "$tmp"
    printf '%s\n' "$BLOCK_END"
  } >> "$CAP" 2>/dev/null || true
fi
exit "$rc"
