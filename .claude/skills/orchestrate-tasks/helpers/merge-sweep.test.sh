#!/usr/bin/env bash
#
# merge-sweep.test.sh — BOTH DIRECTIONS OF THE REVIEW HOLD, IN ONE SWEEP RUN.
#
# WHY IT EXISTS (task-435620b0f02720b2). merge-sweep.sh squash-merges unattended. Until this
# harness there was NO test of the loop at all — only the `--selftest` string table, which never
# executes the arm that decides whether a PR is merged. So the proof this row demands could not
# be produced by anything in the repo: that a PR carrying an open review is REFUSED, and that the
# SAME RUN still merges an otherwise identical PR that carries none. A refusal shown on its own
# is indistinguishable from a sweep that simply stopped working.
#
# THE STUB IS TRANSPORT ONLY. `gh` is replaced by a script that serves the RAW JSON the real API
# returns and then applies the caller's own `--jq` / `-q` filter with real jq. It deliberately does
# NOT pre-select: a stub that answered with the finished string would bypass the very jq in
# merge-sweep.sh that this harness exists to hold. The fixtures are the documented shapes of
#   GET /repos/O/R/pulls            (gh pr list --json …)
#   GET /repos/O/R/pulls/N/requested_reviewers
#   GET /repos/O/R/pulls/N/reviews
#
# THE FIXTURE PAIR IS OTHERWISE IDENTICAL. #101 and #102 differ in exactly one field — #101 has a
# reviewer on its Reviewers list. Same branch prefix, same base, same non-draft state, same title
# with no HOLD/WIP word, same body with a Task: trailer, both MERGEABLE at 4/4. If the harness
# greened because the sweep had stopped merging anything, #102 would fail to appear as MERGED.
#
# AND A CONTROL ON THE CONTROL: #103 carries an unresolved CHANGES_REQUESTED and no pending
# request, so the two hold routes are exercised separately rather than one standing in for both.
#
# MUTATION PROOF (the arm to gut when checking this harness is not vacuous): delete the
# `1) held=...; continue;;` case from merge-sweep.sh's review-hold `case` and this harness must
# RED with "#101 was MERGED"; restore it and it greens.
#
# EXIT: 0 all assertions pass · 1 an assertion failed · 2 the harness could not run (missing tool).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$HERE/merge-sweep.sh"
[ -f "$SWEEP" ] || { echo "CANNOT READ: no merge-sweep.sh beside this harness ($SWEEP)" >&2; exit 2; }
for tool in jq python3; do
  command -v "$tool" >/dev/null || { echo "CANNOT READ: $tool is missing — this harness measured NOTHING" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/orch" "$WORK/fix"

# ── FIXTURES: the RAW payloads, exactly as the API shapes them ────────────────────────────────
cat > "$WORK/fix/pulls.json" <<'JSON'
[
  {"number":101,"headRefName":"gates/reviewed-pr","baseRefName":"main","isDraft":false,
   "title":"fix(gates): a perfectly ordinary change"},
  {"number":102,"headRefName":"gates/unreviewed-pr","baseRefName":"main","isDraft":false,
   "title":"fix(gates): a perfectly ordinary change"},
  {"number":103,"headRefName":"gates/changes-requested-pr","baseRefName":"main","isDraft":false,
   "title":"fix(gates): a perfectly ordinary change"}
]
JSON
# #101 — a reviewer is on the Reviewers list and has not reviewed yet.
echo '{"users":[{"login":"lead-gates"}],"teams":[]}' > "$WORK/fix/requested_reviewers.101.json"
echo '[]'                                            > "$WORK/fix/reviews.101.json"
# #102 — the otherwise identical PR: nobody requested, nothing reviewed.
echo '{"users":[],"teams":[]}'                       > "$WORK/fix/requested_reviewers.102.json"
echo '[]'                                            > "$WORK/fix/reviews.102.json"
# #103 — no pending request, but a reviewer's latest state is still CHANGES_REQUESTED.
echo '{"users":[],"teams":[]}'                       > "$WORK/fix/requested_reviewers.103.json"
cat > "$WORK/fix/reviews.103.json" <<'JSON'
[{"user":{"login":"lead-console"},"state":"COMMENTED","submitted_at":"2026-09-12T01:00:00Z"},
 {"user":{"login":"lead-console"},"state":"CHANGES_REQUESTED","submitted_at":"2026-09-12T02:00:00Z"}]
JSON

# ── THE gh STUB: serve raw JSON, then apply the CALLER'S filter with real jq ──────────────────
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
FIX="${STUB_FIX:?}"
filter=""; prev=""
for a in "$@"; do
  case "$prev" in --jq|-q) filter="$a";; esac
  prev="$a"
done
emit() { # $1 = file of RAW json
  if [ -n "$filter" ]; then jq -r "$filter" < "$1"; else cat "$1"; fi
}
case "${1:-}" in
  pr)
    case "${2:-}" in
      list) emit "$FIX/pulls.json"; exit 0;;
      view)
        n="${3:-}"
        jq --argjson n "$n" '.[]|select(.number==$n)|{title:.title,body:("prose\n\nTask: task-435620b0f02720b2\n")}' < "$FIX/pulls.json"
        exit 0;;
      merge)
        echo "${3:-}" >> "$FIX/merged.txt"; echo "merged"; exit 0;;
    esac;;
  api)
    ep="${2:-}"
    case "$ep" in
      */requested_reviewers) n="${ep%/requested_reviewers}"; n="${n##*/}"; emit "$FIX/requested_reviewers.$n.json"; exit 0;;
      */reviews*)           n="${ep%/reviews*}";            n="${n##*/}"; emit "$FIX/reviews.$n.json";            exit 0;;
    esac;;
esac
echo "STUB: unhandled gh invocation: $*" >&2
exit 9
STUB
chmod +x "$WORK/bin/gh"

# pr-required.sh is NOT the code under test: every fixture PR is green at 4/4 by construction.
cat > "$WORK/orch/pr-required.sh" <<'PRR'
#!/usr/bin/env bash
echo "MERGEABLE 4/4 (fixture)"
PRR

# ── RUN THE SWEEP, ONCE ───────────────────────────────────────────────────────────────────────
: > "$WORK/fix/merged.txt"
out=$(PATH="$WORK/bin:$PATH" STUB_FIX="$WORK/fix" ORCH="$WORK/orch" bash "$SWEEP" FIXTURE/repo 2>&1)
rc=$?
log=$(cat "$WORK/orch/merge-sweep.log" 2>/dev/null || true)
merged_list=$(cat "$WORK/fix/merged.txt" 2>/dev/null || true)

echo "merge-sweep.test.sh — one sweep run over three otherwise identical PRs"
echo "--- sweep stdout (rc=$rc) ---"; printf '%s\n' "$out"
echo "--- merge-sweep.log ---";       printf '%s\n' "$log"
echo "--- PRs the stub was asked to merge ---"; printf '%s\n' "${merged_list:-(none)}"
echo "---"

p=0; f=0
t() { # $1 name, $2 want-yes|want-no, $3 haystack, $4 needle
  local got=no
  case "$3" in *"$4"*) got=yes;; esac
  if [ "$got" = "$2" ]; then p=$((p+1)); echo "  PASS  $1"
  else f=$((f+1)); echo "  FAIL  $1 (wanted $2 for '$4', got $got)"; fi
}

# THE REFUSAL DIRECTION, and it must NAME the signal it read.
t "#101 (pending review request) was NOT merged"      no  "$merged_list" "101"
t "the log HELDs #101"                                yes "$log" "HELD #101"
t "the refusal names the signal it read"              yes "$log" "a pending review request for lead-gates"
# THE SECOND HOLD ROUTE, separately.
t "#103 (unresolved CHANGES_REQUESTED) was NOT merged" no  "$merged_list" "103"
t "the refusal names the reviewer"                     yes "$log" "an unresolved CHANGES_REQUESTED review from lead-console"
# THE SELECTIVITY DIRECTION — same run, otherwise identical PR.
t "#102 (no review signal) WAS merged in the same run" yes "$merged_list" "102"
t "the log MERGEDs #102"                               yes "$log" "MERGED #102"
# The tally must expose the holds rather than fold them into not-yet.
t "the tally reports held-open-review 2"               yes "$out" "held-open-review 2"
t "the tally reports merged 1"                         yes "$out" "merged 1,"
t "nothing was CANNOT READ"                            yes "$out" "CANNOT READ 0"

echo "merge-sweep.test.sh: ${p} passed, ${f} failed"
[ "$f" -eq 0 ] || exit 1
exit 0
