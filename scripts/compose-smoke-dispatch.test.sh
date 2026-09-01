#!/usr/bin/env bash
# compose-smoke-dispatch.test.sh — the dispatcher must be able to FIRE on
# everything the gate actually measures.
#
#   bash scripts/compose-smoke-dispatch.test.sh      (exit 0 = all green)
#
# THE DEFECT THIS PINS. compose-smoke.yml's `changes` job decides smoke=true|false
# from a hand-written `grep -qE` over the changed-file set. That predicate was
# anchored to the repo root plus `^api/`. But the job it gates runs
# scripts/compose-smoke.sh, which runs env-census over BOTH runtime roots —
# `--root api` AND `--root cloud` — and env-census's ROOTS["cloud"] covers
# cloud/config/runtime.exs, cloud/lib and cloud/docker-compose.yml.
#
# So the gate censused cloud/ and NO cloud/ change could trigger it. The RED it
# produces by hand was a red CI could never produce: a gate counted as present
# while blind to its own subject.
#
# WHY THE PREDICATE IS EXTRACTED, NOT COPIED. A copy here would keep passing
# after someone re-narrows the filter in the workflow — the exact regression
# this file exists to stop. The `grep -qE '…'` pattern is lifted out of
# compose-smoke.yml at run time and executed against synthetic path sets. If the
# extraction fails, that is a FAILURE, never a skip.
#
# WHAT IT DOES NOT CLAIM. It says nothing about whether the census is CORRECT —
# env-census has its own proof. It says only that a change to a file the census
# reads can reach the census.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WF="${COMPOSE_SMOKE_WF:-$ROOT/.github/workflows/compose-smoke.yml}"
CENSUS="${COMPOSE_SMOKE_CENSUS:-$ROOT/scripts/env-census.py}"

pass=0; fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-58s (%s)\n' "$1" "$3"
  else fail=$((fail+1)); printf 'FAIL %-58s want %s got %s\n' "$1" "$2" "$3"; fi
}

[ -r "$WF" ] || { echo "FAIL: cannot read $WF" >&2; exit 2; }

# ── extract the dispatcher predicate ────────────────────────────────────────
# The line is:  if printf '%s\n' "$changed" | grep -qE '<PATTERN>'; then
PATTERN="$(sed -n "s/.*grep -qE '\(.*\)'; then/\1/p" "$WF" | head -1)"
if [ -z "$PATTERN" ]; then
  echo "FAIL: could not extract the dispatcher predicate from $WF." >&2
  echo "      The gate's shape changed. Update this harness in the same commit —" >&2
  echo "      do NOT let it degrade to a skip, which would green a gate nothing measured." >&2
  exit 2
fi
echo "extracted predicate: $PATTERN"
echo ""

# NON-VACUITY on the extraction itself: the pattern must be a real alternation,
# not an empty string that matches everything (or nothing).
check "predicate is non-empty"            1 "$([ -n "$PATTERN" ] && echo 1 || echo 0)"
check "predicate anchors at least once"   1 "$(printf '%s' "$PATTERN" | grep -c '\^' | awk '{print ($1>0)?1:0}')"

dispatch() { # dispatch <path> -> true|false, exactly as the workflow decides
  if printf '%s\n' "$1" | grep -qE "$PATTERN"; then echo true; else echo false; fi
}

echo "== 1. the api root — the half that always worked =="
check "api/config/runtime.exs triggers"        true  "$(dispatch 'api/config/runtime.exs')"
check "api/lib/barkpark/accounts.ex triggers"  true  "$(dispatch 'api/lib/barkpark/accounts.ex')"
check "docker-compose.yml triggers"            true  "$(dispatch 'docker-compose.yml')"
check "scripts/env-census.py triggers"         true  "$(dispatch 'scripts/env-census.py')"

echo ""
echo "== 2. the cloud root — THE DEFECT. Every one of these is a file the =="
echo "==    census reads, via ROOTS[\"cloud\"] in scripts/env-census.py.    =="
# These four paths are not a guess: they are ROOTS["cloud"]'s sources + compose.
check "cloud/config/runtime.exs triggers"      true  "$(dispatch 'cloud/config/runtime.exs')"
check "cloud/lib/barkpark_cloud/github.ex triggers" true "$(dispatch 'cloud/lib/barkpark_cloud/github.ex')"
check "cloud/docker-compose.yml triggers"      true  "$(dispatch 'cloud/docker-compose.yml')"

echo ""
echo "== 3. NON-VACUITY — the predicate must still say NO to something =="
# Without these, a predicate widened to `.` would pass every case above.
check "docs/ops/PROD_OPS.md does NOT trigger"  false "$(dispatch 'docs/ops/PROD_OPS.md')"
check "js/packages/core/src/x.ts does NOT"     false "$(dispatch 'js/packages/core/src/x.ts')"
check "internal/cli/root.go does NOT"          false "$(dispatch 'internal/cli/root.go')"
# A path that merely CONTAINS an alternative must not match — anchoring proof.
check "vendor/api/x.ex does NOT (anchored)"    false "$(dispatch 'vendor/api/x.ex')"
check "x/docker-compose.yml does NOT (anchored)" false "$(dispatch 'x/docker-compose.yml')"

echo ""
echo "== 4. the trigger set covers the census's OWN declared roots =="
# Re-derive the subject from env-census.py rather than remembering it, so this
# check follows the script if someone adds a third root.
if [ -r "$CENSUS" ]; then
  roots="$(sed -n 's/^    ap.add_argument("--root", choices=\[\(.*\)\], default.*/\1/p' "$CENSUS" | tr -d '"' | tr ',' ' ')"
  check "env-census declares its roots"        1 "$([ -n "$roots" ] && echo 1 || echo 0)"
  for r in $roots; do
    [ "$r" = "both" ] && continue
    # every root name must appear as a triggerable prefix
    got="$(dispatch "$r/config/runtime.exs")"
    check "root '$r' is reachable by the dispatcher" true "$got"
  done
else
  check "env-census.py is readable"            1 0
fi

echo ""
echo "---"
echo "compose-smoke dispatcher: $pass passed, $fail failed"
[ "$fail" = 0 ]
