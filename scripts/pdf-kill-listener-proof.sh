#!/usr/bin/env bash
#
# pdf-kill-listener-proof.sh — THE PERSONAL DEV FLEET KILL-A-LISTENER PROOF
# (PDF-D14/D24/D28: every wave ships behind a proof that must fire).
#
#   scripts/pdf-kill-listener-proof.sh --plan     print every rung, its assert and
#                                                 the timing-anchor formula. NO side
#                                                 effects, always exit 0.
#   scripts/pdf-kill-listener-proof.sh            the proof: two stub listeners up,
#                                                 kill one — the survivor stays
#                                                 returned AND non-offline, the
#                                                 corpse flips OFFLINE exactly at
#                                                 its TTL boundary and not before.
#   scripts/pdf-kill-listener-proof.sh --negctl   the negative control: the harness
#                                                 keeps beating the corpse at the
#                                                 SAME cadence and the OFFLINE
#                                                 assert must FIRE AS A FAILURE —
#                                                 a check that cannot fail proves
#                                                 nothing (PDS-D20 inherited).
#   scripts/pdf-kill-listener-proof.sh --help
#
# WHAT IT PROVES (and its transcript stamps the epic's criterion 0, PDF-D33):
# presence in the Personal Dev Fleet is a heartbeat with fail-closed staleness
# (PDF-D6/D17/D20) — `Barkpark.Tasks.Fleet` computes offline SERVER-SIDE at
# read time, `offline iff floor(now − last_seen) > ttl_s`, and this harness
# never computes its own staleness: every per-poll status below is the server's.
#
# THE THREE OUTCOMES (the pds-pull-proof.sh ladder, verbatim — no fourth, no
# silent skip):
#   PASS   the rung ran and every assertion held, with run-time-derived numbers.
#   ABORT  the rung cannot run (e.g. this tree does not serve /v1/fleet/* —
#          stale checkout or wrong target). Not a failure, not a pass.
#   FAIL   the rung ran and an assertion did NOT hold.
# Exit: 0 = every rung PASSed (in --negctl: the inner offline-assert FIRED as a
# failure, which is that mode's pass). 1 = FAIL. 2 = ABORT. 3 = usage error.
#
# SUBSTRATE (PDF-D29, all live-proven 2026-07-22):
#   · Run from a FRESH origin/main worktree. The primary checkout has NO
#     /v1/fleet/* routes — an in-place boot 404s by construction; rung 0 turns
#     that into a named ABORT, never a TTL "failure".
#   · The target is a disposable scratch instance booted from THIS tree by
#     scripts/pds-scratch-target.sh. BARKPARK_HOME defaults to a SHORT
#     mktemp root (/tmp/pdf.XXXX — the scratch script's TRAP-3 85-byte cap
#     refuses nested scratchpad paths) and PDS_SCRATCH_POINTER is PINNED
#     per-run to $BARKPARK_HOME/pointer — NEVER the global
#     /tmp/pds-scratch-target.last, which any concurrent scratch boot silently
#     repoints. Cold boot budget 15 min (measured 311.7s); warm ~13-33s.
#   · Teardown must PASS (both ports released, zero orphan postgres) and the
#     host's :4000 listener set must be untouched across the whole run.
#
# THE KILL IS STRAGGLER-PROOF (PDF-D28): `set -m` FIRST — non-interactive bash
# gives backgrounded jobs their own process group ONLY under job control — then
# `kill -- -PGID`, never bare `kill PID`: the bare form leaves the in-flight
# curl child alive to land a straggler beat ~50ms after the kill (proven 2/2;
# group kill 0/2). PGIDs are asserted DISTINCT (from each other and from the
# harness) before anything is killed.
#
# Environment (all optional; --plan prints the defaults):
#   BARKPARK_HOME        scratch root — minted per run when unset (short!)
#   PDS_SCRATCH_POINTER  pointer file — defaults to $BARKPARK_HOME/pointer
#   PDF_TTL_S            corpse/survivor self-declared ttl_s (default 10 —
#                        deliberately NOT the 30/900/120 fixtures, PDF-D22)
#   PDF_BEAT_EVERY       stub-listener beat cadence, seconds (default 2)
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail
# set -m FIRST (PDF-D28): job control is what gives each backgrounded stub
# listener its OWN process group, which is what makes the kill straggler-proof.
set -m

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"
SCRATCH_SCRIPT="$SCRIPT_DIR/pds-scratch-target.sh"

# ── the timing law (PDF-D28) ─────────────────────────────────────────────────
#
# ttl_s=10 for speed. The server's staleness formula (Barkpark.Tasks.Fleet,
# @canonical capability:fleet-presence-staleness) is
#
#     offline  iff  DateTime.diff(now, last_seen, :second) > ttl_s
#
# and DateTime.diff FLOORS, so the true offline boundary in wall seconds is
# elapsed >= ttl_s + 1. The bracket asserted below:
#
#     elapsed <  TTL_S          -> the corpse MUST read non-offline
#     TTL_S <= elapsed < TTL_S+1 -> margin band, UNASSERTED (a poll sent at
#                                  9.99 is served at 10.01 — one clock, but
#                                  request and read are not the same instant)
#     elapsed >= TTL_S + 1      -> the corpse MUST read offline, and STAY
#     corpse not offline by CEILING -> FAIL (timed out)
TTL_S="${PDF_TTL_S:-10}"
BEAT_EVERY="${PDF_BEAT_EVERY:-2}"
ONLINE_EDGE="$TTL_S"
OFFLINE_EDGE=$((TTL_S + 1))
CEILING=$((TTL_S + 5))

CORPSE="proof-w1"
SURVIVOR="proof-w2"

MODE="run"
case "${1:-}" in
  "")            MODE="run" ;;
  --plan)        MODE="plan" ;;
  --negctl)      MODE="negctl" ;;
  -h|--help)     sed -n '3,58p' "$0"; exit 0 ;;
  *) printf '%s: unknown argument %s (try --help)\n' "$SELF" "$1" >&2; exit 3 ;;
esac

# ── output helpers (the pds-pull-proof.sh dialect) ───────────────────────────

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }

N_PASS=0; N_ABORT=0; N_FAIL=0
pass()  { N_PASS=$((N_PASS + 1));  printf '  PASS   %-3s %s\n' "$1" "$2"; }
abort() { N_ABORT=$((N_ABORT + 1)); printf '  ABORT  %-3s %s\n' "$1" "$2"; printf '         %s\n' "$3"; }
fail()  { N_FAIL=$((N_FAIL + 1));  printf '  FAIL   %-3s %s\n' "$1" "$2"; }

head_rung() { printf '\n'; rule; printf 'RUNG %s — %s\n' "$1" "$2"; rule; }

# ── small tools ──────────────────────────────────────────────────────────────

now_epoch() { python3 -c 'import time; print("%.3f" % time.time())'; }

iso_to_epoch() { # ISO8601 (with Z) -> epoch float
  python3 -c '
import sys
from datetime import datetime
s = sys.argv[1].strip().replace("Z", "+00:00")
print("%.6f" % datetime.fromisoformat(s).timestamp())' "$1"
}

# LC_ALL=C on BOTH float helpers is load-bearing: under a comma-decimal locale
# (nb_NO et al) awk's %.2f prints "3,02", which awk then refuses as a strnum —
# and a string-vs-number awk comparison falls back to LEXICOGRAPHIC, where
# "3,02" >= "15" is TRUE. Live-hit on this host: the bracket broke at poll 2
# with the corpse "past the boundary" at elapsed 3s.
fcmp() { # a op b — float comparison; true when it holds
  LC_ALL=C awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{
    if (op == "<")  exit !(a <  b)
    if (op == "<=") exit !(a <= b)
    if (op == ">")  exit !(a >  b)
    if (op == ">=") exit !(a >= b)
    exit 1
  }'
}

fsub() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a - b}'; }

pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

group_members() { # pgid -> "pid (comm)" lines, indented
  ps -Ao pid=,pgid=,comm= 2>/dev/null | awk -v g="$1" '$2 == g {print "        pid " $1 " (" $3 ")"}'
}

group_alive() { ps -Ao pgid= 2>/dev/null | awk -v g="$1" '$1 == g {found=1} END{exit !found}'; }

port4000_snapshot() { lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null | sort | tr '\n' ' ' | sed 's/ *$//'; }

# ── target plumbing (everything comes from scratch.env via the PINNED pointer)

TARGET_BASE=""; TARGET_TOKEN=""

curl_beat() { # worker status ttl_s -> response body on stdout (exit = curl's)
  curl -sS --max-time 5 -X POST "$TARGET_BASE/v1/fleet/beat" \
    -H "Authorization: Bearer $TARGET_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"worker\":\"$1\",\"status\":\"$2\",\"ttl_s\":$3}"
}

curl_roster() { # -> body on stdout
  curl -sS --max-time 10 -H "Authorization: Bearer $TARGET_TOKEN" \
    "$TARGET_BASE/v1/fleet/roster"
}

row_of() { # worker; roster JSON on stdin -> that row as one-line JSON, or ""
  W="$1" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("documents") or []:
    if r.get("worker") == os.environ["W"]:
        print(json.dumps(r, sort_keys=True))
        break
'
}

field_of() { # key; row JSON on stdin -> value, or ""
  K="$1" python3 -c '
import json, os, sys
line = sys.stdin.read().strip()
if not line:
    sys.exit(0)
v = json.loads(line).get(os.environ["K"])
print("" if v is None else v)'
}

beat_last_seen() { # beat-response JSON on stdin -> doc.last_seen, or ""
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(((d.get("doc") or {}).get("last_seen")) or "")'
}

# ── the stub listener: a single foreground-shaped loop, backgrounded ─────────
#
# PDF-D22: no detached beat sidecar — the beat lives inside the one loop and
# shares fate with it. Killing the GROUP kills the loop AND its in-flight curl.

run_stub_loop() { # worker logfile
  local worker="$1" log="$2"
  while true; do
    curl -sS --max-time 5 -X POST "$TARGET_BASE/v1/fleet/beat" \
      -H "Authorization: Bearer $TARGET_TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"worker\":\"$worker\",\"status\":\"idle\",\"ttl_s\":$TTL_S}" >>"$log" 2>/dev/null || true
    printf '\n' >>"$log"
    sleep "$BEAT_EVERY"
  done
}

# ── cleanup: never leave a loop beating or a scratch postgres orphaned ───────

W1_PID=""; W2_PID=""; W1_PGID=""; W2_PGID=""
BOOTED=""; TEARDOWN_DONE=""

cleanup() {
  set +e
  local g
  for g in "$W1_PGID" "$W2_PGID"; do
    [ -n "$g" ] && group_alive "$g" && kill -KILL -- "-$g" 2>/dev/null
  done
  if [ -n "$BOOTED" ] && [ -z "$TEARDOWN_DONE" ]; then
    say ""
    say "cleanup: the run died before rung 6 — emergency teardown of $BARKPARK_HOME"
    "$SCRATCH_SCRIPT" teardown \
      || say "cleanup: emergency teardown FAILED — scratch root left at $BARKPARK_HOME for diagnosis"
  fi
  return 0
}
trap cleanup EXIT

# ═════════════════════════════════════════════════════════════════════════════
# --plan — every rung, its assert, and the anchor formula. No side effects.
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "plan" ]; then
  rule
  say "PDF KILL-A-LISTENER PROOF — PLAN (no side effects: no boot, no mktemp,"
  say "no network; this mode only prints)"
  rule
  say "tree:      $REPO_ROOT"
  say "scratch:   ${BARKPARK_HOME:-/tmp/pdf.XXXX (minted per run via mktemp — short, TRAP-3 85-byte cap)}"
  say "pointer:   ${PDS_SCRATCH_POINTER:-\$BARKPARK_HOME/pointer (PINNED per run — never the global /tmp/pds-scratch-target.last)}"
  say "listeners: $CORPSE (the corpse) + $SURVIVOR (the survivor), status=idle,"
  say "           ttl_s=$TTL_S, one beat every ${BEAT_EVERY}s"
  say "outcomes:  PASS / ABORT / FAIL — no silent skip. Exit 0/2/1 (+3 usage)."
  say ""
  say "THE TIMING-ANCHOR FORMULA (PDF-D28):"
  say "  T_anchor       = the server-echoed doc.last_seen of the corpse's LAST"
  say "                   successful beat, re-read from the ROSTER after the kill"
  say "                   settles (an in-flight beat that outlives a sloppy kill"
  say "                   would move it — hence the re-read AND the group kill)."
  say "  elapsed(poll)  = wall_epoch(poll request) − epoch(T_anchor)"
  say "                   (one host, one clock: last_seen is server-stamped on"
  say "                   the same machine the harness runs on)"
  say "  OFFLINE truth  = server-side only (Barkpark.Tasks.Fleet):"
  say "                   offline iff floor(now − last_seen) > ttl_s  — the"
  say "                   harness NEVER computes its own staleness."
  say "  with ttl_s=$TTL_S:  elapsed <  $ONLINE_EDGE      => corpse MUST read non-offline"
  say "                 $ONLINE_EDGE <= elapsed < $OFFLINE_EDGE => margin band, unasserted"
  say "                 elapsed >= $OFFLINE_EDGE      => corpse MUST read offline, and STAY"
  say "                 not offline by elapsed $CEILING => FAIL (timed out)"
  say ""
  say "RUNGS:"
  say "  0  PRECONDITION — boot the scratch target from THIS tree"
  say "     (pds-scratch-target.sh up; scratch.env sourced via the pinned"
  say "     pointer), then GET /v1/fleet/roster must answer 200 with the"
  say "     {\"documents\":[...]} envelope and a probe POST /v1/fleet/beat must"
  say "     200 — anything else ABORTS 'stale checkout or wrong target': a"
  say "     route failure must never read as a TTL failure."
  say "  1  SPAWN — set -m FIRST, then two backgrounded stub listeners (one"
  say "     foreground-shaped curl loop each, PDF-D22: beat and worker share"
  say "     fate). ASSERT both PGIDs are distinct from each other AND from the"
  say "     harness's own PGID; both workers register (first beat lands)."
  say "  2  BASELINE — the roster returns BOTH rows non-offline (server-computed"
  say "     status), rows quoted verbatim into the transcript."
  say "  3  KILL — kill -- -PGID of the corpse's group (NEVER bare kill PID:"
  say "     the in-flight curl child survives it and lands a straggler beat,"
  say "     proven 2/2 vs 0/2). Confirm loop AND curl child dead by group"
  say "     listing; settle; T_anchor re-read (roster vs the corpse's own last"
  say "     beat log — normally byte-identical)."
  say "  4  TTL BRACKET — poll the roster ~1s until elapsed >= $CEILING, asserting"
  say "     the formula above at every poll, PLUS: the survivor is PRESENT in"
  say "     the response AND non-offline at EVERY poll (presence-in-response"
  say "     catches the empty-read scope bug an ONLINE assert alone would"
  say "     miss). Decisive roster JSON rows printed per poll."
  say "     --negctl variant: after the SAME kill, the HARNESS beats the corpse"
  say "     at the SAME ${BEAT_EVERY}s cadence; the corpse must NEVER flip, i.e. the"
  say "     rung-4 offline-assert must FIRE AS A FAILURE => NEGCTL OK, exit 0."
  say "  5  BP CLI (best-effort, recorded, NEVER blocking) — bp fleet roster"
  say "     -o table with BP_COLOR=none against the scratch target."
  say "  6  TEARDOWN — reap the survivor group, then pds-scratch-target.sh"
  say "     teardown must PASS (both ports released, zero orphan postgres);"
  say "     the host's :4000 listener set must be unchanged across the run."
  rule
  say "Run it:  $0          (the proof)"
  say "         $0 --negctl (the control that must fire)"
  rule
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# run / --negctl
# ═════════════════════════════════════════════════════════════════════════════

command -v curl    >/dev/null 2>&1 || die "curl not on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"
[ -x "$SCRATCH_SCRIPT" ] || die "$SCRATCH_SCRIPT missing — this harness consumes it, never reimplements it"

# Pin the substrate (PDF-D29). Short root, per-run pointer.
export BARKPARK_HOME="${BARKPARK_HOME:-$(mktemp -d /tmp/pdf.XXXX)}"
export PDS_SCRATCH_POINTER="${PDS_SCRATCH_POINTER:-$BARKPARK_HOME/pointer}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
HARNESS_PGID="$(pgid_of $$)"
PORT4000_BEFORE="$(port4000_snapshot)"

rule
say "PDF KILL-A-LISTENER PROOF — ${MODE} — run $RUN_ID"
rule
say "tree:        $REPO_ROOT"
say "worktree:    $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown))"
say "scratch:     $BARKPARK_HOME (${#BARKPARK_HOME} bytes)"
say "pointer:     $PDS_SCRATCH_POINTER (pinned — never the global default)"
say "ttl_s:       $TTL_S · beat every ${BEAT_EVERY}s · offline boundary elapsed >= $OFFLINE_EDGE · ceiling $CEILING"
say "harness PGID $HARNESS_PGID · host :4000 listeners before: ${PORT4000_BEFORE:-none}"

# ── RUNG 0 — PRECONDITION ────────────────────────────────────────────────────

head_rung 0 "PRECONDITION — a target that actually serves /v1/fleet/*"

BOOT_LOG="$BARKPARK_HOME/pdf-boot.log"
T0="$(date +%s)"
say "  booting the scratch target from this tree (log: $BOOT_LOG; cold budget"
say "  15 min — measured 311.7s cold, ~13-33s warm)…"
# BOOTED before `up`, not after: a boot that dies halfway may leave a scratch
# postgres running, and the cleanup trap must still attempt the teardown.
BOOTED=1
if ! "$SCRATCH_SCRIPT" up >"$BOOT_LOG" 2>&1; then
  tail -20 "$BOOT_LOG" | sed 's/^/      /' || true
  abort 0 "env:scratch-boot-failed" \
    "pds-scratch-target.sh up failed from $REPO_ROOT — see $BOOT_LOG. Nothing about the fleet TTL was measured."
  exit 2
fi
T1="$(date +%s)"
# Summarize the boot WITHOUT echoing the minted token line.
grep -E 'scratch root|http port|postgres port|media dir' "$BOOT_LOG" | sed 's/^pds-scratch: /      /' || true
info "boot took $((T1 - T0))s"

# Source scratch.env via the PINNED pointer — never a guessed path.
[ -f "$PDS_SCRATCH_POINTER" ] || { abort 0 "env:pointer-missing" "the pinned pointer $PDS_SCRATCH_POINTER was not written by up"; exit 2; }
# shellcheck disable=SC1090
. "$(cat "$PDS_SCRATCH_POINTER")/scratch.env"
TARGET_BASE="$PDS_SCRATCH_BASE"
TARGET_TOKEN="$PDS_SCRATCH_TOKEN"
[ -n "$TARGET_BASE" ] && [ -n "$TARGET_TOKEN" ] || { abort 0 "env:scratch-env-incomplete" "scratch.env lacks PDS_SCRATCH_BASE/PDS_SCRATCH_TOKEN"; exit 2; }
info "target $TARGET_BASE (token from scratch.env — never printed)"

ROSTER_TMP="$(mktemp "${TMPDIR:-/tmp}/pdf-roster.XXXXXX")"
PRECODE="$(curl -sS -o "$ROSTER_TMP" -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer $TARGET_TOKEN" "$TARGET_BASE/v1/fleet/roster" 2>/dev/null | tr -dc '0-9' | tail -c 3 || true)"
ENVELOPE_OK="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("no"); sys.exit(0)
print("yes" if isinstance(d.get("documents"), list) else "no")' "$ROSTER_TMP")"
info "GET /v1/fleet/roster -> HTTP ${PRECODE:-000}, documents-envelope: $ENVELOPE_OK"
if [ "${PRECODE:-000}" != "200" ] || [ "$ENVELOPE_OK" != "yes" ]; then
  info "body: $(head -c 300 "$ROSTER_TMP" | tr -d '\n')"
  rm -f "$ROSTER_TMP"
  abort 0 "env:stale-checkout-or-wrong-target" \
    "this tree's build does not serve the fleet roster (stale checkout or wrong target) — a route failure must never read as a TTL failure. Worktree from freshly-fetched origin/main and re-run."
  exit 2
fi
rm -f "$ROSTER_TMP"

PROBE_RESP="$(curl_beat "proof-probe" "idle" "$TTL_S" 2>/dev/null || true)"
PROBE_SEEN="$(printf '%s' "$PROBE_RESP" | beat_last_seen)"
if [ -z "$PROBE_SEEN" ]; then
  info "probe beat response: $(printf '%s' "$PROBE_RESP" | head -c 300)"
  abort 0 "env:beat-route-dead" "the probe POST /v1/fleet/beat did not answer with a server-stamped doc.last_seen"
  exit 2
fi
info "probe POST /v1/fleet/beat -> ok, server-stamped last_seen=$PROBE_SEEN"
pass 0 "target serves the fleet routes: roster 200 with the documents envelope, beat 200 with a server-stamped last_seen"

# ── RUNG 1 — SPAWN ───────────────────────────────────────────────────────────

head_rung 1 "SPAWN — two stub listeners, each in its OWN process group"

W1_LOG="$BARKPARK_HOME/beats-$CORPSE.log"
W2_LOG="$BARKPARK_HOME/beats-$SURVIVOR.log"
: >"$W1_LOG"; : >"$W2_LOG"

run_stub_loop "$CORPSE" "$W1_LOG" &
W1_PID=$!
run_stub_loop "$SURVIVOR" "$W2_LOG" &
W2_PID=$!
W1_PGID="$(pgid_of "$W1_PID")"
W2_PGID="$(pgid_of "$W2_PID")"
info "$CORPSE   pid=$W1_PID pgid=$W1_PGID"
info "$SURVIVOR pid=$W2_PID pgid=$W2_PGID"
info "harness             pgid=$HARNESS_PGID"

if [ -z "$W1_PGID" ] || [ -z "$W2_PGID" ] \
   || [ "$W1_PGID" = "$W2_PGID" ] || [ "$W1_PGID" = "$HARNESS_PGID" ] || [ "$W2_PGID" = "$HARNESS_PGID" ]; then
  fail 1 "PGIDs are NOT three distinct groups (w1=$W1_PGID w2=$W2_PGID harness=$HARNESS_PGID) — a group kill would take out the wrong thing; refusing to kill anything"
  exit 1
fi

# Wait for both to REGISTER (first beat lands and echoes a doc).
REG_OK=""
i=0
while [ $i -lt 40 ]; do
  W1_FIRST="$(head -1 "$W1_LOG" 2>/dev/null | beat_last_seen)"
  W2_FIRST="$(head -1 "$W2_LOG" 2>/dev/null | beat_last_seen)"
  if [ -n "$W1_FIRST" ] && [ -n "$W2_FIRST" ]; then REG_OK=1; break; fi
  sleep 0.25
  i=$((i + 1))
done
if [ -z "$REG_OK" ]; then
  fail 1 "the stub listeners did not both register within 10s (w1 first-beat last_seen='${W1_FIRST:-}', w2='${W2_FIRST:-}')"
  exit 1
fi
info "first beats landed: $CORPSE last_seen=$W1_FIRST · $SURVIVOR last_seen=$W2_FIRST"
pass 1 "two stub listeners up, three distinct PGIDs (w1=$W1_PGID, w2=$W2_PGID, harness=$HARNESS_PGID), both registered"

# ── RUNG 2 — BASELINE ────────────────────────────────────────────────────────

head_rung 2 "BASELINE — both rows present and non-offline (server-computed)"

BASE_ROSTER="$(curl_roster)"
BASE_W1="$(printf '%s' "$BASE_ROSTER" | row_of "$CORPSE")"
BASE_W2="$(printf '%s' "$BASE_ROSTER" | row_of "$SURVIVOR")"
say "      $CORPSE:   ${BASE_W1:-ABSENT}"
say "      $SURVIVOR: ${BASE_W2:-ABSENT}"
BASE_S1="$(printf '%s' "$BASE_W1" | field_of status)"
BASE_S2="$(printf '%s' "$BASE_W2" | field_of status)"
if [ -z "$BASE_W1" ] || [ -z "$BASE_W2" ] || [ "$BASE_S1" = "offline" ] || [ "$BASE_S2" = "offline" ] || [ -z "$BASE_S1" ] || [ -z "$BASE_S2" ]; then
  fail 2 "baseline roster does not show both rows non-offline ($CORPSE=$BASE_S1, $SURVIVOR=$BASE_S2)"
  exit 1
fi
pass 2 "roster returns both rows, statuses $CORPSE=$BASE_S1 $SURVIVOR=$BASE_S2 (both non-offline)"

# ── RUNG 3 — KILL ────────────────────────────────────────────────────────────

head_rung 3 "KILL — group kill the corpse; confirm loop AND curl child dead"

say "      group $W1_PGID members before the kill:"
group_members "$W1_PGID"
KILL_EPOCH="$(now_epoch)"
kill -TERM -- "-$W1_PGID"
info "sent: kill -TERM -- -$W1_PGID (the group, never a bare PID — a bare kill leaves the in-flight curl to land a straggler beat, proven 2/2)"

DEAD=""
i=0
while [ $i -lt 20 ]; do
  if ! group_alive "$W1_PGID"; then DEAD=1; break; fi
  sleep 0.2
  i=$((i + 1))
done
if [ -z "$DEAD" ]; then
  info "group survived TERM for 4s — escalating to KILL"
  kill -KILL -- "-$W1_PGID" 2>/dev/null || true
  sleep 0.5
  group_alive "$W1_PGID" && { fail 3 "group $W1_PGID still alive after SIGKILL"; exit 1; }
fi
wait "$W1_PID" 2>/dev/null || true
say "      group $W1_PGID members after the kill:"
group_members "$W1_PGID"
[ -z "$(group_members "$W1_PGID")" ] && info "(none — loop and curl child both gone)"

# Settle, then anchor. The roster's last_seen after the group is dead is the
# server's truth of the corpse's LAST successful beat; the corpse's own beat
# log is the cross-check (normally byte-identical — a divergence means a beat
# was in flight at kill time and its response never reached the log).
sleep 1
LOG_ANCHOR="$({ grep -v '^$' "$W1_LOG" || true; } | tail -1 | beat_last_seen)"
ROSTER_ANCHOR="$({ curl_roster || true; } | row_of "$CORPSE" | field_of last_seen)"
info "corpse last beat per its own log:    ${LOG_ANCHOR:-none}"
info "corpse last_seen per the roster:     ${ROSTER_ANCHOR:-none}"
if [ -z "$ROSTER_ANCHOR" ]; then
  fail 3 "the roster no longer carries a last_seen for $CORPSE — nothing to anchor on"
  exit 1
fi
if [ "$LOG_ANCHOR" = "$ROSTER_ANCHOR" ]; then
  info "byte-identical — the beat response and the roster read agree"
else
  info "NOTE: they differ — a beat was in flight at kill time; anchoring on the roster's (server-truth) value"
fi
T_ANCHOR="$ROSTER_ANCHOR"
ANCHOR_EPOCH="$(iso_to_epoch "$T_ANCHOR")"
info "T_anchor = $T_ANCHOR (epoch $ANCHOR_EPOCH); the kill landed at elapsed $(fsub "$KILL_EPOCH" "$ANCHOR_EPOCH")s"
pass 3 "corpse group $W1_PGID confirmed dead (loop + curl child); T_anchor pinned from the server-echoed last_seen"

# ── RUNG 4 — THE TTL BRACKET ─────────────────────────────────────────────────

if [ "$MODE" = "negctl" ]; then
  head_rung 4 "NEGCTL TTL BRACKET — the harness beats the corpse; the offline-assert must FIRE as a failure"
  info "the corpse's loop is DEAD, but the harness now beats $CORPSE every ${BEAT_EVERY}s"
  info "at the same cadence — if the offline check below cannot fail under that,"
  info "it proves nothing (PDS-D20: distrust vacuous green)."
else
  head_rung 4 "TTL BRACKET — poll ~1s; non-offline below $ONLINE_EDGE, offline from $OFFLINE_EDGE, survivor always returned"
fi

POLL=0
BRACKET_FAILS=0
CORPSE_WENT_OFFLINE=""
FIRST_OFFLINE_ELAPSED=""
POLLS_PAST_EDGE=0
NEG_BEATS=0
NEG_BEAT_ERRS=0
LAST_NEG_BEAT="$ANCHOR_EPOCH"

bfail() { BRACKET_FAILS=$((BRACKET_FAILS + 1)); say "      ASSERT-FAIL: $*"; }

while :; do
  TNOW="$(now_epoch)"
  ELAPSED="$(fsub "$TNOW" "$ANCHOR_EPOCH")"

  if [ "$MODE" = "negctl" ] && fcmp "$(fsub "$TNOW" "$LAST_NEG_BEAT")" '>=' "$BEAT_EVERY"; then
    NB_RESP="$(curl_beat "$CORPSE" "idle" "$TTL_S" 2>/dev/null || true)"
    NB_SEEN="$(printf '%s' "$NB_RESP" | beat_last_seen)"
    if [ -n "$NB_SEEN" ]; then
      NEG_BEATS=$((NEG_BEATS + 1))
      say "      negctl beat #$NEG_BEATS at elapsed=${ELAPSED}s -> last_seen=$NB_SEEN"
    else
      NEG_BEAT_ERRS=$((NEG_BEAT_ERRS + 1))
      say "      negctl beat FAILED at elapsed=${ELAPSED}s: $(printf '%s' "$NB_RESP" | head -c 200)"
    fi
    LAST_NEG_BEAT="$TNOW"
  fi

  POLL=$((POLL + 1))
  ROSTER="$(curl_roster || true)"
  ROW1="$(printf '%s' "$ROSTER" | row_of "$CORPSE")"
  ROW2="$(printf '%s' "$ROSTER" | row_of "$SURVIVOR")"
  S1="$(printf '%s' "$ROW1" | field_of status)"
  S2="$(printf '%s' "$ROW2" | field_of status)"

  printf '  poll %2d  elapsed=%6ss  %s=%-8s %s=%-8s\n' "$POLL" "$ELAPSED" "$CORPSE" "${S1:-ABSENT}" "$SURVIVOR" "${S2:-ABSENT}"
  say "           $CORPSE:   ${ROW1:-ABSENT}"
  say "           $SURVIVOR: ${ROW2:-ABSENT}"

  # The survivor: PRESENT in the response and non-offline, at EVERY poll.
  if [ -z "$ROW2" ]; then
    bfail "the survivor is ABSENT from the roster response (the empty-read scope bug)"
  elif [ "$S2" = "offline" ] || [ -z "$S2" ]; then
    bfail "the survivor reads '$S2' at elapsed=${ELAPSED}s — it is alive and beating"
  fi

  # The corpse: present always; status per the bracket. (The margin band
  # [ONLINE_EDGE, OFFLINE_EDGE) is deliberately unasserted — request and read
  # are not the same instant even on one clock.)
  if [ -z "$ROW1" ]; then
    bfail "the corpse row is ABSENT from the roster — the roster must return it (as offline once stale), never drop it"
  else
    if [ "$S1" = "offline" ]; then
      if [ -z "$CORPSE_WENT_OFFLINE" ]; then FIRST_OFFLINE_ELAPSED="$ELAPSED"; fi
      CORPSE_WENT_OFFLINE=1
      if fcmp "$ELAPSED" '<' "$ONLINE_EDGE"; then
        bfail "the corpse reads offline at elapsed=${ELAPSED}s — BEFORE its ttl_s=$TTL_S"
      fi
    else
      if [ "$MODE" != "negctl" ] && fcmp "$ELAPSED" '>=' "$OFFLINE_EDGE"; then
        bfail "the corpse reads '${S1:-ABSENT}' at elapsed=${ELAPSED}s — past the offline boundary ($OFFLINE_EDGE)"
      fi
      if [ "$MODE" != "negctl" ] && [ -n "$CORPSE_WENT_OFFLINE" ]; then
        bfail "the corpse FLAPPED back to '${S1:-?}' after reading offline at ${FIRST_OFFLINE_ELAPSED}s — offline must STICK"
      fi
    fi
    if fcmp "$ELAPSED" '>=' "$OFFLINE_EDGE"; then
      POLLS_PAST_EDGE=$((POLLS_PAST_EDGE + 1))
    fi
  fi

  if fcmp "$ELAPSED" '>=' "$CEILING"; then
    break
  fi
  sleep 1
done

if [ "$POLLS_PAST_EDGE" -lt 2 ]; then
  bfail "only $POLLS_PAST_EDGE poll(s) landed past the offline boundary — the bracket never really tested it"
fi

if [ "$MODE" = "negctl" ]; then
  say ""
  info "negctl beats sent: $NEG_BEATS (errors: $NEG_BEAT_ERRS) at the same ${BEAT_EVERY}s cadence"
  if [ "$NEG_BEATS" -lt 5 ] || [ "$NEG_BEAT_ERRS" -gt 0 ]; then
    fail 4 "the negctl cadence did not hold ($NEG_BEATS beats, $NEG_BEAT_ERRS errors) — the control is not a control"
    exit 1
  fi
  if [ -n "$CORPSE_WENT_OFFLINE" ]; then
    fail 4 "NEGCTL BROKEN — the corpse flipped offline (first at elapsed=${FIRST_OFFLINE_ELAPSED}s) despite continued beats: the beat path or the anchor is broken"
    exit 1
  fi
  if [ "$BRACKET_FAILS" -gt 0 ]; then
    fail 4 "$BRACKET_FAILS non-corpse assertion(s) failed during the negctl bracket (survivor/presence) — see the ASSERT-FAIL lines above"
    exit 1
  fi
  # The offline-assert FIRED as a failure: every poll past the boundary read
  # non-offline while the harness kept beating. That is this mode's PASS.
  info "the rung-4 OFFLINE assert (corpse offline at elapsed >= $OFFLINE_EDGE) FIRED AS A"
  info "FAILURE at every poll past the boundary — with beats continuing the corpse"
  info "never flips. The check CAN fail, so the main run's green is not vacuous."
  pass 4 "NEGCTL OK — the offline-assert demonstrably fires as a failure when beats continue ($POLLS_PAST_EDGE polls past the boundary, all non-offline)"
else
  if [ -z "$CORPSE_WENT_OFFLINE" ]; then
    fail 4 "TIMED OUT — the corpse never read offline by elapsed $CEILING (hard ceiling ttl_s+5)"
    exit 1
  fi
  if [ "$BRACKET_FAILS" -gt 0 ]; then
    fail 4 "$BRACKET_FAILS bracket assertion(s) failed — see the ASSERT-FAIL lines above"
    exit 1
  fi
  pass 4 "corpse non-offline at every poll below $ONLINE_EDGE, first offline at elapsed=${FIRST_OFFLINE_ELAPSED}s (boundary $OFFLINE_EDGE, ceiling $CEILING), stayed offline; survivor present AND non-offline at all $POLL polls"
fi

# ── RUNG 5 — BP CLI (best-effort; recorded, never blocking) ──────────────────

head_rung 5 "BP CLI — best-effort capture (records, never blocks the proof)"

if command -v bp >/dev/null 2>&1; then
  BP_OUT="$(BARKPARK_SERVER="$TARGET_BASE" BARKPARK_API_TOKEN="$TARGET_TOKEN" BP_COLOR=none \
    bp fleet roster -o table 2>&1 || true)"
  say "      \$ bp fleet roster -o table   (BARKPARK_SERVER=<scratch> BP_COLOR=none)"
  printf '%s\n' "$BP_OUT" | sed 's/^/      /' | head -20
  pass 5 "bp CLI output recorded above (best-effort — an old installed binary may not speak the fleet manifest yet; that is recorded, never a proof failure)"
else
  pass 5 "bp not on PATH — recorded and skipped (best-effort by design)"
fi

# ── RUNG 6 — TEARDOWN ────────────────────────────────────────────────────────

head_rung 6 "TEARDOWN — reap the survivor, tear the target down clean"

if group_alive "$W2_PGID"; then
  kill -TERM -- "-$W2_PGID" 2>/dev/null || true
  sleep 0.5
  group_alive "$W2_PGID" && { kill -KILL -- "-$W2_PGID" 2>/dev/null || true; sleep 0.3; }
fi
wait "$W2_PID" 2>/dev/null || true
if group_alive "$W2_PGID"; then
  fail 6 "the survivor group $W2_PGID would not die — refusing to tear down under it"
  exit 1
fi
info "survivor group $W2_PGID reaped"

TD_LOG="${TMPDIR:-/tmp}/pdf-teardown.$$.log"
TD_RC=0
"$SCRATCH_SCRIPT" teardown >"$TD_LOG" 2>&1 || TD_RC=$?
sed 's/^/      /' "$TD_LOG"
TEARDOWN_DONE=1

PORT4000_AFTER="$(port4000_snapshot)"
info "host :4000 listeners — before: '${PORT4000_BEFORE:-none}' · after: '${PORT4000_AFTER:-none}'"

if [ "$TD_RC" -ne 0 ] || ! grep -q 'teardown: PASS' "$TD_LOG"; then
  rm -f "$TD_LOG"
  fail 6 "pds-scratch-target teardown did NOT pass (exit $TD_RC) — see its output above; the scratch root may be left for diagnosis"
  exit 1
fi
rm -f "$TD_LOG"
if [ "$PORT4000_BEFORE" != "$PORT4000_AFTER" ]; then
  fail 6 "the host's :4000 listener set CHANGED across the run ('$PORT4000_BEFORE' -> '$PORT4000_AFTER') — the isolation promise broke"
  exit 1
fi
pass 6 "teardown PASS (ports released, zero orphan postgres, scratch root removed); host :4000 untouched"

# ── verdict ──────────────────────────────────────────────────────────────────

say ""
rule
say "VERDICT — $MODE: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL"
if [ "$MODE" = "negctl" ]; then
  say "NEGCTL OK — the offline check is a real instrument: it fired as a failure"
  say "the moment the corpse was kept alive by beats."
else
  say "The corpse flipped OFFLINE exactly at its TTL boundary (first offline poll"
  say "at elapsed=${FIRST_OFFLINE_ELAPSED}s against ttl_s=$TTL_S, boundary $OFFLINE_EDGE) and not before; the"
  say "survivor stayed present and non-offline at every poll. Presence is a"
  say "heartbeat; stale IS offline; fail-closed (PDF-D6/D17/D20)."
fi
rule
exit 0
