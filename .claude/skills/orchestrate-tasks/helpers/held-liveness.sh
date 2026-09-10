#!/usr/bin/env bash
# held-liveness.sh <lane-dir> — THE keep-alive check. Every lead runs this at the top of every
# loop, and after any peer stand-down, instead of tailing its own pulse log and calling it held.
#
# SIBLING: pr-watch.sh (in this directory) answers "are my PRs moving"; THIS answers "are my
# claims still mine". Both are one bash helper every lead calls instead of an ad-hoc loop.
#
# WHY THIS FILE EXISTS. A pulse loop that STOPS RUNNING is silent by construction. Measured
# 2026-09-10T00:58Z (lead-security): the lane's nohup loop died between 00:03Z and 00:58Z with
# NO line anywhere — no refusal, no exit line, nothing in events.log. The process exit prints
# nothing; the log simply stops growing; and every reader of that log reads "the last line was
# ok" as "held". Four rows — one claimed at 00:09Z on a 45-minute lease — were 4 minutes from
# lapsing back to ready, where another lane would have claimed them out from under three open
# PRs. Nothing in the campaign tooling compared the log's AGE to the LEASE, and nothing read the
# LEDGER's own claim state for the rows a lane believed it held.
#
# LEAD-BRIEF.md already carries the two earlier shapes of this ("A running pulse loop is not
# evidence that claims are held"; "A pulse failure is the only warning you get"). A written
# finding does not fire by itself — so the check lives HERE, as a command with an exit code.
#
# WHAT IT ANSWERS, per row in the lane's OWN held.txt (LEAD-BRIEF: "a pulse loop reads a file
# only your lane writes"):
#   a) who the LEDGER says holds it            (.doc.claim.worker)
#   b) when the lease expires                  (.doc.claim.lease_extension.until when an open PR
#      extends it; otherwise .doc.claim.ts_iso + the 45-minute lease — "A claim is a **45 min**
#      lease (`:task_lease_ttl_seconds`, 2700 s)", docs/setup/TASK-SYSTEM.md line 92)
#   c) how stale the lane's own pulse log is   (newest line of --log vs --pulse-interval)
#   d) whether the loop's pid is still alive   (--pid-file)
# Lease-until always comes from the LEDGER, never from local state: local state is exactly what
# a dead loop keeps telling you.
#
# RULES it implements:
#   * READS ONLY. `bp task get <id> -o json` with BARKPARK_TOKEN unset, one call per row. No
#     ledger writes, ever — this helper is safe to run from any lane at any cadence.
#   * READS ONLY <lane-dir>/held.txt. It never widens to "all rows claimed by W": the four
#     questions of a keep-alive are separate, and this one is "is the list I pulse still mine".
#   * Every violation is a NAMED line carrying the row id, and makes the exit non-zero.
#   * A failed ledger read prints a distinct `CANNOT READ` line and exits 3 — never a green,
#     never "lapsed". The CANNOT-READ output deliberately contains no reassuring verdict.
#   * An EMPTY held.txt is exit 2, not exit 0. An empty list is not "all rows are fine"; it is
#     the shape a trimmed-out-from-under-you list has (LEAD-BRIEF: "Hardening the alarm does
#     nothing when the input list is what goes empty").
#   * A done/cancelled row is NOT a violation — it is printed CLOSED with a TRIM advisory, so
#     the lead trims the list. A closed row left in the list is how a lead pulses ghosts.
#   * Second channel: with --tee FILE every line is appended there too, so a scripted run's
#     verdict is readable by another lane.
#
# USAGE
#   held-liveness.sh "$ORCH/lead-security" --expect-worker lead-security \
#       --pid-file "$ORCH/lead-security/pulse.pid" --log "$ORCH/lead-security/pulse.log"
#   held-liveness.sh --selftest            # hermetic, no network, stub bp on PATH
#
# FLAGS
#   --expect-worker W  the worker id the ledger must show for every row (default: none — then
#                      any non-null worker passes, which is a WEAKER check; pass it.)
#   --pid-file F       file holding the pulse loop's pid; a dead pid is a named violation.
#   --log F            the lane's pulse log; its NEWEST line must be younger than the interval.
#   --warn-minutes N   a lease with N or fewer minutes left is a violation (default 15).
#   --pulse-interval-minutes N  expected pulse cadence (default 18, LEAD-BRIEF's `sleep 1080`).
#                      The log is stale when its newest line is older than N + a 3-min grace.
#   --lease-minutes N  lease length when the row carries no lease_extension (default 45).
#   --bp CMD           the ledger reader (default `bp`, always run under `env -u BARKPARK_TOKEN`).
#   --tee FILE         append every printed line here as well.
#
# EXIT: 0 = every row held by the expected worker with room to spare, log fresh, pid alive.
#       1 = at least one NAMED violation.  2 = bad arguments / missing or EMPTY held.txt.
#       3 = at least one ledger read REFUSED (CANNOT READ). 3 beats 1: an unread row is unknown.
set -u
SELF="${BASH_SOURCE[0]}"

TEE=""
say() {
  printf '%s\n' "$*"
  [ -n "$TEE" ] && printf '%s %s\n' "$(date -u +%H:%MZ)" "$*" >> "$TEE" 2>/dev/null
  return 0
}

# ISO-8601 -> epoch seconds. GNU date first, then BSD/macOS. Fractional seconds and the Z are
# stripped; a value this cannot parse returns non-zero and is reported, never treated as 0.
iso_epoch() {
  local t="${1:-}" e; [ -n "$t" ] || return 1
  t="${t%Z}"; t="${t%%.*}"; t="${t%%+*}"; t="${t%% *}"
  e=$(date -u -d "${t}Z" +%s 2>/dev/null) && [ -n "$e" ] && { printf '%s' "$e"; return 0; }
  e=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$t" +%s 2>/dev/null) && [ -n "$e" ] && { printf '%s' "$e"; return 0; }
  return 1
}

# ------------------------------------------------------------------ SELFTEST (no network) ----
# Drives the helper against a stub `bp` on PATH, from a NON-REPO cwd, with real clock arithmetic
# (every fixture timestamp is computed from `date` at run time, so no arm can pass by matching a
# frozen string). Seven arms:
#   1 all-held green                     2 a row whose ledger worker DIFFERS  -> named, exit 1
#   3 a lease inside the warning window  4 a pulse log older than the interval -> named, exit 1
#   5 a dead pid                         6 an unreadable ledger -> CANNOT READ, exit 3, and the
#                                          output contains no "held"/"OK" reassurance
#   7 an EMPTY held.txt -> exit 2 with its own line (an empty list is not "all held")
# Each arm asserts the LAST line, the exit code, and that the failing ROW is NAMED.
# MUTATION that must red it: in the per-row loop, replace the ledger read's worker with the
# expected worker (`w="$EXPECT"`), i.e. trust the local list instead of the ledger. Arm 2 goes
# red and no other arm does — which is precisely the defect this helper exists to catch.
selftest() {
  local d rc out fails=0
  _ind() { while IFS= read -r _l; do printf '      | %s\n' "$_l"; done; }
  d=$(mktemp -d) || return 1
  mkdir -p "$d/bin" "$d/rows" "$d/lane"

  cat > "$d/bin/bp" <<'STUB'
#!/usr/bin/env bash
# stub bp: answers ONLY `task get <id> -o json`, from $STUB_DIR/rows/<id>.json.
[ "$1" = task ] && [ "$2" = get ] || { echo "stub bp: unexpected '$*'" >&2; exit 9; }
id="$3"
[ "${BP_STUB_BREAK:-}" = "$id" ] && { echo "stub bp: read refused" >&2; exit 4; }
f="$STUB_DIR/rows/$id.json"
[ -f "$f" ] || { echo "stub bp: no such row $id" >&2; exit 4; }
cat "$f"
STUB
  chmod +x "$d/bin/bp"

  _row() { # _row <id> <worker|null> <ts_iso> <lifecycle> [lease_until]
    local id="$1" w="$2" ts="$3" ls="$4" until="${5:-}" wj="null" uj="null"
    [ "$w" = null ] || wj="\"$w\""
    [ -z "$until" ] || uj="{\"until\":\"$until\"}"
    cat > "$d/rows/$id.json" <<EOF
{"doc":{"claim":{"worker":$wj,"epoch":1,"ts_iso":"$ts","lease_extension":$uj},
        "content":{"lifecycle_status":"$ls"}}}
EOF
  }
  _ago() { date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
  _in()  { date -u -v+"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes"      +%Y-%m-%dT%H:%M:%SZ; }

  _run() { # _run <label> <expected-exit> -- <args...>  ; stdout in $out, rc in $rc
    local label="$1" wantrc="$2"; shift 3
    # cwd is deliberately NOT the repo: the helper must not depend on where it is called from.
    out=$(cd "$d" && PATH="$d/bin:$PATH" STUB_DIR="$d" bash "$SELF" "$@" 2>&1); rc=$?
    if [ "$rc" != "$wantrc" ]; then
      echo "FAIL $label: exit $rc, wanted $wantrc"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); return 1
    fi
    echo "ok   $label (exit $rc)"; return 0
  }
  _last() { # _last <label> <extended-regex the LAST line must match>
    local label="$1" pat="$2" line; line=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
    if printf '%s' "$line" | grep -qE "$pat"; then echo "ok   $label (last line)"
    else echo "FAIL $label: last line was: $line"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  }
  _want() { # _want <label> <count> <pattern>
    local label="$1" want="$2" pat="$3" got
    got=$(printf '%s\n' "$out" | grep -cE "$pat" | tr -d ' ')
    if [ "$got" = "$want" ]; then echo "ok   $label ($got matching /$pat/)"
    else echo "FAIL $label: $got line(s) matching /$pat/, wanted $want"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  }

  local ALIVE DEAD
  ALIVE=$$
  # A pid that is certainly NOT alive: spawn, reap, reuse its number.
  bash -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null

  printf '%s\n' task-aaa task-bbb > "$d/lane/held.txt"
  echo "$ALIVE" > "$d/lane/pulse.pid"

  echo "== arm 1: every row held by the expected worker, log fresh, pid alive -> exit 0"
  _row task-aaa lead-x "$(_ago 5)"  in_progress
  _row task-bbb lead-x "$(_ago 2)"  in_progress
  printf '%s ok task-aaa\n%s ok task-bbb\n' "$(_ago 4)" "$(_ago 4)" > "$d/lane/pulse.log"
  if _run "arm1 runs" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm1 verdict is OK" 'liveness: OK'
    _want "arm1 names both rows" 2 '^(task-aaa|task-bbb) '
    _want "arm1 flags nothing"   0 'FOREIGN|LAPSING|UNCLAIMED|STALE LOG|DEAD PID|CANNOT READ'
  fi

  echo "== arm 2: a row the LEDGER says another worker holds -> NAMED, exit 1"
  _row task-bbb lead-other "$(_ago 2)" in_progress
  if _run "arm2 runs" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm2 verdict is a problem count" 'liveness: [0-9]+ PROBLEM'
    _want "arm2 NAMES the foreign row"      1 '^task-bbb .*FOREIGN'
    _want "arm2 does not flag the good row" 0 '^task-aaa .*(FOREIGN|LAPSING)'
  fi
  _row task-bbb lead-x "$(_ago 2)" in_progress

  echo "== arm 3: a lease inside the warning window -> NAMED, exit 1"
  # claimed 38 min ago on a 45-min lease => 7 min left, inside a 15-min warning window.
  _row task-aaa lead-x "$(_ago 38)" in_progress
  if _run "arm3 runs" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
    _last "arm3 verdict is a problem count" 'liveness: [0-9]+ PROBLEM'
    _want "arm3 NAMES the lapsing row"      1 '^task-aaa .*LAPSING'
    _want "arm3 prints its minutes-left"    1 '^task-aaa .*minutes-left=[0-9]+ '
  fi
  echo "== arm 3b: the SAME row with an open-PR lease_extension is NOT lapsing (ledger, not local)"
  _row task-aaa lead-x "$(_ago 38)" in_progress "$(_in 90)"
  if _run "arm3b runs" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
    _last "arm3b verdict is OK" 'liveness: OK'
    _want "arm3b uses the extension" 1 '^task-aaa .*lease-source=extension'
  fi
  _row task-aaa lead-x "$(_ago 5)" in_progress

  echo "== arm 4: a pulse log older than the interval -> NAMED, exit 1 (the dead-loop shape)"
  printf '%s ok task-aaa\n' "$(_ago 55)" > "$d/lane/pulse.log"
  if _run "arm4 runs" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
    _last "arm4 verdict is a problem count" 'liveness: [0-9]+ PROBLEM'
    _want "arm4 names the stale log"        1 'STALE LOG'
    _want "arm4 prints the log age"         1 'STALE LOG.*55 min'
  fi
  printf '%s ok task-aaa\n' "$(_ago 4)" > "$d/lane/pulse.log"

  echo "== arm 5: the pulse loop's pid is not alive -> NAMED, exit 1"
  echo "$DEAD" > "$d/lane/pulse.pid"
  if _run "arm5 runs" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm5 verdict is a problem count" 'liveness: [0-9]+ PROBLEM'
    _want "arm5 names the dead pid"         1 "DEAD PID.*$DEAD"
  fi
  echo "$ALIVE" > "$d/lane/pulse.pid"

  echo "== arm 6: an unreadable ledger -> CANNOT READ, exit 3, and NO reassuring verdict"
  out=$(cd "$d" && PATH="$d/bin:$PATH" STUB_DIR="$d" BP_STUB_BREAK=task-bbb \
        bash "$SELF" "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" 2>&1); rc=$?
  if [ "$rc" = 3 ]; then echo "ok   arm6 runs (exit 3)"
  else echo "FAIL arm6: exit $rc, wanted 3"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  _last "arm6 verdict is CANNOT READ"  'liveness: CANNOT READ'
  _want "arm6 NAMES the unread row"    1 '^CANNOT READ task-bbb'
  # The whole point: a refusal must not be readable as a green. No "held", no "OK", anywhere.
  _want "arm6 says nothing about being held" 0 '[Hh]eld'
  _want "arm6 never says OK"                 0 '\bOK\b'

  echo "== arm 7: an EMPTY held.txt is exit 2 with its own line — an empty list is not 'all held'"
  : > "$d/lane/held.txt"
  if _run "arm7 runs" 2 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm7 verdict names the empty list" 'liveness: EMPTY LIST'
    _want "arm7 refuses to call it fine"      0 'liveness: OK'
  fi
  printf '%s\n' task-aaa task-bbb > "$d/lane/held.txt"

  echo "== arm 8: a done row is CLOSED + a TRIM advisory, not a violation (exit stays 0)"
  _row task-bbb lead-x "$(_ago 200)" "done"
  if _run "arm8 runs" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm8 verdict is OK"      'liveness: OK'
    _want "arm8 names the closed row" 1 '^task-bbb .*CLOSED'
    _want "arm8 asks for a trim on the row"  1 '^task-bbb .*TRIM it'
    _want "arm8 carries a summary TRIM line"  1 '^TRIM: 1 closed row'
    _want "arm8 does not call it lapsing" 0 '^task-bbb .*LAPSING'
  fi

  rm -rf "$d"
  if [ "$fails" -gt 0 ]; then echo "held-liveness.sh selftest: $fails FAILED"; return 1; fi
  echo "held-liveness.sh selftest: all arms passed"; return 0
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ------------------------------------------------------------------ ARGUMENTS ----------------
EXPECT=""; PIDFILE=""; PULSELOG=""; WARN=15; INTERVAL=18; LEASE=45; BP="bp"; GRACE=3
LANE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-worker)  EXPECT="${2:-}"; shift 2;;
    --pid-file)       PIDFILE="${2:-}"; shift 2;;
    --log)            PULSELOG="${2:-}"; shift 2;;
    --warn-minutes)   WARN="${2:-}"; shift 2;;
    --pulse-interval-minutes) INTERVAL="${2:-}"; shift 2;;
    --lease-minutes)  LEASE="${2:-}"; shift 2;;
    --bp)             BP="${2:-}"; shift 2;;
    --tee)            TEE="${2:-}"; shift 2;;
    -h|--help)        sed -n '2,60p' "$SELF"; exit 0;;
    --*)              echo "held-liveness.sh: unknown flag '$1'" >&2; exit 2;;
    *)                if [ -n "$LANE" ]; then echo "held-liveness.sh: one lane dir, got '$LANE' and '$1'" >&2; exit 2; fi
                      LANE="$1"; shift;;
  esac
done
for _n in "$WARN" "$INTERVAL" "$LEASE"; do
  case "$_n" in ''|*[!0-9]*) echo "held-liveness.sh: --warn-minutes/--pulse-interval-minutes/--lease-minutes must be whole numbers" >&2; exit 2;; esac
done
if [ -z "$LANE" ]; then
  echo "held-liveness.sh: no lane dir. usage: held-liveness.sh <lane-dir> [--expect-worker W] [--pid-file F] [--log F] [--warn-minutes N]" >&2; exit 2
fi
HELDFILE="$LANE/held.txt"
if [ ! -f "$HELDFILE" ]; then
  say "liveness: NO LIST — $HELDFILE does not exist. Nothing was checked; this is NOT 'no rows to keep alive'."
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "held-liveness.sh: jq is required" >&2; exit 2; }

IDS=()
while IFS= read -r _line || [ -n "$_line" ]; do
  _line="${_line%%#*}"
  # trim surrounding whitespace without leaning on the caller's shell
  _line="$(printf '%s' "$_line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$_line" ] && IDS+=("$_line")
done < "$HELDFILE"

if [ "${#IDS[@]}" -eq 0 ]; then
  say "liveness: EMPTY LIST — $HELDFILE lists no rows. An empty list is NOT 'every row is fine': it is the shape a list trimmed out from under you has. If your lane really holds nothing, stop the pulse loop."
  exit 2
fi

NOW=$(date -u +%s)
PROBLEMS=0; REFUSALS=0; CLOSED=0; MINLEFT=""

for id in "${IDS[@]}"; do
  if ! json=$(env -u BARKPARK_TOKEN "$BP" task get "$id" -o json 2>/dev/null); then
    say "CANNOT READ $id: the ledger read failed. This is NOT a lapse, NOT a foreign claim, and NOT a pass."
    REFUSALS=$((REFUSALS+1)); continue
  fi
  # NOTE the "-" placeholders. bash `read` treats TAB as IFS *whitespace*, so consecutive tabs
  # collapse and an empty field silently shifts every field after it left — which is exactly how
  # a row with no lease_extension came out reading its lifecycle as its lease-until. Never emit
  # an empty @tsv field into `read`.
  if ! parsed=$(printf '%s' "$json" | jq -r '[(.doc.claim.worker // "null"), (.doc.claim.ts_iso // "-"), (.doc.claim.lease_extension.until // "-"), (.doc.content.lifecycle_status // "?")] | @tsv' 2>/dev/null); then
    say "CANNOT READ $id: the ledger answered, but not with parseable JSON. This is NOT a pass."
    REFUSALS=$((REFUSALS+1)); continue
  fi
  IFS=$'\t' read -r w ts ext life <<<"$parsed"
  [ "$ts" = "-" ] && ts=""
  [ "$ext" = "-" ] && ext=""

  # lease-until ALWAYS from the ledger: an extension when an open PR carries one, otherwise the
  # claim's own ts_iso + the 45-min lease (docs/setup/TASK-SYSTEM.md:92).
  src="ts+${LEASE}m"; until_iso="$ext"
  if [ -n "$ext" ]; then
    src="extension"
  elif [ -n "$ts" ]; then
    base=$(iso_epoch "$ts") || base=""
    [ -n "$base" ] && until_iso=$(date -u -r $((base + LEASE*60)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                                  || date -u -d "@$((base + LEASE*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  fi
  if [ -n "$until_iso" ] && ue=$(iso_epoch "$until_iso"); then
    left=$(( (ue - NOW) / 60 ))
  else
    left=""; until_iso="${until_iso:-?}"
  fi
  base_line="$id worker=$w lease-until=${until_iso:-?} lease-source=$src minutes-left=${left:-?}"

  case "$life" in
    done|cancelled|closed)
      say "$base_line CLOSED (lifecycle=$life) — TRIM it from $HELDFILE; pulsing a closed row is how a lane pulses ghosts."
      CLOSED=$((CLOSED+1)); continue;;
  esac
  if [ "$w" = null ] || [ -z "$w" ]; then
    say "$base_line UNCLAIMED — the ledger shows NO holder. Your lane believes it holds this row; the ledger does not."
    PROBLEMS=$((PROBLEMS+1)); continue
  fi
  if [ -n "$EXPECT" ] && [ "$w" != "$EXPECT" ]; then
    say "$base_line FOREIGN — the ledger says '$w', you expected '$EXPECT'. Do not pulse it; message its owner."
    PROBLEMS=$((PROBLEMS+1)); continue
  fi
  if [ -z "$left" ]; then
    say "$base_line UNDATED — the ledger carries no parseable lease timestamp, so the lease cannot be checked. This is NOT a pass."
    PROBLEMS=$((PROBLEMS+1)); continue
  fi
  if [ "$left" -le "$WARN" ]; then
    say "$base_line LAPSING — $left min left, at or under the $WARN-min window. Pulse it NOW or it returns to ready."
    PROBLEMS=$((PROBLEMS+1)); continue
  fi
  say "$base_line ok"
  { [ -z "$MINLEFT" ] || [ "$left" -lt "$MINLEFT" ]; } && MINLEFT="$left"
done

# --- the lane's OWN loop: the two questions a ledger read cannot answer ---------------------
if [ -n "$PULSELOG" ]; then
  if [ ! -s "$PULSELOG" ]; then
    say "STALE LOG: $PULSELOG is missing or empty — the loop has never written a line. A loop that has produced no output is not a running loop."
    PROBLEMS=$((PROBLEMS+1))
  else
    newest=$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$PULSELOG" | tail -1)
    if [ -z "$newest" ] || ! ne=$(iso_epoch "$newest"); then
      say "STALE LOG: the newest line of $PULSELOG carries no parseable ISO timestamp, so its age cannot be measured. This is NOT a pass."
      PROBLEMS=$((PROBLEMS+1))
    else
      age=$(( (NOW - ne) / 60 ))
      if [ "$age" -gt $((INTERVAL + GRACE)) ]; then
        say "STALE LOG: the newest line of $PULSELOG is $age min old, past the ${INTERVAL}-min cadence (+${GRACE} grace). A loop that stops running prints NOTHING — the log just stops growing."
        PROBLEMS=$((PROBLEMS+1))
      else
        say "pulse log: newest line $age min old (cadence ${INTERVAL} min) — fresh."
      fi
    fi
  fi
fi
if [ -n "$PIDFILE" ]; then
  if [ ! -s "$PIDFILE" ]; then
    say "DEAD PID: $PIDFILE is missing or empty — there is no pid to check, so nothing proves a loop is running."
    PROBLEMS=$((PROBLEMS+1))
  else
    pid=$(tr -dc '0-9' < "$PIDFILE")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      say "DEAD PID: pid ${pid:-?} from $PIDFILE is not alive. The loop exited; its exit printed nothing."
      PROBLEMS=$((PROBLEMS+1))
    else
      say "pulse loop: pid $pid alive."
    fi
  fi
fi

[ "$CLOSED" -gt 0 ] && say "TRIM: $CLOSED closed row(s) are still listed in $HELDFILE."
if [ "$REFUSALS" -gt 0 ]; then
  say "liveness: CANNOT READ — $REFUSALS of ${#IDS[@]} row(s) could not be read from the ledger. Nothing here proves your claims survive; re-run before you rely on it."
  exit 3
fi
if [ "$PROBLEMS" -gt 0 ]; then
  say "liveness: $PROBLEMS PROBLEM(S) — see the named lines above."
  exit 1
fi
say "liveness: OK — ${#IDS[@]} row(s) checked, $((${#IDS[@]} - CLOSED)) held by ${EXPECT:-<any worker>}, min lease ${MINLEFT:-n/a} min."
exit 0
