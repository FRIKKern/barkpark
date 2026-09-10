#!/usr/bin/env bash
# pulse-loop.sh <worker> <held-file> <log> — THE pulse loop. Every lead calls this instead of
# writing its own `while true; do ... done` keep-alive.
#
# WHY THIS FILE EXISTS. Every lane copied the shape LEAD-BRIEF.md prescribes ("stops loudly after
# three refusals") and every copy counted ANY refused pulse as a strike. But the brief also tells
# leads to over-pulse rather than tidy, so a row the lead CLOSES stays on the held file and the
# server refuses its pulse with `not_in_progress:done` on EVERY round, forever. Measured
# 2026-09-10T00:05Z in this campaign: three closes in one shift put three permanent refusals on
# the list, the loop hit `STOPPING: 3 refused rounds`, and the NINE LIVE rows on the same file
# went unpulsed for 40 minutes — one lease-lapse away from `bp task ready` re-offering rows with
# open PRs and a red pr-task-gate ("carries no claim") on every one. Nothing alarmed; the lead
# happened to read the log.
#
# The three-strike rule was built for a DEAD SERVER or a STOLEN CLAIM. `not_in_progress:*` is
# neither: it is the loop's own LIST going stale, and the honest action is to drop that id from
# the round and say so — never to count it against the live rows.
#
# RULES it implements:
#   * `not_in_progress:*` (done / blocked / any lifecycle refusal) => the row LEFT THE POOL:
#     dropped from THIS round with a logged `DROPPED` line, and NEVER a strike. Non-sticky: the
#     held file is the input, so the row is retried next round and self-heals if it reopens.
#   * Strikes count ONLY claim-in-doubt refusals — `not_holder`, `stale_claim`, 5xx, timeouts,
#     and any refusal this file does not recognise (an unknown refusal is in doubt by default).
#   * Strikes are PER ROW, not per round: one hostile row can never stop the pulses for the
#     others. THREE CONSECUTIVE claim-in-doubt rounds on ONE row exits 3 NAMING that row.
#     A successful pulse resets that row's counter; a `not_in_progress` drop leaves it untouched
#     (a row that left the pool is not evidence about the claim either way).
#   * A 5xx round DROPS NOTHING: every id stays on the list and each one takes one strike.
#   * Every refusal goes to STDERR *and* to the log. A background loop whose only output is a log
#     file is silent by construction (LEAD-BRIEF.md, 2026-09-02).
#   * The HELD FILE IS RE-READ FRESH EVERY ROUND — a lead appends to it while the loop runs.
#   * Interval 1080 s (18 min), floored. PULSE_LOOP_ALLOW_FAST=1 lifts the floor — SELFTEST ONLY.
#   * Every ledger call is exactly:
#       env -u BARKPARK_TOKEN bp task pulse <id> <worker> --now "<text>" --yes -o json
#     `--now` is not optional: main's five pulse loops omitted it, were refused 15 of 15 times,
#     and three claims lapsed.
#
# USAGE
#   pulse-loop.sh lead-cli "$ORCH/lead-cli/held.txt" "$ORCH/lead-cli/pulse.log"        # forever
#   pulse-loop.sh --once lead-cli held.txt pulse.log     # one round, then exit (foreground check)
#   pulse-loop.sh --selftest                             # hermetic, no network, stub bp on PATH
#
# FLAGS
#   --once / --passes N   stop after N rounds (default: forever).
#   --interval N          seconds between rounds (default 1080, floor 1080).
#   --note TEXT           the --now text (default "<worker> holding; PR/verification in flight").
#
# EXIT: 0 = rounds exhausted. 2 = bad arguments / unreadable held file. 3 = a row hit three
#       consecutive claim-in-doubt rounds (the line names it).
set -u
SELF="${BASH_SOURCE[0]}"

# ------------------------------------------------------------------ SELFTEST (no network) ----
# Drives the helper against a stub `bp` on PATH. Arms:
#   a) a CLOSED row is dropped (logged, not a strike) and the OTHER rows on the list are still
#      pulsed IN THE SAME ROUND — over three rounds, so the run must still exit 0.
#   b) three consecutive not_holder rounds on ONE row exits 3 NAMING that row, while the healthy
#      row on the same list keeps being pulsed right up to the stop.
#   c) a 5xx round drops nothing (both rows pulsed again next round) and is ONE strike per row.
#   d) the ledger call shape: `task pulse <id> <worker> --now <text> --yes -o json`, with
#      BARKPARK_TOKEN UNSET in the child even though the caller exported one.
#   e) the held file is re-read FRESH every round: a row appended mid-run gets pulsed.
# MUTATION that must red arm (a): count `not_in_progress` as a claim-in-doubt strike (i.e. delete
# the `not_in_progress` branch of classify()). Arm (a) then exits 3 on the closed row — which is
# the production incident, reproduced.
selftest() {
  local d rc out fails=0
  _ind() { while IFS= read -r _l; do printf '      | %s\n' "$_l"; done; }
  d=$(mktemp -d) || return 1
  mkdir -p "$d/bin" "$d/reply" "$d/count"

  # Stub bp: line N of reply/<id> on round N (last line repeats). Tokens:
  #   ok | not_in_progress:done | not_holder | stale_claim | 5xx | append:<id>
  cat > "$d/bin/bp" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
if [ -n "${BARKPARK_TOKEN+x}" ]; then echo "TOKEN_PRESENT" >> "$STUB_DIR/argv.log"; else echo "TOKEN_UNSET" >> "$STUB_DIR/argv.log"; fi
id="$3"
f="$STUB_DIR/reply/$id"
n=1; [ -f "$STUB_DIR/count/$id" ] && n=$(cat "$STUB_DIR/count/$id")
echo $((n+1)) > "$STUB_DIR/count/$id"
line=""; [ -f "$f" ] && { line=$(sed -n "${n}p" "$f"); [ -n "$line" ] || line=$(tail -1 "$f"); }
[ -n "$line" ] || line=ok
case "$line" in
  append:*) printf '%s\n' "${line#append:}" >> "$STUB_DIR/held"; line=ok;;
esac
case "$line" in
  ok)   echo '{"ok":true,"doc":{"claim":{"epoch":'"$n"'}}}'; exit 0;;
  5xx)  echo '{"ok":false,"error":"http 503 upstream unavailable"}' >&2; exit 1;;
  *)    echo '{"ok":false,"error":"'"$line"'"}' >&2; exit 1;;
esac
STUB
  chmod +x "$d/bin/bp"

  _run() { # _run <label> <expected-exit> <passes> ; stdout+stderr in $out, rc in $rc
    local label="$1" wantrc="$2" passes="$3"
    : > "$d/log"; : > "$d/argv.log"; : > "$d/err"; rm -f "$d/count/"*
    # stdout and stderr are captured SEPARATELY: loud() writes a refusal to both, so a combined
    # capture would count every refusal twice and no assertion here would mean what it says.
    out=$(PATH="$d/bin:$PATH" STUB_DIR="$d" BARKPARK_TOKEN=would-be-wrong PULSE_LOOP_ALLOW_FAST=1 \
          bash "$SELF" --interval 0 --passes "$passes" lead-test "$d/held" "$d/log" 2>"$d/err"); rc=$?
    if [ "$rc" != "$wantrc" ]; then
      echo "FAIL $label: exit $rc, wanted $wantrc"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); return 1
    fi
    echo "ok   $label (exit $rc)"; return 0
  }
  _want() { # _want <label> <count> <pattern> [file]
    local label="$1" want="$2" pat="$3" src="${4:-}" got
    if [ -n "$src" ]; then got=$(grep -cE "$pat" "$src" | tr -d ' ')
    else got=$(printf '%s\n' "$out" | grep -cE "$pat" | tr -d ' '); fi
    if [ "$got" != "$want" ]; then
      echo "FAIL $label: $got line(s) matching /$pat/, wanted $want"
      { [ -n "$src" ] && cat "$src" || printf '%s\n' "$out"; } | _ind; fails=$((fails+1))
    else echo "ok   $label ($got matching /$pat/)"; fi
  }
  _min() { # _min <label> <at-least> <pattern> <file>
    local label="$1" want="$2" pat="$3" src="$4" got
    got=$(grep -cE "$pat" "$src" | tr -d ' ')
    if [ "$got" -lt "$want" ]; then
      echo "FAIL $label: $got line(s) matching /$pat/, wanted at least $want"; cat "$src" | _ind; fails=$((fails+1))
    else echo "ok   $label ($got matching /$pat/, wanted >= $want)"; fi
  }

  echo "== arm a: a CLOSED row is dropped, is NEVER a strike, and the live rows on the same list"
  echo "          are still pulsed in the SAME round (3 rounds -> exit 0, not 3)"
  printf '%s\n' closed-row live-a live-b > "$d/held"
  printf '%s\n' not_in_progress:done > "$d/reply/closed-row"
  printf '%s\n' ok > "$d/reply/live-a"; printf '%s\n' ok > "$d/reply/live-b"
  if _run "arm a runs" 0 3; then
    _want "arm a drops the closed row every round"        3 'DROPPED closed-row:.*not_in_progress'
    _want "arm a never calls the drop a strike"           0 'strike .*closed-row'
    _want "arm a still pulses live-a in every round"      3 'ok live-a' "$d/log"
    _want "arm a still pulses live-b in every round"      3 'ok live-b' "$d/log"
    _want "arm a refusal reached the LOG too"             3 'DROPPED closed-row' "$d/log"
    _want "arm a refusal reached STDERR too"              3 'DROPPED closed-row' "$d/err"
    _want "arm a never stops"                             0 'STOPPING'
  fi

  echo "== arm b: three consecutive not_holder rounds on ONE row exits 3 NAMING that row"
  printf '%s\n' doubt-row live-a > "$d/held"
  printf '%s\n' not_holder > "$d/reply/doubt-row"; printf '%s\n' ok > "$d/reply/live-a"
  if _run "arm b runs" 3 9; then
    _want "arm b names the row in the stop line"       1 'STOPPING: doubt-row .*3 consecutive'
    _want "arm b counted exactly three strikes"        3 'strike [123]/3 doubt-row'
    _want "arm b stopped on round 3, not later"        3 'REFUSED doubt-row'
    _want "arm b kept pulsing the healthy row until the stop" 2 'ok live-a' "$d/log"
  fi
  echo "== arm b2: a SUCCESSFUL pulse resets that row's counter (2 doubts, an ok, 2 doubts = no stop)"
  printf '%s\n' doubt-row > "$d/held"
  printf '%s\n' not_holder not_holder ok not_holder not_holder > "$d/reply/doubt-row"
  if _run "arm b2 runs" 0 5; then
    _want "arm b2 never stops" 0 'STOPPING'
    _want "arm b2 never reaches strike 3" 0 'strike 3/3'
  fi

  echo "== arm c: a 5xx round DROPS NOTHING and is ONE strike per row"
  printf '%s\n' row-1 row-2 > "$d/held"
  printf '%s\n' 5xx ok ok > "$d/reply/row-1"; printf '%s\n' 5xx ok ok > "$d/reply/row-2"
  if _run "arm c runs" 0 3; then
    _want "arm c strikes row-1 exactly once"   1 'strike 1/3 row-1'
    _want "arm c strikes row-2 exactly once"   1 'strike 1/3 row-2'
    _want "arm c drops nothing"                0 'DROPPED'
    _want "arm c keeps pulsing row-1 after"    2 'ok row-1' "$d/log"
    _want "arm c keeps pulsing row-2 after"    2 'ok row-2' "$d/log"
    _want "arm c 5xx classed as claim-in-doubt" 2 'REFUSED (row-1|row-2).*503'
  fi
  echo "== arm c2: a 5xx on EVERY round still stops at three, naming the row"
  printf '%s\n' row-1 > "$d/held"; printf '%s\n' 5xx > "$d/reply/row-1"
  if _run "arm c2 runs" 3 9; then _want "arm c2 names row-1" 1 'STOPPING: row-1'; fi

  echo "== arm d: the ledger call shape, with BARKPARK_TOKEN unset in the child"
  printf '%s\n' row-1 > "$d/held"; printf '%s\n' ok > "$d/reply/row-1"
  if _run "arm d runs" 0 1; then
    _want "arm d call shape" 1 '^task pulse row-1 lead-test --now .+ --yes -o json$' "$d/argv.log"
    _want "arm d unset the token" 1 '^TOKEN_UNSET$' "$d/argv.log"
    _want "arm d leaked no token" 0 '^TOKEN_PRESENT$' "$d/argv.log"
  fi

  echo "== arm e: the held file is re-read FRESH every round (a lead appends mid-run)"
  printf '%s\n' row-1 > "$d/held"
  printf '%s\n' append:late-row ok ok > "$d/reply/row-1"; printf '%s\n' ok > "$d/reply/late-row"
  if _run "arm e runs" 0 3; then
    # A loop that snapshotted the list at startup would pulse late-row ZERO times.
    _min  "arm e pulses the appended row"      2 'ok late-row' "$d/log"
    _want "arm e keeps pulsing the original"   3 'ok row-1' "$d/log"
  fi

  echo "== arm f: an unreadable held file is a LOUD exit 2, never a quiet 'nothing to pulse'"
  out=$(PATH="$d/bin:$PATH" STUB_DIR="$d" PULSE_LOOP_ALLOW_FAST=1 \
        bash "$SELF" --interval 0 --passes 1 lead-test "$d/nope.txt" "$d/log" 2>&1); rc=$?
  if [ "$rc" = 2 ]; then echo "ok   arm f (exit 2)"; else echo "FAIL arm f: exit $rc, wanted 2"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  _want "arm f says why" 1 'held file'

  rm -rf "$d"
  if [ "$fails" -gt 0 ]; then echo "pulse-loop.sh selftest: $fails FAILED"; return 1; fi
  echo "pulse-loop.sh selftest: all arms passed"; return 0
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ------------------------------------------------------------------ ARGUMENTS ----------------
INTERVAL=1080; PASSES=0; NOTE=""
ARGV=()
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="${2:-}"; shift 2;;
    --passes)   PASSES="${2:-}"; shift 2;;
    --once)     PASSES=1; shift;;
    --note)     NOTE="${2:-}"; shift 2;;
    -h|--help)  sed -n '2,45p' "$SELF"; exit 0;;
    --*)        echo "pulse-loop.sh: unknown flag '$1'" >&2; exit 2;;
    *)          ARGV+=("$1"); shift;;
  esac
done
if [ "${#ARGV[@]}" -ne 3 ]; then
  echo "pulse-loop.sh: usage: pulse-loop.sh <worker> <held-file> <log>" >&2; exit 2
fi
WORKER="${ARGV[0]}"; HELD="${ARGV[1]}"; LOG="${ARGV[2]}"
[ -n "$NOTE" ] || NOTE="$WORKER holding; PR/verification in flight"
case "$INTERVAL" in ''|*[!0-9]*) echo "pulse-loop.sh: --interval must be a whole number of seconds" >&2; exit 2;; esac
case "$PASSES"   in ''|*[!0-9]*) echo "pulse-loop.sh: --passes must be a whole number" >&2; exit 2;; esac
if [ "$INTERVAL" -lt 1080 ] && [ "${PULSE_LOOP_ALLOW_FAST:-}" != 1 ]; then
  echo "pulse-loop.sh: --interval $INTERVAL is below the 18-minute cadence; clamping to 1080 (a 40 s loop sent 39 pulses in ten minutes and was stopped)" >&2
  INTERVAL=1080
fi
if [ ! -r "$HELD" ]; then
  echo "pulse-loop.sh: held file '$HELD' is missing or unreadable — NOTHING was pulsed. This is NOT 'no rows held'." >&2
  [ -n "$LOG" ] && printf '%s pulse-loop: held file %s unreadable — nothing pulsed\n' "$(date -u +%H:%M:%SZ)" "$HELD" >> "$LOG" 2>/dev/null
  exit 2
fi

say()  { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; return 0; }
# A refusal is LOUD: stdout+log via say(), and stderr as well. A background loop whose only
# output is a log file is silent by construction.
loud() { say "$*"; printf '%s\n' "$*" >&2; return 0; }

# bash 3.2 has no associative arrays: the per-ROW consecutive claim-in-doubt counter lives here.
STATE=$(mktemp -d) || exit 2
trap 'rm -rf "$STATE"' EXIT
PASS=0

# classify <exit-code> <output> -> prints: ok | not_in_progress | doubt
# THE RULE THIS FILE EXISTS FOR: `not_in_progress:*` is the LIST going stale, not the claim going
# wrong — it is never a strike. Everything else that is not an outright success is claim-in-doubt
# (not_holder, stale_claim, 5xx, timeouts, and anything unrecognised: an unknown refusal about a
# claim is in doubt by default).
classify() {
  local rc="$1" out="$2"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"ok":true'; then echo ok; return; fi
  if printf '%s' "$out" | grep -q 'not_in_progress'; then echo not_in_progress; return; fi
  echo doubt
}

while :; do
  PASS=$((PASS+1))
  rm -f "$STATE/seen."*                       # de-dupe WITHIN a round; a lead may append twice
  ROWS=0
  # THE HELD FILE IS READ FRESH HERE, every round: leads append to it while this loop runs.
  while IFS= read -r line || [ -n "$line" ]; do
    id=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$id" in ''|'#'*) continue;; esac
    case "$id" in *[!A-Za-z0-9_.:-]*)
      loud "pulse-loop: SKIPPED unusable id '$id' from $HELD (not a bare doc id) — not a strike"; continue;; esac
    [ -f "$STATE/seen.$id" ] && continue
    : > "$STATE/seen.$id"
    ROWS=$((ROWS+1))

    out=$(env -u BARKPARK_TOKEN bp task pulse "$id" "$WORKER" --now "$NOTE" --yes -o json 2>&1); rc=$?
    verdict=$(classify "$rc" "$out")
    short=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-240)

    case "$verdict" in
      ok)
        rm -f "$STATE/strikes.$id"            # a successful pulse resets THAT row's counter
        say "ok $id epoch=$(printf '%s' "$out" | grep -o '"epoch":[0-9]*' | head -1 | cut -d: -f2)"
        ;;
      not_in_progress)
        # The row left the pool. Drop it from THIS round, say so, and DO NOT touch its strike
        # counter. Non-sticky on purpose: the held file is the input, so a row that reopens
        # starts being pulsed again next round without anyone editing anything.
        loud "DROPPED $id: left the pool ($short) — dropped from this round, NOT a strike"
        ;;
      doubt)
        n=1; [ -f "$STATE/strikes.$id" ] && n=$(( $(cat "$STATE/strikes.$id") + 1 ))
        echo "$n" > "$STATE/strikes.$id"
        loud "REFUSED $id: claim in doubt ($short) — strike $n/3 $id"
        if [ "$n" -ge 3 ]; then
          loud "STOPPING: $id refused with the claim in doubt on 3 consecutive rounds — its lease is unsafe. Re-claim it (bp task claim $id $WORKER --yes) and restart this loop."
          exit 3
        fi
        ;;
    esac
  done < "$HELD"

  [ "$ROWS" -eq 0 ] && say "pulse-loop: held list $HELD is empty this round — nothing pulsed (still watching)"
  if [ "$PASSES" -gt 0 ] && [ "$PASS" -ge "$PASSES" ]; then exit 0; fi
  [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done
