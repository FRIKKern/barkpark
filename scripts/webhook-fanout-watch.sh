#!/usr/bin/env bash
# webhook-fanout-watch.sh — a LEVEL check over LIVE site-autodeploy webhook rows.
#
# THE ONE QUESTION IT ANSWERS
#
#   Does any `site-autodeploy-*` webhook row still match EVERYTHING?
#
# On the box, `Registry.content_webhook_types/1` returns `[]` — the
# match-everything sentinel — for any blank or absent doc_type. That is a
# documented fail-OPEN: a single doc_type edit silently re-arms the fan-out, and
# nothing on the write side complains. The WRITE-side guard already exists and is
# green (api/test/.../registry_test.exs, the types clause); what did not exist is
# anything that re-asserts the LIVE ROWS after the 2026-08-07 03:43Z repair,
# which set all five live rows to `types=["paper"]`. This is that re-assertion.
#
# VERDICT IS BOOLEAN, AND IT IS ONLY THAT
#
#   red  iff  some `site-autodeploy-*` row has `types = []`  (or the population
#             sits below the pinned floor — see ANTI-VACUOUS FLOOR)
#
# FAN-OUT IS METERED, NEVER JUDGED (charter D206, D228(f))
#
# Every run prints, for each dataset/doc_type group in the population:
#
#   FAN-OUT (metered, not judged): dataset=<d> doc_type=<t> rows=<n>
#
# and derives NO verdict from those numbers. That restraint is the design, not
# an omission. D206 rules the current five-sites-on-one-dataset population the
# CURRENT STATE of this system, and D228(f) rules that cutting it "needs a fresh
# argument, not a label". A `rows > 1` verdict would therefore be red from minute
# one, on purpose-built ground truth — and an alarm engineered to be silenced is
# worse than no alarm at all. The number is here so a human can WATCH it move;
# the day someone has the fresh argument, the meter is already collecting.
#
# ANTI-VACUOUS FLOOR — WEBHOOK_FANOUT_EXPECT_MIN (default 1, callers pin 5)
#
# "Every row is well typed" is trivially true of ZERO rows, and of one surviving
# row after four were deleted. So the population size is checked against a floor
# and a shortfall is RED.
#
# THAT NUMBER IS HUMAN-MOVED, AND IT HAS TO BE. The guard cannot derive it: the
# shipped CLI has no site-list verb (`bp cloud site list` answers `unknown site
# command "list"`), so there is no second authority to count sites against.
# Pinning it in the caller means a downward move is a DIFF a reviewer sees.
#
#   A legitimate red — a sixth site spawned, a demo site retired — is a
#   RE-PIN, never a disable. If you find yourself deleting this check rather
#   than changing the number, that is the failure mode it was written against.
#
# FOUR-VALUED EXIT (breakglass-watch.sh's contract, deliberately identical)
#
#   0  every row in the population carries a doc-type filter, and the population
#      meets the floor
#   1  at least one row matches everything, OR the population is below the floor
#   2  UNKNOWN — transport blip (5xx, timeout, connection reset). Never green,
#      never a silent pass; it is a silence, and it says so.
#   3  CONFIGURATION FAULT — the credential could not read (401/403/not logged
#      in), the input could not be parsed, or `jq` is absent. Permanent until a
#      human acts; retrying cannot help; reds.
#
#   ANY OTHER CODE IS RED. A watch whose exit code you do not recognise has not
#   told you the thing is fine — see the trailing dispatcher at the bottom.
#
# NO `continue-on-error`, HERE OR IN THE WORKFLOW
#
# `continue-on-error: true` launders a red into a green run conclusion: the step
# shows an X that nobody scrolls to and the job — the thing branch protection and
# the fleet actually read — reports success. That is precisely the disease this
# epic exists to cure (a deploy that fails and reports nothing). If this check is
# too noisy to block, the answer is to fix the check or delete it, not to make it
# unable to lose.
#
# ─── RUNBOOK: the LIVE verdict ───────────────────────────────────────────────
#
# The hermetic half (scripts/webhook-fanout-watch.test.sh) rides CI and can
# block. The LIVE half is a HUMAN-RUN COMMAND, on purpose — see THE OPEN HUMAN
# GATE below.
#
#   make cli-install                                  # REQUIRED FIRST STEP. The
#                                                     # `bp` on PATH can report a
#                                                     # current-looking sha and
#                                                     # still be missing verbs
#                                                     # (`webhook reconcile` was
#                                                     # the case that bit us).
#   bp login                                          # control-plane session
#   bp cloud webhook list guerrilla --dataset production -o json > /tmp/wh.json
#   WEBHOOK_FANOUT_EXPECT_MIN=5 scripts/webhook-fanout-watch.sh --rows-file /tmp/wh.json
#   echo "exit=$?"                                    # 0 ok · 1 red · 2 unknown · 3 fault
#
# `--rows-file -` reads stdin, so the two steps can be one pipe.
#
# If it exits 1 because the population shrank, RE-PIN WEBHOOK_FANOUT_EXPECT_MIN
# in the caller (and say why in the commit). Do not delete the floor.
#
# ─── THE OPEN HUMAN GATE (why this is not a scheduled workflow) ──────────────
#
#   GATE: dr-w19-hg-cloud-control-plane-read-token — OPEN.
#   Needs: a control-plane read credential armed as a GitHub Actions secret
#          (working name BARKPARK_CLOUD_READ_TOKEN), plus `bp` available to the
#          runner.
#
# Today neither exists. `bp` is not on GitHub runners (shell-harnesses.yml says
# so in as many words), and the only ledger secret, BARKPARK_TASK_TOKEN, is
# stated UNPROVISIONED on main and points at the CONTENT api, not the control
# plane. A scheduled workflow shipped now would exit 3 on every run, forever —
# a watch that can only lose, which trains the fleet to ignore it. So the live
# verdict is a runbook command and a NAMED gate, exactly the way BREAKGLASS_TOKEN
# was named before it was armed.
#
# ─── RESIDUAL, STATED NOT HIDDEN ─────────────────────────────────────────────
#
# The population is NAME-PREFIX-DERIVED: it is "the rows that exist and are
# called site-autodeploy-*". A site whose webhook row was never created at all is
# invisible to this guard IN BOTH DIRECTIONS — it cannot be an offender and it
# cannot be counted. The pinned floor makes a SHRINK a diff; it does not make
# this a completeness check. This is a REGRESSION WATCH over an applied repair.
#
# USAGE
#   scripts/webhook-fanout-watch.sh --rows-file <file|->
#   WEBHOOK_FANOUT_EXPECT_MIN=5 scripts/webhook-fanout-watch.sh --rows-file -
#   scripts/webhook-fanout-watch.sh --prefix site-autodeploy- --rows-file f.json

set -uo pipefail

PREFIX="site-autodeploy-"
ROWS_FILE=""
EXPECT_MIN="${WEBHOOK_FANOUT_EXPECT_MIN:-1}"

# The exit vocabulary, named so the code reads like the contract above.
EXIT_OK=0
EXIT_RED=1
EXIT_UNKNOWN=2
EXIT_FAULT=3

say() { echo "$*"; }
red() { echo "$*" >&2; }

# A CONFIGURATION fault: the credential could not read, and waiting will not
# change that. Matched on the bodies `bp`/`gh`/curl actually emit.
is_config_fault() { # body
  grep -qiE 'rate limit|abuse detection' <<<"$1" && return 1
  grep -qiE 'HTTP 401|HTTP 403|unauthor|forbidden|bad credentials|not logged in|barkpark_not_found|permission denied|requires authentication|resource not accessible' <<<"$1"
}

# A TRANSPORT blip: it clears on its own, so it is UNKNOWN rather than red. The
# split matters — a 502 that reds every run trains the fleet to dismiss the
# watch, and a revoked token that warns instead of reds is a watch with no
# authority reporting green.
is_transport_blip() { # body
  grep -qiE 'HTTP 5[0-9][0-9]|bad gateway|gateway timeout|service unavailable|timeout|timed out|connection (refused|reset)|could not resolve|network is unreachable|rate limit' <<<"$1"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      # A flag whose VALUE is missing is a configuration fault, not a hang.
      # `shift 2` with one argument left FAILS (and, without `set -e`, does not
      # shift) — the loop then spins on the same argv forever. A watch that
      # never returns is worse than one that reds: nothing downstream ever
      # learns anything. So the arity is checked before the shift.
      --rows-file|--prefix|--expect-min)
        if [ $# -lt 2 ]; then
          red "CONFIGURATION FAULT — $1 needs a value."
          return "$EXIT_FAULT"
        fi
        case "$1" in
          --rows-file) ROWS_FILE="$2" ;;
          --prefix) PREFIX="$2" ;;
          --expect-min) EXPECT_MIN="$2" ;;
        esac
        shift 2 ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; return "$EXIT_OK" ;;
      *) red "unknown argument: $1"; return "$EXIT_FAULT" ;;
    esac
  done

  # The floor is the anti-vacuity guard, so a floor that is not a number must
  # not be allowed to sail past it. `[ 0 -lt "" ]` and `[ 0 -lt abc ]` both make
  # `test` exit 2 with an error on stderr, and a bare `if` reads that as FALSE —
  # i.e. "the floor is met". That is the vacuous green this file exists against.
  if ! printf '%s' "$EXPECT_MIN" | grep -qE '^[0-9]+$'; then
    red "CONFIGURATION FAULT — the floor must be a non-negative integer, got '$EXPECT_MIN'."
    red "Set it with --expect-min <n> or WEBHOOK_FANOUT_EXPECT_MIN=<n>; the runbook pins 5."
    return "$EXIT_FAULT"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    red "CONFIGURATION FAULT — jq is not on PATH, so the webhook rows cannot be parsed."
    red "This is not a green and not a blip: install jq."
    return "$EXIT_FAULT"
  fi

  if [ -z "$ROWS_FILE" ]; then
    red "CONFIGURATION FAULT — no --rows-file given."
    red "This guard never reaches the network itself; feed it the control plane's answer:"
    red "  bp cloud webhook list <instance> --dataset <ds> -o json | $0 --rows-file -"
    red "(run 'make cli-install' first — see the RUNBOOK in this file's header)"
    return "$EXIT_FAULT"
  fi

  local raw
  if [ "$ROWS_FILE" = "-" ]; then
    raw="$(cat)"
  elif [ -f "$ROWS_FILE" ]; then
    raw="$(cat "$ROWS_FILE")"
  else
    red "CONFIGURATION FAULT — --rows-file $ROWS_FILE does not exist."
    red "A watch pointed at a file that is not there has read NOTHING; it must not report success."
    return "$EXIT_FAULT"
  fi

  # The read may have failed rather than answered. Classify the body BEFORE
  # trying to parse it, so 'a 403 body is not valid JSON' cannot masquerade as a
  # parse fault (right colour, wrong reason — and the fix is different).
  if ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
    if is_config_fault "$raw"; then
      red "CONFIGURATION FAULT — the control plane refused the read:"
      red "  $(head -1 <<<"$raw")"
      red "That is permanent until a human acts (run 'bp login', or arm the control-plane token)."
      red "It is NOT retried and NOT softened: a watch that cannot read what it watches must fail."
      return "$EXIT_FAULT"
    fi
    if is_transport_blip "$raw"; then
      say "::warning::UNKNOWN — the control plane could not be reached: $(head -1 <<<"$raw")"
      say "This is NOT a green. It is a silence, and transport blips clear on their own — re-run."
      return "$EXIT_UNKNOWN"
    fi
    red "CONFIGURATION FAULT — the webhook rows could not be parsed as JSON."
    red "First line was: $(head -1 <<<"$raw")"
    red "Expected 'bp cloud webhook list … -o json' output."
    return "$EXIT_FAULT"
  fi

  # Accept the three shapes the CLI and the API can hand us: a bare array, the
  # {"webhooks":[…]} list payload, and the {"data":{"webhooks":[…]}} envelope.
  # Anything else is a SHAPE fault, not an empty population — silently reading
  # an unknown shape as zero rows is how this guard would go vacuously green.
  local rows
  rows="$(jq -c '
    if type == "array" then .
    elif (type == "object" and has("webhooks") and (.webhooks | type == "array")) then .webhooks
    elif (type == "object" and (.data | type == "object") and (.data | has("webhooks")) and (.data.webhooks | type == "array")) then .data.webhooks
    else error("unrecognised webhook payload shape")
    end' <<<"$raw" 2>/dev/null)" || {
      red "CONFIGURATION FAULT — the JSON parsed, but carries no webhook rows in any known shape."
      red "Wanted an array, {\"webhooks\":[…]} or {\"data\":{\"webhooks\":[…]}}."
      return "$EXIT_FAULT"
    }

  local pop total
  pop="$(jq -c --arg p "$PREFIX" '[ .[] | select(((.name // "") | tostring) | startswith($p)) ]' <<<"$rows")"
  total="$(jq -r 'length' <<<"$pop")"

  # ── THE METER. Printed on every run, including reds. Judged by nobody. ──
  say "FAN-OUT (metered, not judged) — one line per dataset/doc_type group:"
  if [ "$total" -eq 0 ]; then
    say "  FAN-OUT (metered, not judged): dataset=(none) doc_type=(none) rows=0"
  else
    # The group key separates on jq's \u0000 ESCAPE, never a literal NUL byte.
    # A literal NUL cannot survive exec, so bash DROPS it while building this
    # argv: jq then received `.dataset + "" + .doc_type` and metered two
    # distinct pairs whose concatenations collide - ("ab","c") and ("a","bc")
    # - as ONE group, printed under the first one label set. The escape also
    # keeps this file plain text: a raw NUL makes every line-printing grep
    # over scripts/ classify it BINARY and emit nothing but "Binary file ...
    # matches", which is how a census concluded this script had no set line.
    jq -r '
      [ .[] | { dataset: ((.dataset // "(unset)") | tostring),
                doc_type: ( (.types // []) | if length == 0 then "(MATCHES EVERYTHING)" else join("+") end ) } ]
      | group_by(.dataset + "\u0000" + .doc_type)
      | .[]
      | "  FAN-OUT (metered, not judged): dataset=\(.[0].dataset) doc_type=\(.[0].doc_type) rows=\(length)"
    ' <<<"$pop"
  fi
  say "  (no verdict is derived from these counts — charter D206/D228(f))"

  local offenders
  offenders="$(jq -r '.[] | select(((.types // []) | length) == 0) | ((.name // "(unnamed)") | tostring)' <<<"$pop")"

  if [ -n "$offenders" ]; then
    red "RED — a site-autodeploy webhook matches EVERYTHING again (types = []):"
    printf '%s\n' "$offenders" | while IFS= read -r n; do
      [ -n "$n" ] || continue
      red "  $n"
    done
    red "An empty types filter is the box's match-everything sentinel (content_webhook_types/1"
    red "fails OPEN for a blank doc_type), so every document change in that dataset fans out."
    red "Repair: bp cloud webhook reconcile <instance> --dataset <ds>   (run 'make cli-install' first)"
    return "$EXIT_RED"
  fi

  if [ "$total" -lt "$EXPECT_MIN" ]; then
    red "RED — the population is BELOW the pinned floor: $total row(s) matching '$PREFIX', floor is $EXPECT_MIN."
    red "'Every row is well typed' is trivially true of zero rows. This guard refuses to be vacuous."
    red "If the shrink is legitimate (a site retired), RE-PIN WEBHOOK_FANOUT_EXPECT_MIN in the caller"
    red "and say why in the commit — that number is human-moved because the CLI has no site-list verb."
    red "Do NOT delete the floor to make this green."
    return "$EXIT_RED"
  fi

  say "ok — $total site-autodeploy row(s), every one carrying a doc-type filter (floor $EXPECT_MIN met)."
  return "$EXIT_OK"
}

main "$@"
rc=$?
# ANY undefined code is red. A watch that exits 7 has not told you the thing is
# fine, and `set -e` plus a stray command is exactly how a 7 happens.
case "$rc" in
  0|1|2|3) exit "$rc" ;;
  *) echo "webhook-fanout-watch: undefined exit code $rc — treating as RED (an unrecognised verdict is not a pass)" >&2; exit 1 ;;
esac
