defmodule BarkparkCloud.OAuth do
  @moduledoc """
  The consumer OAuth/SSO context — "Continue with GitHub / Google" for the Cloud
  account. The OAuth twin of `BarkparkCloud.Billing`: a behaviour
  (`BarkparkCloud.OAuth.Provider`) with per-IdP strategy modules
  (`OAuth.Github`, `OAuth.Google`), an INJECTED HTTP transport (the same verified
  -TLS `:httpc` client billing uses, `Billing.HttpClient.request/1`), and a
  stub-in-test discipline so callback tests are hermetic and make zero network
  calls.

  ## Cookieless by necessity

  `cloud/` is NOT Phoenix and has NO session cookie — it is a token-bearer JSON
  API + a vanilla SPA storing `{token, team_id}` in `localStorage`. So both the
  CSRF `state` and the final token handoff are cookieless:

    * `state` is a SELF-VERIFYING signed token — `HMAC-SHA256(secret,
      provider|nonce|exp)` — with no DB row and no cookie, mirroring the Stripe
      webhook HMAC idiom (`StripeGateway.verify_signature`). `verify_state/2`
      constant-time-compares the mac, checks `exp > now`, and binds the state to
      the callback's `:provider` path param.
    * the token handoff (router's concern) rides the URL FRAGMENT, never the
      query, so it stays out of access logs / `Referer`.

  Honest limit: without a browser-bound cookie the signed state guards against
  forged provider responses (an attacker can't mint a valid mac) but not classic
  login-CSRF where a victim finishes an attacker-initiated flow. For a sign-IN
  (the only v1 action) the residual risk is low — the session lands in whoever's
  browser completed the flow. Binding state to a per-browser cookie is deferred
  with the rest of the cookie story (and is required before a `link-to-authed-
  account` action ships).

  ## Config (read at CALL time, so runtime.exs wins)

      config :barkpark_cloud, BarkparkCloud.OAuth,
        base_url: "https://barkpark.cloud",
        state_secret: <hmac-key>,
        http_client: &BarkparkCloud.Billing.HttpClient.request/1,
        providers: %{
          "github" => %{module: OAuth.Github, client_id: ..., client_secret: ...},
          "google" => %{module: OAuth.Google, client_id: ..., client_secret: ...}
        }

  A provider is ENABLED only when both its `client_id` and `client_secret` are
  non-empty — the analog of Coolify's `OauthSetting.couldBeEnabled` completeness
  gate. `enabled_providers/0` drives both the route allow-list (a disabled or
  unknown provider is a 404) and the SPA buttons. The `redirect_uri` is DERIVED
  from `base_url`, never stored: `<base_url>/v1/auth/oauth/<provider>/callback`.

  ## Single-use state (replay defence)

  A signed HMAC state is tamper-proof and TTL-bound, but a signed token is
  REPLAYABLE within its TTL — an intercepted callback URL could be driven twice.
  So the state is also SINGLE USE: `mint_state/1` records the state's random
  nonce in the `oauth_states` ledger, and `verify_state/2` CONSUMES it (an atomic
  DELETE). A second callback with the same state deletes zero rows and is
  rejected. `expires_at` is a hard TTL backstop that reaps a nonce the browser
  never redeems.
  """
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.OAuth.State
  alias BarkparkCloud.Repo

  # The signed-state lifetime: a browser must complete the round-trip within this
  # window or verify_state rejects it (a stale `state` is as good as forged).
  @state_ttl_seconds 600

  @typedoc "A verified identity ready for `Accounts.get_or_create_user_from_oauth/1`."
  @type identity :: %{provider: String.t(), provider_uid: String.t(), email: String.t() | nil}

  ## Provider registry / gating

  @doc """
  The provider names ENABLED in the current config — those with a non-empty
  `client_id` AND `client_secret`. Drives the route allow-list and the SPA's
  visible buttons. Order follows the config map's keys, sorted for determinism.
  """
  @spec enabled_providers() :: [String.t()]
  def enabled_providers do
    providers()
    |> Enum.filter(fn {_name, cfg} -> configured?(cfg) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "Is `provider` a known, fully-configured (enabled) provider?"
  @spec enabled?(String.t()) :: boolean()
  def enabled?(provider) when is_binary(provider), do: provider in enabled_providers()
  def enabled?(_), do: false

  ## Authorize

  @doc """
  Build the IdP authorization-code URL for `provider` and a fresh signed `state`.

  Returns `{:ok, url, state}` for an enabled provider (the router 302s the
  browser to `url`), or `{:error, :provider_not_enabled}` otherwise. The `state`
  is also embedded in `url`'s query; it is returned separately only so a caller
  can assert on it.
  """
  @spec authorize_url(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :provider_not_enabled}
  def authorize_url(provider) when is_binary(provider) do
    case resolve(provider) do
      {:ok, module, config} ->
        state = mint_state(provider)
        url = module.authorize_url(config, state, redirect_uri(provider))
        {:ok, url, state}

      :error ->
        {:error, :provider_not_enabled}
    end
  end

  ## Identity exchange

  @doc """
  Exchange an authorization `code` for the user's verified identity at `provider`.

  Runs the strategy's token request, then its userinfo request, then (for a
  strategy that needs a second email call, e.g. GitHub) merges the decoded email
  list before `parse_identity/1`. All HTTP goes through the injected
  `http_client` — there is none in dev/test, so this fails closed
  (`:http_client_not_configured`) and the stub is wired only in test config.

  Returns `{:ok, %{provider, provider_uid, email}}` or `{:error, term}`. The
  router collapses every error to a single generic redirect — it never leaks
  which step failed.
  """
  @spec fetch_identity(String.t(), String.t()) :: {:ok, identity()} | {:error, term()}
  def fetch_identity(provider, code) when is_binary(provider) and is_binary(code) do
    with {:ok, module, config} <- resolve_ok(provider),
         {:ok, access_token} <- exchange_code(module, config, provider, code),
         {:ok, userinfo} <- get_userinfo(module, access_token),
         {:ok, identity} <- parse_identity(module, access_token, userinfo) do
      {:ok, %{provider: provider, provider_uid: identity.uid, email: identity.email}}
    end
  end

  ## Signed state (stateless CSRF) — mint + verify

  @doc """
  Mint a signed `state` for `provider`: `base64url(payload) <> "." <> hmac_hex`,
  where `payload = {p: provider, n: nonce, exp: now + ttl}` and the mac is
  `HMAC-SHA256(state_secret, payload_json)`.

  The random `nonce` is ALSO recorded in the `oauth_states` single-use ledger so
  `verify_state/2` can consume it exactly once — the signed state is then
  redeemable AT MOST once (replay-proof), not merely until its TTL.
  """
  @spec mint_state(String.t()) :: String.t()
  def mint_state(provider) when is_binary(provider) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    exp = System.system_time(:second) + @state_ttl_seconds

    payload = Jason.encode!(%{"p" => provider, "n" => nonce, "exp" => exp})

    %State{}
    |> State.changeset(%{
      nonce: nonce,
      provider: provider,
      expires_at: exp |> DateTime.from_unix!() |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert!()

    encoded = Base.url_encode64(payload, padding: false)
    encoded <> "." <> hmac_hex(payload)
  end

  @doc """
  Verify a presented `state` against `provider`, CONSUMING it (single use).

  `:ok` iff: the mac recomputes and CONSTANT-TIME-matches, `exp > now`, the
  embedded provider equals `provider` (so a state minted for GitHub can't be
  replayed on the Google callback), AND its nonce is still present in the
  `oauth_states` ledger — which this call deletes, so a SECOND verify of the same
  state (a replay) finds nothing and is rejected. Any malformed / tampered /
  expired / cross-provider / already-consumed state is `{:error, reason}` — never
  a raise. The consume runs LAST so a forged or cross-provider attempt never
  burns a legitimately-issued nonce.
  """
  @spec verify_state(String.t(), String.t()) :: :ok | {:error, atom()}
  def verify_state(state, provider) when is_binary(state) and is_binary(provider) do
    with [encoded, presented_mac] <- String.split(state, ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(encoded, padding: false),
         true <- secure_compare(presented_mac, hmac_hex(payload)),
         {:ok, %{"p" => p, "n" => nonce, "exp" => exp}} <- Jason.decode(payload),
         true <- is_binary(nonce),
         true <- is_integer(exp) and exp > System.system_time(:second),
         true <- p == provider,
         true <- consume_state(nonce, provider) do
      :ok
    else
      _ -> {:error, :invalid_state}
    end
  end

  def verify_state(_, _), do: {:error, :invalid_state}

  # The single-use compare-and-consume: delete the ledger row for this
  # (nonce, provider) that has NOT yet expired. Exactly one row deleted → first
  # redemption (accept). Zero rows → already consumed (replay), expired, or never
  # issued (reject). The DELETE is atomic, so two racing callbacks can't both win.
  defp consume_state(nonce, provider) do
    now = DateTime.utc_now()

    {deleted, _} =
      from(s in State,
        where: s.nonce == ^nonce and s.provider == ^provider and s.expires_at > ^now
      )
      |> Repo.delete_all()

    deleted == 1
  end

  ## Internals — exchange steps

  defp exchange_code(module, config, provider, code) do
    req = module.token_request(config, code, redirect_uri(provider))

    with {:ok, %{} = body} <- request_json(req),
         token when is_binary(token) and token != "" <- body["access_token"] do
      {:ok, token}
    else
      _ -> {:error, :token_exchange_failed}
    end
  end

  defp get_userinfo(module, access_token) do
    case request_json(module.userinfo_request(access_token)) do
      {:ok, %{} = body} -> {:ok, body}
      _ -> {:error, :userinfo_failed}
    end
  end

  # For a strategy that exports emails_request/1 (GitHub), fetch the email list
  # and merge it under "emails" so the single parse_identity/1 call can find the
  # verified primary. Google returns the email inline and skips this.
  defp parse_identity(module, access_token, userinfo) do
    userinfo =
      if function_exported?(module, :emails_request, 1) do
        case request_json_list(module.emails_request(access_token)) do
          {:ok, emails} when is_list(emails) -> Map.put(userinfo, "emails", emails)
          _ -> userinfo
        end
      else
        userinfo
      end

    case module.parse_identity(userinfo) do
      {:ok, identity} -> {:ok, identity}
      :error -> {:error, :identity_parse_failed}
    end
  end

  # Run a request through the injected client and JSON-decode a 2xx object body.
  defp request_json(req) do
    with fun when is_function(fun, 1) <- http_client(),
         {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(req),
         {:ok, %{} = decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      nil -> {:error, :http_client_not_configured}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  # Like request_json/1 but the 2xx body is expected to be a JSON ARRAY (GitHub's
  # /user/emails). Atom keys are not used; the list is maps of string keys.
  defp request_json_list(req) do
    with fun when is_function(fun, 1) <- http_client(),
         {:ok, %{status: status, body: body}} when status in 200..299 <- fun.(req),
         {:ok, list} when is_list(list) <- Jason.decode(body) do
      {:ok, list}
    else
      nil -> {:error, :http_client_not_configured}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  ## Internals — config resolution (read at call time)

  # Resolve an ENABLED provider to {:ok, module, config}; unknown/disabled → :error.
  defp resolve(provider) do
    cfg = providers()[provider]

    if is_map(cfg) and configured?(cfg) and is_atom(cfg[:module]) do
      {:ok, cfg[:module], cfg}
    else
      :error
    end
  end

  defp resolve_ok(provider) do
    case resolve(provider) do
      {:ok, module, config} -> {:ok, module, config}
      :error -> {:error, :provider_not_enabled}
    end
  end

  defp configured?(cfg) do
    present?(cfg[:client_id]) and present?(cfg[:client_secret])
  end

  defp present?(v), do: is_binary(v) and v != ""

  # The redirect_uri is DERIVED, never stored — Coolify backfills the same value
  # (bootstrap/helpers/socialite.php). The operator registers exactly this URI in
  # each provider's OAuth app.
  defp redirect_uri(provider), do: "#{base_url()}/v1/auth/oauth/#{provider}/callback"

  defp providers, do: config()[:providers] || %{}
  defp http_client, do: config()[:http_client]
  defp base_url, do: config()[:base_url] || "https://barkpark.cloud"

  defp state_secret do
    config()[:state_secret] ||
      raise """
      #{inspect(__MODULE__)} has no :state_secret. Set OAUTH_STATE_SECRET (wired
      in runtime.exs) — the HMAC key for the OAuth CSRF state token.
      """
  end

  defp config, do: Application.get_env(:barkpark_cloud, __MODULE__, [])

  ## Internals — HMAC + constant-time compare (mirrors StripeGateway)

  defp hmac_hex(payload) do
    :crypto.mac(:hmac, :sha256, state_secret(), payload) |> Base.encode16(case: :lower)
  end

  # Constant-time comparison — inlined to avoid pulling in Plug.Crypto for one
  # call (same as StripeGateway). Equal length AND every byte equal, in time
  # independent of where the first mismatch is.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and constant_time_equal?(a, b, 0)
  end

  defp secure_compare(_, _), do: false

  defp constant_time_equal?(<<x, rest_a::binary>>, <<y, rest_b::binary>>, acc) do
    constant_time_equal?(rest_a, rest_b, Bitwise.bor(acc, Bitwise.bxor(x, y)))
  end

  defp constant_time_equal?(<<>>, <<>>, acc), do: acc === 0
end
