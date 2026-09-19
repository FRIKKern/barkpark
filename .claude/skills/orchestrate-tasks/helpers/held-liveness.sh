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
#   b) when the lease expires                  = MAX(.doc.claim.ts_iso + the 45-minute lease,
#      .doc.claim.lease_extension.until when the key is present) — never the extension ALONE.
#      "A claim is a **45 min** lease (`:task_lease_ttl_seconds`, 2700 s)",
#      docs/setup/TASK-SYSTEM.md line 92. The winning side is printed as `lease-source=`.
#
#      WHY MAX, RE-DERIVED FROM THE SERVER (api/lib/barkpark/tasks/ttl_sweeper.ex, read at
#      e6b983c18; re-read these three sites rather than trusting this comment):
#        * :329  the reap predicate on ts_iso —
#                "((?->'claim'->>'ts_iso')::timestamptz IS NULL OR
#                  (?->'claim'->>'ts_iso')::timestamptz < ?)"   [? = now - ttl]
#        * :340  LEASE-EXTENSION-SQL, an ADDITIONAL `where` the candidate must ALSO satisfy —
#                "((?->'claim'->'lease_extension'->>'until')::timestamptz IS NULL OR
#                  (?->'claim'->'lease_extension'->>'until')::timestamptz <= ?)"   [? = now]
#        * :448  lease_extended?/2, the in-lock re-check: `DateTime.compare(dt, now) == :gt`.
#      Both `where`s are ANDed, so a row is reaped only when ts_iso is stale AND the window has
#      elapsed. The extension is a SKIP, and a skip can only ever LENGTHEN a lease. Reading the
#      extension IN PREFERENCE to ts_iso lets a STALE window SHORTEN the lease, which the server
#      cannot do — measured 2026-09-18T09:54Z on task-b90711d2b54d8c07 (PR #19287 had merged, so
#      nothing renewed the window): a row pulsing on cadence read LAPSING for ~45 minutes.
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
#   * THE PULSE LOG'S STAMP IS A CONTRACT WITH pulse-loop.sh (task-9afe7e0d6c901dbc). Two shapes
#     are accepted: `%Y-%m-%dT%H:%M:%SZ` (what pulse-loop.sh's say() writes today) and the legacy
#     `%H:%M:%SZ` (what it wrote before 2026-09-18 — and what every loop ALREADY RUNNING then
#     keeps writing, because a loop is never edited in place). A line in neither shape is a
#     refusal that NAMES both formats; it is never silently "stale".
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

# epoch seconds -> ISO-8601 Z. GNU date first, then BSD/macOS. Empty on failure, never a guess.
epoch_iso() {
  local e="${1:-}"; [ -n "$e" ] || return 1
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  return 1
}

# ---- THE PULSE LOG'S OWN STAMP (task-9afe7e0d6c901dbc) ---------------------------------------
# A log line's LEADING stamp -> epoch seconds. TWO shapes are accepted, deliberately:
#
#   full-iso   2026-09-18T08:39:57Z   what pulse-loop.sh's say() emits today.
#   time-only  08:39:57Z              what pulse-loop.sh emitted before 2026-09-18.
#
# The legacy shape is NOT dead weight: a pulse loop is never edited in place, so every loop that
# was already running when the format changed keeps writing time-only stamps for the whole of its
# life -- and those are exactly the long-lived loops this helper exists to measure. Refusing that
# shape re-creates the defect this task cured: from 2026-09-10 to 2026-09-18 the parser accepted
# only full ISO while the loop wrote time-only, so EVERY real run printed STALE LOG about a loop
# that was pulsing every 18 minutes. A uniform verdict discriminates nothing.
#
# A time-only stamp carries NO DATE, so today's UTC date is assumed. MIDNIGHT ROLLOVER: a
# 23:59:12Z line read at 00:04Z would date to ~24 h in the FUTURE, and a future instant would
# compute a NEGATIVE age and read as "fresh" -- a silent green on the one line that proves
# nothing. Any result more than ROLLOVER_GRACE seconds ahead of now is therefore pulled back one
# day.
#
# It reports through GLOBALS (LOGSTAMP_EPOCH, LOGSTAMP_SHAPE), not stdout, on purpose: called as
# `e=$(log_stamp_epoch ...)` the shape would be set inside a SUBSHELL and lost, and the caller
# would print a time-only age with no note saying the date was assumed. Returns 1 and clears both
# globals when neither shape is present -- never 0, never a guessed time.
LOGSTAMP_SHAPE=""
LOGSTAMP_EPOCH=""
ROLLOVER_GRACE=120
LOGSTAMP_FORMATS="%Y-%m-%dT%H:%M:%SZ (full ISO, what pulse-loop.sh emits) or %H:%M:%SZ (the legacy time-only stamp)"
log_stamp_epoch() {
  local line="${1:-}" now="${2:-}" stamp e
  LOGSTAMP_SHAPE=""; LOGSTAMP_EPOCH=""
  [ -n "$now" ] || now=$(date -u +%s)
  stamp=$(printf '%s' "$line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}')
  if [ -n "$stamp" ]; then
    e=$(iso_epoch "$stamp") || return 1
    LOGSTAMP_SHAPE="full-iso"; LOGSTAMP_EPOCH="$e"; return 0
  fi
  stamp=$(printf '%s' "$line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}')
  [ -n "$stamp" ] || return 1
  e=$(iso_epoch "$(date -u +%Y-%m-%d)T$stamp") || return 1
  [ "$e" -gt $((now + ROLLOVER_GRACE)) ] && e=$((e - 86400))
  LOGSTAMP_SHAPE="time-only"; LOGSTAMP_EPOCH="$e"; return 0
}

# ------------------------------------------------------------------ SELFTEST (no network) ----
# Drives the helper against a stub `bp` on PATH, from a NON-REPO cwd, with real clock arithmetic
# (every fixture timestamp is computed from `date` at run time, so no arm can pass by matching a
# frozen string). Seven arms:
#   1 all-held green                     2 a row whose ledger worker DIFFERS  -> named, exit 1
#   3 a lease inside the warning window  4 a pulse log older than the interval -> named, exit 1
#   3b an open-PR extension LONGER than the ts lease (both rules agree -> it measures neither)
#   3c a STALE extension under a FRESH ts_iso: ok, lease-source=ts+45m  (task-c5d38911080f3592)
#   3d a FUTURE extension over a STALE ts_iso: ok, lease-source=extension (the mirror)
#   MUTATION that must red 3c: `if [ -n "$ext_e" ]; then src=extension` first, i.e. prefer the
#   extension. MUTATION that must red 3d: drop the ext_e branch and always take ts_e.
#   4b the log pulse-loop.sh ACTUALLY WROTE (that helper is RUN, one round, stub bp) is measured
#   4c every `date -u +<fmt>` READ OUT OF pulse-loop.sh's source is accepted, both directions
#   4d CONTROL: the legacy time-only stamp is parsed, fresh and old, never silently STALE
#   4e the midnight-rollover guard: a future-dated time-only stamp cannot read as fresh
#   4f a log with no readable stamp REFUSES with a line naming both accepted formats
#   5 a dead pid                         6 an unreadable ledger -> CANNOT READ, exit 3, and the
#                                          output contains no "held"/"OK" reassurance
#   7 an EMPTY held.txt -> exit 2 with its own line (an empty list is not "all held")
# Each arm asserts the LAST line, the exit code, and that the failing ROW is NAMED.
# Arms 4b-4f exist because arm 4's fixture is written by THIS file's own _ago(): it could only
# ever prove the parser reads the shape this file imagines, and for eight days it did exactly
# that while every real run printed STALE LOG about a live loop.
# MUTATION that must red 4d: drop the time-only branch of log_stamp_epoch(). MUTATION that must
# red 4e: delete the `-gt now+ROLLOVER_GRACE` pull-back (the future stamp then reads as fresh).
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
  # NOTE on this fixture (it does NOT encode the old preference): ts_iso 38 min ago on a 45-min
  # lease expires in 7 min, the window in 90 — so the extension is ALSO the max, and this arm
  # stays green under both the old preference rule and the new max() rule. That is exactly why
  # it could never have caught task-c5d38911080f3592: an arm whose two rules agree measures
  # neither. Arms 3c and 3d are the two orderings where they DISAGREE.
  _row task-aaa lead-x "$(_ago 38)" in_progress "$(_in 90)"
  if _run "arm3b runs" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
    _last "arm3b verdict is OK" 'liveness: OK'
    _want "arm3b uses the extension" 1 '^task-aaa .*lease-source=extension'
  fi

  echo "== arm 3c (task-c5d38911080f3592): a STALE extension never SHORTENS a fresh ts_iso lease"
  # THE MEASURED SHAPE. ts_iso 5 min ago => ts lease has ~40 min left. lease_extension.until is
  # 20 min in the PAST (the PR merged; nothing renews the window). The server reaps on
  # ts_iso + ttl (ttl_sweeper.ex:329) and treats the window as an ADDITIONAL skip (:340, :448),
  # so this row is SAFE. Preferring the extension reports LAPSING on a row pulsing on cadence.
  _row task-aaa lead-x "$(_ago 5)" in_progress "$(_ago 20)"
  if _run "arm3c runs" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
    _last "arm3c verdict is OK" 'liveness: OK'
    _want "arm3c ts_iso wins the max"    1 "^task-aaa .*lease-source=ts\\+45m"
    _want "arm3c keeps the ~40 min left" 1 '^task-aaa .*minutes-left=(39|40|41) '
    _want "arm3c NEVER calls it lapsing" 0 '^task-aaa .*LAPSING'
  fi

  echo "== arm 3d (mirror): a FUTURE extension over a STALE ts_iso still wins — max, not ts-only"
  # The other ordering. ts_iso 80 min ago (its 45-min lease elapsed 35 min ago) but the window
  # is open 20 min out: ttl_sweeper.ex:340/:448 SKIP this row, so it is held, via the extension.
  # This arm is what stops the fix over-correcting into "always ts_iso".
  _row task-aaa lead-x "$(_ago 80)" in_progress "$(_in 20)"
  if _run "arm3d runs" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
    _last "arm3d verdict is OK" 'liveness: OK'
    _want "arm3d extension wins the max" 1 '^task-aaa .*lease-source=extension'
    _want "arm3d NEVER calls it lapsing" 0 '^task-aaa .*LAPSING'
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

  echo "== arm 4b: a log line pulse-loop.sh ACTUALLY WROTE is measurable (cross-helper lock)"
  # The arm-4 fixture above is written by THIS file's _ago, so it can only prove the parser reads
  # the shape this file IMAGINES. task-9afe7e0d6c901dbc: from 2026-09-10 to 2026-09-18
  # pulse-loop.sh wrote %H:%M:%SZ while this parser wanted ^YYYY-MM-DDT..., and every real run
  # printed STALE LOG "no parseable ISO timestamp" about a loop pulsing every 18 minutes -- a
  # uniform verdict the self-made fixture never saw.
  #
  # So this arm does not type a stamp at all. It RUNS pulse-loop.sh (one round, stub bp, no
  # network) and hands held-liveness.sh the log THAT run wrote, through pulse-loop's own say().
  local PL
  PL="$(dirname "$SELF")/pulse-loop.sh"
  if [ ! -f "$PL" ]; then
    echo "FAIL arm4b: $PL is not there — the cross-helper lock cannot see its subject"; fails=$((fails+1))
  else
    mkdir -p "$d/pl"
    cat > "$d/bin/bp-pulse-stub" <<'PSTUB'
#!/usr/bin/env bash
echo '{"ok":true,"doc":{"claim":{"epoch":1}}}'
PSTUB
    chmod +x "$d/bin/bp-pulse-stub"
    # pulse-loop.sh calls `bp` by name; give it one that always answers ok, ahead of the row stub.
    mkdir -p "$d/plbin"; cp "$d/bin/bp-pulse-stub" "$d/plbin/bp"
    printf '%s\n' task-aaa > "$d/pl/held.txt"
    : > "$d/pl/pulse.log"
    ( PATH="$d/plbin:$PATH" PULSE_LOOP_ALLOW_FAST=1 bash "$PL" --interval 0 --passes 1 \
        lead-x "$d/pl/held.txt" "$d/pl/pulse.log" >/dev/null 2>&1 )
    if [ ! -s "$d/pl/pulse.log" ]; then
      echo "FAIL arm4b: pulse-loop.sh wrote no log line — the lock has no subject to measure"; fails=$((fails+1))
    else
      echo "     pulse-loop.sh wrote: $(tail -1 "$d/pl/pulse.log")"
      cp "$d/pl/pulse.log" "$d/lane/pulse.log"
      if _run "arm4b runs (log written BY pulse-loop.sh)" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
        _last "arm4b verdict is OK"     'liveness: OK'
        _want "arm4b measured the age"  1 'pulse log: newest line [0-9]+ min old'
        _want "arm4b saw no STALE LOG"  0 'STALE LOG'
      fi
    fi
  fi
  printf '%s ok task-aaa\n' "$(_ago 4)" > "$d/lane/pulse.log"

  echo "== arm 4c: EVERY stamp format pulse-loop.sh emits is a format this parser accepts"
  # A PREDICATE, not a two-item list: the formats are read out of pulse-loop.sh's source at run
  # time, so a NEW `date -u +<fmt>` added there tomorrow is checked tomorrow without editing this
  # arm. Each format is exercised in BOTH directions -- fresh must not say STALE, old must.
  if [ -f "$PL" ]; then
    local fmts nfmt=0 f
    fmts=$(grep -oE 'date -u \+[^)"'"'"' ]+' "$PL" | sed 's/^date -u +//' | sort -u)
    if [ -z "$fmts" ]; then
      echo "FAIL arm4c: no 'date -u +<fmt>' found in $PL — the lock cannot see its subject"; fails=$((fails+1))
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      nfmt=$((nfmt+1))
      printf '%s ok task-aaa\n' "$(date -u -v-4M +"$f" 2>/dev/null || date -u -d '4 minutes ago' +"$f")" > "$d/lane/pulse.log"
      if _run "arm4c fresh '$f'" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
        _want "arm4c '$f' fresh is measured"  1 'pulse log: newest line [0-9]+ min old'
        _want "arm4c '$f' fresh is not STALE" 0 'STALE LOG'
      fi
      printf '%s ok task-aaa\n' "$(date -u -v-55M +"$f" 2>/dev/null || date -u -d '55 minutes ago' +"$f")" > "$d/lane/pulse.log"
      if _run "arm4c old '$f'" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
        _want "arm4c '$f' old is STALE with its age" 1 'STALE LOG.*55 min'
      fi
    done <<EOF
$fmts
EOF
    echo "     arm4c checked $nfmt distinct pulse-loop.sh stamp format(s)"
  fi
  printf '%s ok task-aaa\n' "$(_ago 4)" > "$d/lane/pulse.log"

  echo "== arm 4d CONTROL: the LEGACY time-only stamp is PARSED, never silently STALE"
  # A loop is never edited in place. Every pulse loop that was already running on 2026-09-18
  # keeps writing `08:39:57Z` for the rest of its life, and those are the long-lived loops this
  # helper exists to measure. Fresh must read fresh; old must read old, with the age.
  printf '%s ok task-aaa\n' "$(date -u -v-4M +%H:%M:%SZ 2>/dev/null || date -u -d '4 minutes ago' +%H:%M:%SZ)" > "$d/lane/pulse.log"
  if _run "arm4d legacy fresh" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm4d legacy fresh verdict is OK"  'liveness: OK'
    _want "arm4d legacy fresh is measured"    1 'pulse log: newest line [0-9]+ min old'
    _want "arm4d legacy fresh names the shape" 1 'legacy time-only stamp'
    _want "arm4d legacy fresh is not STALE"   0 'STALE LOG'
  fi
  printf '%s ok task-aaa\n' "$(date -u -v-55M +%H:%M:%SZ 2>/dev/null || date -u -d '55 minutes ago' +%H:%M:%SZ)" > "$d/lane/pulse.log"
  if _run "arm4d legacy old" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
    _want "arm4d legacy old is STALE with its age" 1 'STALE LOG.*55 min'
  fi

  echo "== arm 4e: the midnight-rollover guard — a time-only stamp cannot read as FUTURE-fresh"
  # 23:59:12Z read at 00:04Z dates to ~24 h ahead if today's date is pasted on blindly; a future
  # instant computes a NEGATIVE age and passes the freshness test. The guard pulls it back a day,
  # so the line reads ~1 day old -- STALE, loudly, which is the honest answer for a stamp whose
  # date nobody wrote down. Simulated here by stamping 30 min in the FUTURE.
  printf '%s ok task-aaa\n' "$(date -u -v+30M +%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes' +%H:%M:%SZ)" > "$d/lane/pulse.log"
  if _run "arm4e future-dated time-only" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
    _want "arm4e did NOT read it as fresh" 0 'newest line [0-9]+ min old \(cadence'
    _want "arm4e pulled it back one day"   1 'STALE LOG.*1[34][0-9][0-9] min old'
  fi

  echo "== arm 4f: a log with NO readable stamp REFUSES with a line that NAMES both formats"
  printf 'pulse-loop: something happened\nanother unstamped line\n' > "$d/lane/pulse.log"
  if _run "arm4f unstamped log" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm4f names the full-ISO format"  1 'Accepted:.*%Y-%m-%dT%H:%M:%SZ'
    _want "arm4f names the legacy format"    1 'Accepted:.*%H:%M:%SZ'
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

  echo "== arm 9 (task-50d7d1a599dd14dd): --session reads THIS session's list, never the lane-wide one"
  # Two sessions of one lane. s1 holds task-aaa; s2 holds task-ccc. The legacy
  # lane-wide held.txt still lists task-bbb, and neither session may read it.
  printf '%s\n' task-aaa > "$d/lane/held.s1.txt"
  printf '%s\n' task-ccc > "$d/lane/held.s2.txt"
  _row task-aaa lead-x "$(_ago 2)" in_progress
  _row task-ccc lead-x "$(_ago 2)" in_progress
  printf '%s ok task-aaa\n%s ok task-ccc\n' "$(_ago 4)" "$(_ago 4)" > "$d/lane/pulse.log"
  if _run "arm9 s1 runs" 0 -- "$d/lane" --session s1 --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm9 s1 sees its own row"      1 '^task-aaa '
    _want "arm9 s1 cannot see s2's row"   0 '^task-ccc '
    _want "arm9 s1 cannot see held.txt's" 0 '^task-bbb '
  fi
  if _run "arm9 s2 runs" 0 -- "$d/lane" --session s2 --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm9 s2 sees its own row"    1 '^task-ccc '
    _want "arm9 s2 cannot see s1's row" 0 '^task-aaa '
  fi

  echo "== arm 10: a NAMED list that is absent REFUSES (exit 2) — it never falls back to the lane-wide file"
  if _run "arm10 runs" 2 -- "$d/lane" --session s99 --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm10 names the missing per-session file" 1 'held\.s99\.txt does not exist'
    _want "arm10 did NOT read the lane-wide list"    0 '^task-bbb '
  fi

  rm -rf "$d"
  if [ "$fails" -gt 0 ]; then echo "held-liveness.sh selftest: $fails FAILED"; return 1; fi
  echo "held-liveness.sh selftest: all arms passed"; return 0
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ------------------------------------------------------------------ ARGUMENTS ----------------
EXPECT=""; PIDFILE=""; PULSELOG=""; WARN=15; INTERVAL=18; LEASE=45; BP="bp"; GRACE=3
LANE=""; HELDARG=""; SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-worker)  EXPECT="${2:-}"; shift 2;;
    # PER-SESSION PULSE LISTS (task-50d7d1a599dd14dd). Two sessions of one lane
    # each own a held.<session>.txt; naming the file (or the session) is how a
    # session reads ITS OWN list instead of a peer's. Bare held.txt stays the
    # default so a pre-session lane dir keeps working unchanged.
    --held)           HELDARG="${2:-}"; shift 2;;
    --session)        SESSION="${2:-}"; shift 2;;
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
# THE LIST THIS SESSION OWNS. Precedence: an explicit --held file, else the
# per-session name from --session, else the legacy lane-wide held.txt. Naming
# a file that is not there is a REFUSAL below, never a silent fallback to the
# lane-wide list: reading a peer's list would attribute its rows to you.
if [ -n "$HELDARG" ]; then
  HELDFILE="$HELDARG"
elif [ -n "$SESSION" ]; then
  HELDFILE="$LANE/held.$SESSION.txt"
else
  HELDFILE="$LANE/held.txt"
fi
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

  # lease-until ALWAYS from the ledger, and ALWAYS the LATER of the two candidates — the shape
  # ttl_sweeper.ex:329 + :340 (both `where`s ANDed) and :448 enforce. See the header's (b).
  # An extension can only LENGTHEN a lease; a STALE window (its PR merged, nothing renewed it)
  # must never shorten one. `lease-source=` names the side that won, so a reader can tell a
  # ts-driven lease from a PR-extended one WITHOUT re-reading the row.
  ts_e=""; ts_until=""; ext_e=""
  if [ -n "$ts" ]; then
    if base=$(iso_epoch "$ts"); then
      ts_e=$((base + LEASE*60)); ts_until=$(epoch_iso "$ts_e") || { ts_e=""; ts_until=""; }
    fi
  fi
  [ -n "$ext" ] && { ext_e=$(iso_epoch "$ext") || ext_e=""; }

  src="?"; until_iso=""; ue=""
  if [ -n "$ts_e" ] && { [ -z "$ext_e" ] || [ "$ts_e" -ge "$ext_e" ]; }; then
    src="ts+${LEASE}m"; until_iso="$ts_until"; ue="$ts_e"
  elif [ -n "$ext_e" ]; then
    src="extension"; until_iso="$ext"; ue="$ext_e"
  fi
  if [ -n "$ue" ]; then
    left=$(( (ue - NOW) / 60 ))
  else
    # Nothing parseable on either side. Show the raw string we DID get, never a computed one.
    left=""; until_iso="${ext:-${ts:-?}}"; [ -n "$until_iso" ] || until_iso="?"
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
    # The newest line that CARRIES a stamp in either accepted shape. Matching on the stamp (not
    # on `tail -1`) means a trailing stack trace or a bare continuation line cannot hide a fresh
    # pulse -- and a log of nothing BUT such lines still refuses below, by name.
    newest=$(grep -E '^([0-9]{4}-[0-9]{2}-[0-9]{2}T)?[0-9]{2}:[0-9]{2}:[0-9]{2}' "$PULSELOG" | tail -1)
    if [ -z "$newest" ] || ! log_stamp_epoch "$newest" "$NOW"; then
      say "STALE LOG: the newest line of $PULSELOG carries no stamp this helper can read, so its age cannot be measured. Accepted: $LOGSTAMP_FORMATS. This is NOT a pass."
      PROBLEMS=$((PROBLEMS+1))
    else
      shape_note=""
      [ "$LOGSTAMP_SHAPE" = time-only ] && shape_note=" [legacy time-only stamp — today's UTC date assumed]"
      age=$(( (NOW - LOGSTAMP_EPOCH) / 60 ))
      if [ "$age" -gt $((INTERVAL + GRACE)) ]; then
        say "STALE LOG: the newest line of $PULSELOG is $age min old, past the ${INTERVAL}-min cadence (+${GRACE} grace).${shape_note} A loop that stops running prints NOTHING — the log just stops growing."
        PROBLEMS=$((PROBLEMS+1))
      else
        say "pulse log: newest line $age min old (cadence ${INTERVAL} min) — fresh.${shape_note}"
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
