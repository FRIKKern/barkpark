defmodule BarkparkCloud.Web.UsageRouteTest do
  @moduledoc """
  GET /v1/barkparks/:id/usage (C9 — charter decision D48): the console's usage
  meters, composed honestly. Proves:

    * 200 with the FULL fixed meter vocabulary, every meter uniform-shaped
    * flow meters (api_requests / bandwidth) are ALWAYS "unmetered"
    * seats reflect the team's real member count (+ pending-invitation detail)
    * db_size / disk come from the latest health beat, carrying its measured_at
    * the webhook count is fetched server-side with the vault-stored admin token,
      and that token is ABSENT from the rendered body (regex-scanned) while the
      upstream request DID carry it (custody round-trip)
    * honest degradation: an unreachable instance still returns 200 with the
      control-plane meters present and webhooks degraded to "unmetered" — never a
      500, never a fake zero, never a block
    * a still-provisioning (no-url) instance never calls upstream; webhooks
      degrade, seats still return
    * auth: 401 unauthenticated; team-scope fail-closed → the SAME 404 for
      wrong-team / nonexistent / malformed ids
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient, as: Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext-XYZ"
  @instance_url "https://prod.barkpark.cloud"

  ## Fixtures (mirror InstanceApiProxyTest's)

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

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, opts \\ []) do
    token = Keyword.get(opts, :token)
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp usage(conn), do: Jason.decode!(conn.resp_body)["usage"]
  defp meters(conn), do: usage(conn)["meters"]

  defp program(response), do: Fake.program([response])
  defp ok_json(status, body), do: {:ok, %{status: status, body: body}}

  defp seed_health(bp, payload) do
    {:ok, _event} = Registry.record_event(bp, "health", payload)
    :ok
  end

  describe "GET /v1/barkparks/:id/usage — the composed envelope" do
    test "200 with the full meter vocabulary, uniform-shaped" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[{"id":"wh_1"},{"id":"wh_2"}]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      m = meters(conn)

      assert Enum.sort(Map.keys(m)) ==
               Enum.sort(
                 ~w(documents datasets webhooks db_size disk seats api_requests bandwidth)
               )

      for {_name, meter} <- m do
        assert Map.has_key?(meter, "value")
        assert meter["quota"] == nil
        assert meter["warn_at"] == nil
        assert is_binary(meter["source"])
      end
    end

    test "flow meters are always unmetered" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["api_requests"]["value"] == "unmetered"
      assert m["bandwidth"]["value"] == "unmetered"
    end

    test "documents/datasets ship honestly unmetered in v1 (no fake zero)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["documents"]["value"] == "unmetered"
      assert m["datasets"]["value"] == "unmetered"
      assert m["documents"]["source"] == "instance.documents"
    end
  end

  describe "seats meter" do
    test "reflects the team's real member count + pending invitations" do
      {owner, team} = user_with_team()
      # A second member and a pending invitation.
      {:ok, _} = Accounts.add_member(team, user_fixture(), "admin")
      {:ok, _} = Accounts.invite_member(team, "invitee@example.com", "member", owner)

      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(owner))
      seats = meters(conn)["seats"]

      assert seats["value"] == 2
      assert seats["pending_invitations"] == 1
      assert seats["source"] == "control-plane.team_members"
    end
  end

  describe "telemetry meters" do
    test "db_size + disk come from the latest health beat with its measured_at" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      seed_health(bp, %{
        "disk_used_percent" => 57,
        "pg_size_bytes" => 987_654_321
      })

      program(ok_json(200, ~s({"webhooks":[]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert m["db_size"]["value"] == 987_654_321
      assert m["disk"]["value"] == 57
      assert is_binary(m["db_size"]["measured_at"])
      assert m["db_size"]["measured_at"] == m["disk"]["measured_at"]
    end

    test "no health beat yet → db_size/disk unmetered, endpoint still 200" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      m = meters(conn)

      assert conn.status == 200
      assert m["db_size"]["value"] == "unmetered"
      assert m["disk"]["value"] == "unmetered"
    end
  end

  describe "webhook count — server-side fetch + token custody" do
    test "webhooks value == the instance count; token round-trips but never leaks" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[{"id":"wh_1"},{"id":"wh_2"},{"id":"wh_3"}]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert meters(conn)["webhooks"]["value"] == 3
      # The source label admits the count's dataset scope (production only).
      assert meters(conn)["webhooks"]["source"] == "instance.webhooks.production"

      # The upstream fetch hit the default-dataset webhook list with the bearer.
      assert [req] = Fake.requests()
      assert req.method == :get
      assert req.url == @instance_url <> "/v1/webhooks/production"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)

      # ...and the token is ABSENT from the rendered body.
      refute conn.resp_body =~ @instance_admin_token
    end

    test "zero webhooks renders a real 0, not the degrade" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      assert meters(conn)["webhooks"]["value"] == 0
    end
  end

  describe "honest degradation — the endpoint never 500s, never blocks" do
    test "an unreachable instance → 200, control-plane meters present, webhooks unmetered" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      seed_health(bp, %{"pg_size_bytes" => 42})
      program({:error, {:http_client, :timeout}})

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      m = meters(conn)
      # The instance-sourced meter degraded...
      assert m["webhooks"]["value"] == "unmetered"
      # ...but control-plane meters STILL returned.
      assert m["seats"]["value"] == 1
      assert m["db_size"]["value"] == 42
      refute conn.resp_body =~ @instance_admin_token
    end

    test "an upstream non-2xx degrades webhooks, endpoint still 200" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(500, ~s({"error":"boom"})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      assert conn.status == 200
      assert meters(conn)["webhooks"]["value"] == "unmetered"
    end

    test "a garbage-shaped webhook body degrades webhooks (no guessed count)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"not_webhooks":true})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))
      assert meters(conn)["webhooks"]["value"] == "unmetered"
    end

    test "a still-provisioning instance (no url) never calls upstream; seats still return" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      Fake.program([])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      m = meters(conn)
      assert m["webhooks"]["value"] == "unmetered"
      assert m["seats"]["value"] == 1
      assert Fake.requests() == []
    end

    test "a pre-feature instance (no admin token) never calls upstream" do
      {user, team} = user_with_team()

      bp =
        team
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      Fake.program([])
      conn = call(:get, "/v1/barkparks/#{bp.id}/usage", token: session_token(user))

      assert conn.status == 200
      assert meters(conn)["webhooks"]["value"] == "unmetered"
      assert Fake.requests() == []
    end
  end

  describe "auth + team-scope fail-closed" do
    test "no auth → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      Fake.program([])

      conn = call(:get, "/v1/barkparks/#{bp.id}/usage")
      assert conn.status == 401
      assert Fake.requests() == []
    end

    test "wrong-team / nonexistent / malformed ids are the SAME 404, upstream never called" do
      {_owner_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      token_a = session_token(user_a)
      Fake.program([])

      wrong_team = call(:get, "/v1/barkparks/#{bp_b.id}/usage", token: token_a)
      nonexistent = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/usage", token: token_a)
      malformed = call(:get, "/v1/barkparks/not-a-uuid/usage", token: token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert malformed.status == 404

      assert Jason.decode!(wrong_team.resp_body) == Jason.decode!(nonexistent.resp_body)
      assert Jason.decode!(nonexistent.resp_body) == Jason.decode!(malformed.resp_body)

      assert Fake.requests() == []
    end
  end
end
