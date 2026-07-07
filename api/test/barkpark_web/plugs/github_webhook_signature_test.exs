defmodule BarkparkWeb.Plugs.GithubWebhookSignatureTest do
  @moduledoc """
  The fail-closed HMAC gate for the inbound GitHub webhook. A valid
  `X-Hub-Signature-256` over the cached raw body passes; a tampered body, a
  missing raw body, a missing header, and a dark plugin (no secret) all 401-halt
  with the canonical envelope. Uses DataCase because Settings.get_credentials/0
  reads the encrypted plugin_settings fallback row.
  """
  use Barkpark.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkWeb.Plugs.GithubWebhookSignature
  alias Barkpark.Plugins.Github.{Settings, Signature}

  @secret "test-github-webhook-secret-123"
  @body ~s({"action":"opened","issue":{"number":42},"sender":{"type":"User"}})
  @config_key Barkpark.Plugins.Github

  setup do
    prior = Application.get_env(:barkpark, @config_key)
    # TTL 0 forces the memoized secret reader to re-resolve on every call so a
    # per-test config change (incl. the dark-plugin case) is never masked by a
    # stale cache entry; also clear the persistent_term between cases.
    Application.put_env(:barkpark, @config_key, webhook_secret: @secret, webhook_secret_ttl_ms: 0)
    Settings.reset_webhook_secret_cache()

    on_exit(fn ->
      Settings.reset_webhook_secret_cache()

      if prior,
        do: Application.put_env(:barkpark, @config_key, prior),
        else: Application.delete_env(:barkpark, @config_key)
    end)

    :ok
  end

  defp call(conn), do: GithubWebhookSignature.call(conn, GithubWebhookSignature.init([]))

  # A conn carrying the cached raw body + a header that signs `sig_over` (defaults
  # to the real body → a valid delivery).
  defp signed_conn(raw_body, sig_over \\ nil) do
    header = Signature.sign(sig_over || raw_body, @secret)

    conn(:post, "/v1/plugins/github/webhook", raw_body)
    |> assign(:raw_body, raw_body)
    |> put_req_header("x-hub-signature-256", header)
  end

  defp assert_401(conn) do
    assert conn.halted
    assert conn.status == 401
    assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(conn.resp_body)
  end

  test "a valid signature over the raw body passes through untouched" do
    conn = call(signed_conn(@body))
    refute conn.halted
    assert conn.status == nil
  end

  test "a tampered body (signature over different bytes) → 401 halt" do
    # Header signs @body but the cached raw_body was altered in flight.
    conn =
      conn(:post, "/v1/plugins/github/webhook", @body)
      |> assign(:raw_body, @body <> "tampered")
      |> put_req_header("x-hub-signature-256", Signature.sign(@body, @secret))
      |> call()

    assert_401(conn)
  end

  test "a wrong-secret signature → 401 halt" do
    conn =
      @body
      |> signed_conn()
      |> put_req_header("x-hub-signature-256", Signature.sign(@body, "some-other-secret"))
      |> call()

    assert_401(conn)
  end

  test "missing raw_body (never teed) → 401 halt" do
    conn =
      conn(:post, "/v1/plugins/github/webhook", @body)
      |> put_req_header("x-hub-signature-256", Signature.sign(@body, @secret))
      |> call()

    assert_401(conn)
  end

  test "missing signature header → 401 halt" do
    conn =
      conn(:post, "/v1/plugins/github/webhook", @body)
      |> assign(:raw_body, @body)
      |> call()

    assert_401(conn)
  end

  test "dark plugin (no webhook secret configured) → 401 halt" do
    Application.delete_env(:barkpark, @config_key)
    conn = call(signed_conn(@body))
    assert_401(conn)
  end
end
