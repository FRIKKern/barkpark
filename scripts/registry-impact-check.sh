#!/usr/bin/env bash
#
# registry-impact-check.sh — WHICH REGISTRIES COUNT THE FILES THIS DIFF TOUCHES?
#
# THE CLASS
# ---------
# A FENCE AROUND A FILE DOES NOT COVER THE REGISTRIES THAT COUNT THINGS IN IT.
# An author reasons carefully about the file being edited. A census, ratchet or
# pin that COUNTS things in that file is simply not the kind of object a scope
# paragraph is written to think about, so the change lands, main goes red AFTER
# the merge, and the author had no way to see it coming.
#
# Measured, and the reason this file exists — both are replayed by the harness:
#
#   1. #18213 (7d56df653) thawed a region inside scripts/pds-pull-proof.sh. That
#      file is a ROW in .github/run-level-readers.allow, pinned at a reference
#      COUNT. The count moved, the row did not, main reddened, and #18258
#      (90d63a4dd) was a one-line follow-up editing only the allow file.
#   2. #18191 (5ca440b3d) taught three deploy engines to read their own published
#      check count back out of deploy/README.md. Branch deploy/assets-survive-gap
#      adds 147 lines of checks to deploy/instance-deploy_test.sh; it DOES touch
#      deploy/README.md, but only to add a prose paragraph, never to move the
#      pinned number. It reds on rebase.
#
# The rule has been WRITTEN DOWN repeatedly and still missed its own next case
# twice. A written finding does not fire by itself. This is the script with the
# trigger.
#
# WHAT A REGISTRY IS — THE DERIVATION PREDICATE, STATED ONCE
# ----------------------------------------------------------
# NOT a hard-coded list of the five or six known ones. A list is a SNAPSHOT and
# it rots; a two-item skip list in this repo turned out to really be eight. The
# set is DERIVED from the tree on every run by one rule:
#
#   A REGISTRY IS A FILE THAT HOLDS AN EXPECTED VALUE IT DID NOT COMPUTE IN THIS
#   RUN AND COMPARES A MEASUREMENT AGAINST IT, **OR** THAT WALKS A FILE-TYPE
#   GLOB AND DEMANDS EVERY MEMBER BE ACCOUNTED FOR.
#
# The second clause is not decoration. It was added because the first clause
# alone, measured against the six known registries, MISSED the two that govern
# brand-new scripts/ files — selftest-wiring-census.sh and pds-door-census.sh —
# whose expectation is a row or a wiring per member and is therefore held by the
# CORPUS, never by the registry. Those are exactly the new-file class.
#
# Three doors satisfy it, and a file needs only one:
#
#   B1 IN-FILE PIN       an upper-case identifier whose name carries EXPECTED /
#                        FLOOR / PIN / PINNED / BASELINE / ROWS / _MAX / _MIN,
#                        assigned a bare integer literal. The literal is the
#                        recorded expectation. (Elixir module attributes too.)
#   B2 COMMITTED ARTIFACT  the file names a TRACKED path ending .allow / .pin /
#                        .allowlist / .baseline / .tsv / -registry.json, or names
#                        a tracked README.md on a line that also carries a count
#                        word. That artifact is the recorded expectation.
#   B3 TOTALITY          it hands a file-type glob to a corpus-scan verb. There
#                        is no number to read; the expectation is "every member
#                        is accounted for", distributed across the corpus as a
#                        row, a wiring or an exemption marker per file.
#
# KNOWN MISS, stated here rather than discovered later: a RIDER that pins facts
# about a census it execs — api/test/barkpark/pds_door_census_test.exs — matches
# no door, because it holds neither an expectation nor a glob of its own. Its
# obligation still surfaces, via the census it rides (scripts/pds-door-census.sh),
# so the miss costs a name in the output and not a missed red.
#
# Everything else this script does is CORPUS RESOLUTION: given a registry, which
# files can move its measurement? Three doors, and the honest limits of each are
# stated in --list-registries output:
#
#   D1 ENUMERATED  the changed path appears VERBATIM in one of the registry's
#                  expectation artifacts. Exact, zero guesswork. Cannot fire for
#                  a NEW file — by construction a new file is in no allowlist
#                  yet, which is precisely the defect class, so D2 carries it.
#   D2 SCANNED     the changed path matches a path glob the registry hands to a
#                  corpus-scan verb (git ls-files / find / git grep / wildcard /
#                  readdir / for..in). This is the NEW-FILE door.
#   D3 SELF        the changed path IS the registry, or IS one of its expectation
#                  artifacts. Covers the self-counting harness (a --self-test
#                  that tallies its own checks against a published number).
#   D4 CONTENT     the registry's corpus is a CONTENT grep, and the changed file's
#                  content MATCHES it — so the edit made the file a MEMBER. The
#                  patterns and the --include extensions are read out of the
#                  registry's own `grep -rl` / `git grep -l` invocation, so this
#                  is a predicate over a SHAPE, never a second list: 15 files
#                  under *.sh/*.mjs/*.exs/*.py carry a list-mode recursive
#                  content grep as this script sees them (comments stripped,
#                  continuations joined).
#
# WHY D4 EXISTS, measured: d3af39283 reddened run-level-reader-census.sh on main
# and stayed red. It touched three paths, and NONE of them is in any registry's
# rows or globs — tooling/concept-map/ci-boundary.test.mjs BECAME a member by
# gaining run-level reads (0 source hits at d3af39283^, 2 at d3af39283). D1/D2/D3
# are all path-keyed and every one of them stayed silent. Membership here is
# decided by what a file CONTAINS after the edit, not by where it sits.
#
# Hence --at: a membership question must be asked of the tree the change produced.
# A historical replay that asks it of the current working tree gets the wrong
# answer in both directions, and the harness proves both — the SAME path set is
# CLEAN at d3af39283^ and IMPLICATED at d3af39283, with only that flag moving.
#
# --at PINS THE WHOLE EVALUATION, AND IT HAD TO LEARN TO. It first pinned only
# CONTENT, leaving the tracked list, the registry set, each registry's source and
# each EXPECTATION ARTIFACT read from the working tree. That split is a replay
# asking one question of two trees, and it went undetected until main adjudicated
# tooling/concept-map/ci-boundary.test.mjs into .github/run-level-readers.allow:
# D1 read the artifact from the present, saw the row, and claimed the hit as
# D1-ENUMERATED — while the d3af39283^ CONTROL, which D1 ignores entirely because
# D1 is path-keyed, fired too. Subject and control produced BYTE-IDENTICAL output.
# The harness still scored 24/24 on a stale local branch and 20/24 in CI, on the
# same commit, because every arm asserted about the subject and none about the
# RELATIONSHIP between a subject and its control. Every tree read now goes through
# tree_grep_l() or content_of(), so honouring the ref in one place and forgetting
# it in another is not representable.
#
# D4'S DECLARED GAP — the honest half, and it is stated in the CLEAN output too.
# D4 reads patterns ONLY from the `-e '<pat>'` shape. A registry that passes a
# BARE quoted pattern as grep's first operand is NOT covered:
#   scripts/docs-anchors-check.sh — `grep -rl '^## Code anchors' docs --include='*.md'`
# so a doc that GAINS that heading becomes a member and this check stays silent.
# Measured: of those 15 files, exactly 2 pass patterns as `-e` literals
# (scripts/run-level-reader-census.sh and scripts/orchestrate-launch-recipe.test.sh)
# and 13 do not. I implemented the bare-operand door and REMOVED it:
# those invocations are pipelines, so telling grep's pattern from the filter's
# pattern is not soundly doable by extraction, and the two-path negative control
# went from CLEAN to two implicated registries, BOTH FALSE (web/README.md contains
# `^## Code anchors` zero times). Detection bought by making everything implicated
# is worse than a declared gap, so the gap is declared.
#
# WHAT IT DELIBERATELY DOES NOT DO
# --------------------------------
# It NEVER says "declared, you are fine". Touching an expectation artifact is not
# proof of bumping the right value inside it — case 2 above touched
# deploy/README.md and reddened anyway. A touch is reported as an annotation
# beside the obligation, never as a discharge of it. A checker that can clear its
# own finding on a file-path match would have passed case 2.
#
# ADVISORY AND READ-ONLY. It writes nothing, re-seeds nothing, mutates nothing.
#
# EXIT CODES — three states, three codes
#   0  nothing implicated (and the run proved it actually scanned something)
#   1  at least one registry counts something in these paths
#   2  CANNOT READ — the scan did not happen; no verdict is available
#
# A failed read must never look like a clean one, so exit 2 prints no tally at
# all, only the refusal and its reason.
#
# USAGE
#   registry-impact-check.sh                      # diff against origin/main + working tree
#   registry-impact-check.sh --base <ref>
#   registry-impact-check.sh --path P [--path Q]  # explicit path set
#   registry-impact-check.sh --paths-from <file>  # one path per line, - for stdin
#   registry-impact-check.sh --at <ref>           # pin the WHOLE evaluation to
#                                                 # <ref> (default: working tree).
#                                                 # --content-at is a deprecated
#                                                 # alias from when it pinned only
#                                                 # content, which was the bug.
#   registry-impact-check.sh --list-registries    # the derived set, with misses
#   registry-impact-check.sh --selftest           # harness hook
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

RC_CLEAN=0
RC_IMPLICATED=1
RC_CANNOT_READ=2

ROOT="${REGISTRY_IMPACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"

# A floor on the candidate sweep. Not a cosmetic number: if the tree or the grep
# machinery breaks, the derived set collapses toward zero, every path is
# "implicated by nothing", and this script prints a confident clean. The floor is
# what a broken scan cannot satisfy. Same shape as ALLOW_ROWS_EXPECTED in
# run-level-reader-census.sh and CAPS_ROWS_EXPECTED in check-doc-budgets.sh.
REGISTRY_FLOOR="${REGISTRY_IMPACT_FLOOR:-20}"

cannot_read() {
  echo "registry-impact-check: CANNOT READ — $1" >&2
  echo "registry-impact-check: no verdict. This run measured nothing; do not read silence as a clean result." >&2
  exit "$RC_CANNOT_READ"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/registry-impact.XXXXXX" 2>/dev/null)" || cannot_read "could not create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- argument parse
MODE=run
BASE="${REGISTRY_IMPACT_BASE:-origin/main}"
# Empty = the working tree. A historical replay must set this to the commit under
# test, or the content-membership door asks its question of the wrong tree.
# Empty = the working tree. When set, it pins THE WHOLE EVALUATION to that ref:
# the tracked file list, the derived registry set, every registry's source, every
# expectation artifact, and file content. It used to pin ONLY content, and that
# split is what made the d3af39283 replay stop replaying — see the header.
AT_REF="${REGISTRY_IMPACT_AT_REF:-${REGISTRY_IMPACT_CONTENT_REF:-}}"
: > "$TMP/paths.explicit"
HAVE_EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) shift; [ $# -gt 0 ] || cannot_read "--base needs a ref"; BASE="$1" ;;
    --at|--content-at) shift; [ $# -gt 0 ] || cannot_read "$1 needs a ref"; AT_REF="$1" ;;
    --path) shift; [ $# -gt 0 ] || cannot_read "--path needs a path"; printf '%s\n' "$1" >> "$TMP/paths.explicit"; HAVE_EXPLICIT=1 ;;
    --paths-from)
      shift; [ $# -gt 0 ] || cannot_read "--paths-from needs a file"
      if [ "$1" = "-" ]; then cat >> "$TMP/paths.explicit"
      else [ -f "$1" ] || cannot_read "--paths-from: no such file: $1"; cat "$1" >> "$TMP/paths.explicit"; fi
      HAVE_EXPLICIT=1 ;;
    --list-registries) MODE=list ;;
    --selftest) MODE=selftest ;;
    -h|--help) sed -n '1,90p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) cannot_read "unknown argument: $1" ;;
  esac
  shift
done

[ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ] || cannot_read "no git repository at $ROOT"

if [ "$MODE" = selftest ]; then
  ST="$ROOT/scripts/registry-impact-check.test.sh"
  [ -f "$ST" ] || cannot_read "--selftest: no harness at $ST"
  exec bash "$ST"
fi

# ------------------------------------------------------------------ tracked tree
if [ -n "$AT_REF" ]; then
  git -C "$ROOT" ls-tree -r --name-only "$AT_REF" > "$TMP/tracked" 2>/dev/null \
    || cannot_read "git ls-tree failed for ref '$AT_REF' under $ROOT"
else
  git -C "$ROOT" ls-files > "$TMP/tracked" 2>/dev/null || cannot_read "git ls-files failed under $ROOT"
fi
TRACKED_N=$(wc -l < "$TMP/tracked" | tr -d ' ')
[ "$TRACKED_N" -gt 0 ] 2>/dev/null || cannot_read "git ls-files returned nothing under $ROOT"

# Every directory that really exists in the tracked tree. A glob's directory is
# resolved against THIS, never against the shape of a shell word.
sed -E 's#/[^/]*$##' "$TMP/tracked" | LC_ALL=C sort -u > "$TMP/dirs"
: > "$TMP/too-broad"
: > "$TMP/degenerate"
# The degenerate-pattern control string. Shares no vocabulary with any real
# corpus pattern, so only a pattern matching on STRUCTURE can match it.
printf 'zqxjk-degenerate-pattern-control-7f3\n' > "$TMP/sentinel"

# A corpus glob wider than this share of the tree is a shrug, not an obligation.
BREADTH_MAX=$(( TRACKED_N / 20 ))
[ "$BREADTH_MAX" -gt 0 ] || BREADTH_MAX=1

# CONTROL for the grep machinery. git grep's ERE has no word boundary and has
# silently returned ZERO FILES for a pattern that is everywhere; a -P sweep whose
# control also returns zero is a broken instrument, not an absence. This control
# must hit, or there is no verdict.
# Every corpus grep goes through here so the ref cannot be honoured in one place
# and forgotten in another — which is precisely the bug this function exists to
# make unrepresentable. `git grep -l <ref>` prefixes each path with "<ref>:".
tree_grep_l() {
  local re="$1"; shift
  if [ -n "$AT_REF" ]; then
    git -C "$ROOT" grep -lP "$re" "$AT_REF" -- "$@" 2>/dev/null | sed "s|^${AT_REF}:||"
  else
    git -C "$ROOT" grep -lP "$re" -- "$@" 2>/dev/null
  fi
}

CTRL_N=$(tree_grep_l 'set -uo pipefail' '*.sh' | wc -l | tr -d ' ')
[ "${CTRL_N:-0}" -gt 5 ] 2>/dev/null || cannot_read "grep control failed: a -P sweep for 'set -uo pipefail' over *.sh matched ${CTRL_N:-0} files. The scan machinery is not working, so an empty result would be meaningless."

# ------------------------------------------------------- PHASE 1: derive the set
# B1 — an in-file pinned integer expectation.
B1_RE='^[[:space:]]*(readonly[[:space:]]+|export[[:space:]]+|@|const[[:space:]]+|local[[:space:]]+)?[A-Za-z_@][A-Za-z0-9_]*(EXPECTED|Expected|_FLOOR|_floor|_PIN|_pin|PINNED|BASELINE|baseline|_ROWS|_MAX|_MIN|expected)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*"?[0-9]+"?[[:space:]]*$'
# B2 — names a committed expectation artifact.
B2_RE='[A-Za-z0-9_][A-Za-z0-9_./-]*\.(allow|allowlist|pin|baseline|tsv)\b|[A-Za-z0-9_][A-Za-z0-9_./-]*-registry\.json\b'
# B2b — names a tracked README on a line that also carries a count word.
B2B_RE='[A-Za-z0-9_][A-Za-z0-9_./-]*README\.md\b.*\b(count|checks|CHECKS|COUNT|Count)\b|\b(count|checks|COUNT|CHECKS)\b.*[A-Za-z0-9_][A-Za-z0-9_./-]*README\.md\b'
# B3 — THE TOTALITY SHAPE, and the door that carries the whole NEW-FILE class.
# A census like selftest-wiring-census.sh records no number anywhere: it walks a
# file-type glob and demands that every member be accounted for — wired, or
# exempt, or carrying a disposition row. Its expectation is DISTRIBUTED ACROSS
# ITS OWN CORPUS, not held by the registry, so B1 and B2 are both structurally
# blind to it. Measured: B1+B2+B2b alone missed selftest-wiring-census.sh and
# pds-door-census.sh — the two registries that govern brand-new scripts/ files,
# which is precisely the defect class this whole script exists for.
#
# The verb set must match SCAN_VERB_RE below. It did not at first, and the gap
# cost pds-door-census.sh: it enumerates with `for g in 'scripts/pds-*.sh' …`,
# which carries no find/ls-files/grep verb at all.
B3_RE='(git ls-files|\bfind\s|git grep|Path\.wildcard|File\.ls|readdirSync|\bfor\s+\w+\s+in\s)[^\n]*[*][.][a-z]'

SRC_GLOBS=( '*.sh' '*.mjs' '*.js' '*.exs' '*.ex' '*.py' '*.yml' )

{
  tree_grep_l "$B1_RE"  "${SRC_GLOBS[@]}"
  tree_grep_l "$B2_RE"  "${SRC_GLOBS[@]}"
  tree_grep_l "$B2B_RE" "${SRC_GLOBS[@]}"
  tree_grep_l "$B3_RE"  "${SRC_GLOBS[@]}"
} | LC_ALL=C sort -u > "$TMP/registries"

REG_N=$(wc -l < "$TMP/registries" | tr -d ' ')
if [ "${REG_N:-0}" -lt "$REGISTRY_FLOOR" ]; then
  cannot_read "the derivation predicate matched only ${REG_N:-0} files, below the floor of $REGISTRY_FLOOR. A collapsed set makes every path look un-implicated, so this run has no verdict to give. (tracked files seen: $TRACKED_N; grep control: $CTRL_N)"
fi

# -------------------------------------------------- PHASE 2: per-registry corpus
# For registry R this writes two files:
#   $TMP/art/<slug>   tracked expectation artifacts R reads
#   $TMP/glob/<slug>  ERE matchers for path globs R hands to a corpus-scan verb
mkdir -p "$TMP/art" "$TMP/glob" "$TMP/cpat" "$TMP/cinc" "$TMP/cdir" "$TMP/content"
slug_of() { printf '%s' "$1" | tr '/.' '__'; }

# A registry whose corpus is a CONTENT GREP decides membership by what a file
# CONTAINS, not by where it sits. scripts/run-level-reader-census.sh is the
# measured example: its corpus is
#   grep -rl --include='*.sh' --include='*.yml' --include='*.mjs' \
#        -e 'gh run list' -e 'gh run view' -e 'workflow_runs[' -e 'actions/runs' $dirs
# so tooling/concept-map/ci-boundary.test.mjs was NOT a member at d3af39283^ (0
# source hits) and BECAME one at d3af39283 (2 hits), reddening main — while every
# path-keyed door stayed silent, because the file's PATH never entered any list.
# That transition is the new-MEMBER half of the new-file class, and D1/D2/D3 are
# all structurally blind to it.
#
# This is derived from the registry's OWN grep invocation — the patterns it hands
# to -e, the extensions it hands to --include — so it is a predicate over a shape
# (13 files repo-wide use a list-mode recursive content grep, 7 of them registries),
# not a second hard-coded list. No registry is named anywhere in this file.
CONTENT_GREP_RE='(grep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*(rl|lr)[a-zA-Z]*|git[[:space:]]+grep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*l)[[:space:]]'

# The file content a membership question is asked OF. A replay of a historical
# commit MUST resolve content at that commit: the whole point is that the file
# was not a member before it and is one after, and the working tree at this head
# is neither. Falls back to HEAD for a path not on disk.
content_of() {
  local p="$1" cs
  cs="$TMP/content/$(slug_of "$p")"
  if [ ! -e "$cs" ]; then
    if [ -n "$AT_REF" ]; then
      git -C "$ROOT" show "$AT_REF:$p" 2>/dev/null | head -c 2000000 > "$cs" || : > "$cs"
    elif [ -f "$ROOT/$p" ]; then
      head -c 2000000 "$ROOT/$p" > "$cs" 2>/dev/null || : > "$cs"
    else
      git -C "$ROOT" show "HEAD:$p" 2>/dev/null | head -c 2000000 > "$cs" || : > "$cs"
    fi
  fi
  printf '%s' "$cs"
}

SCAN_VERB_RE='git ls-files|\bfind[[:space:]]|git grep|Path\.wildcard|File\.ls|readdir|glob\(|for[[:space:]].*[[:space:]]in[[:space:]].*\*|ls[[:space:]]'

extract_for() {
  local r="$1" slug f line tok norm
  slug="$(slug_of "$r")"
  f="$(content_of "$r")"
  : > "$TMP/art/$slug"; : > "$TMP/glob/$slug"
  [ -s "$f" ] || return 0

  # --- expectation artifacts: path-shaped tokens that EXIST in the tracked tree.
  #
  # NARROW ON PURPOSE. A first cut accepted .md/.json/.txt too and drowned: it
  # offered scripts/elixir-path-escape-check.sh's 48 CENSUS SUBJECTS (every doc
  # the Elixir suite reads) as 48 things to "declare". Those are its corpus, not
  # its expectation. Only suffixes whose whole reason to exist is to RECORD an
  # expectation are taken, plus a README named beside a count word (the
  # deploy/README.md self-test count guard, which has no other spelling).
  {
    grep -oE '\.?[A-Za-z0-9_][A-Za-z0-9_./-]*\.(allow|allowlist|pin|baseline|tsv)' "$f" 2>/dev/null
    grep -oE '\.?[A-Za-z0-9_][A-Za-z0-9_./-]*-registry\.json' "$f" 2>/dev/null
    grep -hE "$B2B_RE" "$f" 2>/dev/null | grep -oE '\.?[A-Za-z0-9_][A-Za-z0-9_./-]*README\.md' 2>/dev/null
  } | LC_ALL=C sort -u \
    | while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        # Resolve the literal against the tracked tree, trying the dotted form
        # too: a token is scraped as `github/run-level-readers.allow` because the
        # leading `.` is not a word character, and the un-dotted form is tracked
        # by nothing. That one missing dot made D1 — the exact door — dead for
        # every .github/ artifact in the repo, and the first run only fired
        # through the fuzzy glob door instead.
        if LC_ALL=C grep -qxF "$tok" "$TMP/tracked"; then
          printf '%s\n' "$tok"
        elif LC_ALL=C grep -qxF ".$tok" "$TMP/tracked"; then
          printf '.%s\n' "$tok"
        fi
      done | LC_ALL=C sort -u > "$TMP/art/$slug"

  # --- corpus globs, taken ONLY from lines carrying a corpus-scan verb.
  grep -nE "$SCAN_VERB_RE" "$f" 2>/dev/null | head -400 | while IFS= read -r line; do
    printf '%s\n' "$line" | grep -oE "[A-Za-z0-9_$\{\}\"'./-]*\*[A-Za-z0-9_./*-]*" 2>/dev/null | while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      # Normalise: drop a leading shell variable segment ("$root/scripts" -> scripts).
      norm="$(printf '%s' "$tok" | sed -E 's/^["'"'"']+//; s/["'"'"']+$//; s/^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\///')"
      case "$norm" in
        *'$'*) continue ;;             # still variable-bearing: unresolvable, drop it
        '*'|'*.'*)
          # A bare extension glob. Scope it to a directory named on the same line,
          # else to the registry's own top-level directory — never repo-wide.
          local dir cand
          # Resolve the directory against DIRECTORIES THAT ACTUALLY EXIST in the
          # tracked tree, never by regex shape. A shape-only reader took
          #   find "$root/scripts" -type f -name '*.test.sh'
          # and produced the glob `root/*.test.sh`, because the leftmost match of
          # a `<dir>/` pattern inside "$root/scripts" is `root/` — the SHELL
          # VARIABLE's name, which is not a directory anywhere. That matched no
          # file, and the new-file door — the only one that can reach a file that
          # does not exist yet — was silently dead. The harness caught it; nothing
          # in the output looked wrong.
          dir=""
          for cand in $(printf '%s\n' "$line" | grep -oE '[A-Za-z_$][A-Za-z0-9_${}/.-]*' | sed -E 's/^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\///; s#/+$##'); do
            case "$cand" in *'$'*|'') continue ;; esac
            if LC_ALL=C grep -qxF "$cand" "$TMP/dirs"; then dir="$cand"; break; fi
          done
          [ -n "$dir" ] || dir="${r%%/*}"
          case "$dir" in ''|*'$'*) continue ;; esac
          printf '%s/%s\n' "$dir" "$norm" ;;
        */*) printf '%s\n' "$norm" ;;
        *) continue ;;
      esac
    done
  done | LC_ALL=C sort -u | while IFS= read -r g; do
    # A corpus census names a FILE TYPE. A bare `dir/*` does not: it is almost
    # always an `ls` or a copy, and admitting it made the first run offer
    # scripts/*  as the corpus of an unrelated .test.mjs, implicating it in every
    # change under scripts/. Requiring an extension component is what separates
    # "this census walks *.test.sh" from "this line happened to list a directory".
    case "$g" in
      *'*'*.[a-z]*) : ;;
      *) continue ;;
    esac
    # BREADTH CAP, derived from the tree rather than declared. A repo-wide glob
    # like `**/*.ex` resolved 1116 of 15304 tracked files and made every Elixir
    # edit "implicated" by a dozen unrelated pin tests — a checker that fires on
    # everything has told the author nothing. The cap is a share of the tracked
    # count, so it moves with the repo instead of rotting: 5% here separates
    # scripts/*.sh (281, a real corpus) from **/*.ex (1116, a shrug.)
    # `gn=$(grep -c … || echo 0)` is WRONG and was the bug that killed the
    # new-file door: grep -c PRINTS "0" and THEN exits 1, so the `|| echo 0`
    # appends a second line and gn becomes "0\n0". `[ "0\n0" -gt N ]` is not
    # false, it is an ERROR returning 2 — which became the while-loop's exit
    # status, which made the `&& mv` below not run, which left the glob file at
    # the empty stub. Every glob for that registry vanished and the output looked
    # exactly like an honest CLEAN.
    gn=$(LC_ALL=C grep -cE "$(glob_to_ere "$g")" "$TMP/tracked" 2>/dev/null) || gn=0
    case "$gn" in ''|*[!0-9]*) gn=0 ;; esac
    if [ "$gn" -gt "$BREADTH_MAX" ]; then
      echo "$g" >> "$TMP/too-broad"
      continue
    fi
    printf '%s\n' "$g"
  done > "$TMP/glob/$slug.tmp"
  # Unconditional. Guarding this on the loop's exit status is what let a single
  # erroring comparison silently discard a whole registry's corpus.
  mv "$TMP/glob/$slug.tmp" "$TMP/glob/$slug"

  # --- D4: the content-keyed corpus, read out of the registry's own grep.
  : > "$TMP/cpat/$slug"; : > "$TMP/cinc/$slug"; : > "$TMP/cdir/$slug"
  # Join backslash continuations FIRST. The measured example spans three physical
  # lines and its -e patterns live on the second: a line-at-a-time reader sees the
  # `grep -rl` and none of what it greps FOR.
  # WHOLE-LINE COMMENTS GO FIRST, then continuations are joined. Order matters and
  # the omission was self-inflicted: the header of THIS FILE quotes the measured
  # registry's grep invocation verbatim as documentation, the joiner glued that
  # comment block into one line, and the extractor read `-e 'gh run list'` out of
  # its own prose — making this script a content-member of everything the census
  # matches, itself included. An instrument must not be able to match its own
  # description of another instrument. This is the same reason the census strips
  # comments before counting: prose about a pattern is not the pattern.
  local joined="$TMP/joined.$slug"
  grep -vE '^[[:space:]]*(#|//)' "$f" 2>/dev/null \
    | sed -e :a -e '/\\$/N; s/\\\n//; ta' > "$joined" || : > "$joined"
  grep -E "$CONTENT_GREP_RE" "$joined" 2>/dev/null | head -40 > "$TMP/cg.$slug" || : > "$TMP/cg.$slug"
  if [ -s "$TMP/cg.$slug" ]; then
    # Patterns: every -e argument. Quoted literals only — an unquoted or
    # variable-bearing pattern is DROPPED rather than guessed, because a guessed
    # pattern manufactures membership nobody owes.
    # ONLY the `-e '<pat>'` shape. This is a DELIBERATE, MEASURED narrowing.
    #
    # Of the 8 files in the tree carrying a list-mode recursive content grep, 2
    # pass patterns as `-e` literals and the rest pass a BARE quoted pattern as
    # grep's first operand — scripts/docs-anchors-check.sh keys a real corpus on
    # `grep -rl '^## Code anchors' docs --include='*.md'`, so a doc gaining that
    # heading becomes a member. That is a genuine second instance of this class
    # and it is NOT covered here.
    #
    # It is not covered because I tried and MEASURED THE COST. Extracting the bare
    # operand means telling grep's pattern apart from every other quoted string on
    # a line that has already had its continuations joined — and those lines are
    # pipelines (`grep -rl '…' docs --include='*.md' | grep -v '^docs/cards/'`),
    # so "strip the option-attached strings and take the first one left" picks up
    # the filter's pattern, or a neighbouring command's. The two-path negative
    # control went from CLEAN to TWO implicated registries, both FALSE:
    # web/README.md contains `^## Code anchors` zero times. A 100% false-positive
    # rate on the control is buying detection by making everything implicated,
    # which is the one thing this door must not do. The gap is declared in the
    # header and in --list-registries instead of being papered over.
    grep -oE "\-e[[:space:]]+'[^']+'|\-e[[:space:]]+\"[^\"\$]+\"" "$TMP/cg.$slug" 2>/dev/null \
      | sed -E "s/^-e[[:space:]]+//; s/^['\"]//; s/['\"]$//" \
      | LC_ALL=C sort -u \
      | while IFS= read -r cp; do
          [ -n "$cp" ] || continue
          # DEGENERATE-PATTERN CONTROL. This script's own source contains the
          # string `-e[[:space:]]+'[^']+'` — the extractor's own regex — so
          # extracting from itself yields the pattern `[^']+`, which matches
          # essentially every line of every file and made this script a
          # content-member of everything, itself included. The rejection is a
          # CONTROL, not a length heuristic: a pattern that matches a sentinel
          # string sharing no vocabulary with any real corpus pattern is matching
          # on structure rather than on content, and is dropped.
          # Greps a FILE, never a pipe: `printf … | grep -q` is the 141-under-load
          # shape this script already had to remove once.
          if LC_ALL=C grep -qE -- "$cp" "$TMP/sentinel" 2>/dev/null; then
            echo "$cp" >> "$TMP/degenerate"
            continue
          fi
          printf '%s\n' "$cp"
        done > "$TMP/cpat/$slug"
    # Extension scope: every --include glob.
    grep -oE "\-\-include=?[[:space:]]*'[^']+'|\-\-include=?[[:space:]]*\"[^\"]+\"" "$TMP/cg.$slug" 2>/dev/null \
      | sed -E "s/^--include=?[[:space:]]*//; s/^['\"]//; s/['\"]$//" \
      | LC_ALL=C sort -u > "$TMP/cinc/$slug"
    # Directory scope. The operand is usually a variable ($dirs), built a loop
    # away from its literal, so it is not resolvable at the call site. Instead:
    # any literal assignment in this file whose value is a list of REAL tracked
    # directories is taken as scope (SCAN_DIRS="scripts tooling .github/workflows"
    # resolves this way). Union only — it can narrow nothing — and when nothing
    # resolves, the check simply does not scope by directory, which over-calls in
    # the direction of the finding rather than away from it.
    grep -oE '^[[:space:]]*[A-Z][A-Z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"')' "$f" 2>/dev/null \
      | sed -E 's/^[[:space:]]*[A-Z][A-Z0-9_]*=//; s/^["'"'"']//; s/["'"'"']$//' \
      | tr ' ' '\n' | grep -vE '^[[:space:]]*$' \
      | while IFS= read -r d; do
          case "$d" in *'$'*|/*|*'*'*) continue ;; esac
          # `--` or grep reads a value like `--sha` as an OPTION and spews a
          # usage block per candidate. Harmless to the verdict, fatal to the
          # output's readability, and it is the shape that hides a real error.
          LC_ALL=C grep -qxF -- "$d" "$TMP/dirs" && printf '%s\n' "$d"
        done | LC_ALL=C sort -u > "$TMP/cdir/$slug"
  fi
}

# Is path $1 a content-member of registry slug $2?
d4_member() {
  local p="$1" s="$2" cs ok inc d
  [ -s "$TMP/cpat/$s" ] || return 1
  # Extension scope, when the registry declared one.
  if [ -s "$TMP/cinc/$s" ]; then
    ok=1
    while IFS= read -r inc; do
      [ -n "$inc" ] || continue
      case "${p##*/}" in $inc) ok=0; break ;; esac
    done < "$TMP/cinc/$s"
    [ "$ok" = 0 ] || return 1
  fi
  # Directory scope, when one resolved.
  if [ -s "$TMP/cdir/$s" ]; then
    ok=1
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$p" in "$d"/*) ok=0; break ;; esac
    done < "$TMP/cdir/$s"
    [ "$ok" = 0 ] || return 1
  fi
  cs="$(content_of "$p")"
  [ -s "$cs" ] || return 1
  # Comment lines are stripped the way the measured registry strips them, so
  # prose describing a pattern does not manufacture a member.
  grep -vE '^[[:space:]]*(#|//)' "$cs" 2>/dev/null > "$cs.code" || : > "$cs.code"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if LC_ALL=C grep -qE -- "$pat" "$cs.code" 2>/dev/null; then return 0; fi
  done < "$TMP/cpat/$s"
  return 1
}

# glob -> ERE. '**' matches across separators, a lone '*' does not.
glob_to_ere() {
  printf '%s' "$1" | sed -E 's/[.]/\\./g; s/\*\*/\x01/g; s/\*/[^\/]*/g; s/\x01/.*/g; s/^/^/; s/$/$/'
}

# ------------------------------------------------------------------ list mode
if [ "$MODE" = list ]; then
  echo "registry-impact-check --list-registries"
  echo "  tracked files:      $TRACKED_N"
  echo "  grep control:       $CTRL_N files matched the control pattern (>5 required)"
  echo "  derived registries: $REG_N (floor $REGISTRY_FLOOR)"
  echo ""
  echo "PREDICATE: a file holding an expected value it did not compute this run."
  echo "  B1 in-file pinned integer  B2 committed artifact (.allow/.pin/.tsv/.baseline/-registry.json)"
  echo "  B2b a tracked README.md named beside a count word"
  echo ""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    extract_for "$r"
    s="$(slug_of "$r")"
    printf '%s\n' "$r"
    if [ -s "$TMP/art/$s" ]; then
      printf '    expects: '; tr '\n' ' ' < "$TMP/art/$s"; printf '\n'
    fi
    if [ -s "$TMP/glob/$s" ]; then
      printf '    scans:   '; tr '\n' ' ' < "$TMP/glob/$s"; printf '\n'
    fi
  done < "$TMP/registries"
  echo ""
  echo "TALLY: $REG_N registries derived from $TRACKED_N tracked files."
  exit "$RC_CLEAN"
fi

# ------------------------------------------------------ PHASE 3: the changed set
if [ "$HAVE_EXPLICIT" = 1 ]; then
  grep -v '^[[:space:]]*$' "$TMP/paths.explicit" | LC_ALL=C sort -u > "$TMP/changed"
  CHANGED_SRC="explicit (--path/--paths-from)"
else
  MB="$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null)"
  [ -n "$MB" ] || cannot_read "no merge-base between '$BASE' and HEAD; pass --base or --path"
  {
    git -C "$ROOT" diff --name-only "$MB" HEAD 2>/dev/null
    git -C "$ROOT" diff --name-only HEAD 2>/dev/null
    git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null
  } | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u > "$TMP/changed"
  CHANGED_SRC="$BASE...HEAD (merge-base ${MB:0:9}) + working tree + untracked"
fi

CHANGED_N=$(wc -l < "$TMP/changed" | tr -d ' ')

echo "registry-impact-check — which registries count the files this change touches?"
echo "  changed set:        $CHANGED_N path(s) from $CHANGED_SRC"
echo "  derived registries: $REG_N (floor $REGISTRY_FLOOR, tracked $TRACKED_N, grep control $CTRL_N)"
echo ""

if [ "${CHANGED_N:-0}" -eq 0 ]; then
  echo "EMPTY CHANGED SET — nothing to check. This is not a clean bill of health for any"
  echo "change; it is the statement that this run was handed no paths."
  echo ""
  echo "TALLY: 0 obligation(s) across 0 changed path(s); $REG_N registries were scanned."
  exit "$RC_CLEAN"
fi

: > "$TMP/hits"
while IFS= read -r r; do
  [ -n "$r" ] || continue
  extract_for "$r"
  s="$(slug_of "$r")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    door=""
    if [ -s "$TMP/art/$s" ] && LC_ALL=C grep -qxF "$p" "$TMP/art/$s" 2>/dev/null; then
      door="D3-ARTIFACT"
    elif [ "$p" = "$r" ]; then
      door="D3-SELF"
    fi
    if [ -z "$door" ] && [ -s "$TMP/art/$s" ]; then
      # EXACT token match, never a substring. A bare `grep -F` for
      # `scripts/pds-pull-proof.sh` also hits `scripts/pds-pull-proof_test.sh`
      # and every longer sibling, so a row for one file would claim its whole
      # name-family. The path must be bounded by something that cannot be part
      # of a path on either side.
      p_ere="$(printf '%s' "$p" | sed -E 's/[][^$.*\\\/+?(){}|]/\\&/g')"
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        # READ AT THE REF, not from the working tree. Reading the artifact here
        # while D4 read content at the ref is what made the d3af39283 subject and
        # its d3af39283^ CONTROL produce BYTE-IDENTICAL output the moment main
        # adjudicated the row: D1 answered for the present, the control claimed to
        # answer for the past, and both said the same thing.
        if LC_ALL=C grep -qE "(^|[^A-Za-z0-9_./-])${p_ere}([^A-Za-z0-9_./-]|$)" "$(content_of "$a")" 2>/dev/null; then
          door="D1-ENUMERATED"; break
        fi
      done < "$TMP/art/$s"
    fi
    if [ -z "$door" ] && [ -s "$TMP/glob/$s" ]; then
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        # NO PIPE HERE, deliberately. `printf … | grep -q` is the shape that
        # returns 141 under load: grep -q exits on the first match and closes the
        # pipe, printf takes SIGPIPE, and `pipefail` hands the pipeline 141 — so a
        # MATCH reads as a NO-MATCH exactly when the box is busy. That would kill
        # the new-file door intermittently and invisibly, which is the same defect
        # class this script exists to catch. scripts/pipefail-sigpipe-scan.sh
        # flagged this very line. Bash's own =~ touches no second process.
        g_ere="$(glob_to_ere "$g")"
        if [[ "$p" =~ $g_ere ]]; then door="D2-SCANNED:$g"; break; fi

      done < "$TMP/glob/$s"
    fi
    # D4 LAST, because D1/D2/D3 already name a remedy and this one is the most
    # expensive. It is the only door that can see a file BECOME a member by what
    # the edit put inside it.
    if [ -z "$door" ] && d4_member "$p" "$s"; then
      door="D4-CONTENT"
    fi
    [ -n "$door" ] || continue
    printf '%s\t%s\t%s\n' "$r" "$p" "$door" >> "$TMP/hits"
  done < "$TMP/changed"
done < "$TMP/registries"

HIT_N=$(wc -l < "$TMP/hits" | tr -d ' ')

if [ "${HIT_N:-0}" -eq 0 ]; then
  echo "CLEAN — no derived registry counts or enumerates anything in these paths."
  echo "This is a MEASURED empty, not a skipped one: $REG_N registries were resolved and"
  echo "each was matched against all $CHANGED_N changed path(s). A scan that could not run"
  echo "exits $RC_CANNOT_READ and prints no tally at all."
  # A CLEAN must say what it looked at, including the door most likely to be
  # misread. Content membership is the one that depends on WHICH TREE the question
  # was asked of, and a clean that does not name the ref is inviting the reader to
  # assume a tree that was never read.
  # Counted off the filesystem, not by a grep whose flags I guessed: `grep -lc`
  # printed 202 content-keyed registries out of 201 examined — an impossible
  # number, and a tally that can exceed its own denominator is the lie this
  # script's own rules forbid. -size +0 asks the only question that matters here.
  CK_N=$(find "$TMP/cpat" -type f 2>/dev/null | wc -l | tr -d ' ')
  CK_LIVE=$(find "$TMP/cpat" -type f -size +0 2>/dev/null | wc -l | tr -d ' ')
  echo "Whole evaluation was pinned to: ${AT_REF:-the working tree} — tracked list, registry set,"
  echo "each registry's source, each expectation artifact, and file content, all read there."
  echo "Content membership (D4) was evaluated for $CK_LIVE content-keyed registr(y|ies) of $CK_N examined."
  echo "If you are replaying a commit and did NOT pass --at <that commit>, this run measured TODAY's tree."
  echo "THIS CLEAN DOES NOT COVER: a registry whose corpus grep passes a BARE quoted pattern rather"
  echo "than -e '<pat>' (scripts/docs-anchors-check.sh is the known one: a doc gaining a"
  echo "'## Code anchors' heading becomes a member). Extraction cannot tell that pattern from a"
  echo "pipeline filter's without manufacturing false positives, so it is declared, not guessed."
  echo ""
  echo "TALLY: 0 obligation(s) across $CHANGED_N changed path(s); $REG_N registries scanned."
  exit "$RC_CLEAN"
fi

echo "IMPLICATED — these registries count or enumerate something in the changed paths."
echo "Each needs its declaration IN THIS SAME COMMIT, or main reds after the merge."
echo ""

LC_ALL=C sort -u "$TMP/hits" | cut -f1 | LC_ALL=C uniq | while IFS= read -r r; do
  s="$(slug_of "$r")"
  echo "REGISTRY  $r"
  LC_ALL=C sort -u "$TMP/hits" | awk -F'\t' -v R="$r" '$1==R {printf "    via %-28s %s\n", $3, $2}'
  if [ -s "$TMP/art/$s" ]; then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      if LC_ALL=C grep -qxF "$a" "$TMP/changed"; then
        echo "    DECLARE in $a  [this diff TOUCHES it — a touch is NOT a bump; verify the pinned value moved]"
      else
        echo "    DECLARE in $a  [this diff does NOT touch it]"
      fi
    done < "$TMP/art/$s"
  else
    echo "    DECLARE by re-running $r and reconciling its in-file pinned expectation."
  fi
  echo ""
done

OBLIG_N=$(LC_ALL=C sort -u "$TMP/hits" | cut -f1 | LC_ALL=C uniq | wc -l | tr -d ' ')
echo "TALLY: $OBLIG_N registr(y|ies) implicated by $HIT_N path-match(es) across $CHANGED_N changed path(s)."
echo "Advisory and read-only: nothing was written. Run each named registry to see the red before CI does."
exit "$RC_IMPLICATED"
