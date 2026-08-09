# w32 verifier: PR merge state, #10400 supersession, Sobelow red, #10129/#10811 — re-derivation recipes

Run from the repo root. Every line below is the command that re-derives one claim.

## (a) #11364 and #11368 are MERGED, by mergeCommit ancestry (not by label)

    gh pr view 11364 --json number,state,mergeCommit,mergedAt,headRefName
    gh pr view 11368 --json number,state,mergeCommit,mergedAt,headRefName
    git fetch origin && for c in b03f3d8fc8d7ac77a0550de7adbfa681607dcf23 d9befa361e0aa5f7f935b389ceb095529e6c10e9; do \
      printf "%s " $c; git merge-base --is-ancestor $c origin/main && echo YES || echo NO; done

b03f3d8f (#11364) is also origin/main's tip; d9befa36 (#11368) is its parent.

## (b) #10400 carries NO test main lacks -> close as superseded

    git fetch origin pull/10400/head:pr10400tmp
    git show pr10400tmp:cloud/test/barkpark_cloud/deploy_ledger_test.exs | grep -o 'test "[^"]*"' | sort -u > /tmp/pr10400tests.txt
    git show origin/main:cloud/test/barkpark_cloud/deploy_ledger_test.exs | grep -o 'test "[^"]*"' | sort -u > /tmp/maintests.txt
    comm -23 /tmp/pr10400tests.txt /tmp/maintests.txt          # EMPTY = nothing unique on the PR
    wc -l /tmp/pr10400tests.txt /tmp/maintests.txt             # 78 vs 93

The rebase branch that actually landed is #11368's:

    git diff --stat 10245c3ea621f93ce18b6d8536aac811686227cc origin/main -- cloud/test/   # EMPTY
    git branch -r --list 'origin/loop-epic/the-content-api-s-own-status*'                 # the stranded branch

## (c) The Sobelow red on #11364 is a BASELINE LINE-SHIFT, not a new finding

Deciding command inside the job is `mix sobelow --skip --exit Low`; read only ITS output
(the reconcile step below it prints ~100 more findings that decide nothing).

    gh api 'repos/{owner}/{repo}/commits/31f25f7f7eae6e02e1966776eac3ab1d48a27a3e/check-runs?per_page=100' \
      --jq '.check_runs[]|select(.conclusion=="failure")|[.name,.details_url]|@tsv'
    gh run view --job 93276741401 --log > /tmp/sobelow.log
    sed -n '1365,1409p' /tmp/sobelow.log        # the deciding step: exactly 3 findings, then exit 1

Proof it is a shift, not a regression:

    git show origin/main:api/.sobelow-skips | grep -n CSRF                      # ...router.ex:521, :545, :604
    git show origin/main:api/lib/barkpark_web/router.ex | grep -n 'pipeline :session_token_root\|pipeline :user_auth\|pipeline :media_mutate'   # 539, 563, 622
    for L in 521 545 604; do git show 46b5373ed6:api/lib/barkpark_web/router.ex | sed -n "${L}p"; done   # same three pipelines

521->539, 545->563, 604->622: +18 on all three. #11364 touched only
api/lib/barkpark_web/controllers/error_json.ex and two tests — never router.ex:

    gh pr view 11364 --json files --jq '.files[].path'

And main itself is red on the same gate, so nothing merged unreviewed:

    for c in $(git log --format=%H -6 origin/main); do printf "%s " $c; \
      gh api "repos/{owner}/{repo}/commits/$c/check-runs?per_page=100" \
        --jq '[.check_runs[]|select(.name|startswith("Sobelow static"))|.conclusion]|join(",")'; echo; done

## (d) #10129 / #10811: real conflict sets, and whether either is superseded

GitHub's `mergeable: CONFLICTING` does not say WHICH files. Compute it:

    for p in 10129 10811; do git fetch origin pull/$p/head:pr${p}tmp; \
      git merge-tree --write-tree origin/main pr${p}tmp | grep CONFLICT; done

Neither payload has landed — both are live work, not superseded:

    git grep -n "coalesced_attempts\|CoalescedAttempts" origin/main -- internal/   # ZERO Go readers
    git grep -n "deploys_failing\|DeploysFailing" origin/main                      # ZERO hits anywhere
