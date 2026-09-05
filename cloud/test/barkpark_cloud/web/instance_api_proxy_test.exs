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
    * honest degradation: an upstream 404 on rotate/deliveries/replay (the
      C5-new endpoints — instance too old) → 502 capability_unavailable; any
      other non-2xx relays the instance's own status as upstream_error
    * a URL-reshaping dataset/id value is a 400 before any upstream call
    * every `:mutate` writes EXACTLY one audit event naming actor + barkpark +
      capability; a read writes none; a rejected mutation writes none
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.InstanceApiCatalog
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

  # A LIVE box under a BILLING suspension (cch-w57-s4) — everything the proxy
  # needs is present; only the billing verdict differs.
  defp suspended_barkpark(team) do
    team
    |> live_barkpark()
    |> Ecto.Changeset.change(suspended: true, suspended_reason: "billing_lapsed")
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

  # Drive `method`/`path_fun.(id)` as an actor from team A against a barkpark
  # owned by team B, and assert the object-level-authorization fail-closed:
  # a wrong-team id is the SAME 404 as a nonexistent id (no existence leak),
  # the Fake upstream is never touched, and — for a `:mutate` — team B's audit
  # log stays empty. The proof of load-bearingness is that reverting
  # resolve_team_barkpark/2's `when tid == team.id` guard reds every call site.
  defp assert_cross_team_404(method, path_fun, opts \\ []) do
    body = Keyword.get(opts, :body)
    mutating = Keyword.get(opts, :mutating, false)

    {_owner_b, team_b} = user_with_team()
    bp_b = live_barkpark(team_b)

    {user_a, _team_a} = user_with_team()
    token_a = session_token(user_a)
    Fake.program([])

    call_opts = if body, do: [token: token_a, body: body], else: [token: token_a]

    wrong_team = call(method, path_fun.(bp_b.id), call_opts)
    nonexistent = call(method, path_fun.(Ecto.UUID.generate()), call_opts)

    assert wrong_team.status == 404
    assert nonexistent.status == 404
    # No existence leak: the barkpark the actor does NOT own is indistinguishable
    # from one that never existed.
    assert json_body(wrong_team) == json_body(nonexistent)
    assert json_body(wrong_team) == %{"ok" => false, "error" => %{"code" => "not_found"}}
    # The credential was never spent — the relay never happened.
    assert Fake.requests() == []
    if mutating, do: assert(Accounts.list_audit_events(team_b) == [])
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

      assert Jason.decode!(req.body) == %{
               "url" => "https://acme.test/hook",
               "events" => ["create"]
             }

      assert_token_custody(conn)
      assert audit_count(team, "webhook.created") == 1

      [event] = Accounts.list_audit_events(team)
      assert event.actor_user_id == user.id
      assert event.target_type == "barkpark"
      assert event.target_id == bp.id
      assert event.metadata["capability"] == "webhook.create"
      assert event.metadata["dataset"] == "production"
      # Create names no webhook yet — the key is ABSENT, not null.
      refute Map.has_key?(event.metadata, "webhook_id")
      refute Map.has_key?(event.metadata, "event_id")
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

      # The audit trail records WHICH delivery was replayed, not just that one was.
      [event] = Accounts.list_audit_events(team)
      assert event.metadata["webhook_id"] == "wh_9"
      assert event.metadata["event_id"] == "evt_5"
    end

    test "test-send POSTs the test-send sub-path and writes one webhook.test_sent event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(200, ~s({"delivered":true,"status":204})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/test-send",
          token: session_token(user)
        )

      assert conn.status == 200
      assert [req] = Fake.requests()
      assert req.method == :post
      # The capability ATOM is underscored; only the upstream PATH is hyphenated.
      assert req.url == @instance_url <> "/v1/webhooks/production/wh_9/test-send"

      # The audit clause is load-bearing: maybe_audit_instance_mutation/4 calls
      # instance_mutation_action/1 unconditionally for every :mutate tier and has
      # no catch-all, so a missing clause would be a FunctionClauseError right
      # here rather than a quiet missing row.
      assert audit_count(team, "webhook.test_sent") == 1
      [event] = Accounts.list_audit_events(team)
      assert event.metadata["capability"] == "webhook.test_send"
      assert event.metadata["webhook_id"] == "wh_9"
    end

    test "test-send on a too-old instance degrades to capability_unavailable, not a bare 404" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # Phoenix's UNCODED 404 — the shape a box that predates the route returns.
      program(ok_json(404, ~s({"errors":{"detail":"Not Found"}})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/test-send",
          token: session_token(user)
        )

      assert conn.status == 502
      assert %{"error" => %{"code" => "capability_unavailable"}} = json_body(conn)
      # A failed capability is not a mutation that happened.
      assert audit_count(team, "webhook.test_sent") == 0
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

  # cch-w57-s4 — the :read / :mutate authority split on a SUSPENDED box
  # (charter D673). Isolation withholds the platform's maintenance attention, so
  # a `:mutate` relayed with the stored admin credential is refused BEFORE the
  # ciphertext is decrypted; a `:read` grants nothing durable and still relays.
  # The caller is a plain "member" — the actually-reachable, non-admin path.
  describe "a SUSPENDED box — :mutate is refused, :read still relays" do
    test "a :read still relays and still answers 200 (the grant is NOT withdrawn)" do
      {user, team} = user_with_team("member")
      bp = suspended_barkpark(team)
      program(ok_json(200, ~s({"webhooks":[{"id":"wh_1","name":"revalidation"}]})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks", token: session_token(user))

      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert [req] = Fake.requests()
      assert req.url == @instance_url <> "/v1/webhooks/production"
      assert_token_custody(conn)
    end

    test "a :mutate (create) → 409 suspended with ZERO upstream requests" do
      {user, team} = user_with_team("member")
      bp = suspended_barkpark(team)
      # Programmed to SUCCEED: if the guard is missing this relays a 201 and the
      # recorded request carries the plaintext admin token.
      program(ok_json(201, ~s({"id":"wh_new","secret":"whsec_x"})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks",
          body: %{"url" => "https://acme.test/hook", "events" => ["create"]},
          token: session_token(user)
        )

      # The credential was never spent — asserted FIRST so a lost guard fails
      # with the relayed request (bearer and all) in the message, not just a 201.
      assert Fake.requests() == []
      assert conn.status == 409
      assert json_body(conn) == %{"ok" => false, "error" => %{"code" => "suspended"}}
      refute conn.resp_body =~ @instance_admin_token
      assert Accounts.list_audit_events(team) == []
    end

    test "every other :mutate verb is refused the same way, upstream untouched" do
      # task-a0f4f8757ba28e76 (ARM B): `rotate` now gates at team ADMIN before the
      # suspension check, so a plain member would be refused 403 there and never
      # reach the 409 this sweep asserts. An admin walks every verb to the
      # suspension arm; the member-side refusal has its own test in
      # instance_api_proxy_admin_verbs_test.exs.
      {user, team} = user_with_team("admin")
      bp = suspended_barkpark(team)
      Fake.program([])
      token = session_token(user)

      calls = [
        call(:put, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9",
          body: %{"active" => false},
          token: token
        ),
        call(:delete, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9", token: token),
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/rotate", token: token),
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/test-send", token: token),
        call(
          :post,
          "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries/evt_1/replay",
          token: token
        )
      ]

      for conn <- calls do
        assert conn.status == 409
        assert json_body(conn)["error"]["code"] == "suspended"
      end

      assert Fake.requests() == []
      assert Accounts.list_audit_events(team) == []
    end

    # The sweep above enumerates its verbs BY HAND, which is only as complete as
    # the day it was typed. This arm derives the population from the catalog, so a
    # capability ADDED at `:mutate` reds here instead of silently gaining a route
    # around the refusal. It is the ADD direction the hand list cannot have.
    test "the hand-swept :mutate verbs ARE the catalog's :mutate population" do
      mutating =
        InstanceApiCatalog.catalog()
        |> Enum.filter(&(&1.tier == :mutate))
        |> Enum.map(& &1.capability)
        |> MapSet.new()

      swept =
        MapSet.new([
          :"webhook.create",
          :"webhook.update",
          :"webhook.delete",
          :"webhook.rotate",
          :"webhook.test_send",
          :"webhook.replay"
        ])

      assert MapSet.equal?(mutating, swept),
             "the proxy's :mutate population drifted from the suspended-box sweep above.\n" <>
               "  in the catalog but NOT swept (ADD): " <>
               "#{inspect(MapSet.difference(mutating, swept) |> MapSet.to_list())}\n" <>
               "  swept but no longer :mutate (STALE): " <>
               "#{inspect(MapSet.difference(swept, mutating) |> MapSet.to_list())}\n" <>
               "A new :mutate capability needs a driven 409-with-zero-upstream-requests row in this " <>
               "describe; a capability that stopped mutating needs this pin lowered deliberately."

      refute MapSet.size(mutating) == 0,
             "the catalog reports NO :mutate capability at all — an unreadable population must never " <>
               "read as 'nothing to refuse'"
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

    test "upstream 404 on rotate → 502 capability_unavailable (rotate is C5-new too), no audit" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(404, ~s({"errors":{"detail":"Not Found"}})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/rotate", token: session_token(user))

      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "capability_unavailable"
      assert Accounts.list_audit_events(team) == []
    end

    test "upstream 404 on a pre-C4 CRUD route stays an honest upstream_error 404" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(404, ~s({"error":"webhook_not_found"})))

      conn = call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_gone", token: session_token(user))

      assert conn.status == 404
      body = json_body(conn)
      assert body["error"]["code"] == "upstream_error"
      assert body["error"]["status"] == 404
    end
  end

  describe "honest degradation — a webhook DELETED elsewhere (C11 / OC4)" do
    # The instance disambiguates old-box vs deleted-webhook BY DESIGN: its
    # WebhookController answers a genuine miss with a resource-CODED 404 body
    # (`webhook_not_found` / `event_not_found`), while a route-missing 404 on a
    # too-old box is Phoenix's UNCODED `{"errors":{"detail":...}}`. A coded body
    # → `webhook_gone` ("refresh the list"), NOT the "update this instance" lie.
    test "coded 404 (webhook_not_found) on deliveries → 502 webhook_gone, refresh hint" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      program(
        ok_json(404, ~s({"error":{"code":"webhook_not_found","message":"webhook not found"}}))
      )

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries",
          token: session_token(user)
        )

      assert conn.status == 502
      body = json_body(conn)
      assert body["ok"] == false
      assert body["error"]["code"] == "webhook_gone"
      assert body["error"]["hint"] =~ "refresh"
      # NOT the capability lie.
      refute body["error"]["hint"] =~ "update"
    end

    test "coded 404 (event_not_found) on replay → 502 webhook_gone, and no audit event" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program(ok_json(404, ~s({"error":{"code":"event_not_found","message":"event not found"}})))

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries/evt_5/replay",
          token: session_token(user)
        )

      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "webhook_gone"
      # A capability that returned 404 is not an action that happened.
      assert Accounts.list_audit_events(team) == []
    end

    test "coded 404 (webhook_not_found) on rotate → 502 webhook_gone, no audit" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      program(
        ok_json(404, ~s({"error":{"code":"webhook_not_found","message":"webhook not found"}}))
      )

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/rotate", token: session_token(user))

      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "webhook_gone"
      assert Accounts.list_audit_events(team) == []
    end

    test "an UNCODED 404 (string error / route-missing) stays capability_unavailable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # A string `error` (not the coded object) is NOT a confident 'gone' signal.
      program(ok_json(404, ~s({"error":"not_found"})))

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9/deliveries",
          token: session_token(user)
        )

      assert conn.status == 502
      assert json_body(conn)["error"]["code"] == "capability_unavailable"
    end
  end

  describe "URL-reshaping values are refused before any upstream call" do
    test "a query-injecting ?dataset= is a 400 bad_request, upstream never called" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      Fake.program([])

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/api/webhooks?dataset=prod%3Fadmin%3D1",
          token: session_token(user)
        )

      assert conn.status == 400
      assert json_body(conn) == %{"ok" => false, "error" => %{"code" => "bad_request"}}
      assert Fake.requests() == []
    end

    test "a fragment-carrying webhook id is a 400, upstream never called" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      Fake.program([])

      conn =
        call(:get, "/v1/barkparks/#{bp.id}/api/webhooks/wh_9%23frag", token: session_token(user))

      assert conn.status == 400
      assert Fake.requests() == []
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

      nonexistent =
        call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/api/webhooks", token: token_a)

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

    # The 2 tests above cover GET base (list) and nested DELETE. The remaining 7
    # webhook-proxy verbs funnel through the SAME proxy_instance_webhook/2 ->
    # resolve_team_barkpark/2 gate, but each is a distinct route with its own
    # method + path; a per-verb cross-team row proves the object-level check is
    # not accidentally bypassed by any one of them (IDOR/BOLA capstone).

    test "create (POST base) across teams is the SAME 404, no upstream, no audit" do
      assert_cross_team_404(
        :post,
        &"/v1/barkparks/#{&1}/api/webhooks",
        body: %{"url" => "https://acme.test/hook", "events" => ["create"]},
        mutating: true
      )
    end

    test "show (GET :webhook_id) across teams is the SAME 404, upstream never called" do
      assert_cross_team_404(:get, &"/v1/barkparks/#{&1}/api/webhooks/wh_9")
    end

    test "update (PUT :webhook_id) across teams is the SAME 404, no upstream, no audit" do
      assert_cross_team_404(
        :put,
        &"/v1/barkparks/#{&1}/api/webhooks/wh_9",
        body: %{"active" => false},
        mutating: true
      )
    end

    test "rotate across teams is the SAME 404, no upstream, no audit" do
      assert_cross_team_404(:post, &"/v1/barkparks/#{&1}/api/webhooks/wh_9/rotate",
        mutating: true
      )
    end

    test "deliveries (GET) across teams is the SAME 404, upstream never called" do
      assert_cross_team_404(:get, &"/v1/barkparks/#{&1}/api/webhooks/wh_9/deliveries")
    end

    test "replay across teams is the SAME 404, no upstream, no audit" do
      assert_cross_team_404(
        :post,
        &"/v1/barkparks/#{&1}/api/webhooks/wh_9/deliveries/evt_5/replay",
        mutating: true
      )
    end

    test "test-send across teams is the SAME 404, no upstream, no audit" do
      assert_cross_team_404(
        :post,
        &"/v1/barkparks/#{&1}/api/webhooks/wh_9/test-send",
        mutating: true
      )
    end
  end
end
