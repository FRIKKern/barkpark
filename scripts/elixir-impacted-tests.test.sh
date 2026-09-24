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
# §6  a stdin-reading child cannot truncate the changed-path list
# §7  a sink-invariant xref is refused (the discriminating control)
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

# §1g — BRANCH (d1) vs (d2): the one-hop extension of the census.
#
# (d1) `cloud/test/**` used to land in (d) and select ALL — 1,892 api test
# files for a PR that edits no api file, measured at 12.8 median minutes per
# run over the 2026-09-18..20 window. It is in the TEST set because
# async_global_seam_guard_test.exs requires scripts/async_env_seam_scan.exs and
# that scanner reads `Path.join(repo_root(), "cloud/test")`. The census
# resolves the api-side literal (the script) and not the script's own literal
# (the tree), so the reader was knowable and unnamed. The selector now takes
# that one hop.
#
# THE TWO ASSERTIONS ARE DIFFERENT QUESTIONS, and the second is the one that
# matters: "not ALL" only says the widening was silenced; "contains the reader
# the hop is FOR" says the narrowing landed on the right files. A selector that
# emitted only the ALWAYS set here would pass the first and fail the second.
# ONE selector run, THREE questions. Each narrowing run is ~20 s of the
# REQUIRED Elixir gate's own selftest step, so re-invoking the selector once
# per assertion would spend the minutes this change exists to save.
ct_path="cloud/test/barkpark_cloud/accounts_test.exs"
ct_err="$(mktemp "${TMPDIR:-/tmp}/bp-ct-err.XXXXXX")"
ct_out="$(printf '%s\n' "$ct_path" | bash "$SEL" --select 2>"$ct_err")"
ct_n="$(printf '%s\n' "$ct_out" | sed '/^$/d' | awk 'END{print NR}')"
if is_all "$ct_out"; then
  bad "a cloud/test-only change NO LONGER selects ALL" "still ALL"
elif [ -z "$ct_out" ]; then
  bad "a cloud/test-only change NO LONGER selects ALL" "EMPTY — the failure this file exists to catch"
else
  ok "a cloud/test-only change NO LONGER selects ALL ($ct_n of $(cd "$ROOT/api" && find test -name '*_test.exs' | awk 'END{print NR}') api test files)"
fi
if grep -qxF -- "test/barkpark/async_global_seam_guard_test.exs" <<<"$ct_out"; then
  ok "…and it selects the seam guard, the api test that actually reads cloud/test"
else
  bad "…and it selects the seam guard, the api test that actually reads cloud/test" "absent from $ct_n files"
fi

# DERIVED, NOT LISTED — and proved by a SECOND INSTRUMENT rather than by
# re-reading the selector's own answer. The harness recomputes the one hop with
# its own pipeline (census -> source files -> their quoted on-disk path
# literals -> back to the readers) and asserts the selector's derived reader
# set is exactly that. A hard-coded list inside the selector would diverge from
# this join the first time the tree moved; a snapshot of today's answer would
# not.
tmp_ext_rows="$(mktemp "${TMPDIR:-/tmp}/bp-ext-rows.XXXXXX")"
bash "$HERE/elixir-path-escape-check.sh" --list-escapes 2>/dev/null \
  | awk -F'\t' '{print $1 "\t" $2}' | LC_ALL=C sort -u >"$tmp_ext_rows" || true
ext_expect="$(
  cut -f1 "$tmp_ext_rows" | LC_ALL=C sort -u | while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ "$s" = "scripts/elixir-path-escape-check.sh" ] && continue
    [ -f "$ROOT/$s" ] || continue
    grep -ohaE '"[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_.-]+)+"' -- "$ROOT/$s" </dev/null 2>/dev/null \
      | tr -d '"' | LC_ALL=C sort -u | while IFS= read -r t; do
        [ -n "$t" ] || continue
        [ -e "$ROOT/$t" ] || continue
        [ "$t" = "cloud/test" ] || continue
        awk -F'\t' -v s="$s" '$1 == s { print $2 }' "$tmp_ext_rows"
      done
  done | LC_ALL=C sort -u
)"
rm -f -- "$tmp_ext_rows"
ext_got="$(sed -n 's/.*DERIVED readers are: //p' "$ct_err" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u)"
rm -f -- "$ct_err"
if [ -z "$ext_expect" ]; then
  bad "the independent one-hop join finds a reader for cloud/test" "it found NONE — the control itself is measuring nothing"
elif [ "$ext_got" = "$ext_expect" ]; then
  ok "the selector's derived readers for cloud/test EQUAL an independently computed one-hop join ($(printf '%s\n' "$ext_expect" | awk 'END{print NR}') reader(s))"
else
  bad "the selector's derived readers EQUAL an independent one-hop join" "selector: [$(printf '%s' "$ext_got" | tr '\n' ' ')] independent: [$(printf '%s' "$ext_expect" | tr '\n' ' ')]"
fi

# (d2) THE MUTATION CONTROL, and the reason this block is not just three greens
# in a row. The danger of naming readers is SILENCING A CORRECT WIDENING, so a
# TEST-set path that the census and its one-hop extension BOTH fail to name
# must still select ALL. internal/taskboard/board.go is the sharpest specimen
# available: three of its SIBLINGS (components.go, tokens_gen.go, testdata/)
# are censused, so a derivation that widened from a file to its directory —
# the most likely wrong way to build this — would narrow it. It must not.
assert_all "(d2) internal/taskboard/board.go — a TEST-set path whose SIBLINGS are censused but which nothing reads — still selects ALL" "internal/taskboard/board.go"
assert_all "(d2) cmd/barkpark/testdata/** with no censused reader still selects ALL" "cmd/barkpark/testdata/nothing-reads-this.json"
assert_all "(d2) web/node_modules/** still selects ALL" "web/node_modules/left-pad/index.js"

# THE OTHER HALF OF THE MUTATION: the paths that MUST keep widening for a
# reason that has nothing to do with the census. The gate scripts and the
# workflow are in the COMPILE set and are answered by branch (a) BEFORE any
# census lookup, so the hop cannot reach them.
assert_all "(a) scripts/elixir-impacted-tests.sh still selects ALL" "scripts/elixir-impacted-tests.sh"
assert_all "(a) scripts/elixir-path-escape-check.sh still selects ALL" "scripts/elixir-path-escape-check.sh"
assert_all "(a) a cloud/test change PLUS a gate-script change still selects ALL" "cloud/test/barkpark_cloud/accounts_test.exs
scripts/elixir-path-escape-check.sh"
assert_all "(a) a cloud/test change PLUS an api/ non-narrowable path still selects ALL" "cloud/test/barkpark_cloud/accounts_test.exs
api/mix.lock"

# §1b — the empty diff. Same polarity as the elixir.yml dispatcher's own empty
# arm: rare but legal, and a narrow answer from no information is the unsafe one.
out="$(printf '' | bash "$SEL" --select 2>/dev/null)"
if is_all "$out"; then ok "an EMPTY changed-path set selects ALL"; else bad "an EMPTY changed-path set selects ALL" "got '$out'"; fi

# §1c — ONE bad path in an otherwise narrowable set poisons the whole verdict.
# This is the case a per-path selector gets wrong: it narrows on the good paths
# and quietly drops the one it did not understand.
lib_leaf=""
for cand in $(cd "$ROOT/api" && ls lib/barkpark/*.ex 2>/dev/null | head -60); do
  # a leaf: something with a convention test, so §2 has a target — and NOT a
  # RULE 4 door, which selects ALL by design and would make every §2 assertion
  # below read as a regression. The predicate is asked, never hard-coded: the
  # first candidate on this tree (lib/barkpark/access.ex) IS a door, and the
  # next file to become one must not silently turn §2 red.
  t="test/${cand#lib/}"; t="${t%.ex}_test.exs"
  [ -f "$ROOT/api/$t" ] || continue
  bash "$SEL" --is-door "api/$cand" >/dev/null 2>&1 && continue
  lib_leaf="api/$cand"; lib_leaf_test="$t"; break
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
echo "=== §2b  RULE 3 — the web-surface hop (the #17153 blind spot)"
#
# THE DEFECT THIS SECTION EXISTS FOR. #17153 changed api/lib/barkpark/tasks/landed.ex,
# the selector narrowed to 263 of 1676 files, the required gate went green, and
# main reddened at test/barkpark_web/controllers/tasks_landed_test.exs:115. That
# test is a `use BarkparkWeb.ConnCase` HTTP contract test: it reaches the changed
# context over the ROUTER and names no module the closure or the by-name test
# grep could see.
#
# Both arms below are needed. The positive one alone is satisfied by a rule that
# selects the whole controllers/ tree; the negative one alone is satisfied by a
# rule that selects nothing.

# ── the real specimen, on the real tree ────────────────────────────────────
# THE #17153 SPECIMEN IS NOW ALSO A RULE 4 DOOR. lib/barkpark/tasks/landed.ex
# returns `{:error, :…_required}`, so RULE 4 (added for #18085) claims it first
# and the selection is ALL — a strict SUPERSET of what RULE 3 would have
# selected, so the #17153 defect is still caught, but this arm can no longer
# measure RULE 3 through it. Asked of the predicate, never assumed: if landed.ex
# stops being a door the original assertion comes straight back.
specimen_lib="api/lib/barkpark/tasks/landed.ex"
specimen_test="test/barkpark_web/controllers/tasks_landed_test.exs"
specimen_is_door=0
if bash "$SEL" --is-door "$specimen_lib" >/dev/null 2>&1; then specimen_is_door=1; fi

if [ ! -f "$ROOT/${specimen_lib}" ] || [ ! -f "$ROOT/api/${specimen_test}" ]; then
  bad "the #17153 specimen is still in the tree" "$specimen_lib / $specimen_test — the arm below cannot run"
elif [ "$specimen_is_door" -eq 1 ]; then
  assert_all "the #17153 specimen is now a RULE 4 door — it selects ALL, a superset of RULE 3's answer" "$specimen_lib"
else
  # The PRECONDITION, asserted rather than assumed: if the contract test ever
  # starts naming the module, the by-name net reaches it and this arm stops
  # measuring RULE 3 while still passing. Red on that instead.
  if grep -qF 'Tasks.Landed' "$ROOT/api/${specimen_test}" 2>/dev/null; then
    bad "the specimen contract test names NO module of the changed context" \
        "$specimen_test now names Tasks.Landed — the by-name net reaches it, so this arm no longer measures the web-surface hop"
  else
    ok "precondition: $specimen_test names no module of the changed context (so only RULE 3 can reach it)"
    assert_selects "a changed context selects its web surface's ConnCase contract test" "$specimen_lib" "$specimen_test"
  fi
fi

# ── a DERIVED real-tree specimen, so RULE 3 stays measured on the real tree ─
# Found by the definition of the rule rather than by a remembered filename: a
# NON-door lib module whose selection contains a web test that (i) is not in the
# ALWAYS set, (ii) names none of the module's modules, and (iii) is therefore
# reachable ONLY by the lib->lib hop. The first hit wins; the search is bounded.
always_for_r3="$(bash "$SEL" --print-always 2>/dev/null)"
r3_lib=""; r3_test=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  bash "$SEL" --is-door "api/$cand" >/dev/null 2>&1 && continue
  cand_mods="$(sed -nE 's/^[[:space:]]*defmodule[[:space:]]+([A-Za-z0-9_.]+).*/\1/p' "$ROOT/api/$cand")"
  [ -n "$cand_mods" ] || continue
  cand_out="$(sel "api/$cand")"
  is_all "$cand_out" && continue
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    grep -qxF -- "$wt" <<<"$always_for_r3" && continue
    named=0
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      grep -qF -- "$m" "$ROOT/api/$wt" 2>/dev/null && named=1
    done <<<"$cand_mods"
    [ "$named" -eq 1 ] && continue
    r3_lib="api/$cand"; r3_test="$wt"; break
  done <<<"$(grep '^test/barkpark_web/' <<<"$cand_out" || true)"
  [ -n "$r3_lib" ] && break
done <<<"$(cd "$ROOT/api" && find lib/barkpark -name '*.ex' -not -path 'lib/barkpark_web/*' | LC_ALL=C sort | head -60)"

if [ -z "$r3_lib" ]; then
  bad "a RULE-3-only specimen exists on the real tree" "none found in 60 candidates — the lib->lib hop may be dead on the real tree"
else
  ok "derived RULE-3-only specimen: $r3_lib -> $r3_test (not in ALWAYS, names no module of the change)"
  assert_selects "the derived specimen's web test IS selected by the lib->lib hop" "$r3_lib" "$r3_test"

  # ── the negative control: a FAMILY, not the directory ────────────────────
  # A rule that answered "every web test" would satisfy the arm above and buy
  # nothing. Count what the specimen actually drags out of test/barkpark_web/
  # beyond the ALWAYS set, and compare it against the directory.
  web_total="$(cd "$ROOT/api" && find test/barkpark_web -name '*_test.exs' | awk 'END{print NR}')"
  sel_out="$(sel "$r3_lib")"
  web_sel="$(grep -c '^test/barkpark_web/' <<<"$sel_out" || true)"
  if [ "${web_total:-0}" -gt 0 ] && [ "${web_sel:-0}" -gt 0 ] && [ "$web_sel" -lt "$web_total" ]; then
    ok "the derived specimen selects $web_sel of $web_total web tests — a family, not the directory"
  else
    bad "the derived specimen selects a strict subset of test/barkpark_web/" "got $web_sel of $web_total"
  fi
fi

# ── a synthetic tree, because the real one cannot be mutated ───────────────
# lib/barkpark/widgets/gizmo.ex  <- the changed context
# lib/barkpark_web/controllers/gizmo_controller.ex  <- names it (the lib->lib hop)
# test/barkpark_web/controllers/gizmo_wire_test.exs <- names NEITHER module
# test/barkpark_web/controllers/unrelated_thing_test.exs <- must stay out
mkdir -p "$tmp/api4/lib/barkpark/widgets" "$tmp/api4/lib/barkpark_web/controllers" "$tmp/api4/test/barkpark_web/controllers"
printf 'defmodule Barkpark.Widgets.Gizmo do\n  def record(_), do: :ok\nend\n' >"$tmp/api4/lib/barkpark/widgets/gizmo.ex"
printf 'defmodule BarkparkWeb.GizmoController do\n  alias Barkpark.Widgets.Gizmo\n  def create(c, _), do: Gizmo.record(c)\nend\n' >"$tmp/api4/lib/barkpark_web/controllers/gizmo_controller.ex"
printf 'defmodule BarkparkWeb.GizmoWireTest do\n  use BarkparkWeb.ConnCase, async: true\n  test "POST /v1/gizmos", %%{conn: conn} do\n    assert conn\n  end\nend\n' >"$tmp/api4/test/barkpark_web/controllers/gizmo_wire_test.exs"
printf 'defmodule BarkparkWeb.UnrelatedThingTest do\n  use BarkparkWeb.ConnCase, async: true\nend\n' >"$tmp/api4/test/barkpark_web/controllers/unrelated_thing_test.exs"

# the planted contract test names neither module — assert it, or the fixture is
# proving the by-name net instead of RULE 3
if grep -qE 'Barkpark\.Widgets\.Gizmo|GizmoController' "$tmp/api4/test/barkpark_web/controllers/gizmo_wire_test.exs"; then
  bad "the planted contract test names no module" "the fixture would be caught by the by-name net — it proves nothing about RULE 3"
else
  ok "the planted contract test names neither the context nor its controller"
fi

synth_out="$(printf 'api/lib/barkpark/widgets/gizmo.ex\n' | BP_IMPACTED_XREF_DIR="$tmp/api4" bash "$SEL" --select 2>/dev/null)"
if is_all "$synth_out"; then
  bad "the planted ConnCase contract test is selected" "the synthetic tree selected ALL"
elif grep -qxF 'test/barkpark_web/controllers/gizmo_wire_test.exs' <<<"$synth_out"; then
  ok "a planted ConnCase contract test for a lib module IS selected (the lib->lib hop, then the name family)"
else
  bad "the planted ConnCase contract test is selected" "not in the $(printf '%s\n' "$synth_out" | awk 'END{print NR}')-file selection"
fi
if grep -qxF 'test/barkpark_web/controllers/unrelated_thing_test.exs' <<<"$synth_out"; then
  bad "an unrelated controller test in the SAME directory stays out" "unrelated_thing_test.exs was dragged in — the rule is a directory scan, not a family"
else
  ok "an unrelated controller test in the same directory stays out"
fi

# a lib module NO web surface names must add no web tests at all
printf 'defmodule Barkpark.Widgets.Hermit do\nend\n' >"$tmp/api4/lib/barkpark/widgets/hermit.ex"
herm_out="$(printf 'api/lib/barkpark/widgets/hermit.ex\n' | BP_IMPACTED_XREF_DIR="$tmp/api4" bash "$SEL" --select 2>/dev/null)"
if is_all "$herm_out"; then
  bad "a lib module no web surface names drags in no controller test" "it selected ALL"
elif grep -q '^test/barkpark_web/controllers/' <<<"$herm_out"; then
  bad "a lib module no web surface names drags in no controller test" "it selected $(grep -c '^test/barkpark_web/controllers/' <<<"$herm_out")"
else
  ok "a lib module NO web surface names drags in no controller test (the hop is a hop, not a default)"
fi

echo
echo "=== §2c  RULE 4 — the fail-closed door (the #18085 blind spot)"
#
# THE DEFECT THIS SECTION EXISTS FOR. #18085 (head 02d74f815, job 103713658033)
# changed api/lib/barkpark/content/write_scope.ex so an unresolved write from an
# attributable caller REFUSES. The selector narrowed to 563 test files, the
# required Elixir gate went 4/4 green, it merged, and main reddened on the same
# base at api/test/barkpark/search/indx_engine_scope_test.exs with
# MatchError {:error, :workspace_scope_required} — a test that calls
# Content.create_document/4 and reaches the door at RUNTIME without naming it.
#
# Four arms, and all four are needed. (a) is satisfied by a script hard-wired to
# ALL, so (b) and (c) are the negative controls that make it mean something;
# (d) is the census bound, without which RULE 4 could eat the whole selector and
# every other case in this file would still pass.

door_lib="api/lib/barkpark/content/write_scope.ex"
door_test="test/barkpark/search/indx_engine_scope_test.exs"

# ── the PRECONDITION, asserted rather than assumed ─────────────────────────
# If the failing test ever starts naming the door module, the ordinary by-name
# net reaches it and this section stops measuring RULE 4 while still passing.
if [ ! -f "$ROOT/$door_lib" ] || [ ! -f "$ROOT/api/$door_test" ]; then
  bad "the #18085 specimen is still in the tree" "$door_lib / api/$door_test — §2c cannot run"
elif grep -qF 'Barkpark.Content.WriteScope' "$ROOT/api/$door_test" 2>/dev/null; then
  bad "the specimen test names NO module of the door it passes through" \
      "$door_test now names Barkpark.Content.WriteScope — the by-name net reaches it, so this section no longer measures RULE 4"
else
  ok "precondition: $door_test names no module of the door it calls through (so only RULE 4 can reach it)"

  # (a) the predicate classifies the real door
  if bash "$SEL" --is-door "$door_lib" >/dev/null 2>&1; then
    ok "the predicate classifies $door_lib as a door"
  else
    bad "the predicate classifies $door_lib as a door" "--is-door exited non-zero"
  fi

  assert_all "a change confined to the door selects ALL" "$door_lib"

  # ── THE REPLAY of #18085's OWN twelve-path diff, not a stand-in ──────────
  # The camouflage that made the original miss invisible is in this list: five
  # sibling TEST files were edited and therefore selected, so the selection
  # looked complete while the one unedited test the change broke never ran.
  replay_18085="api/lib/barkpark/content/tag_registry.ex
api/lib/barkpark/content/write_scope.ex
api/lib/barkpark/plugins/bootstrap.ex
api/lib/barkpark/plugins/tickets/thread.ex
api/lib/mix/tasks/onix.import.ex
api/test/barkpark/audit_test.exs
api/test/barkpark/content/graph_test.exs
api/test/barkpark/content/mutation_echo_test.exs
api/test/barkpark/content/owner_scoped_test.exs
api/test/barkpark/content/write_scope_classified_door_test.exs
api/test/barkpark_web/controllers/listen_controller_test.exs
api/test/barkpark_web/live/bulldocs_live_test.exs"
  replay_out="$(sel "$replay_18085")"
  if is_all "$replay_out"; then
    ok "REPLAY #18085: its twelve-path diff selects ALL — $door_test runs"
  elif grep -qxF -- "$door_test" <<<"$replay_out"; then
    ok "REPLAY #18085: $door_test is in the narrowed selection"
  else
    bad "REPLAY #18085: the selection reaches $door_test" \
        "it is NOT in the $(printf '%s\n' "$replay_out" | awk 'END{print NR}')-file selection — the original miss is unfixed"
  fi
fi

# ── (b)(c) the MUTATION MATRIX, on a synthetic tree ───────────────────────
# Three modules that differ ONLY in the property RULE 4 keys on. Without the
# middle one, a rule that answered ALL for any lib file would pass.
mkdir -p "$tmp/api5/lib/barkpark/gate" "$tmp/api5/test/barkpark/gate"
printf 'defmodule Barkpark.Gate.Refuser do\n  def check(_), do: {:error, :workspace_scope_required}\nend\n' >"$tmp/api5/lib/barkpark/gate/refuser.ex"
printf 'defmodule Barkpark.Gate.Polite do\n  def check(_), do: {:error, :nope}\nend\n' >"$tmp/api5/lib/barkpark/gate/polite.ex"
printf 'defmodule Barkpark.Gate.Declared do\n  # @impact door — refuses with a vocabulary the derived arm does not know\n  def check(_), do: {:error, :nope}\nend\n' >"$tmp/api5/lib/barkpark/gate/declared.ex"
printf 'defmodule Barkpark.Gate.PoliteTest do\n  use ExUnit.Case\nend\n' >"$tmp/api5/test/barkpark/gate/polite_test.exs"

synth_door() { printf '%s\n' "$1" | BP_IMPACTED_XREF_DIR="$tmp/api5" bash "$SEL" --select 2>/dev/null; }

out="$(synth_door api/lib/barkpark/gate/refuser.ex)"
if is_all "$out"; then ok "a module returning a policy refusal selects ALL (the derived arm)"; else bad "a module returning a policy refusal selects ALL" "got $(printf '%s\n' "$out" | awk 'END{print NR}') files"; fi

out="$(synth_door api/lib/barkpark/gate/declared.ex)"
if is_all "$out"; then ok "a module carrying '@impact door' selects ALL even with no known refusal atom (the declared arm)"; else bad "a module carrying '@impact door' selects ALL" "got $(printf '%s\n' "$out" | awk 'END{print NR}') files"; fi

# THE NEGATIVE CONTROL. Same tree, same shape, no refusal vocabulary and no
# declaration: it must still narrow, or RULE 4 is just `echo ALL`.
out="$(synth_door api/lib/barkpark/gate/polite.ex)"
if is_all "$out"; then
  bad "an ordinary lib module is NOT a door" "it selected ALL — RULE 4 is not keyed on the refusal vocabulary at all"
elif [ -z "$out" ]; then
  bad "an ordinary lib module is NOT a door" "it selected EMPTY"
else
  ok "an ordinary lib module in the same tree still NARROWS ($(printf '%s\n' "$out" | awk 'END{print NR}') files) — RULE 4 is keyed on the refusal, not on being a lib file"
fi

# ── (d) THE CENSUS BOUND. A door class that grew to most of lib would make the
# selector an expensive `echo ALL`, and every arm above would still pass.
doors_n="$(bash "$SEL" --doors 2>/dev/null | sed '/^$/d' | awk 'END{print NR}')"
lib_n="$(cd "$ROOT/api" && find lib -name '*.ex' | awk 'END{print NR}')"
if [ "${doors_n:-0}" -eq 0 ]; then
  bad "the door census is non-empty" "it named none — RULE 4 is inert and §2c's real-tree arm cannot be measuring it"
elif [ "$doors_n" -lt $((lib_n / 7)) ]; then
  ok "the door census is $doors_n of $lib_n lib modules (< 15%, so narrowing still buys something)"
else
  bad "the door census is under 15% of lib" "$doors_n of $lib_n — RULE 4 has eaten the selection"
fi

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

# A `mix` stand-in for the sections that run the xref path for real (§6, §7).
#   varying   — answers PER SINK, the shape a working xref has: the hub
#               (lib/barkpark/plugin.ex) gets its `use Barkpark.Plugin`
#               dependents, the leaf (lib/barkpark/tasks/landed.ex) gets
#               nothing, anything else a small graph with `.ex` in it.
#   invariant — ONE fixed graph whatever --sink says: the shape measured on
#               CI's Elixir 1.18.4 / OTP 27 pin (task-37b4448cb9ccb000).
#   inverted  — varies, but the leaf's graph is BIGGER than the hub's.
# `greedy` adds a child that drains stdin (§6's mutation).
write_mix_stub() {
  local out="$1" shape="$2" greedy="${3:-}"
  {
    echo '#!/usr/bin/env bash'
    [ "$greedy" = greedy ] && echo 'cat >/dev/null 2>&1 || true'
    # shellcheck disable=SC2016 # the stub's own code, written literally
    echo 'sink=""; while [ "$#" -gt 0 ]; do [ "$1" = "--sink" ] && sink="${2:-}"; shift; done'
    case "$shape" in
      varying)
        cat <<'STUB'
case "$sink" in
  lib/barkpark/plugin.ex) printf '%s\n' "lib/barkpark/plugins/media.ex" "\`-- lib/barkpark/plugin.ex (compile)" "lib/barkpark/plugins/quiz.ex" "\`-- lib/barkpark/plugin.ex (compile)" ;;
  lib/barkpark/tasks/landed.ex) : ;;
  *) printf '%s\n' "lib/barkpark/content/lifecycle.ex" "lib/barkpark/repo.ex" ;;
esac
STUB
        ;;
      invariant)
        cat <<'STUB'
printf '%s\n' "lib/barkpark_web/router.ex" "\`-- lib/barkpark_web/router/plugins.ex (compile)" "lib/barkpark/tasks/events.ex" "\`-- lib/barkpark/tasks/internal.ex (compile)"
STUB
        ;;
      inverted)
        cat <<'STUB'
case "$sink" in
  lib/barkpark/plugin.ex) printf '%s\n' "lib/barkpark/plugins/media.ex" ;;
  lib/barkpark/tasks/landed.ex) printf '%s\n' "lib/barkpark_web/router.ex" "lib/barkpark/tasks/events.ex" ;;
  *) printf '%s\n' "lib/barkpark/content/lifecycle.ex" "lib/barkpark/repo.ex" ;;
esac
STUB
        ;;
    esac
  } >"$out"
  chmod +x "$out"
}

echo
echo "=== §6  A CHILD THAT READS STDIN MUST NOT TRUNCATE THE CHANGED-PATH LIST"
# THE DEFECT THIS SECTION EXISTS FOR (task-627ab62e43790c0e). The classify loop
# was fed `done <<EOF $changed EOF`, putting the changed-path list on the loop
# body's fd 0. `compile_closure`/`xref_probe` start `mix` inside that body; on
# the runner the BEAM drains the pipe bash 5.x backs a here-document with, so
# `read` hit EOF and every path after the first lib file went UNCLASSIFIED —
# with no non-zero status, no stderr, and no `ALL`. #19303 (e58d8bbcd) narrowed
# to 596 files that way, the required Elixir gate went green, and the nightly
# found 31 failures 23 hours later.
#
# WHY §1-§5 COULD NOT SEE IT: every case above runs under BP_IMPACTED_NO_XREF=1
# (line ~34), so no child process is ever started inside the loop and the loop's
# fd is never at risk. The harness was structurally blind to the one failure
# mode the selector exists to prevent. This section is the only one that starts
# a real child, so it must NOT inherit that export.
sec6_dir="$(mktemp -d "${TMPDIR:-/tmp}/bp-impacted-sec6.XXXXXX")"
# Two `mix` stand-ins, identical but for ONE line: whether the child reads stdin.
# That single-line difference IS the mutation. Both answer PER SINK (see
# write_mix_stub): a stub that printed one fixed graph for every --sink would be
# refused by the discriminating control (§7) before §6 measured anything.
write_mix_stub "$sec6_dir/mix-quiet" varying
write_mix_stub "$sec6_dir/mix-greedy" varying greedy
chmod +x "$sec6_dir/mix-quiet" "$sec6_dir/mix-greedy"

# A lib file FIRST (so a child runs), then a changed test file that
# `is_narrowable_test` selects unconditionally. If the list is truncated, that
# second path silently disappears — which is exactly the shape to catch.
sec6_input='api/lib/barkpark/content/lifecycle.ex
api/test/barkpark/tasks/queue_test.exs'
sec6_want='test/barkpark/tasks/queue_test.exs'

sec6_run() {
  mkdir -p "$sec6_dir/bin" && cp "$sec6_dir/$1" "$sec6_dir/bin/mix"
  printf '%s\n' "$sec6_input" | \
    env -u BP_IMPACTED_NO_XREF \
        BP_IMPACTED_ROOT="$ROOT" \
        PATH="$sec6_dir/bin:$PATH" \
        bash "$SEL" --select 2>/dev/null
}

if [ ! -f "$ROOT/api/lib/barkpark/content/lifecycle.ex" ] || [ ! -f "$ROOT/api/$sec6_want" ]; then
  bad "§6 fixtures are present" "lifecycle.ex or $sec6_want is gone — §6 measured NOTHING"
else
  # THE CONTROL, AND IT IS NOT OPTIONAL. Without it a selector that answered
  # ALL to everything would pass the greedy case below while measuring nothing.
  sec6_quiet="$(sec6_run mix-quiet)"
  if is_all "$sec6_quiet"; then
    bad "§6 control: a quiet child still narrows" "got ALL — §6's greedy arm can no longer mean anything"
  elif grep -qxF -- "$sec6_want" <<<"$sec6_quiet"; then
    ok "§6 control: a child that does NOT read stdin leaves the list intact ($sec6_want selected)"
  else
    bad "§6 control: a quiet child keeps $sec6_want" "it is missing even with a non-draining child"
  fi

  # THE MUTATION. Same input, same script, one greedy child. Two answers are
  # acceptable and they are the two SAFE ones: the list survived (the fd fix
  # held), or the selector noticed it did not and widened to ALL (the count
  # identity held). The one answer that must never occur is the one CI gave:
  # a narrow selection that quietly lacks the path it never read.
  sec6_greedy="$(sec6_run mix-greedy)"
  if is_all "$sec6_greedy"; then
    ok "§6 a stdin-reading child is caught and widens to ALL (the count identity held)"
  elif grep -qxF -- "$sec6_want" <<<"$sec6_greedy"; then
    ok "§6 a stdin-reading child cannot reach the list ($sec6_want still selected)"
  else
    bad "§6 a stdin-reading child must not silently truncate the changed-path list" \
        "the selection NARROWED to $(grep -c . <<<"$sec6_greedy") files and $sec6_want — a path handed in on stdin — is not among them. This is the #19303 fault: a green gate over code it never ran."
  fi
fi
rm -rf -- "$sec6_dir"

echo
echo "=== §7  A SINK-INVARIANT xref IS REFUSED, NOT NARROWED ON (task-37b4448cb9ccb000)"
# THE DEFECT. `mix xref graph --sink S --label compile-connected` printed the
# SAME 10-line graph (md5 6d8d306d06f1628f5a38755f53898b71) for landed.ex,
# media.ex, accounts.ex and plugin.ex on CI's own pin, Elixir 1.18.4 / OTP 27.
# The repo.ex positive control passed it, because it only asks for `.ex` in the
# output. The selector then narrowed every lib change on a constant.
#
# THREE ARMS, one stub each (write_mix_stub): invariant must be REFUSED by name,
# varying must be TRUSTED (the control — without it, a probe hard-wired to DEAD
# passes the first arm while measuring nothing), inverted must be refused too.
sec7_dir="$(mktemp -d "${TMPDIR:-/tmp}/bp-impacted-sec7.XXXXXX")"
sec7_input='api/lib/barkpark/content/lifecycle.ex'
sec7_run() {
  # $1 = stub shape; stdout -> $sec7_dir/out, stderr -> $sec7_dir/err
  mkdir -p "$sec7_dir/bin"
  write_mix_stub "$sec7_dir/bin/mix" "$1"
  printf '%s\n' "$sec7_input" | \
    env -u BP_IMPACTED_NO_XREF \
        BP_IMPACTED_ROOT="$ROOT" \
        PATH="$sec7_dir/bin:$PATH" \
        bash "$SEL" --select >"$sec7_dir/out" 2>"$sec7_dir/err"
}
sec7_probe_rc() {
  mkdir -p "$sec7_dir/bin"
  write_mix_stub "$sec7_dir/bin/mix" "$1"
  env -u BP_IMPACTED_NO_XREF BP_IMPACTED_ROOT="$ROOT" PATH="$sec7_dir/bin:$PATH" \
    bash "$SEL" --xref-probe >/dev/null 2>&1
}
sec7_named='xref is SINK-INVARIANT: --sink lib/barkpark/plugin.ex and --sink lib/barkpark/tasks/landed.ex returned the IDENTICAL closure'

if [ ! -f "$ROOT/api/lib/barkpark/content/lifecycle.ex" ] || [ ! -f "$ROOT/api/lib/barkpark/plugin.ex" ] || [ ! -f "$ROOT/api/lib/barkpark/tasks/landed.ex" ]; then
  bad "§7 fixtures are present" "lifecycle.ex, plugin.ex or landed.ex is gone — §7 measured NOTHING"
else
  # CONTROL: a per-sink answer narrows.
  sec7_run varying
  sec7_out="$(cat "$sec7_dir/out")"
  if is_all "$sec7_out" || [ -z "$sec7_out" ]; then
    bad "§7 control: a sink-VARYING xref is trusted and narrows" "got '$(head -c 200 "$sec7_dir/out")' / stderr: $(head -3 "$sec7_dir/err" | tr '\n' ' ')"
  else
    ok "§7 control: a sink-VARYING xref is trusted and narrows ($(grep -c . <<<"$sec7_out") files)"
  fi
  if sec7_probe_rc varying; then ok "§7 control: --xref-probe says OK for a sink-varying xref"; else bad "§7 control: --xref-probe says OK for a sink-varying xref" "it exited non-zero"; fi

  # THE ARM: one graph for every sink -> ALL, and the refusal names both sinks.
  sec7_run invariant
  sec7_out="$(cat "$sec7_dir/out")"
  if ! is_all "$sec7_out"; then
    bad "§7 a SINK-INVARIANT xref falls back to ALL" "it NARROWED to $(grep -c . <<<"$sec7_out") files on a closure that does not depend on the changed file"
  elif ! grep -qF -- "narrowing unavailable: running ALL" "$sec7_dir/err"; then
    bad "§7 a SINK-INVARIANT xref falls back to ALL, naming both sinks" "ALL, but stderr lacks the fallback line 'narrowing unavailable: running ALL' (main ruling 2026-09-24)"
  elif grep -qF -- "$sec7_named" "$sec7_dir/err"; then
    ok "§7 a SINK-INVARIANT xref falls back to ALL, naming both sinks"
  else
    bad "§7 a SINK-INVARIANT xref falls back to ALL, naming both sinks" "ALL, but stderr lacks the named line: $(head -3 "$sec7_dir/err" | tr '\n' ' ')"
  fi
  if sec7_probe_rc invariant; then bad "§7 --xref-probe reports DEAD for a sink-invariant xref" "it exited 0 (OK)"; else ok "§7 --xref-probe reports DEAD for a sink-invariant xref"; fi

  # A leaf whose closure is not smaller than the hub's does not discriminate either.
  sec7_run inverted
  sec7_out="$(cat "$sec7_dir/out")"
  if is_all "$sec7_out" && grep -qF -- 'xref does not discriminate' "$sec7_dir/err"; then
    ok "§7 a leaf closure BIGGER than the hub's falls back to ALL"
  else
    bad "§7 a leaf closure BIGGER than the hub's falls back to ALL" "got $(grep -c . <<<"$sec7_out") lines / stderr: $(head -3 "$sec7_dir/err" | tr '\n' ' ')"
  fi
fi
rm -rf -- "$sec7_dir"

echo
echo "=== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
