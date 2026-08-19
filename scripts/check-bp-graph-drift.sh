#!/usr/bin/env bash
# check-bp-graph-drift.sh — DIRECTIONAL byte-identity tripwire for the four
# bp-graph.js copies (search-template epic D72, hardening D12's deferral).
#
# bp-graph.js is a zero-dependency Canvas2D force graph that ships on four
# surfaces. Its own header declares the direction:
#
#     MIRROR SET — canonical lives at api/priv/static/assets/bp-graph.js
#     Edit the canonical copy, then copy it verbatim to every mirror.
#
# So this gate is DIRECTIONAL, not mutual: it compares each MIRROR against the
# declared CANONICAL and names the mirror that rotted. The header's own
# suggestion (`md5 -q <all four> | sort -u | wc -l` == 1) is MUTUAL and strictly
# weaker — it reports "not 1" for a single edit without naming WHICH file moved,
# and it cannot tell "a mirror rotted" (copy the canonical over it) from "the
# canonical was edited" (propagate to all three). Directional gives a one-line
# red and a fix message that is literal `cp` commands. There is no make target
# and no generator that syncs these copies; `cp` IS the fix.
#
# WHY IT EXISTS: the template snapshots once went 19 lines stale (missing
# setTheme), which shipped a dead theme toggle for ~10 days with no possible
# signal. doc-gates.yml triggers on templates/** and web/** but has NO
# api/priv/** entry and no **/*.js glob — a CANONICAL-only edit, precisely the
# edit the doctrine mandates, fires nothing. Hence a dedicated workflow whose
# trigger paths list all four literal copies.
#
# ADVISORY, and honestly so — but NOT for the reason first written here. The
# original ground was "there is nothing to register against", true only while
# protection was a 404. Since 2026-07-28T22:42:10Z main IS protected, with
# `enforce_admins: true` and a required-context list committed at
# `.github/required-checks.json`. This check is not on that list, so it REDS THE
# PR PAGE and does not gate the merge. (`/rulesets` -> [] is TRUE and still the
# wrong reading: protection here is classic branch protection, not a ruleset.)
# Putting a check ON that list is a repo-settings decision taken through
# scripts/required-checks-*.sh, never smuggled in here.
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.
#
# `--selftest` proves the tripwire bites, in temp files, planting nothing in the
# tree — and asserts the REASON STRINGS, not merely a drift count. That is a
# deliberate fix to the proven blind spot in the sibling
# scripts/check-astro-finder-drift.sh: its selftest asserts counts only, so
# neutering its missing-file arm still PASSES (`cmp -s` exits non-zero against a
# nonexistent file, so the count stays right while the reason silently degrades
# from "MISSING" to "DRIFTED"). Reasons are the product here; assert the product.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The direction, declared by the file itself.
CANONICAL="api/priv/static/assets/bp-graph.js"

# Every mirror, one repo-relative path per line.
MIRRORS="
web/public/bp-graph.js
templates/search-starter/public/bp-graph.js
templates/astro-search-starter/public/bp-graph.js
"

# report <root> — one REASON LINE per problem, empty output when all mirrors are
# byte-identical to the canonical. Always exits 0; the caller decides.
report() {
  root="$1"

  if [ ! -f "$root/$CANONICAL" ]; then
    echo "  MISSING CANONICAL  $CANONICAL (nothing to compare the mirrors against)"
    return 0
  fi

  echo "$MIRRORS" | while read -r mirror; do
    [ -z "$mirror" ] && continue
    if [ ! -f "$root/$mirror" ]; then
      echo "  MISSING MIRROR     $mirror (expected a verbatim copy of $CANONICAL)"
    elif ! cmp -s "$root/$CANONICAL" "$root/$mirror"; then
      echo "  DRIFTED            $mirror != $CANONICAL"
    fi
  done
}

# fix_commands — the literal cp invocations that reconcile every mirror.
fix_commands() {
  echo "$MIRRORS" | while read -r mirror; do
    [ -z "$mirror" ] && continue
    echo "  cp $CANONICAL $mirror"
  done
}

# check <root> — print the human verdict, return 1 on any drift.
check() {
  root="$1"
  rep="$(report "$root")"

  if [ -n "$rep" ]; then
    echo "DRIFT — a bp-graph.js mirror is out of sync with the canonical:"
    echo "$rep"
    echo
    echo "Fix: edit ONLY $CANONICAL, then copy it verbatim to every mirror:"
    fix_commands
    return 1
  fi

  echo "OK — all 3 mirrors are byte-identical to $CANONICAL."
  return 0
}

# ---- argument dispatch -------------------------------------------------------
# Refuse an argument this gate does not understand. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "check-bp-graph-drift: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

# ---- selftest ---------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  plant() {
    rm -rf "${tmp:?}"/*
    mkdir -p "$tmp/$(dirname "$CANONICAL")"
    printf 'canonical bp-graph bytes\n' > "$tmp/$CANONICAL"
    echo "$MIRRORS" | while read -r m; do
      [ -z "$m" ] && continue
      mkdir -p "$tmp/$(dirname "$m")"
      cp "$tmp/$CANONICAL" "$tmp/$m"
    done
  }

  fail() {
    echo "SELFTEST FAIL: $1"
    echo "--- report was ---"
    printf '%s\n' "${2:-}"
    exit 1
  }

  assert_has() { # <report> <needle> <label>
    case "$1" in
      *"$2"*) ;;
      *) fail "$3 — expected the report to contain: $2" "$1" ;;
    esac
  }

  assert_lacks() { # <report> <needle> <label>
    case "$1" in
      *"$2"*) fail "$3 — report must NOT contain: $2" "$1" ;;
      *) ;;
    esac
  }

  assert_lines() { # <report> <n> <label>
    got="$(printf '%s\n' "$1" | grep -c '[^[:space:]]' || true)"
    [ "$got" -eq "$2" ] || fail "$3 — expected $2 reason line(s), got $got" "$1"
  }

  # 1. Byte-identical set → silent, and the check exits 0.
  plant
  rep="$(report "$tmp")"
  assert_lines "$rep" 0 "identical copies"
  check "$tmp" >/dev/null || fail "identical copies should exit 0" "$rep"

  # 2. One mutated mirror → exactly one DRIFTED line NAMING that mirror, and the
  #    other two mirrors are not implicated (directional: one edit, one red).
  plant
  printf 'x' >> "$tmp/templates/search-starter/public/bp-graph.js"
  rep="$(report "$tmp")"
  assert_lines "$rep" 1 "one mutated mirror"
  assert_has "$rep" "DRIFTED" "one mutated mirror"
  assert_has "$rep" "templates/search-starter/public/bp-graph.js != $CANONICAL" "one mutated mirror"
  assert_lacks "$rep" "web/public/bp-graph.js" "one mutated mirror must not implicate siblings"
  if check "$tmp" >/dev/null; then fail "a mutated mirror must exit 1" "$rep"; fi

  # 3. A DELETED mirror must read MISSING MIRROR — not DRIFTED. This is the arm
  #    the sibling script's count-only selftest cannot watch: `cmp -s` also fails
  #    on a nonexistent file, so a neutered missing-file branch keeps the COUNT
  #    right and only degrades the REASON. Asserting the string bites.
  plant
  rm -f "$tmp/web/public/bp-graph.js"
  rep="$(report "$tmp")"
  assert_lines "$rep" 1 "deleted mirror"
  assert_has "$rep" "MISSING MIRROR     web/public/bp-graph.js" "deleted mirror"
  assert_lacks "$rep" "DRIFTED" "a deleted mirror must not be reported as DRIFTED"
  if check "$tmp" >/dev/null; then fail "a deleted mirror must exit 1" "$rep"; fi

  # 4. Mutation AND deletion together → both reasons, both named.
  plant
  printf 'x' >> "$tmp/templates/astro-search-starter/public/bp-graph.js"
  rm -f "$tmp/web/public/bp-graph.js"
  rep="$(report "$tmp")"
  assert_lines "$rep" 2 "mutation + deletion"
  assert_has "$rep" "MISSING MIRROR     web/public/bp-graph.js" "mutation + deletion"
  assert_has "$rep" "DRIFTED            templates/astro-search-starter/public/bp-graph.js" "mutation + deletion"

  # 5. A missing CANONICAL is its own reason — never three phantom mirror drifts.
  plant
  rm -f "$tmp/$CANONICAL"
  rep="$(report "$tmp")"
  assert_lines "$rep" 1 "missing canonical"
  assert_has "$rep" "MISSING CANONICAL  $CANONICAL" "missing canonical"
  assert_lacks "$rep" "MISSING MIRROR" "a missing canonical must not cascade into mirror reasons"
  if check "$tmp" >/dev/null; then fail "a missing canonical must exit 1" "$rep"; fi

  # 6. The fix message is three literal cp commands, one per mirror.
  fixes="$(fix_commands)"
  assert_lines "$fixes" 3 "fix commands"
  assert_has "$fixes" "cp $CANONICAL web/public/bp-graph.js" "fix commands"

  echo "SELFTEST PASS: directional tripwire reports DRIFTED / MISSING MIRROR /"
  echo "               MISSING CANONICAL by REASON STRING, names the offending"
  echo "               path, exits 1 on each, and emits 3 literal cp fixes."
  exit 0
fi

# ---- real check -------------------------------------------------------------
echo "bp-graph.js mirror identity (advisory): 3 mirrors vs $CANONICAL"
check "$REPO_ROOT"
