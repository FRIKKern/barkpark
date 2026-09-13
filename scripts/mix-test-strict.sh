#!/usr/bin/env bash
#
# mix-test-strict.sh — `mix test`, but it REFUSES BEFORE RUNNING when any path
# argument names no file, or names something that matches no test.
#
# WHY IT EXISTS (task-1d5bf80f8f4de47a, reproduced 2026-09-12 in cloud/):
#
#   $ mix test test/barkpark_cloud/registry_name_claim_select_census_test.exs \
#              test/barkpark_cloud/does_not_exist_test.exs
#   12 tests, 0 failures          <- exit 0
#
# `mix test` refuses ONLY when EVERY named path is unmatched ("Paths given to
# \"mix test\" did not match any directory/file", exit 1). One surviving path is
# enough to swallow the rest, so a renamed or mistyped file inside a multi-path
# gate recipe produces a GREEN WITH NO SUBJECT: the trailer a PR body quotes is
# byte-identical to a run that actually covered the file. That already happened
# once (lead-deploy-r5/w4 quoted a gate over a renamed test).
#
# api/mix.exs already carries a narrower guard in its `test` alias
# (`strict_test_paths/1`, task-9dc1b0aaf43797df): it checks EXISTENCE only, and
# only in api/. cloud/ has no such alias at all — the reproduction above is on
# origin/main today. This script is the one entry point both projects' gate
# recipes can name, and it adds the second arm: a path that EXISTS but matches
# no test (a directory holding no `*_test.exs`, or a file that is not one) runs
# zero tests and still exits 0.
#
# USAGE (from inside a mix project directory):
#   cd cloud && ../scripts/mix-test-strict.sh test/barkpark_cloud/foo_test.exs
#   cd api   && ../scripts/mix-test-strict.sh test/barkpark/a_test.exs test/barkpark/b_test.exs
#
# Every argument is forwarded to `mix test` UNCHANGED once validation passes —
# the script adds a precondition, never a behaviour. Flags, `--flag=value`,
# value-taking flags and their values, `file:LINE` addressing and a bare
# argument-less run are all untouched.
#
# EXIT: 0/1 whatever `mix test` returned · 2 REFUSED before running.
#   (2 is deliberately distinct from mix's own 1 so a gate can tell "tests
#   failed" from "the recipe named a file that is not there".)
#
# HONEST LIMIT, stated once: the test-file pattern here is ExUnit's default
# `*_test.exs`. A project that sets a custom `test_pattern` in its Mix project
# config would need that pattern taught here; neither api/mix.exs nor
# cloud/mix.exs sets one (checked 2026-09-12), and the check is one-directional
# anyway — it can refuse a file mix would have run, never green one it drops.
#
# BP_MIX_TEST_STRICT_DRY_RUN=1 prints the exact command it would exec and exits
# 0 without invoking mix. That is the harness seam (scripts/mix-test-strict.test.sh);
# it is also how you can read what a recipe forwards.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ME="mix-test-strict"

# Flags that SWALLOW the following token. That token is a value, never a path,
# so it must not be existence-checked: `--only boot` would otherwise refuse
# because no file named `boot` exists. Kept in sync by eye with api/mix.exs's
# @value_flags; a flag missing here can only cause a FALSE REFUSAL (loud), never
# a false green.
VALUE_FLAGS=" --only --include --exclude --seed --max-cases --max-failures --formatter --slowest --partitions --repeat-until-failure --timeout --exit-status --cover-export-name --profile-require --name "

# ExUnit accepts a repeatable trailing `:<line>` on a path to address single
# tests inside a file. It must come off before the existence check, or every
# line-addressed run would be refused.
strip_line_suffix() {
  local t="$1"
  while :; do
    case "$t" in
      *:[0-9]) t="${t%:[0-9]}" ;;
      *:[0-9][0-9]) t="${t%:[0-9][0-9]}" ;;
      *:[0-9][0-9][0-9]) t="${t%:[0-9][0-9][0-9]}" ;;
      *:[0-9][0-9][0-9][0-9]) t="${t%:[0-9][0-9][0-9][0-9]}" ;;
      *:[0-9][0-9][0-9][0-9][0-9]) t="${t%:[0-9][0-9][0-9][0-9][0-9]}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$t"
}

refusals=""
note_refusal() { refusals="${refusals}  $1"$'\n'; }

# The mix project is the CWD's own mix.exs. Without this the script would run
# `mix test` from wherever it was invoked, mix would refuse for its own reason,
# and the operator would read a confusing error instead of a named one.
# MUT: project-guard
if [ ! -f "mix.exs" ]; then
  echo "$ME: CANNOT READ — no mix.exs in $(pwd). Run this from a mix project directory (api/ or cloud/)." >&2
  exit 2
fi

# Validation runs in a FUNCTION so its `shift`s consume the function's own
# positional parameters, never the script's. The exec at the bottom therefore
# forwards the ORIGINAL argv, byte for byte — that is what makes the control
# (same test count as bare `mix test`) true by construction rather than by care.
validate_args() {
  local tok spec path found positional_only=0
  while [ "$#" -gt 0 ]; do
    tok="$1"

    if [ "$positional_only" -eq 0 ]; then
      if [ "$tok" = "--" ]; then positional_only=1; shift; continue; fi
      case "$tok" in
        --*=*) shift; continue ;;               # `--flag=value`: no separate value token
        -*)
          case "$VALUE_FLAGS" in
            *" $tok "*) shift; [ "$#" -gt 0 ] && shift; continue ;;
          esac
          shift; continue ;;
      esac
    fi

    spec="$tok"
    path="$(strip_line_suffix "$spec")"

    # MUT: exists-guard  — the arm that makes the reproduction above impossible.
    if [ ! -e "$path" ]; then
      note_refusal "argument names no file: $spec"
      shift; continue
    fi

    # MUT: matches-guard — a path that EXISTS and still runs zero tests.
    if [ -d "$path" ]; then
      found="$(find "$path" -type f -name '*_test.exs' 2>/dev/null)"
      if [ -z "$found" ]; then
        note_refusal "argument matches no test (directory holds no *_test.exs): $spec"
      fi
    else
      case "$path" in
        *_test.exs) : ;;
        *) note_refusal "argument matches no test (not a *_test.exs file): $spec" ;;
      esac
    fi
    shift
  done
}

validate_args "$@"

if [ -n "$refusals" ]; then
  {
    echo "$ME: REFUSING to run — the argument list would produce a green with no subject."
    printf '%s' "$refusals"
    echo ""
    echo "  \`mix test\` drops an unmatched path SILENTLY whenever another path matches, and still"
    echo "  exits 0 with a full \"N tests, 0 failures\" trailer. Fix the path (or drop it) before"
    echo "  quoting this gate. Nothing was run."
  } >&2
  exit 2
fi

if [ -n "${BP_MIX_TEST_STRICT_DRY_RUN:-}" ]; then
  # `$*` here is the script's OWN argv — validate_args never touched it — so a
  # dry run prints exactly what the exec below would forward.
  echo "$ME: DRY RUN (BP_MIX_TEST_STRICT_DRY_RUN set) — would exec: mix test $*"
  exit 0
fi

exec mix test "$@"
