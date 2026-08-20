# cch-w40 v3 — the LIVE S2 row set, re-derivation recipes (2026-08-07)

Baseline: `origin/main` = `95642c5500119d5ef5bb938a47516cacb5ab0f05`.

## 0. Materialize the three files this row talks about

    cd /Volumes/SATECHI/github/barkpark
    git show origin/main:cloud/priv/static/app.js            > /tmp/m.js
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/r.ex
    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex   > /tmp/a.ex
    git show origin/main:cloud/priv/static/__app.test.mjs    > /tmp/t.mjs

## 1. The population — 9 `status === 403` arms and 13 `status === 422` arms

    grep -nE 'status === 403|status === 422' /tmp/m.js
    grep -cE 'status === 403' /tmp/m.js   # 9
    grep -cE 'status === 422' /tmp/m.js   # 13

## 2. The two already-paid rows are ancestors of main

    gh pr view 9848 --json mergeCommit -q .mergeCommit.oid   # e20740837…
    gh pr view 9851 --json mergeCommit -q .mergeCommit.oid   # 5b7f1fd12…
    git merge-base --is-ancestor e20740837d8a1b9e8c6975f382effa779371539a origin/main && echo PAID-9848
    git merge-base --is-ancestor 5b7f1fd1268265f21e7a4e5bb595460aa1888773 origin/main && echo PAID-9851

## 3. DEFECT — attachDomain's bare 422 (app.js:6998) covers FIVE server slugs

    sed -n '6990,7002p' /tmp/m.js          # the arm
    sed -n '3596,3655p' /tmp/r.ex          # POST /v1/barkparks/:id/domain + attach_custom_domain
    sed -n '3680,3700p' /tmp/r.ex          # persist_and_enqueue_domain

Server 422s on that path: `domain_required` (3616), `domain_not_pointed`
(+expected_ip/observed, 3642), `invalid_domain` (3651 and 3697), `invalid`
(3690). The console renders one sentence — "Only <name>.barkpark.cloud domains
are supported for now." — which is FALSE for `domain_not_pointed` (external
FQDNs ARE supported, via DomainOwnership.pointed_at?) and discards a full
remediation payload. No test pin exists:

    grep -c 'barkpark.cloud domains' /tmp/t.mjs   # 0
    grep -c 'attachDomain' /tmp/t.mjs             # 0

## 4. DEFECT — envVarWriteFailureCopy 403 (app.js:18410) shadows the fence AND
##             is false on the cross-tenant arm

    sed -n '18404,18414p' /tmp/m.js
    sed -n '4390,4400p' /tmp/r.ex     # {:error, :barkpark_not_in_team} -> 403 bare (D396(5))
    sed -n '7610,7614p' /tmp/t.mjs    # the pin S2 must flip: /owners and admins/i

## 5. MINOR DEFECT — newSubmitSiteUrl 422 (app.js:17311)

    sed -n '17305,17316p' /tmp/m.js
    sed -n '3005,3010p' /tmp/r.ex     # audit-insert failure -> 422 {error:"invalid"}

The wire SUCCEEDED; the console says "That doesn't look like a URL" and points
at the input. Server comment itself calls it "a 422 the operator can simply retry".

## 6. MUST-CLEAR controls (honest AND unreachable — do NOT file)

    sed -n '10928,10932p' /tmp/r.ex                 # with_team_role
    sed -n '364,396p'   /tmp/a.ex                   # non-member -> 404, not 403
    git show origin/main:cloud/lib/barkpark_cloud/accounts/team_membership.ex | sed -n '39p'
    sed -n '4320,4334p' /tmp/r.ex                   # GET /v1/env-vars: only 401 | 422 no_team | 200
    sed -n '3796,3802p' /tmp/r.ex                   # vercel-deploy: not_deployable is the only 422

- `membersFailureCopy:18023` 403 — GET /v1/teams/:id/members gates at min_role
  "member"; rank("member")=1 is the floor, so the 403 branch is unenterable and
  a non-member gets 404. Also reached with a /v1/me status, and require_user
  (auth.ex:48-58) emits 401 only.
- `envVarsFailureCopy:18399` 403 — same: the read route cannot emit 403.
- `envVarsFailureCopy:18398` 422 — `no_team` is the route's ONLY 422.
- `newSubmitVercelDeploy:17247` 422 — `not_deployable` is the route's ONLY 422.

## 7. The crown-adjacent live liar, independently re-derived

    grep -n 'outranked\|cannot_grant_higher_role\|Auth.forbidden' /tmp/r.ex
    sed -n '233,236p' /tmp/m.js     # FORBIDDEN_REASON_COPY has ONE key: no_team

router.ex:4958 / :4997 send `reason: "outranked" | "cannot_grant_higher_role"`
with no `required` → forbiddenEvidenceCopy returns null → friendly() falls to
ERRORS.forbidden ("Only the team owner can manage billing.") on the members
screen. Filed as task-ed706f4e1c616f89.

## 8. Baseline suite is green before any edit

    node cloud/priv/static/__app.test.mjs   # rc=0, "# fail 0"
