defmodule BarkparkCloud.Web.InstanceApiProxyTest do
  @moduledoc """
  The instance-API proxy (C4 — charter decisions D46 / D51): the console's
  server-side gateway into a live instance's OWN webhook API. Proves:

    * EXPLICIT routes only — a non-catalog path is a 404 with ZERO upstream calls
    * the golden relay: the request hits the exact catalog-derived upstream path
      with the DECRYPTED admin bearer, and the reply is the uniform
      `{ok, resource, data}` envelope
    * `?dataset=` selects the dataset (default "production")
    * the admin token is absent from EVERY response body (regex-scanned)
    * team-scope fail-closed: wrong-team / nonexistent / malformed id → the SAME
      404, upstream never called
    * honest states: 409 not_live, 404 no_admin_token, 500 decrypt_failed,
      502 reachable:false on a transport failure
    * honest degradation: an upstream 404 on deliveries/replay (instance too old)
      → 502 capability_unavailable; any other non-2xx relays the instance's own
      status as upstream_error
    * every `:mutate` writes EXACTLY one audit event naming actor + barkpark +
      capability; a read writes none; a rejected mutation writes none
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

  ## Fixtures (mirror RouterSelfUpdateTest's)

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

  # A LIVE instance: url + host + stored admin token (the /succeed shape).
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
    body = Keyword.get(opts, :body)
    token = Keyword.get(opts, :token)

    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          method
          |> conn(path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp program(response), do: Fake.program([response])
  defp ok_json(status, body), do: {:ok, %{status: status, body: body}}

  # Assert the token never leaked AND round-tripped through the vault to the
  # upstream bearer — the whole point of server-side custody.
  defp assert_token_custody(conn) do
    refute conn.resp_body =~ @instance_admin_token

    for req <- Fake.requests() do
      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)
    end
  end

  defp audit_count(team, action) do
    team
    |> Accounts.list_audit_events()
    |> Enum.count(&(&1.action == action))
  end

  describe "route surface — explicit, no free-form passthrough" do
    test "a non-catalog path under /api is a 404 with ZERO upstream calls" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      Fake.program([])

      # A sibling resource we never routed.
      c1 = call(:get, "/v1/barkparks/#{bp.id}/api/datasets", token: session_token(user))
      # A bogus verb hung off the webhooks tree.
      c2 =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_1/frobnicate",
          token: session_token(user)
        )

      assert c1.status == 404
      assert c2.status == 404
      assert Fake.requests() == []
    end
  end

  describe "GET /v1/barkparks/:id/api/webhooks — list" do
    test "relays to the exact upstream path, decrypted bearer, uniform envelope" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[{"id":"wh_1","name":"revalidation"}]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", token: session_token(user))

      assert conn.status == 200

      assert json_body(conn) == %{
               "ok" => true,
               "resource" => "webhook",
               "data" => %{"webhooks" => [%{"id" => "wh_1", "name" => "revalidation"}]}
             }

      assert [req] = Fake.requests()
      assert req.method == :get
      assert req.url == @instance_url <> "/v1/webhooks/production"
      assert_token_custody(conn)
    end

    test "?dataset= overrides the default production dataset" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[]})))

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/api/webhooks?dataset=staging",
          token: session_token(user)
        )

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/staging"
    end

    test "no reads write an audit event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[]})))

      call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", token: session_token(user))
      assert Accounts.list_audit_events(team) == []
    end

    test "no auth → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      Fake.program([])

      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks")
      assert conn.status == 401
      assert Fake.requests() == []
    end
  end

  describe "GET /v1/barkparks/:id/api/webhooks/:webhook_id — show/deliveries" do
    test "show renders {dataset}/{id}" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"id":"wh_9","active":true})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9", token: session_token(user))

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9"
    end

    test "deliveries renders the sub-path" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"deliveries":[]})))

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries",
          token: session_token(user)
        )

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9/deliveries"
    end
  end

  describe "mutations — audit exactly once, correct upstream" do
    test "create POSTs the body and writes one webhook.created event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(201, ~s({"id":"wh_new","secret":"whsec_x"})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks",
          body: %{"url" => "https://acme.test/hook", "events" => ["create"]},
          token: session_token(user)
        )

      assert conn.status == 201
      assert json_body(conn)["ok"] == true
      assert json_body(conn)["data"] == %{"id" => "wh_new", "secret" => "whsec_x"}

      assert [req] = Fake.requests()
      assert req.method == :post
      assert req.url == @instance_url <> "/v1/webhooks/production"
      assert Jason.decode!(req.body) == %{"url" => "https://acme.test/hook", "events" => ["create"]}

      assert_token_custody(conn)
      assert audit_count(team, "webhook.created") == 1

      [event] = Accounts.list_audit_events(team)
      assert event.actor_user_id == user.id
      assert event.target_type == "barkpark"
      assert event.target_id == bp.id
      assert event.metadata["capability"] == "webhook.create"
    end

    test "update PUTs and writes one webhook.updated event (also serves enable/disable)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"id":"wh_9","active":false})))

      conn =
        call(:put, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9",
          body: %{"active" => false},
          token: session_token(user)
        )

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.method == :put
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9"
      assert audit_count(team, "webhook.updated") == 1
    end

    test "delete is a :mutate DELETE and writes one webhook.deleted event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"ok":true})))

      conn = call(:delete, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9", token: session_token(user))

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.method == :delete
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9"
      assert audit_count(team, "webhook.deleted") == 1
    end

    test "rotate POSTs the rotate sub-path and writes one webhook.rotated event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"secret":"whsec_new"})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/rotate", token: session_token(user))

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9/rotate"
      assert audit_count(team, "webhook.rotated") == 1
    end

    test "replay POSTs the deliveries/:event_id/replay sub-path and audits once" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(202, ~s({"queued":true})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries/evt_5/replay",
          token: session_token(user)
        )

      assert conn.status == 202
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9/deliveries/evt_5/replay"
      assert audit_count(team, "webhook.replayed") == 1
    end

    test "a rejected mutation (upstream 422) writes NO audit event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(422, ~s({"error":"invalid_url"})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks",
          body: %{"url" => "not-a-url"},
          token: session_token(user)
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["ok"] == false
      assert body["error"]["code"] == "upstream_error"
      assert body["error"]["status"] == 422
      assert body["error"]["detail"] == %{"error" => "invalid_url"}
      assert Accounts.list_audit_events(team) == []
    end
  end

  describe "honest failure states" do
    test "a still-provisioning instance (no url) → 409 not_live, upstream never called" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      Fake.program([])

      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", token: session_token(user))

      assert conn.status == 409
      assert json_body(conn) == %{"ok" => false, "error" => %{"code" => "not_live"}}
      assert Fake.requests() == []
    end

    test "a pre-feature instance (no admin token) → 404 no_admin_token, upstream never called" do
      {user, team} = user_with_team()

      bp =
        team
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      Fake.program([])
      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", token: session_token(user))

      assert conn.status == 404
      assert json_body(conn) == %{"ok" => false, "error" => %{"code" => "no_admin_token"}}
      assert Fake.requests() == []
    end

    test "tampered ciphertext fails closed → 500 decrypt_failed, upstream never called" do
      {user, team} = user_with_team()

      bp =
        team
        |> barkpark_fixture()
        |> Ecto.Changeset.change(
          url: @instance_url,
          host: "203.0.113.10",
          admin_token_encrypted: Base.encode64("not-real-ciphertext-material")
        )
        |> Repo.update!()

      Fake.program([])
      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", token: session_token(user))

      assert conn.status == 500
      assert json_body(conn) == %{"ok" => false, "error" => %{"code" => "decrypt_failed"}}
      assert Fake.requests() == []
    end

    test "a transport failure → 502 instance_unreachable with reachable:false" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program({:error, {:http_client, :timeout}})

      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", token: session_token(user))

      assert conn.status == 502

      assert json_body(conn) == %{
               "ok" => false,
               "error" => %{"code" => "instance_unreachable"},
               "reachable" => false
             }

      assert_token_custody(conn)
    end
  end

  describe "honest degradation — instance too old for C5 endpoints" do
    test "upstream 404 on deliveries → 502 capability_unavailable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(404, ~s({"error":"not_found"})))

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries",
          token: session_token(user)
        )

      assert conn.status == 502
      body = json_body(conn)
      assert body["ok"] == false
      assert body["error"]["code"] == "capability_unavailable"
      assert body["error"]["hint"] =~ "update"
    end

    test "upstream 404 on replay → 502 capability_unavailable, and no audit event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(404, ""))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries/evt_5/replay",
          token: session_token(user)
        )

      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "capability_unavailable"
      # A capability that never landed is not an action that happened.
      assert Accounts.list_audit_events(team) == []
    end
  end

  describe "team-scope fail-closed (no existence leak)" do
    test "wrong-team, nonexistent, and malformed ids are the SAME 404, upstream never called" do
      {_owner_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      token_a = session_token(user_a)
      Fake.program([])

      wrong_team = call(:get, "/v1/barkparks/#{bp_b.id}/api/webhooks", token: token_a)
      nonexistent = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/api/webhooks", token: token_a)
      malformed = call(:get, "/v1/barkparks/not-a-uuid/api/webhooks", token: token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert malformed.status == 404

      assert json_body(wrong_team) == json_body(nonexistent)
      assert json_body(nonexistent) == json_body(malformed)
      assert json_body(wrong_team) == %{"ok" => false, "error" => %{"code" => "not_found"}}

      assert Fake.requests() == []
    end

    test "a mutation across teams also leaks nothing and writes no audit event" do
      {_owner_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      Fake.program([])

      conn =
        call(:delete, "/v1/barkparks/#{bp_b.id}/api/webhooks/wh_9", token: session_token(user_a))

      assert conn.status == 404
      assert Fake.requests() == []
      assert Accounts.list_audit_events(team_b) == []
    end
  end
end
