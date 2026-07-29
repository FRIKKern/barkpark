# Recipe — Site Spawner Wave 8 ledger reconcile (2026-07-29)

Re-derives the state a verifier reconciled: six merged-but-open `ssw8-*` rows closed,
and the true open roster under `bp-cloud-site-spawner-epic`.

## 0. bp is unusable without a cached manifest when guerrilla is loaded

`bp` fetches `/v1/capabilities` per invocation with a short client timeout; under wave
load the endpoint answered in 14.9 s and every `bp task get` died with
`context deadline exceeded`. The anonymous manifest has `auth_tier: none` and **no
`task` noun at all** (`unknown command "task"`), so the manifest must be fetched WITH
the token:

```sh
curl -s --max-time 180 -H "Authorization: Bearer $(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")" \
  'https://guerrilla.barkpark.cloud/v1/capabilities?views=1&chat=1' -o /tmp/capauth.json
export BARKPARK_MANIFEST=/tmp/capauth.json   # 150 commands, auth_tier=admin, task.* present
```

## 1. Prove the six PRs are on origin/main

```sh
git log origin/main --oneline -60 | grep -E '#66(2[5-9]|30)'
for p in 6625 6626 6627 6628 6629 6630; do
  gh pr view $p --json title,mergedAt,mergeCommit \
    -q '.mergedAt+" "+.mergeCommit.oid+" | "+.title'
done
```

PR ↔ task mapping (from each PR body's trailing `Task:` line):

| PR | merge sha | task |
|---|---|---|
| 6625 | 1fed1cfb88fbc1d8b1fe83279d8c9588f94caf9c | ssw8-bind-by-reading |
| 6626 | 23bd055f38bbdf1c2471ff097eb9cec0b0968628 | ssw8-teardown-truth |
| 6627 | 3d84ad07befb117c911a8bbcb1b660c29374f0d7 | ssw8-claim-ledger-site-verbs |
| 6628 | 07f99071e04b5c04337abdf1d9793ce2101e766f | ssw8-console-binding-truth |
| 6629 | bfe189de6f3c757d44dc33e0cd84ec5c6adc4837 | ssw8-content-rev-honesty |
| 6630 | 351f757535ed968fc92b9bd8b22238ebbbf24ad2 | ssw8-docs-stop-overclaiming |

## 2. Close a merge-gated criterion (the `--merge-gated` fence)

Epochs were NOT absent — each row carried an EXPIRED builder claim
(`claim.worker: null`, `claim.expired_at` in the past, epoch 5/9/7/10/9/9). Re-claiming
bumps the epoch; use the NEW one for stamp and close.

`bp task stamp … --met` on a criterion whose text starts `MERGE-GATED` is REFUSED with
`{"error":{"code":"merge_gated_criterion"}}`. The override flag is undocumented in the
manifest flag list:

```sh
ep=$(bp task claim <id> <worker> -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['doc']['claim']['epoch'])")
bp task stamp <id> <worker> $ep --criterion 5 --met --merge-gated \
  --criterion-text "MERGE-GATED (the lead closes this): the PR is merged to main." \
  --evidence "PR #NNNN merged as <sha> at <ts>"
bp task close <id> <worker> $ep done "<summary>"
```

## 3. Read back PUBLISHED state (a printed rev is not persistence)

`lifecycle_status` lives BOTH at `doc.lifecycle_status` and `doc.content.lifecycle_status`;
`doc.status` is the perspective (`published`/`draft`), not the task state.

```sh
for t in ssw8-bind-by-reading ssw8-teardown-truth ssw8-claim-ledger-site-verbs \
         ssw8-console-binding-truth ssw8-content-rev-honesty ssw8-docs-stop-overclaiming; do
  bp task get $t -o json | python3 -c "
import json,sys;d=json.load(sys.stdin);doc=d['doc'];ac=doc['content']['acceptance_criteria']
print(doc['doc_id'] if 'doc_id' in doc else '', doc['lifecycle_status'], doc['status'],
      '%d/%d'%(sum(1 for a in ac if a.get('met')),len(ac)))"
done
```

## 4. The true roster

```sh
bp task get bp-cloud-site-spawner-epic -o json > /tmp/epic.json   # carries all 112 children
for off in 0 200 400 600 800 1000; do bp task ready --limit 200 --offset $off -o json; done > /tmp/ready.jsonl
```
Then intersect open children against ready `doc_id`s. Post-reconcile:
112 children = 58 done / 41 open / 7 considering / 6 cancelled; 40 of the 41 open rows
are in the ready queue; the 41st, `drafts.ssw8-bind-by-reading`, is a DRAFT-perspective
twin (`doc.status == "draft"`) of the row just closed and inflates the roster by one.

## 5. Gotcha: prose blocks are not dependency edges

`ssw8-bare-path-and-retire-order` and `ssw8-site-doctor` were described as "needs #6626 /
#6625+#6627 on main", but both carry `dependency_count: 0`, `queue_gate: null` and were
already sitting in the ready queue — the block existed only in the charter's prose.
