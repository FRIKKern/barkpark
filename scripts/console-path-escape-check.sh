#!/usr/bin/env bash
#
# console-path-escape-check.sh — the console skip-shim's path ratchet AND the
# single source of truth for the path set console-harness.yml dispatches on.
#
# WHY THIS EXISTS (Cloud Console Hardening wave 9, M1)
# ---------------------------------------------------
# console-harness.yml used to carry workflow-level `on: … paths:` keys. Measured
# on live GitHub (honest-gates D18): a paths-filtered workflow emits NO check run
# at all, so a required context pointing at it sits "is expected." forever and
# the PR is BLOCKED with no red to fix. PR #7805's docs-only head f1c33790
# rendered 13 check runs and not one console-harness name. So the workflow now
# runs on every head and makes its path decision at JOB level, behind an
# always-running dispatcher — exactly the shape elixir.yml carries.
#
# That is only honest while the declared path set is a SUPERSET of everything
# the console harness actually reads. It reads well outside cloud/priv/static:
# the seal-predicate tests pass `--repo <the real repo root>`, so the predicate
# readFileSync's .github/workflows/cloud.yml, SPAWNS design/emit-fence.test.mjs,
# and existsSync's five cloud/test/barkpark_cloud/web/*_test.exs files. Measured:
# deleting cloud.yml's `paths:` key reds 7 of 31 harness tests, moving
# emit-fence.test.mjs reds 1 of 31, moving one measured_by file reds 6 of 31 —
# and NONE of those three families was declared in the old filters.
#
# So: this script re-derives the read census from the working tree on every run
# and FAILS when a resolved repo-root read is not covered by the declared set
# below. Adding a new cross-tree read without widening the dispatcher is a red,
# not a silent hole.
#
# HOW A READ IS RESOLVED
# ----------------------
# Two families, because the console harness reads in two idioms:
#
#   1. `path.join(REPO_ROOT, "…")` — the literal idiom
#      (cloud/priv/static/__app.test.mjs:5369-5370 reads the two Go goldens).
#
#   2. THE DATA TABLE. seal-predicate.mjs never writes its reads as literals at
#      the read site: it interpolates them out of KNOWN_DEFECTS rows
#      (`${REPO}/${d.guard}`, `${REPO}/${p}` over measured_by,
#      `${REPO}/${d.measured_in_ci.workflow}`). A scanner that only looked at
#      read sites would see a template and report the tree clean — the exact
#      blind pass this ratchet exists to prevent. So the census WALKS THE TABLE
#      and treats `guard:`, `workflow:` and every `measured_by:` entry as a read.
#
# Anything landing inside cloud/priv/static is the harness's own tree, not an
# escape. Anything outside it AND existing on disk is a repo-root read the
# dispatcher must cover.
#
# The existence filter is what keeps the mutation fixtures out of the census
# (seal-predicate.test.mjs carries a deliberately-nonexistent
# `…_test_DELETED.exs` entry): they are asserted on, never read.
#
# NOT `git ls-files` (charter D31): a prototype that enumerated via git reported
# "OK: every repo-root read is covered" and exited 0 with the mutation fixture
# sitting on disk UNTRACKED — a textbook vacuous pass of exactly the class this
# epic exists to remove. The harness carries an untracked case.
#
# USAGE
#   console-path-escape-check.sh                 # the ratchet (CI + the gate)
#   console-path-escape-check.sh --selftest      # run the harness
#   console-path-escape-check.sh --list-escapes  # print the resolved census
#   console-path-escape-check.sh --print-set console
#   console-path-escape-check.sh --match console      # changed paths on stdin
#                                                     # -> prints true|false
#
# `--print-set` / `--match` are consumed by the console-harness.yml dispatcher,
# so the workflow and this ratchet can never disagree about what the path set is.

set -euo pipefail

# ---------------------------------------------------------------------------
# THE DECLARED PATH SET (ONE set — the console has no compile/test split)
# ---------------------------------------------------------------------------
# Glob grammar, deliberately tiny: `dir/**` = that directory and everything
# under it; anything else = one exact file path. No other wildcards.
#
# Every entry is a MEASURED read (see --list-escapes for the census), except the
# last three, which are the shim's own files: a change to the workflow or to
# this ratchet must always run the jobs it gates.
#
# NOTE the two internal/ entries are EXACT FILES, never internal/*/testdata/**:
# those directories carry hundreds of unrelated pdrender/taskboard goldens, and
# the console harness reads exactly two of them
# (cloud/priv/static/__app.test.mjs:5369-5370). Over-inclusion costs the shim
# precisely what it exists to save; the ratchet below is what makes the narrow
# declaration safe — a new read reds instead of skipping.
#
# `.github/required-checks.json` is declared AHEAD of the read that needs it, and
# that is deliberate. The sibling slice `cch-w9-cloud-gate-shim-rung2` makes the
# seal predicate's rung-2 leg A read `${REPO}/.github/required-checks.json`; the
# console harness runs the predicate's tests, so an edit to that file changes
# what those tests conclude. Neither slice's own tree shows the pair — this half
# declares a path it does not yet read, the other half writes a read it does not
# dispatch on — which is exactly how the two would have merged into a live hole
# with both ratchets reporting OK. Declaring it here is also what keeps main
# GREEN whichever of the two lands first.
CONSOLE_PATHS='cloud/priv/static/**
internal/taskboard/testdata/styleguide_lifecycle.txt
internal/pdrender/testdata/styleguide_tokens.txt
.github/workflows/cloud.yml
design/emit-fence.test.mjs
cloud/test/barkpark_cloud/web/**
.github/required-checks.json
.github/workflows/console-harness.yml
scripts/console-path-escape-check.sh
scripts/console-path-escape-check.test.sh'

# EXEMPT — reads that resolve to a real file but are NOT reachable from the
# console harness's default lane. Each line is `<path><TAB><why>`; an entry
# without a reason is a bug. Keep this list at zero-growth: the honest fix for a
# new cross-tree read is to declare it above, not to exempt it.
CONSOLE_ESCAPE_EXEMPT=''

# The census floor. The measured population is 9 resolved repo-root reads; a
# floor of 4 is generous. Its job is to catch a NEUTERED SCANNER: a regex that
# silently stopped matching the data table would otherwise report "0 uncovered
# reads" and exit 0 — clean-looking, and completely blind. That is not
# hypothetical here: the whole point of the table walk is that the reads are
# INTERPOLATED, so the scanner is one regex away from seeing nothing.
#
# It is a CONSTANT on purpose. An env-var override would be a one-line CI bypass
# of the only check that can tell "clean" from "blind", and the harness asserts
# that setting CONSOLE_ESCAPE_MIN changes nothing.
CONSOLE_ESCAPE_MIN=4

# The harness's own tree. Reads landing here are not escapes.
CONSOLE_HOME='cloud/priv/static'

# CONSOLE_PATH_ESCAPE_ROOT retargets the scan at a synthetic fixture tree; the
# harness is its only caller. It cannot weaken a real run — pointing it at the
# repo gives the identical verdict.
REPO_ROOT="${CONSOLE_PATH_ESCAPE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

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
# answer `true` for everything, silently running the whole harness on every PR
# (or, on the other polarity of a future caller, skipping it everywhere).
assert_set_name() {
  case "$1" in
    console) ;;
    *)
      echo "console-path-escape-check: unknown path set '$1' (want console)" >&2
      exit 2
      ;;
  esac
}

set_globs() {
  assert_set_name "$1"
  case "$1" in
    console) printf '%s\n' "$CONSOLE_PATHS" ;;
  esac
}

# One alternation ERE for the whole set. Returned as a single string (not a
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
    echo "console-path-escape-check: path set '$1' resolved to an empty pattern" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# the census
# ---------------------------------------------------------------------------
# Prints one resolved repo-root path per line, `<path><TAB><source-file>`.
list_escapes() {
  local f lit resolved lits sources d
  # WORKING TREE enumeration (D31) — `find`, never `git ls-files`. An untracked
  # .mjs on disk is code the harness will run, so it is code this ratchet must
  # see.
  sources="$(cd -- "$REPO_ROOT" && find "$CONSOLE_HOME" -type f \( -name '*.mjs' -o -name '*.js' \) 2>/dev/null | LC_ALL=C sort)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    #  (1) the literal idiom: path.join(REPO_ROOT, "…") / join(REPO, '…')
    #  (2) the DATA TABLE: guard: '…' | workflow: '…' | measured_by entries
    # Both funnel into the same quoted-literal extraction below, so one
    # existence filter and one coverage check cover every idiom.
    lits="$(
      {
        grep -Eoh "(REPO_ROOT|REPO)[[:space:]]*,[[:space:]]*['\"][^'\"]*['\"]" "$REPO_ROOT/$f" || true
        grep -Eoh "(guard|workflow)[[:space:]]*:[[:space:]]*['\"][^'\"]*['\"]" "$REPO_ROOT/$f" || true
        #  (2b) THE TEMPLATE-LITERAL IDIOM: `${REPO}/some/path`. Not a variant of
        #      (1) — that one matches a `join(REPO, "…")` CALL, and this one is a
        #      backtick string with no comma and no quotes anywhere near it, so
        #      the (1) grep cannot see it. seal-predicate.mjs reads
        #      `${REPO}/.github/required-checks.json` in exactly this shape (its
        #      rung-2 leg A), and the two are written by DIFFERENT slices, which
        #      is precisely how a census goes quietly blind: each half looks
        #      complete on its own branch. The static prefix is emitted bare —
        #      the quoted-literal sed below leaves a line it cannot match alone.
        grep -Eoh '\$\{(REPO_ROOT|REPO)\}/[^`'"'"'"[:space:],)]*' "$REPO_ROOT/$f" \
          | sed -E 's/^\$\{(REPO_ROOT|REPO)\}\///' || true
        #  (3) the walk-up idiom: any `"../…"` literal, resolved against the
        #      reading file's own directory. Nothing in the tree uses it today
        #      (the two idioms above are how the harness is written), but it is
        #      the obvious next way to reach out of cloud/priv/static, and a
        #      census that only saw yesterday's idioms is one refactor from
        #      blind.
        grep -Eoh "['\"]\.\./[^'\"]*['\"]" "$REPO_ROOT/$f" || true
        # measured_by: [ … ] — an ARRAY, frequently spanning several lines.
        # Walked with a tiny state machine so a row whose entries are wrapped
        # (seal-predicate.mjs:173-176) is not silently half-read.
        awk '
          /measured_by[[:space:]]*:/ { inarr = 1 }
          inarr { print }
          inarr && /]/ { inarr = 0 }
        ' "$REPO_ROOT/$f" | grep -Eoh "['\"][^'\"]*['\"]" || true
      } | sed -E "s/.*['\"]([^'\"]*)['\"][[:space:]]*\$/\1/"
    )"
    [ -n "$lits" ] || continue
    while IFS= read -r lit; do
      # `"…/#{x}"`-style splices and wildcards: keep the static prefix only.
      lit="${lit%%\$\{*}"
      case "$lit" in
        *'*'*)
          lit="${lit%%\**}"
          lit="${lit%/}"
          ;;
      esac
      [ -n "$lit" ] || continue
      # repo-relative only: an absolute path or a bare word is not a repo read.
      case "$lit" in
        /* | *' '*) continue ;;
        */*) ;;
        *) continue ;;
      esac
      # A walk-up literal is relative to the file that carries it; a bare
      # repo-relative literal (the data table's idiom) is already anchored.
      case "$lit" in
        ../* | ./*)
          d="$(dirname -- "$f")"
          resolved="$(norm_path "$d/$lit")"
          ;;
        *) resolved="$(norm_path "$lit")" ;;
      esac
      [ -n "$resolved" ] || continue
      # inside the harness's own tree is not an escape
      case "$resolved" in "$CONSOLE_HOME" | "$CONSOLE_HOME"/*) continue ;; esac
      # Only reads that can actually happen: a literal resolving to nothing on
      # disk is a mutation fixture, not a dependency.
      [ -e "$REPO_ROOT/$resolved" ] || continue
      printf '%s\t%s\n' "$resolved" "${f#./}"
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
  done <<<"$CONSOLE_ESCAPE_EXEMPT"
  return 1
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

mode="${1:---check}"

case "$mode" in
  --print-set)
    assert_set_name "${2:?--print-set needs console}"
    set_globs "$2"
    exit 0
    ;;

  --match)
    # changed paths on stdin -> `true` if ANY of them is in the named set.
    # This is what console-harness.yml dispatches on, so the workflow and the
    # ratchet can never disagree about what the path set contains.
    want="${2:?--match needs console}"
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
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/console-path-escape-check.test.sh"
    ;;

  --check) ;;

  *)
    echo "console-path-escape-check: unknown argument '$mode'" >&2
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

echo "console-path-escape-check: scanning \$REPO_ROOT=$REPO_ROOT"
echo "console-path-escape-check: $count distinct repo-root read(s) resolved from $CONSOLE_HOME"

# FAIL-CLOSED on a neutered scanner. "Nothing found" is never good news here.
if [ "$count" -lt "$CONSOLE_ESCAPE_MIN" ]; then
  echo "::error::console-path-escape-check: only $count repo-root read(s) found, floor is $CONSOLE_ESCAPE_MIN." >&2
  echo "  The SCANNER is broken, not the repo clean — the measured population is 9." >&2
  echo "  Check the grep/awk in list_escapes before touching the floor." >&2
  exit 1
fi

console_ere="$(set_ere console)"
uncovered=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$p" | grep -Eq -- "$console_ere"; then
    continue
  fi
  if is_exempt "$p"; then
    echo "  exempt: $p"
    continue
  fi
  uncovered=$((uncovered + 1))
  echo "::error::console-path-escape-check: UNCOVERED repo-root read: $p" >&2
  printf '%s\n' "$census" | awk -F'\t' -v p="$p" '$1 == p { print "    read from: " $2 }' | sort -u >&2
done <<<"$paths"

if [ "$uncovered" -gt 0 ]; then
  cat >&2 <<'MSG'

The console harness reads path(s) that console-harness.yml's dispatcher does
NOT dispatch on. A PR touching one of them would SKIP the harness and report a
green Console gate.

Fix: add the path to CONSOLE_PATHS at the top of this script —
console-harness.yml reads its set from here, so declaring it once is enough.
Exempt it only if the reading code is unreachable from the harness's default
lane, and say so in the exemption's reason.
MSG
  exit 1
fi

echo "OK: every repo-root read from $CONSOLE_HOME is dispatched on."
