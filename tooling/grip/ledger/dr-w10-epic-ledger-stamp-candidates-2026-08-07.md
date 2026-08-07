# dr-w10 — epic ledger stamp candidates: re-derivation recipe (2026-08-07)

Verifier lane `epic-ledger-stamp-candidates`. Every number below re-derives from these
commands. No mutations were made; this file records HOW, not a claim that it was done.

## 0. Board census (child_count 166, not 164)

    cd /Volumes/SATECHI/github/barkpark
    bp task get task-fb4fb869490b4213 -o json > /tmp/epic.json
    python3 -c "import json,collections;ch=json.load(open('/tmp/epic.json'))['children'];print(len(ch),collections.Counter(c['lifecycle_status'] for c in ch))"
    # 166 Counter({'open': 152, 'done': 12, 'cancelled': 2})   <- in_progress is ZERO

## 1. Zero-criteria children (vacuous for every percent-complete instrument)

    python3 -c "import json;ch=json.load(open('/tmp/epic.json'))['children'];print([(c['doc_id'],c['lifecycle_status']) for c in ch if (c.get('criteria_progress') or {}).get('total',0)==0])"
    # 17 total: 15 open, 1 done (task-ca88b8ea571b3470), 1 cancelled (dr-w5-followup-gyl-dooodo-host-keys)

Five of the 15 open ones are named in a merged PR — and all five are FILED-BY, not
DONE-BY, that PR (they are `*-followup-*` rows the PR created). This is the exact
false-positive class the assignment warned about:
dr-bl-graph-phantom-id-exposure(#9613), dr-followup-start-reported-callers(#9615),
dr-w3-s3-followup-capacity-code-handshake(#9783),
dr-w3-s6-followup-unavailable-tint(#9825),
dr-w8-s5-followup-serve-stderr-is-discarded(#10018).

## 2. The 30 / 45 / 20 cut (mention-in-merged-PR)

    gh pr list --state merged --limit 300 --json number,title,body --search 'merged:>=2026-08-04' > /tmp/merged.json
    python3 - <<'EOF'
    import json
    prs={x['number']:((x['title'] or '')+'\n'+(x['body'] or '')) for x in json.load(open('/tmp/merged.json'))}
    rows=[]
    for c in json.load(open('/tmp/epic.json'))['children']:
        if c['lifecycle_status']!='open': continue
        cp=c.get('criteria_progress') or {}
        if any(c['doc_id'] in b for b in prs.values()): rows.append((c['doc_id'],cp.get('met',0),cp.get('total',0)))
    mp=[r for r in rows if r[1]>0]
    print(len(rows),len(mp),sum(r[2]-r[1] for r in mp),sum(1 for r in mp if r[2]-r[1]==1))
    EOF
    # 60 30 45 20   <- reproduces the charter's 30 rows / 45 criteria / 20 one-short EXACTLY

Tighter cut (doc_id in an origin/main commit message since 2026-08-04):

    git log origin/main --since=2026-08-04 --pretty='%H%x00%s%x00%b%x01' > /tmp/commits.txt
    # -> 23 open rows, 21 with met>0, 34 criteria remaining, 13 one-short
    #    (charter said 19/42/9 — the board is live; the direction of the gap is that
    #     MORE rows are one-short today than when the direction was written)

## 3. Why 26 of the 45 are stampable: the unmet criteria are merge paperwork

    for f in /tmp/t_*.json; do python3 -c "…print unmet criteria…" $f; done
    # 41 of the 45 unmet criteria on those 30 rows are the LEAD-owned merge gate
    # ('the PR is merged to main', 'all four required contexts green').

Merge state of every named PR (32 PRs) — all MERGED, all merge commits ancestors of
origin/main:

    for n in 9613 9614 9615 9616 9617 9727 9729 9730 9731 9732 9733 9734 9824 9827 \
             9876 9888 9889 9890 9905 9929 9930 9953 9959 9960 10016 10017 10018 \
             10020 10079 10080 10081 10082; do
      read st oid < <(gh pr view $n --json state,mergeCommit --jq '[.state,(.mergeCommit.oid//"none")]|@tsv')
      git merge-base --is-ancestor $oid origin/main && echo "$n $st $oid ancestor=YES"
    done
    # 32/32 MERGED, 32/32 ancestor=YES

## 4. THE TRAP IN THE MERGE-GATE CRITERION ITSELF

Ten of these criteria say to read "all four required contexts green ON THE MERGE COMMIT".
That sentence is unsatisfiable as written:

    gh api "repos/FRIKKern/barkpark/commits/<merge-sha>/check-runs?per_page=100" \
      --jq '[.check_runs[]|select(.name=="PR references an active task")]|length'
    # 0 on EVERY merge commit checked (19/19)

Cause, verbatim from origin/main:

    git show origin/main:.github/workflows/pr-task-gate.yml | grep -n -A2 '^on:'
    # 69:on:
    # 70-  pull_request:

`pull_request` only — the task gate never fires on a push/merge commit, so it can never
be green there. Six of the 19 merge commits carry NO check-runs at all. The satisfiable
form is the PR-level rollup (`gh pr view <n> --json statusCheckRollup`), which the w8-era
criteria already switched to.

Related, and worth the lead's eye: merge commit `dbcb1288` (#9613) and `d008deae` (#9876)
each carry `Console gate=failure` — main itself has landed red on a required context.

## 5. The second D128 trap: REFUTED as stated

Claim under test: "PR references an active task" is a COMMIT STATUS, so a check-runs-only
verifier misses it. On a known-red PR head:

    sha=$(gh pr view 10069 --json headRefOid --jq .headRefOid)   # 8371d09e68e4ab9d72c8b95b91c8587fce888474
    gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs?per_page=100" --jq '.check_runs[]|[.name,.conclusion]|@tsv' | grep 'active task'
    # PR references an active task	failure          <- IT IS A CHECK-RUN
    gh api "repos/FRIKKern/barkpark/commits/$sha/status" --jq '{state:.state,total:.total_count,n:(.statuses|length)}'
    # {"n":0,"state":"pending","total":0}             <- ZERO commit statuses exist
    gh pr view 10069 --json statusCheckRollup --jq '.statusCheckRollup[]|select(.name=="PR references an active task")|[.__typename,.conclusion]|@tsv'
    # CheckRun	FAILURE

There are no commit statuses anywhere on this repo. The real invisibility is §4 above
(pull_request-only trigger ⇒ absent from merge commits), not a status-vs-check-run split.

## 6. Prior art — this repair has been FILED TWICE AND NEVER DONE

    bp search query "ledger stamp criteria merged PR unstamped"
    bp task get dr-bl-w8-stamp-sixteen-merged-and-unstamped-tasks -o json
    # open, criteria 0/5, parent task-fb4fb869490b4213
    bp task get dr-bl-w5-merge-gated-paperwork-is-unsatisfiable -o json
    # open, criteria 0/4
    # "Thirteen stale-open rows have MERGED PRs, and four are blocked FOREVER on
    #  'the PR body states X' for a PR that already merged"

Both are children of the epic. Both are still 0-met. The count has grown 13 -> 16 -> 30.

## 7. The one that proves bulk-stamping would fabricate

dr-w2-s6 (#9733) owes "The PR body states that dr-w2-s2 and this slice are two halves of
one repair":

    gh pr view 9733 --json body --jq .body | wc -c   # 4028
    gh pr view 9733 --json body --jq .body | grep -ic "s2"   # 0

The PR is merged; the sentence was never written. A merged-PR bulk stamp closes this
falsely. Read every criterion.
