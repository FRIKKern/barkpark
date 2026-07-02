defmodule BarkparkCloud.Web.RouterSiteUrlTest do
  @moduledoc """
  dwb-6 "site-url" — the deferred-URL control-plane half.

  `POST /v1/barkparks/:id/site-url {url}` uses the stored per-instance admin token
  SERVER-SIDE to point the bootstrap ISR-revalidation webhook (registered DISABLED
  with a `.invalid` placeholder at dwb-5) at the just-deployed site and flip it
  ACTIVE. Proves:

    * happy path: 200 {site_url, webhook_url}; the instance was LISTed then the
      matching endpoint PUT with the real `<site>/api/barkpark/webhook` + active:true;
      the admin token rode as the bearer and NEVER leaks into the response
    * idempotent re-PUT converges (200 again, same wiring)
    * member-gated (any team member); cross-team / unknown / malformed id → SAME 404
    * unauth → 401; missing/blank url → 422; non-http url → 422 invalid_url
    * not-live → 409; missing admin token → 404; no bootstrap → 404;
      no revalidation webhook on the instance → 409 no_webhook; instance failure → 502
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
  @admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"
  @workspace "acme"
  @dataset "production"
  @webhook_id "wh_bootstrap_123"
  @site "https://acme-blog.vercel.app"

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

  # A live instance with a stored admin token AND bootstrap outputs (what dwb-4/5
  # write on /succeed) — the shape site-url needs to reach the instance webhook.
  defp bootstrapped_barkpark(team) do
    barkpark_fixture(team)
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@admin_token),
      template: "blog-starter",
      bootstrap_workspace: @workspace,
      bootstrap_project: "default",
      bootstrap_dataset: @dataset,
      bootstrap_read_token_encrypted: Vault.encrypt("bp_read_secret")
    )
    |> Repo.update!()
  end

  defp call(method, path, body, token) do
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

  # The instance list response carrying the bootstrap-owned endpoint.
  defp list_response do
    {:ok,
     %{
       status: 200,
       body:
         Jason.encode!(%{
           webhooks: [
             %{id: @webhook_id, name: "bootstrap-revalidation", active: false},
             %{id: "wh_other", name: "some-other-hook", active: true}
           ]
         })
     }}
  end

  describe "POST /v1/barkparks/:id/site-url" do
    test "member wires the site → 200; instance LISTed then PUT with real URL + active; token never leaks" do
      {user, team} = user_with_team("member")
      bp = bootstrapped_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        list_response(),
        {:ok, %{status: 200, body: ~s({"webhook":{"id":"#{@webhook_id}","active":true}})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)

      assert conn.status == 200
      body = json_body(conn)
      assert body["site_url"] == @site
      assert body["webhook_url"] == @site <> "/api/barkpark/webhook"

      [list_req, put_req] = StudioLinkFakeHttpClient.requests()

      # LIST: GET the scoped dataset webhooks with the decrypted admin bearer.
      assert list_req.method == :get

      assert list_req.url ==
               @instance_url <> "/w/#{@workspace}/p/default/v1/webhooks/#{@dataset}"

      assert {"Authorization", "Bearer " <> @admin_token} =
               List.keyfind(list_req.headers, "Authorization", 0)

      # PUT: the matched endpoint, real URL + active:true.
      assert put_req.method == :put

      assert put_req.url ==
               @instance_url <>
                 "/w/#{@workspace}/p/default/v1/webhooks/#{@dataset}/#{@webhook_id}"

      put_payload = Jason.decode!(put_req.body)
      assert put_payload["url"] == @site <> "/api/barkpark/webhook"
      assert put_payload["active"] == true

      # The admin token must never appear in the response.
      refute conn.resp_body =~ @admin_token
    end

    test "idempotent: a re-PUT with the same URL converges (200 again)" do
      {user, team} = user_with_team()
      bp = bootstrapped_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      program = fn ->
        StudioLinkFakeHttpClient.program([
          list_response(),
          {:ok, %{status: 200, body: ~s({"ok":true})}}
        ])
      end

      program.()
      first = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert first.status == 200

      program.()
      second = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert second.status == 200
      assert json_body(second) == json_body(first)
    end

    test "cross-team / unknown / malformed id are the SAME 404 (no leak), instance never called" do
      {_ub, team_b} = user_with_team()
      bp_b = bootstrapped_barkpark(team_b)

      {ua, _team_a} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(ua)

      wrong = call(:post, "/v1/barkparks/#{bp_b.id}/site-url", %{url: @site}, token_a)

      missing =
        call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/site-url", %{url: @site}, token_a)

      malformed = call(:post, "/v1/barkparks/not-a-uuid/site-url", %{url: @site}, token_a)

      assert wrong.status == 404
      assert missing.status == 404
      assert malformed.status == 404
      assert json_body(wrong) == json_body(missing)
      assert json_body(malformed)["error"] == "not_found"
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "no token → 401" do
      {_u, team} = user_with_team()
      bp = bootstrapped_barkpark(team)
      assert call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, nil).status == 401
    end

    test "missing/blank url → 422 url_required; a non-http url → 422 invalid_url" do
      {user, team} = user_with_team()
      bp = bootstrapped_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      blank = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: ""}, token)
      assert blank.status == 422
      assert json_body(blank)["error"] == "url_required"

      ftp = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: "ftp://nope"}, token)
      assert ftp.status == 422
      assert json_body(ftp)["error"] == "invalid_url"

      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "not-live instance (no url) → 409 not_live" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "not_live"
    end

    test "live but no stored admin token → 404 no_admin_token" do
      {user, team} = user_with_team()

      bp =
        barkpark_fixture(team)
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end

    test "live + admin token but no bootstrap → 404 no_bootstrap" do
      {user, team} = user_with_team()

      bp =
        barkpark_fixture(team)
        |> Ecto.Changeset.change(
          url: @instance_url,
          host: "203.0.113.10",
          admin_token_encrypted: Vault.encrypt(@admin_token)
        )
        |> Repo.update!()

      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_bootstrap"
    end

    test "instance has no revalidation webhook → 409 no_webhook" do
      {user, team} = user_with_team()
      bp = bootstrapped_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: Jason.encode!(%{webhooks: [%{id: "x", name: "other"}]})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "no_webhook"
    end

    test "instance list/update failure → 502 instance_unreachable" do
      {user, team} = user_with_team()
      bp = bootstrapped_barkpark(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      # LIST transport error.
      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])
      down = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert down.status == 502
      assert json_body(down)["error"] == "instance_unreachable"

      # LIST ok, PUT rejected.
      StudioLinkFakeHttpClient.program([
        list_response(),
        {:ok, %{status: 500, body: ~s({"error":"boom"})}}
      ])

      put_fail = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, token)
      assert put_fail.status == 502
    end
  end
end
