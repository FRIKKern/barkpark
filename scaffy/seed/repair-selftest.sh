#!/usr/bin/env bash
# Hermetic proof that scaffy/seed/repair.sh works — no credential, no egress.
#
# THE DEFECT THIS CLOSES. The repair arm executed 0 times in the gate's first
# 12 runs (nine reds took the credential guard, three greens skipped the step).
# It was one repo secret away from being an unattended cron writer against
# production content whose first execution would also be its first evidence.
# This script makes every run of the gate execute the repair logic against a
# local fixture, so the code is proven BEFORE the token exists rather than by
# the production write that uses it.
#
# WHAT IT PROVES — four arms, each asserted on exit code AND on observable
# effect, because an arm that only shows one colour has not been tested:
#   1. HAPPY      repair.sh posts one atomic createOrReplace+publish batch per
#                 drifted id and exits 0. Asserted on the RECORDED bodies.
#   2. UNKNOWN_TAG the E3 422 wall is cleared by registering the payload's tag
#                 docs and retrying, and the retry SUCCEEDS. Asserted on the
#                 recorded tag registrations plus the eventual command write.
#   3. REFUSE     a server that refuses the write reds (exit 1). A repair arm
#                 that swallowed a failed write would report a repair it never
#                 made.
#   4. EMPTY      an empty drifted-id list is an ERROR, not a clean run. The
#                 caller only invokes repair on a DRIFT verdict, so zero ids
#                 means the handoff broke — "gate satisfiable by emptiness".
#
# Usage: scaffy/seed/repair-selftest.sh   (run from anywhere; it cds to root)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

TMP="${RUNNER_TEMP:-/tmp}/scaffy-repair-selftest.$$"
SRV=""
rm -rf "$TMP"
mkdir -p "$TMP/payloads" "$TMP/work"
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

PORT="${REPAIR_SELFTEST_PORT:-8766}"
TOKEN="test-token"
fails=0

note() { printf '\n=== %s\n' "$*"; }
ok()   { printf '    ok   — %s\n' "$*"; }
bad()  { printf '    FAIL — %s\n' "$*"; fails=$((fails + 1)); }

# Real derived payloads — the fixture is the actual corpus, so the mutation
# bodies under test are byte-for-byte what a production repair would send.
go run ./scaffy/seed --out "$TMP/payloads" >/dev/null 2>&1 \
  || { echo "::error::repair-selftest: could not derive payloads"; exit 1; }

# Two real ids to re-seed.
ls "$TMP/payloads" | sed 's/\.json$//' | head -2 > "$TMP/drifted.txt"
id_count=$(grep -c '[^[:space:]]' "$TMP/drifted.txt")
[ "$id_count" -eq 2 ] || { echo "::error::repair-selftest: fixture needs 2 ids, got $id_count"; exit 1; }

start_server() { # start_server <mode> <record-file>
  MODE="$1" RECORD_FILE="$2" PORT="$PORT" EXPECT_TOKEN="$TOKEN" \
    python3 scaffy/seed/testdata/mock_mutate_server.py >/dev/null 2>&1 &
  SRV=$!
  # Probe /healthz, NEVER the mutate path: a probe that rides the endpoint
  # under measurement gets recorded as traffic and corrupts the assertions.
  for _ in $(seq 1 50); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  echo "::error::repair-selftest: mock server never came up"; exit 1
}
stop_server() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }

run_repair() { # run_repair <ids-file> -> sets OUT and CODE
  OUT="$(SERVER="http://127.0.0.1:$PORT" BARKPARK_SEED_TOKEN="$TOKEN" \
    DRIFTED_IDS_FILE="$1" PAYLOAD_DIR="$TMP/payloads" WORK_DIR="$TMP/work" \
    bash scaffy/seed/repair.sh 2>&1)"
  CODE=$?
}

# ── ARM 1 — HAPPY ────────────────────────────────────────────────────────────
note "ARM 1 — happy path: two drifted ids re-seeded"
: > "$TMP/rec-happy.jsonl"
start_server happy "$TMP/rec-happy.jsonl"
run_repair "$TMP/drifted.txt"
stop_server
echo "$OUT" | sed 's/^/    | /'
[ "$CODE" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $CODE"
recorded=$(grep -c . "$TMP/rec-happy.jsonl")
[ "$recorded" -eq 2 ] && ok "server recorded 2 mutation batches" \
  || bad "expected 2 recorded batches, got $recorded"
# Each batch must be ONE atomic createOrReplace+publish for a command.
shape_ok=1
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n=$(jq '.mutations|length' <<<"$line")
  t=$(jq -r '.mutations[0].createOrReplace._type' <<<"$line")
  cid=$(jq -r '.mutations[0].createOrReplace._id' <<<"$line")
  pid=$(jq -r '.mutations[1].publish.id' <<<"$line")
  ptype=$(jq -r '.mutations[1].publish.type' <<<"$line")
  if [ "$n" != 2 ] || [ "$t" != command ] || [ "$ptype" != command ] || [ "$cid" != "$pid" ]; then
    shape_ok=0
  fi
done < "$TMP/rec-happy.jsonl"
[ "$shape_ok" -eq 1 ] \
  && ok "every batch is createOrReplace(_type=command) + publish of the SAME id" \
  || bad "a recorded batch had the wrong shape"

# ── ARM 2 — UNKNOWN_TAG (the E3 wall) ────────────────────────────────────────
note "ARM 2 — unknown_tag 422 wall is cleared by registering tags, and the retry succeeds"
: > "$TMP/rec-tag.jsonl"
start_server unknown_tag "$TMP/rec-tag.jsonl"
run_repair "$TMP/drifted.txt"
stop_server
echo "$OUT" | sed 's/^/    | /'
[ "$CODE" -eq 0 ] && ok "exit 0 — the retry cleared the wall" \
  || bad "expected exit 0 after tag registration, got $CODE"
grep -q 'unknown_tag on ' <<<"$OUT" && ok "took the unknown_tag branch (not a lucky first-try pass)" \
  || bad "never entered the unknown_tag branch — the wall was not exercised"
tag_writes=$(jq -r 'select(.mutations[0].createOrReplace._type=="tag")|.mutations[0].createOrReplace._id' "$TMP/rec-tag.jsonl" 2>/dev/null | sort -u | grep -c .)
[ "$tag_writes" -gt 0 ] && ok "registered $tag_writes distinct tag doc(s)" \
  || bad "no tag docs were registered"
cmd_writes=$(jq -r 'select(.mutations[0].createOrReplace._type=="command")|.mutations[0].createOrReplace._id' "$TMP/rec-tag.jsonl" 2>/dev/null | sort -u | grep -c .)
[ "$cmd_writes" -eq 2 ] && ok "both commands landed after the retry" \
  || bad "expected 2 command writes after retry, got $cmd_writes"

# ── ARM 3 — REFUSE ───────────────────────────────────────────────────────────
note "ARM 3 — a refused write REDS (it must not report a repair it never made)"
: > "$TMP/rec-refuse.jsonl"
start_server refuse "$TMP/rec-refuse.jsonl"
run_repair "$TMP/drifted.txt"
stop_server
echo "$OUT" | sed 's/^/    | /'
[ "$CODE" -eq 1 ] && ok "exit 1" || bad "expected exit 1 on a refused write, got $CODE"
grep -q '::error::' <<<"$OUT" && ok "emitted an ::error:: annotation" \
  || bad "a refused write produced no ::error:: annotation"

# ── ARM 4 — EMPTY ────────────────────────────────────────────────────────────
note "ARM 4 — an empty drifted-id list is an ERROR, never a silent success"
: > "$TMP/empty.txt"
: > "$TMP/rec-empty.jsonl"
start_server happy "$TMP/rec-empty.jsonl"
run_repair "$TMP/empty.txt"
stop_server
echo "$OUT" | sed 's/^/    | /'
[ "$CODE" -eq 1 ] && ok "exit 1 — refused to report success over zero work" \
  || bad "expected exit 1 on an empty id list, got $CODE (gate satisfiable by emptiness)"
wrote=$(grep -c . "$TMP/rec-empty.jsonl")
[ "$wrote" -eq 0 ] && ok "posted nothing" || bad "posted $wrote batches on an empty list"

# ── verdict ──────────────────────────────────────────────────────────────────
echo
if [ "$fails" -ne 0 ]; then
  echo "::error::repair-selftest FAILED — $fails assertion(s) red. The repair arm is not trustworthy; do not install BARKPARK_SEED_TOKEN until this is green."
  exit 1
fi
echo "repair-selftest OK — happy, unknown_tag retry, refusal and empty-list arms all proven against a local fixture (zero egress, zero credentials)."
