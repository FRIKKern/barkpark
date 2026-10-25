defmodule BarkparkCloud.Web.RouterStudioHandoffTest do
  @moduledoc """
  "Sign in with Barkpark Cloud" for an EXTERNAL Studio — the control-plane half.

  `POST /v1/auth/studio-handoff` answers the URL the SPA sends the editor to:
  `return_to?ticket=…&state=…`, where the ticket is an EXCHANGE ticket the
  instance minted off its stored admin token. Pins: membership on the
  instance's own team, `return_to` exactly on the instance's callback
  allowlist, the exchange fields sent to the instance, and the team-admin
  allowlist API.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @admin_token "instance-admin-token-plaintext"
  @callback_url "https://studio.example.com/auth/cloud/callback"
  @state "s_0123456789abcdefABCDEF"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp live_barkpark(team, callbacks \\ [@callback_url]) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://handoff-#{n}.barkpark.cloud",
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@admin_token),
      studio_callback_urls: callbacks
    )
    |> Repo.update!()
  end

  defp call(method, path, body, token) do
    conn =
      method
      |> conn(path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp handoff(bp, token, overrides \\ %{}) do
    body =
      Map.merge(
        %{instance: bp.id, return_to: @callback_url, state: @state, code_challenge: @challenge},
        overrides
      )

    call(:post, "/v1/auth/studio-handoff", body, token)
  end

  defp exchange_ticket(t),
    do: {:ok, %{status: 201, body: ~s({"ticket":"#{t}","expires_in":60,"purpose":"exchange"})}}

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/auth/studio-handoff" do
    test "allowed: a team member gets return_to?ticket&state, and the instance mints an exchange ticket" do
      {owner, team, _} = user_with_team()
      _ = owner
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, token} = Accounts.create_user_session_token(member)
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([exchange_ticket("bplt_x1")])
      conn = handoff(bp, token)

      assert conn.status == 200
      assert body(conn)["url"] == @callback_url <> "?ticket=bplt_x1&state=#{@state}"

      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.url == bp.url <> "/v1/auth/login-tickets"

      assert Jason.decode!(req.body) == %{
               "email" => member.email,
               "role" => "member",
               "purpose" => "exchange",
               "audience" => "https://studio.example.com",
               "code_challenge" => @challenge
             }

      refute conn.resp_body =~ @admin_token
    end

    test "denied: a member of another team is 404 and the instance is never called" do
      {_, team_a, _} = user_with_team()
      bp = live_barkpark(team_a)
      {_, _team_b, outsider_token} = user_with_team()

      conn = handoff(bp, outsider_token)
      assert conn.status == 404
      assert body(conn) == %{"error" => "not_found"}
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "denied: return_to not EXACTLY on the allowlist is 403, nothing minted" do
      {_, team, token} = user_with_team()
      bp = live_barkpark(team)

      for bad <- [
            "https://evil.example.com/auth/cloud/callback",
            @callback_url <> "/",
            @callback_url <> "?next=/x",
            "https://studio.example.com/auth/cloud/callback#x",
            "https://studio.example.com.evil.com/auth/cloud/callback"
          ] do
        conn = handoff(bp, token, %{return_to: bad})
        assert conn.status == 403, "expected 403 for #{bad}"
        assert body(conn)["error"] == "return_to_not_allowed"
      end

      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "denied: no session, bad state, bad challenge" do
      {_, team, token} = user_with_team()
      bp = live_barkpark(team)

      assert handoff(bp, nil).status == 401
      assert body(handoff(bp, token, %{state: "short"}))["error"] == "invalid_state"

      assert body(handoff(bp, token, %{code_challenge: "nope"}))["error"] ==
               "invalid_code_challenge"

      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "an instance that ignores purpose (older Barkpark) is 409 instance_outdated, no URL" do
      {_, team, token} = user_with_team()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_browser","expires_in":60})}}
      ])

      conn = handoff(bp, token)
      assert conn.status == 409
      assert body(conn)["error"] == "instance_outdated"
      refute conn.resp_body =~ "bplt_browser"
    end

    test "a suspended instance mints nothing" do
      {_, team, token} = user_with_team()
      bp = live_barkpark(team) |> Ecto.Changeset.change(suspended: true) |> Repo.update!()

      assert handoff(bp, token).status == 409
      assert StudioLinkFakeHttpClient.requests() == []
    end
  end

  describe "/v1/barkparks/:id/studio-callbacks" do
    test "a team admin adds, lists and removes a callback; the handoff follows the list" do
      {_, team, token} = user_with_team("owner")
      bp = live_barkpark(team, [])
      path = "/v1/barkparks/#{bp.id}/studio-callbacks"

      assert handoff(bp, token).status == 403

      conn = call(:post, path, %{url: " " <> @callback_url <> " "}, token)
      assert body(conn) == %{"studio_callbacks" => [@callback_url]}
      # idempotent
      assert body(call(:post, path, %{url: @callback_url}, token))["studio_callbacks"] == [
               @callback_url
             ]

      assert body(call(:get, path, %{}, token)) == %{"studio_callbacks" => [@callback_url]}

      StudioLinkFakeHttpClient.program([exchange_ticket("bplt_x2")])
      assert handoff(bp, token).status == 200

      assert body(call(:delete, path, %{url: @callback_url}, token)) == %{
               "studio_callbacks" => []
             }

      assert handoff(bp, token).status == 403
    end

    test "a plain member cannot change the list" do
      {_, team, _} = user_with_team("owner")
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, token} = Accounts.create_user_session_token(member)
      bp = live_barkpark(team, [])

      assert call(:post, "/v1/barkparks/#{bp.id}/studio-callbacks", %{url: @callback_url}, token).status ==
               403
    end

    test "unsafe callback URLs are refused" do
      {_, team, token} = user_with_team("owner")
      bp = live_barkpark(team, [])
      path = "/v1/barkparks/#{bp.id}/studio-callbacks"

      for bad <- [
            "http://studio.example.com/auth/cloud/callback",
            "https://studio.example.com",
            "https://user@studio.example.com/cb",
            "https://studio.example.com/cb?x=1",
            "https://studio.example.com/cb#f",
            "javascript:alert(1)",
            "/auth/cloud/callback"
          ] do
        conn = call(:post, path, %{url: bad}, token)
        assert conn.status == 422, "expected 422 for #{bad}"
      end

      assert call(:post, path, %{url: "http://localhost:3171/auth/cloud/callback"}, token).status ==
               200
    end
  end
end
