#!/usr/bin/env bash
#
# The EMPTY-BASELINE TWIN SCAN: the only proof that can see a D141(c) waiver
# transfer.
#
# WHY. Sobelow binds an inline `# sobelow_skip [...]` annotation to a function
# by AST ADJACENCY. Put the annotation INSIDE a function body and it does not
# no-op — it silently binds to the NEXT `def` in the file. The function the
# author reviewed goes back to being flagged, and a DIFFERENT, unreviewed
# function becomes waived. api/scripts/sobelow-inline-overlap-check.sh's
# --binding predicates catch the source-text shapes of this (MISSPELL,
# DETACHED, INDENT, MULTI-CLAUSE) and its PAIRING PIN catches a displacement
# onto another def the author named in advance. Both are STATIC. This script is
# the DYNAMIC twin: it asks the scanner itself which findings moved.
#
# WHY A NORMAL BEFORE/AFTER DIFF CANNOT SEE IT. Run the real gate
# (`mix sobelow --skip`) before and after an annotation migration and the
# transferred waiver is invisible: the finding it now silently waives was
# ALREADY being swallowed by the api/.sobelow-skips fingerprint baseline, so
# its disappearance changes no number. The baseline has to be taken OUT of both
# trees for the annotations to be the only thing acting. That is the twin scan:
#
#     from-ref tree ── .sobelow-skips emptied ──> scan ──> finding set A
#     to-ref   tree ── .sobelow-skips emptied ──> scan ──> finding set B
#
#   REMOVED (in A, not in B)  a finding an annotation in the to-tree now waives.
#                             The intended ones are the migration's targets; an
#                             EXTRA one is the transfer's signature — a waiver
#                             landed on a function nobody reviewed.
#   ADDED   (in B, not in A)  a finding that came BACK. An annotation-only
#                             change must never resurrect a finding: a waiver
#                             was detached from the function it used to cover.
#                             This is the other half of the SAME displacement —
#                             when an annotation slides into the body above it,
#                             the function it left reappears here and the
#                             function below it disappears from REMOVED.
#
# WHAT REDS (exit 1)
#   * any ADDED finding                            (always asserted)
#   * REMOVED count != --expect-removed N          (only when N is declared;
#                                                   this is how a migration
#                                                   that knows it is waiving
#                                                   exactly N findings catches
#                                                   the extra removal)
#
# EXIT CODES
#   0  twin scan completed and every asserted predicate held
#   1  a finding: an added finding, or a removed count that misses --expect-removed
#   2  fail-closed. Usage error, an unresolvable ref, a tree with no mix.exs, a
#      baseline that would not empty, mismatched .sobelow-conf between the twins,
#      or a scan that produced ZERO findings. A comparison of two empty
#      populations has not passed — it has failed to run, and exit 0 there would
#      read as "no transfer" when it means "no measurement".
#
# KNOWN LIMITS
#   * Findings are keyed on the scanner's own compact line (detector + message +
#     path:line). A pure LINE SHIFT — the same finding at a new line because
#     code above it moved — reads as one REMOVED plus one ADDED. That is why
#     this check is for annotation-only migrations, where nothing above the
#     annotations moves; on a mixed diff, read the pairs before believing them.
#   * A `.sobelow-conf` that differs between the two trees would make the twins
#     incomparable, so that is refused (exit 2) rather than reported.
#
# USAGE
#   api/scripts/sobelow-annotation-transfer-check.sh [<from-ref>..<to-ref>]
#                                                    [--expect-removed N]
#                                                    [--selftest]
#
# Default range: origin/main..HEAD.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: sobelow-annotation-transfer-check.sh [<from-ref>..<to-ref>]
                                            [--expect-removed N] [--selftest]
                                            [--from-tree DIR --to-tree DIR]

  <from-ref>..<to-ref>  refs to twin-scan (default: origin/main..HEAD)
  --expect-removed N    red unless exactly N findings were removed
  --selftest            run the fixture arms that prove this check can fail,
                        then exit; scans throwaway fixture trees only
  --from-tree DIR       scan an already-materialised tree instead of exporting
  --to-tree DIR         a ref. Both must be given together. Used by --selftest.
USAGE
}

API_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

RANGE=""
EXPECT_REMOVED=""
SELFTEST=0
FROM_TREE=""
TO_TREE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --expect-removed)
      [[ $# -ge 2 ]] || { echo "error: --expect-removed needs a value" >&2; exit 2; }
      EXPECT_REMOVED=$2
      shift 2
      ;;
    --from-tree)
      [[ $# -ge 2 ]] || { echo "error: --from-tree needs a value" >&2; exit 2; }
      FROM_TREE=$2
      shift 2
      ;;
    --to-tree)
      [[ $# -ge 2 ]] || { echo "error: --to-tree needs a value" >&2; exit 2; }
      TO_TREE=$2
      shift 2
      ;;
    --selftest)
      SELFTEST=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --*)
      # An ignored unknown argument is how a flag that was never implemented
      # "passes". Fail closed instead.
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z $RANGE ]] || { echo "error: more than one range given: $RANGE and $1" >&2; exit 2; }
      RANGE=$1
      shift
      ;;
  esac
done

if [[ -n $EXPECT_REMOVED && ! $EXPECT_REMOVED =~ ^[0-9]+$ ]]; then
  echo "error: --expect-removed takes a non-negative integer, got: $EXPECT_REMOVED" >&2
  exit 2
fi
if [[ -n $FROM_TREE && -z $TO_TREE ]] || [[ -z $FROM_TREE && -n $TO_TREE ]]; then
  echo "error: --from-tree and --to-tree must be given together" >&2
  exit 2
fi
if [[ -n $FROM_TREE && -n $RANGE ]]; then
  echo "error: a ref range and --from-tree/--to-tree are mutually exclusive" >&2
  exit 2
fi

# `cc` on a developer machine can be shadowed by a non-compiler wrapper, which
# blows up the Erlang crypto NIF build `mix sobelow`'s compile step needs.
# Respect an explicit CC; otherwise discover a real compiler on PATH rather
# than pinning an absolute path that may not exist on a runner image.
if [[ -z ${CC:-} ]]; then
  for candidate in clang gcc cc; do
    if resolved=$(command -v -- "$candidate" 2>/dev/null); then
      CC=$resolved
      break
    fi
  done
fi
[[ -n ${CC:-} ]] && export CC

# --- scanning ----------------------------------------------------------------

# `mktemp -d` under a TMPDIR with a trailing slash yields a path with a doubled
# separator, which Sobelow canonicalises in its output and the path-stripping
# awk below then fails to match — the twins stop being comparable and EVERY
# finding reads as one removed plus one added. Canonicalise before scanning.
abspath() {
  (cd -- "$1" 2>/dev/null && pwd -P)
}

# Pick the Mix project root inside an exported tree: the repo exports the API
# project at api/, but a fixture tree is its own root.
scan_root_of() {
  local tree=$1
  if [[ -f $tree/api/mix.exs ]]; then
    printf '%s\n' "$tree/api"
  elif [[ -f $tree/mix.exs ]]; then
    printf '%s\n' "$tree"
  else
    return 1
  fi
}

# Empty the fingerprint baseline so ONLY inline annotations act. This is the
# whole point of the twin scan; if it does not take, the run is meaningless.
empty_baseline() {
  local root=$1
  : > "$root/.sobelow-skips"
  if [[ -s $root/.sobelow-skips ]]; then
    echo "error: could not empty the Sobelow baseline at $root/.sobelow-skips" >&2
    return 2
  fi
}

# `--skip` is LOAD-BEARING: Sobelow only pairs an inline annotation with its
# function when :skip is set (sobelow.ex combine_skips). Without it the
# annotations do nothing and the twins are identical by construction.
# `--private` keeps the run off the network.
# shellcheck disable=SC2016  # $SCAN_ROOT is expanded by the `eval` in run_scan, not here.
SCAN_CMD_DEFAULT='mix sobelow --root "$SCAN_ROOT" --skip --private --format compact'

run_scan() { # $1 = scan root, $2 = output file for the NORMALISED finding set
  local root=$1 out=$2 raw status=0
  raw=$(mktemp "${TMPDIR:-/tmp}/sobelow-twin-raw.XXXXXX")
  (
    cd -- "$API_DIR"
    SCAN_ROOT=$root eval "${SOBELOW_TWIN_SCAN_CMD:-$SCAN_CMD_DEFAULT}"
  ) >"$raw" 2>/dev/null || status=$?
  # Sobelow's compact writer prints the scan root as an absolute path with the
  # leading slash eaten; strip whichever form appears so findings are keyed on
  # a tree-relative path:line and the two twins are comparable at all.
  awk -v pfx="${root#/}/" -v pfx2="$root/" '
    { gsub(/\033\[[0-9;]*m/, "") }
    /^\[\+\]/ {
      sub(/^\[\+\] /, "")
      i = index($0, pfx)
      if (i > 0) { $0 = substr($0, 1, i - 1) substr($0, i + length(pfx)) }
      else {
        i = index($0, pfx2)
        if (i > 0) { $0 = substr($0, 1, i - 1) substr($0, i + length(pfx2)) }
      }
      print
    }
  ' "$raw" | LC_ALL=C sort > "$out"
  rm -f -- "$raw"
  return "$status"
}

# --- the load-bearing assertions (the --selftest mutation targets) -----------

assert_no_added_findings() { # $1 = added file
  local added=$1 n
  n=$(grep -c . -- "$added" || true)
  if [[ $n -ne 0 ]]; then
    echo "error: $n finding(s) came BACK in the to-tree — an annotation stopped covering the function it used to cover (D141(c) displacement, or a waiver deleted):" >&2
    sed 's/^/    ADDED   /' "$added" >&2
    return 1
  fi
  echo "  ok  no finding was resurrected (0 added)"
}

assert_expected_removals() { # $1 = removed file, $2 = expected count or ""
  local removed=$1 want=$2 n
  n=$(grep -c . -- "$removed" || true)
  if [[ -z $want ]]; then
    echo "  --  removed count not asserted (no --expect-removed); $n removed"
    return 0
  fi
  if [[ $n -ne $want ]]; then
    echo "error: expected exactly $want removed finding(s), measured $n. An EXTRA removal is the D141(c) transfer signature: a waiver landed on a function nobody reviewed." >&2
    sed 's/^/    REMOVED /' "$removed" >&2
    return 1
  fi
  echo "  ok  removed count is exactly $want, as declared"
}

# --- the twin scan -----------------------------------------------------------

WORKDIR=""
cleanup() {
  if [[ -n $WORKDIR ]]; then
    rm -rf -- "$WORKDIR"
    WORKDIR=""
  fi
}

export_ref() { # $1 = ref, $2 = destination dir; prints nothing
  local ref=$1 dest=$2
  mkdir -p -- "$dest"
  git -C "$API_DIR" archive "$ref" | tar -x -C "$dest"
}

conf_fingerprint() { # $1 = scan root
  if [[ -f $1/.sobelow-conf ]]; then
    cat -- "$1/.sobelow-conf"
  else
    printf 'ABSENT\n'
  fi
}

run_check() {
  local from_tree to_tree from_label to_label

  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-annotation-transfer.XXXXXX")
  trap cleanup EXIT INT TERM

  if [[ -n $FROM_TREE ]]; then
    from_tree=$FROM_TREE
    to_tree=$TO_TREE
    from_label="tree:$FROM_TREE"
    to_label="tree:$TO_TREE"
  else
    local range=${RANGE:-origin/main..HEAD} from_ref to_ref
    if [[ $range != *".."* ]]; then
      echo "error: range must be <from-ref>..<to-ref>, got: $range" >&2
      return 2
    fi
    from_ref=${range%%..*}
    to_ref=${range##*..}
    [[ -n $from_ref && -n $to_ref ]] || { echo "error: both sides of the range are required, got: $range" >&2; return 2; }
    local from_sha to_sha
    from_sha=$(git -C "$API_DIR" rev-parse --verify "$from_ref^{commit}" 2>/dev/null) || {
      echo "error: cannot resolve from-ref: $from_ref" >&2; return 2; }
    to_sha=$(git -C "$API_DIR" rev-parse --verify "$to_ref^{commit}" 2>/dev/null) || {
      echo "error: cannot resolve to-ref: $to_ref" >&2; return 2; }
    from_label="$from_ref ($from_sha)"
    to_label="$to_ref ($to_sha)"
    from_tree="$WORKDIR/from"
    to_tree="$WORKDIR/to"
    export_ref "$from_sha" "$from_tree"
    export_ref "$to_sha" "$to_tree"
  fi

  from_tree=$(abspath "$from_tree") || { echo "error: from-tree does not exist: $from_tree" >&2; return 2; }
  to_tree=$(abspath "$to_tree") || { echo "error: to-tree does not exist: $to_tree" >&2; return 2; }
  [[ -n $from_tree && -n $to_tree ]] || { echo "error: a twin tree path does not exist" >&2; return 2; }

  local from_root to_root
  from_root=$(scan_root_of "$from_tree") || { echo "error: no mix.exs in the from-tree ($from_tree or $from_tree/api)" >&2; return 2; }
  to_root=$(scan_root_of "$to_tree") || { echo "error: no mix.exs in the to-tree ($to_tree or $to_tree/api)" >&2; return 2; }

  if ! diff -q <(conf_fingerprint "$from_root") <(conf_fingerprint "$to_root") >/dev/null; then
    echo "error: .sobelow-conf differs between the twins — the two scans would not be comparable" >&2
    return 2
  fi

  empty_baseline "$from_root" || return 2
  empty_baseline "$to_root" || return 2

  echo "twin scan (empty .sobelow-skips in BOTH trees; only inline annotations act)"
  echo "  from: $from_label"
  echo "  to:   $to_label"

  local from_set="$WORKDIR/from.findings" to_set="$WORKDIR/to.findings"
  run_scan "$from_root" "$from_set" || true
  run_scan "$to_root" "$to_set" || true

  local n_from n_to
  n_from=$(grep -c . -- "$from_set" || true)
  n_to=$(grep -c . -- "$to_set" || true)
  echo "  from findings: $n_from"
  echo "  to   findings: $n_to"
  if [[ $n_from -eq 0 || $n_to -eq 0 ]]; then
    echo "error: a twin scanned ZERO findings (from=$n_from to=$n_to) — nothing was compared, so this run proves nothing about a transfer" >&2
    return 2
  fi

  local removed="$WORKDIR/removed" added="$WORKDIR/added"
  LC_ALL=C comm -23 "$from_set" "$to_set" > "$removed"
  LC_ALL=C comm -13 "$from_set" "$to_set" > "$added"

  local n_removed n_added
  n_removed=$(grep -c . -- "$removed" || true)
  n_added=$(grep -c . -- "$added" || true)

  echo
  echo "REMOVED ($n_removed) — findings the to-tree's annotations now waive:"
  sed 's/^/  - /' "$removed"
  echo "ADDED ($n_added) — findings that came back:"
  sed 's/^/  + /' "$added"
  echo

  local rc=0
  assert_no_added_findings "$added" || rc=1
  assert_expected_removals "$removed" "$EXPECT_REMOVED" || rc=1

  if [[ $rc -ne 0 ]]; then
    echo "FAIL: twin scan reports $n_removed removed / $n_added added" >&2
    return 1
  fi
  printf 'PASS: twin scan reports %d removed / %d added\n' "$n_removed" "$n_added"
}

# --- selftest ----------------------------------------------------------------
#
# The arms scan REAL fixture trees with the REAL scanner. A faked scanner would
# have to encode D141(c)'s binding rule itself, which is precisely the claim
# under test — the fixture would then assert a shape the system may never emit.
# The fixtures are two-function modules, so each scan is well under a second.

write_fixture() { # $1 = dir, $2 = variant
  local dir=$1 variant=$2
  mkdir -p -- "$dir/lib/fixture"
  cat > "$dir/mix.exs" <<'MIXEOF'
defmodule Fixture.MixProject do
  use Mix.Project
  def project, do: [app: :fixture, version: "0.1.0"]
end
MIXEOF
  case $variant in
    preslot)
      # No annotation yet, but the line the annotation will occupy is already
      # there. `preslot` -> `bound` is therefore a pure WAIVER change with no
      # line shift, which is the shape an annotation-only migration has once
      # every finding in a touched file is waived. Findings: alpha:4, beta:8.
      cat > "$dir/lib/fixture/reader.ex" <<'EXEOF'
defmodule Fixture.Reader do
  # the annotation goes here
  def alpha(path) do
    File.read(path)
  end

  def beta(path) do
    File.read(path)
  end
end
EXEOF
      ;;
    bare)
      # Same module WITHOUT the placeholder line, so every finding below sits
      # one line higher. Only used to pin the documented line-shift limit.
      # Findings: alpha:3, beta:7.
      cat > "$dir/lib/fixture/reader.ex" <<'EXEOF'
defmodule Fixture.Reader do
  def alpha(path) do
    File.read(path)
  end

  def beta(path) do
    File.read(path)
  end
end
EXEOF
      ;;
    bound)
      # The annotation is where its author meant it: immediately above alpha's
      # def, so Sobelow binds it to alpha. Findings: beta:8.
      cat > "$dir/lib/fixture/reader.ex" <<'EXEOF'
defmodule Fixture.Reader do
  # sobelow_skip ["Traversal.FileModule"]
  def alpha(path) do
    File.read(path)
  end

  def beta(path) do
    File.read(path)
  end
end
EXEOF
      ;;
    inbody)
      # D141(c). The SAME annotation, one line lower, INSIDE alpha's body. The
      # file is the same length, so nothing shifts — and yet Sobelow binds the
      # annotation to the NEXT def: beta is silently waived and alpha comes
      # back. Findings: alpha:4. Against `bound` that is 1 removed / 1 added.
      cat > "$dir/lib/fixture/reader.ex" <<'EXEOF'
defmodule Fixture.Reader do
  def alpha(path) do
    # sobelow_skip ["Traversal.FileModule"]
    File.read(path)
  end

  def beta(path) do
    File.read(path)
  end
end
EXEOF
      ;;
    empty)
      # A project with nothing to find: the vacuous-population fail-closed arm.
      printf 'defmodule Fixture.Nothing do\n  def noop, do: :ok\nend\n' > "$dir/lib/fixture/reader.ex"
      ;;
    nomix)
      rm -f -- "$dir/mix.exs"
      ;;
    *)
      echo "write_fixture: unknown variant: $variant" >&2
      return 2
      ;;
  esac
}

run_arm_suite() { # $1 = script under test, $2 = label, $3 = fixture root
  local script=$1 label=$2 root=$3 failures=0

  arm() { # <name> <expected exit> <from variant> <to variant> [extra args...]
    local name=$1 want=$2 fromv=$3 tov=$4
    shift 4
    local slug dir
    slug=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '-')
    dir="$root/$slug"
    rm -rf -- "$dir"
    mkdir -p -- "$dir/from" "$dir/to"
    write_fixture "$dir/from" "$fromv"
    write_fixture "$dir/to" "$tov"
    local got=0 out
    out=$(bash "$script" --from-tree "$dir/from" --to-tree "$dir/to" "$@" 2>&1) || got=$?
    if [[ $got -ne $want ]]; then
      printf '  FAIL  %-44s expected exit %d, got %d\n%s\n' "$name" "$want" "$got" "$out" >&2
      failures=1
      return 0
    fi
    printf '  ok    %-44s exit %d\n' "$name" "$got"
  }

  echo "arms against $label:"
  arm "identical trees" 0 bound bound
  arm "honest migration, 1 waived" 0 preslot bound --expect-removed 1
  arm "IN-BODY annotation transfers the waiver" 1 bound inbody
  arm "removed count misses the declaration" 1 preslot bound --expect-removed 2
  arm "to-tree has no mix.exs" 2 bound nomix
  arm "a twin scans ZERO findings" 2 bound empty
  # Pinned in the direction the check can actually see: a pure line shift is
  # NOT distinguishable from a transfer here, and the check says so loudly
  # rather than quietly guessing.
  arm "LIMIT: a pure line shift reads as a pair" 1 bare preslot
  unset -f arm
  return "$failures"
}

# Replace a shell function's body with `return 0`, i.e. delete the assertion.
mutate_out_function() {
  local fn=$1 src=$2 dst=$3
  awk -v fn="$fn" '
    !skip && $0 == fn"() { # $1 = added file" { print fn"() { return 0; }"; skip = 1; next }
    !skip && $0 == fn"() { # $1 = removed file, $2 = expected count or \"\"" { print fn"() { return 0; }"; skip = 1; next }
    skip && $0 == "}" { skip = 0; next }
    !skip { print }
  ' "$src" > "$dst"
  if cmp -s -- "$src" "$dst"; then
    echo "error: mutation '$fn' was a no-op — the selftest would prove nothing" >&2
    return 2
  fi
}

run_selftest() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-transfer-selftest.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  local self="${BASH_SOURCE[0]}" failures=0

  mkdir -p "$tmp/real"
  run_arm_suite "$self" "the check as written" "$tmp/real" || failures=1

  # Mutation 1: delete the added-findings assertion. The IN-BODY arm is the one
  # that reds ONLY through it (it declares no --expect-removed), so the arms
  # must stop being able to fail.
  local m1="$tmp/mutant-no-added-assertion.sh"
  mutate_out_function assert_no_added_findings "$self" "$m1" || return 2
  mkdir -p "$tmp/m1"
  echo
  if run_arm_suite "$m1" "MUTANT: added-findings assertion deleted" "$tmp/m1" 2>/dev/null; then
    echo "SELFTEST FAIL: mutant with no added-findings assertion still passed every arm" >&2
    failures=1
  else
    echo "  ok    mutation caught: deleting the added-findings assertion reds the arms"
  fi

  # Mutation 2: delete the expected-removals assertion. The declaration-mismatch
  # arm must stop being able to fail.
  local m2="$tmp/mutant-no-removed-assertion.sh"
  mutate_out_function assert_expected_removals "$self" "$m2" || return 2
  mkdir -p "$tmp/m2"
  echo
  if run_arm_suite "$m2" "MUTANT: expected-removals assertion deleted" "$tmp/m2" 2>/dev/null; then
    echo "SELFTEST FAIL: mutant with no expected-removals assertion still passed every arm" >&2
    failures=1
  else
    echo "  ok    mutation caught: deleting the expected-removals assertion reds the arms"
  fi

  echo
  if [[ $failures -ne 0 ]]; then
    echo "SELFTEST FAILED" >&2
    return 1
  fi
  echo "SELFTEST PASS: the twin scan greens on identical trees and on an honest migration,"
  echo "               REDS on an in-body annotation that transfers its waiver to the next def,"
  echo "               REDS when the removed count misses its declaration, fails CLOSED on a tree"
  echo "               with no mix.exs and on a twin that scanned zero findings — and each of the"
  echo "               two assertions is proven load-bearing by deleting it."
}

if [[ $SELFTEST -eq 1 ]]; then
  run_selftest
  exit $?
fi

run_check
