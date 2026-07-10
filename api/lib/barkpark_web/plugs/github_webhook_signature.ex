defmodule BarkparkWeb.Plugs.GithubWebhookSignature do
  @moduledoc """
  Fail-closed HMAC gate for the inbound GitHub webhook — the ONLY auth on the
  `:github_webhook` pipeline.

  This is a server-to-server GitHub App callback, not a browser origin, so there
  is no api-token, no session cookie, and no CORS. Authenticity rests entirely on
  the `X-Hub-Signature-256` header: GitHub HMAC-SHA256s the RAW request body with
  the App's configured webhook secret, and only GitHub (and us) know that secret.

  The plug reads:

    * `conn.assigns[:raw_body]` — the exact bytes GitHub signed, teed in by
      `BarkparkWeb.Plugs.CacheBodyReader` at the endpoint's parse step;
    * the `x-hub-signature-256` request header;
    * the `:webhook_secret` from
      `Barkpark.Plugins.Github.Settings.webhook_secret_cached/0` — a short-TTL
      memoized reader, so a burst of unauthenticated probes carrying a bogus
      signature can no longer force a DB read + audit row on every request
      before the HMAC is checked (it touches the DB at most once per TTL).

  It delegates the comparison to the pure, constant-time
  `Barkpark.Plugins.Github.Signature.verify/3`. On `:ok` the request passes
  through untouched. On ANYTHING else — a tampered/missing/malformed signature, a
  missing raw body (a non-webhook request that never got teed), a blank secret, or
  a dark plugin (no secret provisioned) — it responds `401` with the canonical
  `{"error": {"code": "unauthorized", "message": ...}}` envelope and halts.

  FAIL CLOSED: the gate never accepts when it cannot positively verify. Every
  unhappy path funnels through the same `reject/1`.
  """
  import Plug.Conn

  alias Barkpark.Plugins.Github.{Settings, Signature}

  # GitHub sends `X-Hub-Signature-256`; Plug lower-cases header names.
  @header "x-hub-signature-256"

  def init(opts), do: opts

  def call(conn, _opts) do
    with raw_body when is_binary(raw_body) <- conn.assigns[:raw_body],
         [header | _] <- get_req_header(conn, @header),
         secret when is_binary(secret) <- Settings.webhook_secret_cached(),
         :ok <- Signature.verify(raw_body, header, secret) do
      conn
    else
      _ -> reject(conn)
    end
  end

  # One shared emitter → the 401 carries request_id (+ hint) for log correlation.
  defp reject(conn) do
    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      :unauthorized,
      "unauthorized",
      "invalid webhook signature"
    )
  end
end
