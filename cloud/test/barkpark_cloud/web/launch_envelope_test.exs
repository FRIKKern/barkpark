defmodule BarkparkCloud.Web.LaunchEnvelopeTest do
  @moduledoc """
  Coherence arc A5 — regression pin for the `POST /v1/launch` response envelope
  the onboarding narrative (A4) routes on:

    * a 201 launch returns `{"barkpark": {"id": _, ...}}` — the id `submitLaunch`
      reads to redirect to `#instance/<id>` (no post-launch dump to #fleet);
    * a 402 (no subscription, trial exhausted) carries `checkout_path` — the id
      the inline plan step reads to send the operator to checkout and back.

  Drives the router directly via Plug.Test, mirroring `go_live_limit_test.exs`.
  Cheap DB-only fixtures (no warm-pool / provisioning) — the row is created in a
  provisioning state and the async job enqueue is best-effort, so the 201 shape
  is asserted without any provider round-trip.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing}
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery staple"
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Stamp the team's one free trial as already used (in the past, no live sub) so
  # go-live's dwb-13 auto-start returns :trial_used → the 402 stands.
  defp exhaust_trial(team) do
    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(t in Team, where: t.id == ^team.id),
        set: [trial_started_at: past, trial_ends_at: past]
      )

    :ok
  end

  test "POST /v1/launch 201 → %{\"barkpark\" => %{\"id\" => _}} (A4 redirect contract)" do
    # A never-trialed team's first launch auto-starts the free trial → 201.
    {user, team} = user_with_team()
    refute Billing.entitled?(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "My First Site"}, token)
    assert conn.status == 201

    body = json_body(conn)
    # The exact shape A4's submitLaunch reads to route to `#instance/<id>`.
    assert %{"barkpark" => %{"id" => id}} = body
    assert is_binary(id) and id != ""
  end

  test "POST /v1/launch 402 carries checkout_path (A4 inline plan step contract)" do
    # Trial exhausted + no subscription → the entitlement gate 402s, and the body
    # must carry the checkout path A4's inline plan step reads.
    {user, team} = user_with_team()
    exhaust_trial(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/launch", %{name: "Nope"}, token)
    assert conn.status == 402

    body = json_body(conn)
    assert body["error"] == "no_active_subscription"
    assert body["checkout_path"] == "/v1/billing/checkout"
  end
end
