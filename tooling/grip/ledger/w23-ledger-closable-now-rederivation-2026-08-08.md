<!-- doc-tier: cold | canonical-for: dr-w23-ledger-closable-now-rederivation | budget: 6000tok -->

# Wave 23 verify — the ledger-closable-now recipes (2026-08-08)

Every claim below re-derives from ONE command. Run them from the repo root on a quiet host.
Nothing here was mutated: this file is a recipe sheet, not a receipt.

## The epic rail census (408 rows)

    bp task get task-fb4fb869490b4213 -o json > /tmp/EPIC.json
    python3 -c "import json;ch=json.load(open('/tmp/EPIC.json'))['children'];from collections import Counter;print(Counter(c['lifecycle_status'] for c in ch))"
    # -> Counter({'open': 336, 'done': 66, 'cancelled': 6})

Fully-stamped done rows (met==total): **65**. Done-but-unmet: **exactly one**,
`dr-followup-start-reported-callers` at 0/4.

    python3 -c "import json;ch=json.load(open('/tmp/EPIC.json'))['children'];print([ (c['doc_id'],c['criteria_progress']) for c in ch if c['lifecycle_status']=='done' and c['criteria_progress']['met']<c['criteria_progress']['total']])"

Open rows one criterion from done: **36** (not 3 — the three named in the brief are a subset).

## (a) The three "free wins" — gating PRs

    for n in 9876 9887 9888 9889 9890 9905 10562 10019; do gh pr view $n --json number,state,mergedAt; done

- #9876 MERGED 2026-08-07T00:14:48Z · #9887 MERGED 2026-08-07T06:13:52Z
- #9888 MERGED 2026-08-07T00:50:57Z · #9889 MERGED 2026-08-07T00:35:41Z · #9890 MERGED 2026-08-07T00:15:03Z
- #9905 MERGED 2026-08-07T00:23:14Z · #10562 MERGED 2026-08-07T23:28:14Z
- **#10019 CLOSED, mergedAt null**

Merge-commit ancestry (all rc=0):

    for n in 9887 9888 10562; do sha=$(gh pr view $n --json mergeCommit -q .mergeCommit.oid); git merge-base --is-ancestor "$sha" origin/main && echo "$n $sha ANCESTOR"; done
    # 9887 c2eecb66d085cc8bf210a41054ea1a05af784866 ANCESTOR
    # 9888 dfa5e4dac8fa9fd9644ad8cbe2dce0c4eefe66a4 ANCESTOR
    # 10562 32c002490bb1ffe1372d5d0dea93b6c6539daf09 ANCESTOR

Required-context verdicts (Elixir gate / Cloud gate / Console gate / PR references an active task):

    gh pr view <n> --json statusCheckRollup -q '.statusCheckRollup[] | select(.name|IN("Elixir gate","Cloud gate","Console gate","PR references an active task")) | "\(.name) -> \(.conclusion)"'
    # 9887, 9888, 9889, 9890, 10562: all four SUCCESS on every one

## The claim state that decides the close command

    bp task get <id> -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['rev'],d['claim'])"

| row | rev | claim.worker | epoch | expired_at |
|---|---|---|---|---|
| dr-w5-s1-ladder-reaches-triage | f9f37431a83d960fa92e5b80523f4e8b | **null** | 8 | 2026-08-07T23:41:00Z (lapsed) |
| dr-w6-s1-land-the-stack | 5883298f32da799384217d9d09f56552 | **null** | 10 | 2026-08-07T23:41:00Z (lapsed) |
| dr-w19-s2-deploy-yml-can-scream | 559855cde5f8fd585915d622a737da30 | **null** | 8 | 2026-08-07T23:33:01Z (lapsed) |
| dr-w8-s6-raw-capture-stops-leaking | 8ac99ba0eb20124aae4ad50a3ba2a178 | **null** | 5 | 2026-08-07T02:41:00Z (lapsed) |
| dr-w2-s4-scrub-knows-our-own-token | — | `dr-w6-s3-ledger-repair` | 7 | **null — never expires** |
| dr-w2-s6-engine-one-extractor-… | — | `dr-w6-s3-ledger-repair` | 7 | **null — never expires** |

`bp task close --help`: *worker_id — Worker identity that holds the claim.* A null worker holds
nothing, so a lapsed row must be re-claimed first; the claim bumps the epoch and captures a fresh
work digest, which is also what stops the close 409ing `doc_changed_since_claim`.

Precedent that this is the route: `dr-w6-s3-the-proofs-and-the-ledger-repair` sat at claim epoch 6 /
worker null and was closed at **epoch 11**.

    bp task get dr-w6-s3-the-proofs-and-the-ledger-repair -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['doc']['claim'])"

## (b) drafts.dr-w6-s3 is a DUPLICATE, not a draft

    bp task get dr-w6-s3-the-proofs-and-the-ledger-repair -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['id'],d['status'],d['lifecycle_status'],d['criteria_progress'])"
    # dd069fb4-d7de-4a98-b579-8cab0b91ab0a published done {'met': 12, 'total': 12}
    bp task get drafts.dr-w6-s3-the-proofs-and-the-ledger-repair -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['id'],d['status'],d['lifecycle_status'],d['criteria_progress'])"
    # 79002182-36e3-44f8-9d2d-b25fb8dbe9fb draft open {'met': 8, 'total': 12}

Two DISTINCT doc ids on the same rail. The published row closed at 2026-08-07T23:03:33.717781Z; the
draft's `updated_at` is 2026-08-07T23:03:57.723466Z — **24 seconds after the close**. Publishing it
mints a second open row for finished work.

The gate on dr-w2-s4 / dr-w2-s6 is not the draft — it is a non-expiring claim held by worker
`dr-w6-s3-ledger-repair` at epoch 7. A second draft nobody named also sits on the rail:
`drafts.dr-w18-bl-boundary-continuity-gauge`, 0/4.

## (c) dr-w8-s6 — the substance landed, under another slice's PR

    git grep -n 'def raw(' origin/main -- cloud/lib/barkpark_cloud/failure_copy.ex
    # :390  def raw(value), do: value |> strip_ansi() |> scrub()
    git log --oneline -S'def raw(value), do: value |> strip_ansi() |> scrub()' origin/main -- cloud/lib/barkpark_cloud/failure_copy.ex
    # 8251f3a5c fix(cloud): four display boundaries stop shipping a colourised credential (#10710)
    gh pr view 10710 --json state,mergedAt   # MERGED 2026-08-08T09:53:29Z
    git grep -n 'FailureCopy.raw(' origin/main -- cloud/lib api/lib
    # router.ex:9307, router.ex:11119  (two live callers)

So `raw/1` entered main via **#10710 (dr-w22-s1)**, never via #10019. dr-w22-s1's own criterion 9
demands "the lead closes #10019 as superseded" — `gh pr view 10019` says CLOSED. Charter D386
(line 6144) records #10019 as "open, conflicting" at ruling time.

## (d) Spot-check of the 65 fully-stamped done rows — 5 of 65, all honest

| row | claim tested | re-derivation | verdict |
|---|---|---|---|
| dr-w17-s5-deploy-start-stops-laundering-refusals | "Deploy.start/1 is deleted" | `git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex \| awk '/^defmodule\|^  def start/{print NR": "$0}'` | HONEST — the 3 surviving `def start` are `@impl` Starter callbacks in TaskStarter/SyncStarter/NoopStarter (:2135/:2182/:2207); `Sites.Deploy` itself exposes only `start_reported/1` at :594 |
| dr-w12-s2-publish-clock-reader | new module + migration-sourced censor | `git cat-file -e origin/main:cloud/lib/barkpark_cloud/publish_clock.ex`; `git ls-tree -r --name-only origin/main -- cloud/priv/repo/migrations \| grep 20260807130000` | HONEST — module present, `20260807130000_create_content_publishes.exs` present |
| dr-w15-s3-emit-the-two-corpses | delivery node + refusal_phase reach the route | `git grep -n 'DeployLedger.delivery(' origin/main -- cloud/lib` → router.ex:9592; `git grep -n 'refusal_phase:' origin/main -- cloud/lib` → router.ex:11139 | HONEST — floor since raised 105→123, monotonic |
| dr-w16-s3-ledger-publics-declare-reachability | `not_attempted_classes/0` deleted | `git grep -n 'not_attempted_classes' origin/main -- cloud/lib/barkpark_cloud/deploy_ledger.ex` | HONEST — remaining hits are the module attribute `@not_attempted_classes` (:199, :358) and a tombstone comment (:336-337) naming dr-w16-s3; the public function is gone |
| task-ca88b8ea571b3470 | `/v1/agent/space` route exists | `git grep -n 'post "/v1/agent/space"' origin/main -- cloud/lib` → router.ex:1357 | HONEST |

**Zero fully-stamped false-dones in the sample.**

## The one done-but-unmet row is an UNSTAMPED TRUE-DONE, not a fabrication

    git grep -n 'Deploy\.start_reported(' origin/main -- cloud/lib
    # auto_deploy_worker.ex:304, template_freshness_worker.ex:296, router.ex:11712, router.ex:13303
    git grep -n 'Deploy\.start(' origin/main -- cloud/lib
    # 5 hits, ALL inside comments (auto_deploy_worker.ex:299, deploy.ex:584,
    #   template_freshness_worker.ex:291, router.ex:11658, router.ex:13291)

`dr-followup-start-reported-callers` is closed `done` at 0/4 while all four call sites are converted
on main. Its criteria were never flipped — the ledger under-reports here, it does not over-report.

## dr-w5-s1's "independent second review" has no recorded discharge

    grep -n 'independent second read before merge is a MANUAL LEAD STEP' .claude/workflows/bp-deploy-reliability-charter.md
    # 1729 — preceded at :1727 by "HIGH-FLIP-RISK, still owed: #9887's ladder ordering and bucket boundary"

#9887 merged 2026-08-07T06:13:52Z regardless. What DID land is D68's corrected boundary
(attention ≤8, in-flight 9-10, healthy 11):

    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '250,262p'
    # "behind" sits at index 7 → rank 8 (attention); "removing" 9, "provisioning" 10, "ok" 11

## Branch-delivery re-derivation (priority 0 of the direction, re-confirmed)

    git ls-remote --heads origin | grep -E 'the-control-plane-stops-calling-a-box-2|deploy-self-tests-stop-skipping|delivery-gauge-stops-being-dark'
    # ZERO output — all three dr-w21 slices are STILL unpushed as of 2026-08-08T10:4xZ
    git ls-remote --heads origin | grep 'the-raw-failure-capture-stops-leaking'
    # 654521cdf4fbd15e52de4780c24041a1b800b35b refs/heads/loop-epic/the-raw-failure-capture-stops-leaking-a--5-r  (its PR #10019 is CLOSED)
