#!/usr/bin/env bash
# docblock-enumeration-check.sh — a guard script's OWN header must enumerate
# every blocking check it runs.
#
# WHY THIS EXISTS. A guard's docblock claiming "this reds when X" is the purest
# phantom-warrant shape in the tree: a reader auditing the script's contract
# reads the header, never the 1,400 lines below it, and concludes the listed
# arms are the whole contract. scripts/docs-anchors-check.sh shipped SEVEN
# blocking arms (§3b, §3c, §8b, §8c, §9, §10, §12) that appear nowhere in its
# own "Blocking checks:" list — so the header understated the gate by nearly
# half, in BOTH directions that matter: a reader could not know §9 would red
# them, and a reader deleting §12 would find nothing in the header to contradict.
#
# A roster reads as complete by construction (§9's lesson, same shape), so no
# reader catches it. The fix is not a corrected list — that decays the day the
# next arm lands — it is a DERIVATION: the required set is computed from the
# code and compared to the header, both directions.
#
# CONTRACT (all blocking; each is a separate exit-1 arm):
#   A. Every numbered section that can set FAIL is named in the docblock.
#   B. Every number the docblock enumerates exists as a numbered section.
#   C. The derived blocking set is NON-EMPTY. A parser that stops matching
#      (headings reformatted, `FAIL=1` renamed) otherwise passes vacuously —
#      an empty required set is satisfied by any docblock at all.
#
# A "numbered section" is a line `# --- <N>. …`; N is `12`, `3b`, `8c`.
# A section is BLOCKING if its body assigns `FAIL=1` or calls `fail "…"`.
# The docblock is everything above `set -euo pipefail`; an enumeration entry is
# `#  <N>. ` at the head of a comment line. Warn-only arms may be enumerated
# (§7 is) — arm B accepts them because they DO exist as sections; only arm A's
# required set is restricted to blocking ones.
#
# Usage:  bash scripts/docblock-enumeration-check.sh [file …]
#         bash scripts/docblock-enumeration-check.sh --selftest
# Default target: scripts/docs-anchors-check.sh (the only script in the tree
# whose header enumeration is bound to in-file section anchors — see the PR).
#
# bash 3.2 compatible: no associative arrays, no mapfile, no 3-arg match().

set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "usage: docblock-enumeration-check.sh [--selftest|--help] [file ...]"
  echo "  (no args)   check scripts/docs-anchors-check.sh"
  echo "  --selftest  run the hermetic fixture suite (exit 0 pass / 1 fail)"
}

# --- derivation ---------------------------------------------------------------

# Numbers of sections whose body can set FAIL. Printed one per line.
blocking_sections() {
  awk '
    /^# --- / {
      sec = ""
      if ($0 ~ /^# --- [0-9]+[a-z]*\./) { sec = $3; sub(/\.$/, "", sec) }
      next
    }
    sec != "" && (/FAIL=1/ || /(^|[ \t;&|(])fail "/) { seen[sec] = 1 }
    END { for (s in seen) print s }
  ' "$1"
}

# Every numbered section, blocking or not.
all_sections() {
  awk '
    /^# --- [0-9]+[a-z]*\./ { s = $3; sub(/\.$/, "", s); print s }
  ' "$1"
}

# Numbers the docblock enumerates.
docblock_numbers() {
  sed -n '1,/^set -euo pipefail/p' "$1" |
    grep -oE '^#[[:space:]]+[0-9]+[a-z]*\.[[:space:]]' |
    sed -E 's/^#[[:space:]]+//; s/\.[[:space:]]*$//'
}

check_file() {
  local f="$1" rc=0 n
  local blocking enumerated allsec

  if [ ! -f "$f" ]; then
    echo "FAIL: $f does not exist"
    return 1
  fi

  blocking=$(blocking_sections "$f" | sort -u)
  enumerated=$(docblock_numbers "$f" | sort -u)
  allsec=$(all_sections "$f" | sort -u)

  # C. NON-VACUITY FIRST. Arms A and B are both absence proofs, and an empty
  # required set makes A pass against ANY docblock — including one that lists
  # nothing. This is the only arm here with a known ground truth.
  if [ -z "$blocking" ]; then
    echo "FAIL: $f — derived ZERO blocking sections. Either the '# --- <N>.'"
    echo "      headings or the FAIL=1 / fail \"…\" idiom changed shape and this"
    echo "      guard stopped reading the file. A zero here is a broken parser,"
    echo "      never a clean bill of health."
    return 1
  fi

  # A. blocking section not named in the docblock
  for n in $blocking; do
    if ! printf '%s\n' "$enumerated" | grep -qxF "$n"; then
      echo "FAIL: $f §$n can set FAIL but is absent from the docblock's enumeration"
      echo "      (a reader auditing this script's contract concludes §$n does not exist)"
      rc=1
    fi
  done

  # B. docblock names a number with no section behind it
  for n in $enumerated; do
    if ! printf '%s\n' "$allsec" | grep -qxF "$n"; then
      echo "FAIL: $f docblock enumerates §$n, which no '# --- $n.' section defines"
      echo "      (the arm was renamed, renumbered or deleted; the claim outlived it)"
      rc=1
    fi
  done

  if [ "$rc" -eq 0 ]; then
    echo "ok:   $f docblock enumerates all $(printf '%s\n' "$blocking" | wc -l | tr -d ' ') blocking section(s); no orphan entries"
  fi
  return "$rc"
}

# --- selftest -----------------------------------------------------------------
# Drives THIS script against mktemp fixtures, proving each arm still reds on its
# own planted violation AND stays quiet on the corrected real file. A guard
# proven only present-in-file is not proven to fire.

ST_FAIL=0
st_case() {
  local name="$1" want="$2" needle="$3" target="$4" rc out
  set +e
  out=$(bash "$SELF" "$target" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$want" ]; then
    echo "SELFTEST FAIL: $name — expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/    /'
    ST_FAIL=1
    return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF "$needle"; then
    echo "SELFTEST FAIL: $name — exit $rc as expected but output lacks: $needle"
    printf '%s\n' "$out" | sed 's/^/    /'
    ST_FAIL=1
    return
  fi
  echo "selftest ok: $name (exit $rc)"
}

run_selftest() {
  local dir real
  dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" EXIT
  real="$REPO_ROOT/scripts/docs-anchors-check.sh"

  # QUIET ARM — the real, corrected gate must pass. This is the arm that fails
  # if the docblock fix in this PR is reverted.
  st_case "real docs-anchors-check.sh is complete" 0 "ok:" "$real"

  # ARM A — drop one blocking section from the docblock enumeration.
  sed '/^#   3\. Every "Code anchors" line/d' "$real" > "$dir/drop-a.sh"
  st_case "A: blocking section dropped from docblock" 1 "absent from the docblock" "$dir/drop-a.sh"

  # ARM B — enumerate a number no section defines.
  awk 'NR==5{print; print "#  99. a check that does not exist."; next} {print}' \
    "$real" > "$dir/orphan-b.sh"
  st_case "B: docblock entry with no section" 1 "which no '# --- 99.' section defines" "$dir/orphan-b.sh"

  # ARM C — non-vacuity: reformat every section heading away. Arm A would pass
  # vacuously (empty required set); C must red instead.
  sed 's/^# --- \([0-9]\)/# == \1/' "$real" > "$dir/vacuous-c.sh"
  st_case "C: zero derived blocking sections" 1 "derived ZERO blocking sections" "$dir/vacuous-c.sh"

  # CONTROL — a file that is complete by construction must NOT red, or arms A/B
  # are just "any file reds".
  cat > "$dir/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
# fixture — complete by construction
#
# Blocking checks:
#   1. first.
#   2. second.
set -euo pipefail
# --- 1. first ---
FAIL=1
# --- 2. second ---
fail "boom"
CLEAN
  st_case "CONTROL: complete fixture stays quiet" 0 "ok:" "$dir/clean.sh"

  if [ "$ST_FAIL" -ne 0 ]; then
    echo "docblock-enumeration-check --selftest: FAILED"
    exit 1
  fi
  echo "docblock-enumeration-check --selftest: PASS"
  exit 0
}

# --- main ---------------------------------------------------------------------

if [ "$#" -gt 0 ]; then
  case "$1" in
    --selftest) run_selftest ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "docblock-enumeration-check: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

RC=0
if [ "$#" -eq 0 ]; then
  set -- "$REPO_ROOT/scripts/docs-anchors-check.sh"
fi
for target in "$@"; do
  check_file "$target" || RC=1
done
exit "$RC"
