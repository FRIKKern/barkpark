defmodule BarkparkCloud.Billing.HttpClient do
  @moduledoc """
  The real HTTP transport for `BarkparkCloud.Billing.StripeGateway` — the
  cloud-17 wiring that turns the injectable-client SEAM into an actual call to
  `api.stripe.com`.

  ## No new dependency — Erlang's built-in `:httpc`

  The control plane has NO HTTP library in the tree (only Jason). Rather than
  pull one in, this uses OTP's bundled `:inets`/`:httpc` client. `request/1`
  takes the gateway's request map verbatim —

      %{
        method:  :get | :post,
        url:     "https://api.stripe.com/v1/...",
        headers: [{"Authorization", "Bearer sk_…"}, {"Content-Type", "…"}],
        body:    "a=b&c=d"   # URL-encoded form
      }

  — and returns `{:ok, %{status: status, body: body}}` (binary body) on a
  completed exchange (any status, the gateway decides 2xx-vs-not) or
  `{:error, {:http_client, reason}}` on a transport failure.

  ## TLS — verified, not blind

  This talks to Stripe over HTTPS, so the certificate is VERIFIED:
  `verify: :verify_peer` against the OS trust store (`:public_key.cacerts_get/0`,
  OTP 25+) with hostname checking (`pkix_verify_hostname_match_fun(:https)`).
  Without this `:httpc` would happily accept any cert — a MITM seam. Timeouts
  are bounded so a hung Stripe never wedges a request.

  ## Pure / impure split

  `to_httpc/1` is a PURE mapping from the request map to the exact `:httpc`
  argument tuple (charlist url/headers, content-type pulled out for POST). It is
  unit-tested without the network. `request/1` is the thin impure shell that
  feeds that tuple to `:httpc.request/4` and normalises the result.
  """

  # Default form content-type when the request map carries no explicit one.
  @default_content_type "application/x-www-form-urlencoded"

  # Bounded so a hung Stripe can't wedge a request indefinitely.
  @timeout 15_000
  @connect_timeout 10_000

  @type request_map :: %{
          method: :get | :post | :put | :delete,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  @doc """
  Perform the gateway's request via `:httpc` and normalise the result.

  Returns `{:ok, %{status: status, body: binary}}` on a completed HTTP exchange
  (the gateway maps 2xx → success) or `{:error, {:http_client, reason}}` on a
  transport-level failure.
  """
  @spec request(request_map()) ::
          {:ok, %{status: non_neg_integer(), body: binary()}} | {:error, term()}
  def request(%{method: method} = req) do
    {request_arg, http_opts, opts} = to_httpc(req)

    case :httpc.request(method, request_arg, http_opts, opts) do
      {:ok, {{_http_version, status, _reason_phrase}, _resp_headers, resp_body}} ->
        {:ok, %{status: status, body: to_string(resp_body)}}

      {:error, reason} ->
        {:error, {:http_client, reason}}
    end
  end

  @doc """
  PURE mapping from the gateway request map to the `:httpc.request/4` argument
  tuple `{request_arg, http_opts, opts}` — no network, unit-testable.

  For `:post`, `:httpc` takes the content-type and body as SEPARATE arguments,
  so the `Content-Type` header is pulled out of the header list and the
  remaining headers are passed alongside:

      {:post, {url_charlist, headers_without_ct, content_type_charlist, body}, http_opts, opts}

  For `:get`, the 2-tuple `{url_charlist, headers_charlist}` form is used.

  `http_opts` carries the verified-TLS `ssl` options + timeouts; `opts` requests
  a binary response body.
  """
  @spec to_httpc(request_map()) :: {tuple(), keyword(), keyword()}
  def to_httpc(%{method: :post, url: url, headers: headers, body: body}) do
    {content_type, other_headers} = pop_content_type(headers)

    request_arg =
      {to_charlist(url), to_header_charlists(other_headers), to_charlist(content_type),
       to_string(body)}

    {request_arg, http_opts(), opts()}
  end

  def to_httpc(%{method: :get, url: url, headers: headers}) do
    request_arg = {to_charlist(url), to_header_charlists(headers)}
    {request_arg, http_opts(), opts()}
  end

  # PUT — the instance-API proxy's `webhook.update` (and the dwb-6
  # `wire_site_url` webhook re-point). `:httpc` accepts the same 4-tuple form as
  # POST (content-type + body pulled out), so the JSON body rides alongside the
  # remaining headers.
  def to_httpc(%{method: :put, url: url, headers: headers, body: body}) do
    {content_type, other_headers} = pop_content_type(headers)

    request_arg =
      {to_charlist(url), to_header_charlists(other_headers), to_charlist(content_type),
       to_string(body)}

    {request_arg, http_opts(), opts()}
  end

  # DELETE — Stripe's immediate `cancel_subscription` (DELETE /v1/subscriptions/:id).
  # `:httpc` accepts the same 4-tuple form as POST (content-type + body), so the
  # body is the form-encoded params (typically empty) and the Content-Type rides
  # alongside the remaining headers.
  def to_httpc(%{method: :delete, url: url, headers: headers, body: body}) do
    {content_type, other_headers} = pop_content_type(headers)

    request_arg =
      {to_charlist(url), to_header_charlists(other_headers), to_charlist(content_type),
       to_string(body)}

    {request_arg, http_opts(), opts()}
  end

  # ── Internals ──

  # Pull the (case-insensitive) Content-Type header out of the list, returning
  # {content_type_string, remaining_headers}. Defaults when absent.
  defp pop_content_type(headers) do
    {ct_pairs, rest} =
      Enum.split_with(headers, fn {k, _v} -> String.downcase(k) == "content-type" end)

    content_type =
      case ct_pairs do
        [{_k, v} | _] -> v
        [] -> @default_content_type
      end

    {content_type, rest}
  end

  defp to_header_charlists(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  # Verified TLS against the OS trust store + bounded timeouts. verify_peer with
  # cacerts + the https hostname-match fun is what makes this safe to send a
  # live secret key over.
  #
  # `autoredirect: false` is LOAD-BEARING for SSRF safety, not a nicety: Erlang
  # :httpc defaults autoredirect to TRUE, so a saved webhook that passes the
  # save-time SafeUrl check could 302 → http://169.254.169.254 (or 127.0.0.1) and
  # :httpc would silently FOLLOW it, unvalidated (blind redirect-SSRF). Disabling
  # it means a 3xx is RETURNED to the caller, not followed, so the guard can't be
  # bypassed by a redirect. Do not remove without re-validating each Location.
  defp http_opts do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      autoredirect: false,
      timeout: @timeout,
      connect_timeout: @connect_timeout
    ]
  end

  defp opts, do: [body_format: :binary]
end
