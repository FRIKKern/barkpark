defmodule BarkparkCloud.Web.RouterCloudflareRedactionTest do
  @moduledoc """
  SECURITY REGRESSION — the raw Cloudflare v4 HTTP response body must NEVER reach
  the client. The cf-in-front deploy binding (D57) threads the raw provider body
  into `{:cloudflare_http_error, status, body}` (Cloudflare.Real.request/1 on a
  non-2xx); that body can carry account/zone internals (`cf_zone_id`, record ids,
  the connected account's metadata). Before the fix the deploy binding echoed it
  verbatim via `detail` interpolating `inspect(reason)`, so an authenticated OWNER
  driving POST /v1/sites/:id/deploy with `via=cloudflare` received the raw
  Cloudflare internals in the 502 response. `cloudflare_reason/1` now redacts it
  to a generic, status-keyed message while the router logs the full detail
  server-side.

  This test drives the REAL authenticated owner deploy path with the Cloudflare
  client swapped to `Cloudflare.Real` + an injected http_client stub whose
  response body carries a `cf_zone_SENSITIVE_SENTINEL`, and asserts that sentinel
  NEVER appears in the client response while it DOES appear in the server log. It
  REDS on the unfixed tree (where `inspect(reason)` echoes the whole tuple,
  sentinel and all) and GREENS with the redaction fix. `async: true`
  (hg-w1-async-seam-process-scope-followup): the Cloudflare client + http_client
  swap is installed in THIS TEST'S process dictionary via
  `Cloudflare.put_process_config/1` rather than mutating node-global
  Application env, so it is invisible to every other concurrently-running
  test — see Cloudflare's moduledoc "Process-scoped config override".
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
  @sentinel "cf_zone_SENSITIVE_SENTINEL"

  ## Fixtures (mirror site_cf_deploy_test.exs)

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

  # Swap the Cloudflare client to the REAL builder + an injected http_client
  # `stub` so the first DNS write fails with a sentinel-bearing error, scoped
  # to THIS test's process only (no on_exit needed — see Cloudflare's
  # moduledoc "Process-scoped config override"). The three stubs below drive
  # the three distinct shapes that reach the router else arm, so both the
  # positive arm AND the bare `_` catch-all are mutation-proven fail-closed.
  defp put_leaky_cloudflare(stub) do
    Cloudflare.put_process_config(
      Keyword.merge(Cloudflare.resolved_config(),
        client: BarkparkCloud.Cloudflare.Real,
        http_client: stub
      )
    )
  end

  # A NON-2xx Cloudflare response → `{:cloudflare_http_error, 403, body}` (the
  # positive redactor arm). Body carries the sentinel.
  defp http_error_stub do
    fn _req ->
      {:ok,
       %{
         status: 403,
         body:
           ~s({"success":false,"errors":[{"code":9109,"message":"zone #{@sentinel} not authorized for this token"}]})
       }}
    end
  end

  # A 2xx whose body is UNDECODABLE → `%Jason.DecodeError{}` whose `.data` carries
  # the raw (sentinel-bearing) body. Reaches the bare `_` catch-all.
  defp decode_error_stub do
    fn _req -> {:ok, %{status: 200, body: ~s(not-json zone=#{@sentinel})}} end
  end

  # A transport-level failure term surfaced verbatim by Real.request/1 → a raw
  # tuple carrying the sentinel. Reaches the bare `_` catch-all.
  defp transport_error_stub do
    fn _req -> {:error, {:transport_failed, "zone #{@sentinel} unreachable"}} end
  end

  defp drive_leaky_deploy do
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

    with_log(fn ->
      call(
        :post,
        "/v1/sites/#{site.id}/deploy",
        %{via: "cloudflare", domain: "blog.example.com"},
        token
      )
    end)
  end

  describe "POST /v1/sites/:id/deploy via=cloudflare — raw Cloudflare body redaction" do
    test "the raw Cloudflare HTTP-error body (and its zone id) NEVER reaches the owner" do
      put_leaky_cloudflare(http_error_stub())
      {conn, log} = drive_leaky_deploy()

      # Non-vacuous guard FIRST: prove we actually reached the cloudflare-bind
      # error arm of the OWNER deploy path (not a 401/403/409/422 short-circuit
      # that would make the redaction assertion vacuously pass).
      assert conn.status == 502,
             "expected the cf-bind failure arm, got #{conn.status}: #{conn.resp_body}"

      body = json_body(conn)
      assert body["error"] == "cloudflare_bind_failed"

      # THE SEAL: the sentinel from the raw Cloudflare body must not appear
      # ANYWHERE in the client response — neither the redacted `detail` nor the
      # full body.
      refute conn.resp_body =~ @sentinel
      refute body["detail"] =~ @sentinel

      # …and the client gets the generic, status-keyed message instead.
      assert body["detail"] == "Cloudflare rejected the DNS/proxy write (HTTP 403)"

      # …while the server log DID carry the full raw body (operators keep the
      # diagnostic). This is the belt-log half of the fix — it must be present.
      assert log =~ "cloudflare_bind_failed"
      assert log =~ @sentinel
    end

    test "an undecodable 2xx body (Jason.DecodeError shape) hits the bare `_` catch-all fail-closed" do
      put_leaky_cloudflare(decode_error_stub())
      {conn, log} = drive_leaky_deploy()

      assert conn.status == 502,
             "expected the cf-bind failure arm, got #{conn.status}: #{conn.resp_body}"

      body = json_body(conn)
      assert body["error"] == "cloudflare_bind_failed"
      # The DecodeError's `.data` carries the raw body — it must not escape.
      refute conn.resp_body =~ @sentinel
      # The bare `_` catch-all fixed generic (NOT the status-keyed one).
      assert body["detail"] ==
               "Cloudflare rejected the DNS/proxy write — the box is still serving standalone"

      assert log =~ @sentinel
    end

    test "a raw transport-failure term hits the bare `_` catch-all fail-closed" do
      put_leaky_cloudflare(transport_error_stub())
      {conn, log} = drive_leaky_deploy()

      assert conn.status == 502,
             "expected the cf-bind failure arm, got #{conn.status}: #{conn.resp_body}"

      body = json_body(conn)
      assert body["error"] == "cloudflare_bind_failed"
      refute conn.resp_body =~ @sentinel

      assert body["detail"] ==
               "Cloudflare rejected the DNS/proxy write — the box is still serving standalone"

      assert log =~ @sentinel
    end
  end
end
