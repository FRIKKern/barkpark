defmodule BarkparkCloud.Web.RouterStudioLinkTest do
  @moduledoc """
  dwb-7 "Studio one-click entry" — the control-plane half.

  `POST /v1/barkparks/:id/studio-link` uses the stored per-instance admin token
  SERVER-SIDE to mint a single-use login ticket on the instance and returns the
  handoff URL. Proves:

    * happy path: 200 {url} = <instance>/login/ticket/<ticket>; the instance
      call carried `Authorization: Bearer <decrypted admin token>` and the
      admin token NEVER appears in the response
    * cross-team deny: a member of another team gets the SAME 404 as a
      nonexistent id (no existence leak)
    * unauthenticated → 401; malformed (non-UUID) id → 404, not 500
    * not-live instance → 409; missing admin token → 404 no_admin_token
    * instance failure → 502 instance_unreachable

  cch-w54-s2 adds the SUSPENSION half: a box suspended through the real
  producer (`Registry.suspend_team_barkparks/2`) mints nothing on any of the
  three admin-credential-backed routes — studio-link, app-token, credentials —
  and the refusal fires BEFORE the stored admin token is decrypted, so the
  instance is never called. These tests assert the REFUSAL; there is
  deliberately no test here asserting 200 for a suspended box, because that
  would pin the defect this slice closes.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"

  ## Fixtures (mirror RouterTest's)

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

  # A SUSPENDED live instance, suspended through the REAL producer both billing
  # paths call (`billing.ex:855`/`:882`) rather than a hand-set column — so the
  # tests prove the state a paying-then-lapsing team actually lands in.
  defp suspended_live_barkpark(team) do
    bp = live_barkpark(team)
    {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
    Registry.get_barkpark(bp.id)
  end

  describe "POST /v1/barkparks/:id/studio-link" do
    test "member of owning team → 200 {url}; instance called with the admin bearer; token never leaks" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_test-ticket-1","expires_in":60})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)

      assert conn.status == 200
      assert json_body(conn)["url"] == @instance_url <> "/login/ticket/bplt_test-ticket-1"

      # The instance-side mint was called correctly: right endpoint, the
      # DECRYPTED admin token as bearer.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :post
      assert req.url == @instance_url <> "/v1/auth/login-tickets"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)

      # The admin token itself must NEVER appear in the response (the whole
      # point vs /credentials) — nor may the URL carry it.
      refute conn.resp_body =~ @instance_admin_token
    end

    test "the mint body carries the cloud user's email (cloud-identity handoff)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_user-shaped-1","expires_in":60})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)
      assert conn.status == 200

      # The instance mint request asks for a USER-shaped ticket bound to the
      # cloud account's email — the browser lands signed in AS this user.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert Jason.decode!(req.body) == %{"email" => user.email}
    end

    test "cross-team: a member of ANOTHER team gets the same 404 as a nonexistent id (no leak)" do
      {_user_b, team_b} = user_with_team()
      bp_b = live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      wrong_team = call(:post, "/v1/barkparks/#{bp_b.id}/studio-link", token_a)
      nonexistent = call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/studio-link", token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert json_body(wrong_team) == json_body(nonexistent)

      # And the instance was never called for either.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "no token → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link")
      assert conn.status == 401
    end

    test "malformed (non-UUID) id → 404, not a 500 CastError" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/not-a-uuid/studio-link", token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "not-live instance (no url yet) → 409 not_live" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)
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

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end

    test "instance mint failing (non-201 / transport error) → 502 instance_unreachable" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])
      down = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)
      assert down.status == 502
      assert json_body(down)["error"] == "instance_unreachable"

      StudioLinkFakeHttpClient.program([{:ok, %{status: 401, body: ~s({"error":"nope"})}}])
      denied = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)
      assert denied.status == 502
    end
  end

  # cch-w54-s2 — SUSPENSION CLOSES THE THREE ADMIN-CREDENTIAL-BACKED PATHS.
  #
  # Suspension is billing's "data retained, access revoked" (billing.ex
  # cancel_subscription/1). Before this block, a box suspended through the REAL
  # producer still handed a team member a redeemable Studio ticket, a durable
  # read+write+chat app token, and — to an admin — the PLAINTEXT instance admin
  # token. Every test here asserts the REFUSAL and, where the route calls the
  # instance, that the instance was NEVER called: the guard sits above
  # `reveal_admin_token/1`, so a suspended box costs the control plane one
  # boolean and leaks nothing.
  describe "suspension closes the mint and reveal paths" do
    test "studio-link on a suspended box → 409 suspended, and the instance is never called" do
      {user, team} = user_with_team()
      bp = suspended_live_barkpark(team)
      assert bp.suspended
      {:ok, token} = Accounts.create_user_session_token(user)

      # Programmed to succeed on purpose: if the guard were missing, this box
      # would mint a real ticket. It must never be consumed.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_must-not-mint","expires_in":60})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "suspended"
      assert json_body(conn)["detail"] =~ "suspended"
      refute conn.resp_body =~ "bplt_must-not-mint"
      refute conn.resp_body =~ @instance_admin_token

      # The refusal beat the decrypt: no byte left the control plane.
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "app-token on a suspended box → 409 suspended; no durable credential is issued" do
      {user, team} = user_with_team()
      bp = suspended_live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok,
         %{
           status: 201,
           body:
             ~s({"token":"bpapp_must-not-mint","permissions":["read","write","chat"],"expires_at":"2030-01-01T00:00:00Z"})
         }}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/app-token", token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "suspended"
      assert json_body(conn)["detail"] =~ "suspended"
      refute conn.resp_body =~ "bpapp_must-not-mint"
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "credentials on a suspended box → 409 suspended; the plaintext admin token stays hidden" do
      {user, team} = user_with_team()
      bp = suspended_live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks/#{bp.id}/credentials", token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "suspended"
      refute conn.resp_body =~ @instance_admin_token
    end

    test "the 409 detail names the billing remedy without promising restoration" do
      {user, team} = user_with_team()
      bp = suspended_live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)
      detail = json_body(conn)["detail"]

      assert detail =~ "subscription is current"
      # The card banner already carries the restoration promise (app.js
      # suspendedCardBannerHtml); an error toast repeating it would answer a
      # question nobody asked instead of saying why THIS click failed.
      refute detail =~ "comes back"
      refute detail =~ "exactly as it was"
    end

    test "resuming the team re-opens all three paths (the guard can lose)" do
      {user, team} = user_with_team()
      bp = suspended_live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      assert call(:post, "/v1/barkparks/#{bp.id}/studio-link", token).status == 409

      {:ok, 1} = Registry.resume_team_barkparks(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_after-resume","expires_in":60})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", token)
      assert conn.status == 200
      assert json_body(conn)["url"] == @instance_url <> "/login/ticket/bplt_after-resume"

      creds = call(:get, "/v1/barkparks/#{bp.id}/credentials", token)
      assert creds.status == 200
      assert json_body(creds)["admin_token"] == @instance_admin_token
    end

    test "a LIVE (unsuspended) box is untouched by the guard on all three routes" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_healthy","expires_in":60})}},
        {:ok, %{status: 201, body: ~s({"token":"bpapp_healthy","permissions":["read"]})}}
      ])

      assert call(:post, "/v1/barkparks/#{bp.id}/studio-link", token).status == 200
      assert call(:post, "/v1/barkparks/#{bp.id}/app-token", token).status == 200
      assert call(:get, "/v1/barkparks/#{bp.id}/credentials", token).status == 200
    end

    test "a suspended box in ANOTHER team is still the plain 404 — the 409 leaks no existence" do
      {_user_b, team_b} = user_with_team()
      bp_b = suspended_live_barkpark(team_b)

      {user_a, _team_a} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      wrong_team = call(:post, "/v1/barkparks/#{bp_b.id}/studio-link", token_a)
      nonexistent = call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/studio-link", token_a)

      assert wrong_team.status == 404
      assert json_body(wrong_team) == json_body(nonexistent)
    end
  end
end
