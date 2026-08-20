defmodule BarkparkCloud.Web.RouterVercelRedactionTest do
  @moduledoc """
  SECURITY REGRESSION — the raw Vercel v13 HTTP response body must NEVER reach
  the client. The zero-paste Vercel handoff (task-4e4a53b101a97051) binds the raw
  provider body into `{:vercel_http_error, status, body}` (`Vercel.Real.request/1`
  on a non-2xx), and `Vercel.deploy_for/1`'s with-chain short-circuits it verbatim
  to the 502 detail; that body can carry account/project internals. Before the fix
  the deploy endpoint echoed it via `detail: vercel_reason(reason)` where
  `vercel_reason/1` was `reason |> inspect() |> String.slice(0, 300)` — so an
  authenticated team-admin (owner) driving POST /v1/barkparks/:id/vercel-deploy
  received the raw Vercel internals in the 502 response (a `cus_…`-shaped id would
  survive the 300-char slice intact). `vercel_reason/1` now redacts it to a
  generic, status-keyed message while the router logs the full detail server-side
  (origin/main did NOT log there — redaction alone would have blinded operators,
  so the `Logger.error` at the else arm is REQUIRED, not decorative).

  This test drives the REAL authenticated owner deploy path with the Vercel client
  swapped to `Vercel.Real` + an injected http_client stub whose response body
  carries a `cus_SENTINEL`, and asserts that sentinel NEVER appears in the client
  response while it DOES appear in the server log. It REDS on the unfixed tree
  (where `inspect(reason)` echoes the whole tuple, sentinel and all) and GREENS
  with the redaction fix. Both the status-keyed positive arm and the bare `_`
  catch-all are mutation-proven fail-closed. `async: false` because it mutates the
  node-global `:barkpark_cloud, Vercel` env (the client + http_client) for the
  test.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Vercel
  alias BarkparkCloud.Vercel.Real
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @sentinel "cus_SENTINEL"

  ## Fixtures (mirror vercel_test.exs)

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

  defp owner_token do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {token, team}
  end

  # A barkpark with a stored content bootstrap for a DEPLOYABLE template — the
  # state a templated launch leaves behind, so `deploy_for/1` reaches
  # `client().deploy_project/3` (and thus the http_client stub).
  defp bootstrapped_barkpark(team, template \\ "blog-starter") do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    env = %{
      "BARKPARK_API_URL" => "https://acme.barkpark.cloud/w/acme/p/default",
      "BARKPARK_TOKEN" => "bp_read_supersecret",
      "BARKPARK_WORKSPACE" => "acme",
      "BARKPARK_PROJECT" => "default",
      "BARKPARK_DATASET" => "production",
      "BARKPARK_WEBHOOK_SECRET" => "whsec_test"
    }

    {:ok, bp} =
      bp
      |> Ecto.Changeset.change(%{
        template: template,
        bootstrap_workspace: "acme",
        bootstrap_project: "default",
        bootstrap_dataset: "production",
        bootstrap_read_token_encrypted: Vault.encrypt("bp_read_supersecret"),
        bootstrap_env_encrypted: Vault.encrypt(Jason.encode!(env))
      })
      |> BarkparkCloud.Repo.update()

    bp
  end

  defp call(method, path, body, token) do
    conn =
      conn(method, path, if(body, do: Jason.encode!(body), else: ""))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Swap the Vercel client to the REAL builder + an injected http_client `stub`
  # and wire a platform token (so `configured?/0` is true and the endpoint does
  # NOT 503 short-circuit). Restore the prior env on exit. The stubs below drive
  # the two distinct shapes that reach the router else arm, so both the positive
  # arm AND the bare `_` catch-all are mutation-proven fail-closed.
  defp put_leaky_vercel(stub) do
    prev = Application.get_env(:barkpark_cloud, Vercel)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark_cloud, Vercel, prev),
        else: Application.delete_env(:barkpark_cloud, Vercel)
    end)

    Application.put_env(
      :barkpark_cloud,
      Vercel,
      Keyword.merge(prev || [],
        client: Real,
        token: "vt_test_token",
        http_client: stub
      )
    )
  end

  # A NON-2xx Vercel response → `{:vercel_http_error, 402, body}` (the positive
  # redactor arm). Body carries the sentinel.
  defp http_error_stub do
    fn _req ->
      {:ok,
       %{
         status: 402,
         body:
           ~s({"error":{"code":"payment_required","message":"customer #{@sentinel} has no active plan"}})
       }}
    end
  end

  # A 2xx whose body is UNDECODABLE → `%Jason.DecodeError{}` whose `.data` carries
  # the raw (sentinel-bearing) body. Reaches the bare `_` catch-all.
  defp decode_error_stub do
    fn _req -> {:ok, %{status: 200, body: ~s(not-json customer=#{@sentinel})}} end
  end

  # A transport-level failure term surfaced verbatim by Real.request/1 → a raw
  # tuple carrying the sentinel. Reaches the bare `_` catch-all.
  defp transport_error_stub do
    fn _req -> {:error, {:transport_failed, "customer #{@sentinel} unreachable"}} end
  end

  defp drive_leaky_deploy do
    {token, team} = owner_token()
    bp = bootstrapped_barkpark(team)

    with_log(fn ->
      call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
    end)
  end

  describe "POST /v1/barkparks/:id/vercel-deploy — raw Vercel body redaction" do
    test "the raw Vercel HTTP-error body (and its cus_ id) NEVER reaches the owner" do
      put_leaky_vercel(http_error_stub())
      {conn, log} = drive_leaky_deploy()

      # Non-vacuous guard FIRST: prove we actually reached the vercel_error arm of
      # the OWNER deploy path (not a 401/403/404/503/422 short-circuit that would
      # make the redaction assertion vacuously pass).
      assert conn.status == 502,
             "expected the vercel_error failure arm, got #{conn.status}: #{conn.resp_body}"

      body = json_body(conn)
      assert body["error"] == "vercel_error"

      # THE SEAL: the sentinel from the raw Vercel body must not appear ANYWHERE
      # in the client response — neither the redacted `detail` nor the full body.
      refute conn.resp_body =~ @sentinel
      refute body["detail"] =~ @sentinel

      # …and the client gets the generic, status-keyed message instead.
      assert body["detail"] == "Vercel rejected the deploy (HTTP 402)"

      # …while the server log DID carry the full raw body (operators keep the
      # diagnostic). This is the belt-log half of the fix — it must be present
      # (origin/main did NOT log here at all).
      assert log =~ "vercel_error"
      assert log =~ @sentinel
    end

    test "an undecodable 2xx body (Jason.DecodeError shape) hits the bare `_` catch-all fail-closed" do
      put_leaky_vercel(decode_error_stub())
      {conn, log} = drive_leaky_deploy()

      assert conn.status == 502,
             "expected the vercel_error failure arm, got #{conn.status}: #{conn.resp_body}"

      body = json_body(conn)
      assert body["error"] == "vercel_error"
      # The DecodeError's `.data` carries the raw body — it must not escape.
      refute conn.resp_body =~ @sentinel
      # The bare `_` catch-all fixed generic (NOT the status-keyed one).
      assert body["detail"] == "the Vercel deploy could not be completed"

      assert log =~ @sentinel
    end

    test "a raw transport-failure term hits the bare `_` catch-all fail-closed" do
      put_leaky_vercel(transport_error_stub())
      {conn, log} = drive_leaky_deploy()

      assert conn.status == 502,
             "expected the vercel_error failure arm, got #{conn.status}: #{conn.resp_body}"

      body = json_body(conn)
      assert body["error"] == "vercel_error"
      refute conn.resp_body =~ @sentinel
      assert body["detail"] == "the Vercel deploy could not be completed"

      assert log =~ @sentinel
    end
  end
end
