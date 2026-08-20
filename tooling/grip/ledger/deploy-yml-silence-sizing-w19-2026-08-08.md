# deploy.yml silence — sizing recipe (wave 19 verify, v4-deploy-yml-silence)

Re-derivation recipes for the claims in the wave-19 verify packet. Every row is
one literal command. Counts drift forward in time; the SHAPE does not.

## 1. Thirty days of deploy.yml run conclusions (workflow id 304821157)

    gh api --paginate -X GET repos/:owner/:repo/actions/workflows/304821157/runs \
      -f per_page=100 --jq '.workflow_runs[] | {id,conclusion,created_at}' \
    | python3 -c 'import sys,json,datetime,collections
rows=[json.loads(l) for l in sys.stdin if l.strip()]
cut=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=30)).isoformat()
r=[x for x in rows if x["created_at"]>cut]
print(len(r),collections.Counter(x["conclusion"] for x in r))'

Measured 2026-08-08: 1378 runs / success 932 / cancelled 344 / failure 102.
NOTE `gh run list --limit 1000` CAPS at 1000 and silently truncates the window
to ~24 days — use the paginated API form above, not `gh run list`.

## 2. The 49-hour dark window (the sizing fact)

    # same fetch as (1), then:
    # window 2026-07-21T07:59:48Z .. 2026-07-23T08:46:54Z
    # → 121 runs: 84 failure, 37 cancelled, ZERO success

## 3. Which job / step failed, per failing run

    gh api repos/:owner/:repo/actions/runs/<RUN_ID>/jobs \
      --jq '.jobs[] | select(.conclusion=="failure") | .name + " :: " + ([.steps[]|select(.conclusion=="failure")|.name]|join(","))'

Over the 102 failures: control-plane/Deploy control plane over SSH = 84,
instance/Deploy content instance over SSH = 17, instance/Smoke test = 1.

## 4. Which instance-deploy.sh exit codes actually reached CI

    gh api repos/:owner/:repo/actions/jobs/<JOB_ID>/logs | grep 'Process completed with exit code'

Observed set over 30 d: 11 x12, 12 x1, 13 x1, 255 x1, 1 x1. **exit 15 (`gave up
waiting for the deploy lock`, instance-deploy.sh:144) has NEVER fired.**

## 5. The grep (reporting constructs in deploy.yml)

    git show origin/main:.github/workflows/deploy.yml | grep -n 'failure()\|always()\|notify\|continue-on-error'; echo rc=$?
    # rc=1 — zero matches across 158 lines

## 6. Every human-visible CI alert this repository has ever produced

    gh issue list --state all --search 'CI failure in:title' --limit 20 --json number,title,createdAt

Two, ever: #4966 (2026-07-20, zz-alert-proof), #5658 (2026-07-22,
paper-readers). Neither is a deploy.

## 7. The reporter already exists on main; only the wiring is missing

    git ls-tree origin/main scripts/ | grep file-ci-failure-issue
    git grep -n 'report-main-failure' origin/main -- .github ; echo rc=$?   # rc=1, absent
    gh pr view 10155 --json state,files
