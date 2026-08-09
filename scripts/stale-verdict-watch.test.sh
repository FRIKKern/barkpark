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
#   (d) an UNKNOWN row is WARNED, never dropped                  → exit 2
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

# ═══ (d) UNKNOWN is a warning row, never an omission ═════════════════════════
section "(d) mergeable=UNKNOWN → warned, never dropped, exit 2"

fixture "$TMP/d.json" "$(pr_row 9004 UNKNOWN UNKNOWN "$(full_set "$OLD")")"
out="$(run_watch "$TMP/d.json")"; rc=$?
[ "$rc" = "2" ] && ok "exit 2 — not green, not red: unclassified" || bad "expected exit 2, got $rc"
grep -q "WARNING ROWS" <<<"$out" && ok "a WARNING ROWS block is printed" || bad "no WARNING ROWS block"
grep -q "? #9004" <<<"$out" && ok "#9004 is named — the naive CONFLICTING filter would have dropped it silently" \
  || bad "#9004 was dropped from the report"
grep -q "1 UNKNOWN after re-polling" <<<"$out" && ok "the population counts it as UNKNOWN" || bad "the population hid the UNKNOWN row"

# THE MUTATION: a red alongside an unknown must still read RED — the warning
# lane must not be able to downgrade a real finding.
fixture "$TMP/d-mixed.json" \
  "$(pr_row 9004 UNKNOWN UNKNOWN "$(full_set "$OLD")")" \
  "$(pr_row 9005 CONFLICTING DIRTY "$(full_set "$OLD")")"
out="$(run_watch "$TMP/d-mixed.json")"; rc=$?
[ "$rc" = "1" ] && ok "mutation: red wins over unknown (exit 1)" || bad "mutation: expected exit 1, got $rc"
grep -q "? #9004" <<<"$out" && ok "mutation: the unknown row is STILL printed next to the red" || bad "mutation: the unknown row vanished once a red existed"

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
if command -v git >/dev/null 2>&1 && [ -f "$CONTENDED" ]; then
  if git -C "$REPO_ROOT" diff --quiet HEAD -- ".github/workflows/main-gate-watch.yml" 2>/dev/null; then
    ok "the contended .github/workflows/main-gate-watch.yml is untouched by this slice"
  else
    bad "this slice modified the CONTENDED main-gate-watch.yml — that is the co-scoped-fixes trap"
  fi
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
echo "── stale-verdict-watch: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
