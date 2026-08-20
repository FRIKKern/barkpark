# Re-derivation recipe — wave 56 VERIFY: the free closes, the honest denominator

Date: 2026-08-08. Scope: cloud-console-hardening epic, arrears census.
Everything below is a command, not a reading. No bp mutation was performed by
the verifier (role fence: verifiers do not mutate the ledger).

## 1. Roster shape and the honest denominator (372, not 380)

    bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys,collections;d=json.load(sys.stdin);print(d['child_count'],collections.Counter(c['lifecycle_status'] for c in d['children']))"
    # 761 Counter({'open': 378, 'done': 323, 'cancelled': 58, 'considering': 1, 'in_progress': 1})

The children view carries NO `dataset` / `status` field, so the drafts split is
not derivable from it. It IS derivable from the flat list:

    bp task ls --all -o json | python3 -c "
    import json,sys,collections
    d=json.load(sys.stdin)['docs']
    live=[x for x in d if x.get('parent_id')=='cloud-console-hardening-epic'
          and x.get('lifecycle_status') in ('open','in_progress','considering','researching','blocked')]
    print(len(live), collections.Counter(str(c.get('status')) for c in live))
    print('drafts.* doc_ids:', sum(1 for c in live if c['doc_id'].startswith('drafts.')))
    "
    # 380 Counter({'published': 372, 'draft': 8})
    # drafts.* doc_ids: 8

REFUTED en route: `dataset` is `production` for all 380. The drafts are marked
by `doc_id` prefix `drafts.` + `status: draft`, NOT by dataset. Anyone
re-deriving 372 via a dataset filter gets 380 and concludes the brief is wrong.

Of the 8: FIVE shadow an already-counted published row
(cch-w50-bl-fifteen-lapsed-trials…, cch-w54-s1…, cch-w53-s6…, cch-w50-s1…,
cch-w49-bl-required-checks-drift…) and THREE are probe junk (zz-p-a/zz-p-b).
So 372 is honest for two independent reasons, not one.

## 2. The one-criterion-short frontier (18 published-live rows)

    bp task ls --all -o json | python3 -c "
    import json,sys
    d=json.load(sys.stdin)['docs']
    pub=[x for x in d if x.get('parent_id')=='cloud-console-hardening-epic'
         and x.get('lifecycle_status') in ('open','in_progress','considering')
         and not x['doc_id'].startswith('drafts.')]
    for c in sorted(pub,key=lambda x:x['doc_id']):
        p=c.get('criteria_progress') or {}
        if p.get('total') and p['met']==p['total']-1:
            cl=c.get('claim') or {}
            print(c['doc_id'],p['met'],'/',p['total'],cl.get('epoch'),cl.get('expired_at'))
    "

## 3. Free-close eligibility = sole unmet criterion is MERGE-GATED **and** the PR merged

    for p in 10956 10957 10959 10962 10849 10850; do
      gh pr view $p --json number,state,mergedAt,mergeCommit -q '[.number,.state,.mergedAt,.mergeCommit.oid[0:9]]|@tsv'
    done

Required-context proof per merged head (NOT the rollup — `gh run list` lies):

    sha=$(gh pr view <N> --json headRefOid -q .headRefOid)
    gh api repos/:owner/:repo/commits/$sha/check-runs \
      --jq '.check_runs[]|[.name,.conclusion]|@tsv' | sort -u

CAVEAT reproduced on #10956 (head 933ba6bac): "PR references an active task" is
ABSENT from the check-runs feed while `gh run list --commit 933ba6bac` shows
`pr-task-gate success`. Absence in the feed is not absence of the run.

## 4. Claims are LAPSED — a bare close 409s

    date -u +%Y-%m-%dT%H:%M:%SZ      # 2026-08-08T15:29:47Z
    # every w55 slice claim.expired_at is 15:10–15:19Z → lapsed by minutes

Recipe (re-claim bumps the epoch AND resets the work digest, so the close that
follows cannot trip `doc_changed_since_claim`):

    bp task claim  <id> <worker>            # read `epoch` out of the response
    bp task close  <id> <worker> <epoch> done \
      --set 'criteria:=[{"index":<N>,"met":true,"evidence":"PR #<pr> merged <sha>","criterion":"<exact stored wording>"}]' \
      "merge-gated criterion discharged: PR #<pr> merged to main, four required contexts green"

`--criterion-text` / the `criterion` key is REQUIRED on every met=true entry;
an index-only flip is refused 409 criterion_text_required.
Shape proven without mutating:

    bp task claim cch-w55-s2-archive-does-not-stop-paying cch-w56-verifier-arrears --dry-run
    # POST https://guerrilla.barkpark.cloud/v1/tasks/…/claim  {"worker_id":"cch-w56-verifier-arrears"}

## 5. Digest claims re-derived on origin/main (not quoted)

    git show origin/main:cloud/config/config.exs | grep -nE '\{"[0-9*/ ,-]+",'
    # 14 crontab workers (the 15th grep hit, :265, is a comment) — none billing/dunning
    # {"0 * * * *", BarkparkCloud.Workers.TrialExpiryWorker}  ← positive control alive
    git grep -n clock_kinds origin/main -- cloud/test/barkpark_cloud/promise_actor_manifest_test.exs
    # :655 assert clock_kinds == [:crontab_absent, :crontab_row, :external_only, :synchronous]
    git show origin/main:cloud/test/barkpark_cloud/promise_actor_manifest_test.exs | sed -n 313,314p
    # defp resolve_clock(:synchronous), do: {:ok, "N/A — …"}   ← constant, CANNOT lose
    git grep -in remind origin/main -- cloud/lib | wc -l      # 0
    git grep -n stop origin/main -- internal/cli/cloud_instance_archive_cmd.go
    # :186 parseHzArgs(rest, valueFlags, []string{"fast","stop"}, usage)
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '^\| D[0-9]+' | sort -V | tail -1
    # D644
