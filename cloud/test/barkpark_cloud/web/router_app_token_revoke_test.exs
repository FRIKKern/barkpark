defmodule BarkparkCloud.Web.RouterAppTokenRevokeTest do
  @moduledoc """
  Mobile wave 2 (mob-w2-app-token-revoke) — the app-token revoke path,
  control-plane half (`router_app_token_test.exs`'s lifecycle twin).

  `DELETE /v1/barkparks/:id/app-token` uses the stored per-instance admin token
  SERVER-SIDE to revoke app token(s) on the instance. Proves:

    * token mode: body `{"token": raw}` → the instance is called with
      `DELETE /v1/auth/app-tokens`, the DECRYPTED admin bearer and exactly that
      token in the body; the admin token never appears in any response
    * logout-everywhere: EMPTY body → the instance body carries the CALLING
      user's email (server-derived — never caller-supplied), `revoked_count`
      relayed
    * the revoke is AUDITED ("barkpark.app_token_revoked" — in the AuditEvent
      allowlist) with mode + count, never a token value
    * cross-team deny: a member of another team gets the SAME 404 as a
      nonexistent id; unauthenticated → 401; malformed id → 404, not 500
    * instance-side 404 split (D8): canonical not_found envelope → 404;
      Phoenix no-route body (pre-revoke instance) → 409 revoke_unsupported
    * the instance's DELIBERATE verdicts stay out of the 502 collapse
      (mob-bl-revoke-hardening): 422 → 422 `revoke_refused`, 429 → 429
      `instance_rate_limited`, and only a transport failure → 502 — asserted as
      three DISTINCT response error codes
    * the caller's IP is relayed as X-Forwarded-For, so two proxied callers key
      two DIFFERENT instance-side buckets instead of sharing the Cloud egress one
    * exactly-one-of is ENFORCED: `{"token": ""}` → 422 `invalid_token` (never a
      silent logout-everywhere); both `token` and `email` → 422 `exactly_one_of`
    * not-live → 409; missing admin token → 404; transport failure → 502
    * `app_token_revoke:<ip>` bucket → 429 past 10 hits/min, mint bucket
      untouched (D7)

  async: false — the rate-limit legs share the DeviceAuth.RateLimiter ETS
  table keyed by peer IP (always 127.0.0.1 under Plug.Test).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.DeviceAuth.RateLimiter, as: DeviceAuthRateLimiter
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"
  @app_token_raw "bpapp_token-to-revoke-plaintext"

  setup do
    DeviceAuthRateLimiter.reset()
    on_exit(fn -> DeviceAuthRateLimiter.reset() end)
    :ok
  end

  ## Fixtures (mirror RouterAppTokenTest's)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp live_barkpark(team) do
    bp = barkpark_fixture(team)

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp call(method, path, token \\ nil, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp revoked_200, do: {:ok, %{status: 200, body: ~s({"revoked":true})}}

  describe "DELETE /v1/barkparks/:id/app-token" do
    test "token mode: instance called with the admin bearer + exactly the presented token; payload relayed; admin token never leaks; audited without any token value" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([revoked_200()])

      conn =
        call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{token: @app_token_raw})

      assert conn.status == 200
      assert json_body(conn) == %{"revoked" => true}

      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :delete
      assert req.url == @instance_url <> "/v1/auth/app-tokens"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)

      assert Jason.decode!(req.body) == %{"token" => @app_token_raw}

      # The admin token itself must NEVER appear in the response.
      refute conn.resp_body =~ @instance_admin_token

      # Audited (allowlisted action), carrying mode + count — never a token.
      assert [event] =
               Repo.all(
                 from(e in Accounts.AuditEvent, where: e.action == "barkpark.app_token_revoked")
               )

      assert event.target_id == bp.id
      refute inspect(event.metadata) =~ @app_token_raw
      refute inspect(event.metadata) =~ @instance_admin_token
    end

    test "logout-everywhere: empty body → the instance body carries the CALLING user's email; revoked_count relayed" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: ~s({"revoked_count":2})}}])

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token)

      assert conn.status == 200
      assert json_body(conn) == %{"revoked_count" => 2}

      assert [req] = StudioLinkFakeHttpClient.requests()
      assert Jason.decode!(req.body) == %{"email" => user.email}
    end

    test "cross-team: a member of ANOTHER team gets the same 404 as a nonexistent id (no leak)" do
      {_user_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      wrong_team = call(:delete, "/v1/barkparks/#{bp_b.id}/app-token", token_a)
      nonexistent = call(:delete, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert json_body(wrong_team) == json_body(nonexistent)

      # And the instance was never called for either.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "no token → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token")
      assert conn.status == 401
    end

    test "malformed (non-UUID) id → 404, not a 500 CastError" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/not-a-uuid/app-token", token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "instance canonical not_found envelope → 404 not_found (the token really doesn't exist)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok,
         %{
           status: 404,
           body: ~s({"error":{"code":"not_found","message":"document not found"}})
         }}
      ])

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{token: "bpapp_gone"})
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "pre-revoke instance (route 404s with the Phoenix no-route body) → 409 revoke_unsupported (D8)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 404, body: ~s({"errors":{"detail":"Not Found"}})}}
      ])

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{token: "bpapp_x"})
      assert conn.status == 409
      assert json_body(conn)["error"] == "revoke_unsupported"
    end

    test "not-live instance (no url yet) → 409 not_live" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "not_live"
    end

    test "live instance without a stored admin token → 404 no_admin_token" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      bp =
        bp
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end

    test "instance revoke failing (transport error / unexpected status) → 502 instance_unreachable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])
      down = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token)
      assert down.status == 502
      assert json_body(down)["error"] == "instance_unreachable"

      StudioLinkFakeHttpClient.program([{:ok, %{status: 401, body: ~s({"error":"nope"})}}])
      denied = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token)
      assert denied.status == 502
    end

    test "instance 422 (the presented token is an ADMIN token) → 422 revoke_refused, NOT the 502 collapse" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok,
         %{
           status: 422,
           body:
             ~s({"error":{"code":"unprocessable","message":"admin tokens cannot be revoked through the app-token path"}})
         }}
      ])

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{token: "bpadmin_x"})

      assert conn.status == 422
      assert json_body(conn)["error"] == "revoke_refused"
    end

    test "instance 429 (its own revoke bucket tripped) → 429 instance_rate_limited, NOT the 502 collapse" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 429, body: ~s({"error":{"code":"rate_limited","message":"slow down"}})}}
      ])

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{token: "bpapp_x"})

      assert conn.status == 429
      assert json_body(conn)["error"] == "instance_rate_limited"
    end

    test "the three instance outcomes stay DISTINCT by response error code: 422 revoke_refused vs 429 instance_rate_limited vs 502 instance_unreachable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      codes =
        for programmed <- [
              {:ok, %{status: 422, body: ~s({"error":{"code":"unprocessable"}})}},
              {:ok, %{status: 429, body: ~s({"error":{"code":"rate_limited"}})}},
              {:error, {:http_client, :closed}}
            ] do
          StudioLinkFakeHttpClient.program([programmed])
          conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{token: "bpapp_x"})
          {conn.status, json_body(conn)["error"]}
        end

      assert codes == [
               {422, "revoke_refused"},
               {429, "instance_rate_limited"},
               {502, "instance_unreachable"}
             ]

      # Distinct, not merely three tuples — the whole point of the split.
      assert length(Enum.uniq(codes)) == 3
    end

    test "the caller's IP is RELAYED as X-Forwarded-For so the instance buckets per phone, not per control plane" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([revoked_200(), revoked_200()])

      for ip <- [{203, 0, 113, 7}, {198, 51, 100, 9}] do
        conn =
          :delete
          |> conn("/v1/barkparks/#{bp.id}/app-token", Jason.encode!(%{token: @app_token_raw}))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer #{token}")
          |> Map.put(:remote_ip, ip)
          |> Router.call(@opts)

        assert conn.status == 200
      end

      relayed =
        StudioLinkFakeHttpClient.requests()
        |> Enum.map(&List.keyfind(&1.headers, "X-Forwarded-For", 0))

      # Two distinct proxied callers → two DISTINCT instance bucket keys. Before
      # the relay both arrived from the single Cloud egress address and shared
      # one 10/min allowance (a whole team behind one bucket).
      assert relayed == [{"X-Forwarded-For", "203.0.113.7"}, {"X-Forwarded-For", "198.51.100.9"}]
    end

    test ~s|{"token": ""} is a 422 naming the field — it must NEVER fall through to logout-everywhere| do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{token: ""})

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_token"
      assert json_body(conn)["detail"] =~ "non-empty"

      # And nothing was revoked anywhere: the instance was never called.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a body carrying BOTH token and email is a 422 exactly_one_of — token does not silently win" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn =
        call(:delete, "/v1/barkparks/#{bp.id}/app-token", token, %{
          token: @app_token_raw,
          email: "someone-else@example.com"
        })

      assert conn.status == 422
      assert json_body(conn)["error"] == "exactly_one_of"
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "app_token_revoke:<ip> bucket → 429 past 10 hits/min; mint + start buckets untouched (D7)" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      # 10 authed hits are allowed (nonexistent id → 404 — the check still
      # counts, so probing ids burns the same budget as revoking)...
      for _ <- 1..10 do
        conn = call(:delete, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token)
        assert conn.status == 404
      end

      # ...the 11th from the same IP is braked before any registry work.
      conn = call(:delete, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token)
      assert conn.status == 429
      assert json_body(conn)["error"] == "rate_limited"
      assert StudioLinkFakeHttpClient.requests() == []

      # Action-scoped: the revoke flood leaves the MINT bucket (and the
      # device-auth "start" bucket) for the same IP untouched.
      assert DeviceAuthRateLimiter.check("app_token:127.0.0.1") == :ok
      assert DeviceAuthRateLimiter.check("start:127.0.0.1") == :ok
    end
  end
end
