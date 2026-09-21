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
#   e) whether ANY OTHER process on the box is pulsing a row on that list (the GHOST SCAN,
#      task-d2fba9b9c019997b). Measured 2026-09-20: four pulse-loop.sh processes were still
#      running 25 hours after the leads that started them died on the session cap, each reading
#      a held.s24.txt, while the relaunched s25 leads ran fresh loops beside them. Two processes
#      sharing one worker id pulse the same row, so its claim epoch advances at DOUBLE rate from
#      a source the lead cannot see — and `bp task close` is a CAS on that epoch, so an epoch
#      read a minute before the write is already stale and the refusal says `stale_claim`, which
#      points at the ledger and not at a second process on this box.
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
#   * THE CHECKOUT-DISTANCE BANNER (task-0d92408b59ae2190). Every run prints, BEFORE any row
#     verdict, how far the git checkout this helper was read from is BEHIND the last-known
#     `origin/main`. Measured 2026-09-21: the shared checkout was 581 commits behind and two
#     independent false findings were filed in one shift off it, neither caught by inspection,
#     because a stale read is not an error — `cat`, `grep` and `git show HEAD:<path>` all
#     SUCCEED and return well-formed, internally consistent content that was true 581 commits
#     ago. The failure is a CONFIRMED ANSWER TO THE WRONG QUESTION. This helper is the venue
#     because every lead already runs it at the top of every loop; a doctrine line was already
#     written and was read and then not applied, twice, on the same day.
#     IT IS ADVISORY AND TOUCHES NOTHING. It never increments PROBLEMS and never changes the
#     exit code — leads branch on 0/1/2/3/4 and that contract is unchanged (arm 13d proves it).
#     IT NEVER FETCHES: a fetch on a per-loop helper is network on someone else's cadence, and
#     an unfetched ref can only UNDER-report, so the number is a FLOOR and the line says so.
#     A tree it cannot measure prints CHECKOUT DISTANCE UNKNOWN and NEVER a "0" — a failed read
#     that renders byte-identical to a zero has already cost this campaign real incidents.
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
#   --no-ghost-scan    skip the ghost scan (e) entirely. For arms of the selftest that are about
#                      something else; a lane should never pass it.
#   --checkout DIR     the tree whose distance from origin/main the banner measures. Default:
#                      the checkout this helper's own file lives in (if that file is not inside
#                      one, the current directory), because the helper you are running comes
#                      from the same tree as everything else you are reading.
#   --no-checkout-banner  skip the distance banner entirely.
#   --git-cmd CMD      the git used by the banner (default `git`). A TEST SEAM for arm 13.
#   --ps-cmd CMD       the process enumerator for (e). Default `ps -axww -o pid=,args=`. A TEST
#                      SEAM: the selftest drives the empty-population refusal with `--ps-cmd
#                      true`. The matching itself is never stubbed — the positive-control arm
#                      starts a REAL second process and finds it through real ps.
#
# THE GHOST SCAN NEVER KILLS ANYTHING. It reports. A wrong kill strands a peer lane's claims, so
# the verdict distinguishes a ghost carrying YOUR OWN worker id and nothing but your rows (safe
# to stop) from a PEER's live loop (never stop it — it may be the only thing holding that peer's
# rows). Processes are matched on the ARGV this run actually parsed, never on a name, and the
# matched worker and held file are printed so the reader can check the match.
#
# EXIT: 0 = every row held by the expected worker with room to spare, log fresh, pid alive, and
#           no other process pulsing the list.
#       1 = at least one NAMED violation.  2 = bad arguments / missing or EMPTY held.txt.
#       3 = at least one ledger read REFUSED (CANNOT READ). 3 beats 1: an unread row is unknown.
#       4 = the ghost scan could not enumerate ANY pulse-loop process, not even this lane's own.
#           A failed read must never be byte-identical to a zero, so this is its own code and its
#           own line; it beats 1 for the same reason 3 does.
#       The checkout-distance banner NEVER contributes to any of these. It is advisory text.
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

# ---- THE CHECKOUT-DISTANCE BANNER (task-0d92408b59ae2190) -----------------------------------
# WHY IT LIVES IN THIS FILE AND NOT IN A BRIEF. On 2026-09-21 the shared checkout
# /Volumes/SATECHI/github/barkpark was 581 commits behind origin/main. A lead filed a P1 against
# an instrument that had already been fixed on main, and a builder sent two false corrections to
# the lead who filed the row — both from reads that SUCCEEDED. The brief already said "helpers
# from a FRESH worktree"; it was read, and then not applied, by two different agents on the same
# day. A written finding does not fire by itself, so this one is a line of output on a command
# every lead already runs.
#
# WHY INSPECTION CANNOT CATCH THE THING THIS MEASURES. The stale checkout is a valid git repo,
# on main, clean. `cat`, `grep`, `sed` and `git show HEAD:<path>` all return exit 0 and
# well-formed, internally CONSISTENT content — the file agrees with its own tests, its own
# comments and its sibling files, because it is a coherent older SNAPSHOT of the tree, not a
# corruption of the current one. There is no error, no empty read, no malformed byte to notice.
# The failure is a confirmed answer to the wrong question, and the only thing that can see it is
# a comparison against a ref the reader did not read the file from.
#
# WHAT IT DOES NOT DO:
#   * It does not fetch. A helper on an 18-minute lead loop is the wrong place to put network
#     traffic, and refs/remotes/origin/main on disk is already the thing every `git show
#     origin/main:<path>` in the campaign resolves against — so measuring it is measuring what
#     the reader will actually get. An unfetched ref can only ever UNDER-state the distance, so
#     the number is a FLOOR and every branch of the line says so.
#   * It does not touch PROBLEMS, REFUSALS or the exit code. Leads branch on 0/1/2/3/4.
#   * It never prints "0" for a tree it could not measure. Three distinct refusals (not a repo /
#     no origin/main ref / rev-list produced no number) each say UNKNOWN and say that it is not
#     a zero, because an empty variable rendering as a confident 0 is the exact shape that has
#     already cost this campaign real incidents.
checkout_distance_banner() {
  [ "$CHECKOUT_BANNER" = 1 ] || return 0
  local d="$CHECKOUT_DIR" src top behind tip
  if [ -n "$d" ]; then
    src="--checkout"
  else
    d=$(cd -- "$(dirname -- "$SELF")" 2>/dev/null && pwd) || d=""
    if [ -n "$d" ] && "$GIT_CMD" -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
      src="the tree this helper itself was read from"
    else
      d="$PWD"; src="the current directory — this helper's own file is not inside a checkout"
    fi
  fi
  if ! "$GIT_CMD" -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    say "CHECKOUT DISTANCE UNKNOWN: $d ($src) is not a git checkout, so its distance from origin/main was NOT measured. This is a failed measurement, NOT a zero."
    return 0
  fi
  top=$("$GIT_CMD" -C "$d" rev-parse --show-toplevel 2>/dev/null); [ -n "$top" ] && d="$top"
  if ! "$GIT_CMD" -C "$d" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then
    say "CHECKOUT DISTANCE UNKNOWN: $d ($src) has no refs/remotes/origin/main, so there is nothing on disk to measure against and the distance was NOT measured. This is a failed measurement, NOT a zero. Run: git -C $d fetch origin main"
    return 0
  fi
  behind=$("$GIT_CMD" -C "$d" rev-list --count HEAD..refs/remotes/origin/main 2>/dev/null)
  case "${behind:-}" in
    ''|*[!0-9]*)
      say "CHECKOUT DISTANCE UNKNOWN: 'git -C $d rev-list --count HEAD..refs/remotes/origin/main' produced no number, so the distance was NOT measured. This is a failed measurement, NOT a zero."
      return 0;;
  esac
  # UTC, always. A local-offset stamp in a campaign whose agents compare times across lanes is
  # how a "guessed clock" gets manufactured; and an unreadable date says so rather than printing
  # an empty string that reads as a missing field.
  tip=$(TZ=UTC0 "$GIT_CMD" -C "$d" log -1 --date=iso-strict-local --format=%cd refs/remotes/origin/main 2>/dev/null)
  [ -n "$tip" ] || tip=$("$GIT_CMD" -C "$d" log -1 --format=%cI refs/remotes/origin/main 2>/dev/null)
  [ -n "$tip" ] || tip="date unreadable"
  if [ "$behind" -eq 0 ]; then
    say "checkout: $d ($src) is LEVEL with the origin/main ref ON DISK — 0 commits behind, ref tip committed $tip. NO FETCH WAS PERFORMED, so this is a floor: fetch before you trust it (git -C $d fetch origin main)."
    return 0
  fi
  say "CHECKOUT STALE: $d ($src) is $behind COMMIT(S) BEHIND the origin/main ref ON DISK (ref tip committed $tip), and NO FETCH WAS PERFORMED, so the real distance is $behind OR MORE."
  say "CHECKOUT STALE: every cat / grep / 'git show HEAD:<path>' in that tree SUCCEEDS and hands you well-formed, internally consistent content that was true $behind commits ago — there is no error to notice, so the failure mode is a CONFIRMED ANSWER TO THE WRONG QUESTION, not a read that fails. Orient at the REF instead: git -C $d fetch origin main && git -C $d show origin/main:<path> | grep …  — or cut a worktree: git worktree add <dir> origin/main. (This banner is advisory; it did not change this run's exit code.)"
  return 0
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
#  13 THE CHECKOUT-DISTANCE BANNER, against REAL git repos this arm builds (no network):
#     13a a checkout 2 commits behind its own refs/remotes/origin/main -> CHECKOUT STALE naming
#         the count; 13b THE CONTROL, the SAME repo with the ref moved onto HEAD -> level, 0,
#         and no CHECKOUT STALE line at all; 13c two unmeasurable trees (not a repo / no
#         origin/main ref) -> UNKNOWN, each saying it is NOT a zero, and NEVER the string
#         "0 commits behind"; 13d THE EXIT CONTRACT: 13a's firing banner over an all-held green
#         lane still exits 0 and still ends on "liveness: OK"; 13e --no-checkout-banner is
#         silent. MUTATION that must red 13b: make the zero branch print the STALE text (13a
#         alone cannot tell a real measurement from a banner that always fires). MUTATION that
#         must red 13c: replace either UNKNOWN say with the level line — an unmeasured tree then
#         renders byte-identical to a measured zero, which is the defect, not the fix.
#  11 THE GHOST SCAN's positive control: a real second process with a pulse-loop argv pulsing a
#     row on this list -> NAMED, exit 1 (11a); the overlap removed while the same processes keep
#     running -> the SAME arm goes GREEN (11b); an enumerator that returns nothing -> exit 4,
#     never a clean no-ghost verdict (11c).
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
  if _run "arm1 runs" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm1 verdict is OK" 'liveness: OK'
    _want "arm1 names both rows" 2 '^(task-aaa|task-bbb) '
    _want "arm1 flags nothing"   0 'FOREIGN|LAPSING|UNCLAIMED|STALE LOG|DEAD PID|CANNOT READ'
  fi

  echo "== arm 2: a row the LEDGER says another worker holds -> NAMED, exit 1"
  _row task-bbb lead-other "$(_ago 2)" in_progress
  if _run "arm2 runs" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm2 verdict is a problem count" 'liveness: [0-9]+ PROBLEM'
    _want "arm2 NAMES the foreign row"      1 '^task-bbb .*FOREIGN'
    _want "arm2 does not flag the good row" 0 '^task-aaa .*(FOREIGN|LAPSING)'
  fi
  _row task-bbb lead-x "$(_ago 2)" in_progress

  echo "== arm 3: a lease inside the warning window -> NAMED, exit 1"
  # claimed 38 min ago on a 45-min lease => 7 min left, inside a 15-min warning window.
  _row task-aaa lead-x "$(_ago 38)" in_progress
  if _run "arm3 runs" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
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
  if _run "arm3b runs" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
    _last "arm3b verdict is OK" 'liveness: OK'
    _want "arm3b uses the extension" 1 '^task-aaa .*lease-source=extension'
  fi

  echo "== arm 3c (task-c5d38911080f3592): a STALE extension never SHORTENS a fresh ts_iso lease"
  # THE MEASURED SHAPE. ts_iso 5 min ago => ts lease has ~40 min left. lease_extension.until is
  # 20 min in the PAST (the PR merged; nothing renews the window). The server reaps on
  # ts_iso + ttl (ttl_sweeper.ex:329) and treats the window as an ADDITIONAL skip (:340, :448),
  # so this row is SAFE. Preferring the extension reports LAPSING on a row pulsing on cadence.
  _row task-aaa lead-x "$(_ago 5)" in_progress "$(_ago 20)"
  if _run "arm3c runs" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
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
  if _run "arm3d runs" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --warn-minutes 15; then
    _last "arm3d verdict is OK" 'liveness: OK'
    _want "arm3d extension wins the max" 1 '^task-aaa .*lease-source=extension'
    _want "arm3d NEVER calls it lapsing" 0 '^task-aaa .*LAPSING'
  fi
  _row task-aaa lead-x "$(_ago 5)" in_progress

  echo "== arm 4: a pulse log older than the interval -> NAMED, exit 1 (the dead-loop shape)"
  printf '%s ok task-aaa\n' "$(_ago 55)" > "$d/lane/pulse.log"
  if _run "arm4 runs" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
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
      if _run "arm4b runs (log written BY pulse-loop.sh)" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
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
      if _run "arm4c fresh '$f'" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
        _want "arm4c '$f' fresh is measured"  1 'pulse log: newest line [0-9]+ min old'
        _want "arm4c '$f' fresh is not STALE" 0 'STALE LOG'
      fi
      printf '%s ok task-aaa\n' "$(date -u -v-55M +"$f" 2>/dev/null || date -u -d '55 minutes ago' +"$f")" > "$d/lane/pulse.log"
      if _run "arm4c old '$f'" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
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
  if _run "arm4d legacy fresh" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm4d legacy fresh verdict is OK"  'liveness: OK'
    _want "arm4d legacy fresh is measured"    1 'pulse log: newest line [0-9]+ min old'
    _want "arm4d legacy fresh names the shape" 1 'legacy time-only stamp'
    _want "arm4d legacy fresh is not STALE"   0 'STALE LOG'
  fi
  printf '%s ok task-aaa\n' "$(date -u -v-55M +%H:%M:%SZ 2>/dev/null || date -u -d '55 minutes ago' +%H:%M:%SZ)" > "$d/lane/pulse.log"
  if _run "arm4d legacy old" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
    _want "arm4d legacy old is STALE with its age" 1 'STALE LOG.*55 min'
  fi

  echo "== arm 4e: the midnight-rollover guard — a time-only stamp cannot read as FUTURE-fresh"
  # 23:59:12Z read at 00:04Z dates to ~24 h ahead if today's date is pasted on blindly; a future
  # instant computes a NEGATIVE age and passes the freshness test. The guard pulls it back a day,
  # so the line reads ~1 day old -- STALE, loudly, which is the honest answer for a stamp whose
  # date nobody wrote down. Simulated here by stamping 30 min in the FUTURE.
  printf '%s ok task-aaa\n' "$(date -u -v+30M +%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes' +%H:%M:%SZ)" > "$d/lane/pulse.log"
  if _run "arm4e future-dated time-only" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --pulse-interval-minutes 18; then
    _want "arm4e did NOT read it as fresh" 0 'newest line [0-9]+ min old \(cadence'
    _want "arm4e pulled it back one day"   1 'STALE LOG.*1[34][0-9][0-9] min old'
  fi

  echo "== arm 4f: a log with NO readable stamp REFUSES with a line that NAMES both formats"
  printf 'pulse-loop: something happened\nanother unstamped line\n' > "$d/lane/pulse.log"
  if _run "arm4f unstamped log" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm4f names the full-ISO format"  1 'Accepted:.*%Y-%m-%dT%H:%M:%SZ'
    _want "arm4f names the legacy format"    1 'Accepted:.*%H:%M:%SZ'
  fi
  printf '%s ok task-aaa\n' "$(_ago 4)" > "$d/lane/pulse.log"

  echo "== arm 5: the pulse loop's pid is not alive -> NAMED, exit 1"
  echo "$DEAD" > "$d/lane/pulse.pid"
  if _run "arm5 runs" 1 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm5 verdict is a problem count" 'liveness: [0-9]+ PROBLEM'
    _want "arm5 names the dead pid"         1 "DEAD PID.*$DEAD"
  fi
  echo "$ALIVE" > "$d/lane/pulse.pid"

  echo "== arm 6: an unreadable ledger -> CANNOT READ, exit 3, and NO reassuring verdict"
  out=$(cd "$d" && PATH="$d/bin:$PATH" STUB_DIR="$d" BP_STUB_BREAK=task-bbb \
        bash "$SELF" "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" 2>&1); rc=$?
  if [ "$rc" = 3 ]; then echo "ok   arm6 runs (exit 3)"
  else echo "FAIL arm6: exit $rc, wanted 3"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  _last "arm6 verdict is CANNOT READ"  'liveness: CANNOT READ'
  _want "arm6 NAMES the unread row"    1 '^CANNOT READ task-bbb'
  # The whole point: a refusal must not be readable as a green. No "held", no "OK", anywhere.
  _want "arm6 says nothing about being held" 0 '[Hh]eld'
  _want "arm6 never says OK"                 0 '\bOK\b'

  echo "== arm 7: an EMPTY held.txt is exit 2 with its own line — an empty list is not 'all held'"
  : > "$d/lane/held.txt"
  if _run "arm7 runs" 2 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm7 verdict names the empty list" 'liveness: EMPTY LIST'
    _want "arm7 refuses to call it fine"      0 'liveness: OK'
  fi
  printf '%s\n' task-aaa task-bbb > "$d/lane/held.txt"

  echo "== arm 8: a done row is CLOSED + a TRIM advisory, not a violation (exit stays 0)"
  _row task-bbb lead-x "$(_ago 200)" "done"
  if _run "arm8 runs" 0 -- "$d/lane" --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
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
  if _run "arm9 s1 runs" 0 -- "$d/lane" --session s1 --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm9 s1 sees its own row"      1 '^task-aaa '
    _want "arm9 s1 cannot see s2's row"   0 '^task-ccc '
    _want "arm9 s1 cannot see held.txt's" 0 '^task-bbb '
  fi
  if _run "arm9 s2 runs" 0 -- "$d/lane" --session s2 --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm9 s2 sees its own row"    1 '^task-ccc '
    _want "arm9 s2 cannot see s1's row" 0 '^task-aaa '
  fi

  echo "== arm 10: a NAMED list that is absent REFUSES (exit 2) — it never falls back to the lane-wide file"
  if _run "arm10 runs" 2 -- "$d/lane" --session s99 --expect-worker lead-x --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm10 names the missing per-session file" 1 'held\.s99\.txt does not exist'
    _want "arm10 did NOT read the lane-wide list"    0 '^task-bbb '
  fi

  echo "== arm 11 (task-d2fba9b9c019997b): THE GHOST SCAN's positive control"
  # HOW THE SECOND LOOP IS MADE, and why it is not a stub: it is a REAL process, started as
  # `bash <dir>/pulse-loop.sh <worker> <held> <log>` — the exact argv shape the production loop
  # has on this box (`ps` 2026-09-20: `bash .../pulse-loop.sh lead-studio .../held.s24.txt
  # .../pulse.s24.log`). So the arm drives real ps output, the real argv parse, the real read of
  # the other process's held file and the real overlap test. Only the loop's BODY is harmless:
  # it sleeps and never invokes bp, so not one pulse reaches any ledger. Nothing about the
  # matching path is faked; the selftest reaps ONLY the children it started itself.
  printf '%s\n' task-aaa task-bbb > "$d/lane/held.txt"
  _row task-aaa lead-x "$(_ago 2)" in_progress
  _row task-bbb lead-x "$(_ago 2)" in_progress
  printf '%s ok task-aaa\n' "$(_ago 4)" > "$d/lane/pulse.log"
  echo "$ALIVE" > "$d/lane/pulse.pid"
  mkdir -p "$d/ghost"
  cat > "$d/ghost/pulse-loop.sh" <<'GHOSTLOOP'
#!/usr/bin/env bash
# Harmless stand-in for a pulse loop: the argv shape, none of the writes. It NEVER calls bp.
while :; do sleep 1; done
GHOSTLOOP
  chmod +x "$d/ghost/pulse-loop.sh"
  printf '%s\n' task-bbb > "$d/ghost/held.own.txt"    # same worker id as the lane -> OWN-ID
  printf '%s\n' task-bbb > "$d/ghost/held.peer.txt"   # a different worker id     -> PEER
  bash "$d/ghost/pulse-loop.sh" lead-x    "$d/ghost/held.own.txt"  "$d/ghost/pulse.own.log"  & local GH_OWN=$!
  bash "$d/ghost/pulse-loop.sh" lead-peer "$d/ghost/held.peer.txt" "$d/ghost/pulse.peer.log" & local GH_PEER=$!
  sleep 1   # give the kernel a moment to publish both argvs to ps

  echo "== arm 11a: two other processes pulse task-bbb -> NAMED, exit 1, OWN-ID and PEER differ"
  if _run "arm11a runs" 1 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _want "arm11a NAMES the own-id ghost pid"   1 "GHOST PULSER pid=$GH_OWN .*OWN-ID"
    _want "arm11a NAMES the peer loop pid"      1 "GHOST PULSER pid=$GH_PEER .*PEER"
    _want "arm11a names the own-id held file"   1 "GHOST PULSER pid=$GH_OWN .*held=.*held\.own\.txt"
    _want "arm11a names the peer held file"     1 "GHOST PULSER pid=$GH_PEER .*held=.*held\.peer\.txt"
    _want "arm11a names an overlapping row"     2 'GHOST PULSER .*overlap=task-bbb'
    _want "arm11a calls the own-id one stoppable"  1 'OWN-ID.*safe to STOP it'
    _want "arm11a forbids stopping the peer"       1 'PEER.*NEVER stop it'
    _want "arm11a printed the enumerated census"   1 '^ghost scan: [0-9]+ pulse-loop process'
    _want "arm11a did not call the run OK"         0 'liveness: OK'
  fi

  echo "== arm 11b: remove the overlap, SAME processes still running -> the same arm goes GREEN"
  : > "$d/ghost/held.own.txt"; : > "$d/ghost/held.peer.txt"
  if _run "arm11b runs" 0 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log"; then
    _last "arm11b verdict is OK"                'liveness: OK'
    _want "arm11b flags no ghost"             0 'GHOST PULSER'
    _want "arm11b still enumerated processes" 1 '^ghost scan: [0-9]+ pulse-loop process'
  fi

  echo "== arm 11c: NON-VACUITY — an enumerator that yields nothing REFUSES with its own code 4"
  if _run "arm11c runs" 4 -- "$d/lane" --expect-worker lead-x --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" --ps-cmd true; then
    _last "arm11c verdict is the refusal" 'liveness: GHOST SCAN REFUSED'
    _want "arm11c names the empty population" 1 'GHOST SCAN: CANNOT ENUMERATE'
    _want "arm11c never reports a clean scan"  0 '^ghost scan: '
    _want "arm11c never says OK"               0 'liveness: OK'
  fi
  # ══════════════════════════════════════════════════════════════════════════
  # arm 12 — THE COUNT IDENTITY (task-c767be8a820a9300)
  #
  # IDS[] is the liveness POPULATION: a loop that stops early hands every line
  # below a smaller, entirely green list, and the lane reads "liveness: OK — 1
  # row(s)" over a file holding three. These arms drive that truncation through
  # the loop's FALSIFIABILITY SEAM with two stubs ON PATH that differ by EXACTLY
  # ONE LINE — `cat > /dev/null` — so the only variable between red and green is
  # whether a child in that body reads fd 0. Arm 12c mutates the identity out and
  # shows the pre-fix behaviour: a clean OK over one of three.
  # ══════════════════════════════════════════════════════════════════════════
  echo "== arm 12: a stdin-reading child in the list loop shrinks the population — the count must see it"
  mkdir -p "$d/probe-a" "$d/probe-b"
  cat > "$d/probe-a/line-probe" <<'PROBEA'
#!/usr/bin/env bash
cat > /dev/null
exit 0
PROBEA
  # THE CONTROL: byte-identical minus the stdin read.
  sed -e '/^cat > \/dev\/null$/d' "$d/probe-a/line-probe" > "$d/probe-b/line-probe"
  chmod +x "$d/probe-a/line-probe" "$d/probe-b/line-probe"
  if [ "$(diff "$d/probe-a/line-probe" "$d/probe-b/line-probe" | grep -c '^< cat > /dev/null$')" = 1 ]; then
    echo "ok   arm12 stubs differ by exactly the stdin read"
  else
    echo "FAIL arm12 stubs differ by more than the stdin read"; fails=$((fails+1))
  fi
  # THREE rows, all green, so a 1-of-N refusal cannot be an off-by-one and the
  # control cannot be green for any reason other than reaching all of them.
  printf '%s\n' task-aaa task-bbb task-ccc > "$d/lane/held3.txt"
  _row task-aaa lead-x "$(_ago 2)" in_progress
  _row task-bbb lead-x "$(_ago 2)" in_progress
  _row task-ccc lead-x "$(_ago 2)" in_progress
  printf '%s ok task-aaa\n' "$(_ago 1)" > "$d/lane/pulse.log"
  echo "$ALIVE" > "$d/lane/pulse.pid"
  _id_run() { # _id_run <probe-dir> ; sets $out/$rc
    out=$(cd "$d" && PATH="$1:$d/bin:$PATH" STUB_DIR="$d" HELD_LIVENESS_LINE_PROBE=line-probe \
          bash "${2:-$SELF}" "$d/lane" --held "$d/lane/held3.txt" --expect-worker lead-x \
          --no-ghost-scan --pid-file "$d/lane/pulse.pid" --log "$d/lane/pulse.log" 2>&1); rc=$?
  }

  _id_run "$d/probe-a"
  if [ "$rc" = 2 ]; then echo "ok   arm12 stdin-reading child exits 2 (refusal)"
  else echo "FAIL arm12 exit $rc, wanted 2"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  _want "arm12 refusal names 1 of the 3"      1 'reached 1 of the 3 line\(s\)'
  _want "arm12 refusal names the mechanism"   1 'READS STDIN'
  _want "arm12 refusal forbids deleting it"   1 'deleting the count check'
  _want "arm12 never says OK"                 0 'liveness: OK'
  _want "arm12 prints no per-row verdict"     0 '^task-(aaa|bbb|ccc) .* ok$'

  echo "== arm 12b: THE CONTROL — same stub minus the stdin read reaches all three"
  _id_run "$d/probe-b"
  if [ "$rc" = 0 ]; then echo "ok   arm12b control exits 0"
  else echo "FAIL arm12b exit $rc, wanted 0"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  _last "arm12b verdict is OK"            'liveness: OK'
  _want "arm12b checked all three rows"   3 '^task-(aaa|bbb|ccc) .* ok$'
  _want "arm12b says 3 of the 3"          1 'all 3 of the 3 line\(s\)'

  echo "== arm 12c: MUTANT — the identity removed reports a clean OK over 1 of 3"
  # shellcheck disable=SC2016  # the $-names are THIS file's text to match, not ours to expand
  sed -e 's/^if \[ "\$LINES_REACHED" != "\$HELD_FED" \]; then$/if false; then/' "$SELF" > "$d/nocount.sh"
  if ! grep -q '^if false; then$' "$d/nocount.sh"; then
    echo "FAIL arm12c: the mutation did not apply — the identity guard was reworded"; fails=$((fails+1))
  else
    _id_run "$d/probe-a" "$d/nocount.sh"
    if [ "$rc" = 0 ]; then echo "ok   arm12c mutant exits 0 over 1 of 3"
    else echo "FAIL arm12c mutant exit $rc, wanted 0"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
    _want "arm12c mutant calls it OK"          1 'liveness: OK'
    _want "arm12c mutant checked ONE row"      1 '^task-(aaa|bbb|ccc) .* ok$'
  fi

  echo "== arm 13: the checkout-distance banner, against real git repos built here"
  # A REAL repo, not a fixture string: `git rev-list --count` is the thing under test, so
  # stubbing git would only prove this file can echo its own expectation.
  _g() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }
  _mkrepo() { # _mkrepo <dir> -> a repo whose refs/remotes/origin/main is 2 commits AHEAD of HEAD
    mkdir -p "$1"; git init -q "$1" >/dev/null 2>&1 || return 1
    git -C "$1" symbolic-ref HEAD refs/heads/main
    : > "$1/f"; _g "$1" add f >/dev/null 2>&1; _g "$1" commit -q -m A >/dev/null 2>&1
    CK_BASE=$(git -C "$1" rev-parse HEAD)
    echo b > "$1/f"; _g "$1" add f >/dev/null 2>&1; _g "$1" commit -q -m B >/dev/null 2>&1
    echo c > "$1/f"; _g "$1" add f >/dev/null 2>&1; _g "$1" commit -q -m C >/dev/null 2>&1
    CK_TIP=$(git -C "$1" rev-parse HEAD)
    git -C "$1" update-ref refs/remotes/origin/main "$CK_TIP"
    _g "$1" reset -q --hard "$CK_BASE" >/dev/null 2>&1
  }
  mkdir -p "$d/cks/plain"
  if ! _mkrepo "$d/cks/behind"; then
    echo "FAIL arm13: could not build a local git repo — the banner was NOT measured"; fails=$((fails+1))
  else
    # 13a: BEHIND. Same green lane as arm 1, so the ONLY new thing in the output is the banner.
    _run "arm13a runs over a behind checkout" 0 -- "$d/lane" --expect-worker lead-x \
         --no-ghost-scan --pid-file "$d/lane/pulse.pid" --checkout "$d/cks/behind"
    _want "arm13a fires CHECKOUT STALE"          2 '^CHECKOUT STALE:'
    _want "arm13a names the count"               1 'is 2 COMMIT\(S\) BEHIND'
    _want "arm13a says the number is a floor"    1 'NO FETCH WAS PERFORMED, so the real distance is 2 OR MORE'
    _want "arm13a states the failure mode"       1 'CONFIRMED ANSWER TO THE WRONG QUESTION'
    _want "arm13a hands over the ref recipe"     1 'fetch origin main && git -C .* show origin/main:'
    _want "arm13a never claims level"            0 'is LEVEL with'
    # 13d: THE EXIT CONTRACT, measured on the very run whose banner fired.
    _last "arm13d exit contract: still OK"       'liveness: OK'

    # 13b: THE CONTROL. Same repo, same invocation shape, ref moved onto HEAD. A banner that
    # always fires passes 13a; only this arm can tell that apart from a measurement.
    git -C "$d/cks/behind" update-ref refs/remotes/origin/main "$(git -C "$d/cks/behind" rev-parse HEAD)"
    _run "arm13b runs over a level checkout" 0 -- "$d/lane" --expect-worker lead-x \
         --no-ghost-scan --pid-file "$d/lane/pulse.pid" --checkout "$d/cks/behind"
    _want "arm13b is silent about staleness"     0 '^CHECKOUT STALE:'
    _want "arm13b reads level, zero behind"      1 'is LEVEL with the origin/main ref ON DISK — 0 commits behind'
    _last "arm13b exit contract: still OK"       'liveness: OK'

    # 13c: the two unmeasurable trees. Neither may render as a zero.
    _run "arm13c-i a non-repo dir" 0 -- "$d/lane" --expect-worker lead-x \
         --no-ghost-scan --pid-file "$d/lane/pulse.pid" --checkout "$d/rows"
    _want "arm13c-i says UNKNOWN"                1 '^CHECKOUT DISTANCE UNKNOWN:.*is not a git checkout'
    _want "arm13c-i says NOT a zero"             1 'This is a failed measurement, NOT a zero'
    _want "arm13c-i never renders a 0"           0 '0 commits behind'
    git init -q "$d/cks/plain" >/dev/null 2>&1
    _run "arm13c-ii a repo with no origin/main" 0 -- "$d/lane" --expect-worker lead-x \
         --no-ghost-scan --pid-file "$d/lane/pulse.pid" --checkout "$d/cks/plain"
    _want "arm13c-ii says UNKNOWN"               1 '^CHECKOUT DISTANCE UNKNOWN:.*no refs/remotes/origin/main'
    _want "arm13c-ii says NOT a zero"            1 'This is a failed measurement, NOT a zero'
    _want "arm13c-ii never renders a 0"          0 '0 commits behind'

    # 13e: the opt-out prints nothing at all.
    _run "arm13e --no-checkout-banner" 0 -- "$d/lane" --expect-worker lead-x \
         --no-ghost-scan --pid-file "$d/lane/pulse.pid" --no-checkout-banner --checkout "$d/cks/plain"
    _want "arm13e prints no banner line"         0 '^(CHECKOUT STALE|CHECKOUT DISTANCE UNKNOWN|checkout:)'
  fi

  # Reap ONLY this selftest's own children. The helper itself never signals any process.
  kill "$GH_OWN" "$GH_PEER" 2>/dev/null; wait "$GH_OWN" "$GH_PEER" 2>/dev/null

  rm -rf "$d"
  if [ "$fails" -gt 0 ]; then echo "held-liveness.sh selftest: $fails FAILED"; return 1; fi
  echo "held-liveness.sh selftest: all arms passed"; return 0
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ------------------------------------------------------------------ ARGUMENTS ----------------
EXPECT=""; PIDFILE=""; PULSELOG=""; WARN=15; INTERVAL=18; LEASE=45; BP="bp"; GRACE=3
CHECKOUT_BANNER=1; CHECKOUT_DIR=""; GIT_CMD="git"
LANE=""; HELDARG=""; SESSION=""
GHOSTSCAN=1; PS_CMD="ps -axww -o pid=,args="
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
    --no-ghost-scan)  GHOSTSCAN=0; shift;;
    --ps-cmd)         PS_CMD="${2:-}"; shift 2;;
    --checkout)       CHECKOUT_DIR="${2:-}"; shift 2;;
    --no-checkout-banner) CHECKOUT_BANNER=0; shift;;
    --git-cmd)        GIT_CMD="${2:-}"; shift 2;;
    -h|--help)        sed -n '2,135p' "$SELF"; exit 0;;
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
# FIRST LINE OF EVERY RUN. Printed before the held list is even resolved, so that the exit-2
# refusals below ("NO LIST", "EMPTY LIST") carry it too — a lead whose lane dir looks wrong is
# exactly a lead who may be reading a months-old tree. Advisory: it cannot change the exit code.
checkout_distance_banner

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

# ── THE COUNT IDENTITY (task-c767be8a820a9300) ───────────────────────────────
# IDS[] IS THE LIVENESS POPULATION. Everything below — every per-row verdict,
# the ghost scan's overlap, "liveness: OK — N row(s) checked" — is computed over
# whatever this one loop puts in it. A loop that stops early does not report a
# problem; it reports a SMALLER, ENTIRELY GREEN population, and the lane reads
# "OK" over rows nobody looked at. This is the instrument leads quote in their
# status files, so a silent shrink here is a silent shrink of the whole lane's
# evidence.
#
# The way it comes apart: this loop is fed by a FILE on fd 0, and any CHILD in
# its body inherits fd 0. One stdin read in such a child swallows the rest of
# the list and the loop ends AT EXIT 0 after one row. As written today no child
# in this body reads fd 0 (the trim's `tr`/`sed` are fed by a pipe), so the
# defect here is LATENT — which is exactly why the guard is a count and not fd
# discipline: fd discipline is a property of every child this body will ever
# gain, which nothing can hold, while the identity notices no matter WHY the
# loop came up short. Nothing is redirected to </dev/null here: there is no
# child to redirect, and adding one later must red this check, not be pre-
# silenced by it.
#
# HELD_FED is the number of lines the file HANDED IN, counted outside the loop
# from the same file. awk counts a final unterminated line as a record, which
# matches this loop's `|| [ -n "$_line" ]` clause; the two readers have to agree
# on what a line is or the identity is noise.
HELD_FED=$(awk 'END{print NR}' "$HELDFILE"); [ -n "$HELD_FED" ] || HELD_FED=0
# FALSIFIABILITY SEAM, and nothing else. A guard nothing can trip is
# indistinguishable from a comment, and the loop below has no fd-0-inheriting
# child to stub — so the selftest supplies one HERE, at exactly the position
# and with exactly the fd inheritance a future child would have. Empty in every
# real run (an unset variable is a no-op), set only by the identity arms of
# --selftest. It is not a hook for callers and nothing else reads it.
HELD_LINE_PROBE="${HELD_LIVENESS_LINE_PROBE:-}"
IDS=()
LINES_REACHED=0
while IFS= read -r _line || [ -n "$_line" ]; do
  # COUNTED FIRST, before any skip: a line is "reached" once this loop has read
  # it, blank and comment lines included — HELD_FED counts those too.
  LINES_REACHED=$((LINES_REACHED+1))
  [ -n "$HELD_LINE_PROBE" ] && "$HELD_LINE_PROBE" >/dev/null 2>&1
  _line="${_line%%#*}"
  # trim surrounding whitespace without leaning on the caller's shell
  _line="$(printf '%s' "$_line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$_line" ] && IDS+=("$_line")
done < "$HELDFILE"

# THE IDENTITY, CHECKED BEFORE ANY VERDICT — before the empty-list refusal too.
# A loop that stopped early did not only miss rows, it also built the population
# every later line is measured against, so even its refusals would be claims
# over work it never did. Both numbers are in the sentence: "the loop is broken"
# is unactionable, "reached 1 of the 9 rows your list holds" is not.
if [ "$LINES_REACHED" != "$HELD_FED" ]; then
  say "liveness: REFUSING — the held-list loop reached $LINES_REACHED of the $HELD_FED line(s) $HELDFILE handed it, so the liveness population is SHORT by $((HELD_FED - LINES_REACHED)) and every verdict below would be an OK over rows that were never read. It is NOT a finding about your claims — it is this instrument failing to do its own work, and the near-certain cause is that something in that loop body now READS STDIN: the list is on fd 0 and any child inherits fd 0, so one stdin read swallows the remaining lines and the loop ends after $LINES_REACHED iteration(s) at exit 0. Find the new stdin reader and give it its own input (for example '</dev/null'), then re-run. Do NOT satisfy this by deleting the count check: the count is the only thing that can see this at all."
  exit 2
fi

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

# --- GHOST SCAN: is any OTHER process pulsing the rows on MY list? ---------------------------
# Everything above answers "is MY loop alive and are MY rows held". None of it can see a SECOND
# pulser, and a second pulser is invisible by construction: it advances the same rows' claim
# epochs correctly, so the ledger looks healthy while every epoch you read goes stale under you.
# REPORTS ONLY — this helper never signals, kills or touches any process.
GHOST_ENUM_FAIL=0

# ghost_argv_fields <argv tokens...> -> "<worker>\t<held-file>" on stdout, rc 1 when the argv is
# not a pulse-loop invocation. Deliberately NOT a name match: the token must be the SCRIPT of the
# command line (argv[0], or straight after an interpreter), so a `grep pulse-loop.sh` — whose
# script is grep — can never match, and pulse-loop.sh's own flags are consumed the way it parses
# them (`pulse-loop.sh [--once] [--interval N] [--passes N] <worker> <held-file> <log>`).
ghost_argv_fields() {
  local -a A=("$@"); local i b prev idx=-1 w="" h=""
  for ((i=0; i<${#A[@]}; i++)); do
    b="${A[$i]##*/}"
    [ "$b" = "pulse-loop.sh" ] || continue
    if [ "$i" -eq 0 ]; then idx=$i; break; fi
    prev="${A[$((i-1))]##*/}"
    case "$prev" in bash|sh|zsh|dash|ksh|nohup|env|setsid|time) idx=$i; break;; esac
  done
  [ "$idx" -ge 0 ] || return 1
  i=$((idx+1))
  while [ "$i" -lt "${#A[@]}" ]; do
    case "${A[$i]}" in
      --interval|--passes) i=$((i+2)); continue;;
      --*)                 i=$((i+1)); continue;;
    esac
    if [ -z "$w" ]; then w="${A[$i]}"; else h="${A[$i]}"; break; fi
    i=$((i+1))
  done
  [ -n "$w" ] && [ -n "$h" ] || return 1     # an argv with no held file is not a pulser we can judge
  printf '%s\t%s' "$w" "$h"
}

if [ "$GHOSTSCAN" = 1 ]; then
  if [ -z "$PIDFILE" ]; then
    say "GHOST SCAN: NOT RUN — no --pid-file, so no pid is known to be YOURS and every loop on the box would read as foreign. This is NOT 'no ghost found'."
  else
    OWNPID=$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)
    PROCS=$(eval "$PS_CMD" 2>/dev/null) || PROCS=""
    GTOTAL=0; GOTHER=0; GOVER=0
    set -f   # a process argv may contain * or ? — word-split it, never glob it
    while IFS= read -r _pline; do
      [ -n "$_pline" ] || continue
      # shellcheck disable=SC2086  # word-splitting the argv is the point; `set -f` above kills globbing
      set -- $_pline
      gpid="$1"; shift
      case "$gpid" in ''|*[!0-9]*) continue;; esac
      [ "$gpid" = "$$" ] && continue                       # never report this scanner as a ghost
      gfields=$(ghost_argv_fields "$@") || continue        # matched on the ARGV, not on a name
      GTOTAL=$((GTOTAL+1))
      [ -n "$OWNPID" ] && [ "$gpid" = "$OWNPID" ] && continue
      GOTHER=$((GOTHER+1))
      gw="${gfields%%$'\t'*}"; gh="${gfields#*$'\t'}"
      if [ ! -r "$gh" ]; then
        say "GHOST PULSER pid=$gpid worker=$gw held=$gh UNREADABLE — its list cannot be read, so its overlap with yours is UNKNOWN, not empty. Do not treat this as clear."
        PROBLEMS=$((PROBLEMS+1)); continue
      fi
      govn=0; gfirst=""; gextra=0
      while IFS= read -r _r || [ -n "$_r" ]; do
        _r="${_r%%#*}"
        _r="$(printf '%s' "$_r" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$_r" ] || continue
        _hit=0
        for _mine in "${IDS[@]}"; do [ "$_r" = "$_mine" ] && { _hit=1; break; }; done
        if [ "$_hit" = 1 ]; then govn=$((govn+1)); [ -n "$gfirst" ] || gfirst="$_r"
        else gextra=$((gextra+1)); fi
      done < "$gh"
      [ "$govn" -gt 0 ] || continue
      GOVER=$((GOVER+1)); PROBLEMS=$((PROBLEMS+1))
      ghead="GHOST PULSER pid=$gpid worker=$gw held=$gh overlap=$gfirst rows-overlapping=$govn"
      if [ -n "$EXPECT" ] && [ "$gw" != "$EXPECT" ]; then
        say "$ghead PEER — this loop carries ANOTHER worker's id. NEVER stop it: it may be the only thing keeping that peer's claims alive. Message its lane; until then re-read every epoch immediately before each stamp and close."
      elif [ "$gextra" -gt 0 ]; then
        say "$ghead OWN-ID, NOT CLEAN — it pulses your worker id but also $gextra row(s) that are NOT on your list. Do NOT stop it until those rows are accounted for; re-read every epoch immediately before each stamp and close."
      else
        say "$ghead OWN-ID — it pulses your own worker id and nothing but your own rows, so it is safe to STOP it (a human or the lead decides; this helper never signals anything). Until then every epoch you read can be stale before you use it."
      fi
    done <<GHOSTPS
$PROCS
GHOSTPS
    set +f
    if [ "$GTOTAL" -eq 0 ]; then
      say "GHOST SCAN: CANNOT ENUMERATE — '$PS_CMD' listed no pulse-loop process at all, not even your own. Nothing was compared against your list, so this is NOT a no-ghost verdict."
      GHOST_ENUM_FAIL=1
    else
      say "ghost scan: $GTOTAL pulse-loop process(es) enumerated, $GOTHER not pid ${OWNPID:-?}, $GOVER pulsing a row on $HELDFILE."
    fi
  fi
fi

[ "$CLOSED" -gt 0 ] && say "TRIM: $CLOSED closed row(s) are still listed in $HELDFILE."
if [ "$REFUSALS" -gt 0 ]; then
  say "liveness: CANNOT READ — $REFUSALS of ${#IDS[@]} row(s) could not be read from the ledger. Nothing here proves your claims survive; re-run before you rely on it."
  exit 3
fi
if [ "$GHOST_ENUM_FAIL" = 1 ]; then
  say "liveness: GHOST SCAN REFUSED — the pulse-loop process population could not be read, so 'no other process is pulsing your rows' was never established. This is a failed read, not a zero."
  exit 4
fi
if [ "$PROBLEMS" -gt 0 ]; then
  say "liveness: $PROBLEMS PROBLEM(S) — see the named lines above."
  exit 1
fi
say "liveness: OK — ${#IDS[@]} row(s) checked (all $LINES_REACHED of the $HELD_FED line(s) $HELDFILE handed in were read), $((${#IDS[@]} - CLOSED)) held by ${EXPECT:-<any worker>}, min lease ${MINLEFT:-n/a} min."
exit 0
