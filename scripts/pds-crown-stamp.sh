#!/usr/bin/env bash
#
# pds-crown-stamp.sh — stamp ONE crown acceptance criterion, safely, twelve
# times in a row, under fatigue, without mangling a single one.
#
# WHY THIS EXISTS
# ---------------
# When the climb greens, twelve criteria get stamped by hand. A mangled stamp
# arriving after a successful climb is unrecoverable in the moment: the rung is
# spent, the operator is tired, and the failure mode is a shell quoting bug in a
# 2490-character string nobody wants to re-read.
#
# Both halves of the recipe were PROVEN live before this script existed:
#
#   (a) Criterion 6 pasted INLINE into a double-quoted shell string ran its four
#       backtick pairs as command substitution. The server rejected the stamp
#       with `criteria_mismatch`, exit 2, and NOTHING was written.
#   (b) The identical 2490-char text passed as --criterion-text "$(cat c6.txt)"
#       stamped clean at exit 0.
#
# This script is (b), made repeatable. It fetches criterion N's EXACT stored
# wording from the server to a file via a JSON-field write, then stamps by
# passing that file's contents through command substitution.
#
# NEVER a here-doc, NEVER an echo. Both re-introduce the shell as an
# interpreter of text it has no business interpreting, and a here-doc adds a
# trailing newline that command substitution then silently strips.
#
# THE LAW IS UNIFORM FETCH-TO-FILE FOR ALL TWELVE (PDS-D226)
# ----------------------------------------------------------
# There is no per-criterion judgement call here, and that is the entire point.
#
#   * Criterion 6 is the only one of the twelve that is unsafe inside a
#     double-quoted string (8 backticks), and it fails LOUDLY.
#   * But c5, c6 and c11 all carry single quotes, and CRITERION 11 CARRIES
#     EXACTLY ONE SINGLE QUOTE IN 1248 CHARACTERS. It is invisible on
#     inspection. It is stamped LAST and ALONE at maximum fatigue. Its met-flip
#     removes the final brake on the cmux Stop-hook auto-close.
#
# The uniform law exists precisely so that nobody eyeballs c11, sees no
# backticks, concludes "this one is fine", and types it inline.
#
# A SIGNAL YOU CANNOT TRUST: `command` is a zsh BUILTIN. Of criterion 6's four
# backtick pairs only three emit "command not found" — the fourth mangles
# SILENTLY. The shell's stderr is NOT a mangling detector. The only reliable
# signal is the server's `criteria_mismatch`, which is why this script never
# treats a quiet shell as a clean stamp.
#
# SAFE BY CONSTRUCTION, NOT BY LUCK
# ---------------------------------
# Command substitution strips ALL trailing newlines. Today the recipe is safe
# only because 0 of the 12 crown criteria carry trailing whitespace — safe by
# luck of the data. This script closes that hole: `fetch` writes the raw JSON
# field byte-for-byte and then REFUSES if the stored text ends in a newline,
# because that is exactly the text `$(cat …)` would quietly alter. Luck becomes
# a checked precondition.
#
# THE URL CEILING IS A NON-RISK — SAID OUT LOUD, NOT GUARDED HEAVILY
# ------------------------------------------------------------------
# The circulated "8900–9002 bytes" figure is WRONG. Re-derived by bisection to
# a single byte, 3/3 reproducible on each side: total request target 10016 OK /
# 10017 FAIL. It is a TOTAL-bytes limit, not a per-parameter one. The mechanism
# is Bandit's unconfigured `max_request_line_length` default of 10000:
#
#     "POST " + target + " HTTP/1.1" + CRLF   =   5 + 9984 + 9 + 2 = 10000
#
# Over --http1.1 direct to :4000 with Caddy bypassed, the same byte returns a
# legible 414. Durable law: REQUEST TARGET <= 9984 BYTES.
#
# Per-criterion evidence budgets therefore run 7197 (c6, the tightest) to 9759
# (c3). A proven c6 stamp spent 69 of its 7197. You are not going to hit this.
# It is printed because an invisible limit is worse than a generous one, and
# refused locally because an oversized stamp is fail-closed server-side (a
# 9000-byte sentinel wrote NOTHING) — so the recovery is always "retry shorter",
# never "reconcile a half-write".
#
# The budget is MEASURED, never modelled: this script asks `bp task stamp
# --dry-run` for the exact request line it would send and counts its bytes. It
# does not reimplement the CLI's percent-encoder, so it cannot drift from it.
# Worker and epoch ride the BODY, not the URL, and cost budget nothing.
#
# USAGE
#   scripts/pds-crown-stamp.sh census <task-id>
#       Per-criterion met/length/hazard/budget table. Read this first.
#
#   scripts/pds-crown-stamp.sh fetch <task-id> <N> [--out FILE]
#       Write criterion N's exact stored wording to a file. Prints the path.
#
#   scripts/pds-crown-stamp.sh budget <task-id> <N> [--evidence TEXT]
#       Print the remaining evidence budget, and what TEXT would spend of it.
#
#   scripts/pds-crown-stamp.sh stamp <task-id> <N> <worker> <epoch> \
#       --evidence TEXT [--dry-run]
#       Fetch, budget-check, stamp, then READ BACK and prove met flipped.
#
# N IS ZERO-BASED. The first criterion is 0. The crown's twelve are 0..11.
#
# EXIT STATUS
#   0  the stamp landed and the read-back confirms met:true
#   1  refused locally BEFORE any write (budget, trailing newline, bad index)
#   2  the operation itself failed (network, auth, server rejection)
#
set -uo pipefail

# ── the measured ceiling (see header) ────────────────────────────────────────
readonly TARGET_LIMIT=9984      # Bandit max_request_line_length 10000 - "POST " - " HTTP/1.1" - CRLF
readonly BP_BIN="${BP:-bp}"

readonly EX_OK=0
readonly EX_REFUSED=1
readonly EX_FAILED=2

# ── scratch space ────────────────────────────────────────────────────────────
# ONE directory for the whole run, removed by a single EXIT trap. Deliberately
# not a per-function `trap ... RETURN`: bash leaves that trap armed after the
# function returns, so the next return re-fires it against an out-of-scope $tmp
# and `set -u` reports "tmp: unbound variable" on an otherwise clean run.
PDS_SCRATCH=""
cleanup() { [ -n "$PDS_SCRATCH" ] && rm -rf "$PDS_SCRATCH"; }
trap cleanup EXIT
scratch_dir() {
  if [ -z "$PDS_SCRATCH" ]; then
    PDS_SCRATCH=$(mktemp -d) || { printf 'FAILED: mktemp failed\n' >&2; exit 2; }
  fi
  printf '%s' "$PDS_SCRATCH"
}

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'FAILED: %s\n' "$*" >&2; exit "$EX_FAILED"; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit "$EX_REFUSED"; }

need_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 not found — the JSON-field write has no safe substitute here"
}

usage() {
  sed -n '/^# USAGE/,/^# EXIT STATUS/p' "$0" | sed 's/^# \{0,1\}//'
}

# ── fetch the task JSON once, to a file ──────────────────────────────────────
# Read-only. Never mutates the task.
task_json() {
  local task_id="$1" out="$2"
  "$BP_BIN" task get "$task_id" -o json >"$out" 2>/dev/null \
    || die "bp task get $task_id failed — nothing was written"
  [ -s "$out" ] || die "bp task get $task_id returned nothing"
}

# ── write criterion N's EXACT stored wording to a file ───────────────────────
# This is the JSON-field write. The bytes go from the parsed JSON straight to
# the file: no echo, no here-doc, no shell interpolation anywhere on the path.
# It REFUSES on a trailing newline, which is the one stored shape that
# command substitution would silently alter.
criterion_to_file() {
  local json="$1" idx="$2" out="$3"
  need_python
  python3 - "$json" "$idx" "$out" <<'PY'
import json, sys
src, idx, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
doc = json.load(open(src))["doc"]
ac = doc.get("content", {}).get("acceptance_criteria") or []
if not 0 <= idx < len(ac):
    sys.stderr.write(
        "REFUSED: criterion index %d is out of range — this task has %d criteria (0..%d)\n"
        % (idx, len(ac), len(ac) - 1))
    sys.exit(1)
text = ac[idx]["criterion"]
if text.endswith("\n"):
    sys.stderr.write(
        "REFUSED: criterion %d's stored wording ends in a newline. Command "
        "substitution strips ALL trailing newlines, so $(cat file) would send "
        "text that does not match the stored row and the server would reject it "
        "criteria_mismatch. This recipe does not cover that shape.\n" % idx)
    sys.exit(1)
with open(out, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
PY
}

# ── ask the CLI for the exact request target it WOULD send ───────────────────
# The budget oracle. We do not model the encoder, we measure it: --dry-run
# prints the literal request line, and we count the bytes of its target.
dry_run_target_bytes() {
  local task_id="$1" idx="$2" worker="$3" epoch="$4" text_file="$5" evidence="$6"
  local line target
  line=$("$BP_BIN" task stamp "$task_id" "$worker" "$epoch" \
      --criterion "$idx" --met \
      --evidence "$evidence" \
      --criterion-text "$(cat "$text_file")" \
      --dry-run 2>/dev/null | grep -m1 '^POST ') \
    || return 1
  target=${line#POST }
  target=${target%% *}
  target=${target#*://}       # strip scheme
  target="/${target#*/}"      # strip host, keep the leading slash
  printf '%s' "${#target}"
}

# ── census ───────────────────────────────────────────────────────────────────
cmd_census() {
  local task_id="${1:-}"
  [ -n "$task_id" ] || { usage; exit "$EX_REFUSED"; }
  need_python

  local tmp; tmp=$(scratch_dir)
  local census_saw_unknown=0
  task_json "$task_id" "$tmp/task.json"

  say "criterion census — $task_id"
  say "request-target ceiling ${TARGET_LIMIT} bytes (Bandit max_request_line_length 10000)"
  say ""
  printf '%3s  %-5s  %6s  %5s  %5s  %8s  %s\n' "N" "met" "chars" "btick" "quote" "budget" "hazard"

  local count
  count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["doc"]["content"]["acceptance_criteria"]))' "$tmp/task.json") \
    || die "could not read acceptance_criteria from $task_id"

  local i
  for (( i = 0; i < count; i++ )); do
    criterion_to_file "$tmp/task.json" "$i" "$tmp/c.txt" || { printf '%3s  UNSAFE — see refusal above\n' "$i"; continue; }
    local meta budget spent
    meta=$(python3 - "$tmp/task.json" "$i" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["doc"]["content"]["acceptance_criteria"][int(sys.argv[2])]
t = c["criterion"]
# chr(96) is a backtick. Spelled this way on purpose: a literal backtick inside a
# heredoc nested in $(...) is still scanned by bash's command-substitution parser
# and blows up as an unterminated legacy substitution. A script about quoting
# hazards does not get to have one.
print("%s %d %d %d" % ("yes" if c.get("met") else "no", len(t), t.count(chr(96)), t.count("'")))
PY
)
    spent=$(dry_run_target_bytes "$task_id" "$i" "census" "0" "$tmp/c.txt" "") || spent=""
    if [ -n "$spent" ]; then budget=$(( TARGET_LIMIT - spent )); else budget="?"; census_saw_unknown=1; fi
    # shellcheck disable=SC2086
    set -- $meta
    local hazard="quoted-string safe"
    [ "$4" -gt 0 ] && hazard="single quotes ($4)"
    [ "$3" -gt 0 ] && hazard="BACKTICKS ($3) + quotes ($4) — inline is command substitution"
    printf '%3s  %-5s  %6s  %5s  %5s  %8s  %s\n' "$i" "$1" "$2" "$3" "$4" "$budget" "$hazard"
  done
  say ""
  # A `?` budget is a PROBE FAILURE, not a property of the criterion. Observed in
  # review: criterion 7 printed `?` on one census and 9746 on the next two, same
  # tree, same server — a transient on the dry-run request. Without this legend a
  # lead reading `?` mid-climb has to guess whether the row is dangerous.
  if [ "$census_saw_unknown" = 1 ]; then
    say "One or more budgets read '?': the dry-run probe for that row FAILED — it is not a"
    say "statement that the row has no budget. It is usually transient; re-run the census."
    say "Do NOT stamp against a '?' budget. Get a number first."
    say ""
  fi
  say "Every row above is stamped the SAME way: fetch to file, stamp by \$(cat file)."
  say "There is no 'this one looks fine' row. That judgement is what PDS-D226 forbids."
}

# ── fetch ────────────────────────────────────────────────────────────────────
cmd_fetch() {
  local task_id="${1:-}" idx="${2:-}"; shift 2 2>/dev/null || true
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      *) refuse "unknown flag for fetch: $1" ;;
    esac
  done
  [ -n "$task_id" ] && [ -n "$idx" ] || { usage; exit "$EX_REFUSED"; }
  [ -n "$out" ] || out="$(mktemp -t "pds-crown-c${idx}")" || die "mktemp failed"

  local tmp; tmp=$(scratch_dir)
  task_json "$task_id" "$tmp/task.json"
  criterion_to_file "$tmp/task.json" "$idx" "$out" || exit "$EX_REFUSED"

  say "$out"
  warn "criterion $idx written: $(wc -c <"$out" | tr -d ' ') bytes, no trailing newline"
  warn "stamp it with:  --criterion-text \"\$(cat $out)\""
}

# ── budget ───────────────────────────────────────────────────────────────────
cmd_budget() {
  local task_id="${1:-}" idx="${2:-}"; shift 2 2>/dev/null || true
  local evidence=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence) evidence="${2:-}"; shift 2 ;;
      *) refuse "unknown flag for budget: $1" ;;
    esac
  done
  [ -n "$task_id" ] && [ -n "$idx" ] || { usage; exit "$EX_REFUSED"; }

  local tmp; tmp=$(scratch_dir)
  task_json "$task_id" "$tmp/task.json"
  criterion_to_file "$tmp/task.json" "$idx" "$tmp/c.txt" || exit "$EX_REFUSED"

  report_budget "$task_id" "$idx" "budget-probe" "0" "$tmp/c.txt" "$evidence"
}

# Prints the budget lines and returns 1 if the evidence does not fit.
report_budget() {
  local task_id="$1" idx="$2" worker="$3" epoch="$4" text_file="$5" evidence="$6"
  local bare full budget spent

  bare=$(dry_run_target_bytes "$task_id" "$idx" "$worker" "$epoch" "$text_file" "") \
    || die "could not measure the request target — bp task stamp --dry-run produced no POST line"
  budget=$(( TARGET_LIMIT - bare ))

  say "criterion $idx of $task_id"
  say "  request target with empty evidence : ${bare} bytes"
  say "  ceiling                            : ${TARGET_LIMIT} bytes"
  say "  evidence budget remaining          : ${budget} bytes"

  if [ -z "$evidence" ]; then
    say "  (no evidence supplied — nothing spent)"
    return 0
  fi

  full=$(dry_run_target_bytes "$task_id" "$idx" "$worker" "$epoch" "$text_file" "$evidence") \
    || die "could not measure the request target with evidence attached"
  spent=$(( full - bare ))
  say "  this evidence spends               : ${spent} bytes (encoded)"

  if [ "$full" -gt "$TARGET_LIMIT" ]; then
    warn ""
    warn "REFUSED: evidence overruns the request-target ceiling by $(( full - TARGET_LIMIT )) bytes."
    warn "Nothing was sent. The server is fail-closed here — an oversized stamp writes NOTHING —"
    warn "so the recovery is simply: shorten the evidence and re-run. Never a half-write to reconcile."
    return 1
  fi

  say "  headroom after this stamp          : $(( TARGET_LIMIT - full )) bytes"
  return 0
}

# ── stamp ────────────────────────────────────────────────────────────────────
cmd_stamp() {
  local task_id="${1:-}" idx="${2:-}" worker="${3:-}" epoch="${4:-}"
  shift 4 2>/dev/null || true
  local evidence="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence) evidence="${2:-}"; shift 2 ;;
      --dry-run)  dry=1; shift ;;
      *) refuse "unknown flag for stamp: $1" ;;
    esac
  done
  [ -n "$task_id" ] && [ -n "$idx" ] && [ -n "$worker" ] && [ -n "$epoch" ] \
    || { usage; exit "$EX_REFUSED"; }
  [ -n "$evidence" ] || refuse "--evidence is required and must be non-empty (a met flip without proof is rejected server-side anyway)"

  local tmp; tmp=$(scratch_dir)

  task_json "$task_id" "$tmp/task.json"
  criterion_to_file "$tmp/task.json" "$idx" "$tmp/criterion.txt" || exit "$EX_REFUSED"
  say "fetched criterion $idx to file: $(wc -c <"$tmp/criterion.txt" | tr -d ' ') bytes, exact stored wording"
  say ""

  report_budget "$task_id" "$idx" "$worker" "$epoch" "$tmp/criterion.txt" "$evidence" \
    || exit "$EX_REFUSED"
  say ""

  if [ "$dry" -eq 1 ]; then
    say "--dry-run: not sending. The request that WOULD go out:"
    "$BP_BIN" task stamp "$task_id" "$worker" "$epoch" \
      --criterion "$idx" --met \
      --evidence "$evidence" \
      --criterion-text "$(cat "$tmp/criterion.txt")" \
      --dry-run
    return "$EX_OK"
  fi

  # THE STAMP. --criterion-text comes from the file by command substitution.
  # This single line is the whole point of the script.
  local out rc
  out=$("$BP_BIN" task stamp "$task_id" "$worker" "$epoch" \
      --criterion "$idx" --met \
      --evidence "$evidence" \
      --criterion-text "$(cat "$tmp/criterion.txt")" \
      --yes 2>&1)
  rc=$?
  say "$out"

  if [ "$rc" -ne 0 ]; then
    warn ""
    warn "STAMP REJECTED (exit $rc). Nothing was written — this server is fail-closed on stamps."
    warn ""
    warn "  fenced_off / stale epoch — THE LIKELY ONE ACROSS A LONG CLIMB."
    warn "    \`bp task pulse\` BUMPS THE CLAIM EPOCH. The epoch you were handed at claim time"
    warn "    is dead the moment you pulse, so a stamp run later in the climb with that"
    warn "    original number is fenced out. Nothing is wrong with your text. Re-read the"
    warn "    CURRENT epoch and pass that:"
    warn "        bp task get $task_id -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"doc\"][\"claim\"][\"epoch\"])'"
    warn "    Re-read it after EVERY pulse, not once at the start."
    warn ""
    warn "  criteria_mismatch — the text sent did not match the stored row at index $idx."
    warn "    Do NOT retype it inline; re-run this script (the file path is the fix)."
    exit "$EX_FAILED"
  fi

  # ── READ BACK. A quiet shell is not proof; the stored row is. ──────────────
  say ""
  say "reading back to confirm the flip…"
  task_json "$task_id" "$tmp/after.json"
  local met
  met=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["doc"]["content"]["acceptance_criteria"][int(sys.argv[2])].get("met"))' \
        "$tmp/after.json" "$idx") || die "read-back failed — the stamp may have landed; check by hand"

  if [ "$met" != "True" ] && [ "$met" != "true" ]; then
    warn "READ-BACK FAILED: criterion $idx still reads met=$met after an exit-0 stamp."
    exit "$EX_FAILED"
  fi

  local progress
  progress=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["doc"].get("criteria_progress",{}); print("%s/%s"%(p.get("met"),p.get("total")))' "$tmp/after.json")
  say "CONFIRMED: criterion $idx reads met — $task_id is now at ${progress}."
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    census) cmd_census "$@" ;;
    fetch)  cmd_fetch  "$@" ;;
    budget) cmd_budget "$@" ;;
    stamp)  cmd_stamp  "$@" ;;
    -h|--help|help|"") usage ;;
    *) warn "unknown command: $cmd"; usage; exit "$EX_REFUSED" ;;
  esac
}

main "$@"
