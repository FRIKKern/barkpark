# Re-derivation recipe — sibling-ETS-atomicity wave: ledger residues + epic roster (2026-08-19)

Scope: confirm the two already-filed rows are unclaimed, that their criteria are exactly what
this wave satisfies, and enumerate the epic's full child roster so decide does not re-file.

## The two rows (both OPEN, both UNCLAIMED at 2026-08-19)

    bp task get acpc-bl-ets-bound-class-census-residues -o json \
      | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"],d["claim"],d["assignee"],d["rev"])'
    # open None None aa74bd52cbd4dc3f83820b1de619adc6

    bp task get acpc-bl-graph-corpus-ttl-sweep-frees-live-slots -o json \
      | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"],d["claim"],d["assignee"],d["rev"])'
    # open None None 3081c31b95a9fe4d22b9234c1c77b73c

Criteria, verbatim keys:

    bp task get <id> -o json | python3 -c 'import json,sys;[print(i,c["criterion"]) for i,c in enumerate(json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"],1)]'

## The roster verb (bp task ls has NO --parent / --tag)

    bp task ls --help            # flags: --limit, --offset, --all ONLY
    bp task ls --tag audit -o json
    # {"error":{"code":"usage","message":"unknown flag --tag for task ls"},"ok":false}

Working verb — the PARENT task carries children:

    bp task get api-controller-plug-correctness-audit -o json \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["child_count"]);[print(x["doc_id"],x["lifecycle_status"],x["title"][:70]) for x in d["children"]]'
    # 29 children

`bp doc get task <id> -o json` does NOT carry children (no such key) — use `bp task get`.

CAUTION: child summary objects carry ONLY
`['criteria_progress','doc_id','execution_class','inserted_at','lifecycle_status','title']`.
No claim/assignee. A `.get("claim")` over the roster prints None for rows that ARE claimed
(acpc-w2-ratelimiter-cas-atomic-debit is in_progress, claim epoch 6, worker
`epic-builder-ratelimiter-commit-the-token-bucket-debi`). Claim truth = per-row `bp task get`.

## Fence facts re-derived from origin/main (not the worktree)

    git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | sed -n '1299,1360p'
    # 1300 ensure_graph_corpus_slots(); 1301 sweep; 1305 insert; 1307 size>max -> delete own
    # 1332-1337 sweep: deadline <= now OR not Process.alive?(pid) -> delete
    # 1354-1358 ensure_graph_corpus_slots/0 lazy :ets.new ON THE REQUEST PATH

    git show origin/main:api/lib/barkpark/application.ex | grep -n init_graph_corpus_slots
    # 21:    BarkparkWeb.TasksController.init_graph_corpus_slots()

    git show origin/main:cloud/lib/barkpark_cloud/accounts/two_factor_rate_limiter.ex | sed -n '50,60p'
    git show origin/main:cloud/lib/barkpark_cloud/device_auth/rate_limiter.ex | sed -n '85,95p'
    # both: :ets.select_delete(@table, [{{{key, :"$1"}, :_}, [{:"/=", :"$1", window}], [true]}])
    # comments state the sweep's PURPOSE is unbounded-table-growth, not correctness.

## Duplicate check

    bp search query "stale window select_delete newer window bound reset limiter" -o json
    # no task row for the sweep bound-reset other than residues criterion 1.
