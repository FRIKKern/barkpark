defmodule BarkparkWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Path-scoped raw-body cache for the GitHub webhook.

  GitHub signs each webhook delivery with an HMAC-SHA256 over the RAW request
  bytes (`X-Hub-Signature-256`). To verify that signature we need the exact bytes
  GitHub sent — but `Plug.Parsers` consumes the body stream while decoding JSON,
  so by the time a plug or controller runs the raw body is gone. The standard
  Phoenix idiom is a custom `body_reader` that tees the stream into
  `conn.assigns[:raw_body]` as `Plug.Parsers` reads it.

  We deliberately scope the tee to the GitHub webhook path ONLY. Buffering the
  raw body of EVERY request would double memory for the whole API surface (the
  JSON parser accepts bodies up to 100 MB — see `BarkparkWeb.Endpoint`); a single
  low-traffic server-to-server callback is the only place that needs it. Every
  other path reads straight through `Plug.Conn.read_body/2` with no assign and no
  extra allocation.

  Wired in `BarkparkWeb.Endpoint` via
  `Plug.Parsers.init(body_reader: {#{inspect(__MODULE__)}, :read_body, []})`;
  `BarkparkWeb.Plugs.GithubWebhookSignature` reads the cached bytes.
  """

  # The `github` plugin's webhook route (see `router.ex` `:github_webhook`
  # bucket + `Barkpark.Plugins.Github.register_routes/1`). Only this path caches.
  @webhook_path "/v1/plugins/github/webhook"

  # Fallback cap (BYTES) if `:github_webhook_body_cap` is unset. GitHub documents
  # a hard 25 MB payload ceiling, so 26 MB rejects zero legitimate deliveries.
  @default_webhook_body_cap 26_000_000

  @doc """
  Drop-in replacement for `Plug.Conn.read_body/2` used as a `Plug.Parsers`
  `:body_reader`.

  On the GitHub webhook path, appends each read chunk to
  `conn.assigns[:raw_body]` (accumulating across a chunked body) before handing
  the chunk back to the parser. On every other path it is a transparent
  pass-through — no assign is set, so `Map.has_key?(conn.assigns, :raw_body)`
  stays false and there is zero buffering cost.

  The webhook path also OVERRIDES `:length` down to `github_webhook_body_cap/0`
  (default 26 MB) so the endpoint's 100 MB global bound never applies to this one
  unauthenticated, pre-signature route. A body over the cap makes
  `Plug.Conn.read_body/2` return `{:more, chunk, conn}`, which we return VERBATIM
  — the ONLY read result that reaches the canonical 413 `payload_too_large`
  envelope (`Plug.Parsers.JSON` maps `{:more, ...}` → `{:error, :too_large}` →
  `Plug.Parsers.RequestTooLargeError` → `Endpoint.parse_error_json`). We must
  NEVER return a 2-tuple `{:error, :too_large}`: though well-typed per the
  `read_body/2` @spec, `Plug.Parsers` raises `Plug.BadRequestError` on it — a
  non-enveloped 400 the endpoint does not rescue. The cap BOUNDS the pre-signature
  buffering (up to the cap) — it does not prevent it, which is acceptable and
  documented on `config :barkpark, :github_webhook_body_cap`.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    # `conn.request_path` is set by the adapter before any plug runs and is not
    # mutated by read_body, so the incoming conn's path is the delivery path.
    if conn.request_path == @webhook_path do
      # Cap the per-read `:length` so an over-cap body short-circuits to {:more}
      # (→ enveloped 413) instead of buffering up to the endpoint's 100 MB bound.
      opts = Keyword.put(opts, :length, github_webhook_body_cap())

      case Plug.Conn.read_body(conn, opts) do
        # {:more, ...} returned VERBATIM — see @doc: the ONLY path to the 413 seam.
        {:ok, chunk, conn} -> {:ok, chunk, cache(conn, chunk)}
        {:more, chunk, conn} -> {:more, chunk, cache(conn, chunk)}
        other -> other
      end
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  @doc """
  The inbound GitHub webhook body cap in bytes (`config :barkpark,
  :github_webhook_body_cap`, default #{@default_webhook_body_cap}). Public so
  tests can assert the wired value.
  """
  @spec github_webhook_body_cap() :: pos_integer()
  def github_webhook_body_cap do
    Application.get_env(:barkpark, :github_webhook_body_cap, @default_webhook_body_cap)
  end

  defp cache(conn, chunk) do
    existing = conn.assigns[:raw_body] || ""
    Plug.Conn.assign(conn, :raw_body, existing <> chunk)
  end
end
