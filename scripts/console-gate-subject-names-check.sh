#!/usr/bin/env bash
# console-gate-subject-names — the declared leg set IS the expression's literals.
#
# WHY THIS FILE EXISTS. `.github/workflows/console-harness.yml` job
# `console-gate-subject` publishes its verdict as the check-run NAME, because a
# name is the one field of a check run GitHub does not ration. That makes the
# `name:` a whole-expression template, which no static reader of the workflow
# can resolve — and an unresolvable job name is a CATCH-ALL: its match regex is
# `^.*$`, it claims every other workflow's rendered check-run name, and the
# blocking-closure builder in scripts/required-checks-verify.sh then resolves
# every required context to it. That is not hypothetical. It happened: main was
# red on `Elixir path-escape ratchet` and `merge-verb-table` from 7b991dec9
# (2026-09-22T09:53Z) until the directive this file guards was added, and the
# closure collapse surfaced as four UNRELATED workflow files reported for
# "UNRESOLVED file-header blocking prose (4 > 3)".
#
# The repo's answer is the `# required-checks: matrix-name-legs <file> <filter>`
# directive: the job declares its finite leg set in a committed file, and the
# generator expands the template into that many LITERAL index rows. The
# generator checks the file resolves to literals. NOTHING checks that those
# literals are the strings the expression can actually produce — so a leg file
# left behind by an edit to the expression would quietly re-open the hole while
# every instrument stayed green. This test is that missing check, and it is the
# reason the directive is safe to use here at all.
#
# It compares two derivations of the same set:
#   (1) the single-quoted string literals inside the job's `name:` expression;
#   (2) the committed leg file the directive names.
# Disagreement in EITHER direction is a failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFTEST=0
case "${1:-}" in --selftest) SELFTEST=1; shift ;; esac
WF="${1:-$ROOT/.github/workflows/console-harness.yml}"
LEGS_OVERRIDE="${2:-}"
JOB="console-gate-subject"

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[ -f "$WF" ] || { echo "CANNOT READ: no workflow at $WF" >&2; exit 2; }

# ── --selftest: the clause proven in BOTH directions ─────────────────────────
#
# A guard that cannot fail is not a guard. These arms drive THIS script — the
# same code path, not a re-implementation of it — against leg files mutated one
# row at a time, and assert the exit code each mutation must produce. The green
# arm is arm 1: the committed pair. Without it, "reds on everything" would pass
# the other three.
selftest() {
  local st rc=0 out ec
  st="$(mktemp -d)"
  probe() { # <label> <expected-exit> <legs-file>
    out="$(bash "${BASH_SOURCE[0]}" "$WF" "$3" 2>&1)"; ec=$?
    if [ "$ec" -eq "$2" ]; then
      echo "  ok   $1 (exit $ec)"
    else
      echo "  SELFTEST FAIL: $1 expected exit $2, got $ec" >&2
      printf '%s\n' "$out" | sed 's/^/        /' >&2
      rc=1
    fi
  }

  local real
  real="$ROOT/$LEGSFILE"
  [ -f "$real" ] || { echo "CANNOT READ: the committed leg file is missing; the selftest has no honest input to mutate" >&2; rm -rf "$st"; return 2; }

  cp "$real" "$st/honest.json"
  probe "1/4 the committed leg file matches the expression's literals" 0 "$st/honest.json"

  jq 'del(.[0])' "$real" > "$st/short.json"
  probe "2/4 a leg the expression CAN render but the file omits reds (the invisible-name half)" 1 "$st/short.json"

  jq '. + ["Console gate subject: a sentence this job can never render"]' "$real" > "$st/extra.json"
  probe "3/4 a leg the file declares but the expression can NEVER render reds (the stale-row half)" 1 "$st/extra.json"

  printf '%s\n' '[]' > "$st/empty.json"
  probe "4/4 an EMPTY leg file reds — resolving a template to nothing is not an enumeration" 1 "$st/empty.json"

  rm -rf "$st"
  if [ "$rc" -eq 0 ]; then echo "SELFTEST OK — the clause can both pass and fail."; else echo "SELFTEST FAILED" >&2; fi
  return "$rc"
}


# The directive, scoped to this job's block.
directive="$(awk -v want="$JOB" '
  /^jobs:/ { injobs = 1; next }
  injobs && /^[a-z]/ { injobs = 0 }
  injobs && /^  [A-Za-z0-9_.-]+:/ { j = $0; sub(/^  /, "", j); sub(/:.*$/, "", j); cur = j; next }
  injobs && cur == want && /^[ \t]*#[ \t]*required-checks:[ \t]*matrix-name-legs[ \t]/ {
    line = $0
    sub(/^[ \t]*#[ \t]*required-checks:[ \t]*matrix-name-legs[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    print line
    exit
  }
' "$WF")"

if [ -z "$directive" ]; then
  fail "job '$JOB' declares no \`# required-checks: matrix-name-legs <file> <filter>\`. Its \`name:\` is a whole-expression template, so without the declaration it is a CATCH-ALL that claims every other workflow's check-run name."
  echo "$rc" >/dev/null
  exit 1
fi

legsfile="${directive%%[[:space:]]*}"
legspath="$ROOT/$legsfile"
[ -n "$LEGS_OVERRIDE" ] && legspath="$LEGS_OVERRIDE"
[ -f "$legspath" ] || { echo "CANNOT READ: declared leg file $legsfile is missing" >&2; exit 2; }
LEGSFILE="$legsfile"

if [ "$SELFTEST" = "1" ]; then
  selftest
  exit $?
fi


# (1) the literals the expression can render.
name_line="$(awk -v want="$JOB" '
  /^jobs:/ { injobs = 1; next }
  injobs && /^[a-z]/ { injobs = 0 }
  injobs && /^  [A-Za-z0-9_.-]+:/ { j = $0; sub(/^  /, "", j); sub(/:.*$/, "", j); cur = j; next }
  injobs && cur == want && /^    name:/ { print; exit }
' "$WF")"
[ -n "$name_line" ] || { echo "CANNOT READ: job '$JOB' has no \`name:\` line" >&2; exit 2; }

# A SCAN, NOT A SPLIT. Every single-quoted run in the expression is a candidate
# rendering; the `== '1'` comparand is one too, which is why short runs are
# dropped — a rendered check-run name is a sentence, never a one-character
# comparand. The floor is asserted below, so a rewrite that made the real names
# short would red here rather than silently shrink the set.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$name_line" | grep -o "'[^']*'" | sed "s/^'//; s/'$//" \
  | awk 'length($0) > 10' | LC_ALL=C sort -u > "$tmp/from-expression"

jq -r '.[]' "$legspath" 2>/dev/null | LC_ALL=C sort -u > "$tmp/from-file" \
  || { echo "CANNOT READ: $legsfile is not a JSON array of strings" >&2; exit 2; }

n_expr="$(grep -c . "$tmp/from-expression" || true)"
n_file="$(grep -c . "$tmp/from-file" || true)"

# Scanning nothing is the vacuous pass this file exists to refuse.
[ "$n_expr" -ge 2 ] \
  || fail "read $n_expr renderable literal(s) out of job '$JOB''s \`name:\` expression. A verdict name with fewer than two renderings is not a verdict, and a zero-length read is a no-read, not a match."

only_expr="$(comm -23 "$tmp/from-expression" "$tmp/from-file")"
only_file="$(comm -13 "$tmp/from-expression" "$tmp/from-file")"

if [ -n "$only_expr" ]; then
  fail "job '$JOB' can render name(s) that $legsfile does not declare — each one is a check-run name no static reader can account for:"
  printf '%s\n' "$only_expr" | sed 's/^/        /' >&2
fi
if [ -n "$only_file" ]; then
  fail "$legsfile declares name(s) job '$JOB' can no longer render — a stale leg row matches a name nothing publishes:"
  printf '%s\n' "$only_file" | sed 's/^/        /' >&2
fi

if [ "$rc" -eq 0 ]; then
  echo "ok  job '$JOB': $n_expr renderable name(s) in the \`name:\` expression ≡ $n_file declared in $legsfile"
fi
exit "$rc"
