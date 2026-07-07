defmodule BarkparkCloud.Web.RouterAutoupdateTest do
  @moduledoc """
  isu-w4 — `PATCH /v1/barkparks/:id/autoupdate`: the team-facing fleet-autoupdate
  policy escape hatch (opt-out / pause / pin). Proves the narrow setter, PATCH
  semantics (absent keys untouched), the ADMIN gate, and team-scope fail-closed.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))
    bp
  end

  defp patch_autoupdate(id, token, body) do
    conn =
      conn(:patch, "/v1/barkparks/#{id}/autoupdate", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "team admin sets policy → 200; row updated; blank pin normalized to nil" do
    {user, team} = user_with_team()
    bp = barkpark_fixture(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn =
      patch_autoupdate(bp.id, token, %{
        "autoupdate_enabled" => false,
        "autoupdate_paused" => true,
        "pinned_release" => "  "
      })

    assert conn.status == 200
    assert json_body(conn)["autoupdate"] == %{"enabled" => false, "paused" => true, "pinned_release" => nil}

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.autoupdate_enabled == false
    assert reloaded.autoupdate_paused == true
    assert reloaded.pinned_release == nil
  end

  test "PATCH leaves absent keys unchanged" do
    {user, team} = user_with_team()
    bp = barkpark_fixture(team) |> Ecto.Changeset.change(autoupdate_enabled: true) |> Repo.update!()
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = patch_autoupdate(bp.id, token, %{"pinned_release" => "v0.2.24"})

    assert conn.status == 200
    reloaded = Registry.get_barkpark(bp.id)
    # only the pin changed; enabled stayed true
    assert reloaded.pinned_release == "v0.2.24"
    assert reloaded.autoupdate_enabled == true
  end

  test "a plain team member → 403" do
    {user, team} = user_with_team("member")
    bp = barkpark_fixture(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => true})
    assert conn.status == 403
    assert Registry.get_barkpark(bp.id).autoupdate_paused == false
  end

  test "an admin of another team gets 404 (scope fail-closed, no existence leak)" do
    {_owner, team_a} = user_with_team()
    bp = barkpark_fixture(team_a)

    {other, _team_b} = user_with_team()
    {:ok, token} = Accounts.create_user_session_token(other)

    conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => true})
    assert conn.status == 404
  end

  test "unauthenticated → 401" do
    {_user, team} = user_with_team()
    bp = barkpark_fixture(team)

    conn = patch_autoupdate(bp.id, nil, %{"autoupdate_paused" => true})
    assert conn.status == 401
  end
end
