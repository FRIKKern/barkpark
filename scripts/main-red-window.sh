#!/usr/bin/env bash
# main-red-window.sh — HAS MAIN BEEN CLEAN FOR 24 HOURS? A LEDGER, NOT A MEMORY.
#
# WHY THIS EXISTS. task-0a48c7b64d5ab0f1 c0 asks for something no single command
# can answer: "no workflow has been red on its newest completed run for more than
# 2 hours, MEASURED OVER 24 H". scripts/main-red-predicate.sh answers the instant
# question — what is red RIGHT NOW, and for how long. It cannot answer the 24-hour
# one, because a point reading says nothing about the 23 hours you did not look.
# Every previous attempt on c0 substituted the instant reading for the window and
# was wrong in the same way: a green snapshot is not a clean day.
#
# SO THIS FILE IS TWO HALVES:
#   --record   run the predicate once, append ONE row to a JSONL ledger.
#   --verdict  read the ledger and say whether a clean 24 h has actually been
#              OBSERVED — which is a different and much stronger claim.
#
# THE CONTROL THAT MAKES IT MEAN ANYTHING: COVERAGE. A ledger holding two rows
# 24 hours apart, both TRUE, is NOT a clean day — it is two minutes of evidence
# and 23h58m of silence, and a workflow can go red and be fixed inside that gap
# without leaving a trace. So the verdict refuses unless the window is
# CONTIGUOUSLY covered: no gap longer than MAX_GAP between consecutive polls.
# An absence of red observations is not an observation of no red. This is the
# single most likely way for c0 to be falsely stamped met, so it fails closed.
#
# THE OTHER FAIL-CLOSED DIRECTION: a poll that could not read (2H PREDICATE:
# CANNOT READ) is NOT a pass. A workflow whose verdict is unreadable has no
# measurable age, so it cannot have satisfied "not red for more than 2 hours".
# It breaks the window exactly as a red does.
#
# EXIT CODES. 0 = a clean 24 h window has been OBSERVED. 1 = the window is
# covered and something in it was RED. 3 = the window is covered, nothing in it
# was red, and one or more polls were UNREADABLE. 2 = NOT YET MEASURED (too
# short, holed, or not certifying the present). 4 = the ledger itself could not
# be read. ONLY 0 IS A PASS, and none of 1, 2, 3 may ever be reported as one.
#
# WHY 1 AND 3 ARE SEPARATE CODES. The predicate is deliberately THREE-VALUED --
# TRUE, FALSE, CANNOT READ -- and each row here stores which of the three it
# saw. A verdict that collapses FALSE and CANNOT READ into one exit throws that
# away at the very last step, and the two want OPPOSITE remedies: a RED window
# is main's problem and someone must fix a workflow; an UNREADABLE window is the
# INSTRUMENT's problem and staring at main will never clear it. The stale-page
# fault scripts/main-red-predicate.sh was hardened against on 2026-09-17 lands
# in this bucket -- a stale feed yields CANNOT READ -- and reporting it as a red
# day would send the next reader hunting a workflow that was never broken.
#
# PERSISTENCE. The ledger has to outlive the runner or none of this can ever
# reach 24 h; the mechanism, and why the other two candidates were refused, is
# recorded beside the code in .github/workflows/main-red-owner.yml.
set -uo pipefail

WINDOW_S=${MRW_WINDOW_S:-86400}   # 24 h
MAX_GAP_S=${MRW_MAX_GAP_S:-7200}  # 2 h — the same bound c0 puts on a red
# RETENTION, and it is deliberately TWICE the window rather than equal to it.
# The ledger is carried between runs in a store with a size budget and gains a
# row every hour forever, so it must be pruned. But the coverage control needs
# an ANCHOR row at or BEFORE now-WINDOW: pruning to exactly WINDOW would delete
# that row on every single run, and the prune would quietly BECOME the coverage
# hole it is surrounded by controls to detect. At 2x there is a full extra
# window of anchor margin, and the arms below test the prune in both directions
# (ancient rows go / the anchor survives).
RETAIN_S=${MRW_RETAIN_S:-$((WINDOW_S * 2))}
LEDGER_DEFAULT="tooling/grip/ledger/main-red-window.jsonl"

_self="${BASH_SOURCE[0]}"; case "$_self" in */*) _dir="${_self%/*}";; *) _dir=".";; esac
_dir=$(cd "$_dir" 2>/dev/null && pwd) || _dir="."
_self="$_dir/${_self##*/}"

usage() {
  cat <<'U'
usage:
  main-red-window.sh --record  [ledger] [repo]   run the predicate, append one row
  main-red-window.sh --verdict [ledger]          has a clean 24 h been OBSERVED?
  main-red-window.sh --prune   [ledger]          drop rows older than retention
  main-red-window.sh --selftest                  hermetic arms, no network
U
}

# ── RECORD ──────────────────────────────────────────────────────────────────
# One row per poll. The row carries the predicate's own verdict line VERBATIM,
# not a re-derivation of it: a ledger that paraphrases its instrument cannot be
# audited against the instrument.
do_record() {
  local ledger="${1:-$LEDGER_DEFAULT}" repo="${2:-}" out rc now line verdict
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "poll $now — running the predicate..."
  out=$(bash "$_dir/main-red-predicate.sh" ${repo:+"$repo"} 2>&1); rc=$?
  line=$(printf '%s\n' "$out" | grep -m1 '^2H PREDICATE:' || true)
  if [ -z "$line" ]; then
    # THE INSTRUMENT DID NOT SPEAK. Record that, loudly, as a non-pass. An
    # unparseable run must never vanish from the ledger — a missing row is
    # indistinguishable from a poll that never happened, and the coverage
    # control would then read the hole as "the watcher was down".
    verdict="CANNOT READ"
    line="2H PREDICATE: CANNOT READ -- the predicate emitted no verdict line (exit $rc)"
  else
    case "$line" in
      *"FALSE"*)       verdict="FALSE";;
      *"CANNOT READ"*) verdict="CANNOT READ";;
      *"TRUE"*)        verdict="TRUE";;
      *)               verdict="CANNOT READ";;
    esac
  fi
  local reds
  reds=$(printf '%s\n' "$out" | awk '/^RED ON MAIN \(/{f=1;next} /^$/{f=0} f' \
         | sed 's/^ *//' | awk -F'\t' 'NF>3{print $4}' | awk '{print $1}' | paste -sd, - )
  mkdir -p "$(dirname "$ledger")" 2>/dev/null
  jq -nc --arg at "$now" --arg v "$verdict" --arg l "$line" --arg r "${reds:-}" --argjson rc "$rc" \
     '{at:$at, verdict:$v, line:$l, reds:(if $r=="" then [] else ($r|split(",")) end), predicate_exit:$rc}' \
     >> "$ledger" || { echo "TERMINAL: could not append to $ledger"; return 4; }
  echo "recorded: $verdict  ($line)"
  do_prune "$ledger"
  echo "TERMINAL: recorded one poll at $now into $ledger"
  [ "$verdict" = TRUE ] && return 0
  return 1
}

# ── PRUNE ───────────────────────────────────────────────────────────────────
# FAILS SAFE BY DOING NOTHING. Every failure path here leaves the ledger exactly
# as it found it: an unparseable ledger, a jq that dies, or a rewrite that would
# empty the file are all reasons to keep what we have. A prune that can destroy
# the ledger is a worse fault than a ledger that grows, because the coverage
# control reads a destroyed ledger as a hole and the window becomes unreachable.
do_prune() {
  local ledger="${1:-$LEDGER_DEFAULT}" tmp kept before after
  [ -f "$ledger" ] || { echo "prune: no ledger at $ledger — nothing to do"; return 0; }
  before=$(wc -l < "$ledger" | tr -d ' ')
  tmp="$ledger.prune.$$"
  if ! jq -s -c --argjson r "$RETAIN_S" \
        '[ .[] | select((.at|fromdateiso8601) > (now - $r)) ] | sort_by(.at) | .[]' \
        "$ledger" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; echo "prune: SKIPPED — $ledger did not reduce cleanly; keeping all $before row(s)"; return 0
  fi
  after=$(wc -l < "$tmp" | tr -d ' ')
  if [ "${after:-0}" -eq 0 ]; then
    rm -f "$tmp"; echo "prune: SKIPPED — the rewrite would have emptied the ledger; keeping all $before row(s)"; return 0
  fi
  mv "$tmp" "$ledger" || { rm -f "$tmp"; echo "prune: SKIPPED — could not replace $ledger"; return 0; }
  echo "prune: kept $after of $before row(s) newer than ${RETAIN_S}s"
  return 0
}

# ── VERDICT ─────────────────────────────────────────────────────────────────
do_verdict() {
  local ledger="${1:-$LEDGER_DEFAULT}"
  [ -f "$ledger" ] || { echo "CANNOT READ: no ledger at $ledger"; echo "TERMINAL: exit 4"; return 4; }
  # VALIDATE BEFORE COUNTING. A ledger of garbage must refuse as UNREADABLE, not
  # be counted as a short window — "too few polls" and "I cannot parse this" are
  # different facts and only one of them is fixed by waiting.
  if ! jq -e . "$ledger" >/dev/null 2>&1; then
    echo "CANNOT READ: $ledger is not valid JSONL"; echo "TERMINAL: exit 4"; return 4
  fi
  # ── COVERAGE IS AN EDGE PROBLEM, NOT A SPAN PROBLEM ───────────────────────
  # The first draft asked whether the rows INSIDE the window span 24 h. They
  # never can: rows inside a 24-hour window are at most 24 hours apart, and with
  # any discrete poll interval they are strictly less — so a perfect ledger
  # failed its own test by one poll interval. The question is not how far the
  # rows reach, it is whether the WINDOW is covered, which has three parts:
  #   1. the ledger REACHES BACK past the window start (an ANCHOR row at or
  #      before now-24h), so the start edge is observed and not merely assumed;
  #   2. the newest row is no older than MAX_GAP, so the end edge is live — a
  #      watcher that died an hour ago must not still be certifying the present;
  #   3. no gap between consecutive rows exceeds MAX_GAP.
  # The anchor row is deliberately INCLUDED in the gap walk. Without it the
  # first in-window row has nothing behind it, and a ledger that began 23 hours
  # into the window would show no gap at all.
  local report
  report=$(jq -s -r --argjson w "$WINDOW_S" --argjson g "$MAX_GAP_S" '
    def ts: .at|fromdateiso8601;
    (now) as $now | ($now - $w) as $start
    | (sort_by(ts)) as $all
    | ([$all[]|select(ts <= $start)] | last) as $anchor
    | ([$all[]|select(ts > $start)]) as $inw
    | if $anchor == null then
        "NOANCHOR\t\($inw|length)\t\((if ($all|length)>0 then (($all[0]|ts) - $start)|floor else 0 end))\t0\t0\t0\t"
      elif ($inw|length) == 0 then "STALE\t0\t0\t\(($now - ($anchor|ts))|floor)\t0\t0\t"
      else
        ([$anchor] + $inw) as $rows
        | ([ range(1; $rows|length) | ($rows[.]|ts) - ($rows[.-1]|ts) ]) as $gaps
        | (($gaps|max) // 0) as $maxgap
        | ($now - ($rows[-1]|ts)) as $tail
        # THREE-VALUED, NOT TWO. Split the non-TRUE polls by WHICH non-TRUE
        # they were. Anything that is neither TRUE nor FALSE is unreadable --
        # stated as a catch-all rather than a list of spellings, because a
        # future verdict word this file has never heard of must land in the
        # fail-closed bucket, not slip past an enumeration into "clean".
        | ([$inw[]|select(.verdict == "FALSE")]) as $red
        | ([$inw[]|select(.verdict != "TRUE" and .verdict != "FALSE")]) as $unread
        | ($red + $unread | sort_by(.at)) as $bad
        | "OK\t\($inw|length)\t\($maxgap|floor)\t\($tail|floor)\t\($red|length)\t\($unread|length)\t\([$bad[]|.at+"="+.verdict]|join(" "))"
      end' "$ledger" 2>/dev/null)
  [ -n "$report" ] || { echo "CANNOT READ: $ledger could not be reduced to a window report"; echo "TERMINAL: exit 4"; return 4; }
  local kind rows maxgap tail nred nunread badlist
  IFS=$'\t' read -r kind rows maxgap tail nred nunread badlist <<<"$report"
  echo "window=${WINDOW_S}s max_gap=${MAX_GAP_S}s ledger=$ledger"
  case "$kind" in
    NOANCHOR)
      echo "polls in window=$rows — but the ledger does not reach back past the window start (earliest row is ${maxgap}s INSIDE it)"
      echo "NOT YET MEASURED: no anchor poll at or before now-${WINDOW_S}s; the start of the window was never observed"
      echo "TERMINAL: exit 2"; return 2;;
    STALE)
      echo "polls in window=0 — newest poll is ${tail}s old"
      echo "NOT YET MEASURED: the watcher has not polled inside the window at all"
      echo "TERMINAL: exit 2"; return 2;;
  esac
  echo "polls in window=$rows largest gap=${maxgap}s age of newest poll=${tail}s red=${nred} unreadable=${nunread}"
  # COVERAGE IS ADJUDICATED BEFORE CONTENT. A holed ledger whose every present
  # row says TRUE is not a clean window, it is an unmeasured one — and calling
  # it red would be as wrong as calling it green.
  if [ "$maxgap" -gt "$MAX_GAP_S" ]; then
    echo "NOT YET MEASURED: a ${maxgap}s gap exceeds the ${MAX_GAP_S}s coverage bound — a workflow could have gone red and been fixed unseen inside it"
    echo "TERMINAL: exit 2"; return 2
  fi
  if [ "$tail" -gt "$MAX_GAP_S" ]; then
    echo "NOT YET MEASURED: the newest poll is ${tail}s old, beyond the ${MAX_GAP_S}s bound — this ledger is not certifying the present"
    echo "TERMINAL: exit 2"; return 2
  fi
  # RED OUTRANKS UNREADABLE. A window holding both is reported as the red one:
  # a confirmed red is the stronger and more actionable fact, and burying it
  # under "the instrument blinked" is how a real red goes unowned.
  if [ "${nred:-0}" -gt 0 ]; then
    echo "WINDOW NOT CLEAN: ${nred} RED poll(s) and ${nunread} unreadable: $badlist"
    echo "TERMINAL: exit 1"; return 1
  fi
  # NOTHING WAS RED AND THE INSTRUMENT COULD NOT ALWAYS SEE. This is NOT a clean
  # day and it is NOT a dirty one. A day with a blind spot in it is a day nobody
  # measured, and the fix is to the reader, not to main.
  if [ "${nunread:-0}" -gt 0 ]; then
    echo "WINDOW UNMEASURABLE: 0 red, but ${nunread} poll(s) the instrument could not read: $badlist"
    echo "an unreadable poll has no measurable red-age, so it cannot have satisfied the 2 h bound — and it is not evidence of a red either"
    echo "TERMINAL: exit 3"; return 3
  fi
  echo "CLEAN 24H OBSERVED: $rows contiguous polls inside the window, largest gap ${maxgap}s, newest ${tail}s old, every poll TRUE"
  echo "TERMINAL: exit 0"; return 0
}

# ── SELFTEST ────────────────────────────────────────────────────────────────
# Hermetic: synthetic ledgers only, no predicate, no network. Every arm is a
# PAIR — the same ledger shape with one property moved — because an arm that
# only ever sees one answer cannot tell a working rule from a hard-wired one.
_selftest() {
  local d pass=0 fails=0 out rc
  _ok(){ printf 'PASS %-38s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-38s %s\n' "$1" "${2:-}"; fails=$((fails+1)); }
  bash -n "$_self" 2>/dev/null && _ok "parses" "bash -n clean" || _no "parses" "malformed"
  command -v jq >/dev/null 2>&1 && _ok "dep jq" "$(command -v jq)" || _no "dep jq" "NOT ON PATH"
  d=$(mktemp -d) || { echo "SELFTEST: CANNOT READ — no tmpdir"; return 1; }

  # gen <file> <span_hours> <step_minutes> <verdict-of-row-k...>  (k=0 is OLDEST)
  # gen emits rows from (now - spanh hours) up to now. A ledger meant to PASS
  # must span MORE than 24 h, because the verdict requires an anchor poll at or
  # before the window start — that requirement is itself under test below.
  gen(){ local f="$1" spanh="$2" stepm="$3"; shift 3
    : > "$f"
    local total=$(( spanh*60 / stepm )) i v
    for i in $(seq 0 "$total"); do
      v=TRUE
      for spec in "$@"; do case "$spec" in "$i:"*) v="${spec#*:}";; esac; done
      jq -nc --arg at "$(jq -nr --argjson o "$(( (total-i)*stepm*60 ))" 'now - $o | todateiso8601')" \
             --arg v "$v" '{at:$at,verdict:$v,line:"synthetic",reds:[],predicate_exit:0}' >> "$f"
    done; }

  _run(){ local lbl="$1" f="$2" want="$3" need="$4"
    out=$(bash "$_self" --verdict "$f" 2>&1); rc=$?
    if [ "$rc" != "$want" ]; then _no "$lbl" "exit=$rc want=$want | $(printf '%s\n' "$out"|tail -2|sed -n '1p')"; return; fi
    case "$out" in *"$need"*) _ok "$lbl" "$(printf '%s\n' "$out"|grep -m1 -E 'CLEAN|NOT YET|NOT CLEAN|UNMEASURABLE|CANNOT READ')";;
      *) _no "$lbl" "output lacks [$need]";; esac; }

  # THE PASS. 24 h of TRUE polls at 30-minute spacing.
  gen "$d/clean" 25 30;            _run "a covered clean day passes" "$d/clean" 0 "CLEAN 24H OBSERVED"
  # ...and the SAME shape with ONE red poll must not. Without this pair, a rule
  # hard-wired to exit 0 passes the arm above.
  gen "$d/onered" 25 30 "40:FALSE"; _run "one FALSE poll breaks the window" "$d/onered" 1 "WINDOW NOT CLEAN"
  # AN UNREADABLE POLL IS NOT A PASS -- AND IT IS NOT A RED EITHER. Same shape
  # again, verdict CANNOT READ. It must land in its OWN bucket (exit 3), because
  # the stale-feed fault the predicate was hardened against on 2026-09-17 arrives
  # here as exactly this row, and filing it as "main was red" sends the next
  # reader to debug a workflow that never broke.
  gen "$d/unread" 25 30 "40:CANNOT READ"; _run "one CANNOT READ is UNMEASURABLE not red" "$d/unread" 3 "WINDOW UNMEASURABLE"
  # ...and the PAIR that keeps the split honest in the other direction: a window
  # holding BOTH is reported as the red one. Without this arm, "everything
  # non-TRUE is unmeasurable" would pass the arm above and silently downgrade
  # every real red on main into an instrument complaint.
  gen "$d/mixed" 25 30 "40:CANNOT READ" "41:FALSE"
  _run "a real red outranks an unreadable poll" "$d/mixed" 1 "WINDOW NOT CLEAN"
  # A verdict word this file has never heard of is UNREADABLE, never clean. The
  # bucket is a catch-all, not an enumeration, and this proves it: an
  # enumeration is a snapshot, a predicate is a rule.
  gen "$d/novel" 25 30 "40:SOMETHING NEW"
  _run "an unrecognised verdict word is not clean" "$d/novel" 3 "WINDOW UNMEASURABLE"
  # TOO SHORT IS NOT GREEN. 12 h of flawless polls must read NOT YET MEASURED,
  # never CLEAN — this is the exact substitution that keeps mis-stamping c0.
  gen "$d/short" 12 30;            _run "half a day is NOT YET MEASURED" "$d/short" 2 "NOT YET MEASURED"
  # THE COVERAGE CONTROL, and it is the point of the file. A ledger spanning a
  # full 24 h whose polls are 4 HOURS apart is all-TRUE and still proves nothing.
  gen "$d/holed" 25 240;           _run "a holed day is NOT YET MEASURED" "$d/holed" 2 "exceeds"
  # ...and the QUIET control: 90-minute spacing is inside the 2 h bound and must
  # stay green, or "reject anything sparse" would pass the arm above and reject
  # every real ledger.
  gen "$d/sparse" 25 90;           _run "90-minute spacing still passes" "$d/sparse" 0 "CLEAN 24H OBSERVED"
  # THE ANCHOR ARM. 23 h of flawless 30-minute polls covers almost the whole
  # window and must STILL refuse: the first hour was never observed, and "I saw
  # nothing red in the 23 hours I was watching" is not "nothing was red today".
  # Paired with the 25 h clean arm above, which differs only in reaching back.
  gen "$d/noanchor" 23 30;          _run "a ledger starting inside the window refuses" "$d/noanchor" 2 "no anchor poll"
  # THE END EDGE. 25 h of polls that STOPPED 3 hours ago is fully covered at the
  # start and still must refuse — a dead watcher must not keep certifying the
  # present off yesterday's rows.
  gen "$d/dead" 25 30; jq -sc --argjson c 6 '.[0:(length-$c)][]' "$d/dead" > "$d/dead2" 2>/dev/null \
    && mv "$d/dead2" "$d/dead"
  _run "a watcher that stopped 3 h ago refuses" "$d/dead" 2 "not certifying the present"
  # ── THE RATCHET'S SECOND DIRECTION ────────────────────────────────────────
  # A ratchet has TWO ways to be wrong, and only one of them gets tested: it
  # must also LET GO when the world gets better. 30 h of polls whose oldest six
  # hours were FALSE and whose last 24 h are all TRUE is a day main RECOVERED
  # in, and the window must read CLEAN -- those reds are OUTSIDE it. If they
  # kept dirtying the window, a single bad afternoon would make a clean day
  # unreachable until it aged out of the RETENTION horizon rather than the
  # WINDOW, and c0 could never be stamped. Paired with the one-red arm above,
  # which is the same rule with the red moved INSIDE the window.
  gen "$d/recovered" 30 30 "0:FALSE" "3:FALSE" "7:FALSE" "10:FALSE"
  _run "reds that aged OUT of the window let go" "$d/recovered" 0 "CLEAN 24H OBSERVED"

  # ── WHAT A STORE MISS LOOKS LIKE ──────────────────────────────────────────
  # The persistence store can lose the ledger, SILENTLY -- that is the stated
  # residual of the mechanism chosen in main-red-owner.yml. Neither shape a loss
  # can take may ever read as a clean day.
  #   (a) a TOTAL loss: the ledger restarts and only reaches back a few hours.
  #       That is the anchor arm above, and it refuses.
  #   (b) a PARTIAL loss: the store served an old entry for a while, leaving a
  #       hole in the MIDDLE of an otherwise well-covered window.
  gen "$d/evicted" 30 30
  awk 'NR<25 || NR>40' "$d/evicted" > "$d/evicted2" && mv "$d/evicted2" "$d/evicted"
  _run "a store outage punched mid-window refuses" "$d/evicted" 2 "exceeds"

  # ── THE PRUNE, IN BOTH DIRECTIONS ─────────────────────────────────────────
  # It must actually drop ancient rows (or the blob grows forever) AND it must
  # never eat the anchor (or the prune silently becomes the coverage hole). One
  # arm each; a prune tested only for "it shrank the file" would pass while
  # deleting everything.
  local b4 af
  gen "$d/long" 100 60
  b4=$(wc -l < "$d/long" | tr -d ' ')
  bash "$_self" --prune "$d/long" >/dev/null 2>&1
  af=$(wc -l < "$d/long" | tr -d ' ')
  if [ "${af:-0}" -lt "${b4:-0}" ] && [ "${af:-0}" -gt 0 ]; then
    _ok "prune drops rows past retention" "$b4 -> $af row(s)"
  else _no "prune drops rows past retention" "$b4 -> $af"; fi
  _run "a pruned ledger STILL has its anchor" "$d/long" 0 "CLEAN 24H OBSERVED"
  # THE QUIET CONTROL: a ledger entirely inside retention must come back whole.
  # Without it, "prune = truncate" passes the arm above.
  gen "$d/young" 25 30
  b4=$(wc -l < "$d/young" | tr -d ' ')
  bash "$_self" --prune "$d/young" >/dev/null 2>&1
  af=$(wc -l < "$d/young" | tr -d ' ')
  [ "$af" = "$b4" ] && _ok "prune keeps a young ledger whole" "$b4 row(s) kept" \
    || _no "prune keeps a young ledger whole" "$b4 -> $af"
  # AND IT MUST NOT DESTROY WHAT IT CANNOT PARSE. A junk ledger stays junk --
  # refusing to read is recoverable, deleting the evidence is not.
  printf 'not json\n' > "$d/junkp"
  bash "$_self" --prune "$d/junkp" >/dev/null 2>&1
  [ -s "$d/junkp" ] && _ok "prune leaves an unparseable ledger alone" "file survived" \
    || _no "prune leaves an unparseable ledger alone" "the prune destroyed it"

  # FAIL CLOSED ON THE LEDGER ITSELF.
  printf 'not json\n' > "$d/junk";  _run "a junk ledger refuses" "$d/junk" 4 "CANNOT READ"
  out=$(bash "$_self" --verdict "$d/nope" 2>&1); rc=$?
  [ "$rc" = 4 ] && _ok "a missing ledger refuses" "exit 4" || _no "a missing ledger refuses" "exit=$rc"
  # ONE POLL IS NOT A WINDOW.
  gen "$d/one" 0 30;                _run "a single poll is not a window" "$d/one" 2 "NOT YET MEASURED"
  # EVERY EXIT PRINTS A TERMINAL LINE. A watcher that exits silently is
  # indistinguishable from one still running.
  local silent=0 f
  for f in clean onered unread mixed novel short holed sparse junk one noanchor dead recovered evicted long young; do
    out=$(bash "$_self" --verdict "$d/$f" 2>&1)
    case "$out" in *"TERMINAL:"*) :;; *) silent=$((silent+1));; esac
  done
  [ "$silent" = 0 ] && _ok "every exit prints TERMINAL" "16/16 paths" || _no "every exit prints TERMINAL" "$silent path(s) exited silently"

  rm -rf "$d"
  local total=$((pass+fails))
  if [ "$total" -lt 8 ]; then echo "SELFTEST: CANNOT READ — only $total arm(s) ran"; return 1; fi
  [ "$fails" = 0 ] && { echo "SELFTEST: $pass/$total arms pass"; return 0; }
  echo "SELFTEST: $fails of $total arm(s) FAILED"; return 1
}

case "${1:-}" in
  --selftest) _selftest; exit $?;;
  --record)   shift; do_record "${1:-}" "${2:-}"; exit $?;;
  --verdict)  shift; do_verdict "${1:-}"; exit $?;;
  --prune)    shift; do_prune "${1:-}"; exit $?;;
  *) usage; echo "TERMINAL: no mode given"; exit 4;;
esac
