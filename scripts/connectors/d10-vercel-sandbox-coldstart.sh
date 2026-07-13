#!/usr/bin/env bash
# d10-vercel-sandbox-coldstart.sh — reproducible D10 cold-start harness (Connectors epic, Wave 2 / P1).
#
# D10 [RATIFIED, b27b05e1]: the Cloud sandbox runner = Vercel Sandbox (Firecracker
# microVM), snapshot-baked `claude` image + warm pool. This script RE-RUNS the
# decomposed cold-start measurement the Wave-2 verify fleet ran headless (vercel
# authed as frikk, everything torn down), so the numbers in the charter are
# reproducible rather than vibes. See .claude/workflows/bp-connectors-charter.md
# (D10, D21, D22, D23, D24) and the wave paper connectors-wave-2-2026-07-13.
#
# What it decomposes (all legs measured with the same clock so the exec
# round-trip floor cancels when subtracted):
#   floor      — exec round-trip floor: `true` x3, averaged (~2.70s). Subtract
#                this from any in-sandbox leg to isolate real in-VM work.
#   create     — fresh `vercel sandbox create` cold baseline (~7.54s).
#   npm        — per-boot `npm i -g @anthropic-ai/claude-code` (~7.50s wall).
#                create + per-boot-install ≈ 15s ⇒ the per-boot-install path is
#                DEAD (blows the UX target before the model even starts).
#   snapshot   — `vercel sandbox snapshot <vm> --stop` bake (~5.52s, ONE-TIME,
#                off the hot path — this is why snapshot+warm-pool wins).
#   fromSnap   — create-from-snapshot `vercel sandbox create --snapshot <id>`
#                (~3.02s) + ~0.6s claude init ≈ 3.6s to claude-ready.
#   firstToken — model first-token in-sandbox. CREDENTIAL-GATED (D23): only a
#                valid ANTHROPIC_API_KEY can produce it, and this shell + the
#                guerrilla run-secrets do NOT have one. If the key is set we run
#                the exact human-gated command and report the number; if it is
#                unset we PRINT that command and exit 0 — we NEVER fabricate a
#                number (distrust vacuous green).
#
# The script ALWAYS tears down every sandbox and snapshot it creates (EXIT trap),
# even on error or Ctrl-C.
#
# Usage:
#   scripts/connectors/d10-vercel-sandbox-coldstart.sh --check   # lint/plan only, provisions NOTHING (this is what the gate runs)
#   scripts/connectors/d10-vercel-sandbox-coldstart.sh           # LIVE: provisions + measures + tears down (needs `vercel` authed; costs money+minutes)
#   ANTHROPIC_API_KEY=sk-ant-... scripts/connectors/d10-vercel-sandbox-coldstart.sh   # LIVE + runs the D23 first-token leg
#
set -uo pipefail
export LC_ALL=C   # deterministic '.' decimal separator in awk/printf, any host locale

SCRIPT_NAME="d10-vercel-sandbox-coldstart.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"

# ── Reference numbers (Wave-2 verify fleet, headless, vercel authed as frikk, all torn down). ──
# These are the charter's published (b27b05e1) measurements. A live run fills the
# "this run" column beside them; --check prints these alone.
REF_FLOOR="2.70"
REF_CREATE="7.54"
REF_NPM="7.50"
REF_SNAPSHOT="5.52"
REF_FROM_SNAP="3.02"
REF_CLAUDE_INIT="0.60"   # in-VM claude process init; charter "≈3.6s to claude-ready"

# ── The exact D23 human-gated first-token command (single source of truth — printed
#    verbatim when the key is unset, run verbatim when it is set; no drift, no fake number).
d23_command() {
  local vm="${1:-<SNAPSHOT_VM>}"
  # SC2016: the literal $ANTHROPIC_API_KEY is INTENTIONAL — it is the command a
  # human runs, not an expansion here (we never echo the real key).
  # shellcheck disable=SC2016
  printf 'vercel sandbox exec %s --env ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY -- bash -lc '\''time claude -p "say ok"'\''\n' "$vm"
}

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — reproducible D10 (Vercel Sandbox) cold-start harness.

  --check    lint + print the measurement plan and reference table; provisions
             NO sandbox and calls NO API (this is what the CI gate runs).
  --help     this text.

With no flag it runs LIVE: it needs the \`vercel\` CLI authenticated, provisions
real sandboxes+snapshots (billable, ~1 minute), measures each leg, prints a
decomposed table, and tears everything down on exit.

D23 first-token leg: set ANTHROPIC_API_KEY to run it; unset, the script prints
the exact command and exits 0 (never a fabricated number).

Charter: $CHARTER (D10, D21, D22, D23, D24).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  "") CHECK_ONLY=0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# ── High-resolution clock (portable: python3 → perl → GNU date → integer date). ──
now_s() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time;print("%.3f"%time.time())'
  elif command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
  elif date +%s.%N 2>/dev/null | grep -Eq '\.[0-9]'; then
    date +%s.%N
  else
    date +%s
  fi
}

elapsed() { # elapsed START END -> seconds, 2dp
  awk -v a="$1" -v b="$2" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.2f", d}'
}

# ── Resource tracking + teardown (fires on any exit, including error / Ctrl-C). ──
SANDBOXES=()
SNAPSHOTS=()

cleanup() {
  local rc=$?
  set +e
  if [ "${#SANDBOXES[@]}" -gt 0 ]; then
    echo "==> teardown: removing ${#SANDBOXES[@]} sandbox(es): ${SANDBOXES[*]}" >&2
    vercel sandbox remove "${SANDBOXES[@]}" >/dev/null 2>&1 \
      || echo "    warn: 'vercel sandbox remove' returned nonzero (may already be gone)" >&2
  fi
  if [ "${#SNAPSHOTS[@]}" -gt 0 ]; then
    echo "==> teardown: deleting ${#SNAPSHOTS[@]} snapshot(s): ${SNAPSHOTS[*]}" >&2
    vercel sandbox snapshots delete "${SNAPSHOTS[@]}" >/dev/null 2>&1 \
      || echo "    warn: 'vercel sandbox snapshots delete' returned nonzero" >&2
  fi
  exit $rc
}
trap cleanup EXIT

# ── Table rendering. ──
hr()  { printf '  %-34s %14s %14s\n' "$1" "$2" "$3"; }
line() { printf '  %s\n' "--------------------------------------------------------------"; }

print_table() {
  # print_table <mode>  — mode "ref" prints only the reference column.
  local mode="$1"
  local c_floor c_create c_npm c_snap c_from c_ready
  if [ "$mode" = "live" ]; then
    c_floor="${M_FLOOR:-n/a}"
    c_create="${M_CREATE:-n/a}"
    c_npm="${M_NPM:-n/a}"
    c_snap="${M_SNAPSHOT:-n/a}"
    c_from="${M_FROM_SNAP:-n/a}"
    c_ready=$(awk -v a="${M_FROM_SNAP:-0}" -v b="$REF_CLAUDE_INIT" 'BEGIN{printf "%.2f", a+b}')
  else
    c_floor="-"; c_create="-"; c_npm="-"; c_snap="-"; c_from="-"; c_ready="-"
  fi
  echo ""
  hr "leg" "reference(s)" "this run(s)"
  line
  hr "exec round-trip floor (true x3 avg)" "$REF_FLOOR" "$c_floor"
  hr "fresh create (cold baseline)"        "$REF_CREATE" "$c_create"
  hr "per-boot npm i -g claude-code"       "$REF_NPM"    "$c_npm"
  hr "snapshot bake (--stop, one-time)"    "$REF_SNAPSHOT" "$c_snap"
  hr "create-from-snapshot"                "$REF_FROM_SNAP" "$c_from"
  hr "  + claude init (~in-VM)"            "$REF_CLAUDE_INIT" "-"
  line
  hr "=> claude-ready from snapshot"       "$(awk -v a="$REF_FROM_SNAP" -v b="$REF_CLAUDE_INIT" 'BEGIN{printf "%.2f", a+b}')" "$c_ready"
  echo ""
  echo "  Verdict: create + per-boot-install ($(awk -v a="$REF_CREATE" -v b="$REF_NPM" 'BEGIN{printf "%.2f", a+b}')s) is DEAD (~15s);"
  echo "           snapshot-from-warm-pool (~$(awk -v a="$REF_FROM_SNAP" -v b="$REF_CLAUDE_INIT" 'BEGIN{printf "%.2f", a+b}')s to claude-ready) is the D10 winner."
  echo "  in-VM work on any exec leg = leg - floor (floor is CLI round-trip, ~${REF_FLOOR}s)."
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN (--check: nothing is provisioned, no API is called)

Reference numbers are the Wave-2 verify-fleet measurement (headless, vercel authed
as frikk, all resources torn down), recorded in charter D10 (b27b05e1).

A LIVE run would execute, in order (each leg wall-clocked with a shared hi-res clock):

  1. floor    : vercel sandbox create  (--runtime node24 --timeout 10m --tag purpose=d10-coldstart)
                then: vercel sandbox exec <vm> -- true      (x3, averaged  -> floor)
  2. create   : the create above IS the cold-baseline measurement
  3. npm      : vercel sandbox exec <vm> -- npm i -g @anthropic-ai/claude-code
  4. snapshot : vercel sandbox snapshot <vm> --stop          (-> snapshot id)
  5. fromSnap : vercel sandbox create --snapshot <id> \\
                  --network-policy deny-all --allowed-domain api.anthropic.com   (D5/D24 isolation shape)
  6. firstTok : D23 CREDENTIAL-GATED — see command below.

Teardown (ALWAYS, via EXIT trap):
  vercel sandbox remove <all-created-vms>
  vercel sandbox snapshots delete <all-created-snapshots>

D23 human-gated first-token command (run verbatim when ANTHROPIC_API_KEY is set,
printed verbatim — never faked — when it is unset):

  $(d23_command)
EOF
  print_table ref
}

# ── LIVE legs (only reached when CHECK_ONLY=0). ──
require_vercel_auth() {
  if ! command -v vercel >/dev/null 2>&1; then
    echo "ERROR: 'vercel' CLI not found on PATH. Install it and 'vercel login' first." >&2
    exit 1
  fi
  if ! vercel whoami >/dev/null 2>&1; then
    echo "ERROR: 'vercel' is not authenticated. Run 'vercel login' (or 'vercel sandbox login')." >&2
    exit 1
  fi
  echo "==> vercel authenticated as: $(vercel whoami 2>/dev/null | tail -1)"
}

leg_create() {
  local s e
  echo "==> [1/6] fresh create (cold baseline) ..."
  s=$(now_s)
  SB_FRESH=$(vercel sandbox create --runtime node24 --timeout 10m --tag purpose=d10-coldstart)
  e=$(now_s)
  if [ -z "${SB_FRESH:-}" ]; then echo "ERROR: create returned no sandbox name" >&2; exit 1; fi
  SANDBOXES+=("$SB_FRESH")
  M_CREATE=$(elapsed "$s" "$e")
  echo "    sandbox=$SB_FRESH  create=${M_CREATE}s"
}

leg_floor() {
  local s e d sum="0"
  echo "==> [2/6] exec round-trip floor (true x3) ..."
  for _ in 1 2 3; do
    s=$(now_s); vercel sandbox exec "$SB_FRESH" -- true >/dev/null 2>&1; e=$(now_s)
    d=$(elapsed "$s" "$e")
    sum=$(awk -v a="$sum" -v b="$d" 'BEGIN{printf "%.2f", a+b}')
  done
  M_FLOOR=$(awk -v s="$sum" 'BEGIN{printf "%.2f", s/3}')
  echo "    floor=${M_FLOOR}s (avg of 3)"
}

leg_npm() {
  local s e
  echo "==> [3/6] per-boot npm i -g @anthropic-ai/claude-code ..."
  s=$(now_s); vercel sandbox exec "$SB_FRESH" -- npm i -g @anthropic-ai/claude-code >/dev/null 2>&1; e=$(now_s)
  M_NPM=$(elapsed "$s" "$e")
  echo "    npm(wall)=${M_NPM}s  in-VM=$(awk -v a="$M_NPM" -v f="$M_FLOOR" 'BEGIN{printf "%.2f", a-f}')s"
}

leg_snapshot() {
  local s e
  echo "==> [4/6] snapshot bake (--stop) ..."
  s=$(now_s); SNAP_ID=$(vercel sandbox snapshot "$SB_FRESH" --stop); e=$(now_s)
  if [ -z "${SNAP_ID:-}" ]; then echo "ERROR: snapshot returned no id" >&2; exit 1; fi
  SNAPSHOTS+=("$SNAP_ID")
  M_SNAPSHOT=$(elapsed "$s" "$e")
  echo "    snapshot=$SNAP_ID  bake=${M_SNAPSHOT}s"
}

leg_from_snapshot() {
  local s e
  echo "==> [5/6] create-from-snapshot (deny-all + allow api.anthropic.com) ..."
  s=$(now_s)
  SB_SNAP=$(vercel sandbox create --snapshot "$SNAP_ID" \
            --network-policy deny-all --allowed-domain api.anthropic.com --timeout 10m)
  e=$(now_s)
  if [ -z "${SB_SNAP:-}" ]; then echo "ERROR: create-from-snapshot returned no sandbox name" >&2; exit 1; fi
  SANDBOXES+=("$SB_SNAP")
  M_FROM_SNAP=$(elapsed "$s" "$e")
  echo "    sandbox=$SB_SNAP  fromSnap=${M_FROM_SNAP}s"
}

leg_first_token() {
  echo "==> [6/6] D23 first-token leg ..."
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "    ANTHROPIC_API_KEY present — running the human-gated command in $SB_SNAP:"
    echo "    $(d23_command "$SB_SNAP")"
    local s e
    s=$(now_s)
    vercel sandbox exec "$SB_SNAP" --env "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" -- bash -lc 'time claude -p "say ok"'
    e=$(now_s)
    M_FIRST_TOKEN=$(elapsed "$s" "$e")
    echo "    first-token wall (incl. exec round-trip ~${M_FLOOR:-$REF_FLOOR}s): ${M_FIRST_TOKEN}s"
  else
    echo "    ANTHROPIC_API_KEY UNSET — the first-token number is human-gated (D23)."
    echo "    Run this exact command from a host that has a valid key (nothing further is provisioned here):"
    echo ""
    echo "    $(d23_command "$SB_SNAP")"
    echo ""
    echo "    (No number is reported for this leg — a fabricated one would be a lie. D23.)"
  fi
}

main() {
  echo "== D10 Vercel Sandbox cold-start harness =="
  echo "== charter: $CHARTER (D10/D21/D22/D23/D24) =="

  if [ "$CHECK_ONLY" -eq 1 ]; then
    print_plan
    echo ""
    echo "--check OK: plan linted, nothing provisioned."
    return 0
  fi

  require_vercel_auth
  leg_create
  leg_floor
  leg_npm
  leg_snapshot
  leg_from_snapshot
  print_table live
  leg_first_token
  echo ""
  echo "== done (teardown runs on exit) =="
}

main
