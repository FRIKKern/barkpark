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
# EXIT CODES — all of them, because a caller that cannot tell a refusal from a
# red suite has no gate (task-620ea822de73bf5e):
#
#   0   `mix test` ran and every test passed.
#   1   mix's own failure: a compile error, or `mix test` refusing because EVERY
#       named path was unmatched. Tests may or may not have run.
#   2   `mix test` RAN TO COMPLETION and tests FAILED. This is ExUnit's failure
#       status (`--exit-status`, default 2) — the suite has a subject and a red.
#   64  REFUSED BEFORE RUNNING — this script's own verdict. NOTHING was run.
#       The argument list would have produced a green with no subject, or the
#       CWD is not a mix project.
#
# WHY 64 and not 3: ExUnit's documented statuses are 0 on success and the
# `--exit-status` value on failure, whose default is 2; mix itself uses 1. Any
# small integer is reachable because `--exit-status N` is caller-settable, so
# the refusal code must be one nobody would ever pass: 64 is sysexits(3)'s
# EX_USAGE, and a refusal IS a usage error — the argv named a file that is not
# there. A gate may therefore key on it directly:
#
#   ../scripts/mix-test-strict.sh test/a_test.exs; rc=$?
#   case $rc in 0) echo PASS ;; 64) echo REFUSED, nothing ran ;; *) echo TESTS FAILED ;; esac
#
# BEFORE 2026-09-20 both refusal arms exited 2, i.e. the SAME code ExUnit uses
# for "tests failed" — `… || echo REFUSED` called a red suite a refusal, and the
# remedy for each is the opposite one (fix the argv vs fix the code).
#
# THE LINE ARM (task-11a8c96b5b1d7156, reproduced 2026-09-22): a path that
# exists and IS a *_test.exs file can still run zero tests when it carries a
# `:LINE` suffix that resolves to no test. ExUnit selects the test declared
# CLOSEST AT OR BEFORE the address (ExUnit.Filters.has_tag/3 for {:line, n}:
# `tags.line <= line` and `closest_test_before_line/2`, plus an exact match on a
# `describe` line). An address ABOVE every declaration in the file therefore
# selects nothing — `All tests have been excluded.` / `0 tests, 0 failures
# (N excluded)` at EXIT 0. Measured on Elixir 1.19.5, not assumed:
#
#   line 6 (inside a helper, above the first test)  -> 0 tests, 0 failures, rc 0
#   line 11 (a `describe` line)                     -> 2 tests, rc 0
#   line 12 (a `test` line) and every line below it -> 1 test,  rc 0
#
# That is how a studio worker's post-fix N=20 control printed `0 tests, 0
# failures (3 excluded)` twenty times at exit 0: the same PR's fix had inserted
# a helper ABOVE the addressed line, so the address no longer named a test. A
# green with no subject — the assertion is fine, the code path never arrives.
#
# The refusal DISTINGUISHES the two cases, because the remedies differ:
#   STALE ADDRESS          — the line DID name a test at a git revision this
#                            checkout can read, and an edit moved it. The
#                            message names the revision, the test, and the line
#                            it sits on NOW, so the operator can re-address.
#   NEVER NAMED A TEST     — the line resolved to nothing at that revision
#                            either. The address was wrong when it was written.
#   (UNCLASSIFIED          — no readable git revision to compare against; the
#                            refusal still fires, it just cannot say which.)
#
# ONE-DIRECTIONAL, deliberately: the declaration scan is a generous regex over
# `test` / `describe` / `property` / `doctest` at the head of a line. A line it
# matches by accident only LOWERS the first-declaration line, i.e. makes the
# guard refuse LESS. A file in which it recognises NO declaration at all (every
# test produced by a project-local macro, say) is left alone entirely — the
# guard needs at least one declaration before it will refuse anything, so it can
# never red a run that `mix test` would have given a subject.
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

# The refusal status. Named once so a caller can grep it out of this file and so
# the harness can mutate it back to 2 to prove the distinctness case is real.
# See the EXIT CODES block above for why it is 64 and not 3.
REFUSE_EXIT=64

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

# The line numbers `strip_line_suffix` takes OFF, oldest first. ExUnit accepts a
# repeatable suffix (`foo_test.exs:12:40`), and each one is addressed
# independently, so each one is checked independently.
line_suffixes() {
  local t="$1" out="" n=""
  while :; do
    case "$t" in
      *:[0-9]|*:[0-9][0-9]|*:[0-9][0-9][0-9]|*:[0-9][0-9][0-9][0-9]|*:[0-9][0-9][0-9][0-9][0-9])
        n="${t##*:}"; out="$n $out"; t="${t%:*}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$out"
}

# Declarations in an ExUnit file, as `LINE<TAB>KIND<TAB>REST`. Deliberately
# generous: see the ONE-DIRECTIONAL note in the header. Reads stdin so it can be
# pointed at a working-tree file OR at `git show <rev>:<path>` without a temp
# file rule of its own.
decl_lines() {
  grep -nE '^[[:space:]]*(test|describe|property|doctest)([[:space:]]|\()' \
    | sed -e 's/^\([0-9][0-9]*\):[[:space:]]*\([a-z][a-z]*\)[[:space:](]*/\1\t\2\t/'
}

# Does line $2 resolve to a test, given the declarations on stdin?
#   0 = yes   1 = no   2 = cannot tell (no declaration recognised at all)
# The rule is ExUnit's, measured above: the closest TEST declaration at or
# before the line, or an exact hit on a DESCRIBE line.
line_resolves() {
  local line="$1" first_test="" saw_any=0 l k
  while IFS="$(printf '\t')" read -r l k _rest; do
    case "$l" in ''|*[!0-9]*) continue ;; esac
    saw_any=1
    case "$k" in
      describe) [ "$l" -eq "$line" ] && return 0 ;;
      *) if [ -z "$first_test" ] || [ "$l" -lt "$first_test" ]; then first_test="$l"; fi ;;
    esac
  done
  [ "$saw_any" -eq 1 ] || return 2
  [ -n "$first_test" ] || return 2
  [ "$line" -ge "$first_test" ] && return 0
  return 1
}

# The declaration a line WOULD have resolved to, as `LINE<TAB>KIND<TAB>REST`.
closest_decl() {
  local line="$1" best="" l row
  while IFS= read -r row; do
    l="${row%%	*}"
    case "$l" in ''|*[!0-9]*) continue ;; esac
    [ "$l" -le "$line" ] && best="$row"
  done
  printf '%s' "$best"
}

# Which git revisions this checkout can compare a file against, best first. A
# stale address is one that resolved at a revision and does not resolve now, so
# without a revision the two cases are indistinguishable and the refusal says so
# rather than guessing.
git_candidate_revs() {
  local dir="$1" mb=""
  command -v git >/dev/null 2>&1 || return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 0
  echo "HEAD"
  mb="$(git -C "$dir" merge-base HEAD origin/main 2>/dev/null)"
  if [ -n "$mb" ] && [ "$mb" != "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" ]; then
    echo "$mb"
  fi
}

# The refusal body for one unresolvable `file:LINE`. Multi-line on purpose: the
# operator has to learn WHICH address went stale and WHERE its test went, or the
# message is just "no tests ran" with extra words.
explain_line_address() {
  local path="$1" line="$2" spec="$3"
  local dir base rel rev was decl old_line old_kind old_name new_line shift_by
  local first_test rc

  first_test="$(decl_lines < "$path" | awk -F'\t' '$2 != "describe" { print $1; exit }')"

  printf 'line address resolves to no test: %s\n' "$spec"
  printf '      ExUnit runs the test declared closest AT OR BEFORE the address. Line %s is\n' "$line"
  if [ -n "$first_test" ]; then
    printf '      above the first test declaration in this file (line %s), so it selects nothing\n' "$first_test"
  else
    printf '      above every test declaration in this file, so it selects nothing\n'
  fi
  printf '      and mix test would still exit 0 with a "0 tests, 0 failures (N excluded)" trailer.\n'

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  rel=""
  for rev in $(git_candidate_revs "$dir"); do
    [ -n "$rel" ] || rel="$(git -C "$dir" ls-files --full-name -- "$base" 2>/dev/null | head -1)"
    [ -n "$rel" ] || break
    was="$(git -C "$dir" show "$rev:$rel" 2>/dev/null | decl_lines)"
    [ -n "$was" ] || continue
    line_resolves "$line" <<< "$was"; rc=$?
    [ "$rc" -eq 0 ] || continue

    # STALE: it resolved at $rev and does not resolve now.
    decl="$(closest_decl "$line" <<< "$was")"
    old_line="$(printf '%s' "$decl" | cut -f1)"
    old_kind="$(printf '%s' "$decl" | cut -f2)"
    old_name="$(printf '%s' "$decl" | cut -f3- | sed -e 's/[[:space:]]*do[[:space:]]*$//')"
    printf '      STALE ADDRESS: at %s this line DID name a test — %s %s, declared\n' \
      "$rev" "$old_kind" "$old_name"
    new_line=""
    if [ -n "$old_name" ]; then
      new_line="$(decl_lines < "$path" | awk -F'\t' -v n="$old_name" \
        'index($3, substr(n,1,60)) == 1 { print $1; exit }')"
    fi
    if [ -n "$new_line" ]; then
      shift_by=$((new_line - old_line))
      printf '      at line %s there and at line %s HERE (shifted by %+d). Re-address at :%s.\n' \
        "$old_line" "$new_line" "$shift_by" "$new_line"
    else
      printf '      at line %s there, and no declaration with that name is in the file now.\n' "$old_line"
    fi
    printf '      An edit in this tree moved it: inserting a helper shifts every line below it.\n'
    return 0
  done

  if [ -n "$rel" ]; then
    printf '      NEVER NAMED A TEST: no readable revision of this file resolves line %s to a\n' "$line"
    printf '      test either, so the address was wrong when it was written — not shifted.\n'
  else
    printf '      UNCLASSIFIED: this file is not in a readable git revision, so the guard cannot\n'
    printf '      say whether the address went stale or was never a test. It refuses either way.\n'
  fi
}

refusals=""
note_refusal() { refusals="${refusals}  $1"$'\n'; }

# The mix project is the CWD's own mix.exs. Without this the script would run
# `mix test` from wherever it was invoked, mix would refuse for its own reason,
# and the operator would read a confusing error instead of a named one.
# MUT: project-guard
if [ ! -f "mix.exs" ]; then
  echo "$ME: CANNOT READ — no mix.exs in $(pwd). Run this from a mix project directory (api/ or cloud/)." >&2
  echo "$ME: REFUSED before running (exit $REFUSE_EXIT) — nothing was run." >&2
  exit "$REFUSE_EXIT"
fi

# Validation runs in a FUNCTION so its `shift`s consume the function's own
# positional parameters, never the script's. The exec at the bottom therefore
# forwards the ORIGINAL argv, byte for byte — that is what makes the control
# (same test count as bare `mix test`) true by construction rather than by care.
validate_args() {
  local tok spec path found ln lrc decls positional_only=0
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

      # MUT: line-guard — a path that exists, IS a test file, and still runs
      # zero tests because its `:LINE` suffix is above every declaration.
      # Scoped to specs that CARRY a line suffix: a bare path is byte-for-byte
      # unaffected by this arm.
      decls="$(decl_lines < "$path")"
      for ln in $(line_suffixes "$spec"); do
        line_resolves "$ln" <<< "$decls"; lrc=$?
        [ "$lrc" -eq 0 ] && continue
        # 2 = no declaration recognised at all (macro-generated tests). Silent
        # on purpose: refusing there could red a run that has a real subject.
        [ "$lrc" -eq 2 ] && continue
        note_refusal "$(explain_line_address "$path" "$ln" "$spec")"
      done
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
    echo ""
    echo "  Exit $REFUSE_EXIT means REFUSED, nothing ran. A completed run whose tests failed exits 2."
  } >&2
  exit "$REFUSE_EXIT"
fi

if [ -n "${BP_MIX_TEST_STRICT_DRY_RUN:-}" ]; then
  # `$*` here is the script's OWN argv — validate_args never touched it — so a
  # dry run prints exactly what the exec below would forward.
  echo "$ME: DRY RUN (BP_MIX_TEST_STRICT_DRY_RUN set) — would exec: mix test $*"
  exit 0
fi

exec mix test "$@"
