# cch wave 38 — roster disposition + Law 0 re-derivation recipes (2026-08-07)

Every row below is a COMMAND, not a claim. origin/main at derivation time: `ef77af2748ceda54fdd6e078f71a6e6044b55439`.

## The denominator (157 open of 442 non-draft children)

    bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys,collections;c=[x for x in json.load(sys.stdin)['children'] if not str(x['doc_id']).startswith('drafts.')];print(len(c),collections.Counter(x['lifecycle_status'] for x in c))"
    # 442 Counter({'done': 249, 'open': 157, 'cancelled': 35, 'considering': 1})

Open INCLUDING `drafts.` twins is 170 — the 13-row gap is what makes a naive count disagree with the charter's.

## FALSE-OPEN proofs (each re-derivable in one command)

    # cch-w23-bl-pat-deploy-grant-survives-demotion — the demotion remedy IS on main
    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1844,1866p'
    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '983,991p'

    # cch-cloud-app-has-no-plug-errorhandler — refuted at router.ex:242 and :7931
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'Plug.ErrorHandler\|handle_errors'

    # cch-w11-s1-flip-behind-a-generator-that-cannot-lose — #8394 merged dcd8c9ce, live protection agrees
    git merge-base --is-ancestor dcd8c9ceff0e4505e5071ce8dbae7ee01aa0ac28 origin/main && echo ANCESTOR
    gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.contexts'
    git show origin/main:scripts/required-checks-generate.sh | grep -n 'S1-LOSS\|demoted='

    # cch-w28-s1-empty-roster-control-asserts-clause-a — #9356 merged 0a1b4d2e
    git merge-base --is-ancestor 0a1b4d2ea53be3cb507834f0663faae998e13de3 origin/main && echo ANCESTOR

    # drafts.* twins already merged: s3=#9850, s4-followup=#9688 (b3164194), w32-r2=#9685 (7ad181d1),
    # w34-s3=#9740, w35-s4=#9847 (b52225dd)
    git show origin/main:cloud/priv/static/app.js | grep -n 'function meState'

## Supersession (dispose, do not re-cut)

    gh pr view 9917 --json body -q .body | grep -o 'cch-w3[67]-s[16][a-z-]*'   # names cch-w36-s6
    gh pr view 9920 --json body -q .body | grep -o 'cch-w3[67]-[a-z0-9-]*'      # names cch-w36-bl-…-fix + cch-w37-s4

## The population is 18, and "Pin release" does not exist

    git show origin/main:cloud/priv/static/app.js | grep -ic 'pin release'      # 0
    git fetch origin loop-epic/a-census-that-reds-when-the-console-grow-3-r:refs/tmp/c9920 -f
    git show refs/tmp/c9920:cloud/priv/static/__binding_census.mjs | grep 'elevated: true' | grep -c 'predicate: null'   # 18

## Duplicate-title pairs (one `drafts.` twin each, filed by wave 37)

    bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys,collections;c=[x for x in json.load(sys.stdin)['children'] if x['lifecycle_status']=='open'];t=collections.defaultdict(list);[t[x['title']].append(x['doc_id']) for x in c];print([v for v in t.values() if len(v)>1])"
