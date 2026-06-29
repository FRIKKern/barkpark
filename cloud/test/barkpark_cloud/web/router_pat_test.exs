defmodule BarkparkCloud.Web.RouterPatTest do
  @moduledoc """
  Drives the Personal-Access-Token surface of the cloud-12a JSON API via
  Plug.Test: the session-only management routes (`GET/POST/DELETE /v1/tokens`)
  and PAT-authed access to selected `/v1/*` routes through the
  `require_user_or_pat` + `require_ability` pair. Mirrors RouterTest's
  DataCase + Plug.Test setup.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
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

  # A user who belongs to a fresh team + a live session token. Returns
  # {user, team, session_token}.
  defp logged_in do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, session} = Accounts.create_user_session_token(user)
    {user, team, session}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "Site #{n}", slug: "site-#{n}"})
    site
  end

  ## Request helper

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

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  ## Management routes (session-only)

  describe "POST /v1/tokens" do
    test "mints a PAT, returns the plaintext once, never the hash" do
      {_user, _team, session} = logged_in()

      conn = call(:post, "/v1/tokens", %{name: "ci-key", abilities: ["read"]}, session)
      assert conn.status == 201
      body = decode(conn)

      assert String.starts_with?(body["token"], "bpc_pat_")
      assert body["pat"]["name"] == "ci-key"
      assert body["pat"]["abilities"] == ["read"]
      refute Map.has_key?(body["pat"], "token_hash")
      # The plaintext is not echoed inside the pat object.
      refute body["pat"]["token"]
    end

    test "422 no_team when the user has no team" do
      user = user_fixture()
      {:ok, session} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/tokens", %{name: "ci-key"}, session)
      assert conn.status == 422
      assert decode(conn)["error"] == "no_team"
    end

    test "422 invalid for a too-short name" do
      {_u, _t, session} = logged_in()
      conn = call(:post, "/v1/tokens", %{name: "ab"}, session)
      assert conn.status == 422
      assert decode(conn)["error"] == "invalid"
    end

    test "401 when authenticated with a PAT (management is session-only)" do
      {user, team, _session} = logged_in()

      {:ok, pat_plaintext, _pat} =
        Accounts.create_personal_access_token(user, team, %{name: "self", abilities: ["root"]})

      conn = call(:post, "/v1/tokens", %{name: "escalate", abilities: ["root"]}, pat_plaintext)
      assert conn.status == 401
    end
  end

  describe "GET /v1/tokens" do
    test "lists the caller's PATs newest-first, never the hash" do
      {user, team, session} = logged_in()
      {:ok, _p, _a} = Accounts.create_personal_access_token(user, team, %{name: "alpha"})
      {:ok, _p2, _b} = Accounts.create_personal_access_token(user, team, %{name: "beta"})

      conn = call(:get, "/v1/tokens", nil, session)
      assert conn.status == 200
      tokens = decode(conn)["tokens"]
      assert length(tokens) == 2
      assert hd(tokens)["name"] == "beta"
      refute Map.has_key?(hd(tokens), "token_hash")
    end
  end

  describe "DELETE /v1/tokens/:id" do
    test "revokes the caller's own token" do
      {user, team, session} = logged_in()
      {:ok, _p, pat} = Accounts.create_personal_access_token(user, team, %{name: "doomed"})

      conn = call(:delete, "/v1/tokens/#{pat.id}", nil, session)
      assert conn.status == 200
      assert decode(conn)["ok"] == true
    end

    test "404 for another user's token (no existence leak)" do
      {_owner, team, _s} = logged_in()

      {:ok, _p, pat} =
        Accounts.create_personal_access_token(user_fixture(), team, %{name: "theirs"})

      {_other, _team2, other_session} = logged_in()
      conn = call(:delete, "/v1/tokens/#{pat.id}", nil, other_session)
      assert conn.status == 404
    end
  end

  ## PAT-authed access via require_ability

  describe "ability gating on /v1/* routes" do
    test "a read PAT can GET /v1/barkparks" do
      {user, team, _session} = logged_in()

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "ro-key", abilities: ["read"]})

      conn = call(:get, "/v1/barkparks", nil, read_token)
      assert conn.status == 200
      assert is_list(decode(conn)["barkparks"])
    end

    test "a write PAT can deploy a site; a read PAT is 403'd" do
      {user, team, _session} = logged_in()
      site = site_fixture(team)

      {:ok, write_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "rw-key", abilities: ["write"]})

      {:ok, read_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "ro-key", abilities: ["read"]})

      ok = call(:post, "/v1/sites/#{site.id}/deploy", %{}, write_token)
      assert ok.status == 201

      denied = call(:post, "/v1/sites/#{site.id}/deploy", %{}, read_token)
      assert denied.status == 403
      assert decode(denied)["error"] == "forbidden"
    end

    test "a root PAT passes every ability gate" do
      {user, team, _session} = logged_in()
      site = site_fixture(team)

      {:ok, root_token, _} =
        Accounts.create_personal_access_token(user, team, %{name: "root", abilities: ["root"]})

      assert call(:get, "/v1/barkparks", nil, root_token).status == 200
      assert call(:post, "/v1/sites/#{site.id}/deploy", %{}, root_token).status == 201
    end

    test "a session token still works on the PAT-opted read routes" do
      {_u, _t, session} = logged_in()
      conn = call(:get, "/v1/me", nil, session)
      assert conn.status == 200
    end

    test "a revoked PAT no longer authenticates" do
      {user, team, _session} = logged_in()

      {:ok, token, pat} =
        Accounts.create_personal_access_token(user, team, %{
          name: "soon-dead",
          abilities: ["read"]
        })

      assert call(:get, "/v1/barkparks", nil, token).status == 200
      {:ok, _} = Accounts.revoke_personal_access_token(user, pat.id)
      assert call(:get, "/v1/barkparks", nil, token).status == 401
    end
  end
end
