#!/usr/bin/env bash
set -euo pipefail

# WHY THIS EXISTS — a baseline diff that answers the only question worth asking.
#
# `mix sobelow --mark-skip-all` writes api/.sobelow-skips in a NON-DETERMINISTIC
# ROW ORDER. Two runs of the same tree on the same pinned toolchain produce the
# same 24 rows in different positions, so the reconcile script's `diff -u`
# artifact reports something like "10 removed / 10 added" while NOTHING about
# the finding set changed. MEASURED on run 35250754292-era main (8bd4a8c1a,
# Elixir 1.18.1 / OTP 27): sobelow-skips.diff showed 10 `-` and 10 `+` rows;
# `sort`ing both sides made the diff EMPTY. Zero membership change, pure churn.
#
# That churn is not cosmetic — it is the exact shape of the fake green this
# baseline family exists to abolish. A reviewer who reads the row COUNT sees
# 24 -> 24 and approves; a reviewer who reads the unsorted `diff -u` sees 20
# changed lines and cannot tell a real new waiver from a permutation. Both
# readings are blind in the same direction: they cannot see ONE genuinely
# added row hiding inside nineteen reordered ones.
#
# So this script compares the row SET (a multiset, duplicates preserved) and
# reports membership separately from ordering. An ADDED row means the baseline
# is about to start swallowing a finding it did not swallow before — that is
# the event that needs a human. A reordering needs nobody.
#
# Exit codes are distinct and load-bearing:
#   0  membership identical (ordering may differ — reported, not judged)
#   1  membership differs — rows added and/or removed
#   2  FAIL CLOSED — a side is missing, unreadable, or carries zero rows
#
# The fail-closed clause is the vacuous-pass guard: an empty file trivially has
# "no added rows", so a set comparison that did not refuse emptiness would print
# a green verdict having measured nothing. Both sides are counted BEFORE any
# verdict is printed.

usage() {
  cat >&2 <<'EOF'
usage: sobelow-baseline-setdiff.sh OLD NEW
       sobelow-baseline-setdiff.sh --selftest

Compares two Sobelow baseline files as row SETS.
  exit 0 = membership identical   exit 1 = membership differs   exit 2 = fail closed
EOF
}

# Strip blank lines, sort. Duplicates are PRESERVED (plain sort, never -u):
# two identical rows are two baseline entries and dropping one would hide a
# removal.
normalize() {
  grep -v '^[[:space:]]*$' -- "$1" | sort
}

# "Type: Description,path/to/file.ex:123,FEEDBEEF" -> "Type<TAB>path/to/file.ex"
# Line number and fingerprint are dropped on purpose: they are what drifts when
# code moves, and the (type,file) rollup is what a reviewer reasons about.
rollup() {
  # No `--` before the operand: BSD sed (macOS) treats it as a FILENAME and
  # errors, which the control fixture caught — the rollup still printed, so the
  # fault was visible only in stderr. GNU sed accepts it; the portable spelling
  # is to omit it.
  sed -E 's/^([^:]+):.*,([^,]+):[0-9]+,[0-9A-Fa-f]+$/\1\t\2/' "$1" | sort | uniq -c |
    sed -E 's/^[[:space:]]*//'
}

compare() {
  local old=$1 new=$2 label_old=${3:-OLD} label_new=${4:-NEW}

  for f in "$old" "$new"; do
    if [[ ! -f $f ]]; then
      echo "FAIL CLOSED: not a readable file: $f" >&2
      return 2
    fi
  done

  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-setdiff.XXXXXX")
  # Explicit cleanup, not a RETURN trap: a RETURN trap set here is global and
  # re-fires on every later function return, including the selftest's own
  # helper, where $tmp is already gone.
  _cleanup() { rm -rf -- "$tmp"; }

  normalize "$old" > "$tmp/old" || true
  normalize "$new" > "$tmp/new" || true

  local n_old n_new
  n_old=$(wc -l < "$tmp/old" | tr -d ' ')
  n_new=$(wc -l < "$tmp/new" | tr -d ' ')

  # FAIL-CLOSED CLAUSES — both evaluated before any verdict is printed.
  if [[ $n_old -eq 0 ]]; then
    echo "FAIL CLOSED: $label_old ($old) carries ZERO baseline rows — nothing was compared" >&2
    _cleanup
    return 2
  fi
  if [[ $n_new -eq 0 ]]; then
    echo "FAIL CLOSED: $label_new ($new) carries ZERO baseline rows — nothing was compared" >&2
    _cleanup
    return 2
  fi

  comm -23 "$tmp/old" "$tmp/new" > "$tmp/removed"
  comm -13 "$tmp/old" "$tmp/new" > "$tmp/added"

  local n_removed n_added reordering_only
  n_removed=$(grep -c . "$tmp/removed" || true)
  n_added=$(grep -c . "$tmp/added" || true)

  # Reordering is only a meaningful label when membership matched: it is TRUE
  # when the sets agree but the files are not byte-identical.
  reordering_only=false
  if [[ $n_removed -eq 0 && $n_added -eq 0 ]] && ! cmp -s -- "$old" "$new"; then
    reordering_only=true
  fi

  printf '%s_rows=%s\n' "$label_old" "$n_old"
  printf '%s_rows=%s\n' "$label_new" "$n_new"
  printf 'membership_added=%s\n' "$n_added"
  printf 'membership_removed=%s\n' "$n_removed"
  printf 'reordering_only=%s\n' "$reordering_only"

  if [[ $n_added -gt 0 ]]; then
    echo "--- ADDED rows (the baseline would start swallowing these) ---"
    cat "$tmp/added"
    echo "--- ADDED rollup (count type file) ---"
    rollup "$tmp/added"
  fi
  if [[ $n_removed -gt 0 ]]; then
    echo "--- REMOVED rows (the baseline stops swallowing these) ---"
    cat "$tmp/removed"
    echo "--- REMOVED rollup (count type file) ---"
    rollup "$tmp/removed"
  fi

  if [[ $n_added -eq 0 && $n_removed -eq 0 ]]; then
    if [[ $reordering_only == true ]]; then
      echo "PASS: membership identical ($n_old rows); the files differ by ROW ORDER ONLY."
    else
      echo "PASS: membership identical ($n_old rows); files are byte-identical."
    fi
    _cleanup
    return 0
  fi

  echo "MEMBERSHIP CHANGED: +$n_added / -$n_removed — a human must adjudicate every ADDED row." >&2
  _cleanup
  return 1
}

selftest() {
  local dir fails=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-setdiff-selftest.XXXXXX")

  cat > "$dir/a" <<'EOF'

Traversal.FileModule: Directory Traversal in `File.read`,lib/a.ex:10,AAA1111
DOS.StringToAtom: Unsafe `String.to_atom`,lib/b.ex:20,BBB2222
Config.CSRF: Missing CSRF Protections,lib/router.ex:30,CCC3333
EOF
  # Same three rows, different order + no leading blank line.
  cat > "$dir/a_shuffled" <<'EOF'
Config.CSRF: Missing CSRF Protections,lib/router.ex:30,CCC3333
Traversal.FileModule: Directory Traversal in `File.read`,lib/a.ex:10,AAA1111
DOS.StringToAtom: Unsafe `String.to_atom`,lib/b.ex:20,BBB2222
EOF
  cp "$dir/a" "$dir/a_copy"
  # One extra row: the event that must red.
  { cat "$dir/a"; echo 'XSS.Raw: XSS,lib/new.ex:5,DDD4444'; } > "$dir/a_plus"
  # One extra row AND a reshuffle: the adversarial case — a real addition
  # buried inside a permutation, which is what an eyeball diff loses.
  { echo 'XSS.Raw: XSS,lib/new.ex:5,DDD4444'; grep -v '^[[:space:]]*$' "$dir/a" | sort -r; } > "$dir/a_plus_shuffled"
  # One row missing.
  grep -v 'lib/b.ex' "$dir/a" > "$dir/a_minus"
  : > "$dir/empty"
  printf '\n\n\n' > "$dir/blank_only"

  check() { # name expected_exit old new
    local name=$1 want=$2 old=$3 new=$4 got
    set +e
    compare "$old" "$new" OLD NEW > "$dir/out.$$" 2>&1
    got=$?
    set -e
    if [[ $got -eq $want ]]; then
      printf 'ok   %-34s exit=%s\n' "$name" "$got"
    else
      printf 'FAIL %-34s expected exit=%s got=%s\n' "$name" "$want" "$got"
      sed 's/^/       | /' "$dir/out.$$"
      fails=$((fails + 1))
    fi
  }

  check "byte-identical"            0 "$dir/a"        "$dir/a_copy"
  check "reordered, same set"       0 "$dir/a"        "$dir/a_shuffled"
  check "one row ADDED"             1 "$dir/a"        "$dir/a_plus"
  check "one row REMOVED"           1 "$dir/a"        "$dir/a_minus"
  check "added hidden in reorder"   1 "$dir/a"        "$dir/a_plus_shuffled"
  check "OLD empty -> fail closed"  2 "$dir/empty"    "$dir/a"
  check "NEW empty -> fail closed"  2 "$dir/a"        "$dir/empty"
  check "blank-only -> fail closed" 2 "$dir/a"        "$dir/blank_only"
  check "missing file -> fail closed" 2 "$dir/a"      "$dir/nope"

  # The reordering LABEL is itself asserted, not just the exit code: a script
  # that always printed reordering_only=false would still pass every exit-code
  # fixture above while telling the reviewer nothing.
  set +e
  compare "$dir/a" "$dir/a_shuffled" OLD NEW > "$dir/lbl" 2>&1
  set -e
  if grep -qx 'reordering_only=true' "$dir/lbl"; then
    printf 'ok   %-34s reordering_only=true\n' "label: reordered"
  else
    printf 'FAIL %-34s reordering_only=true not printed\n' "label: reordered"
    fails=$((fails + 1))
  fi
  set +e
  compare "$dir/a" "$dir/a_copy" OLD NEW > "$dir/lbl2" 2>&1
  set -e
  if grep -qx 'reordering_only=false' "$dir/lbl2"; then
    printf 'ok   %-34s reordering_only=false\n' "label: byte-identical"
  else
    printf 'FAIL %-34s reordering_only=false not printed\n' "label: byte-identical"
    fails=$((fails + 1))
  fi

  rm -rf -- "$dir"
  if [[ $fails -eq 0 ]]; then
    echo "SELFTEST PASS"
    return 0
  fi
  echo "SELFTEST FAIL ($fails)" >&2
  return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  -h | --help) usage ;;
  "") usage; exit 2 ;;
  *)
    if [[ $# -ne 2 ]]; then
      usage
      exit 2
    fi
    compare "$1" "$2" committed regenerated
    ;;
esac
