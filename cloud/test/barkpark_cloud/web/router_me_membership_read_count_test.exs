defmodule BarkparkCloud.Web.RouterMeMembershipReadCountTest do
  @moduledoc """
  How many `team_memberships` SELECTs does ONE `GET /v1/me` actually perform?

  The router comment above the `team_role` binding used to claim "ONE role
  read, spent by both the top-level `role:` key and `team_authority.role`".
  A telemetry count says otherwise, and this test is the guard that keeps the
  comment from rotting back into that claim: it attaches to
  `[:barkpark_cloud, :repo, :query]`, filters to statements emitted by THIS
  process (so a concurrent async test's queries can never inflate the count),
  and pins the measured numbers.

  Measured for a single-team member calling `GET /v1/me` with a session token:

    * SIX `team_memberships`-touching SELECTs in total
    * FOUR of them direct `SELECT ... FROM "team_memberships"` row reads
      (`Accounts.get_membership/2`), the other two `list_user_teams/1` JOINs

  Where they come from, in order:

    1. `Auth.require_user_or_pat/2` -> `Accounts.primary_team/1` ->
       `list_user_teams/1`                                        (JOIN)
    2. `team_role` binding -> `Accounts.team_role/2` -> `get_membership/2`
    3. the `teams:` switcher list -> `list_user_teams/1`           (JOIN)
    4. `teams:` per-team `Accounts.team_role/2` -> `get_membership/2`
       (one per team the user belongs to; ONE here)
    5. `team_authority.admin` -> `Authz.team_admin?/2` -> `Authz.role/2` ->
       `get_membership/2`
    6. `team_authority.owner` -> `Authz.team_owner?/2` -> `Authz.role/2` ->
       `get_membership/2`

  So `role:` and `team_authority.role` DO share one read (#2) — but `.admin`
  and `.owner` each take their own, through a DIFFERENT module, and the boot
  spends four membership-row reads, not one.

  If a later change threads a single membership through role/admin/owner, the
  numbers here go DOWN and this test reds by name — update it, and the router
  comment beside it, together.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # Every `team_memberships` SELECT emitted while `fun` runs IN THIS PROCESS.
  # The pid filter is what makes this safe under `async: true`: Ecto emits the
  # telemetry event in the process that ran the query, so another test's
  # statements are dropped rather than counted.
  defp membership_selects(fun) do
    ref = make_ref()
    test = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark_cloud, :repo, :query],
      fn _event, _measure, meta, _config ->
        if self() == test, do: send(test, {ref, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    ref
    |> collect([])
    |> Enum.filter(&(&1 =~ ~r/^SELECT/ and &1 =~ "team_memberships"))
  end

  defp collect(ref, acc) do
    receive do
      {^ref, query} -> collect(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp direct_membership_reads(statements),
    do: Enum.filter(statements, &(&1 =~ ~r/^SELECT .* FROM "team_memberships"/))

  defp member_caller(role) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "readcount-#{n}@example.com",
        password: "s3cret-pass-#{n}!"
      })

    {:ok, team} =
      Accounts.create_team(%{name: "ReadCount #{n}", slug: "readcount-#{n}"})

    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp me(token) do
    conn(:get, "/v1/me")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(@opts)
  end

  test "one GET /v1/me performs SIX team_memberships SELECTs, FOUR of them direct row reads" do
    {_user, _team, token} = member_caller("owner")

    statements = membership_selects(fn -> assert me(token).status == 200 end)

    assert length(statements) == 6,
           """
           Expected 6 team_memberships-touching SELECTs for one GET /v1/me, got \
           #{length(statements)}. If this changed on purpose, update the router \
           comment above the `team_role` binding in the /v1/me handler in the \
           SAME commit — that comment quotes these numbers.

           #{Enum.map_join(statements, "\n", &("  - " <> &1))}
           """

    assert length(direct_membership_reads(statements)) == 4,
           """
           Expected 4 direct `SELECT ... FROM "team_memberships"` row reads \
           (get_membership/2), got #{length(direct_membership_reads(statements))}.
           """
  end

  test "a teamless caller spends no membership ROW reads, only the primary-team lookups" do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "readcount-teamless-#{n}@example.com",
        password: "s3cret-pass-#{n}!"
      })

    {:ok, token} = Accounts.create_user_session_token(user)

    statements = membership_selects(fn -> assert me(token).status == 200 end)

    # The control: with `team` nil every `&&`-guarded read short-circuits, so
    # the only survivors are the two `list_user_teams/1` JOINs. A count that
    # did NOT move between the two tests would mean the filter is measuring
    # something other than this request.
    assert direct_membership_reads(statements) == []
    assert length(statements) == 2
  end
end
