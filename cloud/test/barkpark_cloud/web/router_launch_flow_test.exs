defmodule BarkparkCloud.Web.RouterLaunchFlowTest do
  @moduledoc """
  dwb-6 — the launch-with-template response SHAPES the `/new` SPA relies on to
  drive the flow:

    * 201 {barkpark: {id, …}} — the optimistic row + progress step key off the id
    * 402 {error: "no_active_subscription", checkout_path} — the "price before any
      charge" screen (dwb-13 auto-starts the ONE free trial, so this only fires
      once the trial is spent; the SPA then shows tiers + a checkout CTA)
    * 403 {error: "limit_reached", upgrade_path} — the plan-ceiling screen

  These pin the CONTRACT the client parses; the SPA can't be browser-tested here.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # Mark the team's one free trial as already used so the dwb-13 auto-start returns
  # :trial_used and the 402 stands (mirrors go_live_limit_test.exhaust_trial/1).
  defp exhaust_trial(team) do
    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(t in Team, where: t.id == ^team.id),
        set: [trial_started_at: past, trial_ends_at: past]
      )

    :ok
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "launch with a template → 201 {barkpark:{id}} carrying the chosen template" do
    {user, team} = user_with_team()
    {:ok, _} = Billing.subscribe(team, "supporter")
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "My Blog", template: "blog-starter"}, token)
    assert conn.status == 201
    bp = json_body(conn)["barkpark"]
    assert is_binary(bp["id"])
    assert bp["name"] == "My Blog"

    [row] = Registry.list_barkparks(team)
    assert row.template == "blog-starter"
  end

  test "unentitled + trial spent → 402 {no_active_subscription, checkout_path}" do
    {user, team} = user_with_team()
    exhaust_trial(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "My Blog", template: "blog-starter"}, token)
    assert conn.status == 402
    body = json_body(conn)
    assert body["error"] == "no_active_subscription"
    assert body["checkout_path"] == "/v1/billing/checkout"

    # Nothing provisioned — the entitlement gate precedes any row/job.
    assert Registry.list_barkparks(team) == []
  end

  test "entitled but at the plan ceiling → 403 {limit_reached, upgrade_path}" do
    {user, team} = user_with_team()
    {:ok, _} = Billing.subscribe(team, "free")
    {:ok, token} = Accounts.create_user_session_token(user)

    assert call(:post, "/v1/launch", %{name: "First", template: "blog-starter"}, token).status ==
             201

    conn = call(:post, "/v1/launch", %{name: "Second", template: "blog-starter"}, token)
    assert conn.status == 403
    body = json_body(conn)
    assert body["error"] == "limit_reached"
    assert body["upgrade_path"] == "/v1/billing/checkout"
    assert length(Registry.list_barkparks(team)) == 1
  end
end
