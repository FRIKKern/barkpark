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
end
