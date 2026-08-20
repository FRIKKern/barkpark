<!-- doc-tier: cold | canonical-for: felix-w28-verify-train-ledger-snapshot | budget: 1200tok -->

# Felix wave-28 verify — train & ledger state snapshot (2026-08-18)

Re-derivation recipes for the Act-I state Decide sizes review slices + close list from.
Snapshot taken 2026-08-18 ~00:0X UTC; PRs merged 2026-08-17 23:09-23:10 UTC.

## Train state (all 7 wave-27 PRs)

    for n in 12041 12071 12072 12073 12074 12075 12076; do gh pr view $n --json number,state,mergedAt,mergeable --jq '{n:.number,s:.state,m:.mergedAt,mergeable:.mergeable}'; done

Result: #12071-#12076 MERGED (23:09:49-23:10:07). #12041 OPEN, MERGEABLE, mergeStateStatus=BLOCKED — Test(Elixir 1.18.1/OTP27) + Prod compile gate IN_PROGRESS (re-fired by the 22:39 golden-contingency/hygiene push). Required Cloud/Console/Security/active-task gates SUCCESS.

    gh pr view 12041 --json mergeStateStatus,statusCheckRollup --jq '.mergeStateStatus, (.statusCheckRollup[]|select(.name|test("Test \\(Elixir|Prod compile"))|"\(.name)=\(.status)")'

## PR -> ledger row mapping (from PR bodies)

    for n in 12071 12072 12073 12074 12075; do gh pr view $n --json body --jq '[scan("task-[a-z0-9-]+|felix-w[0-9]+[a-z0-9-]+")]|unique|.[0:2]'; done

- #12071 -> felix-w26-bl-write-scope-swallow-nil (WriteScope fails closed)
- #12072 -> task-966de76b9dd92783 (pg_catalog bundle guard, relkind='r')
- #12073 -> task-felix-w22-bl-webhook-body-rightsize
- #12074 -> felix-w27-s5-spec-gate-pins
- #12075 -> felix-w26-bl-codex-protocol-error-swallow
- #12041 -> felix-w27-s6-12041-golden-contingency + felix-w19-bl-authority-lock-remaining-sites

## Ledger rows — CURRENT holder worker+epoch (D181 recipe)

    for t in felix-w26-bl-write-scope-swallow-nil task-966de76b9dd92783 task-felix-w22-bl-webhook-body-rightsize felix-w27-s5-spec-gate-pins felix-w26-bl-codex-protocol-error-swallow felix-w27-s6-12041-golden-contingency felix-w19-bl-authority-lock-remaining-sites; do bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];c=d.get('claim') or {};print(d['id'][:8],d.get('lifecycle_status'),'closed_at=',c.get('closed_at'),'worker=',c.get('worker'),'epoch=',c.get('epoch'))"; done

5 of 7 already CLOSED (lifecycle=done) by the lead as PRs merged:
- write-scope-swallow-nil : done, epoch 6, worker epic-builder-write-scope-fails-closed-a-refused-datas
- 966de76b (pg-catalog) : done, epoch 6, worker epic-builder-pg-catalog-bundle-guard-broadening-pg-ta
- webhook-body-rightsize : done, epoch 6, worker epic-builder-webhook-body-cap-at-github-s-25mb-ceilin
- spec-gate-pins : done, epoch 5, worker epic-builder-spec-gate-census-pins-two-class-c-lines-
- codex-protocol-error-swallow : done, epoch 6, worker epic-builder-codex-error-kinds-surface-in-the-transcr

2 still in_progress (both tied to still-open #12041, close when it merges):
- felix-w27-s6-12041-golden-contingency : in_progress, epoch 6, worker epic-builder-12041-lands-diagnose-the-shifting-elixir
- felix-w19-bl-authority-lock-remaining-sites : in_progress, epoch 9, worker felix-review-w27

## Review-mode flip (the load-bearing verdict)

#12071 (write_scope, HIGH-FLIP-RISK) and #12072 (pg_catalog, HIGH-FLIP-RISK) are BOTH MERGED with Elixir gate SUCCESS. The two owed second reviews therefore flip from PRE-MERGE to POST-MERGE revert-authority mode. Digest's "train has not moved / lead closed ZERO rows / reviews fly pre-merge" is a full snapshot stale.
