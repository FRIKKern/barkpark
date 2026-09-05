#!/usr/bin/env bash
# stale-verdict-watch.test.sh — the mutation proofs for the stale-verdict watch.
#
# FULLY HERMETIC. Every probe drives scripts/stale-verdict-watch.sh over
# fixtures this harness WRITES ITSELF, with `--fixture` and `--commits`, and
# with `gh` removed from PATH — so "made no API call" is an assertion about
# behaviour, not a claim about control flow.
#
# NOTHING HERE ASSERTS "THE SCRIPT RAN". Each classification is proven by
# MUTATING one field of a base fixture and watching the verdict MOVE, in both
# directions. The four obligations:
#
#   (a) a CONFLICTING PR with a stale green IS reported          → exit 1
#   (b) a MERGEABLE PR merely BEHIND main is NOT reported        → exit 0
#       (main is strict:false; being behind is policy, not a defect)
#   (c) a DUPLICATE-ENTRY PR proves the counting: occurrences-of-SUCCESS
#       reaches the full set and launders a FAILURE out; all-of-present does not
#   (d) an UNKNOWN row beside a classified one is WARNED, never
#       dropped, and the sentence carries its coverage            → exit 2
#  (d2) a run in which NOTHING could be classified is BLIND, and
#       the clean sentence never appears on it                    → exit 5
#   (l) the two TRANSPORT silences are not the warning and not each
#       other: the pull-request list unread                       → exit 6
#       main's commit history unread                              → exit 7
#
# THE REQUIRED SET IS DERIVED, NEVER TYPED. Context names come out of
# .github/required-checks.json at build time, so a renamed context rebuilds
# these fixtures rather than leaving them testing a set this repo stopped having.
#
#   bash scripts/stale-verdict-watch.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$REPO_ROOT/scripts/stale-verdict-watch.sh"
WF="$REPO_ROOT/.github/workflows/stale-verdict-watch.yml"
CONTENDED="$REPO_ROOT/.github/workflows/main-gate-watch.yml"
SPEC="$REPO_ROOT/.github/required-checks.json"
DOC="$REPO_ROOT/docs/ops/merge-gates.md"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok()      { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()     { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
[ -f "$WATCH" ] || { echo "missing $WATCH" >&2; exit 2; }
[ -f "$WF" ]    || { echo "missing $WF" >&2; exit 2; }

# Plain array + `while read`, never `mapfile`: this harness must run on stock
# macOS bash 3.2 as well as on CI's bash 5.
CTX=()
while IFS= read -r line; do
  [ -n "$line" ] && CTX+=("$line")
done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC")
EOF
N="${#CTX[@]}"
[ "$N" -ge 2 ] || { echo "the committed spec lists $N required context(s); these probes need at least 2" >&2; exit 2; }

# A pinned history: ten main commits, all landed AFTER the fixture verdicts
# below. Nothing here depends on the wall clock.
COMMITS="$TMP/commits.txt"
: > "$COMMITS"
# Two commits that predate every fixture verdict. They exist so the window is
# STRICTLY larger than any distance measured below — otherwise every probe would
# saturate the window and the `N+` cap would hide an off-by-one.
echo "2026-06-01T00:00:00Z" >> "$COMMITS"
echo "2026-06-02T00:00:00Z" >> "$COMMITS"
for i in 1 2 3 4 5 6 7 8 9; do
  echo "2026-08-0${i}T00:00:00Z" >> "$COMMITS"
done
echo "2026-08-10T00:00:00Z" >> "$COMMITS"

OLD="2026-07-01T00:00:00Z"    # predates every commit above  → stale
FRESH="2026-08-11T00:00:00Z"  # postdates every commit above → not stale

NOGH="$TMP/nogh"; mkdir -p "$NOGH"
run_watch() { # <fixture> [extra args…]
  local fx="$1"; shift
  env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$WATCH" --fixture "$fx" --commits "$COMMITS" --spec "$SPEC" \
      --repo FRIKKern/barkpark "$@" 2>&1
}

# One PR row. `entries` is a JSON array of {name, conclusion, completedAt}.
pr_row() { # <number> <mergeable> <mergeStateStatus> <entries json>
  jq -c -n --argjson n "$1" --arg m "$2" --arg s "$3" --argjson e "$4" \
    '{number: $n, mergeable: $m, mergeStateStatus: $s,
      headRefOid: "0123456789abcdef0123456789abcdef01234567",
      updatedAt: "2026-08-01T00:00:00Z",
      statusCheckRollup: [ $e[] | {__typename: "CheckRun", name: .name,
                                   status: "COMPLETED", conclusion: .conclusion,
                                   completedAt: .completedAt} ]}'
}

# Every required context, all SUCCESS, all completed at <when>.
full_set() { # <when>
  local when="$1" out="[]" c
  for c in "${CTX[@]}"; do
    out="$(jq -c --arg n "$c" --arg t "$when" '. + [{name: $n, conclusion: "SUCCESS", completedAt: $t}]' <<<"$out")"
  done
  printf '%s' "$out"
}

fixture() { # <path> <row json…>  — assembles a PR-list payload
  local path="$1"; shift
  printf '%s\n' "$@" | jq -s -c '.' > "$path"
}

# ═══ (a) a conflicted PR with a stale green IS reported ══════════════════════
section "(a) CONFLICTING + stale green → reported, exit 1"

fixture "$TMP/a.json" "$(pr_row 9001 CONFLICTING DIRTY "$(full_set "$OLD")")"
out="$(run_watch "$TMP/a.json")"; rc=$?
[ "$rc" = "1" ] && ok "exit 1 (red)" || bad "expected exit 1, got $rc"
grep -q "#9001" <<<"$out" && ok "#9001 is named in the verdict" || bad "#9001 missing from the verdict"
grep -q "STALE: ${CTX[0]} passed at $OLD, 10 commit(s)" <<<"$out" \
  && ok "the staleness distance is counted from main's history (10 commits)" \
  || bad "no staleness distance for ${CTX[0]}"

# THE MUTATION: move the same green AFTER every main commit. Nothing else
# changes — same PR, same CONFLICTING state, same required set.
fixture "$TMP/a-fresh.json" "$(pr_row 9001 CONFLICTING DIRTY "$(full_set "$FRESH")")"
out="$(run_watch "$TMP/a-fresh.json")"; rc=$?
[ "$rc" = "0" ] && ok "mutation: a green newer than every main commit is NOT stale (exit 0)" \
  || bad "mutation: expected exit 0 for a fresh green, got $rc — the completedAt comparison does nothing"
grep -q "^ok — no CONFLICTING" <<<"$out" && ok "mutation: the clean verdict says so plainly" || bad "mutation: no clean verdict line"

# ═══ (b) merely BEHIND main is not a defect ══════════════════════════════════
section "(b) MERGEABLE but behind main (strict:false) → NOT reported, exit 0"

fixture "$TMP/b.json" "$(pr_row 9002 MERGEABLE BEHIND "$(full_set "$OLD")")"
out="$(run_watch "$TMP/b.json")"; rc=$?
[ "$rc" = "0" ] && ok "exit 0 — being behind main is what strict:false permits" || bad "expected exit 0, got $rc"
grep -q "RED" <<<"$out" && bad "a merely-behind PR was reported RED" || ok "#9002 is not reported"
grep -q "1 MERGEABLE" <<<"$out" && ok "it is still COUNTED in the population" || bad "the population dropped the mergeable row"

# THE MUTATION, AND IT IS THE ONE THAT MATTERS: the ONLY field that changes is
# mergeable. A verdict that ignores mergeability would pass probe (b) by
# accident — this proves it does not.
fixture "$TMP/b-conflict.json" "$(pr_row 9002 CONFLICTING DIRTY "$(full_set "$OLD")")"
out="$(run_watch "$TMP/b-conflict.json")"; rc=$?
[ "$rc" = "1" ] && ok "mutation: the SAME row flipped to CONFLICTING IS reported (exit 1)" \
  || bad "mutation: expected exit 1 when mergeable flips to CONFLICTING, got $rc — probe (b) proves nothing"

# ═══ (c) all-of-present, never occurrences-of-SUCCESS ════════════════════════
section "(c) duplicate entries: the occurrence count launders a FAILURE, all-of-present does not"

# #10722's real shape, reduced: every required context green ONCE, plus a second
# entry for the LAST context that FAILED. Occurrences of SUCCESS = N, which
# reaches the full set. All-of-present = N-1, because that context has an entry
# that is not SUCCESS.
dup="$(jq -c --arg n "${CTX[$((N - 1))]}" --arg t "$OLD" \
        '. + [{name: $n, conclusion: "FAILURE", completedAt: $t}]' <<<"$(full_set "$OLD")")"
fixture "$TMP/c.json" "$(pr_row 9003 CONFLICTING DIRTY "$dup")"
out="$(run_watch "$TMP/c.json")"; rc=$?
grep -q "all-of-present (this verdict): 0 " <<<"$out" \
  && ok "all-of-present says 0 assert a full $N-of-$N" \
  || bad "all-of-present did not say 0: $(grep 'all-of-present' <<<"$out")"
grep -q "occurrences-of-SUCCESS (WRONG): 1 — over-reports by 1 (#9003)" <<<"$out" \
  && ok "the occurrence count is shown reporting 1, and named as the over-report" \
  || bad "the side-by-side counting is missing: $(grep 'occurrences' <<<"$out")"
if grep -qE "(FAILURE\+SUCCESS|SUCCESS\+FAILURE)" <<<"$out"; then
  ok "the laundered FAILURE is printed on the context line, not swallowed"
else
  bad "the duplicate entry's FAILURE never appears in the report"
fi
[ "$rc" = "1" ] && ok "the row is still red on its OTHER stale greens (exit 1)" || bad "expected exit 1, got $rc"

# THE MUTATION: drop the duplicate FAILURE. The two countings must now AGREE.
fixture "$TMP/c-nodup.json" "$(pr_row 9003 CONFLICTING DIRTY "$(full_set "$OLD")")"
out="$(run_watch "$TMP/c-nodup.json")"
grep -q "all-of-present (this verdict): 1 " <<<"$out" \
  && grep -q "occurrences-of-SUCCESS (WRONG): 1 — no duplicate-entry rows" <<<"$out" \
  && ok "mutation: without the duplicate, both countings agree at 1 — the gap is the duplicate, not a constant" \
  || bad "mutation: the two countings did not converge when the duplicate was removed"

# ═══ (d) PARTIAL coverage: UNKNOWN is a warning row, never an omission ═══════
section "(d) PARTIAL — an UNKNOWN row beside a classified one → warned, never dropped, exit 2"

# This fixture used to be a SINGLE all-UNKNOWN row, which is not the warning
# case at all — it is the BLIND case, and it was asserting exit 2 (a code the
# workflow maps to success). It is split in two: PARTIAL here, where something
# WAS classified and the run can legitimately speak about what it read, and
# TOTAL in (d2), where nothing was.
fixture "$TMP/d.json" \
  "$(pr_row 9004 UNKNOWN UNKNOWN "$(full_set "$OLD")")" \
  "$(pr_row 9010 MERGEABLE CLEAN "$(full_set "$FRESH")")"
out="$(run_watch "$TMP/d.json")"; rc=$?
[ "$rc" = "2" ] && ok "exit 2 — not green, not red: partially classified" || bad "expected exit 2, got $rc"
grep -q "WARNING ROWS" <<<"$out" && ok "a WARNING ROWS block is printed" || bad "no WARNING ROWS block"
grep -q "? #9004" <<<"$out" && ok "#9004 is named — the naive CONFLICTING filter would have dropped it silently" \
  || bad "#9004 was dropped from the report"
grep -q "1 UNKNOWN after re-polling" <<<"$out" && ok "the population counts it as UNKNOWN" || bad "the population hid the UNKNOWN row"
grep -q "^INCONCLUSIVE — classified 1 of 2 open" <<<"$out" \
  && ok "the sentence carries its coverage (classified 1 of 2 open), so the conclusion cannot be read without it" \
  || bad "the partial run's sentence does not carry its coverage: $(grep -E '^(ok|RED|BLIND|INCONCLUSIVE)' <<<"$out")"
grep -q "^ok — no CONFLICTING" <<<"$out" \
  && bad "the clean sentence was printed by a run that left a row unread" \
  || ok "…and the clean sentence is absent while any row went unread"

# THE MUTATION: a red alongside an unknown must still read RED — the warning
# lane must not be able to downgrade a real finding.
fixture "$TMP/d-mixed.json" \
  "$(pr_row 9004 UNKNOWN UNKNOWN "$(full_set "$OLD")")" \
  "$(pr_row 9005 CONFLICTING DIRTY "$(full_set "$OLD")")"
out="$(run_watch "$TMP/d-mixed.json")"; rc=$?
[ "$rc" = "1" ] && ok "mutation: red wins over unknown (exit 1)" || bad "mutation: expected exit 1, got $rc"
grep -q "? #9004" <<<"$out" && ok "mutation: the unknown row is STILL printed next to the red" || bad "mutation: the unknown row vanished once a red existed"

# ═══ (d2) a run that classified NOTHING is BLIND, never green ════════════════
section "(d2) TOTAL — every row UNKNOWN → BLIND, exit 5, and no clean sentence"

# THE DEFECT THIS OWNS. Of the 19 runs this workflow has ever had, exactly one
# push run concluded success: 31311358759, which classified 0 of 39 rows, printed
# `ok — no CONFLICTING pull request is asserting…` and exited 0 via the rc=2 arm
# — 68 seconds before a 23-row RED run on the same tree. The population line and
# all 39 row names DID print; what lied was the SENTENCE and the CONCLUSION,
# which are the only two things a human skimming a green check reads.
fixture "$TMP/d-blind.json" \
  "$(pr_row 9004 UNKNOWN UNKNOWN "$(full_set "$OLD")")" \
  "$(pr_row 9011 UNKNOWN UNKNOWN "$(full_set "$OLD")")"
out="$(run_watch "$TMP/d-blind.json")"; rc=$?
[ "$rc" = "5" ] && ok "exit 5 — 0 of 2 rows classified is BLIND, a code of its own" \
  || bad "expected exit 5 for an all-UNKNOWN population, got $rc — a run that classified nothing still exits through an arm the workflow maps to success"
grep -q "^BLIND — classified 0 of 2 open" <<<"$out" \
  && ok 'the sentence says BLIND and carries "classified 0 of 2 open"' \
  || bad "no BLIND sentence with its coverage: $(grep -E '^(ok|RED|BLIND|INCONCLUSIVE)' <<<"$out")"
grep -q "^ok — no CONFLICTING" <<<"$out" \
  && bad "the clean sentence was printed by a run that classified NOTHING — that is run 31311358759's exact false green, reproduced" \
  || ok "the clean sentence never appears on a blind run"
grep -q "2 open · 0 CONFLICTING · 0 MERGEABLE · 2 UNKNOWN" <<<"$out" \
  && ok "the population line still prints in full (it always did — the fix is the sentence and the conclusion, not the denominator)" \
  || bad "the population line changed shape: $(grep 'open ·' <<<"$out")"
grep -q "? #9004" <<<"$out" && grep -q "? #9011" <<<"$out" \
  && ok "both unread rows are still named individually" || bad "a blind run dropped its rows from the report"

# THE MUTATION: classify ONE of the two rows and nothing else. The blind verdict
# must collapse to the partial one — proving 5 tracks coverage, not row count.
fixture "$TMP/d-blind-one.json" \
  "$(pr_row 9004 UNKNOWN UNKNOWN "$(full_set "$OLD")")" \
  "$(pr_row 9011 MERGEABLE CLEAN "$(full_set "$OLD")")"
out="$(run_watch "$TMP/d-blind-one.json")"; rc=$?
[ "$rc" = "2" ] && ok "mutation: one classified row demotes BLIND to the exit-2 warning" \
  || bad "mutation: expected exit 2 once a row was classified, got $rc — 5 is not tracking coverage"

# The workflow must ANSWER a 5, and it must fail the run. Without this arm the
# `*)` fallthrough would call it "not a verdict it defines".
grep -qE '^\s+5\) echo "::error::BLIND RUN' "$WF" \
  && ok "the workflow has its own 5) arm and sentence for BLIND" \
  || bad "the workflow has no 5) arm — a blind run would fall through to the undefined-verdict branch"
grep -qE '^\s+5\) echo .*exit 1 ;;' "$WF" \
  && ok "…and arm 5 exits 1, so a blind run can no longer conclude success" \
  || bad "arm 5 does not exit 1 — the blind run still reports green"
grep -q "^#             5 = BLIND" "$WATCH" \
  && ok "the script's own EXIT CODES header documents 5 where the arms are defined" \
  || bad "EXIT CODES header does not document 5"

# Arm 5's copy is NOT arm 1's. An exit-1 stale green cannot clear itself and
# says so; a blind read is transient and the next run re-reads it. Copying arm
# 1's sentence here would teach the reader to ignore a self-clearing alarm.
arm5="$(grep -E '^\s+5\) echo' "$WF")"
grep -q "keep failing every 30 minutes" <<<"$arm5" \
  && bad "arm 5 repeats arm 1's 'it will keep failing every 30 minutes' — a blind read self-clears on the next poll" \
  || ok "arm 5 does not repeat arm 1's 'keep failing every 30 minutes'"
grep -qi "clears this by itself" <<<"$arm5" && grep -qi "PERSISTS" <<<"$arm5" \
  && ok "…it says the next run re-reads and clears this by itself, and that a PERSISTENT 5 means the read is broken" \
  || bad "arm 5 does not distinguish a transient blind read from a persistently broken one: $arm5"

# ═══ (e) the population is re-derived, never baked ═══════════════════════════
section "(e) the population is derived from the payload at run time"

fixture "$TMP/e.json" \
  "$(pr_row 9006 CONFLICTING DIRTY "$(full_set "$FRESH")")" \
  "$(pr_row 9007 MERGEABLE CLEAN "$(full_set "$FRESH")")" \
  "$(pr_row 9008 MERGEABLE CLEAN "$(full_set "$FRESH")")"
out="$(run_watch "$TMP/e.json")"
grep -q "3 open · 1 CONFLICTING · 2 MERGEABLE · 0 UNKNOWN" <<<"$out" \
  && ok "the counts follow the payload (3/1/2/0)" \
  || bad "the population line did not follow the payload: $(grep 'open ·' <<<"$out")"
grep -qE "(^|[^0-9])(40|22) open" <<<"$out" && bad "a baked live number leaked into a fixture run" \
  || ok "no live number is baked into the verdict"

# ═══ (f) the partial class the N-of-N framing hides ══════════════════════════
section "(f) a PR where required contexts NEVER RENDERED is not laundered into 'clean'"

one="$(jq -c --arg n "${CTX[0]}" --arg t "$OLD" -n '[{name: $n, conclusion: "SUCCESS", completedAt: $t}]')"
fixture "$TMP/f.json" "$(pr_row 9009 CONFLICTING DIRTY "$one")"
out="$(run_watch "$TMP/f.json")"
grep -q "PARTIAL CLASS (the $N-of-$N framing hides these): #9009 1-of-1 rendered" <<<"$out" \
  && ok "the 1-of-1 class (#6057/#6086's shape) is called out separately" \
  || bad "the partial class was not reported: $(grep 'PARTIAL' <<<"$out")"
grep -q "NEVER RENDERED" <<<"$out" && ok "the absent contexts are printed as NEVER RENDERED" || bad "absent contexts were not disclosed"

# ═══ (g) the workflow's own discipline ═══════════════════════════════════════
section "(g) the workflow file cannot launder its own scream"

grep -qE '^[[:space:]]*continue-on-error' "$WF" && bad "continue-on-error appears in $WF — a scream nobody is paged for is not a scream" \
  || ok "no continue-on-error anywhere in the workflow"
grep -qE '^\s*- cron: "\*/30 \* \* \* \*"' "$WF" && ok "level-triggered: */30 cron" || bad "no */30 cron — this would be an edge trigger"
grep -q "workflow_dispatch:" "$WF" && ok "workflow_dispatch is available for an on-demand read" || bad "no workflow_dispatch"
grep -q "if: github.event_name != 'pull_request'" "$WF" \
  && ok "the watch job never renders on a PR head, so its name can never enter the required set" \
  || bad "the watch job lacks the pull_request guard"
grep -q "pull-requests: read" "$WF" && ok "permissions carry pull-requests: read (the read this verdict needs)" || bad "no pull-requests: read in permissions"
grep -q "checks: read" "$WF" && ok "permissions carry checks: read" || bad "no checks: read in permissions"
grep -q "contents: read" "$WF" && ok "permissions carry contents: read" || bad "no contents: read in permissions"

# The contended file. cchi-w60-main-gate-watch-push-arm-cannot-win has a live
# builder inside main-gate-watch.yml; this slice must not have touched it.
# `command -v git` and the file existing are NOT enough: inside a `git archive`
# extraction both hold and there is still no repository, so `git diff` exits 128
# and the else-branch accused this slice of touching a file it cannot even see
# the history of (measured: 52 passed / 1 failed from an archive, 53 / 0 from a
# checkout). The absence of a worktree is now STATED rather than assumed.
if command -v git >/dev/null 2>&1 && [ -f "$CONTENDED" ] \
   && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" diff --quiet HEAD -- ".github/workflows/main-gate-watch.yml" 2>/dev/null; then
    ok "the contended .github/workflows/main-gate-watch.yml is untouched by this slice"
  else
    bad "this slice modified the CONTENDED main-gate-watch.yml — that is the co-scoped-fixes trap"
  fi
else
  ok "contended-file probe SKIPPED: $REPO_ROOT carries no git worktree (an archive extraction has no history to diff against) — this is a skip, not a pass of the check"
fi

# ═══ (h) the doc records the present-but-stale-pass case ═════════════════════
section "(h) docs/ops/merge-gates.md carries the present-but-stale-pass case"

if grep -qi "stale" "$DOC" && grep -q "stale-verdict-watch" "$DOC"; then
  ok "merge-gates.md names the stale-pass case and points at this watch"
else
  bad "merge-gates.md does not carry the present-but-stale-pass case"
fi

# ═══ (j) the compute fault does not wear the credential fault's name ═════════
section "(j) rc=3 is credential/spec ONLY; the compute fault has its own code"

# For one release EVERY fault returned 3, and the workflow answered all of them
# with "this run's credential cannot read the pull-request list". The 380 KB
# E2BIG death was reported that way while the credential had just read 40 PRs
# perfectly. Not one of the probes above ever exercised exit 3 — the arm that
# mis-fired was the single arm with no mutation proof. These two probes are that
# proof, and they are what makes the split observable rather than merely typed.

# j: an unreadable SPEC is a spec fault → 3, and it says so.
out="$(run_watch "$TMP/a.json" --spec "$TMP/no-such-spec.json")"; rc=$?
[ "$rc" = "3" ] && ok "an unreadable spec exits 3 (configuration)" || bad "expected exit 3 for an unreadable spec, got $rc"
grep -q "cannot read the required-check spec" <<<"$out" \
  && ok "…and names the spec, not the payload" || bad "the spec fault did not name the spec: $out"

# j: a payload that was READ but cannot be parsed is a COMPUTE fault → 4.
printf 'this is not json, and it is 100%% readable\n' > "$TMP/j-broken.json"
out="$(run_watch "$TMP/j-broken.json")"; rc=$?
[ "$rc" = "4" ] && ok "an unparseable payload exits 4 (compute), NOT 3" \
  || bad "expected exit 4 for an unparseable payload, got $rc — the compute fault is still wearing the credential fault's code"
grep -q "COMPUTE FAULT" <<<"$out" && ok "…and the sentence says COMPUTE FAULT" || bad "no COMPUTE FAULT sentence: $out"
grep -qiE "credential (can|could) ?not|cannot (read|list) (the )?pull.request" <<<"$out" \
  && bad "the compute fault still claims the credential could not read — that is the exact false sentence this slice removes" \
  || ok "…and never claims the credential could not read (it had just read the payload)"
grep -qE "was READ \([0-9]+ bytes\)" <<<"$out" \
  && ok "…and reports the bytes it successfully read, so 'it could not read' is refutable from the log" \
  || bad "the compute fault does not report the payload size: $out"

# The two codes must be documented where they are defined, or the doc drifts
# off the arms exactly as it did before.
grep -q "^#             4 = COMPUTE fault" "$WATCH" && ok "the script's own EXIT CODES header documents 4" \
  || bad "EXIT CODES header does not document 4"
grep -q "^#             3 = CONFIGURATION fault" "$WATCH" && ok "…and still documents 3 as configuration" \
  || bad "EXIT CODES header lost its 3"
grep -qE '^\s+4\) echo "::error::COMPUTE FAULT' "$WF" && ok "the workflow has its own arm and sentence for 4" \
  || bad "the workflow has no 4) arm — an undefined-verdict fallthrough would call it 'not a verdict it defines'"
grep -qE '^\s+3\) echo "::error::CONFIGURATION FAULT' "$WF" && ok "…and the 3 arm still speaks about the credential" \
  || bad "the workflow lost its 3 arm"

# ═══ (k) the payload is too big for argv, on BOTH kernels, and still computes ═
section "(k) a payload above Linux MAX_ARG_STRLEN *and* macOS's total argv still computes"

# THE BUG THIS OWNS. scripts/stale-verdict-watch.sh:286 used to hand the whole
# PR list to jq as ONE argv word. Linux caps a single argv string at
# MAX_ARG_STRLEN = 32 * PAGE_SIZE = 131072 bytes — independent of ARG_MAX
# (2097152 on the same box), which is why the number an author checks says
# there is room. The live 380699-byte payload was 2.9x over, execve failed
# E2BIG, and every Linux run of this watch died before it classified anything.
#
# A 200 KB fixture would pass vacuously on a developer's Mac, which has no
# per-argument cap — that blind spot is exactly how this shipped. So the bound
# here is 1.1 MiB: above Linux's per-arg cap AND above macOS's ~1 MiB TOTAL
# argv, so the probe is able to fail on both kernels. It is GENERATED, never
# committed, and it asserts its own size so quietly shrinking it is a failure.
MAX_ARG_STRLEN=131072
SCALE_MIN=1153434   # 1.1 MiB
BIG="$TMP/k-big.json"
BIG_COMMITS="$TMP/k-commits.txt"

# Realistic bulk: the required set (some rows stale, some fresh) plus the long
# tail of non-required check runs a real PR carries.
rows=140
while :; do
  jq -c -n --argjson req "$(printf '%s\n' "${CTX[@]}" | jq -R . | jq -s -c .)" \
     --arg old "$OLD" --arg fresh "$FRESH" --argjson rows "$rows" '
    [ range(0; $rows) as $i
      | { number: (20000 + $i),
          mergeable: (if $i % 4 == 0 then "CONFLICTING" else "MERGEABLE" end),
          mergeStateStatus: (if $i % 4 == 0 then "DIRTY" else "CLEAN" end),
          headRefOid: ("0123456789abcdef0123456789abcdef" + (1000000 + $i | tostring)),
          updatedAt: "2026-08-01T00:00:00Z",
          statusCheckRollup:
            ( [ $req[] | { __typename: "CheckRun", name: ., status: "COMPLETED",
                           conclusion: "SUCCESS",
                           completedAt: (if $i % 4 == 0 then $old else $fresh end),
                           detailsUrl: "https://github.com/FRIKKern/barkpark/actions/runs/00000000000/job/00000000000" } ]
              + [ range(0; 44) as $k
                  | { __typename: "CheckRun",
                      name: ("advisory-context-\($k)-a-realistically-long-workflow-job-name"),
                      status: "COMPLETED", conclusion: "SUCCESS",
                      completedAt: $fresh,
                      detailsUrl: "https://github.com/FRIKKern/barkpark/actions/runs/00000000000/job/00000000000" } ] ) } ]' \
    > "$BIG"
  [ "$(wc -c < "$BIG" | tr -d ' ')" -ge "$SCALE_MIN" ] && break
  rows=$((rows * 2))
  [ "$rows" -gt 20000 ] && break
done

# The commits payload was the SECOND argv word (`--argjson commits`): 6901 bytes
# at COMMIT_PAGES=3 today, breaching the same ceiling at roughly
# COMMIT_PAGES >= 54. It is moved off argv too, so it is sized past the cap here.
: > "$BIG_COMMITS"
i=0
while [ "$i" -lt 9000 ]; do
  printf '2026-07-%02dT%02d:%02d:00Z\n' $(( (i % 28) + 1 )) $(( (i / 60) % 24 )) $(( i % 60 )) >> "$BIG_COMMITS"
  i=$((i + 1))
done

big_bytes="$(wc -c < "$BIG" | tr -d ' ')"
commit_bytes="$(wc -c < "$BIG_COMMITS" | tr -d ' ')"
[ "${big_bytes:-0}" -ge "$SCALE_MIN" ] \
  && ok "the generated PR payload is ${big_bytes}B ≥ ${SCALE_MIN}B — over Linux's ${MAX_ARG_STRLEN}B per-arg cap AND over macOS's ~1 MiB total argv" \
  || bad "the scale fixture is only ${big_bytes}B — below the ${SCALE_MIN}B bound this probe exists to cross"
[ "${commit_bytes:-0}" -gt "$MAX_ARG_STRLEN" ] \
  && ok "the generated commits payload is ${commit_bytes}B — over the ${MAX_ARG_STRLEN}B per-arg cap too (the second argv word)" \
  || bad "the commits fixture is only ${commit_bytes}B — it does not cross the cap"

out="$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$WATCH" --fixture "$BIG" --commits "$BIG_COMMITS" --spec "$SPEC" \
          --repo FRIKKern/barkpark 2>&1)"; rc=$?
grep -qi "Argument list too long" <<<"$out" \
  && bad "execve E2BIG: a payload still travels by argv (this is the original defect, reproduced)" \
  || ok "no 'Argument list too long' — nothing large travels by argv any more"
[ "$rc" = "1" ] \
  && ok "the verdict COMPUTES over the oversized payload and reds on its stale greens (exit 1)" \
  || bad "expected exit 1 over the scale fixture, got $rc — on Linux the pre-fix script died here with a false credential message"
conf=$(( (rows + 3) / 4 ))
grep -q "$rows open · $conf CONFLICTING" <<<"$out" \
  && ok "…over the WHOLE population ($rows open · $conf CONFLICTING), not a truncated prefix" \
  || bad "the population line does not match the generated fixture: $(grep 'open ·' <<<"$out")"
grep -q "STALE: ${CTX[0]} passed at $OLD" <<<"$out" \
  && ok "…and the staleness distance is measured against the oversized commit history" \
  || bad "no staleness line over the scale fixture"

# THE TRANSPORT ITSELF, asserted structurally: a future edit that puts either
# payload back on the command line reds here even where the kernel would allow
# it (a Mac, a small population), which is the case this watch could not see.
grep -qE -- '^[^#]*--argjson (prs|commits) ' "$WATCH" \
  && bad "a payload is back on argv (--argjson prs/commits) — that is the E2BIG defect returning" \
  || ok "no payload travels by --argjson; only small scalars do"
grep -q -- '--slurpfile prs_in' "$WATCH" && grep -q -- '--slurpfile commits_in' "$WATCH" \
  && ok "both payloads travel by --slurpfile from a file (honest-gates D44's ratified idiom)" \
  || bad "the payloads are not on --slurpfile"

# ═══ (l) rc=2's overload is split into 6 = UNREACHABLE and 7 = DISTANCE ══════
section "(l) transport silence gets its own codes — (e) exit 6, (f) exit 7, (g) the workflow answers both"

# THE DEFECT THIS OWNS (charter D513). rc=2 returned from THREE conditions of
# two different kinds, and the workflow mapped all three to exit 0: the PR list
# never being read at all (zero coverage), main's commit history never being
# read (population known, distance unknown), and the genuine "some rows are
# still UNKNOWN" warning — the only one the rc=2 sentence ever described.
# Both silences reproduce with nothing but a PATH that has no `gh` on it, which
# is what run_watch already builds. The letters (e)/(f)/(g) here are the ones
# the slice brief names; the earlier sections in this file use them for their
# own probes, so they are qualified as (l-e)/(l-f)/(l-g) rather than colliding.

# (l-e) NO --fixture: every poll must reach `gh`, which is not on PATH.
out="$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" SVW_RETRY_SLEEP="0 0 0" \
        bash "$WATCH" --spec "$SPEC" --repo FRIKKern/barkpark --attempts 1 2>&1)"; rc=$?
[ "$rc" = "6" ] && ok "(l-e) the pull-request list being unreadable exits 6 (UNREACHABLE), not the rc=2 warning the workflow maps to success" \
  || bad "(l-e) expected exit 6 when the PR list was never read, got $rc — a run with ZERO coverage still leaves through the partial-coverage warning"
grep -q "UNREACHABLE" <<<"$out" && ok "(l-e) …and says UNREACHABLE, naming the zero coverage" \
  || bad "(l-e) no UNREACHABLE sentence: $out"
grep -qi "classified nothing" <<<"$out" \
  && ok "(l-e) …and states it classified nothing, so the log cannot be read as a clean population" \
  || bad "(l-e) the unreachable sentence does not say it classified nothing: $out"

# (l-f) --fixture PRESENT, --commits omitted: the population is read from the
# fixture and only the commits call reaches the absent `gh`.
out="$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$WATCH" --fixture "$TMP/a.json" --spec "$SPEC" --repo FRIKKern/barkpark 2>&1)"; rc=$?
[ "$rc" = "7" ] && ok "(l-f) an unreadable commit history exits 7 (DISTANCE UNREADABLE), a different code from the unreadable population" \
  || bad "(l-f) expected exit 7 when only main's commit history was unreadable, got $rc"
grep -q "DISTANCE UNREADABLE" <<<"$out" && ok "(l-f) …and says DISTANCE UNREADABLE" \
  || bad "(l-f) no DISTANCE UNREADABLE sentence: $out"
grep -q "^ok — no CONFLICTING" <<<"$out" \
  && bad "(l-f) a run that could not measure any distance printed the clean sentence — that is the manufactured clean verdict this early return exists to prevent" \
  || ok "(l-f) …and never prints the clean sentence: the early return did not fall through into an empty commit window"

# The fall-through this must never become: with an empty commit history every
# `since` is 0 and MIN_COMMITS=1 drops every stale green. Proven by handing the
# script an EMPTY commits fixture — the same state a fall-through would produce
# — over the fixture that reds at exit 1 with a real history.
: > "$TMP/l-empty-commits.txt"
out="$(run_watch "$TMP/a.json" --commits "$TMP/l-empty-commits.txt")"; rc=$?
[ "$rc" = "0" ] \
  && ok "(l-f) an EMPTY commit window turns the same red fixture green (exit 0) — which is exactly why 7 returns early instead of continuing" \
  || bad "(l-f) expected exit 0 over an empty commit window (got $rc); if that is no longer the fall-through outcome, re-derive why 7 must return early"

# (l-g) an argument fault must not wear transport silence's name either.
out="$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$WATCH" --spec "$SPEC" --repo FRIKKern/barkpark --attempts 0 2>&1)"; rc=$?
[ "$rc" = "3" ] && ok "(l-g) --attempts 0 exits 3 at the argv parse (configuration), not silently through the transport code" \
  || bad "(l-g) expected exit 3 for --attempts 0, got $rc — a run that never polled reported itself as a run that was not answered"
grep -q -- "--attempts must be at least 1" <<<"$out" \
  && ok "(l-g) …and the error line names the ARGUMENT; it used to print the transport sentence ('could not list pull requests after 0 attempts'), blaming a read that never happened" \
  || bad "(l-g) --attempts 0 did not name the argument: '$out'"
out="$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$WATCH" --spec "$SPEC" --repo FRIKKern/barkpark --attempts three 2>&1)"; rc=$?
[ "$rc" = "3" ] && grep -q -- "--attempts must be a positive integer" <<<"$out" \
  && ok "(l-g) a non-numeric --attempts exits 3 and names the argument" \
  || bad "(l-g) a non-numeric --attempts did not exit 3 with a message: rc=$rc '$out'"

# (l-g) the workflow must ANSWER both codes, and both must FAIL the run. This
# is the half of the defect the script alone cannot fix: rc=2 was mapped to
# exit 0 under a sentence that itself reads "That is a SILENCE, not a green."
grep -qE '^\s+6\) echo "::error::UNREACHABLE' "$WF" \
  && ok "(l-g) the workflow has its own 6) arm for UNREACHABLE" \
  || bad "(l-g) the workflow has no 6) arm — an unreachable run would fall through to the undefined-verdict branch"
grep -qE '^\s+6\) echo .*exit 1 ;;' "$WF" && ok "(l-g) …and arm 6 exits 1" \
  || bad "(l-g) arm 6 does not exit 1 — a run that read nothing still reports green"
grep -qE '^\s+7\) echo "::error::DISTANCE UNREADABLE' "$WF" \
  && ok "(l-g) the workflow has its own 7) arm for DISTANCE UNREADABLE" \
  || bad "(l-g) the workflow has no 7) arm"
grep -qE '^\s+7\) echo .*exit 1 ;;' "$WF" && ok "(l-g) …and arm 7 exits 1" \
  || bad "(l-g) arm 7 does not exit 1"
arm6="$(grep -E '^\s+6\) echo' "$WF")"
arm7="$(grep -E '^\s+7\) echo' "$WF")"
grep -qi "poll budget" <<<"$arm6" && grep -qi "commits api" <<<"$arm7" \
  && ok "(l-g) the two arms name DIFFERENT remedies (the poll budget vs the commits API) — which is why they are two codes" \
  || bad "(l-g) the 6 and 7 arms do not name distinct remedies: 6='$arm6' 7='$arm7'"
grep -qi "credential" <<<"$arm7" && grep -qi "that read worked" <<<"$arm7" \
  && ok "(l-g) …and arm 7 refuses the credential explanation, because the PR read succeeded" \
  || bad "(l-g) arm 7 does not rule out a credential fault on the PR read: $arm7"

# Arm 2 keeps its exit 0 — it is the genuine partial-coverage warning — but it
# must no longer claim to cover the read that never happened.
arm2="$(grep -E '^\s+2\) echo' "$WF")"
grep -q "could not be read" <<<"$arm2" \
  && bad "arm 2 still says the pull-request list could not be read — that condition is exit 6 now, and arm 2 concludes SUCCESS" \
  || ok "arm 2 no longer claims to cover an unread pull-request list"
grep -q "exit 0 ;;" <<<"$arm2" && ok "…and arm 2 keeps exit 0: partial coverage really is a warning" \
  || bad "arm 2 no longer exits 0: $arm2"

# The codes must be documented where they are defined, or the header drifts off
# the arms exactly as the 3/4 split did before it.
grep -q "^#             6 = UNREACHABLE" "$WATCH" && ok "the script's EXIT CODES header documents 6" \
  || bad "EXIT CODES header does not document 6"
grep -q "^#             7 = DISTANCE UNREADABLE" "$WATCH" && ok "…and documents 7" \
  || bad "EXIT CODES header does not document 7"
grep -q "^#             2 = no red, but SOME rows stayed UNKNOWN after re-polling while" "$WATCH" \
  && ok "…and 2's wording is TIGHTENED to partial coverage, which is all it still means" \
  || bad "the EXIT CODES header still describes 2 loosely enough to re-absorb the silences"

# ═══ (m) the TREND: the red carries its movement, and an unread run is UNREAD ═
section "(m) trend — the count's movement since the last READ run (dr-w29)"

# THE DEFECT THIS OWNS. The watch's red printed the same sentence at 3 reported
# rows and at 30, with no way to tell a growing backlog from a stuck one — and
# any notion of "unchanged since last run" would silently have compared against
# runs that never read (cancelled mid-poll, or BLIND). The trend's baseline is
# the last READ line of a state file; a run that did not read leaves a dangling
# START, which is COUNTED and SAID as UNREAD, never treated as a baseline.
# Everything below runs under run_watch's gh-stripped PATH: the trend makes no
# network call, ever.

# (m1) no state file: the trend states its own absence, and no baseline is invented.
out="$(run_watch "$TMP/a.json")"; rc=$?
grep -q "TREND: no state file configured" <<<"$out" \
  && ok "(m1) with no state file the trend says so — movement is UNKNOWN, not zero" \
  || bad "(m1) no absence sentence without a state file: $out"

# (m2) a red run carries count + movement against the last READ baseline.
ST="$TMP/m-state-baseline.txt"
printf 'READ 2026-08-10T00:00:00Z reported=3 classified=5 open=5\n' > "$ST"
out="$(run_watch "$TMP/a.json" --state-file "$ST")"; rc=$?
[ "$rc" = "1" ] && ok "(m2) the trend does not change the verdict (still exit 1)" \
  || bad "(m2) expected exit 1, got $rc"
grep -q "TREND: reported 1 — was 3 at 2026-08-10T00:00:00Z (moved -2 since the last READ run)" <<<"$out" \
  && ok "(m2) the red carries the count AND its movement — a shrinking backlog reads as -2" \
  || bad "(m2) no movement line against the READ baseline: $out"
grep -q "^READ .* reported=1 " <<<"$(cat "$ST")" \
  && ok "(m2) …and this run, which READ, appended its own READ line for the next baseline" \
  || bad "(m2) the reading run left no READ line: $(cat "$ST")"

# (m3) a CANCELLED predecessor is a dangling START: counted UNREAD, never a baseline.
ST="$TMP/m-state-cancelled.txt"
printf 'READ 2026-08-10T00:00:00Z reported=1 classified=5 open=5\nSTART 2026-08-10T06:00:00Z\n' > "$ST"
out="$(run_watch "$TMP/a.json" --state-file "$ST")"; rc=$?
grep -q "1 intervening run(s) went UNREAD (cancelled, blind, or unreachable) and are counted UNREAD, never as unchanged" <<<"$out" \
  && ok "(m3) the cancelled run's dangling START is counted UNREAD, in those words" \
  || bad "(m3) the dangling START was not counted UNREAD: $out"
grep -q "was 1 at 2026-08-10T00:00:00Z (moved +0" <<<"$out" \
  && ok "(m3) …and the baseline is the READ run behind it, so +0 is measured against a real read" \
  || bad "(m3) the baseline is not the last READ run: $out"

# (m4) a BLIND run (exit 5) writes START and NO READ — end to end, not seeded:
# the next run counts it UNREAD instead of comparing against it.
ST="$TMP/m-state-blind.txt"
printf 'READ 2026-08-10T00:00:00Z reported=1 classified=5 open=5\n' > "$ST"
out="$(run_watch "$TMP/d-blind.json" --state-file "$ST")"; rc=$?
[ "$rc" = "5" ] && ok "(m4) the blind run still exits 5 with the state file in play" \
  || bad "(m4) expected exit 5, got $rc"
grep -q '^START ' "$ST" && ! grep -q 'reported=0' "$ST" \
  && ok "(m4) the blind run left a START and no READ — zero coverage never becomes a baseline" \
  || bad "(m4) the blind run's state write is wrong: $(cat "$ST")"
out="$(run_watch "$TMP/a.json" --state-file "$ST")"; rc=$?
grep -q "1 intervening run(s) went UNREAD" <<<"$out" \
  && ok "(m4) …and the next run counts the blind run UNREAD, baselined on the READ before it" \
  || bad "(m4) the blind run was not counted UNREAD by its successor: $out"

# (m5) no READ line at all: the trend refuses to compare rather than inventing 0.
ST="$TMP/m-state-noread.txt"
printf 'START 2026-08-10T06:00:00Z\n' > "$ST"
out="$(run_watch "$TMP/a.json" --state-file "$ST")"; rc=$?
grep -q "TREND: no READ baseline yet — 1 earlier run(s) left a START with no READ" <<<"$out" \
  && ok "(m5) with only dangling STARTs the trend refuses a baseline and counts them UNREAD" \
  || bad "(m5) no honest no-baseline arm: $out"

# ═══ (n) THE RATCHET: the pin, and the two arms that can still fail ══════════
#
# This watch was RED on every scheduled run from 2026-08-08 to 2026-09-01,
# mostly about ONE pull request. A check that fails identically for three weeks
# cannot warn about the next one. The probes below are the ones that decide
# whether the ratchet ADDED a mechanism or just added silence: the pin must
# fail on a NOVEL row, and it must fail when a pinned row HEALS — otherwise it
# is an allowlist that can only grow.
section "(n) the pinned baseline: NOVEL fails, KNOWN warns, HEALED fails"

NB="$TMP/n-baseline"
HEAD_PIN="0123456789abcdef0123456789abcdef01234567"   # pr_row's fixed head
: > "$NB.empty"
printf '9001 %s 2026-08-01 pinned by the harness to prove KNOWN does not fail the run\n' \
  "${HEAD_PIN:0:9}" > "$NB.pinned"

# (n1) the pre-ratchet behaviour, unchanged: nothing pinned → the row is NOVEL.
out="$(run_watch "$TMP/a.json" --baseline "$NB.empty")"; rc=$?
[ "$rc" = "1" ] && ok "(n1) with an EMPTY pin a stale conflicted row is NOVEL and exits 1" \
  || bad "(n1) expected exit 1 with an empty pin, got $rc"
grep -q "NOVEL  1 — #9001" <<<"$out" && ok "(n1) …and it is named NOVEL" \
  || bad "(n1) the row was not classified NOVEL: $out"

# (n2) the same row, pinned: exit 0 — and STILL PRINTED. A pin that hid the
# row would trade a red that cannot warn for a green that cannot inform.
out="$(run_watch "$TMP/a.json" --baseline "$NB.pinned")"; rc=$?
[ "$rc" = "0" ] && ok "(n2) a pinned row is KNOWN and the run exits 0" \
  || bad "(n2) expected exit 0 for a pinned row, got $rc"
grep -q "KNOWN  1 — #9001" <<<"$out" && ok "(n2) …counted KNOWN" || bad "(n2) not counted KNOWN: $out"
grep -q "^  #9001 " <<<"$out" \
  && ok "(n2) …and the row is still printed in full: the debt stays visible in a green run" \
  || bad "(n2) the pinned row was hidden from the report: $out"
grep -q "STALE: ${CTX[0]} passed at $OLD" <<<"$out" \
  && ok "(n2) …with its staleness distance intact" \
  || bad "(n2) the pinned row lost its staleness detail: $out"

# (n3) THE ADD ARM. A pin must not cover a pull request it does not name.
fixture "$TMP/n-two.json" \
  "$(pr_row 9001 CONFLICTING DIRTY "$(full_set "$OLD")")" \
  "$(jq -c '.headRefOid = "feedfacefeedfacefeedfacefeedfacefeedface"' \
       <<<"$(pr_row 9002 CONFLICTING DIRTY "$(full_set "$OLD")")")"
out="$(run_watch "$TMP/n-two.json" --baseline "$NB.pinned")"; rc=$?
[ "$rc" = "1" ] && ok "(n3) a NEW conflicted row beside a pinned one still exits 1" \
  || bad "(n3) expected exit 1 with one pinned and one novel row, got $rc"
grep -q "NOVEL  1 — #9002" <<<"$out" && ok "(n3) …and only the unpinned #9002 is novel" \
  || bad "(n3) the novel row was not isolated from the pinned one: $out"

# (n4) THE SHRINK ARM — and the reason this is a ratchet and not an allowlist.
# The pinned PR is gone from the population: the run FAILS until the line goes.
echo "[]" > "$TMP/n-empty.json"
out="$(run_watch "$TMP/n-empty.json" --baseline "$NB.pinned")"; rc=$?
[ "$rc" = "8" ] && ok "(n4) a pinned entry that stopped reporting exits 8 — the baseline must shrink" \
  || bad "(n4) expected exit 8 when a pin healed, got $rc"
grep -q "HEALED 1 — #9001" <<<"$out" && ok "(n4) …#9001 is named HEALED" || bad "(n4) #9001 not named HEALED: $out"
grep -q "DELETE its line from the baseline" <<<"$out" \
  && ok "(n4) …with the exact remedy printed" || bad "(n4) no shrink instruction: $out"

# (n5) …and the SAME empty population with an EMPTY pin is a clean 0. Without
# this, (n4)'s red could be "any empty population reds" rather than "a pin
# healed", which is a different claim.
out="$(run_watch "$TMP/n-empty.json" --baseline "$NB.empty")"; rc=$?
[ "$rc" = "0" ] && ok "(n5) the same empty population with an EMPTY pin exits 0 — (n4) reds on the PIN, not on emptiness" \
  || bad "(n5) an empty population with an empty pin exited $rc"

# (n6) AN UNCLASSIFIED PINNED ROW IS NOT A HEALED ONE. GitHub answers UNKNOWN
# for rows it has not recomputed; if that emptied the baseline, a flaky read
# would delete the debt and the next run would re-report it as novel forever.
fixture "$TMP/n-unknown.json" "$(pr_row 9001 UNKNOWN null "$(full_set "$OLD")")"
out="$(run_watch "$TMP/n-unknown.json" --baseline "$NB.pinned")"; rc=$?
[ "$rc" = "5" ] && ok "(n6) an all-UNKNOWN population is BLIND (5), never a baseline-drift verdict" \
  || bad "(n6) expected exit 5 when the only row went UNKNOWN, got $rc"
grep -q "UNREAD 1 — #9001" <<<"$out" && ok "(n6) …the pinned row is counted UNREAD" \
  || bad "(n6) an unclassified pinned row was not held out of the healed set: $out"
grep -q "HEALED 0" <<<"$out" && ok "(n6) …and HEALED stays empty on a read that did not happen" \
  || bad "(n6) healed was non-empty on an unread row: $out"

# (n7) THE PIN IS KEYED ON THE HEAD, NOT THE NUMBER. A push gives the PR a new
# head and a freshly-dispatched verdict; the old line covers a tree that no
# longer exists and must not launder the new one.
fixture "$TMP/n-moved.json" \
  "$(jq -c '.headRefOid = "99999999abcdef0123456789abcdef0123456789"' \
       <<<"$(pr_row 9001 CONFLICTING DIRTY "$(full_set "$OLD")")")"
out="$(run_watch "$TMP/n-moved.json" --baseline "$NB.pinned")"; rc=$?
[ "$rc" = "1" ] && ok "(n7) a pinned NUMBER at a new HEAD is novel and exits 1" \
  || bad "(n7) expected exit 1 when the pinned head moved, got $rc"
grep -q "is PINNED at head ${HEAD_PIN:0:9} and is reported at head" <<<"$out" \
  && ok "(n7) …and the message says the pin describes a different tree" \
  || bad "(n7) no head-moved explanation: $out"

# (n8) GROWING THE FILE COSTS A SENTENCE. A pin with no written reason is a
# configuration fault, not a warning — the reason IS the cost of the pin.
printf '9001 %s 2026-08-01\n' "${HEAD_PIN:0:9}" > "$NB.noreason"
out="$(run_watch "$TMP/a.json" --baseline "$NB.noreason")"; rc=$?
[ "$rc" = "3" ] && ok "(n8) a reasonless pin is refused (3), never silently honoured" \
  || bad "(n8) expected exit 3 for a reasonless pin, got $rc"

# (n9) A --baseline THAT CANNOT BE OPENED IS A TYPO, NOT AN EMPTY PIN. The
# permissive reading would disarm the shrink arm on a misspelling.
out="$(run_watch "$TMP/a.json" --baseline "$TMP/n-does-not-exist")"; rc=$?
[ "$rc" = "3" ] && ok "(n9) an unopenable --baseline is refused (3), never treated as empty" \
  || bad "(n9) expected exit 3 for a missing --baseline, got $rc"

# (n10) THE COMMITTED FILE PARSES, and every line in it carries a reason. A
# baseline that only the harness's own fixtures can parse governs nothing.
BASE_REAL="$REPO_ROOT/scripts/stale-verdict-watch.baseline"
if [ -f "$BASE_REAL" ]; then
  ok "(n10) the committed baseline exists at scripts/stale-verdict-watch.baseline"
  out="$(run_watch "$TMP/n-empty.json" --baseline "$BASE_REAL" 2>&1)"; rc=$?
  [ "$rc" != "3" ] \
    && ok "(n10) …and the shipped file parses (exit $rc, not a 3 configuration fault)" \
    || bad "(n10) the committed baseline does not parse: $out"
else
  bad "(n10) the committed baseline is missing — the default pin path is unreadable"
fi

# ═══ (o) the script's own --selftest, and proof it can lose ══════════════════
section "(o) --selftest is a prover, not a decoration"

out="$(bash "$WATCH" --selftest 2>&1)"; rc=$?
[ "$rc" = "0" ] && ok "(o) --selftest passes on the shipped ratchet" || bad "(o) --selftest failed: $out"
grep -qE "^── stale-verdict-watch --selftest: [0-9]+ passed, 0 failed ──$" <<<"$out" \
  && ok "(o) …and prints a real pass/fail count" || bad "(o) no pass/fail count from --selftest: $out"
sel_n="$(sed -n 's/^── stale-verdict-watch --selftest: \([0-9][0-9]*\) passed.*/\1/p' <<<"$out" | tail -1)"
[ "${sel_n:-0}" -ge 12 ] \
  && ok "(o) …over ${sel_n} assertions, so the count is not a vacuous zero" \
  || bad "(o) --selftest reported only ${sel_n:-0} passing assertions"

# THE ONE THAT MATTERS: break one arm of the partition and --selftest must go
# RED. A selftest that cannot lose proves nothing about the ratchet it guards,
# and each mutation is refused outright if its sed matched nothing — so a
# reflow of the jq turns a silently-vacuous mutant into a loud one.
for mut in pin-any never-healed head-blind; do
  out="$(SVW_MUTATE="$mut" bash "$WATCH" --selftest 2>&1)"; rc=$?
  [ "$rc" != "0" ] \
    && ok "(o) --selftest LOSES under SVW_MUTATE=$mut (exit $rc)" \
    || bad "(o) --selftest passed with the ratchet mutated ($mut) — it cannot lose: $out"
  grep -q "matched nothing in RATCHET_JQ" <<<"$out" \
    && bad "(o) the $mut mutation matched nothing — the mutant is the original, so that probe is vacuous" \
    || ok "(o) …and the $mut mutation actually applied to the program"
done

# AND THE MUTATION SWITCH IS UNREACHABLE FROM A REAL RUN. An env var that can
# disarm a gate in production is a worse defect than the one it tests for.
out="$(SVW_MUTATE=pin-any run_watch "$TMP/a.json" --baseline "$NB.empty")"; rc=$?
[ "$rc" = "1" ] \
  && ok "(o) an ambient SVW_MUTATE is IGNORED by a normal run (still exit 1)" \
  || bad "(o) SVW_MUTATE reached a production run and changed its verdict to $rc"
out="$(SVW_SELFTEST_CHILD=1 SVW_MUTATE=pin-any run_watch "$TMP/a.json" --baseline "$NB.empty")"; rc=$?
[ "$rc" = "0" ] \
  && ok "(o) …and the switch IS real inside a selftest child, so the line above tested the guard, not a no-op" \
  || bad "(o) the mutation had no effect even inside a selftest child (exit $rc) — the guard probe above is vacuous"

# ═══ (p) the PAGED read: it walks a cursor, and it still refuses ════════════
section "(p) the paged pull-request read — pages, retries a page, and still exits 6 when it cannot read"

# THE DEFECT THIS OWNS. The read was `gh pr list --limit 100 --json
# …statusCheckRollup`: one request for a hundred pull requests AND a hundred
# check rollups. Measured on 2026-09-02 at 72 open pull requests it answered
# HTTP 504 on 3 of 3 attempts while limit=25 answered in ~4s, so EVERY
# scheduled run of this workflow exited 6 UNREACHABLE. These probes drive a
# STUB `gh` on PATH, so what they assert is the script's behaviour against a
# transport, not a claim about which command it happens to type.

STUB="$TMP/stub"; mkdir -p "$STUB"
STUB_LOG="$TMP/stub-calls.log"

# A stub that answers page 1 of 2 and then page 2, so a passing probe PROVES a
# cursor was carried. Each page holds one CONFLICTING row with a stale green,
# so a run that reads BOTH pages classifies 2 and reds at 1 — and a run that
# silently read only the first classifies 1, which the count assertion catches.
mk_stub() { # <mode>
  cat > "$STUB/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$@" >> "$STUB_LOG"
mode="$1"
# The commits read is "gh api repos/<r>/commits?..."; the PAGE read is
# "gh api graphql". Match on the SUBCOMMAND, never on the word "commits" --
# the GraphQL query text itself contains a commits selection, and matching
# that made every page request answer with commit dates instead of a page.
case "\$1 \${2:-}" in
  "api repos/"*) cat "$COMMITS"; exit 0 ;;
esac
if [ "\$mode" = "always504" ]; then
  echo "HTTP 504: We couldn't respond to your request in time. Sorry about that. (https://api.github.com/graphql)" >&2
  exit 1
fi
# How many page requests have been made so far (this call included)?
n=\$(grep -c 'graphql' "$STUB_LOG")
if [ "\$mode" = "flaky-page-2" ] && grep -q 'after=' <<<"\$*" && [ ! -f "$TMP/page2-failed-once" ]; then
  touch "$TMP/page2-failed-once"
  echo "HTTP 504: We couldn't respond to your request in time. (https://api.github.com/graphql)" >&2
  exit 1
fi
if grep -q 'after=' <<<"\$*"; then cat "$TMP/gql-page2.json"; else cat "$TMP/gql-page1.json"; fi
STUBEOF
  chmod +x "$STUB/gh"
}

# A raw GraphQL page in GitHub's own shape — NOT the normalised shape — so the
# normaliser is exercised rather than bypassed.
gql_page() { # <path> <number> <hasNext> <cursor>
  local roll="[]" c
  for c in "${CTX[@]}"; do
    roll="$(jq -c --arg n "$c" --arg t "$OLD" \
      '. + [{__typename:"CheckRun", name:$n, conclusion:"SUCCESS", completedAt:$t, status:"COMPLETED"}]' <<<"$roll")"
  done
  jq -n --argjson num "$2" --argjson next "$3" --arg cur "$4" --argjson roll "$roll" \
    '{data:{repository:{pullRequests:{
        pageInfo:{hasNextPage:$next, endCursor:$cur},
        nodes:[{number:$num, mergeable:"CONFLICTING", mergeStateStatus:"DIRTY",
                headRefOid:"0123456789abcdef0123456789abcdef01234567",
                updatedAt:"2026-08-01T00:00:00Z",
                commits:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:$roll}}}}]}}]}}}}' > "$1"
}
gql_page "$TMP/gql-page1.json" 9101 true  "CURSOR_ONE"
gql_page "$TMP/gql-page2.json" 9102 false null

STUB_PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin"
run_stubbed() { # <mode> [extra args…]
  local mode="$1"; shift
  : > "$STUB_LOG"; rm -f "$TMP/page2-failed-once"
  mk_stub "$mode"
  env PATH="$STUB_PATH" SVW_RETRY_SLEEP="0 0 0" SVW_PAGE_SLEEP="0 0 0 0" \
    bash "$WATCH" --spec "$SPEC" --repo FRIKKern/barkpark --commits "$COMMITS" \
      --baseline '' --page-size 1 "$@" 2>&1
}

# (p-1) TWO pages are read and BOTH rows are classified.
out="$(run_stubbed pages)"; rc=$?
[ "$rc" = "1" ] && ok "(p-1) a two-page population still reds at exit 1" \
  || bad "(p-1) expected exit 1 over two paged rows, got $rc: $out"
grep -q "#9101" <<<"$out" && grep -q "#9102" <<<"$out" \
  && ok "(p-1) …and BOTH pages' rows are reported — the cursor was carried past page 1" \
  || bad "(p-1) a row from one of the two pages is missing, so the second page was never fetched: $out"
grep -q "after=CURSOR_ONE" "$STUB_LOG" \
  && ok "(p-1) …and page 2 was asked for with the cursor page 1 named" \
  || bad "(p-1) no request carried the endCursor from page 1: $(cat "$STUB_LOG")"
[ "$(grep -c graphql "$STUB_LOG")" = "2" ] \
  && ok "(p-1) …in exactly 2 page requests, so paging is not re-reading the whole population per row" \
  || bad "(p-1) expected 2 graphql page requests, saw $(grep -c graphql "$STUB_LOG")"

# (p-2) A page that 504s ONCE is retried AS A PAGE — page 1 is not re-fetched.
out="$(run_stubbed flaky-page-2)"; rc=$?
[ "$rc" = "1" ] && ok "(p-2) a single-page 504 is survived: the run still reaches its verdict (exit 1)" \
  || bad "(p-2) a transient 504 on page 2 lost the whole read, got $rc: $out"
grep -q "#9101" <<<"$out" && grep -q "#9102" <<<"$out" \
  && ok "(p-2) …with both rows still present, so the pages read before the failure were not discarded" \
  || bad "(p-2) a row went missing after the retried page: $out"
[ "$(grep -c 'after=' "$STUB_LOG")" = "2" ] \
  && ok "(p-2) …and it was the PAGE that was retried (2 cursor requests), not the whole query" \
  || bad "(p-2) expected the failed page to be re-requested once; cursor requests: $(grep -c 'after=' "$STUB_LOG")"

# (p-3) THE REFUSAL, MUTATION-PROVEN. This is the probe that matters: if the
# paging above had been bought by making a failed read look like an empty
# population, THIS is where it would show. Every page 504s, forever.
out="$(run_stubbed always504 --attempts 2 --page-attempts 2)"; rc=$?
[ "$rc" = "6" ] \
  && ok "(p-3) a read that 504s on every attempt STILL exits 6 UNREACHABLE — the fix did not buy paging with the refusal" \
  || bad "(p-3) expected exit 6 when every page 504s, got $rc — a failed read is being reported as something other than unreachable: $out"
grep -q "UNREACHABLE" <<<"$out" \
  && ok "(p-3) …and says UNREACHABLE" || bad "(p-3) no UNREACHABLE sentence: $out"
grep -q "^ok — no CONFLICTING" <<<"$out" \
  && bad "(p-3) a run that read ZERO pull requests printed the clean sentence" \
  || ok "(p-3) …and never prints the clean sentence over a population it never read"
grep -qi "classified nothing" <<<"$out" \
  && ok "(p-3) …and states it classified nothing" || bad "(p-3) the refusal does not say it classified nothing: $out"

# (p-4) The page size is an ARGUMENT, and a wrong one is a configuration fault
# rather than a silently degraded read.
for bad_size in 0 -1 abc 101; do
  out="$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" bash "$WATCH" --spec "$SPEC" \
          --repo FRIKKern/barkpark --page-size "$bad_size" 2>&1)"; rc=$?
  [ "$rc" = "3" ] && ok "(p-4) --page-size '$bad_size' is a configuration fault (exit 3), not a read" \
    || bad "(p-4) --page-size '$bad_size' exited $rc instead of 3"
done
out="$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" bash "$WATCH" --spec "$SPEC" \
        --repo FRIKKern/barkpark --page-attempts 0 2>&1)"; rc=$?
[ "$rc" = "3" ] && ok "(p-4) --page-attempts 0 is a configuration fault (exit 3)" \
  || bad "(p-4) --page-attempts 0 exited $rc instead of 3"

# (p-5) DISARM. The probes above would all pass against a script that reds
# unconditionally. A stub whose pages hold a MERGEABLE row with a FRESH verdict
# must come out clean — proving (p-1)/(p-2)'s exit 1 was earned by the rows.
clean_roll="[]"
for c in "${CTX[@]}"; do
  clean_roll="$(jq -c --arg n "$c" --arg t "$FRESH" \
    '. + [{__typename:"CheckRun", name:$n, conclusion:"SUCCESS", completedAt:$t, status:"COMPLETED"}]' <<<"$clean_roll")"
done
jq -n --argjson roll "$clean_roll" \
  '{data:{repository:{pullRequests:{pageInfo:{hasNextPage:false, endCursor:null},
     nodes:[{number:9103, mergeable:"MERGEABLE", mergeStateStatus:"CLEAN",
             headRefOid:"0123456789abcdef0123456789abcdef01234567",
             updatedAt:"2026-08-11T00:00:00Z",
             commits:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:$roll}}}}]}}]}}}}' \
  > "$TMP/gql-page1.json"
out="$(run_stubbed pages)"; rc=$?
[ "$rc" = "0" ] \
  && ok "(p-5) disarm: a MERGEABLE, fresh row read through the SAME paged transport exits 0" \
  || bad "(p-5) the paged read reds no matter what it reads (exit $rc): $out"

# ═══ (i) the harness's own assertions can fail ═══════════════════════════════
section "(i) disarm: prove these probes are able to fail"

# A verdict that ALWAYS reds would pass (a), (c) and (d)'s mixed probe. Feed it
# an empty population: anything other than exit 0 means the red is unconditional.
echo "[]" > "$TMP/i-empty.json"
out="$(run_watch "$TMP/i-empty.json")"; rc=$?
[ "$rc" = "0" ] && ok "an empty population exits 0 — the red is conditional, not unconditional" \
  || bad "an empty population exited $rc — this verdict reds no matter what it reads"

# And the inverse: assert a string the verdict never prints, to show grep-based
# probes here are not vacuously satisfied by any output at all.
grep -q "this string is not in any verdict" <<<"$out" \
  && bad "a nonsense assertion passed — these greps match anything" \
  || ok "a nonsense assertion fails, so the greps above are load-bearing"

echo
section "(m) the LIVE page loop: a GraphQL page above macOS total argv still appends to the population"

# THE BUG THIS OWNS. Section (k) proves the --fixture path carries nothing by
# argv. The LIVE path did not go through it: scripts/stale-verdict-watch.sh
# accumulated pages with `jq -n --argjson a "$rows" --argjson b "$got"`, so the
# whole population travelled as one argv word per page. Every run from
# 2026-09-03 06:08Z died "jq: Argument list too long" and was read as
# UNREACHABLE — the harness stayed green because (k) never paged. A stub `gh`
# serves ONE oversized page here; the append must survive and classify it.
LSTUB="$TMP/l-stub"; mkdir -p "$LSTUB/bin"
LPAGE="$LSTUB/page.json"
python3 - "$LPAGE" <<'PY'
import json,sys
nodes=[{"number":30000+i,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%040d"%i,"updatedAt":"2026-08-01T00:00:00Z",
        "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
          {"__typename":"CheckRun","name":"advisory-context-%d-a-realistically-long-workflow-job-name"%k,"status":"COMPLETED","conclusion":"SUCCESS",
           "completedAt":"2026-09-01T00:00:00Z","detailsUrl":"https://github.com/FRIKKern/barkpark/actions/runs/1/job/1"} for k in range(60)]}}}}]}} for i in range(100)]
page={"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":False,"endCursor":None},"nodes":nodes}}}}
open(sys.argv[1],"w").write(json.dumps(page))
PY
printf '#!/usr/bin/env bash\ncase "$*" in *graphql*) cat "%s" ;; *) echo "{}" ;; esac\n' "$LPAGE" > "$LSTUB/bin/gh"; chmod +x "$LSTUB/bin/gh"
lpage_bytes="$(wc -c < "$LPAGE" | tr -d ' ')"
[ "${lpage_bytes:-0}" -ge "$SCALE_MIN" ] \
  && ok "the generated live page is ${lpage_bytes}B ≥ ${SCALE_MIN}B" \
  || bad "the live-page fixture is only ${lpage_bytes}B — below the ${SCALE_MIN}B bound"
out="$(env PATH="$LSTUB/bin:/usr/bin:/bin:/usr/sbin:/sbin" GH_TOKEN=stub \
        bash "$WATCH" --spec "$SPEC" --repo FRIKKern/barkpark 2>&1)"; rc=$?
grep -qi "Argument list too long" <<<"$out" \
  && bad "(m) execve E2BIG on the live page loop — the population still travels by argv" \
  || ok "(m) no 'Argument list too long' on the live page loop"
grep -qE "classified 100" <<<"$out" \
  && ok "(m) the oversized page was appended and all 100 rows classified" \
  || bad "(m) the page was not classified (rc=$rc): $(printf '%s' "$out" | grep -iE 'population|UNREACHABLE|classified' | head -2 | tr '\n' ' ')"

echo
section "(q) a DRAFT conflicted PR is not NOVEL — it is printed, not counted"

# THE BUG THIS OWNS. A CONFLICTING PR asserting a stale green reds main. A
# DRAFT one cannot be merged by anyone — GitHub refuses and the merge sweep
# skips it — so it asserts no verdict a human can act on, and the LEAD-BRIEF's
# own remedy for a stale conflicted PR is "draft it instead". main drafted
# #15631 at 2026-09-04T02:31Z and run 33837151186 at 04:31Z still printed
# "NOVEL 1 — #15631" and failed, because the watch never read isDraft.
#
# THESE PROBES DRIVE THE LIVE PATH, NOT --fixture. Section (m)'s lesson: a
# property proven only on the --fixture path leaves the live path unproven, and
# isDraft is exactly such a field — it enters through the GraphQL selection and
# PR_NORMALISE_JQ, neither of which --fixture touches. So a stub `gh` serves a
# real GraphQL page shape here and the flag travels the transport production
# takes. The commit history still comes from --commits, so nothing is timing-
# dependent.
QSTUB="$TMP/q-stub"; mkdir -p "$QSTUB/bin"

q_page() { # <path> <isDraft: true|false>  — one CONFLICTING PR with a full stale green
  local path="$1" draft="$2" ctxjson="[]" c
  for c in "${CTX[@]}"; do
    ctxjson="$(jq -c --arg n "$c" --arg t "$OLD" \
      '. + [{__typename:"CheckRun", name:$n, status:"COMPLETED", conclusion:"SUCCESS", completedAt:$t}]' <<<"$ctxjson")"
  done
  jq -n --argjson draft "$draft" --argjson ctx "$ctxjson" '
    { data: { repository: { pullRequests: {
        pageInfo: { hasNextPage: false, endCursor: null },
        nodes: [ { number: 15631, mergeable: "CONFLICTING", mergeStateStatus: "DIRTY",
                   updatedAt: "2026-08-01T00:00:00Z",
                   headRefOid: "cbbe4a6390000000000000000000000000000000",
                   isDraft: $draft,
                   commits: { nodes: [ { commit: { statusCheckRollup: { contexts: { nodes: $ctx } } } } ] } } ] } } } }' \
    > "$path"
}

q_run() { # <page json path> — the live read, with only `gh` stubbed
  local page="$1"
  printf '#!/usr/bin/env bash\ncase "$*" in *graphql*) cat "%s" ;; *) echo "[]" ;; esac\n' "$page" > "$QSTUB/bin/gh"
  chmod +x "$QSTUB/bin/gh"
  env PATH="$QSTUB/bin:/usr/bin:/bin:/usr/sbin:/sbin" GH_TOKEN=stub \
    bash "$WATCH" --commits "$COMMITS" --spec "$SPEC" --repo FRIKKern/barkpark 2>&1
}

# (q1) DRAFT — the identical row, marked draft, must NOT be novel and must exit 0.
q_page "$TMP/q-draft.json" true
out="$(q_run "$TMP/q-draft.json")"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "(q1) a DRAFT conflicted PR asserting a stale green exits 0" \
  || bad "(q1) exit $rc, expected 0 — a draft that cannot be merged still fails the run"
grep -qE "NOVEL +0" <<<"$out" \
  && ok "(q1) …and the NOVEL count is 0" \
  || bad "(q1) NOVEL is not 0: $(grep -E 'NOVEL' <<<"$out" | head -1)"
grep -q "DRAFT, not counted: #15631" <<<"$out" \
  && ok "(q1) …and #15631 is PRINTED on its own labelled draft line, not silenced" \
  || bad "(q1) the draft row was not printed on a draft line — a silent exclusion is worse than the red"
grep -q "RED — " <<<"$out" \
  && bad "(q1) the run printed a RED verdict on a population of one draft" \
  || ok "(q1) …and no RED sentence was printed"

# (q2) THE SAME ROW, NOT A DRAFT — still NOVEL, still exit 1. Without this the
# probe above is satisfied by a script that reports nothing at all.
q_page "$TMP/q-ready.json" false
out="$(q_run "$TMP/q-ready.json")"; rc=$?
[ "$rc" -eq 1 ] \
  && ok "(q2) the SAME row not marked draft exits 1" \
  || bad "(q2) exit $rc, expected 1 — the draft exclusion swallowed a real stale green"
grep -qE "NOVEL +1 — #15631" <<<"$out" \
  && ok "(q2) …and #15631 is named NOVEL" \
  || bad "(q2) #15631 is not named NOVEL: $(grep -E 'NOVEL' <<<"$out" | head -1)"
grep -q "DRAFT, not counted: #15631" <<<"$out" \
  && bad "(q2) a non-draft row was printed on the draft line" \
  || ok "(q2) …and it is NOT on the draft line"

echo "── stale-verdict-watch: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
