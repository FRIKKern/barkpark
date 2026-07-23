defmodule BarkparkCloud.Web.RouterAppTokenTest do
  @moduledoc """
  Mobile charter D4/D7/D8 — the member-reachable app-token exchange, control-plane
  half (`router_studio_link_test.exs`'s sibling).

  `POST /v1/barkparks/:id/app-token` uses the stored per-instance admin token
  SERVER-SIDE to mint a workspace-bound `[read,write,chat]` app token on the
  instance and relays the payload. Proves:

    * happy path: 200 {token, workspace_id, permissions, expires_at}; the
      instance call carried `Authorization: Bearer <decrypted admin token>` and a
      body with the cloud user's email + the member-shaped permission set; the
      admin token NEVER appears in the response
    * cross-team deny: a member of another team gets the SAME 404 as a
      nonexistent id (no existence leak)
    * unauthenticated → 401; malformed (non-UUID) id → 404, not 500
    * not-live instance → 409; missing admin token → 404 no_admin_token
    * instance 404 (pre-exchange server) → 409 app_token_unsupported (D8)
    * instance failure → 502 instance_unreachable
    * `app_token:<ip>` rate bucket → 429 past 10 hits/min (D7)

  async: false — the rate-limit legs share the DeviceAuth.RateLimiter ETS table
  keyed by peer IP (always 127.0.0.1 under Plug.Test), so the counters must be
  reset per test and never raced by a sibling async file's app-token hits.
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
  @minted_app_token "bpapp_minted-token-plaintext"

  setup do
    DeviceAuthRateLimiter.reset()
    on_exit(fn -> DeviceAuthRateLimiter.reset() end)
    :ok
  end

  ## Fixtures (mirror RouterStudioLinkTest's)

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

  # A LIVE instance: url set + the encrypted admin token stored (what the
  # provision-succeed path writes).
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

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp minted_201 do
    {:ok,
     %{
       status: 201,
       body:
         Jason.encode!(%{
           token: @minted_app_token,
           workspace_id: "11111111-2222-3333-4444-555555555555",
           permissions: ["read", "write", "chat"],
           expires_at: nil
         })
     }}
  end

  describe "POST /v1/barkparks/:id/app-token" do
    test "member of owning team → 200 payload; instance called with the admin bearer + member-shaped body; admin token never leaks" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([minted_201()])

      conn = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)

      assert conn.status == 200
      body = json_body(conn)
      assert body["token"] == @minted_app_token
      assert body["workspace_id"] == "11111111-2222-3333-4444-555555555555"
      assert body["permissions"] == ["read", "write", "chat"]
      assert body["expires_at"] == nil

      # The instance-side mint was called correctly: right endpoint, the
      # DECRYPTED admin token as bearer, the CALLING user's email + the
      # ratified [read,write,chat] set in the body — never "admin".
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :post
      assert req.url == @instance_url <> "/v1/auth/app-tokens"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)

      sent = Jason.decode!(req.body)
      assert sent["email"] == user.email
      assert sent["permissions"] == ["read", "write", "chat"]
      refute "admin" in sent["permissions"]
      assert is_binary(sent["label"]) and sent["label"] != ""

      # The admin token itself must NEVER appear in the response.
      refute conn.resp_body =~ @instance_admin_token

      # OC24: the mint is AUDITED (the action must be in the AuditEvent
      # allowlist — a rejected insert only logs), and the audit row carries
      # neither the minted token nor the admin token.
      assert [event] =
               Repo.all(
                 from(e in Accounts.AuditEvent, where: e.action == "barkpark.app_token_minted")
               )

      assert event.target_id == bp.id
      refute inspect(event.metadata) =~ @minted_app_token
      refute inspect(event.metadata) =~ @instance_admin_token
    end

    test "cross-team: a member of ANOTHER team gets the same 404 as a nonexistent id (no leak)" do
      {_user_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      wrong_team = call(:post, "/v1/barkparks/#{bp_b.id}/app-token", token_a)
      nonexistent = call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert json_body(wrong_team) == json_body(nonexistent)

      # And the instance was never called for either.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "no token → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/app-token")
      assert conn.status == 401
    end

    test "malformed (non-UUID) id → 404, not a 500 CastError" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/not-a-uuid/app-token", token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "not-live instance (no url yet) → 409 not_live" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)
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

      conn = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end

    test "pre-exchange instance (mint route 404s) → 409 app_token_unsupported (D8)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 404, body: ~s({"errors":{"detail":"Not Found"}})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "app_token_unsupported"
    end

    test "instance mint failing (non-201 / transport error) → 502 instance_unreachable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])
      down = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)
      assert down.status == 502
      assert json_body(down)["error"] == "instance_unreachable"

      StudioLinkFakeHttpClient.program([{:ok, %{status: 401, body: ~s({"error":"nope"})}}])
      denied = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)
      assert denied.status == 502
    end

    test "instance 201 without a token in the body → 502 (never a silent empty credential)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:ok, %{status: 201, body: ~s({"ok":true})}}])

      conn = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)
      assert conn.status == 502
    end

    test "app_token:<ip> bucket → 429 past 10 hits/min; other buckets untouched (D7)" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      # 10 authed hits are allowed (nonexistent id → 404 — the check still
      # counts, so probing ids burns the same budget as minting)...
      for _ <- 1..10 do
        conn = call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token)
        assert conn.status == 404
      end

      # ...the 11th from the same IP is braked before any registry work.
      conn = call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token)
      assert conn.status == 429
      assert json_body(conn)["error"] == "rate_limited"
      assert StudioLinkFakeHttpClient.requests() == []

      # The bucket is action-scoped: the app_token flood leaves the device-auth
      # "start" bucket for the same IP untouched.
      assert DeviceAuthRateLimiter.check("start:127.0.0.1") == :ok
    end
  end
end
