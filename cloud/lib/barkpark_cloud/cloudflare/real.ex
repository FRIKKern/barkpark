defmodule BarkparkCloud.Cloudflare.Real do
  @moduledoc """
  The real `BarkparkCloud.Cloudflare.Client` — it builds the ACTUAL Cloudflare
  v4 API request shapes and sends them over the injected verified-TLS transport.
  Selected in prod ONLY once a human wires an API token (HUMAN-LAST: no real
  credential exists in the repo, so this module is exercised purely through its
  pure builders in the suite — no byte ever reaches `api.cloudflare.com`).

  ## The request shapes (api.cloudflare.com/client/v4)

    * `verify_token/1` — `GET /user/tokens/verify` (Bearer the token being
      verified). The connect-time credential check: a live token answers
      `{"result":{"status":"active"}}`.
    * `upsert_dns_record/3` — `POST /zones/:zone/dns_records` to create, or
      `PUT /zones/:zone/dns_records/:id` to update when the record carries an id.
    * `delete_dns_record/3` — `DELETE /zones/:zone/dns_records/:id`. The
      orphan-cleanup verb: the router's cf-in-front bind calls this when a
      box-liveness re-check after the upsert finds the box gone.
    * `ensure_zone_proxied/3` — `PATCH /zones/:zone/dns_records/:id` with
      `{"proxied": true}` (the orange-cloud flip).
    * `create_origin_ca_cert/2` — `POST /certificates` with the hostnames + CSR.

  ## Two distinct token flows

  `verify_token/1` verifies the token PASSED to it (the credential the user just
  handed over), so it authenticates with that argument — it never reads config.
  The DNS callbacks (`upsert_dns_record/3`, `ensure_zone_proxied/3`) now THREAD a
  per-team token in as their first argument (D52): the control plane resolves the
  team's Cloudflare credential at call time and hands it down, so concurrent
  deploys for different teams never race over a shared `Application.put_env`.
  `create_origin_ca_cert/2` resolves the SEPARATE Origin CA key via the private
  `origin_ca_key/0` — never `token/0`, never a threaded API token. `present_token/1`,
  `token/0`, and `request/1` all FAIL CLOSED (`{:error, :not_configured}` /
  `{:error, :http_client_not_configured}`) and NEVER touch the wire unconfigured.

  ## Injectable HTTP client — €0 in tests, no new dep

  Same seam as `GitHub.Real` / `Vercel.Real`: `request/1` resolves a 1-arity
  client fn from config (`http_client: &m.f/1`) and calls it with the
  `%{method, url, headers, body}` map. In prod that is `Billing.HttpClient`
  (Erlang `:httpc`, verified TLS, `autoredirect: false` for SSRF safety — do NOT
  write a new transport). In dev/test there is no client, so any callback that
  would hit the wire returns `{:error, :http_client_not_configured}` — it can
  NEVER silently call Cloudflare. The pure request builders are the assertion
  seam.

  ## TWO AUTH SCHEMES ON ONE CLIENT (cf-origin-ca-wire-and-provision)

  `ensure_zone_proxied/3` emits a `:patch` request; the shared
  `Billing.HttpClient.to_httpc/1` gained its `:patch` clause in D59 so the
  proxied flip maps to a real `:httpc` PATCH.

  The Origin CA endpoint does NOT accept a Bearer API token. `POST /certificates`
  authenticates with the account's **Origin CA Key** in an
  `X-Auth-User-Service-Key` header — a SEPARATE credential from the scoped API
  token every other call here uses, minted on its own Cloudflare page and read
  from its own config slot (`:origin_ca_key`, env-fed in `runtime.exs`; never a
  literal in this repo). Sending the API token in that header, or the Origin CA
  key as a Bearer, authenticates as the wrong authority and fails.

  So `build_request/5`'s third argument is an AUTH TERM, not a token:
  `{:bearer, token}` (the DNS + verify calls) or `{:origin_ca_key, key}` (the
  certificate call). A bare binary still means Bearer, so every existing call
  site and its assertions read unchanged.
  """
  @behaviour BarkparkCloud.Cloudflare.Client

  @api_base "https://api.cloudflare.com/client/v4"
  @user_agent "barkpark-cloud"

  # Cloudflare Origin CA defaults: RSA cert, ~15y validity (their max).
  @origin_request_type "origin-rsa"
  @origin_validity_days 5475

  @impl true
  def verify_token(token) when is_binary(token) do
    with {:ok, decoded} <- request(verify_token_request(token)) do
      case decoded do
        %{"result" => %{"status" => status}} when is_binary(status) ->
          {:ok, %{status: status}}

        _ ->
          {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def upsert_dns_record(token, zone_id, record)
      when is_binary(zone_id) and is_map(record) do
    with {:ok, token} <- present_token(token),
         {:ok, decoded} <- request(upsert_dns_record_request(token, zone_id, record)) do
      case decoded do
        %{"result" => %{"id" => id, "name" => name}} when is_binary(id) ->
          {:ok, %{record_id: id, name: name}}

        _ ->
          {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def delete_dns_record(token, zone_id, record_id)
      when is_binary(zone_id) and is_binary(record_id) do
    with {:ok, token} <- present_token(token),
         {:ok, decoded} <- request(delete_dns_record_request(token, zone_id, record_id)) do
      case decoded do
        %{"result" => %{"id" => id}} when is_binary(id) -> {:ok, %{deleted: true}}
        # Cloudflare's DELETE response shape is otherwise identical to the
        # other verbs' {"result": {...}}; a missing/blank id still means the
        # call reached 2xx, so treat it as deleted rather than erroring on a
        # response-shape technicality the orphan-cleanup caller cannot act on.
        %{"result" => _} -> {:ok, %{deleted: true}}
        _ -> {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def ensure_zone_proxied(token, zone_id, record_id)
      when is_binary(zone_id) and is_binary(record_id) do
    with {:ok, token} <- present_token(token),
         {:ok, decoded} <- request(ensure_zone_proxied_request(token, zone_id, record_id)) do
      case decoded do
        %{"result" => %{"proxied" => proxied}} -> {:ok, %{proxied: proxied}}
        _ -> {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def create_origin_ca_cert(hostnames, csr) when is_list(hostnames) and is_binary(csr) do
    with {:ok, key} <- origin_ca_key(),
         {:ok, decoded} <- request(create_origin_ca_cert_request(key, hostnames, csr)) do
      case decoded do
        %{"result" => %{"id" => id, "certificate" => cert}} when is_binary(id) ->
          {:ok, %{id: id, certificate: cert}}

        _ ->
          {:error, :unexpected_response}
      end
    end
  end

  ## Pure request builders — the assertion seam (NO network) ─────────────────

  @doc "`GET /user/tokens/verify` (Bearer the token being verified). PURE."
  def verify_token_request(token) do
    build_request(:get, "/user/tokens/verify", token, "", "application/json")
  end

  @doc """
  Create-or-update a DNS record: `PUT /zones/:zone/dns_records/:id` when the
  record carries an `:id`, else `POST /zones/:zone/dns_records`. The body carries
  the record's type/name/content plus proxied/ttl (defaults: unproxied,
  automatic TTL `1`). PURE.
  """
  def upsert_dns_record_request(token, zone_id, record) do
    base = "/zones/" <> URI.encode(zone_id) <> "/dns_records"

    {method, path} =
      case record[:id] || record["id"] do
        id when is_binary(id) and id != "" -> {:put, base <> "/" <> URI.encode(id)}
        _ -> {:post, base}
      end

    body =
      Jason.encode!(%{
        "type" => record[:type] || record["type"],
        "name" => record[:name] || record["name"],
        "content" => record[:content] || record["content"],
        "proxied" => record[:proxied] || record["proxied"] || false,
        "ttl" => record[:ttl] || record["ttl"] || 1
      })

    build_request(method, path, token, body, "application/json")
  end

  @doc """
  Delete a DNS record: `DELETE /zones/:zone/dns_records/:id`. PURE. The
  orphan-cleanup verb's wire shape — no body, same Bearer auth as every other
  callback here.
  """
  def delete_dns_record_request(token, zone_id, record_id) do
    build_request(
      :delete,
      "/zones/" <> URI.encode(zone_id) <> "/dns_records/" <> URI.encode(record_id),
      token,
      "",
      "application/json"
    )
  end

  @doc """
  Flip a DNS record to proxied: `PATCH /zones/:zone/dns_records/:id` with
  `{"proxied": true}`. PURE. (The transport gains its `:patch` clause in the
  live-wiring slice — see the moduledoc NOTE.)
  """
  def ensure_zone_proxied_request(token, zone_id, record_id) do
    build_request(
      :patch,
      "/zones/" <> URI.encode(zone_id) <> "/dns_records/" <> URI.encode(record_id),
      token,
      Jason.encode!(%{"proxied" => true}),
      "application/json"
    )
  end

  @doc """
  Mint an Origin CA cert: `POST /certificates` with the `hostnames`, the PEM
  `csr`, and Cloudflare's RSA/max-validity defaults. PURE.

  The ONLY call here that is not Bearer-authenticated: `origin_ca_key` rides an
  `X-Auth-User-Service-Key` header (see the moduledoc). Passing the scoped API
  token to this builder would produce a request Cloudflare rejects.
  """
  def create_origin_ca_cert_request(origin_ca_key, hostnames, csr) do
    body =
      Jason.encode!(%{
        "hostnames" => hostnames,
        "request_type" => @origin_request_type,
        "requested_validity" => @origin_validity_days,
        "csr" => csr
      })

    build_request(
      :post,
      "/certificates",
      {:origin_ca_key, origin_ca_key},
      body,
      "application/json"
    )
  end

  @doc """
  Assemble one request map for the transport seam: method, `#{@api_base}<path>`,
  the auth + UA + content-type headers, and `body`. PURE.

  `auth` is `{:bearer, token}` for the scoped API token (verify + all three DNS
  calls) or `{:origin_ca_key, key}` for the Origin CA credential (the
  certificate call ONLY). A bare binary is Bearer, so the older 5-arity call
  shape keeps working unchanged.
  """
  def build_request(method, path, auth, body, content_type) do
    %{
      method: method,
      url: @api_base <> path,
      headers:
        auth_headers(auth) ++
          [
            {"User-Agent", @user_agent},
            {"Content-Type", content_type}
          ],
      body: body
    }
  end

  # The per-call header scheme. Two credentials, two headers, no default that
  # could quietly send the wrong one: an unrecognised auth term has no clause.
  defp auth_headers({:bearer, token}) when is_binary(token),
    do: [{"Authorization", "Bearer " <> token}]

  defp auth_headers({:origin_ca_key, key}) when is_binary(key),
    do: [{"X-Auth-User-Service-Key", key}]

  defp auth_headers(token) when is_binary(token), do: auth_headers({:bearer, token})

  ## Internals ───────────────────────────────────────────────────────────────

  # The Origin CA credential — a DIFFERENT secret from `:token` above, in its own
  # config slot, fed from CLOUDFLARE_ORIGIN_CA_KEY in runtime.exs. Fails closed
  # exactly like `token/0`: unset → `:not_configured` BEFORE any request is
  # built, so `create_origin_ca_cert/2` can never fall back to the API token.
  defp origin_ca_key do
    present_token(config()[:origin_ca_key])
  end

  # Fail-closed guard for a THREADED token (D52): a blank/nil token argument is
  # `:not_configured` BEFORE any request is built, so a caller that failed to
  # resolve a per-team credential never reaches the wire.
  defp present_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp present_token(_), do: {:error, :not_configured}

  # Resolve the injected HTTP client and perform the request. NEVER reaches the
  # wire in tests (no client configured → fail closed). On a 2xx, decode the JSON
  # body; otherwise surface the status + body.
  defp request(req) do
    case http_client() do
      fun when is_function(fun, 1) ->
        with {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(req),
             {:ok, decoded} <- decode_body(body) do
          {:ok, decoded}
        else
          {:ok, %{status: status, body: body}} -> {:error, {:cloudflare_http_error, status, body}}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_cloudflare_response, other}}
        end

      _ ->
        {:error, :http_client_not_configured}
    end
  end

  defp decode_body(""), do: {:ok, %{}}
  defp decode_body(body), do: Jason.decode(body)

  defp http_client, do: config()[:http_client]

  # hg-w1-async-seam-process-scope-followup: reads through
  # Cloudflare.resolved_config/0 rather than Application.get_env directly, so
  # this module sees the SAME process-scoped override a test installs via
  # Cloudflare.put_process_config/1 — one config choke point for both readers.
  defp config, do: BarkparkCloud.Cloudflare.resolved_config()
end
