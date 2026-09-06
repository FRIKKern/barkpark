#!/usr/bin/env bash
# elixir-impacted-tests.sh — WHICH ExUnit files does THIS pull request need?
#
# ── WHAT THIS IS, AND THE ONE FAILURE MODE IT IS BUILT AGAINST ─────────────
#
# `mix test` over api/ is 1,458 files and ~900 s, and it is the required gate
# every PR waits on. Running only the impacted subset on a PR is how CI gets
# fast. It is ALSO exactly how a suite goes quietly blind: a selector that
# cannot classify a path, selects nothing, and reports a green required
# context is strictly worse than no selector at all.
#
# So this script has exactly two possible answers, and the safe one is the
# DEFAULT:
#
#     ALL                  <- run the whole suite. Emitted for every input this
#                             script cannot positively narrow: an unrecognised
#                             path, an empty diff, a failed xref, a lib file
#                             with no module in it, a missing tool.
#     <test file paths>    <- emitted ONLY after a positive determination that
#                             every changed path is narrowable AND the closure
#                             computation succeeded.
#
# It NEVER emits an empty selection. `--select` printing nothing is not a
# reachable state: the ALWAYS set below is non-empty by construction and is
# asserted non-empty before anything is printed.
#
# ── WHY A PR MAY NARROW AT ALL ────────────────────────────────────────────
#
# Because main does not. `.github/workflows/elixir.yml`'s dispatcher emits
# every path set `true` on any event that is not a `pull_request`, so every
# push to main runs the entire suite at its own sha, and elixir-nightly.yml
# runs it again with `--include flaky --include requires_node`. A PR-time
# selector is therefore a LATENCY optimisation sitting in front of two
# unnarrowed nets, not a coverage decision. Anything the selection misses is
# caught on main before it can compound — and the attribution watcher
# (.github/workflows/elixir-main-red-attribution.yml) files a row naming the
# merge sha when that happens, so the miss is a measured event and not a
# surprise.
#
# THE RISK, STATED PLAINLY AND NOT PAPERED OVER: a PR-time selector reads
# COMPILE-TIME edges. It cannot see a runtime-only caller — a module reached
# through a registry lookup, a `String.to_existing_atom` dispatch, a
# `Application.get_env`-configured implementation, a Phoenix route assembled
# from a plugin list. The ALWAYS set below is the deliberate net under that
# blind spot, and main-per-sha plus the nightly is the net under the net.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#
#   git diff --name-only HEAD^1 HEAD | scripts/elixir-impacted-tests.sh --select
#   scripts/elixir-impacted-tests.sh --print-always     # the safety net, derived
#   scripts/elixir-impacted-tests.sh --selftest         # the mutation matrix
#
# `--select` reads REPO-ROOT-relative changed paths on stdin and prints
# API-relative test paths (what `cd api && mix test <paths>` wants), or the
# single token `ALL`.
#
# Env:
#   BP_IMPACTED_XREF_DIR   directory to run `mix xref` in (default: api)
#   BP_IMPACTED_NO_XREF=1  skip xref entirely; the closure degrades to the
#                          changed file plus the by-name net. Used by the
#                          selftest, which has no compiled build.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BP_IMPACTED_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
API_DIR="${BP_IMPACTED_XREF_DIR:-$REPO_ROOT/api}"

# ---------------------------------------------------------------------------
# THE NARROWABLE WHITELIST — the fail-safe, and the whole safety argument
# ---------------------------------------------------------------------------
# The `changes` dispatcher in elixir.yml only reaches this script when the TEST
# path set matched, and that set is `api/**` plus a dozen sibling trees
# (scripts/elixir-path-escape-check.sh: ELIXIR_COMPILE_PATHS +
# ELIXIR_TEST_ONLY_PATHS). This script narrows a STRICT SUBSET of that:
#
#     api/lib/**/*.ex          — Elixir source, has a compile closure
#     api/test/**/*_test.exs   — an ExUnit file, which is its own impact
#
# EVERYTHING ELSE THE DISPATCHER CAN LET THROUGH SELECTS `ALL`. Not by an
# enumerated blast list that can fall behind the tree — by the polarity of the
# match. api/config/**, api/mix.exs, api/mix.lock, api/priv/**,
# api/test/test_helper.exs, api/test/support/**, api/test/fixtures/**,
# api/assets/**, api/lib/**/*.heex, design/**, web/**, internal/**, scripts/**,
# docs/openapi.json, .github/workflows/elixir.yml and every path added to
# either set in future all fall through to ALL because they are not in the two
# patterns above. A NEW path set entry cannot narrow this gate by accident; it
# can only ever make it run more.
#
# That is the invariant `--selftest` case "unmapped" proves by construction:
# it feeds a path that matches no pattern and asserts `ALL`.
# ── CLASS 3: a changed path OUTSIDE api/ ──────────────────────────────────
# The first two classes alone sent 19 of the last 40 api/-touching main commits
# to ALL, and almost none of them for a reason: a squash merge that edits one
# lib file also edits `scripts/canonical-marker-bindings.pin`, a `tooling/`
# json, a Go file under `internal/cli/`. Treating every one of those as
# unclassifiable throws away half the win for nothing.
#
# It is answerable, and the instrument already exists. THREE BRANCHES, each
# resting on something already proven rather than on judgement:
#
#   (a) the path is in the COMPILE set (design/**, this workflow, the ratchet
#       scripts) -> ALL. Those paths recompile the app or redefine the gate.
#
#   (b) the escape census NAMES the path — `elixir-path-escape-check.sh
#       --list-escapes` prints `<repo-root path>TAB<the api/ file that reads
#       it>TAB<idiom>`. Then the readers ARE the impact, exactly:
#         * an api/test reader is selected directly;
#         * an api/lib reader is treated as if that lib file had changed, so
#           its compile closure and by-name net are taken. The reader's CODE is
#           unchanged, but its DATA moved, and the tests that can see that are
#           precisely the tests of the reader.
#
#   (c) neither — and this is the branch the path-escape ratchet licenses.
#       That ratchet exists to prove that every repo-root read by api/lib and
#       api/test is covered by one of the two declared path sets, and it runs
#       unfiltered and blocking on every single PR. A path in NEITHER set is
#       therefore a path nothing in this suite reads; it only reached this job
#       riding along with some other changed file. It contributes no tests.
#       If that ratchet is ever wrong, it is wrong for the dispatcher too — the
#       whole suite is already skipped on such a path today.
#
#   (d) in the TEST-ONLY set but NOT in the census -> ALL. The set says the
#       suite reads it; the census cannot say WHO reads it (a computed path, a
#       shelled-out binary). Unknown reader, so unknown impact, so everything.
#       `cloud/test/**` and `web/node_modules/**` land here.
#
# Branch (c) is the only one that can shrink a selection on a path nobody
# classified, and it shrinks it to "no tests OF ITS OWN" — the ALWAYS set still
# rides, and any api/ path in the same diff is still classified on its own
# terms. It cannot produce an empty selection.
in_set() {
  # `--match` prints the word, and a set name typo exits 2 rather than matching
  # everything (assert_set_name in the ratchet).
  local p="$1" want="$2" out
  out="$(printf '%s\n' "$p" | bash "$SCRIPT_DIR/elixir-path-escape-check.sh" --match "$want" 2>/dev/null)" || return 1
  [ "$out" = "true" ]
}

CENSUS=""
CENSUS_LOADED=0
load_census() {
  [ "$CENSUS_LOADED" -eq 1 ] && return 0
  CENSUS_LOADED=1
  CENSUS="$(bash "$SCRIPT_DIR/elixir-path-escape-check.sh" --list-escapes 2>/dev/null)" || CENSUS=""
  return 0
}

# readers of a repo-root path. Census rows can name a DIRECTORY
# (`internal/pdrender/testdata`) while the diff names a file inside it, and the
# reverse when a whole tree is replaced — so the match is a prefix test in both
# directions, not equality.
census_readers() {
  local p="$1"
  load_census
  [ -n "$CENSUS" ] || return 0
  awk -F'\t' -v p="$p" '
    {
      row = $1
      if (row == p || index(p, row "/") == 1 || index(row, p "/") == 1) print $2
    }' <<<"$CENSUS" | LC_ALL=C sort -u
}

is_narrowable_lib() { case "$1" in api/lib/*.ex) return 0 ;; *) return 1 ;; esac; }
is_narrowable_test() { case "$1" in api/test/*_test.exs) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# THE ALWAYS SET — the net, DERIVED where it can be and PINNED where it cannot
# ---------------------------------------------------------------------------
# Every entry has to earn its wall time, so there are exactly two admission
# rules and each one names a class of test that a compile-time closure is
# STRUCTURALLY unable to reach. Nothing is here because it felt important.
#
# RULE 1 — SOURCE-SCANNING TESTS, derived from the tree on every run.
#   A census/tripwire test whose input is the repository tree itself
#   (`Path.wildcard("lib/**/*.ex")`, `File.read!("../docs/api-v1.md")`,
#   `File.ls!`) has NO compile-time edge to the files it judges: it opens them
#   as bytes. `mix xref` therefore reports, correctly, that changing
#   api/lib/foo.ex cannot recompile the census — and the census is precisely
#   the thing that was going to fail on foo.ex. This class is derived by grep
#   at selection time rather than committed as a list, so it cannot rot: a
#   census added tomorrow is in the net tomorrow, with no registration step and
#   no ratchet to go stale.
#
# RULE 2 — RUNTIME-REGISTRY TESTS, pinned, because they cannot be derived.
#   The plugin registry, the router's plugin route block and the capabilities
#   manifest are assembled AT RUNTIME from configuration. There is no
#   compile-time edge from a plugin implementation module to the router that
#   will serve it, so no closure can find these from a plugin change, and no
#   grep pattern distinguishes them from ordinary tests. They are listed by
#   name below, each with the reason, and `--check-pins` asserts every one
#   still exists — a rename reds the gate instead of silently shrinking the
#   net.
#
# WHAT IS DELIBERATELY *NOT* HERE. The never-worse ratchets
# (unreachable-assert-message-check.sh, client-ip-resolver-check.sh,
# test-env-leak-gate.sh) and the two golden-freshness gates are STEPS of the
# mix-test job, outside `mix test` entirely. They already run on every PR that
# reaches the job and no selection can skip them; adding them here would be a
# second, weaker copy of a guard that is already unconditional.

# Rule 1's derivation. A test that reads the tree must NAME the tree — an
# api-relative path literal into lib/, a `../` escape out of api/, or one of
# the three directory-enumeration calls. Broad on purpose: a false positive
# costs one test file of wall time, a false negative costs a blind gate.
ALWAYS_SCAN_ERE='"lib/|"\.\./|Path\.wildcard\(|File\.ls!?\(|Application\.app_dir\('

# Rule 2's pins: <api-relative path><TAB><why a compile closure cannot reach it>
ALWAYS_PINS='test/barkpark/plugin_free_boot_test.exs	the plugins-off boot bar: setup_all restarts the OTP app with :plugins forced to [], so its input is the runtime child spec tree, not a module reference
test/barkpark_web/plugin_routes_test.exs	plugin routes are injected into the router from the runtime plugin list; no compile edge runs from a plugin module to the router
test/barkpark_web/plugin_route_kill_switch_test.exs	same runtime route injection, read through the enablement kill switch
test/barkpark/plugins/registry_test.exs	the registry resolves implementations by config at runtime; a new or changed plugin module reaches it through no compile edge
test/barkpark/plugins/manifest_test.exs	the manifest is collected from the runtime registry, not built at compile time
test/barkpark/plugins/census_test.exs	the plugin census enumerates what is registered at runtime
test/barkpark_web/contract/capabilities_manifest_test.exs	GET /v1/capabilities is assembled at runtime from registry + router; every surface in this repo is driven off it
test/barkpark_web/contract/router_manifest_drift_test.exs	compares the live route table against the manifest; both are runtime products
test/barkpark_web/require_admin_route_census_test.exs	an authorization census over the runtime route table — a new route with the wrong pipeline is exactly what it catches
test/barkpark_web/flat_alias_route_census_test.exs	same runtime route table, alias arm
test/barkpark_web/live/liveview_mount_authz_census_test.exs	enumerates live_session mounts from the runtime router'

pins_paths() { printf '%s\n' "$ALWAYS_PINS" | cut -f1 | sed '/^$/d'; }

# The derived half. Runs from api/, prints api-relative paths.
scan_always_derived() {
  (
    cd -- "$API_DIR" 2>/dev/null || exit 0
    # `grep -rlE` over the test tree. -l gives one line per matching file; a
    # tree with zero matches exits 1, which `|| true` absorbs so `set -e` does
    # not read "no matches" as a crash. The emptiness that would matter is
    # caught by the non-empty assertion in `always_set`, not here.
    grep -rlE "$ALWAYS_SCAN_ERE" test --include='*_test.exs' 2>/dev/null || true
  )
}

always_set() {
  local out
  out="$( { scan_always_derived; pins_paths; } | LC_ALL=C sort -u | sed '/^$/d' )"
  if [ -z "$out" ]; then
    # UNREACHABLE BY CONSTRUCTION, AND THAT IS WHY IT IS CHECKED. An empty
    # ALWAYS set means the net is gone, and the symptom of a gone net is a
    # green gate. Refuse rather than narrow.
    echo "elixir-impacted-tests: the ALWAYS set is EMPTY — refusing to emit a selection with no safety net." >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# the compile closure
# ---------------------------------------------------------------------------
# `mix xref graph --sink <file> --label compile-connected` prints the files
# whose compilation is connected to <file> — i.e. what recompiles when it
# changes. It needs a compiled build, which the mix-test job has by the time
# this runs (the step sits after `Compile (dev)`).
#
# TEST FILES ARE NOT IN THAT GRAPH. `mix compile` does not compile api/test,
# so xref can never name a *_test.exs. The closure is therefore over LIB files
# only, and the lib->test hop is made by the two mappers below. Saying so here
# because "xref selects the tests" is the intuitive and wrong reading.
#
# FAIL-SAFE: any non-zero exit, any unusable output, or an output that does not
# contain the sink itself, returns 1 and the caller emits ALL. A closure that
# silently came back short is the failure mode this whole file exists to avoid,
# so "xref answered something" is not accepted as "xref answered correctly".
compile_closure() {
  local sink="$1" rel out rc
  rel="${sink#api/}"
  if [ "${BP_IMPACTED_NO_XREF:-0}" = "1" ]; then
    printf '%s\n' "$rel"
    return 0
  fi
  # `out=$(...)` under `set -e` EXITS on a non-zero substitution, which would
  # kill the selector instead of falling back to ALL — the exact inversion this
  # file is written against. `|| rc=$?` keeps the failure a value.
  rc=0
  out="$(cd -- "$API_DIR" && mix xref graph --sink "$rel" --label compile-connected --format plain 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "elixir-impacted-tests: mix xref failed (rc=$rc) for ${rel} — falling back to ALL." >&2
    return 1
  fi
  # `--format plain` prints `<file>` or `<file> (compile)` per line, one per
  # edge, with the sink itself as a root. Strip the annotation and dedupe.
  out="$(printf '%s\n' "$out" | sed -e 's/ (compile)$//' -e 's/ (compile-connected)$//' -e 's/ (runtime)$//' -e 's/ (export)$//' -e 's/^[[:space:]|`-]*//' | sed '/^$/d' | LC_ALL=C sort -u)"
  # An EMPTY graph here is legitimate: a true leaf that nothing compile-depends
  # on has no dependents to print. What is NOT legitimate is an empty graph
  # because xref answered wrong — a version whose flags moved, a banner instead
  # of a tree, a stale manifest. Both look identical at this call site, and the
  # wrong one narrows the suite to almost nothing under a green tick.
  #
  # So emptiness is not judged here at all. It is judged ONCE per run by a
  # POSITIVE CONTROL (`xref_probe` below) over a file that is depended on by
  # most of the application: if the instrument can find THAT file's dependents,
  # an empty answer for some leaf is an answer. If it cannot, nothing in this
  # run is trusted and everything falls back to ALL.
  printf '%s\n' "$out"
  # Always include the sink itself: `--sink` prints DEPENDENTS, and the file
  # that changed is impacted by definition.
  printf '%s\n' "$rel"
}

# ── THE POSITIVE CONTROL ──────────────────────────────────────────────────
# `mix xref graph --sink X --label compile-connected` printing nothing is the
# one output shape this script cannot tell apart from a broken instrument, and
# it is also the shape that does maximum damage: it narrows a change to a
# widely-used module down to its convention test. So before any closure is
# trusted, the same invocation is run against a file the whole application
# compile-depends on, and a non-empty answer there is what licenses reading an
# empty answer elsewhere as "leaf" rather than "blind".
#
# `lib/barkpark/repo.ex` is the probe: the Ecto repo, aliased or imported by
# essentially every context module in the tree. If it is ever deleted or
# renamed, the probe fails and the selector falls back to ALL — loudly, and in
# the safe direction.
XREF_PROBE_DONE=0
XREF_PROBE_OK=0
xref_probe() {
  [ "$XREF_PROBE_DONE" -eq 1 ] && { [ "$XREF_PROBE_OK" -eq 1 ]; return; }
  XREF_PROBE_DONE=1
  if [ "${BP_IMPACTED_NO_XREF:-0}" = "1" ]; then
    XREF_PROBE_OK=1
    return 0
  fi
  local probe="lib/barkpark/repo.ex" out rc=0
  if [ ! -f "$API_DIR/$probe" ]; then
    echo "elixir-impacted-tests: the xref positive control ${probe} is gone — no way to tell a leaf from a blind instrument, falling back to ALL." >&2
    return 1
  fi
  out="$(cd -- "$API_DIR" && mix xref graph --sink "$probe" --label compile-connected --format plain 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "elixir-impacted-tests: the xref positive control exited rc=${rc} — falling back to ALL." >&2
    return 1
  fi
  # `.ex` on a line is the weakest thing that must be true of a real graph.
  if ! grep -q '\.ex' <<<"$out"; then
    echo "elixir-impacted-tests: the xref positive control found NO dependents of ${probe}, which the whole application compile-depends on. The instrument is not answering — falling back to ALL." >&2
    return 1
  fi
  XREF_PROBE_OK=1
  return 0
}

# lib/a/b.ex -> test/a/b_test.exs, when it exists. The convention half.
convention_test() {
  local rel="$1" cand
  case "$rel" in lib/*) ;; *) return 0 ;; esac
  cand="test/${rel#lib/}"
  cand="${cand%.ex}_test.exs"
  [ -f "$API_DIR/$cand" ] && printf '%s\n' "$cand"
  return 0
}

# The BY-NAME half, and the reason a cross-module caller is not missed. Every
# module the closure's files define is grepped for across the whole test tree,
# so a test that exercises Foo through Bar is selected when Foo changes even
# though no path convention connects them. This is the mapper the row's "naive
# path map picks 0.2 percent and is blind to cross-module callers" measurement
# was about.
#
# ONE grep FOR THE WHOLE CLOSURE, not one per module. A closure over a
# widely-depended-on module is hundreds of files; a grep of the 1,458-file test
# tree per module would cost more than the suite it is trying to skip.
# `grep -F -f -` takes every module name at once and visits each test file once.
modules_of() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sed -nE 's/^[[:space:]]*defmodule[[:space:]]+([A-Za-z0-9_.]+).*/\1/p' "$API_DIR/$f" 2>/dev/null || true
  done
}

tests_naming_modules() {
  # module names on stdin; api-relative test paths on stdout
  local mods
  mods="$(LC_ALL=C sort -u | sed '/^$/d')"
  [ -n "$mods" ] || return 0
  (cd -- "$API_DIR" && printf '%s\n' "$mods" | grep -rlF -f - test --include='*_test.exs' 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# --select
# ---------------------------------------------------------------------------
select_tests() {
  local changed p sel="" closure f rel
  changed="$(cat)"
  changed="$(printf '%s\n' "$changed" | sed '/^$/d')"

  if [ -z "$changed" ]; then
    # Same polarity as the dispatcher's empty-diff arm: an unknown input runs
    # everything. Never a narrow answer from no information.
    echo "elixir-impacted-tests: the changed-path set is EMPTY — selecting ALL." >&2
    echo "ALL"
    return 0
  fi

  local closure_all="" mods_here readers r
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_narrowable_test "$p"; then
      sel="${sel}${p#api/}
"
      continue
    fi
    if is_narrowable_lib "$p"; then
      # A lib file that defines no module (a bare script, a `defimpl`-only
      # file) leaves the by-name net empty, and an empty net on a real code
      # change is indistinguishable from a working one. Run everything instead.
      mods_here="$(modules_of <<<"${p#api/}")"
      if [ -z "$mods_here" ]; then
        echo "elixir-impacted-tests: ${p} defines no module — cannot compute a by-name net, selecting ALL." >&2
        echo "ALL"
        return 0
      fi
      if ! xref_probe || ! closure="$(compile_closure "$p")"; then
        echo "ALL"
        return 0
      fi
      closure_all="${closure_all}${closure}
"
      continue
    fi
    # ── inside api/, but neither a .ex under lib/ nor a *_test.exs ──────
    # api/config/**, api/mix.*, api/priv/**, api/test/support/**,
    # api/test/fixtures/**, api/assets/**, api/lib/**/*.heex, api/CLAUDE.md.
    # Some of those genuinely cannot matter; enumerating which ones is the
    # rotting blast-list this design refuses to keep. Inside api/ the answer
    # stays ALL.
    case "$p" in
      api/*)
        echo "elixir-impacted-tests: ${p} is under api/ but is not a lib .ex or a *_test.exs — selecting ALL." >&2
        echo "ALL"
        return 0
        ;;
    esac

    # ── CLASS 3: outside api/ ───────────────────────────────────────────
    if in_set "$p" compile; then
      echo "elixir-impacted-tests: ${p} is in the COMPILE path set — selecting ALL." >&2
      echo "ALL"
      return 0
    fi
    readers="$(census_readers "$p")"
    if [ -n "$readers" ]; then
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$r" in
          api/test/*_test.exs) sel="${sel}${r#api/}
" ;;
          api/lib/*.ex)
            if ! xref_probe || ! closure="$(compile_closure "$r")"; then
              echo "ALL"
              return 0
            fi
            closure_all="${closure_all}${closure}
"
            ;;
          *)
            # A census reader this script does not know how to map. Unknown
            # impact, so everything.
            echo "elixir-impacted-tests: ${p} is read by ${r}, which is neither a lib .ex nor a *_test.exs — selecting ALL." >&2
            echo "ALL"
            return 0
            ;;
        esac
      done <<EOF
$readers
EOF
      continue
    fi
    if in_set "$p" test; then
      echo "elixir-impacted-tests: ${p} is in the TEST path set but the escape census names no reader for it — unknown reader, unknown impact, selecting ALL." >&2
      echo "ALL"
      return 0
    fi
    # Branch (c). Dispatched on by neither set, named by no census row: the
    # path-escape ratchet's guarantee is that nothing in this suite reads it.
    echo "elixir-impacted-tests: ${p} is in NEITHER path set and in no census row — nothing in the suite reads it; it contributes no tests." >&2
  done <<EOF
$changed
EOF

  closure_all="$(printf '%s\n' "$closure_all" | sed '/^$/d' | LC_ALL=C sort -u)"
  if [ -n "$closure_all" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sel="${sel}$(convention_test "$f")
"
    done <<EOF
$closure_all
EOF
    sel="${sel}$(printf '%s\n' "$closure_all" | modules_of | tests_naming_modules)
"
  fi

  local net
  net="$(always_set)" || { echo "ALL"; return 0; }
  printf '%s\n%s\n' "$sel" "$net" | sed '/^$/d' | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------
case "${1:---select}" in
  --select) select_tests ;;
  --print-always) always_set ;;
  --xref-probe)
    # THE INSTRUMENT'S OWN LIVENESS, reportable on its own. A broken `mix xref`
    # does not red anything: it makes every selection fall back to ALL, which
    # looks exactly like a repo where every diff happens to be wide. Months
    # could pass. So the workflow prints this on EVERY run, including the runs
    # that select ALL for unrelated reasons, and the one line is the difference
    # between "the closure was not needed" and "the closure has been dead since
    # August".
    if xref_probe; then
      echo "xref-probe: OK — mix xref answers, so an empty closure means a leaf."
      exit 0
    fi
    echo "xref-probe: DEAD — the compile closure is unavailable; every selection will fall back to ALL."
    exit 1
    ;;
  --print-pins) printf '%s\n' "$ALWAYS_PINS" ;;
  --check-pins)
    # A pinned entry that no longer exists is a hole in the net wearing the
    # shape of a full list. Red on it.
    rc=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ ! -f "$API_DIR/$p" ]; then
        echo "elixir-impacted-tests: ALWAYS pin '$p' does not exist. It was renamed or deleted — update ALWAYS_PINS in $0, do not just drop it." >&2
        rc=1
      fi
    done <<EOF
$(pins_paths)
EOF
    if [ "$rc" -eq 0 ]; then
      # `grep -c` prints a count AND exits 1 on zero, so it is not usable bare
      # under `set -e`; count with awk, which cannot.
      echo "elixir-impacted-tests: all $(pins_paths | awk 'END{print NR}') ALWAYS pins exist."
    fi
    exit "$rc"
    ;;
  --selftest) exec bash "$SCRIPT_DIR/elixir-impacted-tests.test.sh" ;;
  *)
    echo "elixir-impacted-tests: unknown argument '$1'" >&2
    echo "usage: $0 [--select|--print-always|--print-pins|--check-pins|--selftest]" >&2
    exit 2
    ;;
esac
