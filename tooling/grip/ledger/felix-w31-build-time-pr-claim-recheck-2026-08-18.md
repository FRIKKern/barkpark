<!-- doc-tier: cold | canonical-for: felix-w31-build-time-pr-claim-recheck | budget: 400tok -->

# Felix W31 — build-time PR + claim recheck (#12132 / #12159)

Verifier assignment [build-time-pr-claim-recheck]. Verdict: BOTH rows NOT-CLOSEABLE this wave.
PRs open, neither head an ancestor of origin/main; both claims lapsed to worker=null.

## Re-derive (one command)

    cd /Volumes/SATECHI/github/barkpark && git fetch origin main -q && \
    for p in 12132 12159; do gh pr view $p --json state,mergedAt,mergeStateStatus,headRefOid; done && \
    for h in $(gh pr view 12132 --json headRefOid -q .headRefOid) $(gh pr view 12159 --json headRefOid -q .headRefOid); do \
      git merge-base --is-ancestor $h origin/main && echo ANC || echo NOT; done && \
    for id in felix-w27-bl-media-dataset-swallow-mirror felix-w30-s1-redaction-global-schema-fallback; do \
      bp task get $id -o json | python3 -c "import json,sys;d=json.load(sys.stdin);doc=d.get('doc') or d;c=doc.get('claim') or {};print('$id epoch=',c.get('epoch'),'worker=',c.get('worker'),'progress=',doc.get('criteria_progress'))"; done

## Measured 2026-08-18 (this run)

| Row | PR | PR state | mergeState | head ANC origin/main | live epoch | worker | progress |
|---|---|---|---|---|---|---|---|
| felix-w27-bl-media-dataset-swallow-mirror | #12132 | OPEN | BLOCKED | NOT | 6 | null (lapsed) | 5/6 |
| felix-w30-s1-redaction-global-schema-fallback | #12159 | OPEN | UNSTABLE | NOT | 8 | null (lapsed) | 5/6 |

Blocking gates: #12132 — "Doc budgets + anchors" FAIL (blocking) + Sobelow PENDING + Test PENDING.
#12159 — "Sobelow static analysis (regression gate)" FAIL (red, blocks merge, as predicted).

Decide: if either PR lands mid-wave, re-read the CURRENT epoch immediately before close
(worker=null now, so re-claim first). As of this read the CAS epochs are media=6, redaction=8.
Neither is closeable by evidence today.
