# cch-w37 verifier — refusal reachability + the two forevers (2026-08-06)

Main at `bf97452bb38488d04cfbb596c2528a3f34ad5baf`. Every row below re-derives from origin/main.

## Re-derive the population (ELEVEN, not twelve)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'error: "forbidden"'
    # => 2059 2223 4303 4339 4361 4648 4664 4877 4910 5056 8291

## Re-derive D396(5)'s two PERMANENT exclusions BY CONTENT (never by line)

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -E '^\| D396 \|' | fold -w 200
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4335,4342p'   # {:error, :barkpark_not_in_team} -> 403   (w35 :4308)
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4662,4666p'   # not admin? and not self_scopable_address? (w35 :4633)

## Re-derive the anti-escalation rank-relativity (:4877 / :4910)

    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1711,1727p'   # remove_member_as/3  -> outranks?/2
    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1782,1808p'   # update_member_role_as/4 -> can_grant? + outranks?
    git show origin/main:cloud/lib/barkpark_cloud/accounts/authz.ex | sed -n '105,113p'

## Re-derive :4664 unreachability

    git show origin/main:cloud/priv/repo/migrations/20260626190000_create_users.exs | grep 'add :email'  # null: false
    git show origin/main:cloud/lib/barkpark_cloud/accounts/user.ex | sed -n '31p;160,168p'               # @email_format + validate_email
    # both register_user and oauth_changeset route through validate_email/1 — no bypass

## Re-derive the :4648 status asymmetry

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/r.ex
    grep -n -A2 'is_nil(conn.assigns.current_team) ->' /tmp/r.ex | grep -oE 'json\(conn, [0-9]+, %\{error: "[a-z_]+"' | sort | uniq -c | sort -rn
    # => 13 x 422 no_team, 1 x 403 forbidden (that one is :4648)

## Re-derive the client half

    git show origin/main:cloud/priv/static/app.js | sed -n '280,297p'   # friendly(): ERRORS[key] wins before data.details
    git show origin/main:cloud/priv/static/app.js | sed -n '192p;207p'  # ERRORS.no_team / ERRORS.forbidden
    git show origin/main:cloud/priv/static/app.js | sed -n '3140,3142p' # notifDeliveriesErrorHtml — hardcoded TRANSIENT copy
    git show origin/main:cloud/priv/static/app.js | sed -n '3573,3578p' # first-page 403 never reaches friendly()

## Re-run the executed reachability probe

    T=$(mktemp -d); git archive origin/main cloud | tar -x -C $T
    cp -R /Volumes/SATECHI/github/barkpark/cloud/deps $T/cloud/deps
    cp -R /Volumes/SATECHI/github/barkpark/cloud/_build $T/cloud/_build
    cd $T/cloud && CC=clang MIX_ENV=test mix compile
    # probe body: /private/tmp/claude-501/.../scratchpad — 14 cases, one per site + 2 controls
    cd $T/cloud && CC=clang mix test test/barkpark_cloud/web/router_ability_matrix_test.exs   # 26 tests, 0 failures

## Blast radius of adding fields to the eleven literals

    cd $T/cloud && grep -rn '%{"error" => "forbidden"}' test | wc -l   # => 0 full-map pins
    cd $T/cloud && grep -rn 'forbidden' test | wc -l                   # => 83 references, all key-indexed
