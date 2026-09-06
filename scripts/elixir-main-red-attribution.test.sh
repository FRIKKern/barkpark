#!/usr/bin/env bash
# elixir-main-red-attribution.test.sh — the mutation matrix for the main-red
# attribution reporter.
#
# THE CASE THAT MATTERS IS §2: a FORCED skipped-test failure. The reporter's
# whole purpose is to notice that main red on a test the pull request never ran,
# so a harness that only exercised the happy path would certify an instrument
# that can never fire. §2 constructs exactly that condition — a diff that
# narrows, and a failure in a file the narrowing does not contain — and demands
# exit 3.
#
# Every case runs against a REAL tree and the REAL selector, not a stub: the
# thing under test is the composition of the two, and a stubbed selector would
# prove only that this file can read its own fixture.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
ATTR="$HERE/elixir-main-red-attribution.sh"

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  echo "  ok   — $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL — $1"
  [ -n "${2:-}" ] && echo "         $2"
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# run: <log file> <diff file> -> sets RC and OUT
run() {
  OUT="$(bash "$ATTR" --log "$1" --diff "$2" 2>&1)"
  RC=$?
}

expect() { # expect <desc> <want-rc> <want-verdict>
  local desc="$1" want_rc="$2" want_v="$3"
  if [ "$RC" -ne "$want_rc" ]; then
    bad "$desc" "expected rc=$want_rc, got rc=$RC — $(head -2 <<<"$OUT" | tr '\n' ' ')"
    return
  fi
  if ! grep -qxF "verdict=$want_v" <<<"$OUT"; then
    bad "$desc" "expected verdict=$want_v, got '$(grep -o 'verdict=[A-Z_]*' <<<"$OUT" | head -1)'"
    return
  fi
  ok "$desc"
}

# ── FIXTURE PICKING, from the live tree ───────────────────────────────────
# A lib file with a convention test (so the selection contains a known file),
# and a test file that the SAME change does NOT select (the miss fixture).
lib=""
lib_test=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  t="test/${cand#lib/}"
  t="${t%.ex}_test.exs"
  [ -f "$ROOT/api/$t" ] && { lib="api/$cand"; lib_test="$t"; break; }
done <<<"$(cd "$ROOT/api" && ls lib/barkpark/*.ex 2>/dev/null | head -30)"

if [ -z "$lib" ]; then
  echo "  FAIL — harness setup: no api/lib/barkpark/*.ex with a convention test"
  exit 1
fi
ok "harness setup: $lib / $lib_test"

printf '%s\n' "$lib" >"$tmp/diff.narrow"
printf 'api/mix.lock\n' >"$tmp/diff.all"

# The selection for the narrow diff, so §2 can pick a file that is NOT in it.
BP_IMPACTED_NO_XREF=1 bash "$HERE/elixir-impacted-tests.sh" --select <"$tmp/diff.narrow" >"$tmp/sel" 2>/dev/null
outsider=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  grep -qxF -- "$t" "$tmp/sel" || { outsider="$t"; break; }
done <<<"$(cd "$ROOT/api" && find test -name '*_test.exs' | LC_ALL=C sort)"
[ -n "$outsider" ] && ok "harness setup: $outsider is OUTSIDE the selection (the miss fixture)" \
  || bad "harness setup: a test outside the selection exists" "the selection covers the entire suite — §2 cannot run"

mklog() { # mklog <file> <test path> — an ExUnit failure block
  cat >"$1" <<LOG

  1) test the thing does the thing (Barkpark.SomeTest)
     $2:41
     Assertion with == failed
     code:  assert foo() == :ok
     left:  :error
     right: :ok
     stacktrace:
       $2:41: (test)

Finished in 12.3 seconds
1 test, 1 failure
LOG
}

echo
echo "=== §1  COVERED — main red on a test the selection DID contain"
mklog "$tmp/log.covered" "$lib_test"
run "$tmp/log.covered" "$tmp/diff.narrow"
expect "a failure inside the selection reports COVERED (rc 0)" 0 COVERED

echo
echo "=== §2  THE MUTATION — a FORCED failure in a test the selection did NOT contain"
# This is the condition the reporter exists to detect. If this case ever passes
# with rc=0, the instrument is dead and every future selector miss is silent.
if [ -n "$outsider" ]; then
  mklog "$tmp/log.missed" "$outsider"
  run "$tmp/log.missed" "$tmp/diff.narrow"
  expect "a failure OUTSIDE the selection reports SKIPPED (rc 3)" 3 SKIPPED
  grep -qF "$outsider" <<<"$OUT" && ok "the report NAMES the skipped file" || bad "the report NAMES the skipped file"
  grep -qF "candidate, not a proof" <<<"$OUT" && ok "the report states its own limit (mapper-only reconstruction)" || bad "the report states its own limit"

  # …and the SAME log against a diff that selects ALL must NOT report a skip.
  # Without this arm the reporter could be keyed on the log alone and would
  # blame the selector for every red on main.
  run "$tmp/log.missed" "$tmp/diff.all"
  expect "the same failure on an ALL diff reports SELECTION_ALL, not a skip" 0 SELECTION_ALL
fi

echo
echo "=== §3  REDS THAT ARE NOT THE SELECTOR'S FAULT"
cat >"$tmp/log.compile" <<'LOG'
== Compilation error in file lib/barkpark/thing.ex ==
** (CompileError) lib/barkpark/thing.ex:12: undefined function foo/0
LOG
run "$tmp/log.compile" "$tmp/diff.narrow"
expect "a compile error is NOT_A_TEST_FAILURE (rc 0)" 0 NOT_A_TEST_FAILURE

cat >"$tmp/log.drift" <<'LOG'
docs/openapi.json is STALE.
::error file=docs/openapi.json,title=OpenAPI descriptor is stale::Run it.
LOG
run "$tmp/log.drift" "$tmp/diff.narrow"
expect "a drift-gate red is NOT_A_TEST_FAILURE (rc 0)" 0 NOT_A_TEST_FAILURE

# A stack frame into lib/ must not be mistaken for a failing TEST file.
cat >"$tmp/log.libframe" <<'LOG'
     stacktrace:
       lib/barkpark/thing.ex:41: Barkpark.Thing.go/1
       (elixir 1.18.4) lib/enum.ex:1: Enum.map/2
LOG
run "$tmp/log.libframe" "$tmp/diff.narrow"
expect "a lib/ stack frame is not read as a failing test file" 0 NOT_A_TEST_FAILURE

echo
echo "=== §4  UNUSABLE INPUT IS LOUD, NEVER A QUIET PASS"
: >"$tmp/log.empty"
run "$tmp/log.empty" "$tmp/diff.narrow"
expect "an EMPTY log is UNUSABLE (rc 1), not a clean pass" 1 UNUSABLE

run "$tmp/nope.log" "$tmp/diff.narrow"
expect "a MISSING log is UNUSABLE (rc 1)" 1 UNUSABLE

run "$tmp/log.covered" "$tmp/nope.diff"
expect "a MISSING diff is UNUSABLE (rc 1)" 1 UNUSABLE

OUT="$(bash "$ATTR" --nope 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "an unknown flag is refused with exit 2" || bad "an unknown flag is refused with exit 2" "got rc=$RC"

echo
echo "=== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
