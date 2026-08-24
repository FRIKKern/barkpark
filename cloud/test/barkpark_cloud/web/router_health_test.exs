defmodule BarkparkCloud.Web.RouterHealthTest do
  @moduledoc """
  HTTP surfaces for health-status: the unauthenticated liveness probes
  (GET /up, GET /health), the team-scoped agent-event history
  (GET /v1/barkparks/:id/events), and the POST /v1/agent/report recovery wiring
  (a fresh report re-arms the staleness latch). Driven directly via Plug.Test,
  mirroring router_test.exs.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
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

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp post_json(path, body, token) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  describe "GET /up and GET /health (liveness)" do
    test "GET /up returns 200 with db up" do
      conn = call(:get, "/up")
      assert conn.status == 200
      assert %{"db" => "up"} = Jason.decode!(conn.resp_body)
    end

    test "GET /health returns 200 with db up" do
      conn = call(:get, "/health")
      assert conn.status == 200
      assert %{"db" => "up"} = Jason.decode!(conn.resp_body)
    end

    test "the probes need no auth" do
      conn = call(:get, "/up")
      assert conn.status == 200
    end
  end

  describe "GET /v1/barkparks/:id/events" do
    test "returns the instance's events newest-first for the owning team" do
      {_user, team, token} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.record_event(bp, "health", %{"n" => 1})
      {:ok, _} = Registry.record_event(bp, "status", %{"transition" => "offline"})

      conn = call(:get, "/v1/barkparks/#{bp.id}/events", token)
      assert conn.status == 200
      %{"events" => events} = Jason.decode!(conn.resp_body)
      assert [%{"type" => "status"}, %{"type" => "health"}] = events
      assert Enum.all?(events, &Map.has_key?(&1, "payload"))
      assert Enum.all?(events, &Map.has_key?(&1, "inserted_at"))
    end

    test "?limit= caps the window" do
      {_user, team, token} = user_with_team()
      bp = barkpark_fixture(team)
      for i <- 1..5, do: {:ok, _} = Registry.record_event(bp, "health", %{"n" => i})

      conn = call(:get, "/v1/barkparks/#{bp.id}/events?limit=1", token)
      assert conn.status == 200
      assert %{"events" => [_one]} = Jason.decode!(conn.resp_body)
    end

    test "another team's instance is a 404 (no existence leak)" do
      {_owner, owner_team, _ot} = user_with_team()
      {_other, _other_team, other_token} = user_with_team()
      bp = barkpark_fixture(owner_team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/events", other_token)
      assert conn.status == 404
    end

    test "a nonexistent id is a 404" do
      {_user, _team, token} = user_with_team()
      conn = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/events", token)
      assert conn.status == 404
    end

    test "no token → 401" do
      {_user, team, _token} = user_with_team()
      bp = barkpark_fixture(team)
      conn = call(:get, "/v1/barkparks/#{bp.id}/events")
      assert conn.status == 401
    end
  end

  describe "GET /v1/barkparks/:id/telemetry" do
    test "re-serves the latest health event as the normalized envelope" do
      {_user, team, token} = user_with_team()
      bp = barkpark_fixture(team)

      {:ok, _} =
        Registry.record_event(bp, "health", %{
          "disk_used_percent" => 42,
          "pg_size_bytes" => 123_456_789,
          "backup_ok" => true,
          "backup_detail" => "daily backup 2h ago",
          "dirty_tree" => false,
          "health_checks" => [
            %{"name" => "tls", "pass" => true},
            %{"name" => "websocket", "pass" => false}
          ]
        })

      conn = call(:get, "/v1/barkparks/#{bp.id}/telemetry", token)
      assert conn.status == 200
      %{"telemetry" => t} = Jason.decode!(conn.resp_body)

      assert t["disk"] == %{"used_pct" => 42}
      assert t["db_size"] == 123_456_789
      assert t["backup"] == %{"ok" => true, "detail" => "daily backup 2h ago"}

      assert t["checks"] == %{
               "pass" => 1,
               "skipped" => 0,
               "total" => 2,
               "failing" => ["websocket"]
             }

      assert t["dirty_tree"] == false
      # reported_at is stamped from the event's inserted_at (RFC3339), never nil
      # for a real event.
      assert is_binary(t["reported_at"])
    end

    test "picks the NEWEST health beat when the stream carries several" do
      {_user, team, token} = user_with_team()
      bp = barkpark_fixture(team)

      {:ok, _} = Registry.record_event(bp, "health", %{"disk_used_percent" => 10})
      {:ok, _} = Registry.record_event(bp, "status", %{"transition" => "offline"})
      {:ok, _} = Registry.record_event(bp, "health", %{"disk_used_percent" => 90})

      conn = call(:get, "/v1/barkparks/#{bp.id}/telemetry", token)
      assert conn.status == 200
      assert %{"telemetry" => %{"disk" => %{"used_pct" => 90}}} = Jason.decode!(conn.resp_body)
    end

    test "an instance that has not phoned home a health beat → telemetry: null (never 500)" do
      {_user, team, token} = user_with_team()
      bp = barkpark_fixture(team)
      # Only a non-health event in the stream: the endpoint finds no health row.
      {:ok, _} = Registry.record_event(bp, "status", %{"transition" => "online"})

      conn = call(:get, "/v1/barkparks/#{bp.id}/telemetry", token)
      assert conn.status == 200
      assert %{"telemetry" => nil} = Jason.decode!(conn.resp_body)
    end

    test "a brand-new instance with an empty event stream → telemetry: null" do
      {_user, team, token} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/telemetry", token)
      assert conn.status == 200
      assert %{"telemetry" => nil} = Jason.decode!(conn.resp_body)
    end

    test "another team's instance is a 404 (no existence leak)" do
      {_owner, owner_team, _ot} = user_with_team()
      {_other, _other_team, other_token} = user_with_team()
      bp = barkpark_fixture(owner_team)
      {:ok, _} = Registry.record_event(bp, "health", %{"disk_used_percent" => 42})

      conn = call(:get, "/v1/barkparks/#{bp.id}/telemetry", other_token)
      assert conn.status == 404
    end

    test "a nonexistent id is a 404" do
      {_user, _team, token} = user_with_team()
      conn = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/telemetry", token)
      assert conn.status == 404
    end

    test "no token → 401" do
      {_user, team, _token} = user_with_team()
      bp = barkpark_fixture(team)
      conn = call(:get, "/v1/barkparks/#{bp.id}/telemetry")
      assert conn.status == 401
    end
  end

  describe "POST /v1/agent/report recovery wiring" do
    # A fresh report from a box the StalenessWorker had LATCHED offline must
    # re-arm the latch: unreachable_count → 0 and unreachable_notification_sent →
    # false, so a LATER outage alerts again. If the router dropped the
    # record_agent_report/2 call (reverting to a bare upsert_health), the latch
    # would stay set forever and a re-outage would be silently swallowed.
    test "a report clears the staleness latch (re-arms so a re-outage can alert)" do
      team = team_fixture()
      bp = barkpark_fixture(team, %{agent_status: "online", health_status: "up"})

      # Simulate the StalenessWorker having flipped + latched this box offline.
      {:ok, latched} = Registry.mark_offline(bp)
      assert latched.unreachable_notification_sent == true
      assert latched.agent_status == "offline"

      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn =
        post_json(
          "/v1/agent/report",
          %{
            "health_status" => "up",
            "agent_status" => "online",
            "version" => "0.1.0",
            "git_commit" => "abc123",
            "health_checks" => []
          },
          agent_token
        )

      assert conn.status == 200

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.unreachable_count == 0
      assert reloaded.unreachable_notification_sent == false
      assert reloaded.agent_status == "online"
      assert reloaded.health_status == "up"
    end
  end
end
