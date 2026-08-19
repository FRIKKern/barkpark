<!-- doc-tier: cold | canonical-for: none | budget: 2000tok -->
# stw12 v9 — p0 live-residue re-derivation (2026-08-18)

Verifier lane v9-p0-live-residue. Re-derives the verdicts on the two p0 live-residue
tasks so Decide never level-skips (L4 tree vs L1 running system).

## stw10-backlog-revoke-public-read-class — GENUINELY-OPEN, live-gated, NOT fixed

    bp task get stw10-backlog-revoke-public-read-class -o json \
      | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['claim'],d['criteria_progress'])"

Expect: `open None {'met': 0, 'total': 4}`.
All 4 criteria demand LIVE proof (HTTP 401 on token re-use; live flagship 200 after
rotate-then-redeploy; prod-DB plaintext scrub of 14 revisions + 1 documents row;
control-plane triage of 4 secret-shaped strings). None offline-provable. Verdict:
stays OPEN → LEAD as p0 live security residue. Closing from the tree = falsely
closing a live security action.

## stw10-backlog-flagship-health-pool — already CLOSED (done), D82-reopen REFUTED

    bp task get stw10-backlog-flagship-health-pool -o json \
      | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['claim']['closed_at'],d['claim']['closed_by'],d['claim']['epoch'],d['criteria_progress'])"

Expect: `done 2026-07-27T17:40:53.605795Z w10-lead 1 {'met': 3, 'total': 3}`.
Root cause resolved by #6284 (N+1 kill), not by pool work. Later hardening #9613
readmits /v1/graph. Both are ancestors of origin/main:

    git merge-base --is-ancestor 68b844c556 origin/main && echo 6284-ANCESTOR   # #6284
    git merge-base --is-ancestor dbcb128880 origin/main && echo 9613-ANCESTOR   # #9613

    git show -s --format='%s %ci' dbcb128880
    # fix(api): graph corpus honours schema visibility, is bounded, and /v1/graph is readmitted (#9613)  2026-08-05

Verdict: the ledger wins the 3/3-met-vs-D82-reopen ambiguity — it is CLOSED, and the
code fix is permanent (ancestor). Do NOT reopen as a wave build slice: the fix is in
the tree, and its "met" evidence (a 2026-07-27 live probe) is a runtime property no
offline box can re-prove. Fresh redeployability assurance = a LIVE probe for the lead,
never a wave build.

## stw10-backlog-graph-n-plus-one — CLOSED, corroborates the chain

    bp task get stw10-backlog-graph-n-plus-one -o json | grep -o '"lifecycle_status":"[a-z]*"' | head -1
    # done ; 3/3 met ; resolved by #6284 (68b844c556, ancestor)
