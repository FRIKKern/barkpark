# v3-retry-gate-divergence — re-derivation recipes (wave 46, 2026-08-07)

Tree under test: `origin/main = 77cf2060cf5e69c13da2837c678ae6e9ea47d7e6`
(NOT `0cb4300a4` — main moved; the primary checkout is 585 commits behind and
its `cloud/lib` predates the evidence-carrying `forbidden/2`, so probing it
returns bare `{"error":"forbidden"}` and is a TRAP).

## R0 — build a runnable full-tree extraction of origin/main

    D=/tmp/om; rm -rf $D; mkdir -p $D
    cd /Volumes/SATECHI/github/barkpark && git archive origin/main | tar -x -C $D
    cp -R /Volumes/SATECHI/github/barkpark/cloud/deps $D/cloud/deps
    cd $D/cloud && CC=clang MIX_ENV=test mix compile
    CC=clang MIX_ENV=test mix ecto.drop --quiet; CC=clang MIX_ENV=test mix ecto.create --quiet
    CC=clang MIX_ENV=test mix ecto.migrate

## R1 — which gate guards each `/v1/barkparks` route (derived, not read)

    cd $D/cloud && awk '/^  (get|post|put|patch|delete) "\/v1\/barkparks/{r=$0; l=NR} /Auth\.require_(team_admin|primary_team_admin|team_owner|primary_team_owner|user_or_pat|user)\(/{if(r!=""&&NR-l<8){print l": "r"  ==> "$0; r=""}}' lib/barkpark_cloud/web/router.ex

## R2 — the three-probe divergence test

Probe source: `scratchpad/retry_gate_divergence_probe_test.exs` (copy into
`$D/cloud/test/`, run with `CC=clang mix test test/retry_gate_divergence_probe_test.exs --trace --seed 0`).
Probes: (A) teamless user through all five routes; (B) multi-team member who is
`member` of the PRIMARY team and `admin` of a SECOND team, with and without
`x-barkpark-team`; (C) plain member of the selected team.

## R3 — the mutation that proves R2 can lose

    # in $D/cloud/lib/barkpark_cloud/web/auth.ex, replace
    #   def require_team_admin(conn, opts), do: gate_role(conn, opts, &Authz.team_admin?/2, "admin")
    # with
    #   def require_team_admin(conn, opts), do: gate_role(conn, opts, &Authz.team_owner?/2, "owner")
    # then re-run R2: retry's pinned-other arm flips 201 -> 403 required:"owner"
    # while rollback/domain/autoupdate stay on their unmutated answers.

## R4 — the console half

    git show origin/main:cloud/priv/static/app.js | sed -n '110,120p'      # x-barkpark-team pinned on EVERY authed request
    grep -n "noAuth" $D/cloud/priv/static/app.js                            # no lifecycle write opts out
    grep -n "no_team" $D/cloud/priv/static/app.js                           # arms for BOTH wire shapes (:192 422, :275 403 reason)
    grep -n "instanceAdminAuthority" $D/cloud/priv/static/app.js            # 4 hits: :6937 :6943 call sites, :14288 def

## R5 — the MUST-RUN command in the brief does not exist

    git show origin/main:cloud/test/barkpark_cloud/web/auth_test.exs
    # => fatal: path ... does not exist in 'origin/main'
    # Live substitutes, all green on origin/main:
    #   test/barkpark_cloud/web/router_refusal_authority_probe_test.exs  (11 tests)
    #   test/barkpark_cloud/web/router_me_authority_test.exs              (6 tests)
    #   test/barkpark_cloud/accounts/role_agreement_census_test.exs       (11 tests)
