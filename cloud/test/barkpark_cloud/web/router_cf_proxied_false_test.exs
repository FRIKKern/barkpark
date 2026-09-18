defmodule BarkparkCloud.Web.RouterCfProxiedFalseTest do
  @moduledoc """
  CRASH REGRESSION — `do_bind_cloudflare/5` must not raise `WithClauseError`
  when Cloudflare answers the proxy PATCH with `proxied: false`.

  `Cloudflare.Client.ensure_zone_proxied/3` is specced
  `{:ok, %{proxied: boolean()}} | {:error, term}`, so `{:ok, %{proxied: false}}`
  is a DECLARED return — Cloudflare accepted the PATCH (2xx) but the orange
  cloud did not stick. The router's `with` matched only
  `{:ok, %{proxied: true}}` and its `else` covered only `{:error, _}` shapes, so
  that declared return had NO clause: the request died with a `WithClauseError`
  (a 500 plus a stacktrace, and no honest answer about the A record just
  written). The fix adds an explicit `{:ok, %{proxied: false}}` arm that fails
  CLOSED — no binding persisted, bounded 502 — and logs loudly.

  Both tests drive the REAL authenticated owner deploy path through
  `Cloudflare.Real` with an injected `http_client` stub, so the shape under test
  is one `Real.ensure_zone_proxied/3` genuinely produces from a Cloudflare body
  (`%{"result" => %{"proxied" => false}}`), not one invented by a hand-written
  client double.

    * THE ARM: the proxied:false stub. REDS on the unfixed tree — reverting the
      router clause makes this raise `WithClauseError` instead of answering 502.
    * THE CONTROL: the identical stub with `"proxied": true`. Stays GREEN either
      way, proving the fix did not swallow the normal path — the binding IS
      persisted and the site flips to `cf_proxied`.

  `async: true` — the Cloudflare client + http_client swap is installed in THIS
  test's process dictionary via `Cloudflare.put_process_config/1` (see the
  Cloudflare moduledoc, "Process-scoped config override"), invisible to every
  concurrently-running test.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Cloudflare, Registry}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @origin "203.0.113.10"
  @domain "blog.example.com"
  @record_id "rec_grey_cloud"

  ## Fixtures (mirror router_cloudflare_redaction_test.exs)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://acme.barkpark.cloud",
      host: @origin,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> BarkparkCloud.Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read"
      })

    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # A Cloudflare that ACCEPTS both writes with 2xx. The DNS upsert (`:post`)
  # succeeds normally; the proxy flip (`:patch`) comes back 200 with the record
  # reporting `proxied` as whatever the caller asked for — `false` is the grey
  # cloud that never flipped, the crash shape.
  # `proxied` is deliberately UNGUARDED: `Real.ensure_zone_proxied/3` lifts the
  # value straight out of the body without checking it is a boolean, so a
  # non-boolean (the `nil` arm below) is a shape the real client really can
  # produce.
  defp put_cloudflare_reporting_proxied(proxied) do
    stub = fn
      %{method: :patch} ->
        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{"result" => %{"id" => @record_id, "proxied" => proxied}})
         }}

      _post_upsert ->
        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{"result" => %{"id" => @record_id, "name" => @domain}})
         }}
    end

    Cloudflare.put_process_config(
      Keyword.merge(Cloudflare.resolved_config(),
        client: BarkparkCloud.Cloudflare.Real,
        http_client: stub
      )
    )
  end

  defp drive_bind do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)
    token = login_token(user)

    {:ok, _} =
      Registry.connect_provider(
        team,
        "cloudflare",
        Jason.encode!(%{"api_token" => "cf_live_token", "zone_id" => "zone_acme"})
      )

    {conn, log} =
      with_log(fn ->
        call(:post, "/v1/sites/#{site.id}/deploy", %{via: "cloudflare", domain: @domain}, token)
      end)

    {conn, log, site}
  end

  describe "POST /v1/sites/:id/deploy via=cloudflare — Cloudflare answers proxied:false" do
    test "THE ARM: the declared {:ok, %{proxied: false}} return is handled, not a WithClauseError" do
      put_cloudflare_reporting_proxied(false)

      # The crash this file exists for raises out of Router.call/2 rather than
      # returning a conn, so the whole drive is the subject of the assertion:
      # on the unfixed tree this line raises WithClauseError.
      {conn, log, site} = drive_bind()

      assert conn.status == 502,
             "expected the bounded cf-bind refusal, got #{conn.status}: #{conn.resp_body}"

      body = json_body(conn)
      assert body["error"] == "cloudflare_bind_failed"

      # The bounded detail names the grey-cloud condition (no raw provider body,
      # no inspect/1 of the term — the redaction discipline of the sibling arms).
      assert body["detail"] =~ "still unproxied"
      assert body["detail"] =~ "serving standalone"

      # The operator-side half: a loud, distinctly-named log line.
      assert log =~ "cloudflare_bind_not_proxied"
      assert log =~ @domain

      # FAIL CLOSED: no cf binding was persisted, so the site did not start
      # claiming it is proxied behind a record that is grey.
      reread = Registry.get_site(site.id)
      refute reread.serving_mode == "cf_proxied"
      assert is_nil(reread.cf_record_id)
      assert is_nil(reread.cf_domain)
    end

    test "the sibling shape: a non-boolean `proxied` (null in the body) is handled too" do
      # `Real` does not check the value is a boolean, so `"proxied": null` yields
      # `{:ok, %{proxied: nil}}` — an `{:ok, _}` the `boolean()` spec does not
      # describe, and the same crash one field-value away from `false`. REDS if
      # the router clause is narrowed back to the `false` literal.
      put_cloudflare_reporting_proxied(nil)
      {conn, log, site} = drive_bind()

      assert conn.status == 502,
             "expected the bounded cf-bind refusal, got #{conn.status}: #{conn.resp_body}"

      assert json_body(conn)["error"] == "cloudflare_bind_failed"
      assert log =~ "cloudflare_bind_not_proxied"
      assert log =~ "proxied=nil"

      reread = Registry.get_site(site.id)
      refute reread.serving_mode == "cf_proxied"
      assert is_nil(reread.cf_record_id)
    end

    test "THE CONTROL: proxied:true still binds — the fix did not swallow the normal path" do
      put_cloudflare_reporting_proxied(true)
      {conn, _log, site} = drive_bind()

      assert conn.status in 200..299,
             "expected the happy bind, got #{conn.status}: #{conn.resp_body}"

      reread = Registry.get_site(site.id)
      assert reread.serving_mode == "cf_proxied"
      assert reread.tls_mode == "cf_internal"
      assert reread.cf_domain == @domain
      assert reread.cf_record_id == @record_id
      assert reread.cf_zone_id == "zone_acme"
    end
  end
end
