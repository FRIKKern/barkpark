#!/usr/bin/env bash
#
# elixir-path-escape-check.sh — the Elixir skip-shim's path ratchet AND the
# single source of truth for the path sets elixir.yml dispatches on.
#
# WHY THIS EXISTS (Honest Gates charter D31)
# ------------------------------------------
# elixir.yml no longer runs its expensive jobs on every PR: a dispatcher job
# computes the changed-path set and job-level `if:` conditions skip the suite
# on PRs that cannot affect it. That is only honest while the declared path
# sets are a SUPERSET of everything the suite actually reads. The Elixir suite
# reads well outside `api/**` — the machine-derived census is 24 repo-root
# escapes, and the obvious hand-written filter list misses three whole families
# (internal/taskboard/**, internal/chat/testdata/**,
# .codex/skills/epic-cycle/scripts/**). A missed family means a PR that edits
# the Go glyph table skips the ONLY gate that enforces GUI<->TUI parity, and
# the skip reports GREEN.
#
# So: this script re-derives the escape census from the working tree on every
# run and FAILS when a resolved repo-root read is not covered by the declared
# sets below. Adding a new cross-tree read without widening the dispatcher is a
# red, not a silent hole.
#
# HOW AN ESCAPE IS RESOLVED
# -------------------------
# Every `"../…"` string literal in api/lib and api/test is resolved against
# BOTH bases the codebase actually uses:
#   * the file's own directory   — the `Path.expand("../x", __DIR__)` idiom
#   * `api/`                     — the `mix test` cwd idiom (File.read!("../x"))
# Anything landing inside api/ is not an escape. Anything landing outside api/
# AND existing on disk is a repo-root read that the dispatcher must cover.
#
# The existence filter is what keeps the traversal-attack fixtures
# (`"../etc/passwd"`, `"../up"`, `"../x"`) out of the census: they are asserted
# on, never read. It is also why the enumeration walks the WORKING TREE.
#
# NOT `git ls-files` (charter D31): a prototype that enumerated via git
# reported "OK: every repo-root read is covered" and exited 0 with the mutation
# fixture sitting on disk UNTRACKED — a textbook vacuous pass of exactly the
# class this epic exists to remove. The harness carries an untracked case.
#
# USAGE
#   elixir-path-escape-check.sh                 # the ratchet (CI + the gate)
#   elixir-path-escape-check.sh --selftest      # run the harness
#   elixir-path-escape-check.sh --list-escapes  # print the resolved census
#   elixir-path-escape-check.sh --print-set compile|test
#   elixir-path-escape-check.sh --match compile|test   # changed paths on stdin
#                                                      # -> prints true|false
#
# `--print-set` / `--match` are consumed by the elixir.yml dispatcher, so the
# workflow and this ratchet can never disagree about what the path sets are.

set -euo pipefail

# ---------------------------------------------------------------------------
# THE DECLARED PATH SETS (charter D31 — TWO sets, deliberately)
# ---------------------------------------------------------------------------
# Glob grammar, deliberately tiny: `dir/**` = that directory and everything
# under it; anything else = one exact file path. No other wildcards.
#
# COMPILE set — paths that can change what the compiler produces. Gates the
# prod-compile job and the perf bench (and, being a subset of the test set,
# implies the test job too).
#   design/** is here, not in the test-only set: design/status-manifest.json is
#   an @external_resource of api/lib/barkpark/portable_doc/render/status_vocab.ex:20,
#   so editing it recompiles that module. design/tokens.json rides the same tree.
#   This file and elixir.yml are here so a change to the shim itself always runs
#   the full suite it is gating.
ELIXIR_COMPILE_PATHS='api/**
design/**
.github/workflows/elixir.yml
scripts/elixir-path-escape-check.sh
scripts/elixir-path-escape-check.test.sh'

# TEST-ONLY set — fixture/mirror trees read by tests but never compiled against.
# Each entry is a MEASURED read, not a guess; see --list-escapes for the census.
#
# Deliberately NOT here, both measured over-inclusions (charter D31):
#   * repo-root templates/**  — no Elixir test reads it. That entry is a
#     copy-paste from go-tests.yml, where it IS load-bearing. The only
#     "templates" the suite reads is internal/provisioner/catalog/templates/**.
#   * scripts/claude-pinned-version.txt — reachable only from
#     api/test/barkpark_web/studio/claude_chat_real_binary_test.exs, whose
#     :real_binary tag is excluded in api/test/test_helper.exs. See EXEMPT below.
# Over-inclusion costs the shim exactly what it exists to save, so both stay out.
#
# NOTE the two docs/ entries are EXACT FILES, never docs/**: docs-only PRs
# skipping the Elixir suite is half the point of this shim.
ELIXIR_TEST_ONLY_PATHS='.codex/skills/epic-cycle/scripts/**
cmd/barkpark/testdata/**
docs/api-v1.md
docs/openapi.json
internal/chat/testdata/**
internal/pdrender/testdata/**
internal/provisioner/catalog/templates/**
internal/taskboard/**
js/packages/react/tests/fixtures/**
scripts/async_env_seam_scan.exs
web/__tests__/**'

# EXEMPT — escapes that resolve to a real file but are NOT reachable from the
# default `mix test` lane. Each line is `<path><TAB><why>`; an entry without a
# reason is a bug. Keep this list at zero-growth: the honest fix for a new
# cross-tree read is to declare it above, not to exempt it.
ELIXIR_ESCAPE_EXEMPT='scripts/claude-pinned-version.txt	read only by claude_chat_real_binary_test.exs, whose :real_binary tag is excluded in api/test/test_helper.exs'

# The census floor. The measured population is 24 resolved repo-root reads; a
# floor of 8 is generous. Its job is to catch a NEUTERED SCANNER: a regex or
# find that silently stops matching would otherwise report "0 uncovered reads"
# and exit 0 — clean-looking, and completely blind.
#
# It is a CONSTANT on purpose. An env-var override would be a one-line CI
# bypass of the only check that can tell "clean" from "blind", and the harness
# asserts that setting ELIXIR_ESCAPE_MIN changes nothing.
ELIXIR_ESCAPE_MIN=8

# ELIXIR_PATH_ESCAPE_ROOT retargets the scan at a synthetic fixture tree; the
# harness is its only caller. It cannot weaken a real run — pointing it at the
# repo gives the identical verdict.
REPO_ROOT="${ELIXIR_PATH_ESCAPE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

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
# other polarity of a future caller, skipping it). The harness caught exactly
# that; this check is the fix.
assert_set_name() {
  case "$1" in
    compile | test) ;;
    *)
      echo "elixir-path-escape-check: unknown path set '$1' (want compile|test)" >&2
      exit 2
      ;;
  esac
}

set_globs() {
  assert_set_name "$1"
  case "$1" in
    compile) printf '%s\n' "$ELIXIR_COMPILE_PATHS" ;;
    test) printf '%s\n%s\n' "$ELIXIR_COMPILE_PATHS" "$ELIXIR_TEST_ONLY_PATHS" ;;
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
    echo "elixir-path-escape-check: path set '$1' resolved to an empty pattern" >&2
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
  sources="$(cd -- "$REPO_ROOT" && find api/lib api/test -type f \( -name '*.ex' -o -name '*.exs' \) 2>/dev/null | LC_ALL=C sort)"
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
      for base in "$d" "api"; do
        resolved="$(norm_path "$base/$lit")"
        [ -n "$resolved" ] || continue
        # inside api/ is not an escape
        case "$resolved" in api | api/*) continue ;; esac
        # Only reads that can actually happen: a literal resolving to nothing on
        # disk is a traversal-attack fixture, not a dependency.
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
  done <<<"$ELIXIR_ESCAPE_EXEMPT"
  return 1
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

mode="${1:---check}"

case "$mode" in
  --print-set)
    assert_set_name "${2:?--print-set needs compile|test}"
    set_globs "$2"
    exit 0
    ;;

  --match)
    # changed paths on stdin -> `true` if ANY of them is in the named set.
    # This is what elixir.yml dispatches on, so the workflow and the ratchet
    # can never disagree about what a path set contains.
    want="${2:?--match needs compile|test}"
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
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/elixir-path-escape-check.test.sh"
    ;;

  --check) ;;

  *)
    echo "elixir-path-escape-check: unknown argument '$mode'" >&2
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

echo "elixir-path-escape-check: scanning \$REPO_ROOT=$REPO_ROOT"
echo "elixir-path-escape-check: $count distinct repo-root read(s) resolved from api/lib + api/test"

# FAIL-CLOSED on a neutered scanner. "Nothing found" is never good news here.
if [ "$count" -lt "$ELIXIR_ESCAPE_MIN" ]; then
  echo "::error::elixir-path-escape-check: only $count repo-root read(s) found, floor is $ELIXIR_ESCAPE_MIN." >&2
  echo "  The SCANNER is broken, not the repo clean — the measured population is 24." >&2
  echo "  Check the grep/find in list_escapes before touching the floor." >&2
  exit 1
fi

test_ere="$(set_ere test)"
uncovered=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$p" | grep -Eq -- "$test_ere"; then
    continue
  fi
  if is_exempt "$p"; then
    echo "  exempt: $p"
    continue
  fi
  uncovered=$((uncovered + 1))
  echo "::error::elixir-path-escape-check: UNCOVERED repo-root read: $p" >&2
  printf '%s\n' "$census" | awk -F'\t' -v p="$p" '$1 == p { print "    read from: " $2 }' | sort -u >&2
done <<<"$paths"

if [ "$uncovered" -gt 0 ]; then
  cat >&2 <<'MSG'

The Elixir suite reads path(s) that elixir.yml's dispatcher does NOT dispatch
on. A PR touching one of them would SKIP the suite and report green.

Fix: add the path to ELIXIR_TEST_ONLY_PATHS (or ELIXIR_COMPILE_PATHS if it can
change compiler output) at the top of this script — elixir.yml reads its sets
from here, so declaring it once is enough. Exempt it only if the reading test
is excluded from the default lane, and say so in the exemption's reason.
MSG
  exit 1
fi

echo "OK: every repo-root read from api/lib + api/test is dispatched on."
