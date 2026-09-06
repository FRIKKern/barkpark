#!/usr/bin/env bash
# elixir-impacted-tests.test.sh — the harness for the PR test selector.
#
# THE GUARD IT IS GUARDING AGAINST. A test selector's only dangerous failure is
# selecting TOO LITTLE and reporting green, so nearly every case below asserts
# the FAIL-SAFE direction: a path this script cannot classify must widen the
# selection to `ALL`, never narrow it. Two cases assert the opposite —
# "a leaf lib change does NOT select ALL" and "the ALWAYS set is non-empty" —
# because without them a selector hard-wired to print `ALL` would satisfy every
# other case here while measuring nothing (the vacuous-green shape, D26).
#
# D37, AND IT BIT THIS FILE FIRST: never `printf … | grep -q`. Under pipefail a
# matching grep exits 0 immediately, printf dies of SIGPIPE, 141 wins the
# pipeline, and EVERY match reads as a miss — the first run of this harness
# reported 12 false failures for exactly that reason. Here-strings have no
# writer to kill, so every membership test below uses one.
#
# §1  fail-safe: which inputs must select ALL
# §2  narrowing actually happens, and picks the right tests
# §3  the ALWAYS set: non-empty, derived, and pinned entries exist
# §4  PAST-DEFECT REPLAY — real merged fixes, replayed through the selector
# §5  refusals: unknown flags, empty ALWAYS set
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
SEL="$HERE/elixir-impacted-tests.sh"

# No compiled build in a harness. Every case here exercises the CLASSIFICATION
# and the by-name/convention mappers, which is what the fail-safe polarity is
# made of; the xref hop is exercised for real on every PR run of the mix-test
# job and its failure arm is asserted at §1e by pointing the selector at a
# directory where `mix` cannot succeed.
export BP_IMPACTED_NO_XREF=1

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

# run the selector over a newline-separated changed-path list
sel() {
  printf '%s\n' "$1" | bash "$SEL" --select 2>/dev/null
}

is_all() { [ "$(printf '%s' "$1" | tr -d '[:space:]')" = "ALL" ]; }

assert_all() {
  local desc="$1" input="$2" out
  out="$(sel "$input")"
  if is_all "$out"; then
    ok "$desc"
  else
    bad "$desc" "expected ALL, got $(printf '%s' "$out" | head -3 | tr '\n' ' ')…"
  fi
}

assert_not_all() {
  local desc="$1" input="$2" out
  out="$(sel "$input")"
  if is_all "$out"; then
    bad "$desc" "expected a NARROWED selection, got ALL"
  elif [ -z "$out" ]; then
    bad "$desc" "expected a NARROWED selection, got EMPTY — an empty selection is the failure this file exists to catch"
  else
    ok "$desc"
  fi
}

assert_selects() {
  local desc="$1" input="$2" want="$3" out
  out="$(sel "$input")"
  if is_all "$out"; then
    bad "$desc" "expected '$want' inside a narrowed selection, got ALL"
  elif grep -qxF -- "$want" <<<"$out"; then
    ok "$desc"
  else
    bad "$desc" "'$want' is NOT in the selection ($(printf '%s\n' "$out" | awk 'END{print NR}') files)"
  fi
}

echo "=== §1  FAIL-SAFE: an unclassifiable path must WIDEN, never narrow"

# The four the acceptance criteria name by hand.
assert_all "api/config/runtime.exs selects ALL" "api/config/runtime.exs"
assert_all "api/config/config.exs selects ALL" "api/config/config.exs"
assert_all "api/mix.lock selects ALL" "api/mix.lock"
assert_all "api/mix.exs selects ALL" "api/mix.exs"
assert_all "api/test/test_helper.exs selects ALL" "api/test/test_helper.exs"

# The classes that make the whitelist a whitelist. Each of these is a path the
# elixir.yml dispatcher CAN let through with test=true.
assert_all "api/test/support/**.ex (a case template) selects ALL" "api/test/support/conn_case.ex"
assert_all "api/test/fixtures/** selects ALL" "api/test/fixtures/onix/sample.xml"
assert_all "api/priv/repo/migrations/** selects ALL" "api/priv/repo/migrations/20260101000000_add_thing.exs"
assert_all "a .heex template under api/lib selects ALL" "api/lib/barkpark_web/components/layouts/root.html.heex"
assert_all "api/assets/** selects ALL" "api/assets/sheet-grid/grid.mjs"
assert_all "the workflow itself (COMPILE set) selects ALL" ".github/workflows/elixir.yml"
assert_all "design/** (COMPILE set) selects ALL" "design/status-manifest.json"
assert_all "a TEST-set tree the census names no reader for selects ALL" "cloud/test/barkpark_cloud/accounts_test.exs"
assert_all "internal/taskboard/** (TEST set, no census reader) selects ALL" "internal/taskboard/board.go"

# §1f — CLASS 3 branches (b) and (c). Neither can produce an empty selection:
# the ALWAYS set rides regardless, and any api/ path in the same diff is still
# classified on its own terms. Both are asserted by IDENTITY against the ALWAYS
# set, not by "is not ALL" — a branch that quietly dropped the net would
# otherwise pass.
always_snapshot="$(bash "$SEL" --print-always 2>/dev/null)"

# (c) a path in NEITHER declared set. The path-escape ratchet's guarantee is
# that nothing in api/lib or api/test reads such a path, and the elixir.yml
# dispatcher acts on the same belief: on a diff of ONLY such paths it emits
# compile=false test=false and this job never runs at all. Selecting the ALWAYS
# set here is therefore STRICTLY MORE than the tree does today, not less.
for unclassified in "some/brand/new/tree/thing.txt" ".tool-versions" "scripts/canonical-marker-bindings.pin"; do
  out="$(sel "$unclassified")"
  if is_all "$out"; then
    ok "an unclassified path ($unclassified) selects ALL"
  elif [ "$out" = "$always_snapshot" ]; then
    ok "an unclassified path ($unclassified) contributes NO tests of its own — the selection is exactly the ALWAYS set"
  else
    bad "an unclassified path ($unclassified) is the ALWAYS set or ALL" "got $(printf '%s\n' "$out" | awk 'END{print NR}') files, neither"
  fi
done

# (b) a path the census DOES name. docs/openapi.json is read by api/lib, so the
# reader's closure is taken — and the test that guards that artifact must be in
# the result. If this ever regresses to "no tests", the OpenAPI contract stops
# being covered by any PR that only regenerates it.
assert_selects "docs/openapi.json selects the test that guards it" "docs/openapi.json" "test/barkpark/api/openapi_test.exs"

# §1b — the empty diff. Same polarity as the elixir.yml dispatcher's own empty
# arm: rare but legal, and a narrow answer from no information is the unsafe one.
out="$(printf '' | bash "$SEL" --select 2>/dev/null)"
if is_all "$out"; then ok "an EMPTY changed-path set selects ALL"; else bad "an EMPTY changed-path set selects ALL" "got '$out'"; fi

# §1c — ONE bad path in an otherwise narrowable set poisons the whole verdict.
# This is the case a per-path selector gets wrong: it narrows on the good paths
# and quietly drops the one it did not understand.
lib_leaf=""
for cand in $(cd "$ROOT/api" && ls lib/barkpark/*.ex 2>/dev/null | head -20); do
  # a leaf: something with a convention test, so §2 has a target
  t="test/${cand#lib/}"; t="${t%.ex}_test.exs"
  [ -f "$ROOT/api/$t" ] && { lib_leaf="api/$cand"; lib_leaf_test="$t"; break; }
done
if [ -z "$lib_leaf" ]; then
  bad "harness setup: found no api/lib/barkpark/*.ex with a convention test" "the whole of §2 cannot run"
else
  ok "harness setup: using $lib_leaf as the leaf fixture"
  assert_all "a narrowable lib file PLUS api/mix.lock still selects ALL" "$lib_leaf
api/mix.lock"
fi

# §1d — a lib file that defines no module.
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/api/lib/barkpark" "$tmp/api/test"
printf '# just a comment, no defmodule\n' >"$tmp/api/lib/barkpark/nomodule.ex"
out="$(printf 'api/lib/barkpark/nomodule.ex\n' | BP_IMPACTED_XREF_DIR="$tmp/api" bash "$SEL" --select 2>/dev/null)"
if is_all "$out"; then ok "a lib file with NO defmodule selects ALL"; else bad "a lib file with NO defmodule selects ALL" "got '$out'"; fi

# §1e — xref cannot succeed -> ALL. Point the selector at a directory that is
# not a mix project, with the no-xref escape hatch OFF, and assert the failure
# arm rather than assuming it.
mkdir -p "$tmp/api2/lib/barkpark" "$tmp/api2/test"
printf 'defmodule Barkpark.Thing do\nend\n' >"$tmp/api2/lib/barkpark/thing.ex"
out="$(printf 'api/lib/barkpark/thing.ex\n' | BP_IMPACTED_NO_XREF=0 BP_IMPACTED_XREF_DIR="$tmp/api2" bash "$SEL" --select 2>/dev/null)"
if is_all "$out"; then ok "a FAILED mix xref selects ALL"; else bad "a FAILED mix xref selects ALL" "got '$(printf '%s' "$out" | head -3 | tr '\n' ' ')'"; fi

echo
echo "=== §2  NARROWING HAPPENS (without these, a selector hard-wired to ALL passes §1)"

if [ -n "$lib_leaf" ]; then
  assert_not_all "a leaf lib change does NOT select ALL" "$lib_leaf"
  assert_selects "a leaf lib change selects its convention test" "$lib_leaf" "$lib_leaf_test"
fi

# a changed test file selects itself
some_test="$(cd "$ROOT/api" && ls test/barkpark/*_test.exs 2>/dev/null | head -1)"
if [ -n "$some_test" ]; then
  assert_selects "a changed test file selects ITSELF" "api/$some_test" "$some_test"
  assert_not_all "a changed test file alone does NOT select ALL" "api/$some_test"
fi

# the selection is a strict subset of the suite — otherwise nothing was bought
if [ -n "$lib_leaf" ]; then
  total="$(cd "$ROOT/api" && find test -name '*_test.exs' | awk 'END{print NR}')"
  got="$(sel "$lib_leaf" | awk 'END{print NR}')"
  if [ "$got" -lt "$total" ] && [ "$got" -gt 0 ]; then
    ok "a leaf lib change selects $got of $total test files (a strict, non-empty subset)"
  else
    bad "a leaf lib change selects a strict non-empty subset" "got $got of $total"
  fi
fi

# THE CROSS-MODULE NET. Pick a module and a test that names it but does NOT sit
# at its convention path; assert the by-name mapper reaches it.
crossed=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  mod="$(sed -nE 's/^[[:space:]]*defmodule[[:space:]]+([A-Za-z0-9_.]+).*/\1/p' "$ROOT/api/$f" | head -1)"
  [ -n "$mod" ] || continue
  conv="test/${f#lib/}"; conv="${conv%.ex}_test.exs"
  other="$(cd "$ROOT/api" && grep -rlF -- "$mod" test --include='*_test.exs' 2>/dev/null | grep -vxF "$conv" | head -1)"
  [ -n "$other" ] || continue
  out="$(sel "api/$f")"
  if ! is_all "$out" && grep -qxF -- "$other" <<<"$out"; then
    ok "the BY-NAME net reaches a non-convention caller: $f -> $other"
    crossed=1
    break
  fi
done <<<"$(cd "$ROOT/api" && ls lib/barkpark/*.ex 2>/dev/null | head -40)"
[ "$crossed" -eq 1 ] || bad "the BY-NAME net reaches a non-convention caller" "no fixture found — the mapper may be dead"

echo
echo "=== §3  THE ALWAYS SET"

always="$(bash "$SEL" --print-always 2>/dev/null)"
n_always="$(sed '/^$/d' <<<"$always" | awk 'END{print NR}')"
if [ "${n_always:-0}" -gt 0 ]; then
  ok "the ALWAYS set is non-empty ($n_always files)"
else
  bad "the ALWAYS set is non-empty" "it is EMPTY — the net is gone"
fi

# every ALWAYS file exists (derived entries come from the tree; pins are checked
# by --check-pins, which is a gate step of its own)
missing=0
while IFS= read -r a; do
  [ -n "$a" ] || continue
  [ -f "$ROOT/api/$a" ] || { missing=$((missing + 1)); echo "         missing: $a"; }
done <<<"$always"
[ "$missing" -eq 0 ] && ok "every ALWAYS file exists on disk" || bad "every ALWAYS file exists on disk" "$missing missing"

# the pins are IN the always set
pins_in=1
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -qxF -- "$p" <<<"$always" || { pins_in=0; echo "         pin not in ALWAYS: $p"; }
done <<<"$(bash "$SEL" --print-pins 2>/dev/null | cut -f1)"
[ "$pins_in" -eq 1 ] && ok "every PINNED entry is in the ALWAYS set" || bad "every PINNED entry is in the ALWAYS set"

# --check-pins is able to REFUSE. Without this the pin check could be a no-op.
mkdir -p "$tmp/api3"
if BP_IMPACTED_XREF_DIR="$tmp/api3" bash "$SEL" --check-pins >/dev/null 2>&1; then
  bad "--check-pins REFUSES when a pinned file is absent" "it passed against an empty tree"
else
  ok "--check-pins REFUSES when a pinned file is absent"
fi
if bash "$SEL" --check-pins >/dev/null 2>&1; then
  ok "--check-pins PASSES on the real tree"
else
  bad "--check-pins PASSES on the real tree" "a pinned ALWAYS entry was renamed or deleted"
fi

# the ALWAYS set rides EVERY narrowed selection
if [ -n "$lib_leaf" ]; then
  out="$(sel "$lib_leaf")"
  net_ok=1
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    grep -qxF -- "$a" <<<"$out" || { net_ok=0; break; }
  done <<<"$always"
  [ "$net_ok" -eq 1 ] && ok "the whole ALWAYS set rides a narrowed selection" || bad "the whole ALWAYS set rides a narrowed selection"
fi

# THE CONTAINMENT THAT LICENSES CLASS 3(b) FOR TEST READERS. Every api/test
# file the escape census names as reading a repo-root path must already be in
# the ALWAYS set — otherwise a census reader could be selected by class 3 and
# NOT by an ordinary lib change, which is a hole with no symptom. Measured 0
# misses when this was written; it is asserted rather than recorded so that a
# new census reader outside the ALWAYS patterns reds instead of slipping in.
census_readers_test="$(bash "$HERE/elixir-path-escape-check.sh" --list-escapes 2>/dev/null | cut -f2 | grep '^api/test/' | sed 's|^api/||' | LC_ALL=C sort -u || true)"
n_readers="$(sed '/^$/d' <<<"$census_readers_test" | awk 'END{print NR}')"
if [ "${n_readers:-0}" -eq 0 ]; then
  bad "the escape census names at least one api/test reader" "it named none — this assertion is vacuous"
else
  cmiss=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -qxF -- "$r" <<<"$always" || { cmiss=$((cmiss + 1)); echo "         census reader not in ALWAYS: $r"; }
  done <<<"$census_readers_test"
  [ "$cmiss" -eq 0 ] && ok "all $n_readers escape-census api/test readers are in the ALWAYS set" || bad "every escape-census api/test reader is in the ALWAYS set" "$cmiss missing"
fi

# THE NET IS NOT THE SUITE. If the ALWAYS set grew to most of the tree the
# narrowing would buy nothing, and nobody would notice from a green gate.
total="$(cd "$ROOT/api" && find test -name '*_test.exs' | awk 'END{print NR}')"
if [ "${n_always:-0}" -lt $((total / 4)) ]; then
  ok "the ALWAYS set is $n_always of $total test files (< 25%, so narrowing still buys something)"
else
  bad "the ALWAYS set is under 25% of the suite" "$n_always of $total — the net has eaten the saving"
fi

echo
echo "=== §4  PAST-DEFECT REPLAY — would this selection have caught real merged bugs?"
#
# A selection rule nobody has shown catching a real past defect is a hope. Each
# row is a MERGED fix from this repo's history: the api/lib file it changed, and
# the api/test file that carries the regression test for it. The assertion is
# that feeding the selector ONLY the lib file selects that test — i.e. on the
# PR that introduced the bug, the narrowed suite would still have had the
# chance to red.
#
# Rows are skipped (loudly) when either side is no longer in the tree, so a
# later rename degrades this to "fewer replays", never to a false pass. The
# count of rows actually exercised is printed and asserted non-zero.
replays=0
replay_skipped=0
replay() {
  local libf="$1" testf="$2" what="$3" out
  if [ ! -f "$ROOT/api/$libf" ] || [ ! -f "$ROOT/api/$testf" ]; then
    replay_skipped=$((replay_skipped + 1))
    echo "  skip — $what (renamed or removed: $libf / $testf)"
    return
  fi
  replays=$((replays + 1))
  out="$(sel "api/$libf")"
  if is_all "$out"; then
    ok "$what — selects ALL (trivially caught)"
  elif grep -qxF -- "$testf" <<<"$out"; then
    ok "$what — the narrowed set contains $testf"
  else
    bad "$what" "$testf is NOT selected by a change to $libf — the narrowing would have MISSED this defect"
  fi
}

# Each row: the file the fix touched, the test that proves the fix.
replay lib/barkpark/content/envelope.ex test/barkpark/content/envelope_internal_sentinel_test.exs "one-envelope reader: the internal sentinel"
replay lib/barkpark/tasks/close.ex test/barkpark/tasks/close_test.exs "the dedup 409 named a required id it withheld"
replay lib/barkpark/tasks/claim.ex test/barkpark/tasks/claim_test.exs "claim epoch CAS"
replay lib/barkpark/search/documents_retriever.ex test/barkpark/search/documents_retriever_tags_meta_parity_test.exs "search insights 500 / nil-workspace synonym read"
replay lib/barkpark_web/router.ex test/barkpark_web/plugin_routes_test.exs "plugin route registration"
replay lib/barkpark/media.ex test/barkpark/media_test.exs "media anonymous read clamp"
replay lib/barkpark/plugins/registry.ex test/barkpark/plugins/registry_test.exs "plugin registry resolution"
replay lib/barkpark/portable_doc/render.ex test/barkpark/portable_doc/render_test.exs "PortableDoc render"
replay lib/barkpark/papers/paper.ex test/barkpark/papers/paper_test.exs "POST /papers refuses ifRev"

if [ "$replays" -gt 0 ]; then
  ok "$replays past-defect replays exercised ($replay_skipped skipped as renamed)"
else
  bad "at least one past-defect replay is exercised" "all $replay_skipped rows were skipped — this section is vacuous"
fi

echo
echo "=== §5  REFUSALS"
if bash "$SEL" --no-such-flag >/dev/null 2>&1; then
  bad "an unknown flag is refused" "it exited 0"
else
  rc=$?
  [ "$rc" -eq 2 ] && ok "an unknown flag is refused with exit 2" || bad "an unknown flag is refused with exit 2" "got rc=$rc"
fi

echo
echo "=== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
