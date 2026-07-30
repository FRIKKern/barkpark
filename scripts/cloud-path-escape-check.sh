#!/usr/bin/env bash
#
# cloud-path-escape-check.sh — the Cloud skip-shim's path ratchet AND the single
# source of truth for the path set cloud.yml dispatches on.
#
# WHY THIS EXISTS
# ---------------
# cloud.yml used to carry a WORKFLOW-LEVEL `on: … paths:` filter. That shape is
# structurally unrequirable: a workflow-level paths filter emits NO check run at
# all on a non-matching PR, and a required context that is ABSENT reports
# "expected" forever — it deadlocks the merge instead of gating it (honest-gates
# D18, re-measured this wave as D89). So the filter moves DOWN, from the
# workflow trigger to job-level `if:` conditions fed by an always-running
# dispatcher, exactly as elixir.yml does. Then, and only then, can an aggregator
# name over this workflow become a required status check.
#
# A job-level skip is only honest while the declared path set is a SUPERSET of
# everything the gated jobs actually read. The Cloud suite reads outside
# `cloud/**`: it byte-compares a Go fixture and it `Code.require_file`s a repo
# root script. Miss one of those and a PR editing it SKIPS the only gate that
# checks it — and the skip reports GREEN.
#
# So: this script re-derives the escape census from the working tree on every
# run and FAILS when a resolved repo-root read is not covered by the declared
# set below. Adding a new cross-tree read without widening the dispatcher is a
# red, not a silent hole.
#
# HOW AN ESCAPE IS RESOLVED
# -------------------------
# Every `"../…"` string literal in cloud/lib and cloud/test is resolved against
# BOTH bases the codebase actually uses:
#   * the file's own directory   — the `Path.expand("../x", __DIR__)` idiom
#   * `cloud/`                   — the `mix test` cwd idiom (File.read!("../x"))
# Anything landing inside cloud/ is not an escape. Anything landing outside
# cloud/ AND existing on disk is a repo-root read the dispatcher must cover.
#
# The existence filter is what keeps the traversal-attack and 404-fixture
# literals (`"../../etc"`, `"../timeout/index.html"`, `"../up"`) out of the
# census: they are asserted on or served as static assets, never read across the
# tree. It is also why the enumeration walks the WORKING TREE.
#
# NOT `git ls-files` (honest-gates D31): a prototype that enumerated via git
# reported "OK: every repo-root read is covered" and exited 0 with the mutation
# fixture sitting on disk UNTRACKED — a textbook vacuous pass of exactly the
# class this ratchet exists to remove. The harness carries an untracked case.
#
# USAGE
#   cloud-path-escape-check.sh                 # the ratchet (CI + the gate)
#   cloud-path-escape-check.sh --selftest      # run the harness
#   cloud-path-escape-check.sh --list-escapes  # print the resolved census
#   cloud-path-escape-check.sh --print-set cloud
#   cloud-path-escape-check.sh --match cloud   # changed paths on stdin
#                                              # -> prints true|false
#
# `--print-set` / `--match` are consumed by the cloud.yml dispatcher, so the
# workflow and this ratchet can never disagree about what the path set is.

set -euo pipefail

# ---------------------------------------------------------------------------
# THE DECLARED PATH SET (ONE set — cloud.yml has no compile/test split: both
# jobs compile the same app, and `test` additionally needs Postgres)
# ---------------------------------------------------------------------------
# Glob grammar, deliberately tiny: `dir/**` = that directory and everything
# under it; anything else = one exact file path. No other wildcards.
#
#   cloud/**                              the app under gate
#   .github/workflows/cloud.yml           a change to the shim runs the suite
#   scripts/cloud-path-escape-check*.sh   likewise for the ratchet itself
#
# The two cross-tree entries are MEASURED reads, not guesses (see
# --list-escapes):
#   internal/cli/cloud/providers_capabilities.json
#       cloud/test/…/providers_capabilities_contract_test.exs Path.expand()s the
#       Go fixture and asserts BYTE EQUALITY against the served JSON. Edit the
#       Go side alone and, unfiltered, the contract test never runs.
#   scripts/async_env_seam_scan.exs
#       cloud/test/…/async_global_seam_guard_test.exs Code.require_file()s the
#       scanner and drives it. The scanner IS the code under test there.
#
# js/packages/create-barkpark-app/templates/** is the VENDORED-TEMPLATE DRIFT
# TRIPWIRE, inherited verbatim from the workflow-level filter this shim
# replaces: cloud/priv/templates/** is a COPY of those templates
# (`make cloud-templates-sync`) guarded by AppFilesDriftTest in the `test` job.
# Editing the SOURCE must run that guard on THIS PR — else the sync is skipped
# and drift lands (the #963→#969 class). It is ALSO a measured escape.
#
# DELIBERATELY NOT DECLARED — api/test/**. scripts/async_env_seam_scan.exs
# derives `default_roots/0` at RUNTIME as [<repo>/cloud/test, <repo>/api/test],
# so an api/test/** edit can in principle change what that scanner reports. It
# is NOT declared, on purpose: an api/test/** trigger would run the whole Cloud
# Elixir suite plus a Postgres service on every api-only PR — the shim would
# cost precisely what it exists to save. The SCANNER is declared instead, which
# covers every change to the scanning logic itself; what remains uncovered is a
# new api/test fixture that the scanner would newly flag. That residue is named
# here rather than left for a reader to discover.
CLOUD_PATHS='cloud/**
.github/workflows/cloud.yml
internal/cli/cloud/providers_capabilities.json
js/packages/create-barkpark-app/templates/**
scripts/async_env_seam_scan.exs
scripts/cloud-path-escape-check.sh
scripts/cloud-path-escape-check.test.sh'

# EXEMPT — census rows that resolve to a real repo-root file but are NOT a
# repo-root DEPENDENCY. Two shapes qualify, and nothing else does:
#   1. the read is unreachable from the default `mix test` lane (an excluded tag);
#   2. the row is an artefact of the SECOND resolution base. Every literal is
#      resolved against both the file's own dir AND `cloud/`, because both idioms
#      are in use; for a literal anchored explicitly to `__DIR__` the `cloud/`
#      resolution is not a read that can happen, and if it happens to land on an
#      existing repo-root file it is a phantom.
# Each line is `<path><TAB><why>`; an entry without a reason is a bug. Keep this
# list at zero-growth: the honest fix for a new cross-tree read is to declare it
# above, not to exempt it — and a shape-2 exemption is only honest while the
# literal's REAL target is itself covered by the declared set.
CLOUD_ESCAPE_EXEMPT='docker-compose.yml	shape 2 — notifications_platform_admin_env_test.exs:189 reads Path.join(__DIR__, "../../docker-compose.yml"), which is cloud/docker-compose.yml (covered by cloud/**). The repo-root file of the same name is reached only by the `cloud/` cwd base, and that base does not apply to a __DIR__-anchored literal.'

# The census floor. The measured population is 4 resolved repo-root reads: the
# two cross-tree reads above, the vendored-template directory, and the one
# EXEMPT phantom above; the floor is 4. Its job is to catch a NEUTERED SCANNER:
# a regex or find that silently stopped matching would otherwise report "0
# uncovered reads" and exit 0 — clean-looking, and completely blind.
#
# It is deliberately EQUAL to the population, not comfortably under it, because
# the population is small: a floor of 1 here would let two thirds of the scanner
# die unnoticed. A legitimate new escape RAISES this number in the same commit
# that declares the path.
#
# It is a CONSTANT on purpose. An env-var override would be a one-line CI bypass
# of the only check that can tell "clean" from "blind", and the harness asserts
# that setting CLOUD_ESCAPE_MIN changes nothing.
CLOUD_ESCAPE_MIN=4

# CLOUD_PATH_ESCAPE_ROOT retargets the scan at a synthetic fixture tree; the
# harness is its only caller. It cannot weaken a real run — pointing it at the
# repo gives the identical verdict.
REPO_ROOT="${CLOUD_PATH_ESCAPE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# normalize a slash path: resolve `.` and `..` lexically, drop empty segments.
# String-only (no arrays) so it behaves identically on bash 3.2 (macOS) and 5.x.
norm_path() {
  local rest="$1" seg out=""
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      '' | '.') ;;
      '..') out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out#/}"
}

# glob (dir/** or an exact path) -> anchored ERE
glob_to_ere() {
  local g="$1" body
  case "$g" in
    */'**')
      body="${g%/**}"
      printf '^%s(/|$)' "$(printf '%s' "$body" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"
      ;;
    *)
      printf '^%s$' "$(printf '%s' "$g" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"
      ;;
  esac
}

# Validate BEFORE any command substitution. An `exit 2` raised inside `$(...)`
# only kills the subshell: set_ere would then return an EMPTY pattern, and an
# empty ERE matches every line — so a typo'd set name would have made `--match`
# answer `true` for everything, silently running the full suite (or, on the
# other polarity of a future caller, skipping it). Ported verbatim from
# scripts/elixir-path-escape-check.sh, where the harness caught exactly that.
assert_set_name() {
  case "$1" in
    cloud) ;;
    *)
      echo "cloud-path-escape-check: unknown path set '$1' (want cloud)" >&2
      exit 2
      ;;
  esac
}

set_globs() {
  assert_set_name "$1"
  case "$1" in
    cloud) printf '%s\n' "$CLOUD_PATHS" ;;
  esac
}

# One alternation ERE for a whole set. Returned as a single string (not a
# -f pattern file) so nothing here needs process substitution: bash 3.2, which
# is what macOS ships and therefore what the local gate runs, segfaults on
# `< <(...)` inside a command substitution.
set_ere() {
  local g out=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if [ -n "$out" ]; then out="$out|"; fi
    out="$out$(glob_to_ere "$g")"
  done <<EOF
$(set_globs "$1")
EOF
  # Belt and braces: an empty ERE matches EVERY line. Never return one.
  if [ -z "$out" ]; then
    echo "cloud-path-escape-check: path set '$1' resolved to an empty pattern" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------
# Prints one resolved repo-root path per line, `<path><TAB><source-file>`.
list_escapes() {
  local f lit base resolved d lits sources
  # WORKING TREE enumeration (D31) — `find`, never `git ls-files`. An untracked
  # .exs on disk is code the suite will run, so it is code this ratchet must see.
  sources="$(cd -- "$REPO_ROOT" && find cloud/lib cloud/test -type f \( -name '*.ex' -o -name '*.exs' \) 2>/dev/null | LC_ALL=C sort)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    lits="$(grep -Eoh '"\.\./[^"]*"' "$REPO_ROOT/$f" || true)"
    [ -n "$lits" ] || continue
    while IFS= read -r lit; do
      lit="${lit%\"}"
      lit="${lit#\"}"
      # `"../#{Path.basename(x)}"` — keep the static prefix, drop the splice.
      lit="${lit%%\#\{*}"
      # `"…/src/**/*.js"` — keep the longest wildcard-free prefix.
      case "$lit" in
        *'*'*)
          lit="${lit%%\**}"
          lit="${lit%/}"
          ;;
      esac
      [ -n "$lit" ] || continue
      d="$(dirname -- "$f")"
      for base in "$d" "cloud"; do
        resolved="$(norm_path "$base/$lit")"
        [ -n "$resolved" ] || continue
        # inside cloud/ is not an escape
        case "$resolved" in cloud | cloud/*) continue ;; esac
        # Only reads that can actually happen: a literal resolving to nothing on
        # disk is a traversal fixture or a static 404 path, not a dependency.
        [ -e "$REPO_ROOT/$resolved" ] || continue
        printf '%s\t%s\n' "$resolved" "${f#./}"
      done
    done <<EOF
$lits
EOF
  done <<EOF
$sources
EOF
}

is_exempt() {
  local p="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%	*}" = "$p" ] && return 0
  done <<<"$CLOUD_ESCAPE_EXEMPT"
  return 1
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

mode="${1:---check}"

case "$mode" in
  --print-set)
    assert_set_name "${2:?--print-set needs cloud}"
    set_globs "$2"
    exit 0
    ;;

  --match)
    # changed paths on stdin -> `true` if ANY of them is in the named set.
    # This is what cloud.yml dispatches on, so the workflow and the ratchet
    # can never disagree about what the path set contains.
    want="${2:?--match needs cloud}"
    assert_set_name "$want"
    ere="$(set_ere "$want")"
    if grep -Eq -- "$ere"; then
      echo "true"
    else
      echo "false"
    fi
    exit 0
    ;;

  --list-escapes)
    # Collected first, then printed: piping the function directly segfaults
    # bash 3.2 (macOS) when its body carries process substitutions.
    escapes="$(list_escapes)"
    printf '%s\n' "$escapes" | sort -u
    exit 0
    ;;

  --selftest)
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/cloud-path-escape-check.test.sh"
    ;;

  --check) ;;

  *)
    echo "cloud-path-escape-check: unknown argument '$mode'" >&2
    echo "usage: $0 [--check|--selftest|--list-escapes|--print-set SET|--match SET]" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# --check: the ratchet
# ---------------------------------------------------------------------------
census="$(list_escapes | sort -u || true)"
paths="$(printf '%s\n' "$census" | cut -f1 | sort -u | sed '/^$/d')"
count="$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')"

echo "cloud-path-escape-check: scanning \$REPO_ROOT=$REPO_ROOT"
echo "cloud-path-escape-check: $count distinct repo-root read(s) resolved from cloud/lib + cloud/test"

# FAIL-CLOSED on a neutered scanner. "Nothing found" is never good news here.
if [ "$count" -lt "$CLOUD_ESCAPE_MIN" ]; then
  echo "::error::cloud-path-escape-check: only $count repo-root read(s) found, floor is $CLOUD_ESCAPE_MIN." >&2
  echo "  The SCANNER is broken, not the repo clean — the measured population is 4." >&2
  echo "  Check the grep/find in list_escapes before touching the floor." >&2
  exit 1
fi

cloud_ere="$(set_ere cloud)"
uncovered=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$p" | grep -Eq -- "$cloud_ere"; then
    continue
  fi
  if is_exempt "$p"; then
    echo "  exempt: $p"
    continue
  fi
  uncovered=$((uncovered + 1))
  echo "::error::cloud-path-escape-check: UNCOVERED repo-root read: $p" >&2
  printf '%s\n' "$census" | awk -F'\t' -v p="$p" '$1 == p { print "    read from: " $2 }' | sort -u >&2
done <<<"$paths"

if [ "$uncovered" -gt 0 ]; then
  cat >&2 <<'MSG'

The Cloud suite reads path(s) that cloud.yml's dispatcher does NOT dispatch on.
A PR touching one of them would SKIP the suite and report green.

Fix: add the path to CLOUD_PATHS at the top of this script — cloud.yml reads its
set from here, so declaring it once is enough. Exempt it only if the reading
test is excluded from the default lane, and say so in the exemption's reason.
MSG
  exit 1
fi

echo "OK: every repo-root read from cloud/lib + cloud/test is dispatched on."
