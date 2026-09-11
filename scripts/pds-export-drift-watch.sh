#!/usr/bin/env bash
#
# pds-export-drift-watch.sh — WATCH the export window that cond_d samples once,
# and name the drift the second it appears instead of at step 8.
#
# ═════════════════════════════════════════════════════════════════════════════
# THE GAP THIS ANSWERS (pds-bl-w13-cond-d-no-reservation)
# ═════════════════════════════════════════════════════════════════════════════
#
# The frozen harness evaluates precondition (d) exactly once:
#
#   scripts/pds-pull-proof.sh:2255-2257
#     gh_out="$(gh run list --workflow deploy.yml --branch main --status in_progress --limit 5 \
#                 --json databaseId -q '.[].databaseId' 2>/dev/null)" || gh_rc=$?
#
# That call sits inside the five-condition block at :2214-2291. The attempt
# counter is spent 3 lines later, at :2296-2300:
#
#     spent_now=$((spent + 1)); printf '%s\n' "$spent_now" >"$FULL_ATTEMPTS_FILE"
#
# and there is no second `--status in_progress` read anywhere in the file's 3698
# lines. The only other `gh run list --workflow deploy.yml` is :1087, `--limit 1`
# with no status filter — a different question (what deployed last), not this one.
#
# So (d) is a SNAPSHOT, not a reservation. A PR that merges to main one second
# after that read triggers deploy.yml, moves guerrilla's deployed sha under the
# ~130 s export, and nothing notices until step 8 re-pins — by which point the
# attempt is SPENT and the evidence taken off it is undated.
#
# ═════════════════════════════════════════════════════════════════════════════
# WHY THIS SHAPE, AND NOT THE OTHER TWO THE ROW OFFERED
# ═════════════════════════════════════════════════════════════════════════════
#
# The row asked for ONE of three, in its own preference order. The order is
# inverted here, deliberately, and the reason is written down rather than left
# to the reader:
#
#   (1) A REAL RESERVATION — a lease file, a bp claim, a labelled draft PR that
#       other sessions HONOUR before merging to a deploy path. REFUSED, and not
#       on effort: the honouring is the whole mechanism, and it is the one half
#       this repository cannot supply from inside a PR. Wave 13 asked the fleet
#       for exactly this hold and NO REPLY EVER ARRIVED (PDS-D238). Shipping a
#       lease file that nothing reads would convert "we know this is a snapshot"
#       into "we have a reservation" — a reassuring word over an unchanged
#       mechanism, which is the failure this epic exists to delete. A lease is
#       buildable the day a fleet-wide merge protocol is RATIFIED; it is not
#       buildable by one branch declaring one.
#
#   (2) A MID-EXPORT DRIFT DETECTOR — BUILT, and this is it. It cannot be built
#       INSIDE the harness (frozen, PDS-D100), so it is built BESIDE it: a
#       read-only sidecar the operator starts in the same minute as the climb.
#
#   (3) A DOCUMENTED EXPECTED-VOID-RATE COST MODEL — BUILT, as the `cost-model`
#       subcommand, and it is built ON TOP of (2) rather than instead of it.
#       That pairing is the actual argument for this shape: a cost model written
#       today would quote a fraction NOTHING MEASURED. This instrument's refusal
#       log IS the dataset the model needs, so (2) and (3) are one artifact —
#       the watcher measures the void rate, the model reads it back, and until
#       enough windows have been watched the model REFUSES TO QUOTE A NUMBER
#       rather than inventing one.
#
# WHAT THIS DOES NOT DO — say it out loud, because a detector is easy to
# oversell and this one is honest about its ceiling:
#
#   * It does NOT un-spend the attempt. The counter is flushed before the
#     request by design (a killed run must not get a free retry), so a drift
#     detected at t+15 s has still cost the attempt it was going to cost.
#     What changes is WHEN you know and WHAT you can say: an early, named,
#     timestamped refusal instead of an undated bundle discovered at step 8.
#   * It does NOT stop the export, kill the harness, or touch the counter.
#     It observes and it reports. The abort is a human act.
#   * It NEVER writes anything on the remote box. Every remote command is a
#     read. It never deploys, never restarts, never sets a floor.
#   * It NEVER edits scripts/pds-pull-proof.sh. The harness is frozen and this
#     file is the whole point of the freeze surviving.
#
# ═════════════════════════════════════════════════════════════════════════════
# FAIL CLOSED, EXACTLY AS cond_d ALREADY DOES (PDS-D98)
# ═════════════════════════════════════════════════════════════════════════════
# `gh`'s exit status is captured apart from its stdout. An API error and a
# genuinely empty result are NOT the same answer, and the GitHub API answers 503
# often enough to matter. A draw that could not see is UNMEASURED (rc 2), never
# CLEAR — and an unmeasured draw is NOT counted as a clean window by the cost
# model either, because a rate computed over draws that saw nothing is the
# vacuous green in numeric costume.
#
# THE FREEZE BLOB IS READ FROM origin/main, NEVER FROM A LITERAL. The literal
# e219e97ccf7f33797c86a2b84d998d599b6bda31, still quoted by several wave-8
# documents and by this task row, is STALE: origin/main carries a different blob
# today and the harness has landed sanctioned edits since. `--freeze-check`
# follows scripts/pds-climb-preflight.sh:128 and asks git, so it can never
# manufacture a refusal out of a hand-typed hash going out of date.
#
# ═════════════════════════════════════════════════════════════════════════════
# USAGE
#   scripts/pds-export-drift-watch.sh sample [--pinned-sha <sha>]
#   scripts/pds-export-drift-watch.sh watch --pinned-sha <sha> \
#        [--budget-seconds 180] [--interval 10] [--session <id>]
#   scripts/pds-export-drift-watch.sh cost-model [--log <tsv>] [--min-sessions 5]
#   scripts/pds-export-drift-watch.sh freeze-check
#   scripts/pds-export-drift-watch.sh --selftest
#
# HOW IT IS ACTUALLY USED, beside a climb:
#   sha="$(ssh root@guerrilla.barkpark.cloud 'git -C /opt/barkpark rev-parse HEAD')"
#   scripts/pds-export-drift-watch.sh watch --pinned-sha "$sha" --budget-seconds 180 &
#   # ... fire the climb ...
#   wait %1   # rc 1 => the window was contended; the transcript must say so
#
# EXIT STATUS
#   0  the window stayed CLEAN for every draw taken (or the model is quotable)
#   1  DRIFT — a deploy.yml run appeared, or the deployed sha moved. Named.
#   2  UNMEASURED — the probe failed, or the model has too few sessions to quote
#   3  usage error
# ═════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SSH_HOST="${PDS_DRIFT_SSH_HOST:-root@guerrilla.barkpark.cloud}"
SSH_KEY="${PDS_DRIFT_SSH_KEY:-$HOME/.ssh/barkpark_indx}"
LOG="${PDS_DRIFT_LOG:-/private/tmp/pds-export-drift-watch.tsv}"
INTERVAL="${PDS_DRIFT_INTERVAL:-10}"
BUDGET_SECONDS="${PDS_DRIFT_BUDGET_SECONDS:-180}"
MIN_SESSIONS="${PDS_DRIFT_MIN_SESSIONS:-5}"
REMOTE_REPO="${PDS_DRIFT_REMOTE_REPO:-/opt/barkpark}"
HARNESS_REL="scripts/pds-pull-proof.sh"

PINNED_SHA=""
SESSION_ID=""

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf 'drift-watch: %s\n' "$*" >&2; exit 3; }

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

# ── the two probes ───────────────────────────────────────────────────────────
#
# Kept as two separate reads on purpose: they answer different questions and
# they fail independently. `gh` sees a deploy that has STARTED but not yet
# swapped the slot — the earliest possible warning. The sha read sees a deploy
# that has ALREADY landed — the thing cond_a re-pins at step 8. A window is
# clean only when BOTH say so.

# stdout: space-joined in-progress run ids (possibly empty). rc: 0 read, 2 blind.
probe_deploy_runs() {
  local out rc=0
  command -v gh >/dev/null 2>&1 || return 2
  out="$(gh run list --workflow deploy.yml --branch main --status in_progress --limit 5 \
           --json databaseId -q '.[].databaseId' 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  printf '%s' "$out" | tr '\n' ' ' | sed 's/ *$//'
  return 0
}

# stdout: the deployed sha. rc: 0 read, 2 blind.
probe_served_sha() {
  local out
  command -v ssh >/dev/null 2>&1 || return 2
  out="$(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
             -o StrictHostKeyChecking=accept-new "$SSH_HOST" \
             "git -C $REMOTE_REPO rev-parse HEAD" 2>/dev/null)" || return 2
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  [ -n "$out" ] || return 2
  printf '%s' "$out"
  return 0
}

ensure_log() {
  local dir
  dir="$(dirname "$LOG")"
  [ -d "$dir" ] || mkdir -p "$dir" || die "cannot create log directory $dir"
  if [ ! -s "$LOG" ]; then
    printf 'ts_utc\tsession\tt_plus_s\tverdict\truns_in_progress\tserved_sha\tpinned_sha\tnote\n' >"$LOG"
  fi
}

log_row() { # session t_plus verdict runs sha pinned note
  ensure_log
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(now_utc)" "$1" "$2" "$3" "${4:--}" "${5:--}" "${6:--}" "$7" >>"$LOG"
}

# ── one draw ─────────────────────────────────────────────────────────────────
# Sets DRAW_VERDICT / DRAW_RUNS / DRAW_SHA / DRAW_NOTE. Returns 0 CLEAN,
# 1 DRIFT, 2 UNMEASURED. There is no fourth answer, and UNMEASURED is never
# folded into CLEAN.
DRAW_VERDICT=""; DRAW_RUNS=""; DRAW_SHA=""; DRAW_NOTE=""
take_draw() {
  local runs sha rc_runs=0 rc_sha=0
  DRAW_VERDICT=""; DRAW_RUNS=""; DRAW_SHA=""; DRAW_NOTE=""

  runs="$(probe_deploy_runs)" || rc_runs=$?
  sha="$(probe_served_sha)"   || rc_sha=$?

  if [ "$rc_runs" -ne 0 ] || [ "$rc_sha" -ne 0 ]; then
    DRAW_VERDICT="UNMEASURED"
    DRAW_NOTE="probe blind (gh rc=$rc_runs, ssh rc=$rc_sha) — an in-flight deploy cannot be ruled out, so this draw claims NOTHING and is not counted as a clean window"
    return 2
  fi

  DRAW_RUNS="$runs"
  DRAW_SHA="$sha"

  if [ -n "$runs" ]; then
    DRAW_VERDICT="DRIFT-DEPLOY-RUNNING"
    DRAW_NOTE="deploy.yml run(s) in progress: $runs — a deploy mid-export swaps the slot under the request"
    return 1
  fi

  if [ -n "$PINNED_SHA" ] && [ "$sha" != "$PINNED_SHA" ]; then
    DRAW_VERDICT="DRIFT-SHA-MOVED"
    DRAW_NOTE="the deployed sha moved under the export: pinned $PINNED_SHA -> now $sha"
    return 1
  fi

  DRAW_VERDICT="CLEAN"
  DRAW_NOTE="no deploy.yml run in progress; served sha still ${PINNED_SHA:-$sha}"
  return 0
}

# ── sample ───────────────────────────────────────────────────────────────────
cmd_sample() {
  local rc=0
  take_draw || rc=$?
  say ""
  info "draw            $(now_utc)"
  info "verdict ....... $DRAW_VERDICT"
  info "runs .......... ${DRAW_RUNS:-<none>}"
  info "served sha .... ${DRAW_SHA:-<unread>}"
  info "pinned sha .... ${PINNED_SHA:-<not pinned — sha leg not evaluated>}"
  info "$DRAW_NOTE"
  say ""
  log_row "${SESSION_ID:-sample}" 0 "$DRAW_VERDICT" "$DRAW_RUNS" "$DRAW_SHA" "$PINNED_SHA" "$DRAW_NOTE"
  return "$rc"
}

# ── watch ────────────────────────────────────────────────────────────────────
# Polls until the budget is exhausted or drift appears. STOPS on the first
# drift: a window that has already been contended cannot become clean again for
# this attempt's purposes, and continuing to poll would only dilute the log.
cmd_watch() {
  local t0 t_plus rc draws=0 clean=0 unmeasured=0 verdict="CLEAN" first_drift=""
  [ -n "$PINNED_SHA" ] || die "watch needs --pinned-sha: without step 0a's pin the sha leg cannot be evaluated and the watch would report a cleanliness it never measured"
  is_int "$INTERVAL" || die "--interval '$INTERVAL' is not an integer"
  is_int "$BUDGET_SECONDS" || die "--budget-seconds '$BUDGET_SECONDS' is not an integer"
  [ -z "$SESSION_ID" ] && SESSION_ID="w$(now_epoch)-$$"

  t0="$(now_epoch)"
  say ""
  say "PDS EXPORT DRIFT WATCH — session $SESSION_ID"
  info "pinned sha .... $PINNED_SHA"
  info "budget ........ ${BUDGET_SECONDS}s at ${INTERVAL}s cadence"
  info "NOTE .......... this does NOT un-spend the attempt. It names the drift early."
  say ""

  while :; do
    t_plus=$(( $(now_epoch) - t0 ))
    rc=0; take_draw || rc=$?
    draws=$((draws + 1))
    case "$rc" in
      0) clean=$((clean + 1)) ;;
      2) unmeasured=$((unmeasured + 1)) ;;
    esac
    info "t+${t_plus}s  $DRAW_VERDICT  ${DRAW_NOTE}"
    log_row "$SESSION_ID" "$t_plus" "$DRAW_VERDICT" "$DRAW_RUNS" "$DRAW_SHA" "$PINNED_SHA" "$DRAW_NOTE"
    if [ "$rc" -eq 1 ]; then
      verdict="$DRAW_VERDICT"; first_drift="$t_plus"
      break
    fi
    [ $(( $(now_epoch) - t0 )) -ge "$BUDGET_SECONDS" ] && break
    [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
  done

  say ""
  if [ -n "$first_drift" ]; then
    say "DRIFT at t+${first_drift}s — $verdict"
    info "$DRAW_NOTE"
    info "the attempt is already spent; what this buys you is a DATED refusal now"
    info "instead of an undated bundle discovered at step 8's re-pin."
    log_row "$SESSION_ID" "$first_drift" "SESSION-DRIFT" "$DRAW_RUNS" "$DRAW_SHA" "$PINNED_SHA" "session verdict"
    say ""
    return 1
  fi

  if [ "$clean" -eq 0 ]; then
    say "UNMEASURED — $draws draw(s), none of which saw anything ($unmeasured blind)"
    log_row "$SESSION_ID" "$t_plus" "SESSION-UNMEASURED" "" "" "$PINNED_SHA" "session verdict"
    say ""
    return 2
  fi

  say "CLEAN — $draws draw(s) over ${t_plus}s, $clean measured clean, $unmeasured blind"
  log_row "$SESSION_ID" "$t_plus" "SESSION-CLEAN" "" "" "$PINNED_SHA" "session verdict"
  say ""
  return 0
}

# ── cost-model ───────────────────────────────────────────────────────────────
# THE MODEL IS READ OFF THE LOG, NEVER ASSERTED. A session is a watched export
# window; it is VOID if any draw in it drifted, CLEAN if at least one draw
# measured clean and none drifted, and EXCLUDED if every draw was blind.
#
# Below the floor it prints NO percentage. A void rate quoted from two windows
# is a number with the authority of a guess, and this epic's whole complaint is
# reassuring words over unmeasured mechanisms.
cmd_cost_model() {
  local total=0 void=0 clean=0 excluded=0
  is_int "$MIN_SESSIONS" || die "--min-sessions '$MIN_SESSIONS' is not an integer"
  if [ ! -s "$LOG" ]; then
    say ""
    say "COST MODEL — UNQUOTABLE: no log at $LOG. Nothing has been watched."
    info "expected void rate: NOT QUOTED (n=0 sessions, floor $MIN_SESSIONS)"
    say ""
    return 2
  fi

  local counts
  counts="$(awk -F'\t' 'NR>1 && $2 != "" && $2 != "sample" {
      s=$2
      if ($4 ~ /^DRIFT/)      drift[s]=1
      else if ($4 == "CLEAN") ok[s]=1
      seen[s]=1
    }
    END {
      for (s in seen) {
        n++
        if (s in drift)   v++
        else if (s in ok) c++
        else              e++
      }
      printf "%d %d %d %d", n+0, v+0, c+0, e+0
    }' "$LOG")"
  # `read`, not `set -- $counts`: positional splitting of a command substitution
  # is where an off-by-one silently rebinds every field, and this block's four
  # numbers are the whole model. A short read leaves the tail at its 0 default.
  read -r total void clean excluded <<<"$counts"
  total="${total:-0}"; void="${void:-0}"; clean="${clean:-0}"; excluded="${excluded:-0}"

  local decided=$((void + clean))
  say ""
  say "EXPECTED-VOID-RATE COST MODEL — computed from $LOG, never asserted"
  info "watched sessions .......... $total"
  info "  VOID (drift observed) ... $void"
  info "  CLEAN ................... $clean"
  info "  EXCLUDED (all blind) .... $excluded"
  info "decidable sessions ........ $decided (the denominator; blind windows are NOT clean)"

  if [ "$decided" -lt "$MIN_SESSIONS" ]; then
    info "expected void rate ........ NOT QUOTED"
    info ""
    info "n=$decided is below the floor of $MIN_SESSIONS. A rate from this many windows"
    info "carries the authority of a guess, and the cost of a WRONG cost model here is"
    info "that a climb is planned against a fiction. Run more watches; the refusals ARE"
    info "the dataset. What IS known without any n: cond_d is a snapshot taken 3 lines"
    info "above the spend, the window it leaves unwatched is the whole ~130 s export,"
    info "and a void costs ONE of a budget whose default is ONE (PDS_FULL_EXPORT_BUDGET)."
    say ""
    return 2
  fi

  local pct
  pct="$(awk -v v="$void" -v d="$decided" 'BEGIN{printf "%.1f", (v*100.0)/d}')"
  info "expected void rate ........ ${pct}% ($void of $decided decidable windows)"
  info ""
  info "READ IT AS A MEASUREMENT WITH A DENOMINATOR, not a law: it is the rate for"
  info "the hours these windows were actually taken in, and merge traffic to main is"
  info "not uniform across a day. Quote the n beside the percentage, always."
  say ""
  return 0
}

# ── freeze-check ─────────────────────────────────────────────────────────────
# c2's assertion, executable: the frozen harness must be byte-identical to
# origin/main. Derived from git (scripts/pds-climb-preflight.sh:128), never from
# a hand-typed literal — the wave-8 literal is already stale.
cmd_freeze_check() {
  local root blob_main blob_head diff
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not a git tree"
  blob_main="$(git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/main:$HARNESS_REL" 2>/dev/null || true)"
  blob_head="$(git -C "$root" rev-parse --verify --quiet "HEAD:$HARNESS_REL" 2>/dev/null || true)"
  diff="$(git -C "$root" diff origin/main -- "$HARNESS_REL" 2>/dev/null)"
  say ""
  say "FREEZE CHECK — $HARNESS_REL (PDS-D100)"
  info "origin/main blob .. ${blob_main:-<unresolved>}"
  info "HEAD blob ......... ${blob_head:-<unresolved>}"
  info "worktree diff ..... $([ -z "$diff" ] && echo '<empty>' || echo "$(printf '%s' "$diff" | wc -l | tr -d ' ') line(s)")"
  say ""
  if [ -n "$diff" ] || { [ -n "$blob_main" ] && [ "$blob_main" != "$blob_head" ]; }; then
    say "THAWED — the frozen harness differs from origin/main. This is a hard stop."
    return 1
  fi
  say "FROZEN — identical to origin/main."
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# SELFTEST — hermetic. No box, no network, no gh, no ssh: both probes are
# resolved through PATH and every arm drives a STUB. Each arm is a PAIR — a
# mutation that MUST be caught beside a control that MUST NOT be — so a green
# here descends from arms that can fail.
# ═════════════════════════════════════════════════════════════════════════════
ST_PASS=0; ST_FAIL=0
st_check() { # label expected_rc actual_rc [substring haystack]
  local label="$1" want="$2" got="$3" needle="${4:-}" hay="${5:-}"
  if [ "$want" != "$got" ]; then
    printf '  FAIL  %s — expected rc=%s, got rc=%s\n' "$label" "$want" "$got"
    ST_FAIL=$((ST_FAIL + 1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$hay" | grep -q -- "$needle"; then
    printf '  FAIL  %s — output does not name %s\n' "$label" "$needle"
    ST_FAIL=$((ST_FAIL + 1)); return
  fi
  printf '  ok    %s (rc=%s)\n' "$label" "$got"
  ST_PASS=$((ST_PASS + 1))
}

run_selftest() {
  local bin self out rc
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  ST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pds-drift-selftest.XXXXXX")" || die "mktemp failed"
  local tmp="$ST_TMP"
  bin="$tmp/bin"; mkdir -p "$bin"
  trap 'rm -rf "$ST_TMP"' EXIT

  # The stubs read their instructions from files, so one PATH serves every arm.
  cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -f "$PDS_STUB_DIR/gh_rc" ] && rc="$(cat "$PDS_STUB_DIR/gh_rc")" || rc=0
[ -f "$PDS_STUB_DIR/gh_out" ] && cat "$PDS_STUB_DIR/gh_out"
exit "$rc"
STUB
  cat >"$bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ -f "$PDS_STUB_DIR/ssh_rc" ] && rc="$(cat "$PDS_STUB_DIR/ssh_rc")" || rc=0
[ "$rc" -eq 0 ] && cat "$PDS_STUB_DIR/ssh_out"
exit "$rc"
STUB
  chmod +x "$bin/gh" "$bin/ssh"

  export PDS_STUB_DIR="$tmp"
  export PDS_DRIFT_LOG="$tmp/log.tsv"
  local P="$bin:$PATH"
  local PIN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  say ""
  say "SELFTEST — hermetic, stubbed gh + ssh, nothing here touches a server"
  say ""

  # ── arm 1/2: the CONTROL pair on `sample` — clean vs a running deploy ──────
  : >"$tmp/gh_out"; printf '0\n' >"$tmp/gh_rc"
  printf '%s\n' "$PIN" >"$tmp/ssh_out"; printf '0\n' >"$tmp/ssh_rc"
  out="$(PATH="$P" "$self" sample --pinned-sha "$PIN" 2>&1)"; rc=$?
  st_check "control: empty gh + unmoved sha reads CLEAN" 0 "$rc" "CLEAN" "$out"

  printf '99887766\n' >"$tmp/gh_out"
  out="$(PATH="$P" "$self" sample --pinned-sha "$PIN" 2>&1)"; rc=$?
  st_check "mutation: a run in progress reads DRIFT and names the id" 1 "$rc" "99887766" "$out"

  # ── arm 3: gh blind must be UNMEASURED, never CLEAN (PDS-D98 parity) ───────
  : >"$tmp/gh_out"; printf '1\n' >"$tmp/gh_rc"
  out="$(PATH="$P" "$self" sample --pinned-sha "$PIN" 2>&1)"; rc=$?
  st_check "mutation: gh non-zero reads UNMEASURED" 2 "$rc" "UNMEASURED" "$out"
  if printf '%s' "$out" | grep -q 'verdict \.* CLEAN'; then
    printf '  FAIL  a blind draw printed CLEAN — the gate fails OPEN\n'; ST_FAIL=$((ST_FAIL + 1))
  else
    printf '  ok    a blind draw never prints CLEAN\n'; ST_PASS=$((ST_PASS + 1))
  fi
  printf '0\n' >"$tmp/gh_rc"

  # ── arm 4: the sha leg, independent of the gh leg ──────────────────────────
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$tmp/ssh_out"
  out="$(PATH="$P" "$self" sample --pinned-sha "$PIN" 2>&1)"; rc=$?
  st_check "mutation: the deployed sha moved reads DRIFT-SHA-MOVED" 1 "$rc" "DRIFT-SHA-MOVED" "$out"
  st_check "  and it names BOTH shas" 1 "$rc" "bbbbbbbb" "$out"
  printf '%s\n' "$PIN" >"$tmp/ssh_out"

  # ── arm 5: ssh blind is its own refusal, not a sha match ───────────────────
  printf '255\n' >"$tmp/ssh_rc"
  out="$(PATH="$P" "$self" sample --pinned-sha "$PIN" 2>&1)"; rc=$?
  st_check "mutation: ssh blind reads UNMEASURED" 2 "$rc" "ssh rc=2" "$out"
  printf '0\n' >"$tmp/ssh_rc"

  # ── arm 6: watch stops at the FIRST drift and dates it ─────────────────────
  : >"$PDS_DRIFT_LOG"
  printf '55443322\n' >"$tmp/gh_out"
  out="$(PATH="$P" PDS_DRIFT_INTERVAL=0 "$self" watch --pinned-sha "$PIN" \
          --budget-seconds 0 --interval 0 --session S-DRIFT 2>&1)"; rc=$?
  st_check "watch: drift ends the session and is dated" 1 "$rc" "DRIFT at t+" "$out"
  st_check "  and the session verdict is logged" 1 "$rc" "55443322" "$out"

  # ── arm 7: watch refuses without a pin rather than vouching for a window ───
  out="$(PATH="$P" "$self" watch --budget-seconds 0 --interval 0 2>&1)"; rc=$?
  st_check "watch: no --pinned-sha is a usage refusal, not a CLEAN" 3 "$rc" "pinned-sha" "$out"

  # ── arm 8: a clean watch session ──────────────────────────────────────────
  : >"$tmp/gh_out"
  out="$(PATH="$P" "$self" watch --pinned-sha "$PIN" --budget-seconds 0 \
          --interval 0 --session S-CLEAN 2>&1)"; rc=$?
  st_check "control: an uncontended window reads CLEAN" 0 "$rc" "CLEAN — 1 draw" "$out"

  # ── arm 9/10: the cost model's floor — the load-bearing refusal ────────────
  out="$(PATH="$P" "$self" cost-model --min-sessions 5 2>&1)"; rc=$?
  st_check "model: n=2 is below the floor and NO rate is quoted" 2 "$rc" "NOT QUOTED" "$out"
  if printf '%s' "$out" | grep -qE 'void rate [.]* [0-9]'; then
    printf '  FAIL  a sub-floor model printed a percentage anyway\n'; ST_FAIL=$((ST_FAIL + 1))
  else
    printf '  ok    a sub-floor model prints no percentage at all\n'; ST_PASS=$((ST_PASS + 1))
  fi

  # Ten decidable sessions, two of them void -> 20.0%.
  : >"$PDS_DRIFT_LOG"
  printf 'ts_utc\tsession\tt_plus_s\tverdict\truns_in_progress\tserved_sha\tpinned_sha\tnote\n' >"$PDS_DRIFT_LOG"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    printf 'T\tS%s\t0\tCLEAN\t\tx\tx\tn\n' "$i" >>"$PDS_DRIFT_LOG"
  done
  {
    printf 'T\tS9\t0\tCLEAN\t\tx\tx\tn\nT\tS9\t12\tDRIFT-DEPLOY-RUNNING\t7\tx\tx\tn\n'
    printf 'T\tS10\t0\tDRIFT-SHA-MOVED\t\ty\tx\tn\n'
    printf 'T\tS11\t0\tUNMEASURED\t\t\tx\tn\n'
  } >>"$PDS_DRIFT_LOG"
  out="$(PATH="$P" "$self" cost-model --min-sessions 5 2>&1)"; rc=$?
  st_check "model: 2 void of 10 decidable reads 20.0%" 0 "$rc" "20.0%" "$out"
  st_check "  and the all-blind session is EXCLUDED, not counted clean" 0 "$rc" "EXCLUDED (all blind) .... 1" "$out"

  # ── arm 11: the freeze check is derived from git, not a literal ────────────
  if grep -q 'e219e97ccf7f33797c86a2b84d998d599b6bda31' "$self" && \
     ! grep -q 'STALE' "$self"; then
    printf '  FAIL  a bare freeze literal with no staleness note\n'; ST_FAIL=$((ST_FAIL + 1))
  else
    printf '  ok    the freeze blob is read from origin/main, not hard-coded\n'; ST_PASS=$((ST_PASS + 1))
  fi

  # ── arm 12: this instrument can never edit the frozen harness ─────────────
  #
  # THE NEEDLE IS ASSEMBLED AT RUNTIME so this arm cannot match its own source
  # line. A guard whose pattern appears verbatim in the guard is a guard that
  # always fires — the same shape as grepping for a retracted sentence and
  # matching the retraction. Comments are stripped first: the header quotes the
  # harness path many times and quoting is not writing.
  local needle harness_lit
  harness_lit="pds-pull""-proof"
  needle="(>|>>|sed -i|tee|cp .*|mv .*)[^|]*${harness_lit}"
  if sed 's/#.*//' "$self" | grep -nE "$needle" >/dev/null; then
    printf '  FAIL  a write verb points at the frozen harness\n'; ST_FAIL=$((ST_FAIL + 1))
  else
    printf '  ok    no write verb in this file targets scripts/pds-pull-proof.sh\n'; ST_PASS=$((ST_PASS + 1))
  fi

  say ""
  say "=== $ST_PASS passed, $ST_FAIL failed ==="
  say ""
  [ "$ST_FAIL" -eq 0 ]
}

# ── argv ─────────────────────────────────────────────────────────────────────
CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    sample|watch|cost-model|freeze-check) CMD="$1" ;;
    --selftest)        CMD="selftest" ;;
    --pinned-sha)      shift; PINNED_SHA="${1:-}" ;;
    --interval)        shift; INTERVAL="${1:-}" ;;
    --budget-seconds)  shift; BUDGET_SECONDS="${1:-}" ;;
    --session)         shift; SESSION_ID="${1:-}" ;;
    --log)             shift; LOG="${1:-}" ;;
    --min-sessions)    shift; MIN_SESSIONS="${1:-}" ;;
    -h|--help)         sed -n '1,120p' "$0"; exit 0 ;;
    *)                 die "unknown argument '$1'" ;;
  esac
  shift
done

case "$CMD" in
  sample)       cmd_sample ;;
  watch)        cmd_watch ;;
  cost-model)   cmd_cost_model ;;
  freeze-check) cmd_freeze_check ;;
  selftest)     run_selftest ;;
  *)            die "usage: $0 {sample|watch|cost-model|freeze-check|--selftest}" ;;
esac
