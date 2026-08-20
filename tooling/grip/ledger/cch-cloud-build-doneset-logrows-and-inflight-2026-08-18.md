<!-- doc-tier: cold | canonical-for: none | budget: 900tok -->
# Cloud-Build done-set audit — logrows-and-inflight re-derivation (2026-08-18)

Verifier lane [logrows-and-inflight]. origin/main HEAD at audit = `a28e5ba53696ae4970996e76cd5735910ae22aeb`.

## wave-9-log — TRUE (honest stamping-lag, NOT false-done)

- Row DONE, criteria 1/2, criterion 1 (merge gate) met=False, empty evidence.
- Closed at `2026-08-18T07:43:15.225430Z` (claim worker `decide-cloud-billing-leak-w9`, epoch 5).
- Evidence PR #12221 merged at `2026-08-18T07:45:39Z` — 2m24s AFTER close → criterion honestly not-yet-met at close time.
- Merge commit `e21bf409893d9de66542a31b06716e3c33d8f102` IS an ancestor of origin/main.
  Rerun: `gh api repos/FRIKKern/barkpark/compare/main...e21bf409893d9de66542a31b06716e3c33d8f102 --jq '{ahead_by,behind_by,status}'`
  → `ahead_by=0, behind_by=6, status=behind` (base=main orientation: ahead_by==0 ⇒ commit ⊆ main ⇒ ancestor).

## wave-2b-log — EXCUSED (0 criteria, no false claim) but content NOT on main

- Row DONE, 0 acceptance_criteria (referent/pr-task-gate claim carrier), closed `2026-08-18T07:50:19.741570Z`.
- Its charter PR #12223 (D85-D90, search-tenancy) is OPEN + CONFLICTING (mergeStateStatus DIRTY).
  Rerun: `gh pr view 12223 --repo FRIKKern/barkpark --json state,mergeable,mergeStateStatus`
- D85/D90/"Wave 2b" appear ONLY in #12223's diff, NOT on origin/main charter → reconciles the surveyor "no D90 on disk" contradiction.
  Rerun: `gh api repos/FRIKKern/barkpark/contents/.claude/workflows/bp-cloud-build-charter.md --jq .content | base64 -d | grep -iE 'Wave.?2b|D90'` → empty.
- On origin/main the charter's D85-D89 belong to Wave 9 (billing leak). #12223 conflicts BECAUSE it re-allocates D85-D90 in the same decisions section → decision-number collision; needs renumber before it can merge.

## In-flight rows — STALE-OPEN mirror (out of denominator, PRs already merged)

All three lifecycle=open, claim_worker=None (correctly OUT of the 36-row done set), but their evidence PRs are MERGED:
- `bpb-cloud-billing-raw-body-leak-fix` 5/6 open — PR #12226 MERGED
- `bpb-search-intel-record-insights-pipeline-align` 5/6 open — PR #12227 MERGED
- `bpb-search-scope-param-tenancy-check` 4/5 open — PR #12228 MERGED

Rerun: `for pr in 12226 12227 12228; do gh pr view $pr --repo FRIKKern/barkpark --json state --jq .state; done` → MERGED×3.
Not false-DONE (denominator not inflated); denominator will grow to ~39 once these close. No live builder claim → safe.

## Verdict for this lane

Zero false-DONEs among the two log rows. No reopens warranted (wave-9 honest lag; wave-2b has no criterion to falsify). Both directions measured; stale-OPEN mirror flagged for Decide.
