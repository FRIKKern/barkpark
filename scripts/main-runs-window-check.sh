#!/usr/bin/env bash
# main-runs-window-check.sh — AN UN-PAGINATED actions/runs QUERY AGAINST MAIN
# READS ~81 SECONDS AND ITS EMPTY RESULT IS "CANNOT READ", NEVER "ABSENT".
#
# THE RULE, in one sentence: a call to the repo-wide `actions/runs` feed scoped
# to branch=main must either PAGINATE (`--paginate`, or a `page=` argument) or
# PRINT the created_at span of the rows it actually read, because on main
# 100 runs was 81 SECONDS of history on 2026-09-13 — roughly 50 workflows fire
# per push and main pushes landed at a 46-second median.
#
# THE SPECIMEN THAT COMMISSIONED THE RULE (task-9ee58a247b158826, 2026-09-13
# 11:40Z, run twice):
#   gh api -X GET repos/FRIKKern/barkpark/actions/runs -f branch=main \
#     -f per_page=100 --jq '...select(.name=="compose-smoke")...'
# returned ZERO rows. The IDENTICAL query with `-f page=3` returned
# e117a0215 success 11:26:32Z, a6ac74999 success 11:16:56Z and 02f5c3473
# success 11:13:42Z, and pages 4 and 5 returned three more. The zero was a
# 1.4-minute window, not an absence — a false "not found" of exactly the class
# only a control ever catches.
#
# WHAT IS *NOT* IN SCOPE, and why the distinction is the whole point:
#   * `actions/workflows/<file>/runs?branch=main` is PER-WORKFLOW. One page of
#     100 there is 100 runs OF THAT WORKFLOW — real history, often weeks of it.
#     The window collapse comes from the repo-wide feed sharing one page across
#     ~50 workflows. scripts/main-red-predicate.sh reads per-workflow for
#     exactly this reason, and this check must not punish it.
#   * tooling/grip/ledger/** — a dated, append-only record of a run that already
#     happened. It is evidence, not a recipe anybody re-runs.
#
# EXIT CODES
#   0  every in-scope repo-wide main runs query paginates or declares its window
#   1  FINDING — the file and line are named
#   2  CANNOT MEASURE — no files in scope, or no git. Never a vacuous green.
#
# USAGE
#   bash scripts/main-runs-window-check.sh
#   bash scripts/main-runs-window-check.sh --selftest
# MRW_ROOT overrides the tree to scan (--selftest uses it).
set -uo pipefail

mrw_scan() { # $1 = root  [$2 = a file to exclude, by realpath]
  python3 - "$1" "${2:-}" <<'PY'
import sys, os, re

root = sys.argv[1]
# THIS FILE DOES NOT SCAN ITSELF. Its planted fixtures ARE the mutation arms —
# the exact strings it must flag — so reading them back is circular, and nothing
# is lost: --selftest already drives every one of them through a planted tree.
# The exemption is SELF ONLY: ARM 1 proves the identical line in another file
# still reds.
SELF = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
IN_SCOPE_PREFIX = ("scripts/", ".github/", "deploy/", "docs/", "tooling/", "Makefile", ".claude/")
OUT_OF_SCOPE    = ("tooling/grip/ledger/",)

# The repo-wide runs feed. NOT actions/workflows/<x>/runs, which is per-workflow
# and bounded; the whole defect is one page shared across ~50 workflows.
REPO_WIDE = re.compile(r"(?<!workflows/)\bactions/runs\b(?!/)")
MAIN      = re.compile(r"branch=main|branch\s+main|-f\s+branch=main|branch=\$\{?\w*main")
PERPAGE   = re.compile(r"per_page\s*=\s*\d+|--limit\s+\d+")
# The two ways to be honest about the window.
PAGINATES = re.compile(r"--paginate|\bpage\s*=|\bpage=\$|for\s+p(age)?\s+in")
DECLARES  = re.compile(r"created_at|createdAt")

files = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "_build", "deps")]
    for fn in filenames:
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root)
        if not rel.startswith(IN_SCOPE_PREFIX):
            continue
        if rel.startswith(OUT_OF_SCOPE):
            continue
        if SELF and os.path.realpath(full) == SELF:
            continue
        files.append((rel, full))

print("in-scope tracked files scanned: %d" % len(files))
if not files:
    print("CANNOT MEASURE: ZERO files in scope — refusing to report 'no violations'")
    sys.exit(2)

findings = []
for rel, full in files:
    try:
        lines = open(full, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        continue
    for i, line in enumerate(lines):
        if not (REPO_WIDE.search(line) and MAIN.search(line) and PERPAGE.search(line)):
            continue
        # NEIGHBOURHOOD, not the single line: a `page=` loop or a created_at
        # print legitimately sits a line or two away from the URL.
        # (A single-line grep is not an absence claim.)
        ctx = "\n".join(lines[max(0, i - 3): i + 4])
        if PAGINATES.search(ctx) or DECLARES.search(ctx):
            continue
        findings.append((rel, i + 1, line.strip()[:150]))

if findings:
    print("")
    print("FINDING — %d un-paginated, un-declared repo-wide main runs query/queries:" % len(findings))
    for rel, ln, txt in findings:
        print("  %s:%d" % (rel, ln))
        print("      %s" % txt)
    print("")
    print("  On main, 100 runs was 81 SECONDS of history on 2026-09-13 — ~50 workflows")
    print("  fire per push at a 46s median cadence. Add --paginate or a page= loop, or")
    print("  print the created_at span of the rows you read. An empty result from this")
    print("  query is CANNOT READ, never absence.")
    sys.exit(1)
print("")
print("main-runs-window gate OK — every repo-wide actions/runs query scoped to main")
print("either paginates or declares the created_at span of what it read.")
sys.exit(0)
PY
}

if [ "${1:-}" = "--selftest" ]; then
  pass=0; fails=0
  _ok(){ printf 'PASS %-36s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-36s %s\n' "$1" "${2:-}"; fails=$((fails+1)); }
  D=$(mktemp -d) || { echo "SELFTEST: CANNOT MEASURE — no tmpdir"; exit 2; }
  mkdir -p "$D/t/scripts" "$D/t/tooling/grip/ledger" "$D/empty"
  _put(){ printf '%s\n' "$2" > "$D/t/$1"; }

  # ARM 1 — THE MUTATION THE ROW SPECIFIES, verbatim.
  _put scripts/bad.sh 'gh api -X GET repos/FRIKKern/barkpark/actions/runs -f branch=main -f per_page=100'
  out=$(mrw_scan "$D/t"); rc=$?
  if [ "$rc" = 1 ] && case "$out" in *"scripts/bad.sh:1"*) true;; *) false;; esac
  then _ok "un-paginated query is flagged" "file and line named"; else _no "un-paginated query is flagged" "rc=$rc | $out"; fi

  # ARM 2 — QUIET: --paginate.
  _put scripts/bad.sh 'gh api --paginate -X GET repos/FRIKKern/barkpark/actions/runs -f branch=main -f per_page=100'
  out=$(mrw_scan "$D/t"); rc=$?
  if [ "$rc" = 0 ]; then _ok "--paginate is accepted" "rc=0"; else _no "--paginate is accepted" "rc=$rc"; fi

  # ARM 3 — QUIET: an explicit page= argument.
  _put scripts/bad.sh 'gh api -X GET "repos/FRIKKern/barkpark/actions/runs?branch=main&per_page=100&page=$p"'
  out=$(mrw_scan "$D/t"); rc=$?
  if [ "$rc" = 0 ]; then _ok "page= is accepted" "rc=0"; else _no "page= is accepted" "rc=$rc"; fi

  # ARM 4 — QUIET: declaring the window instead of paginating.
  _put scripts/bad.sh 'gh api "repos/x/actions/runs?branch=main&per_page=100" --jq ".workflow_runs[]|.created_at" # prints the span read'
  out=$(mrw_scan "$D/t"); rc=$?
  if [ "$rc" = 0 ]; then _ok "declared created_at span accepted" "rc=0"; else _no "declared created_at span accepted" "rc=$rc"; fi

  # ARM 5 — THE DISTINCTION THAT MAKES THE RULE TRUE: a PER-WORKFLOW feed is
  # bounded and must NOT be flagged. Without this arm the rule would red
  # scripts/main-red-predicate.sh, which reads per-workflow on purpose.
  _put scripts/bad.sh 'gh api "repos/x/actions/workflows/elixir.yml/runs?branch=main&per_page=100"'
  out=$(mrw_scan "$D/t"); rc=$?
  if [ "$rc" = 0 ]; then _ok "per-workflow feed is not flagged" "rc=0"; else _no "per-workflow feed is not flagged" "rc=$rc | $out"; fi

  # ARM 6 — a dated ledger record is evidence, not a recipe.
  _put scripts/bad.sh 'echo fine'
  printf '%s\n' 'gh api "repos/x/actions/runs?branch=main&per_page=100"' > "$D/t/tooling/grip/ledger/old.md"
  out=$(mrw_scan "$D/t"); rc=$?
  if [ "$rc" = 0 ]; then _ok "grip ledger is out of scope" "rc=0"; else _no "grip ledger is out of scope" "rc=$rc"; fi

  # ARM 8 — THE SELF-EXEMPTION IS SELF ONLY. A copy of this very file placed
  # elsewhere in the tree is still scanned, so the exemption cannot be widened
  # into "any file that looks like a checker".
  cp "$0" "$D/t/scripts/copy-of-the-check.sh"
  out=$(mrw_scan "$D/t" "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"); rc=$?
  if [ "$rc" = 1 ] && case "$out" in *"copy-of-the-check.sh"*) true;; *) false;; esac
  then _ok "self-exemption is self only" "a copy elsewhere still reds"; else _no "self-exemption is self only" "rc=$rc"; fi
  trash "$D/t/scripts/copy-of-the-check.sh" 2>/dev/null || rm -f "$D/t/scripts/copy-of-the-check.sh"

  # ARM 7 — ZERO SCOPE REFUSES. An empty tree must never read as clean.
  out=$(mrw_scan "$D/empty"); rc=$?
  if [ "$rc" = 2 ] && case "$out" in *"ZERO files in scope"*) true;; *) false;; esac
  then _ok "zero scope refuses" "rc=2"; else _no "zero scope refuses" "rc=$rc"; fi

  trash "$D" 2>/dev/null || rm -rf "$D"
  total=$((pass+fails))
  [ "$total" -lt 8 ] && { echo "SELFTEST: CANNOT MEASURE — only $total arm(s) ran"; exit 2; }
  [ "$fails" = 0 ] && { echo "SELFTEST: $pass/$total arms pass"; exit 0; }
  echo "SELFTEST: $fails of $total arm(s) FAILED"; exit 1
fi

SELF_PATH=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/.."
mrw_scan "${MRW_ROOT:-.}" "$SELF_PATH"
