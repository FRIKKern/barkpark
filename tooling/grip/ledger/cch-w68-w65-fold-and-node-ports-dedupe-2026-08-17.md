# cch-w68 — re-derivation recipe: the cch-w65 fold and the node_ports_exhausted dedupe

Verifier lane `w65-fold-and-dedupe`, 2026-08-17. Every row below re-derives from scratch.

## Q1 — is the teardown reader wave 67 landed a person-visible NAMED SENTENCE?

    git show origin/main:cloud/priv/static/app.js | grep -n teardown_failed
    # → 13255, 13304 — BOTH ARE COMMENT LINES (the literal slug is prose-in-comments only)

    git show origin/main:cloud/priv/static/app.js | sed -n '13288,13440p'   # siteDeleteFailureCopy, 7 arms
    git show origin/main:cloud/priv/static/app.js | sed -n '13470,13518p'   # runSiteDelete → toast / ctl.fail
    git show origin/main:cloud/priv/static/app.js | grep -n 'confirmSiteDelete\|site-delete'
    # → 12436 renders <button id="site-delete">Delete</button>; 12143-12144 wires click → confirmSiteDelete

The reader dispatches on STATUS, not on the literal slug. Prove the statuses are the
teardown_failed statuses:

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'teardown_failed'
    # 7125:  json(conn, status, %{ok: false, error: "teardown_failed", detail: detail})
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '/def teardown/,/^  end/p' | grep -n '{:error,'
    # → 422 (box refusal), 422 (rollback_refusal wrap), 409 identity_refused (typed code), 502 unreachable

VERDICT: real prose, seven named arms, DOM-reachable. Not a key/comment mention.

## Q2 — node_ports_exhausted reader count

    git show origin/main:cloud/priv/static/app.js | grep -c node_ports_exhausted     # → 0 (rc 1)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n node_ports_exhausted  # → 6902 (503, singular detail)
    git show origin/main:cloud/priv/static/app.js | sed -n '346,392p'                 # friendly(): reads data.error, data.details — never data.detail
    git show origin/main:cloud/priv/static/app.js | sed -n '9611,9621p'               # siteCreateFailureCopy → friendly(data, "create failed (503)")

## Q3 — claim state of the three rows

    for t in cch-w65-bl-teardown-and-capacity-refusals-have-no-console-reader \
             cch-w67-bl-node-ports-exhausted-has-one-fact-and-two-owners-and-no-reader \
             cch-w66-bl-site-create-renders-the-raw-slug-and-drops-the-servers-menu; do
      bp task get $t -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['doc_id'] if 'doc_id' in d else '',d['lifecycle_status'],d.get('claim'),d['rev'])"
    done
    # all three: lifecycle open, claim None

## Q4 — criterion 4 of cch-w65 is payable

    gh pr view 11552 --json mergedAt,mergeCommit --jq '[.mergedAt,.mergeCommit.oid]|@tsv'
    # 2026-08-17T06:31:36Z  11412247df1db1293041c0adec4b5c0eb8e22250
    gh api repos/FRIKKern/barkpark/compare/11412247df1db1293041c0adec4b5c0eb8e22250...main --jq .status
    # ahead                                   ← the literal check criterion 3 (0-based) asks for
    gh api repos/FRIKKern/barkpark/compare/4b5d802a1d5a31030f79fa4eb8d4761eb4995db2...main --jq .status
    # identical                               ← #11553; use 11552 for this row

## Q5 — the merge-gate mechanics (autostamp is NOT the honest path here)

    git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '714,722p;785,800p;836,846p'
    # autostamp_merge_gate/6 fires only when landed is a non-empty map AND the criterion
    # carries the EXPLICIT "merge_gate" => true field; its evidence is literally
    #   "auto: UNVERIFIED merge-gate autostamp — no merge observed; caller-asserted …"
    sed -n '316,334p' internal/cli/tasks_stamp_cmd.go
    # the CLI tripwire keys on the criterion TEXT containing MERGE-GATED (case/space tolerant),
    # so a --met needs --merge-gated regardless of the stored field.
    bp task stamp --help    # --merge-gated is NOT printed; it is real (internal/cli/tasks_stamp_cmd.go:298)

Field check (which rows actually carry merge_gate:true):

    bp task get <id> -o json | python3 -c "import json,sys;[print(i,c['met'],c.get('merge_gate'),c['criterion'][:70]) for i,c in enumerate(json.load(sys.stdin)['doc']['content']['acceptance_criteria'])]"
    # cch-w65 idx 3 → merge_gate True   (autostamp COULD fire; explicit stamp is better evidence)
    # cch-w63 idx 9 → merge_gate None   (autostamp CANNOT fire — text-only marker)

## Q6 — stale anchors to not re-cite

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'content_binding_empty\|content_binding_required'
    # 6894 content_binding_required, 6919 content_binding_empty — NOT the 5834-5840 the w66 row cites
    git show origin/main:cloud/priv/static/app.js | grep -n 'siteCreateFailureCopy'
    # 9611 / 9708 / 23004 — NOT the 7301-7303 the w66 row cites
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7113,7126p'
    # the "ZERO readers" deferral comment cch-w65 criterion 1 targets is at ~7117, ALREADY
    # updated by W67 S2 ("THE DEFERRAL IS OVER") — that criterion is paid on main.
