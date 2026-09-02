#!/usr/bin/env bash
# reap-orphans.sh — reap LEAKED preview/browser processes by SIGNATURE.
#                   Never by name alone. Never by port. Never by guess.
#
# ─────────────────────────────────────────────────────────────────────────────
#  WHY THIS EXISTS (task gr-backlog-orphan-reap-signature)
# ─────────────────────────────────────────────────────────────────────────────
#  This checkout is shared by many concurrent agent sessions, and every one of
#  them runs `node .../__preview__/serve.mjs` and headless Chrome. Process NAME
#  is therefore not ownership evidence, and a broad sweep is not cleanup — it is
#  a coin flip against someone else's live evidence run.
#
#  THE INCIDENT. During round-7 verification a verifier reaping the shoot.sh
#  wedge ran a broad `headless|serve.mjs` sweep and killed pid 65109 — a
#  serve.mjs about TWO MINUTES old in a sibling worktree — without checking it
#  against the wedge's actual signature (PPID=1, 3h38m+ elapsed). A new
#  serve.mjs for that tree appeared on another port moments later: the sibling's
#  harness retrying after an unexplained server death. Nothing durable was
#  clobbered; a concurrent run was silently corrupted.
#
#  THE MEASUREMENT. Genuine orphans have a much stronger signature than a name.
#  Of four verifier censuses, three found ZERO orphans and the fourth found five
#  real ones (4 Chrome + 1 serve.mjs) — every one of them PPID=1 and 4h04m to
#  4h11m elapsed, two having written their PNGs three hours earlier. So
#  "my run was clean" is not evidence the risk is closed, AND a matching process
#  name is not evidence a process is an orphan.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE CONTRACT — three ANDs, and a default that cannot hurt anyone
# ─────────────────────────────────────────────────────────────────────────────
#  A process is a reap candidate only when ALL THREE hold:
#
#    1. SIGNATURE  its argv matches a known instrument signature (see
#                  classify() below) — a preview server rooted in a
#                  `__preview__/serve.mjs`, or a headless browser carrying a
#                  --screenshot= job or one of our instruments' own profile
#                  directories.
#                  "node" is not a signature. "Google Chrome" is not a
#                  signature. A PORT is never consulted, in any rule.
#    2. PPID=1     the process has been REPARENTED — its launcher is gone. A
#                  process whose parent is alive belongs to a run in progress,
#                  which is exactly what pid 65109 was.
#    3. ELAPSED    it is older than a floor (default 3600s). A young process is
#                  presumed to be someone's live work even when reparented.
#
#  Dry run is the DEFAULT: with no flags this script signals nothing, ever.
#  Killing requires an explicit --kill. Every candidate — and every near-miss
#  that the PPID or elapsed rules REFUSED — is printed with the evidence that
#  decided it (pid, ppid, elapsed, rule, argv), so a wrong match is visible
#  before it is fatal rather than invisible after.
#
#  Usage:
#    ./reap-orphans.sh                     # list. dry run. signals nothing.
#    ./reap-orphans.sh --kill              # reap what the listing showed
#    ./reap-orphans.sh --min-age 600       # lower the elapsed floor (seconds)
#    ./reap-orphans.sh --scope SUBSTR      # extra AND-filter on argv; NARROWS
#                                          # only, never widens (the selftest
#                                          # fences itself to its own plants)
#    ./reap-orphans.sh --selftest          # plant fakes, prove both directions
#
#  Env: REAP_MIN_AGE (seconds) is the default for --min-age.
#
#  Exit: 0 scan completed (whether or not anything matched) · 1 selftest failed
#        · 2 usage error.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SELF_PID=$$
SELF_NAME="reap-orphans.sh"
MIN_AGE="${REAP_MIN_AGE:-3600}"
DO_KILL=0
SCOPE=""
# When non-empty, the kill path REFUSES any pid outside this list. The selftest
# sets it to its own planted pids so a matcher bug can never reach the host.
ALLOW_PIDS=""

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; }

# ── the signature table ──────────────────────────────────────────────────────
# Prints a rule name and returns 0 when argv carries one of OUR instruments'
# signatures; returns 1 otherwise. A bare interpreter or browser name never
# reaches a `printf` here — that is the whole point of the file.
classify() {
  local argv="$1"
  # Never target a reaper (this script, or a concurrent one).
  case "$argv" in *"$SELF_NAME"*) return 1 ;; esac

  # The preview static server. serve.mjs always lives under __preview__/, and
  # every instrument spawns it by that path (overflow-guard.mjs:604,
  # modal-oracle.mjs:481, breakpoint-sweep.mjs:1387, shoot.sh:233).
  case "$argv" in *__preview__/serve.mjs*) printf 'preview-server'; return 0 ;; esac

  # Headless Chrome, but only when it also carries an argument that only OUR
  # harnesses pass. --headless alone matches every agent's browser on this box.
  case "$argv" in
    *--headless*)
      case "$argv" in
        # A headless screenshot job. NOTE this matches any harness's headless
        # screenshot on the box, not only shoot.sh's — deliberately: a
        # REPARENTED, hours-old one is leaked by any owner's standard, and it is
        # the PPID and elapsed rules (not this one) that carry the safety.
        *--screenshot=*) printf 'headless-screenshot'; return 0 ;;
        # The CDP instruments each mkdtemp a profile under their own prefix.
        *--user-data-dir=*overflow-guard-*   | \
        *--user-data-dir=*modal-oracle-*     | \
        *--user-data-dir=*breakpoint-sweep-* | \
        *--user-data-dir=*cssom-parity-*     | \
        *--user-data-dir=*rhp-proof*         | \
        *--user-data-dir=*studio-journey-*   | \
        *--user-data-dir=*journey-smoke-*)
          printf 'instrument-chrome'; return 0 ;;
      esac
      ;;
  esac
  return 1
}

# ── elapsed parsing ──────────────────────────────────────────────────────────
# ps etime is [[DD-]HH:]MM:SS on both macOS and Linux. Prints seconds, or -1.
etime_seconds() {
  local e="$1" d=0 h=0 m=0 s=0
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  local IFS=:
  # shellcheck disable=SC2086
  set -- $e
  case $# in
    3) h="$1"; m="$2"; s="$3" ;;
    2) m="$1"; s="$2" ;;
    1) s="$1" ;;
    *) echo -1; return 0 ;;
  esac
  case "$d$h$m$s" in *[!0-9]*) echo -1; return 0 ;; esac
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

ps_snapshot() {
  ps -Awwo pid=,ppid=,etime=,command= 2>/dev/null \
    || ps -ewwo pid=,ppid=,etime=,args= 2>/dev/null
}

# ── the scan ─────────────────────────────────────────────────────────────────
# Prints, per matched signature, one of:
#   ORPHAN  … reparented AND past the floor → a reap candidate
#   KEEP    … signature matched but a rule REFUSED it, with the reason
# then (only under --kill) signals the ORPHAN set. Evidence always precedes
# action, so a wrong match is read before it is executed.
scan() {
  local reap_pids="" n_orphan=0 n_keep=0 rc=0

  if [ "$DO_KILL" = 1 ]; then
    echo "== preview orphan reap — ARMED (--kill): matched orphans WILL be signalled"
  else
    echo "== preview orphan reap — dry run (nothing will be signalled)"
  fi
  echo "   rule: SIGNATURE and PPID=1 and elapsed >= ${MIN_AGE}s${SCOPE:+   scope: argv contains '$SCOPE'}"
  echo "   a name match alone is NOT a match, and no rule reads a port."

  local pid ppid etime argv rule age why
  while read -r pid ppid etime argv; do
    [ -n "${argv:-}" ] || continue
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$SELF_PID" ] && continue
    [ "$pid" = "$PPID" ] && continue
    if [ -n "$SCOPE" ]; then case "$argv" in *"$SCOPE"*) ;; *) continue ;; esac; fi
    rule="$(classify "$argv")" || continue
    age="$(etime_seconds "$etime")"

    why=""
    [ "$ppid" = "1" ] || why="parent $ppid is ALIVE (not reparented)"
    if [ "$age" -lt 0 ]; then
      why="${why:+$why; }elapsed '$etime' is unparseable — refusing"
    elif [ "$age" -lt "$MIN_AGE" ]; then
      why="${why:+$why; }younger than the floor (${age}s < ${MIN_AGE}s)"
    fi

    if [ -z "$why" ]; then
      n_orphan=$((n_orphan + 1))
      reap_pids="$reap_pids $pid"
      printf 'ORPHAN  pid=%s ppid=%s elapsed=%s (%ss) rule=%s\n' "$pid" "$ppid" "$etime" "$age" "$rule"
      printf '        argv: %s\n' "$argv"
    else
      n_keep=$((n_keep + 1))
      printf 'KEEP    pid=%s ppid=%s elapsed=%s (%ss) rule=%s\n' "$pid" "$ppid" "$etime" "$age" "$rule"
      printf '        why:  %s\n' "$why"
      printf '        argv: %s\n' "$argv"
    fi
  done <<EOF
$(ps_snapshot)
EOF

  echo "-- $n_orphan orphan(s), $n_keep kept by a rule."
  if [ "$DO_KILL" != 1 ]; then
    echo "-- dry run: nothing was signalled. Re-run with --kill to reap."
    return 0
  fi

  local p
  for p in $reap_pids; do
    if [ -n "$ALLOW_PIDS" ]; then
      case " $ALLOW_PIDS " in
        *" $p "*) ;;
        *) echo "!! REFUSED to signal pid $p — outside the caller's allow-list."; rc=1; continue ;;
      esac
    fi
    echo ">> TERM pid=$p"
    kill -TERM "$p" 2>/dev/null || true
  done
  [ -n "$reap_pids" ] && sleep 1
  for p in $reap_pids; do
    if kill -0 "$p" 2>/dev/null; then
      if [ -n "$ALLOW_PIDS" ]; then
        case " $ALLOW_PIDS " in *" $p "*) ;; *) continue ;; esac
      fi
      echo ">> KILL pid=$p (ignored TERM)"
      kill -KILL "$p" 2>/dev/null || true
    fi
  done
  return $rc
}

# ── selftest ─────────────────────────────────────────────────────────────────
# Plants four fakes and proves the matcher in BOTH directions. It may only ever
# signal a process it started itself: the kill pass is fenced twice — by --scope
# (its own unique marker) and by ALLOW_PIDS (its own planted pids).
PLANTED=""
selftest_cleanup() {
  local p
  for p in $PLANTED; do kill -KILL "$p" 2>/dev/null || true; done
}

selftest() {
  local floor=12 checks=0 fails=0
  local mark="reap-selftest-$$-$(date +%s)"
  local tmpd node sleeper fake decoy
  node="$(command -v node || true)"
  if [ -z "$node" ]; then echo "!! selftest: node is not on PATH"; return 1; fi
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/__preview__" "$tmpd/elsewhere"
  fake="$tmpd/__preview__/serve.mjs"      # carries the preview-server signature
  decoy="$tmpd/elsewhere/other.mjs"       # same BINARY, no signature
  sleeper='setTimeout(function(){},900000)'
  trap selftest_cleanup EXIT

  find_mark() {
    local tag="$1" tries=0 p=""
    while [ "$tries" -lt 50 ]; do
      p="$(ps -Awwo pid=,command= | grep -F "$tag" | grep -v ' grep ' | awk '{print $1}' | head -1)"
      [ -n "$p" ] && { echo "$p"; return 0; }
      tries=$((tries + 1)); sleep 0.1
    done
    return 1
  }
  ok()  { checks=$((checks + 1)); echo "  ok   $1"; }
  bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "  FAIL $1"; }

  echo "== reap-orphans.sh selftest (floor=${floor}s, marker=$mark)"
  echo "-- planting"

  # (1) the genuine orphan: signature + PPID=1 (double fork) + will be aged.
  ( "$node" -e "$sleeper" "$fake" --port 4199 "$mark-orphan" >/dev/null 2>&1 & )
  # (1b) a second genuine orphan carrying the CHROME signature instead.
  ( "$node" -e "$sleeper" "$mark-chrome" --headless=new "--screenshot=$tmpd/__shots__/x.png" >/dev/null 2>&1 & )
  # (4) the decoy: same interpreter, PPID=1, aged — but NO signature.
  ( "$node" -e "$sleeper" "$decoy" "$mark-decoy" >/dev/null 2>&1 & )
  # (3) the live child: signature + aged, but its parent (us) is ALIVE.
  "$node" -e "$sleeper" "$fake" --port 4199 "$mark-parented" >/dev/null 2>&1 &
  local parented_pid=$!
  PLANTED="$PLANTED $parented_pid"

  local orphan_pid chrome_pid decoy_pid fresh_pid expected
  orphan_pid="$(find_mark "$mark-orphan")" || { echo "!! could not plant the orphan"; return 1; }
  chrome_pid="$(find_mark "$mark-chrome")" || { echo "!! could not plant the chrome orphan"; return 1; }
  decoy_pid="$(find_mark "$mark-decoy")"   || { echo "!! could not plant the decoy"; return 1; }
  PLANTED="$PLANTED $orphan_pid $chrome_pid $decoy_pid"
  expected="$(printf '%s\n%s\n' "$orphan_pid" "$chrome_pid" | sort -n | tr -d '\n')"
  echo "   orphan=$orphan_pid (preview-server, ppid=1)  chrome=$chrome_pid (headless-screenshot, ppid=1)"
  echo "   decoy=$decoy_pid (ppid=1, NO signature)  parented=$parented_pid (ppid=$SELF_PID)"

  echo "-- aging past the floor (${floor}s+2) …"
  sleep $((floor + 2))

  # (2) the fresh control: signature + PPID=1, but seconds old — pid 65109's
  #     shape, the process the broad sweep actually killed.
  ( "$node" -e "$sleeper" "$fake" --port 4199 "$mark-fresh" >/dev/null 2>&1 & )
  fresh_pid="$(find_mark "$mark-fresh")" || { echo "!! could not plant the fresh control"; return 1; }
  PLANTED="$PLANTED $fresh_pid"
  echo "   fresh=$fresh_pid (ppid=1, seconds old)"

  # ── A. unscoped DRY RUN: the matcher finds the orphan among the live host's
  #       real processes, with no scope filter helping it. Dry run only — an
  #       unscoped --kill is never run by this selftest, by construction.
  echo "-- A. unscoped dry run (read-only)"
  MIN_AGE=$floor SCOPE="" DO_KILL=0 ALLOW_PIDS=""
  local out_a; out_a="$(scan)"
  if echo "$out_a" | grep -q "^ORPHAN  pid=$orphan_pid "; then
    ok "unscoped dry run reports pid $orphan_pid as ORPHAN"
  else
    bad "unscoped dry run did NOT report pid $orphan_pid as ORPHAN"
  fi
  if echo "$out_a" | grep -q "^ORPHAN  pid=$decoy_pid "; then
    bad "unscoped dry run reported the signature-less decoy $decoy_pid as ORPHAN"
  else
    ok "the signature-less decoy $decoy_pid is not a candidate at all (name is not a signature)"
  fi

  # ── B. scoped DRY RUN: exact-set assertion + the refusal reasons.
  echo "-- B. scoped dry run (--scope $mark)"
  MIN_AGE=$floor SCOPE="$mark" DO_KILL=0 ALLOW_PIDS=""
  local out_b; out_b="$(scan)"
  echo "$out_b" | sed 's/^/   | /'
  local got; got="$(echo "$out_b" | awk '/^ORPHAN/ {sub(/^pid=/,"",$2); print $2}' | sort -n | tr '\n' ' ')"
  if [ "$(echo "$got" | tr -d ' ')" = "$expected" ]; then
    ok "scoped candidate set is EXACTLY {$orphan_pid $chrome_pid} — both signatures, nothing else"
  else
    bad "scoped candidate set was {$got} — expected exactly {$orphan_pid $chrome_pid}"
  fi
  if echo "$out_b" | grep -A1 "^KEEP    pid=$fresh_pid " | grep -q "younger than the floor"; then
    ok "the fresh same-signature process $fresh_pid is KEPT — refused by the elapsed floor"
  else
    bad "the fresh process $fresh_pid was not kept-with-reason by the elapsed floor"
  fi
  if echo "$out_b" | grep -A1 "^KEEP    pid=$parented_pid " | grep -q "is ALIVE (not reparented)"; then
    ok "the aged-but-parented process $parented_pid is KEPT — refused by the PPID rule"
  else
    bad "the parented process $parented_pid was not kept-with-reason by the PPID rule"
  fi

  # ── C. the fence, asserted BEFORE anything is armed.
  if [ "$(echo "$got" | tr -d ' ')" = "$expected" ]; then
    ok "kill list is a subset of this selftest's own plants — safe to arm"
  else
    bad "kill list escaped this selftest's plants — REFUSING to arm"
    echo "== selftest: $checks checks, $fails FAILED"; return 1
  fi

  # ── D. scoped KILL: double-fenced (scope + allow-list).
  echo "-- D. scoped kill (--kill --scope $mark)"
  MIN_AGE=$floor SCOPE="$mark" DO_KILL=1 ALLOW_PIDS="$orphan_pid $chrome_pid"
  scan | sed 's/^/   | /'
  sleep 0.5
  if kill -0 "$orphan_pid" 2>/dev/null; then
    bad "the genuine preview-server orphan $orphan_pid SURVIVED --kill"
  else
    ok "the genuine preview-server orphan $orphan_pid was reaped"
  fi
  if kill -0 "$chrome_pid" 2>/dev/null; then
    bad "the genuine headless-screenshot orphan $chrome_pid SURVIVED --kill"
  else
    ok "the genuine headless-screenshot orphan $chrome_pid was reaped"
  fi
  local survivor
  for survivor in "$fresh_pid:fresh" "$parented_pid:parented" "$decoy_pid:decoy"; do
    local sp="${survivor%%:*}" sn="${survivor##*:}"
    if kill -0 "$sp" 2>/dev/null; then
      ok "the $sn control $sp survived --kill"
    else
      bad "the $sn control $sp was KILLED — this is the pid-65109 defect"
    fi
  done

  echo "== selftest: $checks checks, $fails failed"
  [ "$fails" -eq 0 ] || return 1
  echo "== PASS ($checks checks)"
  return 0
}

# ── argv ─────────────────────────────────────────────────────────────────────
MODE=scan
while [ $# -gt 0 ]; do
  case "$1" in
    --kill)     DO_KILL=1 ;;
    --min-age)  shift; MIN_AGE="${1:-}"; case "$MIN_AGE" in ''|*[!0-9]*) echo "!! --min-age needs whole seconds" >&2; exit 2 ;; esac ;;
    --scope)    shift; SCOPE="${1:-}"; [ -n "$SCOPE" ] || { echo "!! --scope needs a substring" >&2; exit 2; } ;;
    --selftest) MODE=selftest ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "!! unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$MODE" = selftest ]; then selftest; else scan; fi
