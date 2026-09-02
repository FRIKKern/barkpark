#!/usr/bin/env bash
#
# console-export-tree.sh — build an origin/main measurement tree for the console
# instruments, and REFUSE the instruments an export cannot honestly answer.
#
# WHY THIS EXISTS (Cloud Console Hardening, cch-w16-bl-export-recipe-manufactures-false-reds)
# ------------------------------------------------------------------------------------------
# The charter's D183(h) recipe was PROSE, so every builder transcribed it, and
# every transcription drifted. It named a PATH-SCOPED export —
#
#     git archive origin/main cloud/priv/static | tar -x        # plus two testdata dirs
#
# — and a path-scoped export manufactures reds that do not exist on main. The
# extract trap has now been logged in this charter four separate times (D423,
# D547, D601/D622, D782) and re-learned by three wave-16 verifiers independently.
# A recipe you EXECUTE cannot drift; a recipe you copy out of a table cell does.
#
# TWO DIFFERENT FAILURES ARE BEING CONFLATED, AND ONLY ONE OF THEM IS FIXABLE:
#
#   (1) MISSING FILES. __app.test.mjs reads well outside cloud/priv/static — it
#       opens cloud/lib/**, cloud/priv/audit-actions.json, deploy/*.sh and
#       internal/agent/report.go. A path-scoped export cannot keep up with that
#       list (it already could not, one wave after D183(h) was written). The fix
#       is a FULL-TREE export, which this script takes. `git archive <rev>` with
#       no pathspec is not slower in any way that matters and cannot go stale.
#
#   (2) NO .git DIRECTORY. seal-predicate.mjs resolves REPO by walking up from
#       its own file and then shells out to `git merge-base --is-ancestor`,
#       `rev-parse` and friends. An extracted tarball is not a git work tree, so
#       those legs answer a question about the extraction rather than about the
#       commit. NO pathspec fixes this. The only honest venue is `git worktree
#       add` (D782). This script therefore REFUSES BY NAME rather than pretending.
#
# MEASURED at origin/main 7af839d56a, one shape per row, exit code read from $?:
#
#   shape                                                        __app.test.mjs   seal-predicate.test.mjs
#   A  git archive origin/main cloud/priv/static                 1186 / 19  rc 1   (not run)
#   B  A + internal/{taskboard,pdrender}/testdata  (= D183(h))    1188 / 17  rc 1   (not run)
#   C  B + .github                                               1188 / 17  rc 1   47 / 50  rc 1
#   D  git archive origin/main            (full tree, THIS FILE) 1205 /  0  rc 0   65 / 32  rc 1
#   E  git worktree add … origin/main     (a real checkout)      1205 /  0  rc 0   97 /  0  rc 0
#
# Read D against E: a full export is green for everything EXCEPT the predicate,
# where it still fabricates 32 reds. That column is why REFUSED_INSTRUMENTS below
# is a hard refusal and not a warning.
#
# THE PORT NO-OP, recorded here because briefs kept relying on it for isolation:
# `PREVIEW_PORT` is read at __preview__/serve.mjs:38 and NOWHERE ELSE. The sweep
# reads BREAKPOINT_SWEEP_PORT (default 4207) and the guard reads
# OVERFLOW_GUARD_PORT (default 4199). A MUST-RUN that sets PREVIEW_PORT in front
# of breakpoint-sweep.mjs is isolating nothing, and on a host running concurrent
# waves two sweeps will collide on 4207 while both briefs look careful.
# Re-derive:  grep -rn 'PREVIEW_PORT\|BREAKPOINT_SWEEP_PORT\|OVERFLOW_GUARD_PORT' \
#               cloud/priv/static/__preview__/*.mjs
#
# USAGE
#   scripts/console-export-tree.sh --dest <dir> [--rev origin/main] [--verify]
#   scripts/console-export-tree.sh --check <dir>
#   scripts/console-export-tree.sh --selftest
#
#   --dest <dir>   where the tree lands (created; must be empty or absent)
#   --check <dir>  only run the completeness check over an EXISTING tree
#   --rev  <rev>   what to export (default origin/main)
#   --verify       run the export-safe gates in the new tree and report counts
#   --selftest     prove the completeness check catches a missing path (no export)
#
set -euo pipefail

# ── The paths every export-safe console gate actually reads ──────────────────
# Each entry was derived from an observed ENOENT under a path-scoped export, not
# guessed. `--selftest` removes them ONE AT A TIME and asserts each is a red —
# that proves the CHECK is load-bearing per entry, NOT that a gate still reads
# the file, so re-derive the list from a fresh red rather than trusting it:
#   node --test cloud/priv/static/__app.test.mjs 2>&1 | grep -oE "(open|scandir) '[^']*'"
REQUIRED_PATHS=(
  "cloud/priv/static/app.js"
  "cloud/priv/static/__app.test.mjs"
  "cloud/priv/static/__css_check.mjs"
  "cloud/priv/audit-actions.json"
  "cloud/lib"
  "internal/taskboard/testdata"
  "internal/pdrender/testdata"
  "internal/agent/report.go"
  "deploy/lib/site-deploy-common.sh"
  "deploy/site-deploy-node.sh"
  ".github/workflows"
)

# ── Instruments that CANNOT be answered from an extraction, and why ──────────
# Format: <path>|<one-line reason>. Refused loudly, by name, on every run.
REFUSED_INSTRUMENTS=(
  "cloud/priv/static/__preview__/seal-predicate.test.mjs|walks up to a repo root and shells out to git; 32 of 97 fabricated reds in a full export at 7af839d56a, 0 in a worktree"
  "cloud/priv/static/__preview__/seal-predicate.mjs|same root walk; clause (b) ancestry legs answer about the extraction, not the commit (D318, D782)"
)

# ── Gates that ARE honest in an export, run by --verify ──────────────────────
VERIFY_GATES=(
  "node --test cloud/priv/static/__app.test.mjs"
  "node cloud/priv/static/__css_check.mjs"
  "node --test cloud/priv/static/__preview__/bringup-retry.test.mjs"
  "node --test cloud/priv/static/__preview__/defect-selection.test.mjs"
  "node --test cloud/priv/static/__preview__/exit-vocabulary.test.mjs"
  "node --test cloud/priv/static/__preview__/font-pin.test.mjs"
)

die() { printf 'console-export-tree: %s\n' "$*" >&2; exit 2; }

# check_tree <dir> — every REQUIRED_PATHS entry present? Prints each miss.
# Returns 0 when complete, 1 when anything is missing. This is the predicate
# --selftest mutates; keep it free of side effects.
check_tree() {
  local dir="$1" p missing=0
  for p in "${REQUIRED_PATHS[@]}"; do
    if [ ! -e "$dir/$p" ]; then
      printf '  MISSING %s\n' "$p"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ]
}

announce_refusals() {
  local entry path reason
  printf '\nREFUSED — these do NOT run in an export tree, at any pathspec:\n'
  for entry in "${REFUSED_INSTRUMENTS[@]}"; do
    path="${entry%%|*}"
    reason="${entry#*|}"
    printf '  %s\n      %s\n' "$path" "$reason"
  done
  printf '  Run them from a real checkout instead:\n'
  printf '      git worktree add <dir> <rev> && cd <dir> && node --test cloud/priv/static/__preview__/seal-predicate.test.mjs\n\n'
}

selftest() {
  local p rc fails=0 checked=0 tmp
  # NOT `local tmp` for the trap's sake: an EXIT trap runs after the function
  # has returned, where a `local` is already out of scope and `set -u` would
  # kill the cleanup with "unbound variable" (and take the exit code with it).
  SELFTEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/console-export-selftest.XXXXXX")"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT
  tmp="$SELFTEST_TMP"

  # GREEN-WITH: a synthetic tree holding exactly the required set passes.
  for p in "${REQUIRED_PATHS[@]}"; do
    mkdir -p "$tmp/good/$p"
  done
  if check_tree "$tmp/good" >/dev/null; then
    printf 'ok   complete tree passes check_tree\n'
  else
    printf 'FAIL complete tree was rejected\n'; fails=$((fails + 1))
  fi

  # RED-WITHOUT: remove ONE required path at a time. Every entry must be
  # load-bearing on its own, or it is decoration and must be deleted from the
  # list. A pass here that skipped an entry would be the vacuous shape this
  # whole script exists to prevent, so the count is asserted below.
  for p in "${REQUIRED_PATHS[@]}"; do
    rm -rf "${tmp:?}/mut"
    cp -R "$tmp/good" "$tmp/mut"
    rm -rf "${tmp:?}/mut/${p:?}"
    [ ! -e "$tmp/mut/$p" ] || { printf 'FAIL mutation did not apply: %s\n' "$p"; fails=$((fails + 1)); continue; }
    rc=0
    check_tree "$tmp/mut" >/dev/null || rc=$?
    checked=$((checked + 1))
    if [ "$rc" -ne 0 ]; then
      printf 'ok   check_tree reds without %s\n' "$p"
    else
      printf 'FAIL check_tree stayed green without %s\n' "$p"; fails=$((fails + 1))
    fi
  done

  if [ "$checked" -ne "${#REQUIRED_PATHS[@]}" ]; then
    printf 'FAIL mutated %d of %d required paths\n' "$checked" "${#REQUIRED_PATHS[@]}"; fails=$((fails + 1))
  fi

  # The refusal list must be non-empty and must name the predicate suite; an
  # emptied list would let this script certify exactly the tree it refuses.
  if printf '%s\n' "${REFUSED_INSTRUMENTS[@]}" | grep -q 'seal-predicate.test.mjs'; then
    printf 'ok   refusal list names seal-predicate.test.mjs\n'
  else
    printf 'FAIL refusal list does not name seal-predicate.test.mjs\n'; fails=$((fails + 1))
  fi

  printf '\nselftest: %d checks, %d failed\n' "$((checked + 2))" "$fails"
  [ "$fails" -eq 0 ]
}

main() {
  local dest="" rev="origin/main" verify=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --selftest) selftest; exit $? ;;
      --check) [ -n "${2:-}" ] || die "--check needs a directory"
               printf 'checking %s against the read set of the console gates\n' "$2"
               check_tree "$2" && { printf '  complete\n'; exit 0; }
               exit 1 ;;
      --dest) dest="${2:-}"; shift 2 || die "--dest needs a directory" ;;
      --rev)  rev="${2:-}";  shift 2 || die "--rev needs a revision" ;;
      --verify) verify=1; shift ;;
      -h|--help) sed -n '/^# USAGE/,/^$/p' "$0"; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  [ -n "$dest" ] || die "--dest is required (or pass --selftest)"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run this from inside the barkpark repo"
  git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || die "no such revision: $rev"

  if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    die "--dest $dest is not empty; refusing to extract over an existing tree"
  fi
  mkdir -p "$dest"

  local sha
  sha="$(git rev-parse "$rev")"
  printf 'exporting %s (%s) — FULL TREE, no pathspec\n' "$rev" "$sha"
  # No pathspec, on purpose: see (1) in the header. A pathspec is what made the
  # old recipe rot, and it rots again the next time a test opens a new file.
  git archive "$sha" | tar -x -C "$dest"

  printf 'checking the export for every path the console gates read...\n'
  if check_tree "$dest"; then
    printf '  complete: %d/%d required paths present\n' "${#REQUIRED_PATHS[@]}" "${#REQUIRED_PATHS[@]}"
  else
    die "export at $dest is incomplete — see MISSING above"
  fi

  announce_refusals

  if [ "$verify" -eq 1 ]; then
    local gate out rc fails=0
    printf 'running the export-safe gates in %s\n' "$dest"
    for gate in "${VERIFY_GATES[@]}"; do
      out="$(cd "$dest" && eval "$gate" 2>&1)" && rc=0 || rc=$?
      printf '  rc=%s  %s\n' "$rc" "$gate"
      printf '%s\n' "$out" | grep -E '^# (pass|fail)|error\(s\)' | sed 's/^/        /'
      [ "$rc" -eq 0 ] || fails=$((fails + 1))
    done
    printf '\n%d of %d export-safe gates red\n' "$fails" "${#VERIFY_GATES[@]}"
    [ "$fails" -eq 0 ] || exit 1
  fi

  printf 'tree ready: %s\n' "$dest"
}

main "$@"
