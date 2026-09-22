#!/usr/bin/env bash
# dispatch-cap-gate.test.sh — arms for the WIRING of spend-aggregate.py into the
# dispatch cap gate (.claude/skills/fleet-orchestrator/helpers/dispatch.sh).
#
# WHAT THIS GUARDS (task-8a1f525034614c34, follow-up to PR #18915).
# The cap gate used to read ONE file, $FLEET_HOME/orchestrator/spend.jsonl, which
# NOTHING writes: the only producer, record_spend in tooling/fleet/fleet-run.sh,
# appends to $FLEET_HOME/<worker>/spend.jsonl. A missing file summed to $0.00 and the
# gate printed "dispatch allowed" forever. Two separate defects, two separate arms:
#   A2  AGGREGATION — a per-worker ledger must reach the total. REDS on a revert to
#       the inline single-file reader (which sees only the orchestrator file).
#   A4  CANNOT READ — no readable ledger + a cap set must REFUSE (exit 13) and must
#       NOT print "dispatch allowed". REDS on a revert AND on any handler that
#       collapses exit 13 into a zero.
# The remaining arms are the quiet controls: they must stay green across both
# mutations, so a red in A2/A4 cannot be dismissed as "the harness broke".
#
# No server, no network: FLEET_ROSTER_JSON stubs the roster and
# FLEET_FILE_ORDER_BIN stubs the filer (the same seams scripts/pdf-efficiency-proof.sh
# uses). Run:  bash tooling/fleet/dispatch-cap-gate.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH="${DISPATCH_SH:-$REPO_ROOT/.claude/skills/fleet-orchestrator/helpers/dispatch.sh}"
[ -f "$DISPATCH" ] || { echo "FATAL: dispatch.sh not found at $DISPATCH"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-capgate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0

NOW_ISO="$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
ROSTER="$WORK/roster.json"
printf '{"documents":[{"worker":"capgate-stub","status":"idle","ttl_s":900,"last_seen":"%s","capacity":{"size_class":"xl","slots_total":2,"slots_free":2}}]}' "$NOW_ISO" > "$ROSTER"
ORDERS="$WORK/orders.json"
printf '[{"id":"capgate-o1","klass":"light"}]' > "$ORDERS"

FILER="$WORK/filer.sh"
FILER_LOG="$WORK/filer.log"
cat > "$FILER" <<'FILERSH'
#!/usr/bin/env bash
echo "FILED $1" >> "$FILER_LOG"
FILERSH
chmod +x "$FILER"

# run_dispatch <fleet_home> <cap-or-empty> -> RC, OUT (combined stdout+stderr)
RC=0; OUT_FILE="$WORK/out.txt"
run_dispatch() {
  local fh="$1" cap="${2:-}" out="$OUT_FILE"
  : > "$FILER_LOG"
  FLEET_HOME="$fh" FLEET_ROSTER_JSON="$ROSTER" FLEET_FILE_ORDER_BIN="$FILER" \
    FILER_LOG="$FILER_LOG" FLEET_SPEND_CAP="$cap" \
    bash "$DISPATCH" "$ORDERS" >"$out" 2>&1
  RC=$?
}

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; printf '        rc=%s\n' "$RC"; sed 's/^/        | /' "$OUT_FILE"; }
# The asserts grep the CAPTURED FILE, never `printf "$OUT" | grep -q`: under `pipefail`
# a `grep -q` that matches early closes the pipe, printf takes SIGPIPE and the pipeline
# reports 141 — an assert that flips to FAIL on a line that is plainly present. That
# exact flake bit this file twice before the pipe came out.
want_rc()      { [ "$RC" = "$1" ] || { bad "$2 (wanted rc=$1)"; return 1; }; return 0; }
want_line()    { grep -qF -- "$1" "$OUT_FILE" || { bad "$2 (missing line: $1)"; return 1; }; return 0; }
reject_line()  { grep -qF -- "$1" "$OUT_FILE" && { bad "$2 (forbidden line present: $1)"; return 1; }; return 0; }
arm() { printf '\nARM %s\n' "$1"; }

mk_home() { local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }

# ── A1 — a real total from the orchestrator's own ledger (the legacy path still works)
arm "A1 orchestrator ledger 1.25 + a canonical cost_usd:null skip-row, cap 100"
H="$(mk_home a1)"; mkdir -p "$H/orchestrator"
printf '%s\n%s\n' \
  '{"ts":"2026-07-23T00:00:00Z","order_id":"a1","agent":"t","cost_usd":1.25}' \
  '{"ts":"2026-07-23T00:00:01Z","order_id":"a1n","agent":"t","cost_usd":null}' > "$H/orchestrator/spend.jsonl"
run_dispatch "$H" "100"
want_rc 0 "A1" && want_line 'cap gate: spent $1.2500 of cap $100 — dispatch allowed' "A1" \
  && ok "A1 orchestrator-only ledger sums to 1.2500, null row skipped"

# ── A2 — AGGREGATION: a PER-WORKER ledger reaches the total (reds on revert)
arm "A2 per-worker ledger 2.00 + orchestrator 1.00 = 3.0000, cap 100"
H="$(mk_home a2)"; mkdir -p "$H/orchestrator" "$H/capgate-stub"
printf '%s\n' '{"ts":"2026-07-23T00:00:00Z","order_id":"a2o","agent":"t","cost_usd":1.00}' > "$H/orchestrator/spend.jsonl"
printf '%s\n' '{"ts":"2026-07-23T00:00:00Z","order_id":"a2w","agent":"t","cost_usd":2.00}' > "$H/capgate-stub/spend.jsonl"
run_dispatch "$H" "100"
want_rc 0 "A2" && want_line 'cap gate: spent $3.0000 of cap $100 — dispatch allowed' "A2" \
  && ok "A2 the per-worker ledger record_spend actually writes IS in the total (3.0000, not 1.0000)"

# ── A3 — a present-but-EMPTY ledger is a real, readable zero
arm "A3 present-but-empty ledger, cap 5.00 — a real read zero, dispatch proceeds"
H="$(mk_home a3)"; mkdir -p "$H/orchestrator"; : > "$H/orchestrator/spend.jsonl"
run_dispatch "$H" "5.00"
want_rc 0 "A3" && want_line 'cap gate: spent $0.0000 of cap $5.00 — dispatch allowed' "A3" \
  && reject_line 'CANNOT READ' "A3" && ok "A3 an empty file is 0.0000 READ, not CANNOT READ"

# ── A4 — CANNOT READ (the reject anchors on 'cap gate: spent', the gate's VERDICT
#        prefix: the aggregator's refusal text itself quotes "never 'dispatch allowed'"
#        and "NOT $0.00 spent", so a grep for those matches its own retraction): no ledger anywhere + a cap set must REFUSE (reds on revert)
arm "A4 empty FLEET_HOME (no ledger at all), cap 5.00 — CANNOT READ, refuse"
H="$(mk_home a4)"
run_dispatch "$H" "5.00"
want_rc 13 "A4" \
  && want_line 'cap gate: CANNOT READ the spend ledger set under' "A4" \
  && want_line 'dispatch REFUSED, 0 orders placed' "A4" \
  && reject_line 'cap gate: spent' "A4" \
  && { [ ! -s "$FILER_LOG" ] || { bad "A4 (the filer ran under a CANNOT READ refusal)"; false; }; } \
  && ok "A4 an absent ledger set refuses (exit 13) — no \$0.00, no 'dispatch allowed', nothing filed"

# ── A5 — MALFORMED is a named abort, no cap set (the read is unconditional)
arm "A5 non-numeric cost_usd, NO cap set — named abort exit 12"
H="$(mk_home a5)"; mkdir -p "$H/orchestrator"
printf '%s\n' '{"ts":"2026-07-23T00:00:00Z","order_id":"a5","agent":"t","cost_usd":"twelve"}' > "$H/orchestrator/spend.jsonl"
run_dispatch "$H" ""
want_rc 12 "A5" \
  && want_line "MALFORMED_SPEND_LEDGER_ROW" "A5" \
  && want_line "non-numeric 'cost_usd'" "A5" \
  && want_line "ABORT: MALFORMED_SPEND_LEDGER under" "A5" \
  && reject_line " → " "A5" \
  && { [ ! -s "$FILER_LOG" ] || { bad "A5 (the filer ran during a malformed abort)"; false; }; } \
  && ok "A5 garbage is refused BY NAME — never spend=0, never spend=inf, nothing filed"

# ── A6 — non-UTF-8 ledger: still 12, NEVER decoded with errors='replace'
arm "A6 non-UTF-8 ledger bytes — malformed abort, not a coerced U+FFFD parse"
H="$(mk_home a6)"; mkdir -p "$H/orchestrator"
printf '{"ts":"x","cost_usd":1.0,"agent":"\xff\xfe"}\n' > "$H/orchestrator/spend.jsonl"
run_dispatch "$H" "100"
want_rc 12 "A6" && reject_line 'dispatch allowed' "A6" \
  && ok "A6 undecodable bytes abort — no errors='replace' coercion of a brake input"

# ── A7 — cap TRIPPED: the freeze still fires through the aggregator
arm "A7 ledger 2.50 + 2.50 across two ledgers, cap 5.00 — freeze"
H="$(mk_home a7)"; mkdir -p "$H/orchestrator" "$H/capgate-stub"
printf '%s\n' '{"ts":"t","order_id":"a7o","agent":"t","cost_usd":2.50}' > "$H/orchestrator/spend.jsonl"
printf '%s\n' '{"ts":"t","order_id":"a7w","agent":"t","cost_usd":2.50}' > "$H/capgate-stub/spend.jsonl"
run_dispatch "$H" "5.00"
want_rc 0 "A7" \
  && want_line 'SPEND CAP REACHED ($5.0000 >= $5.00) — dispatch halted, 0/1 orders placed' "A7" \
  && { [ ! -s "$FILER_LOG" ] || { bad "A7 (the filer ran under a tripped cap)"; false; }; } \
  && ok "A7 the cap trips on the AGGREGATED total and freezes (exit 0, nothing filed)"

# ── A8 — LIVE RE-READ: truncate in place, the freeze lifts on the next batch (R6 shape)
arm "A8 truncate the tripped ledgers IN PLACE — freeze lifts, no restart"
: > "$H/orchestrator/spend.jsonl"; : > "$H/capgate-stub/spend.jsonl"
run_dispatch "$H" "5.00"
want_rc 0 "A8" && reject_line 'SPEND CAP REACHED' "A8" \
  && want_line 'cap gate: spent $0.0000 of cap $5.00 — dispatch allowed' "A8" \
  && ok "A8 the in-place zero lifted the freeze — the aggregated read is live-per-batch"

# ── A9 — QUIET CONTROL: no cap set + no ledger — the capless path still dispatches
arm "A9 no cap, no ledger — cap gate off, dispatch proceeds, CANNOT READ noted not silent"
H="$(mk_home a9)"
run_dispatch "$H" ""
want_rc 0 "A9" \
  && want_line 'cap gate: no FLEET_SPEND_CAP set — batch cap gate off' "A9" \
  && want_line 'NO total was computed (CANNOT READ, not $0.00)' "A9" \
  && want_line 'capgate-o1 → capgate-stub (light)' "A9" \
  && ok "A9 with no cap the gate is OFF and says so — the wiring does not brick the capless path"

printf '\n%s\n' "-----------------------------------------------"
printf 'dispatch cap gate arms: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
