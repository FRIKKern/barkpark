defmodule BarkparkCloud.Web.RouterBillingLifecycleTest do
  @moduledoc """
  subscription-billing HTTP surface: POST /v1/billing/portal and
  POST /v1/billing/cancel (password-reconfirmed), plus the grace-aware launch
  gate. Driven through Router.call/2 with Plug.Test — €0, no live Stripe.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  # A fresh user joined to `team` at `role`, plus a live session token.
  defp token_for(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/billing/portal" do
    test "subscribed team → 200 {portal_url}" do
      {_user, team, token} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/billing/portal", %{}, token)
      assert conn.status == 200
      assert "https://portal.stub/" <> _ = json_body(conn)["portal_url"]
    end

    test "no subscription → 422 no_subscription" do
      {_user, _team, token} = user_with_team()
      conn = call(:post, "/v1/billing/portal", %{}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "no_subscription"
    end

    test "unauthenticated → 401" do
      conn = call(:post, "/v1/billing/portal", %{})
      assert conn.status == 401
    end
  end

  describe "POST /v1/billing/cancel" do
    test "wrong password → 401, no state change" do
      {_user, team, token} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/billing/cancel", %{password: "wrong-password"}, token)
      assert conn.status == 401
      assert json_body(conn)["error"] == "password_invalid"
      # Still active.
      assert %{status: "active"} = Billing.live_subscription(team)
    end

    test "correct password, grace (default) → 200 cancel_at_period_end, stays entitled" do
      {_user, team, token} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/billing/cancel", %{password: @password}, token)
      assert conn.status == 200
      body = json_body(conn)
      assert body["status"] == "active"
      assert body["cancel_at_period_end"] == true
      assert Billing.entitled?(team)
    end

    # WAS "correct password, immediate → 200 canceled, boxes suspended". The
    # immediate arm is REMOVED from the route (task-527f2a101b99ebf9, ruled
    # 2026-09-07): it was owner-reachable behind nothing but this password
    # re-confirm and no shipped client ever sent it. The pin is INVERTED rather
    # than deleted, so the shape that used to be contract is now the shape that
    # must be refused. The gateway-seam half of the guard lives in
    # router_billing_cancel_immediate_refused_test.exs.
    test "correct password, at_period_end:false → 422 invalid, nothing cancelled and no box suspended" do
      {_user, team, token} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")
      {:ok, bp} = Registry.register_barkpark(team, %{name: "Prod", slug: "prod"})

      conn =
        call(:post, "/v1/billing/cancel", %{password: @password, at_period_end: false}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
      assert [_sentence] = json_body(conn)["details"]["at_period_end"]

      # The caller is told NO, and is not quietly handed the grace cancel
      # instead: the subscription is exactly as it was.
      assert %{status: "active", cancel_at_period_end: false} = Billing.live_subscription(team)
      assert Billing.entitled?(team)
      refute Registry.get_barkpark(bp.id).suspended
    end

    test "no subscription → 422 no_subscription (after password check passes)" do
      {_user, _team, token} = user_with_team()
      conn = call(:post, "/v1/billing/cancel", %{password: @password}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "no_subscription"
    end
  end

  describe "B3 — billing is OWNER-only" do
    test "a member and an admin are 403 on checkout/portal/cancel; the owner reaches billing" do
      {_owner, team, owner_token} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      for role <- ["member", "admin"] do
        token = token_for(team, role)
        assert call(:post, "/v1/billing/checkout", %{plan: "supporter"}, token).status == 403
        assert call(:post, "/v1/billing/portal", %{}, token).status == 403
        # Owner gate fires BEFORE the password step → 403 (not a 401 password fail).
        assert call(:post, "/v1/billing/cancel", %{password: @password}, token).status == 403
      end

      # The owner is not gated out: the portal opens.
      assert call(:post, "/v1/billing/portal", %{}, owner_token).status == 200
    end
  end

  describe "launch gate — entitlement (grace-aware)" do
    test "past_due within grace can still launch (201)" do
      {_user, team, token} = user_with_team()
      {:ok, sub} = Billing.subscribe(team, "supporter")

      {:ok, _} =
        Billing.mark_past_due(sub, %{
          grace_ends_at: DateTime.add(DateTime.utc_now(), 5, :day)
        })

      conn = call(:post, "/v1/launch", %{name: "My Prod"}, token)
      assert conn.status == 201
    end

    test "past_due past grace is blocked (402)" do
      {_user, team, token} = user_with_team()
      {:ok, sub} = Billing.subscribe(team, "supporter")

      {:ok, _} =
        Billing.mark_past_due(sub, %{
          grace_ends_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      conn = call(:post, "/v1/launch", %{name: "My Prod"}, token)
      assert conn.status == 402
      assert json_body(conn)["error"] == "no_active_subscription"
    end
  end
end
