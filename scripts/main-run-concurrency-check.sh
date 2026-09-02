#!/usr/bin/env bash
# main-run-concurrency-check.sh — a MAIN run of a gate workflow must never be
# EVICTED by the next merge.
#
# THE DEFECT THIS FORBIDS, measured 2026-09-02 on main. elixir.yml and
# doc-gates.yml carried
#
#     concurrency:
#       group: <name>-${{ github.ref }}
#       cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
#
# never-cancel-main is honoured (a RUNNING main run is not killed) — but the
# group is per REF, so every push to main is a rival for one slot, and GitHub
# keeps exactly ONE not-yet-started run per group. Under merge cadence each
# merge evicts the pending main run before a runner picks it up: since 10:27Z,
# 40 main elixir runs, 37 cancelled, 1 completed. No main verdict existed to
# cite for the whole storm, and every ledger criterion that asks for a main-run
# log was starved. deploy.yml had the same shape until #15068.
#
# THE PROPERTY (the deploy gate's two halves, re-cut for a workflow that ALSO
# runs on pull requests, where superseding IS wanted):
#   (a) the group must vary by push sha ON MAIN — an expression that mentions
#       github.sha under a refs/heads/main condition — so two merges are never
#       rivals; PR refs may keep a per-ref group so a newer push supersedes;
#   (b) cancel-in-progress must be the literal boolean false OR the exact
#       never-cancel-main guard `${{ github.ref != 'refs/heads/main' }}` — the
#       shape scripts/never-cancel-main-check.sh accepts. A bare `true` would
#       cancel a running main run and is refused here as it is there.
#
# EXIT CODES
#   0  no main run of the targets can be evicted
#   1  FINDING — one can; the reason is named
#   2  CANNOT MEASURE — no python3/PyYAML, a missing target, no concurrency
#      block, or a bad flag. Never a vacuous green.
#
# USAGE
#   bash scripts/main-run-concurrency-check.sh
#   MAIN_CONCURRENCY_TARGETS="<file> <file>" bash scripts/main-run-concurrency-check.sh
#
# The env override exists ONLY so scripts/deploy-concurrency-check.test.sh
# (PART C) can drive this end-to-end against planted fixtures, including a
# verbatim copy of the pre-fix stanza, which must red. CI leaves it unset.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${1:-}" ]; then
  echo "main-run-concurrency-check: unknown argument '$1' (this gate takes none)" >&2
  echo "  point it at other files with MAIN_CONCURRENCY_TARGETS=\"<path> <path>\"." >&2
  exit 2
fi

TARGETS="${MAIN_CONCURRENCY_TARGETS:-.github/workflows/elixir.yml .github/workflows/doc-gates.yml}"

# NO APOSTROPHES OR BACKTICKS IN THE PYTHON BLOCK (bash 3.2 heredoc-in-subst).
scan() {
  python3 - "$1" <<'PY'
import sys

try:
    import yaml
except ImportError:
    print("HARNESS-UNAVAILABLE: PyYAML not importable; this is NOT a verdict on the workflow")
    sys.exit(2)

path = sys.argv[1]
try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:
    print("HARNESS-UNAVAILABLE: %s did not parse as YAML: %s" % (path, exc))
    sys.exit(2)
if not isinstance(doc, dict):
    print("HARNESS-UNAVAILABLE: %s is not a YAML mapping" % path)
    sys.exit(2)

conc = doc.get("concurrency")
if conc is None:
    print("HARNESS-UNAVAILABLE: %s declares no top-level concurrency block" % path)
    sys.exit(2)
if not isinstance(conc, dict):
    print("HARNESS-UNAVAILABLE: %s concurrency is not a mapping (shorthand string form)" % path)
    sys.exit(2)
group = conc.get("group")
if not isinstance(group, str) or not group.strip():
    print("HARNESS-UNAVAILABLE: %s concurrency.group is missing or not a string" % path)
    sys.exit(2)
cip = conc.get("cancel-in-progress", False)

GUARD = "${{ github.ref != 'refs/heads/main' }}".replace("'", chr(39))
findings = []
if "github.sha" not in group or "refs/heads/main" not in group:
    findings.append(
        "concurrency.group %r is not per push sha on main. GitHub keeps ONE "
        "not-yet-started run per group, so under merge cadence each merge evicts "
        "the pending main run before a runner picks it up (measured 2026-09-02: "
        "37 of 40 main runs cancelled). Expected an expression mentioning "
        "github.sha under a refs/heads/main condition." % group
    )
if cip is not False and (not isinstance(cip, str) or cip.strip() != GUARD):
    findings.append(
        "concurrency.cancel-in-progress is %r, neither the literal false nor the "
        "never-cancel-main guard %r; a bare true cancels a RUNNING main run."
        % (cip, GUARD)
    )

print("target: %s" % path)
print("group: %s" % group)
print("cancel-in-progress: %r" % (cip,))
for f in findings:
    print("FAIL " + f)
if not findings:
    print("OK a queued main run cannot be evicted, and a running one cannot be cancelled")
PY
}

RC=0
SEEN=0
for TARGET in $TARGETS; do
  SEEN=$((SEEN + 1))
  if [ ! -f "$TARGET" ]; then
    echo "main-run-concurrency gate could not RUN: target '$TARGET' is not a file — this is NOT a verdict." >&2
    exit 2
  fi
  SCAN_STATUS=0
  RESULT="$(scan "$TARGET")" || SCAN_STATUS=$?
  if [ "$SCAN_STATUS" -ne 0 ] || grep -q '^HARNESS-UNAVAILABLE' <<<"$RESULT"; then
    echo "main-run-concurrency gate could not RUN on ${TARGET} (harness exit ${SCAN_STATUS}) — this is NOT a verdict." >&2
    echo "${RESULT:-(the harness produced no output)}" >&2
    exit 2
  fi
  echo "$RESULT"
  if grep -q '^FAIL ' <<<"$RESULT"; then RC=1; fi
done

if [ "$SEEN" -eq 0 ]; then
  echo "main-run-concurrency gate could not RUN: no targets — an empty scan is not a pass." >&2
  exit 2
fi

if [ "$RC" -ne 0 ]; then
  echo "" >&2
  echo "main-run-concurrency gate FAILED — a main run of a gate workflow can be evicted by the next merge." >&2
  echo "Fix, in the workflow:" >&2
  echo "    concurrency:" >&2
  # shellcheck disable=SC2016  # literal prose, not substitution
  echo '      group: <name>-${{ github.ref == '"'"'refs/heads/main'"'"' && github.sha || github.ref }}' >&2
  # shellcheck disable=SC2016
  echo '      cancel-in-progress: ${{ github.ref != '"'"'refs/heads/main'"'"' }}' >&2
  exit 1
fi
echo "main-run-concurrency gate OK — ${SEEN} workflow(s) keep one group per main sha and never cancel main."
