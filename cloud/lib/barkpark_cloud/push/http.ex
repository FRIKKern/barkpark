defmodule BarkparkCloud.Push.HTTP do
  @moduledoc """
  The HTTP BOUNDARY of the push relay — the outermost thing a real APNs/FCM
  adapter touches, and the ONLY thing the adapter tests fake.

  This is a deliberate second seam, one level below `Push.Adapter`:

      Push.deliver/3 → Push.Adapter (apns | fcm | not_configured)  ← product seam
                          → Push.HTTP  (mint | fake)               ← transport seam

  Faking `Push.Adapter` proves the WORKER's verdict handling (that is what
  `PushFakeAdapter` is for and it stays). Faking `Push.HTTP` proves the
  ADAPTERS themselves — the JWT they sign, the exact URL/headers/JSON they put
  on the wire, and how they map every documented platform status onto the
  behaviour's contract — without a credential, a network, or a device. An
  adapter test that faked `Push.Adapter` would be testing its own stub.

  Configured via

      config :barkpark_cloud, :push_http_client, <module>

  Default `BarkparkCloud.Push.HTTP.Mint`. config/test.exs wires
  `BarkparkCloud.PushFakeHttpClient`.

  ## Why not `:httpc` (which the rest of cloud/ uses)

  The APNs provider API is **HTTP/2 only** — there is no HTTP/1.1 endpoint, so
  `:httpc` (OTP's HTTP/1.1 client, the transport behind `Billing.HttpClient`)
  cannot reach it at all. Mint speaks both, which is why the push relay carries
  the one new dependency in `cloud/mix.exs`.
  """

  @typedoc """
  One outbound request.

    * `:method` — `:post` | `:get`
    * `:url` — absolute http(s) URL
    * `:headers` — `[{name, value}]`, lowercase names (HTTP/2 requires it)
    * `:body` — request body, `""` for none
    * `:protocols` — `[:http2]` pins HTTP/2 (APNs); omit for the default
      `[:http1, :http2]` negotiation (FCM, Google OAuth)
    * `:timeout_ms` — total wall-clock budget for connect+send+receive
  """
  @type request :: %{
          required(:method) => :post | :get,
          required(:url) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => binary(),
          optional(:protocols) => [:http1 | :http2],
          optional(:timeout_ms) => pos_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc """
  Issue `request`. Returns `{:ok, response}` for ANY completed HTTP exchange
  (including 4xx/5xx — status classification belongs to the adapter, not the
  transport), or `{:error, reason}` when no response was obtained at all
  (DNS/TLS/connect/timeout).
  """
  @callback request(request()) :: {:ok, response()} | {:error, term()}

  @doc "The configured transport module."
  @spec client() :: module()
  def client do
    Application.get_env(:barkpark_cloud, :push_http_client, BarkparkCloud.Push.HTTP.Mint)
  end

  @doc "Issue `request` through the configured transport."
  @spec request(request()) :: {:ok, response()} | {:error, term()}
  def request(request) when is_map(request), do: client().request(request)
end
