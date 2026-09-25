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
#     others. THREE CONSECUTIVE claim-in-doubt rounds on ONE row DROP THAT ROW from this loop
#     (a loud `DROPPED-IN-DOUBT <id>` line, then one `SKIPPED <id>` line per round so the log
#     never goes quiet about it) and the loop KEEPS PULSING every other row. Measured
#     2026-09-25 (task-39a82efdf516a26b): the old rule — exit 3 on ONE row's third strike —
#     stopped pulses for the whole list, and three held rows on it lapsed to open/unclaimed.
#     The drop is sticky for this process: re-claim the row and restart the loop to pulse it.
#     The loop still exits 3 (STOPPING) when NO row is left to pulse — every row on the list is
#     dropped in doubt or out of the pool — which is the dead-server / every-claim-gone case.
#     A successful pulse resets that row's counter; a `not_in_progress` drop leaves it untouched
#     (a row that left the pool is not evidence about the claim either way).
#   * A DRAFT-ONLY row (doc_id `drafts.*`, never published) is pulsed like any other, and bp
#     answers a landed pulse on it with exit 6 plus the receipt
#       `bp: pulse_receipt confirmed=false reason=draft_row exit=6`
#     because no BOARD will show the now-line — not because the claim is in doubt: the same
#     reply carries `"ok":true`, the advanced epoch, and the read-back line
#       `the draft holds: now-line "..."  claim <worker> epoch=<n>`.
#     classify() keys on those POSITIVE receipts (reason=draft_row AND "ok":true AND the
#     read-back naming THIS worker's claim) and calls it ok. Measured 2026-09-25: without this,
#     a live, correctly claimed draft row took three "claim in doubt" strikes in a row.
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
#   pulse-loop.sh lead-cli "$ORCH/lead-cli/held.s2.txt" "$ORCH/lead-cli/pulse.s2.log"  # forever
#   pulse-loop.sh --once lead-cli held.s2.txt pulse.s2.log  # one round, then exit (foreground check)
#
# THE HELD FILE IS PER SESSION, NOT PER LANE (task-50d7d1a599dd14dd). `held.txt`
# is the legacy lane-wide name and two concurrent sessions of one lane sharing
# it dropped a live row at 00:35:35Z on 2026-09-07 — a removal errors nowhere
# and the claim lapses ~40 min later. Take the path from
# `helpers/session-files.sh open <lane-dir> <session>` (HELD= / PULSE_LOG=) and
# pass it here; this script reads exactly the file it is given and no other.
#   pulse-loop.sh --selftest                             # hermetic, no network, stub bp on PATH
#
# FLAGS
#   --once / --passes N   stop after N rounds (default: forever).
#   --interval N          seconds between rounds (default 1080, floor 1080).
#   --note TEXT           the --now text (default "<worker> holding; PR/verification in flight").
#
# EXIT: 0 = rounds exhausted. 2 = bad arguments / unreadable held file. 3 = NO row is left to
#       pulse: every row on the list was dropped after three consecutive claim-in-doubt rounds or
#       left the pool (the STOPPING line names the dropped rows). ONE row's third strike never
#       exits — it drops that row and the loop goes on.
set -u
SELF="${BASH_SOURCE[0]}"

# ------------------------------------------------------------------ SELFTEST (no network) ----
# Drives the helper against a stub `bp` on PATH. Arms:
#   a) a CLOSED row is dropped (logged, not a strike) and the OTHER rows on the list are still
#      pulsed IN THE SAME ROUND — over three rounds, so the run must still exit 0.
#   b) three consecutive not_holder rounds on ONE row DROP that row (loud, named) and the healthy
#      row on the same list is STILL PULSED in every round AFTER the drop; the run exits 0.
#   c) a 5xx round drops nothing (both rows pulsed again next round) and is ONE strike per row.
#   d) the ledger call shape: `task pulse <id> <worker> --now <text> --yes -o json`, with
#      BARKPARK_TOKEN UNSET in the child even though the caller exported one.
#   e) the held file is re-read FRESH every round: a row appended mid-run gets pulsed.
#   g) the REAL draft-only pulse reply (captured from bp 2026-09-25, a throwaway draft row,
#      stdout+stderr+exit verbatim) classifies ok over three rounds: no strike, no drop.
#      g2 is its control — the same reply under a DIFFERENT worker is claim-in-doubt, so the
#      read-back's worker is actually read and the arm cannot pass vacuously.
# MUTATION that must red arm (a): count `not_in_progress` as a claim-in-doubt strike (i.e. delete
# the `not_in_progress` branch of classify()). Arm (a) then strikes the closed row 1..3 and drops
# it IN DOUBT instead of dropping it as out-of-pool (four assertions red) — before 2026-09-25 this
# mutation exited 3 and stopped the whole list, the 2026-09-10 production incident.
# MUTATION that must red arm (b): put back `exit 3` on a single row's third strike. Arm (b) then
# exits 3 with the healthy row unpulsed after the drop — the 2026-09-25 incident, reproduced.
# MUTATION that must red arm (g): delete the draft_row branch of classify(). Arm (g) then takes
# strikes 1..3 on a live draft row — the 2026-09-25 incident, reproduced.
selftest() {
  local d rc out fails=0
  _ind() { while IFS= read -r _l; do printf '      | %s\n' "$_l"; done; }
  d=$(mktemp -d) || return 1
  mkdir -p "$d/bin" "$d/reply" "$d/count"

  # Stub bp: line N of reply/<id> on round N (last line repeats). Tokens:
  #   ok | not_in_progress:done | not_holder | stale_claim | 5xx | draft | append:<id>
  # `draft` replays the REAL reply bp gave a pulse on a draft-only row. Captured 2026-09-25 with
  # `env -u BARKPARK_TOKEN bp task pulse drafts.task-fb4089f70da2a43d infra-w11-scratch --now
  # capture --yes -o json` (the loop's exact call shape) on a throwaway draft task created,
  # claimed, pulsed once and closed cancelled for this purpose: exit 6, stdout and stderr
  # below byte-for-byte. Do not hand-edit them — recapture instead.
  cat > "$d/draft.stdout" <<'CAPTURED_STDOUT'
{"doc":{"assignee":"infra-w11-scratch","claim":{"epoch":2,"lease_expires_at":"2026-09-25T13:57:39.666915Z","lease_seconds":2700,"now":{"text":"capture","ts":"2026-09-25T13:12:39.666915Z"},"session":"s_a27da76950c664eb","session_origin":"s_a27da76950c664eb","ts_iso":"2026-09-25T13:12:39.666915Z","work_digest":"6dc3c925e8a118f9","work_field_digests":{"acceptance_criteria":"7f3c8eae70f023de","brief":"500e4b8822925808","description":"0bc7fdabbdae206a","title":"377398c879fc9025"},"worker":"infra-w11-scratch"},"content":{"acceptance_criteria":[{"criterion":"scratch","evidence":"","met":false}],"assignee":"infra-w11-scratch","brief":{"blocks":[{"id":"criteria","level":2,"text":"Criteria","type":"heading"},{"id":"criteria-list","items":["scratch"],"ordered":false,"type":"list"},{"id":"purpose","level":2,"text":"Purpose","type":"heading"},{"content":[{"type":"text","value":"Scratch row for task-39a82efdf516a26b; captures the draft-only pulse reply shape. Cancel on sight."}],"id":"purpose-copy","type":"paragraph"}],"version":1},"created_by":{"at":"2026-09-25T13:12:26Z","id":"e5ce2b91-e38d-426e-ae68-5006dc414b97","kind":"api_token"},"description":"Scratch row for task-39a82efdf516a26b; captures the draft-only pulse reply shape. Cancel on sight.","kind":"task","lifecycle_status":"in_progress"},"criteria_progress":{"met":0,"total":1},"dataset":"production","doc_id":"drafts.task-fb4089f70da2a43d","execution_class":"foreign_claimed","execution_policy":null,"id":"40346679-7173-4a18-8c01-2c74444076e0","inserted_at":"2026-09-25T13:12:26.649191Z","kind":"task","labels":[],"lifecycle_status":"in_progress","papers":[],"parent_id":null,"priority":null,"queue_gate":null,"rev":"e81be23ac70d87251ad5b8275bdf9941","sessions":[],"status":"draft","title":"scratch: pulse-loop draft reply capture (delete me)","type":"task","updated_at":"2026-09-25T13:12:39.666928Z"},"help":["bp task stamp task-fb4089f70da2a43d infra-w11-scratch 2 --criterion <N> --met --evidence \"...\" --criterion-text-file <file holding acceptance_criteria[<N>].criterion, verbatim>","bp task close task-fb4089f70da2a43d infra-w11-scratch 2 done \"<summary of what shipped>\""],"lease":{"expires_at":"2026-09-25T13:57:39.666915Z","granted_at":"2026-09-25T13:12:39.666915Z","minutes":45,"seconds":2700},"ok":true}
CAPTURED_STDOUT
  cat > "$d/draft.stderr" <<'CAPTURED_STDERR'
help: bp task stamp task-fb4089f70da2a43d infra-w11-scratch 2 --criterion <N> --met --evidence "..." --criterion-text-file <file holding acceptance_criteria[<N>].criterion, verbatim>
help: bp task close task-fb4089f70da2a43d infra-w11-scratch 2 done "<summary of what shipped>"
lease: epoch=2 expires_at=2026-09-25T13:57:39.666915Z lease=45min — `bp task pulse` renews the lease AND advances the epoch, so re-read the epoch after every pulse
bp: pulse landed on a DRAFT, not the board — drafts.task-fb4089f70da2a43d (status "draft") answered this read-back
  `drafts.task-fb4089f70da2a43d` has no published row, so no board will ever show this now-line
  the draft holds: now-line "capture"  claim infra-w11-scratch epoch=2
bp: pulse_receipt confirmed=false reason=draft_row exit=6
CAPTURED_STDERR
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
  draft) cat "$STUB_DIR/draft.stdout"; cat "$STUB_DIR/draft.stderr" >&2; exit 6;;
  *)    echo '{"ok":false,"error":"'"$line"'"}' >&2; exit 1;;
esac
STUB
  chmod +x "$d/bin/bp"

  _run() { # _run <label> <expected-exit> <passes> [worker] ; stdout+stderr in $out, rc in $rc
    local label="$1" wantrc="$2" passes="$3" worker="${4:-lead-test}"
    : > "$d/log"; : > "$d/argv.log"; : > "$d/err"; rm -f "$d/count/"*
    # stdout and stderr are captured SEPARATELY: loud() writes a refusal to both, so a combined
    # capture would count every refusal twice and no assertion here would mean what it says.
    out=$(PATH="$d/bin:$PATH" STUB_DIR="$d" BARKPARK_TOKEN=would-be-wrong PULSE_LOOP_ALLOW_FAST=1 \
          bash "$SELF" --interval 0 --passes "$passes" "$worker" "$d/held" "$d/log" 2>"$d/err"); rc=$?
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

  echo "== arm b: three consecutive not_holder rounds on ONE row DROP that row, and the loop keeps"
  echo "          pulsing the other row in every round AFTER the drop (6 rounds -> exit 0, not 3)"
  printf '%s\n' doubt-row live-a > "$d/held"
  printf '%s\n' not_holder > "$d/reply/doubt-row"; printf '%s\n' ok > "$d/reply/live-a"
  if _run "arm b runs" 0 6; then
    _want "arm b counted exactly three strikes"        3 'strike [123]/3 doubt-row'
    _want "arm b stopped PULSING doubt-row at round 3" 3 'REFUSED doubt-row'
    _want "arm b drops doubt-row loudly, once"         1 'DROPPED-IN-DOUBT doubt-row .*3 consecutive'
    _want "arm b drop reached STDERR too"              1 'DROPPED-IN-DOUBT doubt-row' "$d/err"
    _want "arm b says so every later round"            3 'SKIPPED doubt-row' "$d/log"
    _want "arm b never stops"                          0 'STOPPING'
    _want "arm b pulsed live-a in all six rounds"      6 'ok live-a' "$d/log"
    # THE CLAIM: live-a is pulsed AFTER the drop. Count its ok lines that follow the drop line:
    # the drop lands mid-round 3 (doubt-row is listed first), so live-a's round-3 pulse follows
    # it too — rounds 3,4,5,6 = 4. The old exit-3 rule leaves ZERO after the stop line.
    got=$(awk '/DROPPED-IN-DOUBT doubt-row/{f=1;next} f&&/ ok live-a/{n++} END{print n+0}' "$d/log")
    if [ "$got" = 4 ]; then echo "ok   arm b pulsed live-a in every round after the drop (4)"
    else echo "FAIL arm b: live-a pulsed $got time(s) after the drop, wanted 4"; _ind < "$d/log"; fails=$((fails+1)); fi
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
  echo "== arm c2: a 5xx on EVERY round on EVERY row still stops at three, naming the row"
  echo "           (nothing left to pulse is the dead-server case, not one row's doubt)"
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

  echo "== arm g: the REAL draft-only pulse reply (exit 6, reason=draft_row) is ok, never a strike"
  printf '%s\n' drafts.task-fb4089f70da2a43d > "$d/held"
  printf '%s\n' draft > "$d/reply/drafts.task-fb4089f70da2a43d"
  if _run "arm g runs" 0 3 infra-w11-scratch; then
    _want "arm g pulse is ok every round"    3 'ok drafts\.task-fb4089f70da2a43d epoch=2 .*draft' "$d/log"
    _want "arm g never a strike"             0 'strike [0-9]/3'
    _want "arm g never REFUSED"              0 'REFUSED'
    _want "arm g never dropped"              0 'DROPPED'
  fi
  echo "== arm g2: CONTROL — the same reply naming ANOTHER worker's claim is in doubt, not ok"
  if _run "arm g2 runs" 0 1 lead-test; then
    _want "arm g2 is a strike"               1 'REFUSED drafts\.task-fb4089f70da2a43d: claim in doubt'
    _want "arm g2 is not ok"                 0 'ok drafts\.task-fb4089f70da2a43d' "$d/log"
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
  [ -n "$LOG" ] && printf '%s pulse-loop: held file %s unreadable — nothing pulsed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HELD" >> "$LOG" 2>/dev/null
  exit 2
fi

say()  { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; return 0; }
# A refusal is LOUD: stdout+log via say(), and stderr as well. A background loop whose only
# output is a log file is silent by construction.
loud() { say "$*"; printf '%s\n' "$*" >&2; return 0; }

# bash 3.2 has no associative arrays: the per-ROW consecutive claim-in-doubt counter lives here.
STATE=$(mktemp -d) || exit 2
trap 'rm -rf "$STATE"' EXIT
PASS=0

# classify <exit-code> <output> <worker> -> prints: ok | ok_draft | not_in_progress | doubt
# THE RULE THIS FILE EXISTS FOR: `not_in_progress:*` is the LIST going stale, not the claim going
# wrong — it is never a strike. Everything else that is not an outright success is claim-in-doubt
# (not_holder, stale_claim, 5xx, timeouts, and anything unrecognised: an unknown refusal about a
# claim is in doubt by default).
# ok_draft is a success keyed on POSITIVE receipts, never on the absence of an error: bp's own
# receipt `reason=draft_row`, the POST's `"ok":true`, AND the read-back line naming THIS worker's
# claim (`claim <worker> epoch=<n>`). All three, or it is not ok. Matched with bash `case`, not a
# pipe, so no SIGPIPE can turn a success into a miss.
classify() {
  local rc="$1" out="$2" worker="${3:-}"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"ok":true'; then echo ok; return; fi
  case "$out" in *'pulse_receipt confirmed=false reason=draft_row'*)
    case "$out" in *'"ok":true'*)
      case "$out" in *"the draft holds: "*"  claim $worker epoch="[0-9]*) echo ok_draft; return;; esac;;
    esac;;
  esac
  if printf '%s' "$out" | grep -q 'not_in_progress'; then echo not_in_progress; return; fi
  echo doubt
}

while :; do
  PASS=$((PASS+1))
  rm -f "$STATE/seen."*                       # de-dupe WITHIN a round; a lead may append twice
  ROWS=0; LIVE=0
  # THE HELD FILE IS READ FRESH HERE, every round: leads append to it while this loop runs.
  while IFS= read -r line || [ -n "$line" ]; do
    id=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$id" in ''|'#'*) continue;; esac
    case "$id" in *[!A-Za-z0-9_.:-]*)
      loud "pulse-loop: SKIPPED unusable id '$id' from $HELD (not a bare doc id) — not a strike"; continue;; esac
    [ -f "$STATE/seen.$id" ] && continue
    : > "$STATE/seen.$id"
    ROWS=$((ROWS+1))
    if [ -f "$STATE/dropped.$id" ]; then
      # Sticky for this process: its lease is unsafe and pulsing it again proves nothing. Said
      # every round so the log never goes quiet about a row the lead still lists.
      say "SKIPPED $id: dropped after 3 consecutive claim-in-doubt rounds — not pulsed (re-claim it and restart this loop)"
      continue
    fi

    out=$(env -u BARKPARK_TOKEN bp task pulse "$id" "$WORKER" --now "$NOTE" --yes -o json 2>&1); rc=$?
    verdict=$(classify "$rc" "$out" "$WORKER")
    short=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-240)

    case "$verdict" in
      ok)
        rm -f "$STATE/strikes.$id"            # a successful pulse resets THAT row's counter
        say "ok $id epoch=$(printf '%s' "$out" | grep -o '"epoch":[0-9]*' | head -1 | cut -d: -f2)"
        LIVE=$((LIVE+1))
        ;;
      ok_draft)
        rm -f "$STATE/strikes.$id"
        say "ok $id epoch=$(printf '%s' "$out" | grep -o '"epoch":[0-9]*' | head -1 | cut -d: -f2) (draft-only row: bp exit $rc reason=draft_row — the lease renewed on the draft; no board shows it; NOT a strike)"
        LIVE=$((LIVE+1))
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
          # ONE row's doubt never stops the loop: drop that row, keep pulsing the rest.
          : > "$STATE/dropped.$id"
          loud "DROPPED-IN-DOUBT $id refused with the claim in doubt on 3 consecutive rounds — its lease is unsafe, so this loop STOPS PULSING IT and keeps pulsing every other row. Re-claim it (bp task claim $id $WORKER --yes) and restart this loop."
        else
          LIVE=$((LIVE+1))                    # still on the list: strikes 1-2 keep it live
        fi
        ;;
    esac
  done < "$HELD"

  [ "$ROWS" -eq 0 ] && say "pulse-loop: held list $HELD is empty this round — nothing pulsed (still watching)"
  # Nothing left to pulse: every listed row is dropped in doubt or out of the pool. That is the
  # dead-server / every-claim-gone case, and the only doubt that stops the loop.
  if [ "$ROWS" -gt 0 ] && [ "$LIVE" -eq 0 ] && ls "$STATE"/dropped.* >/dev/null 2>&1; then
    dropped=$(cd "$STATE" && for f in dropped.*; do printf '%s ' "${f#dropped.}"; done)
    loud "STOPPING: ${dropped% } — no row left to pulse: every row on $HELD is dropped after 3 consecutive claim-in-doubt rounds or has left the pool. Check the server, re-claim (bp task claim <id> $WORKER --yes) and restart this loop."
    exit 3
  fi
  if [ "$PASSES" -gt 0 ] && [ "$PASS" -ge "$PASSES" ]; then exit 0; fi
  [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done
