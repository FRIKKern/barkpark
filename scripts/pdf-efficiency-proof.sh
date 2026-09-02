#!/usr/bin/env bash
#
# pdf-efficiency-proof.sh — THE PERSONAL DEV FLEET EFFICIENCY PROOF
# (PDF-D42/D54: the wave-B seal — measured heartbeats drive routing, the spend
# cap halts dispatch, and every check is proven able to fail).
#
#   scripts/pdf-efficiency-proof.sh --plan     print every rung, its assert and
#                                              the fixtures. NO side effects,
#                                              always exit 0.
#   scripts/pdf-efficiency-proof.sh            the proof: two stub listeners
#                                              beat genuinely different measured
#                                              profiles; a mixed batch lands
#                                              heavy-on-big + light-on-lean from
#                                              the LIVE roster; swapping the
#                                              capacities (names constant) FLIPS
#                                              the assignment; a tripped spend
#                                              cap freezes dispatch (zero filed);
#                                              an in-place ledger zero lifts the
#                                              freeze with NO restart; a
#                                              malformed ledger row is a NAMED
#                                              abort, never a coerced number.
#   scripts/pdf-efficiency-proof.sh --negctl   the negative control: identical
#                                              capacities on both listeners —
#                                              the R3 swap-flip assert must FIRE
#                                              AS A FAILURE (assignment must NOT
#                                              flip). A check that cannot fail
#                                              proves nothing (PDS-D20).
#   scripts/pdf-efficiency-proof.sh --help
#
# WHAT IT PROVES (its merged transcript stamps the epic's criterion 2, PDF-D33):
# the efficiency loop is LIVE — structured capacity heartbeats round-trip
# through /v1/fleet/beat -> roster -> dispatch.sh -> transform.py -> route.py,
# routing follows CONTENT (capacity), not identity (names), and the
# FLEET_SPEND_CAP brake reads $FLEET_HOME/orchestrator/spend.jsonl (dialect
# cost_usd, PDF-D54 pin 1) live on EVERY batch, failing loud on garbage.
#
# THE THREE OUTCOMES (the pds-pull-proof.sh ladder, verbatim — no fourth, no
# silent skip):
#   PASS   the rung ran and every assertion held.
#   ABORT  the rung cannot run (e.g. this tree does not serve /v1/fleet/*, or
#          the merged dispatch.sh does not read the pinned ledger path/dialect
#          — a substrate or merge-order problem, never a routing verdict).
#   FAIL   the rung ran and an assertion did NOT hold.
# Exit: 0 = every rung PASSed (in --negctl: the swap-flip assert FIRED as a
# failure, which is that mode's pass). 1 = FAIL. 2 = ABORT. 3 = usage error.
#
# SUBSTRATE (PDF-D29/D45, inherited verbatim from pdf-kill-listener-proof.sh):
#   · Run from a FRESH origin/main worktree (both #5685 capacity-contract and
#     #5687 dispatch-glue must be merged in — R0 ABORTs otherwise).
#   · The target is a disposable scratch instance booted from THIS tree by
#     scripts/pds-scratch-target.sh. BARKPARK_HOME defaults to a SHORT mktemp
#     root (/tmp/pdf.XXXX) and PDS_SCRATCH_POINTER is PINNED per-run to
#     $BARKPARK_HOME/pointer — NEVER the global /tmp/pds-scratch-target.last.
#     Cold boot budget 15 min (PDF-D29 measured 311.7s); warm ~13-33s.
#     CC=/usr/bin/clang is exported for any compile (cc is a shadowed alias).
#   · dispatch.sh / route.py / transform.py stay BYTE-UNTOUCHED: the harness
#     rides the merged FLEET_ROSTER_JSON + FLEET_FILE_ORDER_BIN seams only.
#   · Filing is DRAFT-ONLY (createOrReplace via POST /v1/data/mutate/production
#     with the scratch bearer; census perspective=raw WITH the bearer; cleanup
#     via delete {id,type}) — a fresh scratch has ZERO registered tags, so the
#     publish wall would 422 (PDF-D42); the stub filer ALWAYS exits 0 (pin 3).
#   · Teardown must PASS (both ports released, zero orphan postgres for THIS
#     root only — foreign pds.* orphans exist on the host) and the host's
#     :4000 listener set must be untouched across the whole run.
#
# Environment (all optional; --plan prints the defaults):
#   BARKPARK_HOME        scratch root — minted per run when unset (short!)
#   PDS_SCRATCH_POINTER  pointer file — defaults to $BARKPARK_HOME/pointer
#   PDF_TTL_S            stub-listener self-declared ttl_s (default 30)
#   PDF_BEAT_EVERY       stub-listener beat cadence, seconds (default 2)
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail
# set -m FIRST (PDF-D28): job control gives each backgrounded stub listener its
# OWN process group — the reap in teardown is group-wide and straggler-proof.
set -m

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"
SCRATCH_SCRIPT="$SCRIPT_DIR/pds-scratch-target.sh"
HELPERS_DIR="$REPO_ROOT/.claude/skills/fleet-orchestrator/helpers"
DISPATCH_SH="$HELPERS_DIR/dispatch.sh"

# ── fixtures (PDF-D54 — transcribed, not explored) ───────────────────────────
#
# Two stub listeners with GENUINELY DIFFERENT measured profiles (D42): the
# big box declares xl + a high budget, the lean laptop light + a low budget.
# One extra row is beaten ONCE with ttl_s=1 and left to go stale: the
# status:offline roster row whose dispatch exclusion print R2 must capture
# (PDF-D38 / D54 pin 7).
TTL_S="${PDF_TTL_S:-30}"
BEAT_EVERY="${PDF_BEAT_EVERY:-2}"
GHOST_TTL=1

BIG="pdf-big-box"
LEAN="pdf-lean-laptop"
GHOST="pdf-parked-ghost"

CAP_BIG='{"size_class":"xl","slots_total":1,"slots_free":1,"budget":100}'
CAP_LEAN='{"size_class":"light","slots_total":1,"slots_free":1,"budget":3}'
CAP_GHOST='{"size_class":"standard","slots_total":1,"slots_free":1}'

# The spend cap and the ledger rows that trip it. The trip ledger sums to
# EXACTLY the cap: the compare is `spent >= cap` (D54 pin 4) and this proves
# the boundary, not just the overshoot.
CAP_USD="5.00"
TRIP_ROW_A='{"ts":"2026-07-23T00:00:01Z","order_id":"seed-a","agent":"pdf-proof","cost_usd":2.50}'
TRIP_ROW_B='{"ts":"2026-07-23T00:00:02Z","order_id":"seed-b","agent":"pdf-proof","cost_usd":2.50}'
UNDER_ROW='{"ts":"2026-07-23T00:00:03Z","order_id":"seed-c","agent":"pdf-proof","cost_usd":2.50}'
MALFORMED_ROW='{"ts":"2026-07-23T00:00:04Z","order_id":"seed-m","agent":"pdf-proof","cost_usd":"twelve"}'

# Order ids are run-scoped so the raw census can count OUR drafts and only ours.
OP="pdfp$$"

MODE="run"
case "${1:-}" in
  "")            MODE="run" ;;
  --plan)        MODE="plan" ;;
  --negctl)      MODE="negctl" ;;
  -h|--help)     sed -n '3,68p' "$0"; exit 0 ;;
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

R_FAILS=0
efail() { R_FAILS=$((R_FAILS + 1)); say "      ASSERT-FAIL: $*"; }
rung_seal() { # n summary — FAIL+exit if any efail fired, else PASS and reset
  if [ "$R_FAILS" -gt 0 ]; then
    fail "$1" "$2 — $R_FAILS assertion(s) failed (see the ASSERT-FAIL lines above)"
    exit 1
  fi
  pass "$1" "$2"
}

# ── small tools ──────────────────────────────────────────────────────────────

pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
group_alive() { ps -Ao pgid= 2>/dev/null | awk -v g="$1" '$1 == g {found=1} END{exit !found}'; }
port4000_snapshot() { lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null | sort | tr '\n' ' ' | sed 's/ *$//'; }

canon_json() { # compact, key-sorted JSON of the argument (for map equality)
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))'
}

# ── target plumbing (everything comes from scratch.env via the PINNED pointer)

TARGET_BASE=""; TARGET_TOKEN=""

curl_beat() { # worker status ttl_s capacity_json -> response body on stdout
  curl -sS --max-time 5 -X POST "$TARGET_BASE/v1/fleet/beat" \
    -H "Authorization: Bearer $TARGET_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"worker\":\"$1\",\"status\":\"$2\",\"ttl_s\":$3,\"capacity\":$4}"
}

curl_roster() { # -> body on stdout
  curl -sS --max-time 10 -H "Authorization: Bearer $TARGET_TOKEN" \
    "$TARGET_BASE/v1/fleet/roster"
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

cap_of_worker() { # worker; roster JSON on stdin -> canonical capacity JSON, or ""
  W="$1" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("documents") or []:
    if r.get("worker") == os.environ["W"]:
        c = r.get("capacity")
        if isinstance(c, dict):
            print(json.dumps(c, sort_keys=True))
        break'
}

status_of_worker() { # worker; roster JSON on stdin -> status, or ""
  W="$1" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("documents") or []:
    if r.get("worker") == os.environ["W"]:
        print(r.get("status") or "")
        break'
}

# >>> CENSUS-WALK BEGIN (extracted VERBATIM by scripts/pdf-efficiency-proof.test.sh)
#
# THE RAW-TASK CENSUS — PAGE TO EXHAUSTION, OR REFUSE. Never a number taken from
# one capped read.
#
# The query API's contract (api/lib/barkpark_web/controllers/query_controller.ex,
# `query_index/4` + `maybe_put_total/7`): `limit` clamps to [1,1000] (default
# 100), `offset` clamps to [0,100_000], every page carries `result.hasMore`, and
# `?count=true` adds `result.total` — the UNPAGINATED count for exactly this
# type + perspective + filter.
#
# WHAT THIS REPLACED: a single `?perspective=raw&limit=1000` GET whose rows were
# grepped client-side and printed as a census. Measured against the live ledger
# 2026-08-22 that read returned 1000 rows of 7527 (13.3%); measured again
# 2026-09-01 it returns 1000 of 8447 (11.8%). A draft sorting past position 1000
# was invisible, and the census printed "0" — the SAME "0" a run that filed
# nothing prints. Truncation and absence were indistinguishable at the call site,
# so the proof could not fail on a miss. Never raise the cap: a raised cap
# truncates again silently at the new number (the PR #11438 / #13011 pattern).
#
# FIVE NAMED REFUSALS, each asserting NOTHING about the census — a check that
# cannot lose proves nothing (PDS-D20):
#   CENSUS-UNPARSEABLE   a page was not a documents envelope, on any attempt
#   CENSUS-NO-TOTAL      ?count=true was asked for and no `total` came back
#   CENSUS-PAGE-OVERRUN  the pages never went short — more pages than `total`
#                        can hold, so the walk has no end
#   CENSUS-DUP-ROWS      an id repeated across pages (the window shifted under
#                        the walk, so something also fell through the seam)
#   CENSUS-TRUNCATED     rows walked < the server's own `total`
#
# SEAMS (the hermetic harness and a live re-measure drive this SAME text):
#   CENSUS_ID_PREFIX   server-side `filter[_id][contains]` AND the client-side
#                      match; set to "" for the whole type, unfiltered
#   CENSUS_PAGE_LIMIT  rows per page (the API clamps it to 1000)
#   CENSUS_MAX_PAGES   absolute page ceiling (offset itself clamps at 100_000)
#   CENSUS_PAGE_TRIES  attempts per page before CENSUS-UNPARSEABLE. A loaded
#                      server answers a deep-offset page with an intermittent
#                      500 (`DBConnection.ConnectionError`) — measured on
#                      guerrilla 2026-09-01 at roughly one request in three. A
#                      bounded retry is not a swallow: the cap is small, the
#                      refusal names it, and every OTHER refusal still fires on
#                      the first parseable page.
CENSUS_PAGE_LIMIT="${CENSUS_PAGE_LIMIT:-1000}"
CENSUS_MAX_PAGES="${CENSUS_MAX_PAGES:-200}"
CENSUS_PAGE_TRIES="${CENSUS_PAGE_TRIES:-6}"
CENSUS_ID_PREFIX="${CENSUS_ID_PREFIX-$OP-}"
CENSUS=""   # the ONLY output channel — census_ours must NOT run in a subshell,
            # or a refusal would exit that subshell and leave a number behind.
CENSUS_PARSED=""
CENSUS_HDR=""

census_refuse() { # NAME message — non-zero, BY NAME, asserting nothing
  say ""
  say "      $1: $2"
  say "      the census is NOT reported — a walk that cannot prove it read every"
  say "      row proves nothing about the rows it did read."
  exit 1
}

census_page() { # offset -> raw page body on stdout
  # `[`/`]` are percent-encoded: curl reads a bare `[...]` as a glob range and
  # refuses the URL ("bad range specification") before the server ever sees it.
  local off="$1" url
  url="$TARGET_BASE/v1/data/query/production/task?perspective=raw&count=true"
  url="$url&limit=$CENSUS_PAGE_LIMIT&offset=$off&order=_createdAt:asc"
  if [ -n "$CENSUS_ID_PREFIX" ]; then
    url="$url&filter%5B_id%5D%5Bcontains%5D=$CENSUS_ID_PREFIX"
  fi
  curl -sS --max-time 60 -H "Authorization: Bearer $TARGET_TOKEN" "$url"
}

census_fetch_page() { # offset — sets CENSUS_PARSED/CENSUS_HDR, or refuses
  local off="$1" attempt=0 body
  while :; do
    attempt=$((attempt + 1))
    body="$(census_page "$off")"
    # ONE python pass per page: a header line `OK<TAB>n<TAB>total`, then one
    # `M|X<TAB>id` line per returned row (M = matches the prefix).
    CENSUS_PARSED="$(printf '%s' "$body" | P="$CENSUS_ID_PREFIX" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("PARSE-FAIL"); sys.exit(0)
res = d.get("result", d) if isinstance(d, dict) else {}
docs = res.get("documents")
if not isinstance(docs, list):
    print("PARSE-FAIL"); sys.exit(0)
tot = res.get("total")
print("OK\t%d\t%s" % (len(docs), tot if isinstance(tot, int) else ""))
p = os.environ.get("P", "")
for x in docs:
    i = str(x.get("_id", "") if isinstance(x, dict) else "")
    print("%s\t%s" % ("M" if (p == "" or p in i) else "X", i))')"
    # NOT `| head -1`: pipefail + SIGPIPE turns an early-closing head into rc
    # 141, and `set -e` would kill the run mid-walk. Pure expansion, no pipe.
    CENSUS_HDR="${CENSUS_PARSED%%$'\n'*}"
    case "$CENSUS_HDR" in OK*) return 0 ;; esac
    [ "$attempt" -lt "$CENSUS_PAGE_TRIES" ] || census_refuse CENSUS-UNPARSEABLE "the page at offset $off (limit $CENSUS_PAGE_LIMIT) was not a documents envelope on any of $CENSUS_PAGE_TRIES attempt(s); last body: $(printf '%s' "$body" | tr -d '\n' | cut -c1-200)"
  done
}

census_ours() { # sets CENSUS to the count of raw task rows carrying the prefix
  local off=0 pages=0 walked=0 total=0 overrun=0 max_pages
  local ids n page_total distinct matched
  ids="$(mktemp "${WORKDIR:-${TMPDIR:-/tmp}}/census-ids.XXXXXX")"
  while :; do
    census_fetch_page "$off"
    n="$(printf '%s' "$CENSUS_HDR" | cut -f2)"
    page_total="$(printf '%s' "$CENSUS_HDR" | cut -f3)"
    [ -n "$page_total" ] || census_refuse CENSUS-NO-TOTAL "the page at offset $off was asked for ?count=true and came back with no integer \`total\` — without the server's own count a walk cannot know it finished"
    printf '%s\n' "$CENSUS_PARSED" | tail -n +2 >> "$ids"
    walked=$((walked + n))
    pages=$((pages + 1))
    total="$page_total"
    max_pages=$(( (page_total + CENSUS_PAGE_LIMIT - 1) / CENSUS_PAGE_LIMIT + 2 ))
    [ "$max_pages" -le "$CENSUS_MAX_PAGES" ] || max_pages="$CENSUS_MAX_PAGES"
    [ "$n" -ge "$CENSUS_PAGE_LIMIT" ] || break
    if [ "$pages" -ge "$max_pages" ]; then overrun=1; break; fi
    off=$((off + CENSUS_PAGE_LIMIT))
  done
  [ "$overrun" -eq 0 ] || census_refuse CENSUS-PAGE-OVERRUN "read $pages full page(s) of $CENSUS_PAGE_LIMIT ($walked rows) against a server-reported total of $total — the pages never went short, so this walk has no end and any count would be an artefact of where it gave up"
  [ "$walked" -ge "$total" ] || census_refuse CENSUS-TRUNCATED "walked $walked row(s) in $pages page(s) but the server reports total=$total for this read — $((total - walked)) row(s) were never looked at, and a row that was not read is indistinguishable from a row that is not there"
  distinct="$(cut -f2 "$ids" | sort -u | wc -l | tr -d ' ')"
  [ "$distinct" -eq "$walked" ] || census_refuse CENSUS-DUP-ROWS "walked $walked row(s) across $pages page(s) but only $distinct distinct id(s) — the page window shifted under the walk, so a row fell through the seam between two pages"
  matched="$(grep -c '^M' "$ids" 2>/dev/null || true)"
  [ -n "$matched" ] || matched=0
  rm -f "$ids"
  CENSUS="$matched"
  say "      census walk: $pages page(s) of $CENSUS_PAGE_LIMIT, $walked row(s) read, server total=$total, $matched carrying '${CENSUS_ID_PREFIX:-<no filter>}'"
}
# <<< CENSUS-WALK END

delete_doc() { # id type — dataset-in-path delete (PDF-D44d); body swallowed
  curl -sS --max-time 10 -X POST "$TARGET_BASE/v1/data/mutate/production" \
    -H "Authorization: Bearer $TARGET_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"mutations\":[{\"delete\":{\"id\":\"$1\",\"type\":\"$2\"}}]}" >/dev/null 2>&1 || true
}

cleanup_filed() { # delete both filed order drafts, assert census back to zero
  delete_doc "$OP-export" "task"
  delete_doc "$OP-lint" "task"
  local c
  census_ours; c="$CENSUS"
  info "cleanup: deleted $OP-export + $OP-lint — raw census now $c"
  [ "$c" = "0" ] || efail "cleanup left $c raw row(s) behind (want 0)"
}

# ── dispatch runner (the merged glue, byte-untouched, seam-driven) ───────────

DISP_OUT=""; DISP_RC=0

run_dispatch() { # orders_file roster_file cap_or_empty
  local orders="$1" roster="$2" cap="$3"
  DISP_OUT="$WORKDIR/dispatch-$RANDOM.out"
  set +e
  if [ -n "$cap" ]; then
    FLEET_HOME="$FLEET_HOME" FLEET_ROSTER_JSON="$roster" \
      FLEET_FILE_ORDER_BIN="$FILER" FLEET_SPEND_CAP="$cap" \
      bash "$DISPATCH_SH" "$orders" >"$DISP_OUT" 2>&1
  else
    env -u FLEET_SPEND_CAP FLEET_HOME="$FLEET_HOME" FLEET_ROSTER_JSON="$roster" \
      FLEET_FILE_ORDER_BIN="$FILER" \
      bash "$DISPATCH_SH" "$orders" >"$DISP_OUT" 2>&1
  fi
  DISP_RC=$?
  set -e
  sed 's/^/      | /' "$DISP_OUT"
}

expect_line() { grep -qF -- "$1" "$DISP_OUT" || efail "missing expected line: $1"; }
reject_line() { if grep -qF -- "$1" "$DISP_OUT"; then efail "line must NOT appear: $1"; fi; }

show_ledger() {
  if [ -s "$LEDGER" ]; then
    say "      ledger $LEDGER ($(wc -c < "$LEDGER" | tr -d ' ') bytes):"
    sed 's/^/        /' "$LEDGER"
  else
    say "      ledger $LEDGER: (empty or absent)"
  fi
}

pull_roster() { # dest — one LIVE roster snapshot for a dispatch run
  curl_roster > "$1"
  [ -s "$1" ] || { efail "live roster pull returned an empty body"; return 0; }
}

wait_roster_shape() { # bigcap leancap ghost_status ceiling_s -> 0 iff reached
  local bigc="$1" leanc="$2" gst="$3" ceiling="$4" i=0 body
  while [ "$i" -lt $((ceiling * 2)) ]; do
    body="$(curl_roster || true)"
    if [ "$(printf '%s' "$body" | cap_of_worker "$BIG")" = "$(canon_json "$bigc")" ] \
       && [ "$(printf '%s' "$body" | cap_of_worker "$LEAN")" = "$(canon_json "$leanc")" ] \
       && [ "$(printf '%s' "$body" | status_of_worker "$GHOST")" = "$gst" ]; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# ── the stub listener: one foreground-shaped loop, profile read per beat ─────
#
# PDF-D22: no detached beat sidecar. The capacity comes from a per-worker
# profile FILE re-read on every beat — the R3 swap rewrites the file (atomic
# tmp+mv) and the SAME loops, SAME names, start beating the exchanged
# capacities: routing must follow the content, not the identity.

run_stub_loop() { # worker profile_file logfile
  local worker="$1" pf="$2" log="$3" cap
  while true; do
    cap="$(cat "$pf" 2>/dev/null || printf 'null')"
    curl -sS --max-time 5 -X POST "$TARGET_BASE/v1/fleet/beat" \
      -H "Authorization: Bearer $TARGET_TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"worker\":\"$worker\",\"status\":\"idle\",\"ttl_s\":$TTL_S,\"capacity\":$cap}" >>"$log" 2>/dev/null || true
    printf '\n' >>"$log"
    sleep "$BEAT_EVERY"
  done
}

write_profile() { # file json — atomic so a mid-beat read never sees a torn file
  printf '%s' "$2" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ── cleanup: never leave a loop beating or a scratch postgres orphaned ───────

W1_PID=""; W2_PID=""; W1_PGID=""; W2_PGID=""
BOOTED=""; TEARDOWN_DONE=""; WORKDIR=""

cleanup() {
  set +e
  local g
  for g in "$W1_PGID" "$W2_PGID"; do
    [ -n "$g" ] && group_alive "$g" && kill -KILL -- "-$g" 2>/dev/null
  done
  if [ -n "$BOOTED" ] && [ -z "$TEARDOWN_DONE" ]; then
    say ""
    say "cleanup: the run died before the teardown rung — emergency teardown of $BARKPARK_HOME"
    "$SCRATCH_SCRIPT" teardown \
      || say "cleanup: emergency teardown FAILED — scratch root left at $BARKPARK_HOME for diagnosis"
  fi
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
  return 0
}
trap cleanup EXIT

# ═════════════════════════════════════════════════════════════════════════════
# --plan — every rung, its assert, and the fixtures. No side effects.
# ═════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "plan" ]; then
  rule
  say "PDF EFFICIENCY PROOF — PLAN (no side effects: no boot, no mktemp, no"
  say "network; this mode only prints)"
  rule
  say "tree:      $REPO_ROOT"
  say "dispatch:  $DISPATCH_SH (byte-untouched; driven via the merged"
  say "           FLEET_ROSTER_JSON + FLEET_FILE_ORDER_BIN seams)"
  say "scratch:   ${BARKPARK_HOME:-/tmp/pdf.XXXX (minted per run via mktemp — short)}"
  say "pointer:   ${PDS_SCRATCH_POINTER:-\$BARKPARK_HOME/pointer (PINNED per run)}"
  say "listeners: $BIG $CAP_BIG"
  say "           $LEAN $CAP_LEAN"
  say "           $GHOST $CAP_GHOST (beaten ONCE, ttl_s=$GHOST_TTL -> status:offline)"
  say "orders:    <run>-export (heavy) + <run>-lint (light) — one mixed batch"
  say "cap:       FLEET_SPEND_CAP=\$$CAP_USD; trip ledger sums to EXACTLY the cap"
  say "           (compare is spent >= cap, D54 pin 4); ledger dialect cost_usd at"
  say "           \$FLEET_HOME/orchestrator/spend.jsonl (D54 pin 1)"
  say "outcomes:  PASS / ABORT / FAIL — no silent skip. Exit 0/2/1 (+3 usage)."
  say ""
  say "RUNGS:"
  say "  0  PRECONDITION (ABORT-only) — boot the scratch target from THIS tree;"
  say "     GET /v1/fleet/roster must answer 200 with the documents envelope; a"
  say "     structured map-capacity beat must round-trip INTACT to the roster"
  say "     (asserted via GET roster — the beat receipt NEVER echoes capacity,"
  say "     D54 pin 2); and the merged dispatch.sh cap gate must provably read"
  say "     \$FLEET_HOME/orchestrator/spend.jsonl in the cost_usd dialect"
  say "     (functional probe: a seeded ledger of 1.25 + one canonical"
  say "     cost_usd:null skip-row must print 'spent \$1.2500' under a high cap)."
  say "  1  SETUP (ABORT) — two stub curl-loop listeners under set -m beat"
  say "     genuinely different measured profiles (xl/high-budget vs"
  say "     light/low-budget), profile re-read from file on EVERY beat; PGIDs"
  say "     distinct; both register; the ghost row reads status:offline. The"
  say "     RAW roster GET is quoted verbatim (PDF-D53 AC1 evidence)."
  say "  2  POSITIVE — mixed batch (1 heavy + 1 light) through dispatch.sh from"
  say "     a LIVE roster pull: heavy -> $BIG, light -> $LEAN, asserted from the"
  say "     printed decision lines; the ghost's offline-exclusion line prints"
  say "     (PDF-D38); 2 drafts filed (raw census +2), then deleted (census 0)."
  say "  3  SWAP CONTROL — capacities EXCHANGED via the profile files, worker"
  say "     names CONSTANT, fresh live pull, identical batch: the assignment"
  say "     must FLIP (heavy -> $LEAN, light -> $BIG) — routing is content-keyed."
  say "     --negctl variant: both listeners beat IDENTICAL capacities; the flip"
  say "     assert must FIRE AS A FAILURE (assignment must NOT flip) => NEGCTL"
  say "     OK, exit 0. Cap rungs R4-R7 are out of negctl scope BY DESIGN (the"
  say "     control inverts exactly the swap-flip instrument) — printed, never"
  say "     silent."
  say "  4  CAP POSITIVE — ledger summing EXACTLY the cap + FLEET_SPEND_CAP:"
  say "     ONE loud 'SPEND CAP REACHED' freeze line, EVERY order spend_cap,"
  say "     stub filer log 0 bytes AND raw census delta 0 (dispatch layer"
  say "     frozen, not just the route layer — D54 pin 5). Ledger printed."
  say "  5  UNTRIPPED CONTROL — fresh ledger UNDER the cap: dispatch PROCEEDS"
  say "     and the mapping matches R2. Ledger printed."
  say "  6  LEDGER-ZERO LIVE-READ — from the re-confirmed tripped state,"
  say "     truncate the ledger IN PLACE (same inode, no restarts): the freeze"
  say "     must NOT fire on the next batch (catches a cached spend_cap_reached)."
  say "  7  MALFORMED LEDGER (ABORT rung) — one non-numeric cost_usd row, NO"
  say "     FLEET_SPEND_CAP set (the ledger read is unconditional, D54 pin 6):"
  say "     dispatch must exit 12 with the NAMED MALFORMED_SPEND_LEDGER abort,"
  say "     never spend=0 or spend=inf; nothing filed."
  say "  T  TEARDOWN — reap both stub groups, then pds-scratch-target.sh"
  say "     teardown must PASS (ports released, zero orphan postgres for THIS"
  say "     root); the host's :4000 listener set must be unchanged."
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
[ -f "$DISPATCH_SH" ] || die "$DISPATCH_SH missing — the merged dispatch glue is the thing under proof"

# Pin the substrate (PDF-D29). Short root, per-run pointer, compiler unshadowed.
export BARKPARK_HOME="${BARKPARK_HOME:-$(mktemp -d /tmp/pdf.XXXX)}"
export PDS_SCRATCH_POINTER="${PDS_SCRATCH_POINTER:-$BARKPARK_HOME/pointer}"
export CC="${CC:-/usr/bin/clang}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
HARNESS_PGID="$(pgid_of $$)"
PORT4000_BEFORE="$(port4000_snapshot)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pdf-eff.XXXXXX")"

FLEET_HOME="$BARKPARK_HOME/fh"
LEDGER="$FLEET_HOME/orchestrator/spend.jsonl"
FILER="$BARKPARK_HOME/pdf-filer.sh"
FILER_LOG="$BARKPARK_HOME/pdf-filer.log"
PROFILE_BIG="$BARKPARK_HOME/profile-$BIG.json"
PROFILE_LEAN="$BARKPARK_HOME/profile-$LEAN.json"

rule
say "PDF EFFICIENCY PROOF — ${MODE} — run $RUN_ID"
rule
say "tree:        $REPO_ROOT"
say "worktree:    $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown) ($(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown))"
say "scratch:     $BARKPARK_HOME (${#BARKPARK_HOME} bytes)"
say "pointer:     $PDS_SCRATCH_POINTER (pinned — never the global default)"
say "fleet home:  $FLEET_HOME · ledger $LEDGER"
say "orders:      $OP-export (heavy) + $OP-lint (light)"
say "harness PGID $HARNESS_PGID · host :4000 listeners before: ${PORT4000_BEFORE:-none}"

# ── RUNG 0 — PRECONDITION (ABORT-only: substrate + contract pins) ────────────

head_rung 0 "PRECONDITION — fleet routes live, capacity round-trips, cap-gate ledger path+dialect verified"

BOOT_LOG="$BARKPARK_HOME/pdf-boot.log"
T0="$(date +%s)"
say "  booting the scratch target from this tree (log: $BOOT_LOG; cold budget"
say "  15 min — PDF-D29 measured 311.7s cold, ~13-33s warm)…"
# BOOTED before `up`, not after: a boot that dies halfway may leave a scratch
# postgres running, and the cleanup trap must still attempt the teardown.
BOOTED=1
if ! "$SCRATCH_SCRIPT" up >"$BOOT_LOG" 2>&1; then
  tail -20 "$BOOT_LOG" | sed 's/^/      /' || true
  abort 0 "env:scratch-boot-failed" \
    "pds-scratch-target.sh up failed from $REPO_ROOT — see $BOOT_LOG. Nothing about routing or the cap was measured."
  exit 2
fi
T1="$(date +%s)"
grep -E 'scratch root|http port|postgres port|media dir' "$BOOT_LOG" | sed 's/^pds-scratch: /      /' || true
info "boot took $((T1 - T0))s"

[ -f "$PDS_SCRATCH_POINTER" ] || { abort 0 "env:pointer-missing" "the pinned pointer $PDS_SCRATCH_POINTER was not written by up"; exit 2; }
# shellcheck disable=SC1090
. "$(cat "$PDS_SCRATCH_POINTER")/scratch.env"
TARGET_BASE="$PDS_SCRATCH_BASE"
TARGET_TOKEN="$PDS_SCRATCH_TOKEN"
[ -n "$TARGET_BASE" ] && [ -n "$TARGET_TOKEN" ] || { abort 0 "env:scratch-env-incomplete" "scratch.env lacks PDS_SCRATCH_BASE/PDS_SCRATCH_TOKEN"; exit 2; }
info "target $TARGET_BASE (token from scratch.env — never printed)"

ROSTER_TMP="$WORKDIR/roster-r0.json"
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
  abort 0 "env:stale-checkout-or-wrong-target" \
    "this tree's build does not serve the fleet roster — worktree from freshly-fetched origin/main (#5685+#5687 merged) and re-run."
  exit 2
fi

# Structured map-capacity beat must round-trip to the roster INTACT. The beat
# receipt NEVER echoes capacity (D54 pin 2) — the roster is the only witness.
# The probe worker doubles as the run's status:offline row: ttl_s=1, beaten
# once, never again (D54 pin 7).
GHOST_RESP="$(curl_beat "$GHOST" "idle" "$GHOST_TTL" "$CAP_GHOST" 2>/dev/null || true)"
GHOST_SEEN="$(printf '%s' "$GHOST_RESP" | beat_last_seen)"
if [ -z "$GHOST_SEEN" ]; then
  info "probe beat response: $(printf '%s' "$GHOST_RESP" | head -c 300)"
  abort 0 "env:beat-route-dead" "the structured-capacity probe POST /v1/fleet/beat did not answer with a server-stamped doc.last_seen"
  exit 2
fi
info "probe beat ($GHOST, capacity $CAP_GHOST, ttl_s=$GHOST_TTL) -> last_seen=$GHOST_SEEN"
if printf '%s' "$GHOST_RESP" | grep -qF '"capacity"'; then
  abort 0 "env:receipt-echoes-capacity" "the beat receipt carries a capacity key — that contradicts the merged contract (D54 pin 2); wrong tree?"
  exit 2
fi
info "beat receipt carries NO capacity key (D54 pin 2) — asserting the round-trip via GET roster"
GHOST_CAP_BACK="$(curl_roster | cap_of_worker "$GHOST")"
if [ "$GHOST_CAP_BACK" != "$(canon_json "$CAP_GHOST")" ]; then
  info "roster capacity for $GHOST: ${GHOST_CAP_BACK:-ABSENT/UNSTRUCTURED} (wanted $(canon_json "$CAP_GHOST"))"
  abort 0 "env:capacity-not-round-tripping" "a structured map capacity did not survive beat -> roster intact — the #5685 server slice is not on this tree"
  exit 2
fi
info "roster carries the structured capacity INTACT: $GHOST_CAP_BACK"

# The cap-gate contract (D54 pin 1): dispatch.sh must read
# $FLEET_HOME/orchestrator/spend.jsonl in the cost_usd dialect. Static pin +
# functional probe (seeded ledger 1.25 + one canonical cost_usd:null skip-row
# under a high cap -> the printed spent MUST be 1.2500).
grep -qF 'orchestrator/spend.jsonl' "$DISPATCH_SH" && grep -qF 'cost_usd' "$DISPATCH_SH" \
  || { abort 0 "env:dispatch-ledger-contract-drift" "dispatch.sh no longer names orchestrator/spend.jsonl + cost_usd — the D54 pin-1 contract moved; re-pin before trusting any cap rung"; exit 2; }
info "static pin: dispatch.sh names orchestrator/spend.jsonl and cost_usd"

mkdir -p "$FLEET_HOME/orchestrator"
printf '%s\n%s\n' \
  '{"ts":"2026-07-23T00:00:00Z","order_id":"seed-r0","agent":"pdf-proof","cost_usd":1.25}' \
  '{"ts":"2026-07-23T00:00:00Z","order_id":"seed-r0-null","agent":"pdf-proof","cost_usd":null}' \
  > "$LEDGER"
show_ledger
R0_ROSTER="$WORKDIR/roster-r0-stub.json"
NOW_ISO="$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"documents":[{"worker":"r0-stub","status":"idle","ttl_s":900,"last_seen":"%s","capacity":{"size_class":"xl","slots_total":1,"slots_free":1}}]}' "$NOW_ISO" > "$R0_ROSTER"
R0_ORDERS="$WORKDIR/orders-r0.json"
printf '[{"id":"%s-r0check","klass":"light"}]' "$OP" > "$R0_ORDERS"
R0_OUT="$WORKDIR/dispatch-r0.out"
set +e
FLEET_HOME="$FLEET_HOME" FLEET_ROSTER_JSON="$R0_ROSTER" \
  FLEET_FILE_ORDER_BIN="/usr/bin/true" FLEET_SPEND_CAP="100" \
  bash "$DISPATCH_SH" "$R0_ORDERS" >"$R0_OUT" 2>&1
R0_RC=$?
set -e
sed 's/^/      | /' "$R0_OUT"
if [ "$R0_RC" -ne 0 ] || ! grep -qF 'cap gate: spent $1.2500 of cap $100 — dispatch allowed' "$R0_OUT"; then
  abort 0 "env:cap-gate-ledger-mismatch" \
    "the seeded $LEDGER (1.25 + one cost_usd:null skip-row) did not surface as 'spent \$1.2500' (rc=$R0_RC) — the cap gate is not reading the pinned path/dialect; every later cap rung would fake green"
  exit 2
fi
info "functional pin: the cap gate read the seeded ledger at the pinned path, summed the cost_usd dialect (1.25) and skipped the canonical null row"
rm -f "$LEDGER"
pass 0 "target serves the fleet routes; structured capacity round-trips beat -> roster intact (receipt echo-free); cap-gate ledger path + cost_usd dialect verified (static + functional)"

# ── RUNG 1 — SETUP ───────────────────────────────────────────────────────────

if [ "$MODE" = "negctl" ]; then
  head_rung 1 "SETUP (negctl) — two stub listeners with IDENTICAL capacities"
  write_profile "$PROFILE_BIG" "$CAP_BIG"
  write_profile "$PROFILE_LEAN" "$CAP_BIG"
  EXPECT_BIG="$CAP_BIG"; EXPECT_LEAN="$CAP_BIG"
  info "both $BIG and $LEAN beat the SAME profile: $CAP_BIG"
  info "identical content -> the R3 swap-flip assert MUST fire as a failure (PDS-D20)"
else
  head_rung 1 "SETUP — two stub listeners beating genuinely different measured profiles"
  write_profile "$PROFILE_BIG" "$CAP_BIG"
  write_profile "$PROFILE_LEAN" "$CAP_LEAN"
  EXPECT_BIG="$CAP_BIG"; EXPECT_LEAN="$CAP_LEAN"
  info "$BIG  beats $CAP_BIG"
  info "$LEAN beats $CAP_LEAN"
fi

W1_LOG="$BARKPARK_HOME/beats-$BIG.log"
W2_LOG="$BARKPARK_HOME/beats-$LEAN.log"
: >"$W1_LOG"; : >"$W2_LOG"

run_stub_loop "$BIG" "$PROFILE_BIG" "$W1_LOG" &
W1_PID=$!
run_stub_loop "$LEAN" "$PROFILE_LEAN" "$W2_LOG" &
W2_PID=$!
W1_PGID="$(pgid_of "$W1_PID")"
W2_PGID="$(pgid_of "$W2_PID")"
info "$BIG  pid=$W1_PID pgid=$W1_PGID"
info "$LEAN pid=$W2_PID pgid=$W2_PGID"
info "harness            pgid=$HARNESS_PGID"

if [ -z "$W1_PGID" ] || [ -z "$W2_PGID" ] \
   || [ "$W1_PGID" = "$W2_PGID" ] || [ "$W1_PGID" = "$HARNESS_PGID" ] || [ "$W2_PGID" = "$HARNESS_PGID" ]; then
  fail 1 "PGIDs are NOT three distinct groups (w1=$W1_PGID w2=$W2_PGID harness=$HARNESS_PGID) — the teardown group-reap would take out the wrong thing"
  exit 1
fi

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
info "first beats landed: $BIG last_seen=$W1_FIRST · $LEAN last_seen=$W2_FIRST"

# The full R1 shape: both profiles visible on the roster AND the ghost row
# (beaten once in R0, ttl_s=1) reads status:offline.
if ! wait_roster_shape "$EXPECT_BIG" "$EXPECT_LEAN" "offline" 20; then
  BODY="$(curl_roster || true)"
  say "      last roster body:"
  printf '%s\n' "$BODY" | python3 -m json.tool 2>/dev/null | sed 's/^/        /' || printf '%s\n' "$BODY" | sed 's/^/        /'
  fail 1 "the roster never converged to both live profiles + $GHOST offline within 20s"
  exit 1
fi

# The RAW roster GET, quoted verbatim — live stub rows with their structured
# capacities plus one server-computed status:offline row. THIS quote is the
# PDF-D53 AC1 evidence (live roster read half of presence-honesty).
RAW_ROSTER="$(curl_roster)"
say ""
say "      RAW ROSTER GET (PDF-D53 AC1 evidence — live rows, capacities, one offline row):"
say "      GET $TARGET_BASE/v1/fleet/roster"
printf '%s\n' "$RAW_ROSTER" | python3 -m json.tool | sed 's/^/        /'
GHOST_STATUS="$(printf '%s' "$RAW_ROSTER" | status_of_worker "$GHOST")"
[ "$GHOST_STATUS" = "offline" ] || efail "ghost status read '$GHOST_STATUS' in the quoted roster (want offline)"
[ "$(printf '%s' "$RAW_ROSTER" | cap_of_worker "$BIG")" = "$(canon_json "$EXPECT_BIG")" ] || efail "$BIG capacity drifted in the quoted roster"
[ "$(printf '%s' "$RAW_ROSTER" | cap_of_worker "$LEAN")" = "$(canon_json "$EXPECT_LEAN")" ] || efail "$LEAN capacity drifted in the quoted roster"

# The stub filer (D54 pin 3): 5 positional args, draft-only createOrReplace
# with the scratch bearer, ALWAYS exit 0 (dispatch.sh's set -e loop aborts the
# batch on any non-zero filer).
cat > "$FILER" <<'FILER_EOF'
#!/usr/bin/env bash
# pdf-filer.sh — proof stub for FLEET_FILE_ORDER_BIN (PDF-D54 pin 3).
# 5 positional args: id title assignee brief criterion. ALWAYS exits 0.
set -u
ID="${1:?id}"; TITLE="${2:?title}"; WHO="${3:?assignee}"; BRIEF="${4:?brief}"; CRIT="${5:?criterion}"
BODY=$(python3 - "$ID" "$TITLE" "$WHO" "$BRIEF" "$CRIT" <<'PY'
import json, sys
i, t, w, b, c = sys.argv[1:6]
doc = {"_id": i, "_type": "task", "title": t, "kind": "task",
       "lifecycle_status": "open", "priority": 4, "assignee": w,
       "description": b[:140],
       "acceptance_criteria": [{"criterion": c, "met": False, "evidence": ""}]}
print(json.dumps({"mutations": [{"createOrReplace": doc}]}))
PY
)
RESP=$(curl -sS --max-time 10 -X POST "$PDF_TARGET_BASE/v1/data/mutate/production" \
  -H "Authorization: Bearer $PDF_TARGET_TOKEN" -H 'Content-Type: application/json' \
  -d "$BODY" 2>&1 || true)
case "$RESP" in
  *'"results"'*) printf 'FILED %s -> %s\n' "$ID" "$WHO" >>"$PDF_FILER_LOG" ;;
  *)             printf 'FILE_FAILED %s: %.200s\n' "$ID" "$RESP" >>"$PDF_FILER_LOG" ;;
esac
exit 0
FILER_EOF
chmod +x "$FILER"
export PDF_TARGET_BASE="$TARGET_BASE"
export PDF_TARGET_TOKEN="$TARGET_TOKEN"
export PDF_FILER_LOG="$FILER_LOG"
info "stub filer written to $FILER (draft-only createOrReplace, always exit 0)"

ORDERS_FILE="$WORKDIR/orders.json"
printf '[{"id":"%s-export","klass":"heavy"},{"id":"%s-lint","klass":"light"}]' "$OP" "$OP" > "$ORDERS_FILE"
info "orders: $(cat "$ORDERS_FILE")"

rung_seal 1 "two stub listeners up in distinct PGIDs, profiles live on the roster, ghost row offline, RAW roster quoted (D53 AC1)"

# ── RUNG 2 — POSITIVE: mixed batch from the LIVE roster ──────────────────────

head_rung 2 "POSITIVE — mixed batch: heavy-on-big + light-on-lean from a LIVE pull"

: >"$FILER_LOG"
census_ours; C_BEFORE="$CENSUS"
[ "$C_BEFORE" = "0" ] || efail "raw census not clean before R2 (found $C_BEFORE row(s) with prefix $OP-)"

ROSTER_R2="$WORKDIR/roster-r2.json"
pull_roster "$ROSTER_R2"
info "live roster pulled -> $ROSTER_R2 ($(wc -c < "$ROSTER_R2" | tr -d ' ') bytes)"
run_dispatch "$ORDERS_FILE" "$ROSTER_R2" ""

if [ "$MODE" = "negctl" ]; then
  # Identical capacities: the mapping here is a name-tiebreak, not a routing
  # verdict — R2 only establishes a baseline assignment for R3 to compare.
  [ "$DISP_RC" -eq 0 ] || efail "dispatch exited rc=$DISP_RC"
  expect_line "$OP-export → "
  expect_line "$OP-lint → "
  reject_line "UNPLACEABLE"
  BASE_MAP="$(grep -F ' → ' "$DISP_OUT" | sort || true)"
  info "baseline assignment recorded for the R3 inversion:"
  printf '%s\n' "$BASE_MAP" | sed 's/^/        /'
  cleanup_filed
  rung_seal 2 "baseline batch dispatched under IDENTICAL capacities (mapping is a tiebreak, recorded for R3)"
else
  [ "$DISP_RC" -eq 0 ] || efail "dispatch exited rc=$DISP_RC"
  expect_line "$OP-export → $BIG (heavy)"
  expect_line "$OP-lint → $LEAN (light)"
  expect_line "$GHOST excluded: offline/stale (server status=offline)"
  reject_line "UNPLACEABLE"
  FILED_N="$(grep -c '^FILED ' "$FILER_LOG" 2>/dev/null || true)"
  [ "$FILED_N" = "2" ] || efail "stub filer log shows $FILED_N FILED line(s), want 2 ($(head -c 200 "$FILER_LOG" 2>/dev/null))"
  census_ours; C_AFTER="$CENSUS"
  [ "$C_AFTER" = "2" ] || efail "raw census delta wrong: $C_BEFORE -> $C_AFTER (want +2 drafts)"
  info "raw census (perspective=raw, bearer): $C_BEFORE -> $C_AFTER"
  cleanup_filed
  rung_seal 2 "heavy -> $BIG and light -> $LEAN from the LIVE roster; ghost exclusion printed (PDF-D38); 2 drafts filed then cleaned (census 0)"
fi

# ── RUNG 3 — SWAP CONTROL (the negctl inverts exactly this assert) ───────────

if [ "$MODE" = "negctl" ]; then
  head_rung 3 "NEGCTL SWAP — capacities IDENTICAL: the flip assert must FIRE AS A FAILURE"
  # The "swap" of two identical profiles is a no-op by construction: same
  # names, same content. Re-write the files anyway (the exact R3 motion) and
  # give the loops one full cadence to re-beat.
  write_profile "$PROFILE_BIG" "$CAP_BIG"
  write_profile "$PROFILE_LEAN" "$CAP_BIG"
  sleep "$BEAT_EVERY"
else
  head_rung 3 "SWAP CONTROL — capacities EXCHANGED, worker names CONSTANT: the assignment must FLIP"
  write_profile "$PROFILE_BIG" "$CAP_LEAN"
  write_profile "$PROFILE_LEAN" "$CAP_BIG"
  info "profiles exchanged on disk — same loops, same names, next beats carry the swap"
  if ! wait_roster_shape "$CAP_LEAN" "$CAP_BIG" "offline" 20; then
    fail 3 "the roster never reflected the swapped capacities within 20s"
    exit 1
  fi
  info "roster reflects the swap: $BIG now $(canon_json "$CAP_LEAN") · $LEAN now $(canon_json "$CAP_BIG")"
fi

: >"$FILER_LOG"
ROSTER_R3="$WORKDIR/roster-r3.json"
pull_roster "$ROSTER_R3"
run_dispatch "$ORDERS_FILE" "$ROSTER_R3" ""
[ "$DISP_RC" -eq 0 ] || efail "dispatch exited rc=$DISP_RC"

# THE swap-flip assert (run mode: must hold; negctl: must FIRE AS A FAILURE).
FLIPPED="no"
if grep -qF -- "$OP-export → $LEAN (heavy)" "$DISP_OUT" \
   && grep -qF -- "$OP-lint → $BIG (light)" "$DISP_OUT"; then
  FLIPPED="yes"
fi

if [ "$MODE" = "negctl" ]; then
  POST_MAP="$(grep -F ' → ' "$DISP_OUT" | sort || true)"
  info "post-'swap' assignment:"
  printf '%s\n' "$POST_MAP" | sed 's/^/        /'
  if [ "$FLIPPED" = "yes" ]; then
    cleanup_filed
    fail 3 "NEGCTL BROKEN — the assignment FLIPPED with byte-identical capacities: routing is keyed on something other than capacity content"
    exit 1
  fi
  [ "$POST_MAP" = "$BASE_MAP" ] || efail "assignment changed between identical-capacity batches (baseline vs post-'swap' differ)"
  info "the swap-flip assert (heavy -> $LEAN AND light -> $BIG) FIRED AS A FAILURE:"
  info "with identical capacities the assignment does NOT flip. The R3 check CAN"
  info "fail, so the main run's flip is not vacuous (PDS-D20)."
  cleanup_filed
  rung_seal 3 "NEGCTL OK — the swap-flip assert demonstrably fires as a failure under identical capacities; assignment byte-stable across the no-op swap"
else
  [ "$FLIPPED" = "yes" ] || efail "the assignment did NOT flip after the capacity exchange (want heavy -> $LEAN, light -> $BIG) — routing is not content-keyed"
  expect_line "$GHOST excluded: offline/stale (server status=offline)"
  FILED_N="$(grep -c '^FILED ' "$FILER_LOG" 2>/dev/null || true)"
  [ "$FILED_N" = "2" ] || efail "stub filer log shows $FILED_N FILED line(s), want 2"
  cleanup_filed
  # Restore the original profiles so R4-R7 run against the R2 mapping.
  write_profile "$PROFILE_BIG" "$CAP_BIG"
  write_profile "$PROFILE_LEAN" "$CAP_LEAN"
  if ! wait_roster_shape "$CAP_BIG" "$CAP_LEAN" "offline" 20; then
    fail 3 "the roster never reflected the swap-BACK within 20s"
    exit 1
  fi
  info "profiles restored — roster back to the R2 shape"
  rung_seal 3 "capacities exchanged (names constant) FLIPPED the assignment: heavy -> $LEAN, light -> $BIG — routing follows measured content, not identity"
fi

if [ "$MODE" = "negctl" ]; then
  say ""
  say "  NOTE   R4-R7 (cap rungs) are OUT OF NEGCTL SCOPE BY DESIGN — this control"
  say "         inverts exactly the swap-flip assert (the brief's negctl contract);"
  say "         the cap instrument has its own controls inside the main run (R5"
  say "         untripped, R6 live-read, R7 malformed). Printed, never silent."
else

# ── RUNG 4 — CAP POSITIVE: tripped cap freezes dispatch ──────────────────────

head_rung 4 "CAP POSITIVE — ledger sums to EXACTLY the cap: freeze, zero filed"

printf '%s\n%s\n' "$TRIP_ROW_A" "$TRIP_ROW_B" > "$LEDGER"
show_ledger
info "FLEET_SPEND_CAP=\$$CAP_USD · 2.50 + 2.50 = 5.0000 >= 5.00 (the compare is >=, D54 pin 4)"

: >"$FILER_LOG"
census_ours; C_BEFORE="$CENSUS"
ROSTER_R4="$WORKDIR/roster-r4.json"
pull_roster "$ROSTER_R4"
run_dispatch "$ORDERS_FILE" "$ROSTER_R4" "$CAP_USD"
[ "$DISP_RC" -eq 0 ] || efail "frozen dispatch must exit 0 (a reported state, not an error) — got rc=$DISP_RC"
expect_line 'SPEND CAP REACHED ($5.0000 >= $5.00) — dispatch halted, 0/2 orders placed'
expect_line "$OP-export spend_cap"
expect_line "$OP-lint spend_cap"
reject_line " → "
if [ -s "$FILER_LOG" ]; then
  efail "stub filer log is NOT 0 bytes ($(wc -c < "$FILER_LOG" | tr -d ' ') bytes) — the dispatch layer invoked the filer under a tripped cap (D54 pin 5)"
fi
info "stub filer log: 0 bytes (the filer was never invoked — dispatch layer frozen, not just the route layer)"
census_ours; C_AFTER="$CENSUS"
[ "$C_AFTER" = "$C_BEFORE" ] || efail "raw census moved under the freeze: $C_BEFORE -> $C_AFTER (want delta 0)"
info "raw census delta: $C_BEFORE -> $C_AFTER (zero orders filed)"
rung_seal 4 "cap tripped at the exact boundary: ONE loud freeze line, every order spend_cap, filer log 0 bytes, raw census delta 0"

# ── RUNG 5 — UNTRIPPED CONTROL: under the cap, dispatch proceeds ─────────────

head_rung 5 "UNTRIPPED CONTROL — fresh ledger UNDER the cap: dispatch proceeds, R2 mapping"

printf '%s\n' "$UNDER_ROW" > "$LEDGER"
show_ledger
: >"$FILER_LOG"
census_ours; C_BEFORE="$CENSUS"
ROSTER_R5="$WORKDIR/roster-r5.json"
pull_roster "$ROSTER_R5"
run_dispatch "$ORDERS_FILE" "$ROSTER_R5" "$CAP_USD"
[ "$DISP_RC" -eq 0 ] || efail "dispatch exited rc=$DISP_RC"
expect_line 'cap gate: spent $2.5000 of cap $5.00 — dispatch allowed'
reject_line 'SPEND CAP REACHED'
expect_line "$OP-export → $BIG (heavy)"
expect_line "$OP-lint → $LEAN (light)"
FILED_N="$(grep -c '^FILED ' "$FILER_LOG" 2>/dev/null || true)"
[ "$FILED_N" = "2" ] || efail "stub filer log shows $FILED_N FILED line(s), want 2"
census_ours; C_AFTER="$CENSUS"
[ "$C_AFTER" = "2" ] || efail "raw census after the untripped batch: $C_AFTER (want 2)"
cleanup_filed
rung_seal 5 "under the cap the SAME batch proceeds and matches the R2 mapping — the freeze is the cap's doing, nothing else's"

# ── RUNG 6 — LEDGER-ZERO LIVE-READ: truncate in place, freeze must lift ──────

head_rung 6 "LEDGER-ZERO LIVE-READ — truncate the tripped ledger in place; NO restart; freeze must lift"

printf '%s\n%s\n' "$TRIP_ROW_A" "$TRIP_ROW_B" > "$LEDGER"
show_ledger
: >"$FILER_LOG"
ROSTER_R6="$WORKDIR/roster-r6.json"
pull_roster "$ROSTER_R6"
run_dispatch "$ORDERS_FILE" "$ROSTER_R6" "$CAP_USD"
expect_line 'SPEND CAP REACHED ($5.0000 >= $5.00) — dispatch halted, 0/2 orders placed'
info "tripped state re-confirmed (freeze fired)"

INODE_BEFORE="$(stat -f %i "$LEDGER" 2>/dev/null || stat -c %i "$LEDGER")"
: > "$LEDGER"
INODE_AFTER="$(stat -f %i "$LEDGER" 2>/dev/null || stat -c %i "$LEDGER")"
[ "$INODE_BEFORE" = "$INODE_AFTER" ] || efail "the truncate replaced the file (inode $INODE_BEFORE -> $INODE_AFTER) — not an in-place zero"
info "ledger truncated IN PLACE (inode $INODE_BEFORE unchanged); scratch server + shell untouched — no process restarted"
show_ledger

: >"$FILER_LOG"
run_dispatch "$ORDERS_FILE" "$ROSTER_R6" "$CAP_USD"
[ "$DISP_RC" -eq 0 ] || efail "dispatch exited rc=$DISP_RC after the zero"
reject_line 'SPEND CAP REACHED'
expect_line 'cap gate: spent $0.0000 of cap $5.00 — dispatch allowed'
expect_line "$OP-export → $BIG (heavy)"
expect_line "$OP-lint → $LEAN (light)"
FILED_N="$(grep -c '^FILED ' "$FILER_LOG" 2>/dev/null || true)"
[ "$FILED_N" = "2" ] || efail "stub filer log shows $FILED_N FILED line(s) after the zero, want 2"
cleanup_filed
rung_seal 6 "the in-place ledger zero LIFTED the freeze with no restart — the cap read is live-per-batch, never cached"

# ── RUNG 7 — MALFORMED LEDGER: a named ABORT, never a coerced number ─────────

head_rung 7 "MALFORMED LEDGER — non-numeric cost_usd, NO cap set: named abort exit 12"

printf '%s\n' "$MALFORMED_ROW" > "$LEDGER"
show_ledger
info "FLEET_SPEND_CAP deliberately UNSET — the ledger read is unconditional when the file exists (D54 pin 6)"
: >"$FILER_LOG"
ROSTER_R7="$WORKDIR/roster-r7.json"
pull_roster "$ROSTER_R7"
run_dispatch "$ORDERS_FILE" "$ROSTER_R7" ""
[ "$DISP_RC" -eq 12 ] || efail "dispatch exit rc=$DISP_RC, want the named 12 (MALFORMED_SPEND_LEDGER)"
expect_line "MALFORMED_SPEND_LEDGER_ROW line 1"
expect_line "non-numeric 'cost_usd'"
expect_line "ABORT: MALFORMED_SPEND_LEDGER at $LEDGER"
reject_line " → "
reject_line "spend_cap"
[ -s "$FILER_LOG" ] && efail "the filer ran during a malformed-ledger abort"
info "no spend=0, no spend=inf, nothing routed, nothing filed — the brake refuses garbage by name"
rm -f "$LEDGER"
rung_seal 7 "a malformed ledger row is a NAMED abort (exit 12, MALFORMED_SPEND_LEDGER line 1, non-numeric cost_usd) even with no cap set"

fi # end run-mode-only rungs

# ── RUNG T — TEARDOWN ────────────────────────────────────────────────────────

head_rung T "TEARDOWN — reap both stub groups, tear the target down clean"

for g in "$W1_PGID" "$W2_PGID"; do
  if group_alive "$g"; then
    kill -TERM -- "-$g" 2>/dev/null || true
    sleep 0.5
    group_alive "$g" && { kill -KILL -- "-$g" 2>/dev/null || true; sleep 0.3; }
  fi
done
wait "$W1_PID" 2>/dev/null || true
wait "$W2_PID" 2>/dev/null || true
if group_alive "$W1_PGID" || group_alive "$W2_PGID"; then
  fail T "a stub group would not die (w1=$W1_PGID w2=$W2_PGID) — refusing to tear down under it"
  exit 1
fi
info "stub groups $W1_PGID + $W2_PGID reaped"

TD_LOG="$WORKDIR/pdf-teardown.log"
TD_RC=0
"$SCRATCH_SCRIPT" teardown >"$TD_LOG" 2>&1 || TD_RC=$?
sed 's/^/      /' "$TD_LOG"
TEARDOWN_DONE=1

PORT4000_AFTER="$(port4000_snapshot)"
info "host :4000 listeners — before: '${PORT4000_BEFORE:-none}' · after: '${PORT4000_AFTER:-none}'"

if [ "$TD_RC" -ne 0 ] || ! grep -q 'teardown: PASS' "$TD_LOG"; then
  fail T "pds-scratch-target teardown did NOT pass (exit $TD_RC) — see its output above; the scratch root may be left for diagnosis"
  exit 1
fi
if [ "$PORT4000_BEFORE" != "$PORT4000_AFTER" ]; then
  fail T "the host's :4000 listener set CHANGED across the run ('$PORT4000_BEFORE' -> '$PORT4000_AFTER') — the isolation promise broke"
  exit 1
fi
pass T "teardown PASS (ports released, zero orphan postgres for this root, scratch root removed); host :4000 untouched"

# ── verdict ──────────────────────────────────────────────────────────────────

say ""
rule
say "VERDICT — $MODE: PASS=$N_PASS ABORT=$N_ABORT FAIL=$N_FAIL"
if [ "$MODE" = "negctl" ]; then
  say "NEGCTL OK — the swap-flip check is a real instrument: under byte-identical"
  say "capacities it fired as a failure (the assignment refused to flip), so the"
  say "main run's flip is content-keyed routing, not coincidence."
else
  say "The efficiency loop is LIVE: measured capacity heartbeats round-tripped"
  say "beat -> roster -> dispatch -> route; the mixed batch landed heavy-on-big +"
  say "light-on-lean from the live roster; exchanging the capacities (names"
  say "constant) flipped the assignment; the tripped cap froze dispatch at the"
  say "exact >= boundary with zero filed; an in-place ledger zero lifted the"
  say "freeze with no restart; a malformed ledger row aborted BY NAME (exit 12)."
  say "Four verbs, no new concepts (PDF-D23)."
fi
rule
exit 0
