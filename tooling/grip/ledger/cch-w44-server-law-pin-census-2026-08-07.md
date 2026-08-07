# cch-w44 — re-derivation recipes: is the member decision table PINNED?

Verifier `server-law-is-pinned`, wave 44, Cloud Console hardening. Tree: `origin/main` = `ba712a4b29ce5e6721b81a93343182654e47918f`.

## R1 — every test file that touches the two verbs (there are THREE, not two)

    git grep -ln 'remove_member_as\|update_member_role_as\|can_grant?\|outranks?' origin/main -- 'cloud/test/**'

The wave's MUST-RUN names only `authz_test.exs` + `role_agreement_census_test.exs`.
The file that actually pins the decision table is `cloud/test/barkpark_cloud/accounts_invitations_test.exs`
(describes at `:273` and `:324`) plus the two route files
`cloud/test/barkpark_cloud/web/router_invitations_test.exs` (`:301` / `:327`)
and `cloud/test/barkpark_cloud/web/router_refusal_authority_probe_test.exs` (`:126`).

## R2 — run the three suites

    cd cloud && CC=clang mix test test/barkpark_cloud/accounts/authz_test.exs \
      test/barkpark_cloud/accounts/role_agreement_census_test.exs
    cd cloud && CC=clang mix test test/barkpark_cloud/accounts_invitations_test.exs
    cd cloud && CC=clang mix test test/barkpark_cloud/web/router_invitations_test.exs \
      test/barkpark_cloud/web/router_refusal_authority_probe_test.exs

## R3 — the CELL PROBE (the unpinned cells, derived by running, never by reading)

An ExUnit file outside the repo, run against the cloud test env:

    cd cloud && CC=clang mix test <scratch>/cell_probe_test.exs --seed 0 --trace

Body: seed a team via `Accounts.create_team/1` + `Accounts.add_member/3` at the
wanted roles, then call `Accounts.remove_member_as/3` and
`Accounts.update_member_role_as/4` and `IO.puts` the raw tuple. Every scene keeps a
SPARE OWNER so `:last_owner` never masks an authority answer. Cells worth probing:

    A admin-self-REMOVE                 => {:error, :forbidden}
    B admin-self-DEMOTE to member       => {:ok, %TeamMembership{role: "member"}}
    C owner->PEER-OWNER role CHANGE     => {:error, :forbidden}     <- S1 CRUX
    C owner->PEER-OWNER REMOVE          => {:ok, :removed}          <- S1 CRUX
    D owner-self-DEMOTE (2 owners)      => {:ok, role: "member"}
    E owner-self-REMOVE (2 owners)      => {:ok, :removed}
    F admin->member PROMOTE to admin    => {:ok, role: "admin"}
    G owner->admin DEMOTE / REMOVE      => {:ok, ...} / {:ok, :removed}
    H member actor, all four            => {:error, :forbidden} x4
    I off-ladder target ("superadmin")  => admin REMOVE {:ok, :removed}
                                           outranks?("admin","superadmin") == true

## R4 — the off-ladder role is storable (no CHECK constraint)

    git grep -n 'team_memberships' origin/main -- 'cloud/priv/repo/migrations/**'
    git grep -in 'check_constraint\|CHECK (' origin/main -- 'cloud/priv/repo/migrations/**'   # EMPTY

Reachable only by a direct DB write — `TeamMembership.changeset/2` has
`validate_inclusion(:role, @roles)` (`team_membership.ex:54`). Probe I bypasses it with
`Ecto.Changeset.change/2`.

## R5 — the console already omits ALL self controls

    git show origin/main:cloud/priv/static/app.js | sed -n '18477,18484p'

`var actions = (canManage && !isSelf) ? ... : ""` — so the self asymmetries (A vs B,
D vs E) are INVISIBLE in today's UI. They become a hazard only if S1 touches the
`!isSelf` term. Charter D482's *"both still suppressed on isSelf"* therefore matches
main; it costs nothing new, but it under-offers three server-LEGAL self cells (B, D, E).
