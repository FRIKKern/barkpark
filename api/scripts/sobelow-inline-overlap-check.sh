#!/usr/bin/env bash
#
# Ratchet: api/.sobelow-skips must never carry a finding that an inline
# `# sobelow_skip [...]` / `@sobelow_skip [...]` annotation already waives.
#
# WHY. A fingerprint baseline and an inline annotation are two different kinds
# of promise. The annotation says "this call site is reviewed and safe"; the
# baseline says "this exact finding existed when we drew the line". Sobelow
# binds an annotation to a function by AST ADJACENCY (sobelow.ex:418-434) —
# move the function, split the module, insert a `defp` between the comment and
# its `def`, and the binding silently breaks and the finding comes back. That
# is the moment the gate is supposed to speak. If the baseline ALSO carries the
# same finding, it swallows it and nobody ever hears. The overlap is not a
# duplicate; it is an unfalsifiable waiver.
#
# The overlap only appears when the baseline is generated WITHOUT `--skip` —
# see api/scripts/sobelow-baseline-reconcile.sh. This script is the tripwire
# that keeps that regression from being re-committed.
#
# EXIT CODES
#   0  no overlap, and both populations were non-empty
#   1  overlap found (listed on stdout)
#   2  fail-closed: usage error, or one of the two populations scanned ZERO
#      rows. A checker that finds nothing to compare has not passed — it has
#      failed to run, and saying "PASS" there is the vacuous pass this epic
#      exists to remove.
#
# SCOPE / KNOWN LIMIT. An annotation counts here only if Sobelow itself would
# honour it: the comment form is matched with parse.ex:61's regex verbatim, so
# a near-miss like `# sobelow_skip["X"]` (no space before the bracket) is NOT
# an annotation and the baseline entry covering it stays load-bearing.
# Coverage is computed from source text, not from
# Sobelow's own AST: an annotation covers from its own line to the line before
# the next `def`/`defp` at or after it. Nested `def`s inside a covered function
# therefore END the span early, which makes this ratchet CONSERVATIVE — it can
# miss an overlap, it cannot invent one. Findings in `.heex`/`.eex` templates
# have no annotation form and are never reported.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: sobelow-inline-overlap-check.sh [--baseline FILE] [--lib DIR] [--selftest]

  --baseline FILE  baseline to check (default: api/.sobelow-skips)
  --lib DIR        source tree to scan for inline annotations (default: api/lib)
  --selftest       run the mutation fixtures that prove this checker can fail,
                   then exit; does not touch the tracked tree
USAGE
}

API_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BASELINE="$API_DIR/.sobelow-skips"
LIB_DIR="$API_DIR/lib"
SELFTEST=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --baseline)
      [[ $# -ge 2 ]] || { echo "error: --baseline needs a value" >&2; exit 2; }
      BASELINE=$2
      shift 2
      ;;
    --lib)
      [[ $# -ge 2 ]] || { echo "error: --lib needs a value" >&2; exit 2; }
      LIB_DIR=$2
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
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Emit one row per (file, waived type, covered line span) for every inline
# annotation under $LIB_DIR. Paths are printed relative to the PARENT of
# $LIB_DIR so they match the baseline's `lib/...` keys.
scan_annotations() {
  local lib_dir=${1%/} prefix
  # Derive the baseline-shaped prefix from the directory NAME, never from an
  # absolute path: `cd .. && pwd` resolves symlinks (macOS /var -> /private/var)
  # and the strip then silently no-ops, leaving absolute keys that match no
  # baseline entry — a vacuous pass. Caught by the --selftest fixtures.
  prefix=$(basename -- "$lib_dir")
  find "$lib_dir" -type f \( -name '*.ex' -o -name '*.exs' \) -print0 |
    LC_ALL=C sort -z |
    while IFS= read -r -d '' file; do
      awk -v rel="$prefix/${file#"$lib_dir"/}" '
        { line[NR] = $0 }
        END {
          ndef = 0
          for (i = 1; i <= NR; i++)
            if (line[i] ~ /^[[:space:]]*defp?[[:space:](]/) defline[++ndef] = i

          # The comment form must match Sobelow parse.ex:61 EXACTLY —
          #   ~r/#\s?sobelow_skip (\[(\"[^"]+\"(,|, )?)+\])/
          # — because that regex is what rewrites `# sobelow_skip [...]` into
          # the `@sobelow_skip` attribute Sobelow actually reads. A LOOSER
          # regex here fails in the UNSAFE direction: it sees an annotation
          # Sobelow silently ignores (e.g. `# sobelow_skip["X"]`, no space
          # before the bracket), calls the baseline entry a duplicate, and
          # orders the deletion of a load-bearing waiver. Note `#\s?` really
          # does allow `#sobelow_skip`, and the match is NOT anchored to the
          # start of the line, so both are honoured here too.
          skip_comment = "#[[:space:]]?sobelow_skip \\[(\"[^\"]+\"(, ?)?)+\\]"
          for (i = 1; i <= NR; i++) {
            s = line[i]
            is_comment = (match(s, skip_comment) > 0)
            mstart = RSTART; mlen = RLENGTH
            if (!is_comment && s !~ /^[[:space:]]*@sobelow_skip[[:space:]]*\[/) continue

            # The annotation binds to the next def; its span ends where the
            # following def begins (or at end of file).
            span_end = 0
            for (k = 1; k <= ndef; k++) {
              if (defline[k] <= i) continue
              span_end = (k < ndef) ? defline[k + 1] - 1 : NR
              break
            }
            if (span_end == 0) continue   # dangling annotation, binds to nothing

            # Read the waived types out of the matched bracket only, so text
            # after a valid annotation cannot smuggle in extra types.
            rest = is_comment ? substr(s, mstart, mlen) : s
            while (match(rest, /"[^"]+"/)) {
              printf "%s\t%s\t%d\t%d\n", rel,
                     substr(rest, RSTART + 1, RLENGTH - 2), i, span_end
              rest = substr(rest, RSTART + RLENGTH)
            }
          }
        }
      ' "$file"
    done
}

run_check() {
  if [[ ! -f $BASELINE ]]; then
    echo "error: baseline not found: $BASELINE" >&2
    return 2
  fi
  if [[ ! -d $LIB_DIR ]]; then
    echo "error: source tree not found: $LIB_DIR" >&2
    return 2
  fi

  local annotations
  annotations=$(mktemp "${TMPDIR:-/tmp}/sobelow-annotations.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f -- '$annotations'" RETURN
  scan_annotations "$LIB_DIR" > "$annotations"

  local status=0
  awk -F'\t' -v baseline="$BASELINE" '
    # Pass 1: the annotation index, keyed (file, type).
    {
      key = $1 SUBSEP $2
      n = ++count[key]
      lo[key, n] = $3
      hi[key, n] = $4
      annotations++
      next
    }
    END {
      entries = 0
      overlaps = 0
      while ((getline row < baseline) > 0) {
        if (row ~ /^[[:space:]]*$/) continue
        entries++

        # `TYPE: human description,relative/path.ex:LINE,FINGERPRINT`
        # The description may contain commas, so anchor on the tail.
        if (match(row, /,[^,]+:[0-9]+,[0-9A-Fa-f]+[[:space:]]*$/) == 0) continue
        tail = substr(row, RSTART + 1)
        sub(/,[0-9A-Fa-f]+[[:space:]]*$/, "", tail)
        split(tail, loc, ":")
        file = loc[1]
        lineno = loc[2] + 0

        colon = index(row, ":")
        if (colon == 0) continue
        type = substr(row, 1, colon - 1)

        key = file SUBSEP type
        for (n = 1; n <= count[key]; n++) {
          if (lineno < lo[key, n] || lineno > hi[key, n]) continue
          overlaps++
          printf "OVERLAP %s:%d %s — waived inline at %s:%d (annotation covers %d-%d)\n",
                 file, lineno, type, file, lo[key, n], lo[key, n], hi[key, n]
          break
        }
      }
      close(baseline)

      if (annotations == 0) {
        print "error: scanned ZERO inline sobelow annotations — refusing to report a pass" > "/dev/stderr"
        exit 2
      }
      if (entries == 0) {
        print "error: scanned ZERO baseline entries — refusing to report a pass" > "/dev/stderr"
        exit 2
      }

      printf "scanned %d baseline entries against %d inline annotation coverings\n",
             entries, annotations
      if (overlaps > 0) {
        printf "FAIL: %d baseline entries duplicate an inline waiver.\n", overlaps > "/dev/stderr"
        print  "      Regenerate with api/scripts/sobelow-baseline-reconcile.sh (which runs" > "/dev/stderr"
        print  "      `mix sobelow --skip --mark-skip-all`), or drop these lines by hand." > "/dev/stderr"
        exit 1
      }
      print "PASS: no baseline entry duplicates an inline sobelow waiver"
    }
  ' "$annotations" || status=$?
  return "$status"
}

# --- selftest: prove the checker can fail, in both directions ----------------

selftest_fixture() {
  local dir=$1
  mkdir -p "$dir/lib/barkpark"
  cat > "$dir/lib/barkpark/fixture.ex" <<'FIXTURE'
defmodule Barkpark.Fixture do
  def untouched(path) do
    File.read!(path)
  end

  # sobelow_skip ["Traversal.FileModule"]
  def waived(path) do
    File.read!(path)
  end
end
FIXTURE

  # A MALFORMED annotation: no space before the bracket. Sobelow's rewrite
  # regex (parse.ex:61) requires that space, so Sobelow ignores this line
  # entirely and the finding is NOT waived inline — which makes the baseline
  # entry covering it load-bearing. A checker that accepts this shape
  # manufactures an OVERLAP and orders that entry deleted.
  cat > "$dir/lib/barkpark/malformed.ex" <<'MALFORMED'
defmodule Barkpark.Malformed do
  # sobelow_skip["Traversal.FileModule"]
  def not_waived_at_all(path) do
    File.read!(path)
  end
end
MALFORMED
}

expect_status() {
  local label=$1 want=$2
  shift 2
  local got=0 out
  out=$("$@" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    return 1
  fi
  printf '  ok  %-34s exit %d\n' "$label" "$got"
}

run_selftest() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-overlap-selftest.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  selftest_fixture "$tmp"

  # The waived `File.read!` sits at line 8, inside the annotation's span.
  local overlapping="$tmp/overlapping" clean="$tmp/clean" empty="$tmp/empty"
  printf '%s\n' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/fixture.ex:3,AAAAAA' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/fixture.ex:8,BBBBBB' \
    > "$overlapping"
  printf '%s\n' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/fixture.ex:3,AAAAAA' \
    > "$clean"
  : > "$empty"

  # The malformed annotation sits at malformed.ex:2 and its `File.read!` at
  # line 4. Sobelow ignores the annotation, so this entry is load-bearing and
  # must NOT be reported as an overlap. Under the pre-parse.ex:61 regex this
  # fixture exits 1 and orders a live waiver deleted.
  local malformed="$tmp/malformed"
  printf '%s\n' \
    'Traversal.FileModule: Directory Traversal in `File.read!`,lib/barkpark/malformed.ex:4,CCCCCC' \
    > "$malformed"

  echo "selftest: mutation fixtures"
  local failures=0
  expect_status "baseline carries a waived finding" 1 \
    "${BASH_SOURCE[0]}" --baseline "$overlapping" --lib "$tmp/lib" || failures=1
  expect_status "same baseline minus that line" 0 \
    "${BASH_SOURCE[0]}" --baseline "$clean" --lib "$tmp/lib" || failures=1
  expect_status "malformed annotation is NOT an overlap" 0 \
    "${BASH_SOURCE[0]}" --baseline "$malformed" --lib "$tmp/lib" || failures=1
  expect_status "zero baseline entries fails closed" 2 \
    "${BASH_SOURCE[0]}" --baseline "$empty" --lib "$tmp/lib" || failures=1

  # Same baseline, annotation deleted: zero annotations must fail closed, NOT
  # pass — a checker whose second population is empty proves nothing.
  local bare="$tmp/bare"
  mkdir -p "$bare/lib/barkpark"
  grep -v 'sobelow_skip' "$tmp/lib/barkpark/fixture.ex" > "$bare/lib/barkpark/fixture.ex"
  expect_status "zero annotations fails closed" 2 \
    "${BASH_SOURCE[0]}" --baseline "$clean" --lib "$bare/lib" || failures=1

  if [[ $failures -ne 0 ]]; then
    echo "SELFTEST FAILED" >&2
    return 1
  fi
  echo "SELFTEST PASS: the ratchet reds on overlap, greens without it, and fails closed on either empty population"
}

if [[ $SELFTEST -eq 1 ]]; then
  run_selftest
  exit $?
fi

run_check
