# cch-w37 — who consumes the wire label `scope: "primary_team"`? (VERIFY, 2026-08-06)

Baseline: `origin/main` = `bf97452bb38488d04cfbb596c2528a3f34ad5baf`.
Question: does anything OUTSIDE `cloud/priv/static/app.js` consume or document the
403 evidence field `scope: "primary_team"`? Decides slice 3's size.

## RECIPE 1 — every file on main containing `primary_team`, ranked

    cd /Volumes/SATECHI/github/barkpark
    git grep -c 'primary_team' origin/main -- . | sort -t: -k3 -rn

32 files. ZERO under `internal/`, ZERO under `js/`, ZERO under `api/`,
`docs/openapi.json` = 0. Only two `docs/` hits (`docs/swarm/teams-invitations.md`,
`docs/swarm/_INTEGRATION-LOG.md`), both `doc-tier: human`, and both name the
FUNCTION, never the wire label.

## RECIPE 2 — the wire label itself (string literal), every occurrence

    git grep -n '"primary_team"' origin/main

Emitters (2): `cloud/lib/barkpark_cloud/web/auth.ex:420` (admin), `:447` (owner).
Elixir test pins (3, all full-map `==`):
  `cloud/test/barkpark_cloud/web/router_ability_matrix_test.exs:392`, `:408`
  `cloud/test/barkpark_cloud/web/router_test.exs:2147`
JS fixture literals (6, NONE assert on the field):
  `cloud/priv/static/__app.test.mjs:15372, 15400, 15421(negative), 15429, 15487`
  `cloud/priv/static/__preview__/scenarios.mjs:4353`
Console: `app.js:249` — a COMMENT saying the field is never interpolated.

## RECIPE 3 — the bp CLI / TUI decodes only `error`

    git show origin/main:internal/cloudclient/client.go | sed -n '252,265p;1972,2000p'
    git grep -n 'json:"scope"' origin/main -- internal js

`cloudError` decodes `struct{ Error string \`json:"error"\` }`. `CloudRouteError`
carries `{HTTPStatus, Code}` only. No Go type anywhere in `internal/` or `js/`
has a `scope` or `required` field bound to a refusal body. The only `json:"scope"`
hits are `internal/cli/export_cmd.go:50` (export scope) and three pdrender chat
golden tests — unrelated.

## RECIPE 4 — the Go tree builds; one PRE-EXISTING unrelated failure

    T=$(mktemp -d); git archive origin/main internal go.mod go.sum | tar -x -C $T
    cd $T && CC=clang go build ./... && go test ./internal/cli/... 2>&1 | tail -8

Build: clean. Test: `--- FAIL: TestBuildLocalPlanNoCloneInsideCheckout`
(`internal/cli/setup/local_test.go:192`) — an environment artifact (the extracted
tree is inside a checkout), nothing to do with auth or `scope`.

## RECIPE 5 — the two admin gates run behaviourally IDENTICAL predicates

    git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '1037,1045p'
    git show origin/main:cloud/lib/barkpark_cloud/accounts/authz.ex | sed -n '46p;60,76p'
    git show origin/main:cloud/lib/barkpark_cloud/accounts/team_membership.ex | sed -n '45p'

`Accounts.team_admin?/2` = `get_membership` → `TeamMembership.admin?(role)` =
`rank(role) >= rank("admin")`. `Authz.team_admin?/2` = same `get_membership` →
`role in ~w(owner admin)`. Same set {owner, admin}; unknown role false in both.
`require_primary_team_owner` and `require_team_owner` BOTH call
`Authz.team_owner?/2` — byte-identical predicate.

## RECIPE 6 — nothing branches on the 422/403 no-team split of the gated routes

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'Auth.require_primary_team'
    git grep -n 'no_team' origin/main -- cloud/test internal js

Ten gated routes: `/v1/onboarding`(1510), `/v1/audit`(1939),
`DELETE /v1/barkparks/:id`(1978), `.../self-update`(2991), `.../rollback`(3128),
`.../autoupdate`(3252), `.../domain`(3548), `/v1/billing/checkout`(5113),
`/portal`(5154), `/cancel`(5189).
NO test asserts `422 no_team` on ANY of the ten — the only `422 no_team` pins are
`router_pat_test.exs:98-104` (`POST /v1/tokens`, inline cond) and
`router_test.exs:1858-1865` (SSE `?ticket=`, inline).
The ONE bp-CLI `no_team` branch is `internal/cli/cloud_support_cmd.go:643`, on
`POST /v1/fleet/supports`, whose 422 is emitted INLINE at `router.ex:2067` — not
by either gate.
`app.js` never checks status 422 for any of the ten (its 422 branches are
invalid_otp / not_enrolled / provider_not_connected / not_promotable /
no_build_source / not_rollbackable / no_previous / instance_not_live /
provider_unverified).

## RECIPE 7 — the FUNCTION-NAME blast radius the backlog row omits

    git grep -n 'require_primary_team' origin/main -- cloud/test

`router_moduledoc_table_test.exs:132-133` (`@guard_tier` map) and
`router_head_fence_census_test.exs:97-98` (`@session_wrappers` list) pin the
function NAMES. TRAP for a merge: `@guard_tier` contains `require_team_admin`
but NOT `require_team_owner`, and a guard missing from that map is treated as
UNRESOLVED → red. Collapsing `require_primary_team_owner` into
`require_team_owner` therefore reds `router_moduledoc_table_test.exs` unless the
map gains a `"require_team_owner" => "owner"` row in the SAME commit.
