<!-- doc-tier: cold | canonical-for: cch-w37-telegram-c3-connectors-yml-green | budget: 600tok -->

# W37 telegram C3 — connectors.yml GREEN on #11980 merge commit

Verdict: telegram C3 ("PR merged; connectors.yml green") CLOSES BY EVIDENCE.

The connectors.yml workflow (workflow `name: connectors`) emits the check-run
"Typecheck + tests (real Postgres, zero skips)". On #11980's merge commit
`438f6c7ce23bb9c694addd35b883acbfafe3d671` (event=push, the post-merge main
integration sha), that workflow run (databaseId 32077006777) concluded SUCCESS,
and both of its jobs — "Typecheck + tests (real Postgres, zero skips)" and
"Cloud shim confinement + session-sandbox proofs" — concluded success.

Rerun:

    gh run list --workflow connectors.yml --limit 15 --json headSha,conclusion,databaseId,event \
      --jq '.[]|select(.headSha=="438f6c7ce23bb9c694addd35b883acbfafe3d671")'
    # -> {"conclusion":"success","databaseId":32077006777,"event":"push", ...}
    gh api repos/FRIKKern/barkpark/actions/runs/32077006777/jobs --jq '.jobs[]|{name,conclusion}'
    # -> both success

Cross-check via commit check-runs (connectors.yml surfaces as the two named checks):

    gh api repos/FRIKKern/barkpark/commits/438f6c7/check-runs --jq '.check_runs[]|{name,conclusion}'
    # -> "Typecheck + tests (real Postgres, zero skips)": success
    #    "Cloud shim confinement + session-sandbox proofs ...": success

Note: same commit's "Stale verdict watch" and "Crown reconcile" concluded failure,
but those are advisory/reconcile checks unrelated to connectors.yml and do not bear
on telegram C3.
