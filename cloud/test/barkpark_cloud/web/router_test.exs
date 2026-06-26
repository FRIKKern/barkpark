defmodule BarkparkCloud.Web.RouterTest do
  @moduledoc """
  Drives the cloud-12a JSON API directly via Plug.Test — `conn(...)` built and
  run through `Router.call/2`, no live Bandit socket. Mirrors cloud-8/9's
  DataCase + Ecto sandbox setup.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"

  ## Fixtures

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

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  # A user who belongs to a fresh team. Returns {user, team}.
  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  ## Request helpers

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

  ## POST /v1/auth/login

  describe "POST /v1/auth/login" do
    test "right password → 200 {token, team_id}" do
      {user, team} = user_with_team()

      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})

      assert conn.status == 200
      body = json_body(conn)
      assert is_binary(body["token"])
      assert body["team_id"] == team.id

      # The minted token actually authenticates.
      assert %{} = Accounts.verify_user_session_token(body["token"])
    end

    test "wrong password → 401" do
      user = user_fixture()

      conn = call(:post, "/v1/auth/login", %{email: user.email, password: "nope-nope-nope"})

      assert conn.status == 401
      assert json_body(conn)["error"] == "invalid_credentials"
    end

    test "unknown email → 401 (no token)" do
      conn = call(:post, "/v1/auth/login", %{email: "nobody@example.com", password: @password})
      assert conn.status == 401
    end

    test "login for a user with no team → 200 with team_id: null" do
      user = user_fixture()
      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
      assert conn.status == 200
      assert json_body(conn)["team_id"] == nil
      assert is_binary(json_body(conn)["token"])
    end
  end

  ## GET /v1/barkparks

  describe "GET /v1/barkparks" do
    test "valid session token → the team's barkparks" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team, %{name: "Prod", slug: "prod"})
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks", nil, token)

      assert conn.status == 200
      [row] = json_body(conn)["barkparks"]
      assert row["id"] == bp.id
      assert row["slug"] == "prod"
      assert row["health_status"] == "unknown"
      assert row["team_id"] == team.id
    end

    test "no token → 401" do
      conn = call(:get, "/v1/barkparks")
      assert conn.status == 401
      assert json_body(conn)["error"] == "unauthorized"
    end

    test "bad token → 401" do
      conn = call(:get, "/v1/barkparks", nil, "not-a-real-token")
      assert conn.status == 401
    end

    test "team isolation: user A never sees team B's barkparks" do
      {user_a, team_a} = user_with_team()
      {_user_b, team_b} = user_with_team()

      _own = barkpark_fixture(team_a, %{name: "A-own", slug: "a-own"})
      _other = barkpark_fixture(team_b, %{name: "B-secret", slug: "b-secret"})

      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      conn = call(:get, "/v1/barkparks", nil, token_a)

      slugs = conn |> json_body() |> Map.fetch!("barkparks") |> Enum.map(& &1["slug"])
      assert slugs == ["a-own"]
      refute "b-secret" in slugs
    end

    test "an AGENT token cannot satisfy a USER route → 401" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_plaintext, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:get, "/v1/barkparks", nil, agent_plaintext)
      assert conn.status == 401
    end
  end

  ## POST /v1/agent/report

  describe "POST /v1/agent/report" do
    # The cloud-10 report body shape (internal/agent/report.go).
    defp report_body(overrides \\ %{}) do
      Map.merge(
        %{
          "agent_status" => "online",
          "version" => "0.1.0",
          "git_commit" => "abc123def",
          "dirty_tree" => false,
          "health_status" => "up",
          "disk_used_percent" => 41,
          "pg_size_bytes" => 123_456_789,
          "backup_ok" => true,
          "backup_detail" => "fresh",
          "health_checks" => []
        },
        overrides
      )
    end

    test "valid agent token → 200 + the barkpark's health row updated + an event" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:post, "/v1/agent/report", report_body(), agent_token)

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
      assert reloaded.agent_status == "online"
      assert reloaded.version == "0.1.0"
      assert reloaded.git_commit == "abc123def"
      assert reloaded.last_seen_at != nil

      # The report was recorded as an event.
      assert [event | _] = Registry.recent_events(bp, 5)
      assert event.type == "health"
      assert event.payload["disk_used_percent"] == 41
    end

    test "bad agent token → 401 (no health update)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:post, "/v1/agent/report", report_body(), "bogus-agent-token")
      assert conn.status == 401

      # Untouched.
      assert Registry.get_barkpark(bp.id).health_status == "unknown"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/agent/report", report_body())
      assert conn.status == 401
    end

    test "an out-of-enum health_status is normalized to unknown, not a crash" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn =
        call(:post, "/v1/agent/report", report_body(%{"health_status" => "weird"}), agent_token)

      assert conn.status == 200
      assert Registry.get_barkpark(bp.id).health_status == "unknown"
    end

    test "a USER session token cannot satisfy an AGENT route → 401" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/agent/report", report_body(), user_token)
      assert conn.status == 401
    end
  end

  ## GET /v1/agent/commands  +  POST /v1/agent/results

  describe "agent commands + results" do
    test "GET /v1/agent/commands → 200 [] (empty queue)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:get, "/v1/agent/commands", nil, agent_token)
      assert conn.status == 200
      assert json_body(conn) == []
    end

    test "GET /v1/agent/commands with no token → 401" do
      conn = call(:get, "/v1/agent/commands")
      assert conn.status == 401
    end

    test "POST /v1/agent/results → 200 ok" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      results = [%{"id" => "1", "name" => "restart", "approved" => true, "output" => "ok"}]
      conn = call(:post, "/v1/agent/results", results, agent_token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true
    end
  end

  ## POST /v1/providers

  describe "POST /v1/providers" do
    test "valid session token → 201 connected provider (token never echoed)" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/providers",
          %{kind: "hetzner", token: "secret-hetzner-token", label: "main"},
          token
        )

      assert conn.status == 201
      provider = json_body(conn)["provider"]
      assert provider["kind"] == "hetzner"
      assert provider["label"] == "main"
      # The plaintext token is NOT in the response.
      refute Map.has_key?(provider, "token")
      refute Map.has_key?(provider, "encrypted_token")
      refute conn.resp_body =~ "secret-hetzner-token"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "x"})
      assert conn.status == 401
    end

    test "invalid kind → 422" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/providers", %{kind: "aws", token: "x"}, token)
      assert conn.status == 422
    end
  end

  ## POST /v1/go-live  (and its /v1/launch alias)

  describe "POST /v1/go-live" do
    test "session token → 201, a provisioning barkpark row, and Billing charged" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      assert Registry.list_barkparks(team) == []

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "pro"}, token)

      assert conn.status == 201
      bp = json_body(conn)["barkpark"]
      assert bp["name"] == "My Prod"
      assert bp["slug"] == "my-prod"
      assert bp["mode"] == "managed"
      # Honest provisioning state — nothing is live yet (cloud-12b provisions).
      assert bp["health_status"] == "unknown"
      assert bp["agent_status"] == "offline"

      # The row really landed, scoped to the team.
      assert [%Barkpark{slug: "my-prod"}] = Registry.list_barkparks(team)

      # Billing actually charged through the (Stub) gateway — €49 go-live.
      assert {:ok, charge_id} = Billing.charge_go_live(team, 4900)
      assert String.starts_with?(charge_id, "ch_stub_")
    end

    test "/v1/launch is an alias of go-live" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "Launched"}, token)
      assert conn.status == 201
      assert json_body(conn)["barkpark"]["slug"] == "launched"
      assert [%Barkpark{slug: "launched"}] = Registry.list_barkparks(team)
    end

    test "missing name → 422" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{plan: "pro"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "name_required"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/go-live", %{name: "X"})
      assert conn.status == 401
    end
  end

  ## Catch-all

  test "an unknown route → 404 JSON" do
    conn = call(:get, "/v1/nope")
    assert conn.status == 404
    assert json_body(conn)["error"] == "not_found"
  end
end
