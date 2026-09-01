#!/usr/bin/env bash
# new-lineref-check.sh — a comment may not INTRODUCE a `<file>.ex:<line>` citation.
#
# (Note the placeholder spelling. This header describes the pattern it forbids,
# so writing a concrete example would make the file fail its own gate — it did,
# on the first run. `<line>` is not digits, so it does not match. The alternative
# was to spend the `lineref-ok` hatch on the gate's own prose, which would have
# been the worse trade: the hatch should be rare enough that grepping it is
# interesting.)
#
# THE CLASS, AND WHY CATCHING IT LATER IS NOT ENOUGH
# --------------------------------------------------
# A line number in a comment is correct exactly once. The next insertion above
# the cited line silently makes it a lie, and nothing about the comment changes,
# so no reviewer ever looks at it again. This repo has been round this loop
# three times.
#
# tooling/doc-truth/lineref-sweep.mjs already sweeps the corpus for citations
# that have ALREADY drifted, never-worse against a 542-entry baseline. That is
# the right gate for existing debt and it is not this one. Its findings come
# from `runVerify`, which only reports a citation once the cited line no longer
# holds what the comment says — so a citation that is ACCURATE TODAY produces no
# finding, passes, and rots at its leisure. The sweep then reds, on a PR that
# merely inserted a line somewhere above, authored by someone who never saw the
# comment.
#
# This gate removes the class instead of timing it: refuse the citation while it
# is still true, because being true today is not a property it keeps.
#
# MEASURED FIRING RATE, so nobody has to guess whether this is hostile. Over the
# last 40 commits on main, 37 touched source files; 4 of them (~11%) introduced
# exactly one new comment lineref each. About one PR in nine, one line to fix,
# and each of those four is a future false alarm in the sweep.
#
# DIFF-SCOPED, NOT TREE-SCOPED — deliberately. The tree carries 547 pre-existing
# citations. A tree-scoped clean-tree gate would red main on day one and get
# disabled, and a disabled gate still looks like coverage. Scoping to lines the
# PR ADDS needs no baseline at all, and a gate with no baseline has nothing that
# can rot, no regeneration ritual, and no `--write-baseline` escape to reach for
# when it goes red.
#
# THE ESCAPE HATCH IS DELIBERATE AND VISIBLE. Sometimes a line number really is
# the clearest thing to write — pinning a spot in a vendored file, quoting a
# stack frame. Put `lineref-ok` in the same comment and this gate stands down.
# It is one grep to audit every such decision, which a silent exemption list
# would not be.
#
# WHAT COUNTS AS A CITATION: <path>.<source-ext>:<digits>, and only on a line
# the diff ADDS whose content starts with a comment marker (// # -- *). Code is
# not scanned: a citation inside a string literal is not a claim about the repo,
# and a
# scanner that cannot tell prose from payload reports noise until it is ignored.
#
# WHAT EACH GATE STILL SEES AFTER THIS ONE LANDS — stated explicitly, because
# two gates over one corpus is how a check goes quietly vacuous.
#
#   lineref-sweep.mjs   UNCHANGED. It still walks the WHOLE tracked corpus via
#                       git ls-files and still reds on any of its 542 baselined
#                       citations that DRIFTS. This gate removes nothing from
#                       its input: it edits no file the sweep reads, filters
#                       nothing ahead of it, and touches neither the baseline
#                       nor the corpus definition. Its population is the same
#                       set of files it saw yesterday.
#
#   new-lineref-check   ONLY the comment lines a PR ADDS. It never looks at an
#                       existing citation, so it can never report — or silence —
#                       anything the sweep is watching.
#
# The two are disjoint by construction: one watches citations that EXIST for
# drift, the other refuses citations that do not exist yet. The only coupling is
# intended and one-way — a citation this gate refuses never enters the sweep's
# corpus, so the sweep's population stops GROWING while every entry already in
# it stays as watched as before. Neither gate is a pre-filter for the other, and
# neither can be deleted without losing a population the other never sees.

# EXIT CODES, kept distinct:
#   0  no new citations
#   1  FINDING — at least one added comment introduces a file:line citation
#   2  HARNESS-UNAVAILABLE — no git, or the base ref cannot be resolved. NOT a
#      pass: a gate that cannot see the diff must not certify it.
#
# Usage:
#   scripts/new-lineref-check.sh                 # vs origin/main (or $BASE_REF)
#   scripts/new-lineref-check.sh <base-ref>
#   scripts/new-lineref-check.sh --selftest      # prove the gate can fail
set -uo pipefail

MODE="${1:-}"

# A citation: some path ending in a source extension, then :digits.
CITATION='[A-Za-z0-9_./-]+\.(ex|exs|heex|go|ts|tsx|js|mjs|jsx|mts|cts|sh|css)\:[0-9]+'
# An added line whose content begins with a comment marker.
ADDED_COMMENT='^\+[[:space:]]*(//|#|--|\*)'

SRC_GLOBS=('*.ex' '*.exs' '*.heex' '*.go' '*.ts' '*.tsx' '*.mjs' '*.js' '*.jsx' '*.sh')

command -v git >/dev/null 2>&1 || {
  echo "HARNESS-UNAVAILABLE: git is not on PATH — cannot read the diff." >&2
  echo "This is NOT a pass: a gate that cannot see its input must not certify it." >&2
  exit 2
}

resolve_base() {
  local want="$1" base
  if [ -n "$want" ]; then
    base="$want"
  elif [ -n "${BASE_REF:-}" ]; then
    base="$BASE_REF"
  elif [ -n "${GITHUB_BASE_REF:-}" ]; then
    base="origin/$GITHUB_BASE_REF"
  else
    base="origin/main"
  fi
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null || return 1
  printf '%s' "$base"
}

run_check() {
  local want="${1:-}" base merge_base diff hits scanned rc=0

  base="$(resolve_base "$want")" || {
    echo "HARNESS-UNAVAILABLE: cannot resolve base ref '${want:-${BASE_REF:-${GITHUB_BASE_REF:-origin/main}}}'." >&2
    echo "This is NOT a pass. Fetch the base branch and re-run." >&2
    return 2
  }

  # THREE-DOT. `git diff base..HEAD` re-reports every commit that landed on the
  # base since this branch forked, so a busy main makes the gate blame a PR for
  # lines it never wrote. Three-dot diffs against the merge base, which is the
  # set of lines this branch is actually responsible for.
  merge_base="$(git merge-base "$base" HEAD 2>/dev/null)" || {
    echo "HARNESS-UNAVAILABLE: no merge base between '$base' and HEAD." >&2
    return 2
  }

  # NOTHING TO CHECK IS NOT A PASS, AND MUST NOT READ LIKE ONE. On the push arm
  # (HEAD is the base, or an ancestor of it) the range is empty and every gate
  # over zero inputs reports success. Say SKIPPED, by name, with the reason — a
  # reader scanning the log must be able to tell "found nothing wrong" from
  # "never looked". Still exit 0: on main there is genuinely nothing to judge.
  if [ "$merge_base" = "$(git rev-parse HEAD)" ]; then
    echo "new-lineref-check: SKIPPED — HEAD is the merge base with '$base', so this"
    echo "  revision adds no lines relative to it. Nothing was inspected. This gate"
    echo "  is meaningful on a pull request, where HEAD is ahead of its base."
    return 0
  fi

  diff="$(git diff --unified=0 "$merge_base" HEAD -- "${SRC_GLOBS[@]}" 2>/dev/null)"
  scanned="$(printf '%s\n' "$diff" | grep -cE "$ADDED_COMMENT" || true)"
  hits="$(printf '%s\n' "$diff" | grep -E "$ADDED_COMMENT" | grep -E "$CITATION" | grep -v 'lineref-ok' || true)"

  if [ -n "$hits" ]; then
    echo "new-lineref-check: FAILED — a comment introduces a file:line citation."
    echo ""
    printf '%s\n' "$hits" | sed 's/^/    /'
    echo ""
    echo "  A line number is correct exactly once. The next insertion above it makes"
    echo "  the comment a lie, and nothing about the comment changes, so nobody looks"
    echo "  again. tooling/doc-truth/lineref-sweep.mjs will red on this later, on"
    echo "  someone else's PR."
    echo ""
    echo "  FIX: cite what does not move — the file, the function, or a"
    echo "  \`@canonical capability:\` slug:"
    echo "      # see assignConcepts in tooling/concept-map/concepts.mjs"
    echo "      # see @canonical capability:concept-token-fold"
    echo ""
    echo "  If the line number is genuinely the clearest thing to write, put"
    echo "  \`lineref-ok\` in the same comment. That is one grep to audit."
    rc=1
  else
    echo "new-lineref-check: OK — no new file:line citations ($scanned added comment line(s) scanned vs $base)"
  fi
  return "$rc"
}

selftest() {
  local dir pass=0 fail=0 here
  here="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  dir="$(mktemp -d -t nlrc-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN

  # A hermetic repo: a base commit, then a branch commit carrying the fixture.
  ( cd "$dir" \
    && git init -q . \
    && git config user.email t@t && git config user.name t \
    && mkdir -p sub \
    && echo "defmodule A do" > sub/a.ex && echo "end" >> sub/a.ex \
    && git add -A && git commit -qm base ) >/dev/null 2>&1

  st() { # st <label> <expected-rc>
    local label="$1" want="$2" got out
    out="$( cd "$dir" && bash "$here" HEAD~1 2>&1 )"; got=$?
    if [ "$got" = "$want" ]; then
      echo "  ok    $label — exit $got"
      pass=$((pass + 1))
    else
      echo "  FAIL  $label — got $got want $want"
      printf '%s\n' "$out" | sed 's/^/          /'
      fail=$((fail + 1))
    fi
  }

  commit_with() { # commit_with <line>
    ( cd "$dir" \
      && git checkout -q -B work HEAD >/dev/null 2>&1 \
      && git reset -q --hard HEAD >/dev/null 2>&1 \
      && printf '%s\n' "$1" >> sub/a.ex \
      && git add -A && git commit -qm fixture ) >/dev/null 2>&1
  }
  reset_base() { ( cd "$dir" && git reset -q --hard HEAD~1 ) >/dev/null 2>&1; }

  echo "new-lineref-check --selftest"
  echo ""

  commit_with "  # see assignConcepts in tooling/concept-map/concepts.mjs"
  st "0) a comment citing a FILE (no line) passes" 0
  reset_base

  commit_with "  # see tooling/concept-map/concepts.mjs:130 for the fold"
  st "a) a comment citing file:line REDS" 1
  reset_base

  commit_with "  # see tooling/concept-map/concepts.mjs:130 — lineref-ok, vendored pin"
  st "b) the lineref-ok escape hatch stands down" 0
  reset_base

  commit_with '  x = "tooling/concept-map/concepts.mjs:130"'
  st "c) a citation in CODE, not a comment, is not scanned" 0
  reset_base

  commit_with "  # the service listens on example.com:8080"
  st "d) a host:port is not a citation" 0
  reset_base

  commit_with "  // api/lib/barkpark/content.ex:44 is where it happens"
  st "e) a // comment is scanned too" 1
  reset_base

  # HEAD == base: the push-arm shape. Must exit 0 but say SKIPPED, not OK — a
  # reader has to be able to tell "found nothing" from "never looked".
  local g_out g_rc
  g_out="$( cd "$dir" && bash "$here" HEAD 2>&1 )"; g_rc=$?
  if [ "$g_rc" = 0 ] && printf '%s' "$g_out" | grep -q "SKIPPED"; then
    echo "  ok    g) HEAD == base says SKIPPED, not OK — exit $g_rc"
    pass=$((pass + 1))
  else
    echo "  FAIL  g) HEAD == base must say SKIPPED at exit 0 — got $g_rc"
    printf '%s\n' "$g_out" | sed 's/^/          /'
    fail=$((fail + 1))
  fi

  # An unresolvable base must REFUSE, never pass.
  local got out
  out="$( cd "$dir" && bash "$here" no/such/ref 2>&1 )"; got=$?
  if [ "$got" = 2 ]; then
    echo "  ok    f) an unresolvable base ref REFUSES (exit 2, not 0) — exit $got"
    pass=$((pass + 1))
  else
    echo "  FAIL  f) an unresolvable base ref REFUSES — got $got want 2"
    printf '%s\n' "$out" | sed 's/^/          /'
    fail=$((fail + 1))
  fi

  echo ""
  if [ "$fail" -eq 0 ]; then
    echo "SELFTEST PASSED: $pass of $((pass + fail)) arms"
    return 0
  fi
  echo "SELFTEST FAILED: $fail of $((pass + fail)) arm(s) did not behave"
  return 1
}

case "$MODE" in
  --selftest) selftest ;;
  --help|-h) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) run_check "$MODE" ;;
esac
