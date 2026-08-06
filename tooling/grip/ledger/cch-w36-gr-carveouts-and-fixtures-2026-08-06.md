# cch-w36 verifier recipe — GR carve-outs + GR33 plain-member fixture inventory

Re-derivation recipes only. Every row is one literal command against `origin/main`
at `070c7584b820745e1ac8377ca6926edef6d2f257`. No line number in this file is
authority — re-run the command.

## GR text (the three rulings a slice would contradict)

    git show origin/main:.claude/workflows/bp-cloud-gui-remake-charter.md | sed -n '23p;49p;52,58p;69p;73p'

GR9 = line 23 (operator principal; "Never gate on team role"), GR33 = line 49
(settings anatomy + PLAIN-MEMBER LAW), GR36 = lines 52-58 (per-page rulings;
G-01 carries `ERRORS.forbidden`), GR46 = line 69 (closes
`gr-backlog-portal-retry-sentence` BECAUSE `ERRORS.forbidden` exists), GR49 =
line 73 (fail-closed operator bounce, ORDERED).

## D157 / D191 (the carve-out shape and the inheritance that makes it binding)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '443p;479p'

## Fixture inventory — plain-member scenarios that exist today

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'me(.*"member")'
    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'deepLink:' | awk -F'deepLink: ' '{print $2}' | sort | uniq -c | sort -rn
    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'Denied'

Six member scenarios; the default `me()` role is `"owner"`
(`role: role || "owner"`), so any scenario NOT passing a third arg is an owner.

## The client predicates and the gate they guess at

    git show origin/main:cloud/priv/static/app.js | grep -n 'role === "owner"'
    git show origin/main:cloud/priv/static/app.js | grep -n 'function operatorVisible\|function operatorRouteAllowed'
    git show origin/main:cloud/priv/static/app.js | grep -n 'function readFailureCopy\|function friendly\|forbidden:'

## The server half

    git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | grep -n 'forbidden(conn\|defp forbidden'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -c '403, %{error: "forbidden"}'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'get "/v1/audit"' -A 2

## Existing census precedents (scan-the-router shape)

    git show origin/main:cloud/test/barkpark_cloud/web/router_ability_matrix_test.exs | head -45
    git show origin/main:cloud/test/barkpark_cloud/accounts/role_agreement_census_test.exs | head -30

## Smoke assertions the GR49 ADD must not break

    git show origin/main:cloud/priv/static/__preview__/smoke.mjs | sed -n '/"operator-denied"/,/^  },/p'
    git show origin/main:cloud/priv/static/__preview__/smoke.mjs | grep -n 'toast-stack'
