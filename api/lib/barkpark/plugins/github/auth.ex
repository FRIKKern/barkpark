defmodule Barkpark.Plugins.Github.Auth do
  @moduledoc """
  GitHub App installation-token cache for the `github` mirror plugin.

  Single-process GenServer so concurrent callers de-duplicate in-flight
  token fetches automatically (the GenServer serialises calls; the second
  caller sees the token the first one cached).

  ## Two-step GitHub App auth

    1. Mint an RS256 **app JWT** from the App's private key via
       `:public_key` (`iss` = App ID, `iat` = now − 60 s clock-skew slack,
       `exp` = now + 600 s — GitHub caps App JWTs at 10 min).
    2. Exchange it at
       `POST <api_base>/app/installations/<installation_id>/access_tokens`
       for a ~1 h **installation token**, cached with
       `expires_at = monotonic_seconds() + expires_in − 60` (60 s safety
       margin; `expires_in` defaults to 3600 when GitHub omits it).

  ## Public API

    * `token/0`      — `{:ok, bearer}` | `{:error, %AuthError{}}`
    * `invalidate/0` — drop the cached token; next `token/0` re-fetches.

  ## Credential resolution

  Resolves creds through `Barkpark.Plugins.Github.Settings.get_credentials/0`:
  `app_id`, `installation_id`, `private_key` (PEM), and `api_base` (the App API
  base — defaults to `https://api.github.com`; tests inject a Bypass base). That
  resolver reads the SAME `Application.get_env(:barkpark, Barkpark.Plugins.Github)`
  key this GenServer always did (so env-provisioned creds and the wave-1 tests
  are unaffected) and, when a key is blank there, falls back to the encrypted
  `plugin_settings` "github" row so a maintainer who provisioned the App through
  the admin Settings UI actually reaches the token exchange. No credential is
  ever hardcoded.

  ## Lifecycle

  Lazy — does NOT fetch a token at boot; the first `token/0` call triggers
  the first fetch. Started under supervision by the plugin's
  `register_workers/1` (wave-1 slice 1); tests start it directly.
  """

  use GenServer

  alias Barkpark.Plugins.Github.Errors.AuthError
  alias Barkpark.Plugins.Github.Settings

  @default_api_base "https://api.github.com"
  @safety_margin_seconds 60
  @default_expires_in 3600
  # GitHub caps App JWTs at 10 minutes; back off the issued-at 60 s for
  # clock skew between us and GitHub.
  @jwt_ttl_seconds 600
  @jwt_iat_backdate_seconds 60
  @github_api_version "2022-11-28"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the GenServer. Registered under the module name."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns a cached or freshly-fetched installation bearer token.

  Concurrent callers serialise on the GenServer; only one HTTP token
  exchange is in flight at a time.
  """
  @spec token() :: {:ok, String.t()} | {:error, AuthError.t()}
  def token, do: GenServer.call(__MODULE__, :token, 35_000)

  @doc "Drop the cached token. Next `token/0` will re-fetch."
  @spec invalidate() :: :ok
  def invalidate, do: GenServer.call(__MODULE__, :invalidate)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{token: nil, expires_at: 0}}

  @impl true
  def handle_call(:token, _from, state) do
    now = System.monotonic_time(:second)

    cond do
      is_binary(state.token) and state.expires_at > now ->
        {:reply, {:ok, state.token}, state}

      true ->
        case fetch_token() do
          {:ok, bearer, ttl} ->
            new_state = %{token: bearer, expires_at: now + ttl - @safety_margin_seconds}
            {:reply, {:ok, bearer}, new_state}

          {:error, %AuthError{}} = err ->
            {:reply, err, %{state | token: nil, expires_at: 0}}
        end
    end
  end

  def handle_call(:invalidate, _from, _state) do
    {:reply, :ok, %{token: nil, expires_at: 0}}
  end

  # ---------------------------------------------------------------------------
  # Internal: token fetch
  # ---------------------------------------------------------------------------

  defp fetch_token do
    cfg = config()

    cond do
      blank?(cfg[:app_id]) ->
        {:error, %AuthError{status: 0, endpoint: nil, message: "GitHub App ID not configured"}}

      blank?(cfg[:installation_id]) ->
        {:error,
         %AuthError{status: 0, endpoint: nil, message: "GitHub installation ID not configured"}}

      blank?(cfg[:private_key]) ->
        {:error,
         %AuthError{status: 0, endpoint: nil, message: "GitHub App private key not configured"}}

      true ->
        case build_app_jwt(cfg[:app_id], cfg[:private_key]) do
          {:ok, jwt} ->
            exchange(jwt, cfg)

          :error ->
            {:error,
             %AuthError{status: 0, endpoint: nil, message: "GitHub App private key invalid"}}
        end
    end
  end

  defp exchange(jwt, cfg) do
    url =
      "#{api_base(cfg)}/app/installations/#{cfg[:installation_id]}/access_tokens"

    req =
      Req.new(
        url: url,
        method: :post,
        headers: [
          {"authorization", "Bearer " <> jwt},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", @github_api_version},
          {"user-agent", user_agent()}
        ],
        receive_timeout: 30_000,
        # Route the installation-token fetch onto the dedicated auth-outbound
        # Finch pool (Felix W10) so a slow GitHub App API cannot borrow from the
        # global default pool shared with webhook/CDN traffic.
        finch: Barkpark.Auth.Finch,
        retry: false
      )

    case Req.request(req) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        access_token = extract_token(body)
        ttl = extract_ttl(body)

        if is_binary(access_token) and access_token != "" do
          {:ok, access_token, ttl}
        else
          {:error,
           %AuthError{
             status: status,
             endpoint: url,
             message: "installation-token response missing token"
           }}
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, %AuthError{status: status, endpoint: url, message: "App JWT rejected"}}

      {:ok, %{status: 404}} ->
        {:error, %AuthError{status: 404, endpoint: url, message: "installation not found"}}

      {:ok, %{status: status}} ->
        {:error,
         %AuthError{
           status: status,
           endpoint: url,
           message: "installation-token endpoint returned unexpected status"
         }}

      {:error, exception} ->
        {:error,
         %AuthError{
           status: 0,
           endpoint: url,
           message: "installation-token fetch failed: #{inspect(exception_reason(exception))}"
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: RS256 app-JWT minting via :public_key
  # ---------------------------------------------------------------------------

  @doc false
  # Exposed for the test suite so it can assert the JWT shape/signature.
  @spec build_app_jwt(term(), String.t()) :: {:ok, String.t()} | :error
  def build_app_jwt(app_id, private_key_pem) do
    with {:ok, key} <- decode_private_key(private_key_pem) do
      now = System.system_time(:second)

      header = %{"alg" => "RS256", "typ" => "JWT"}

      claims = %{
        "iat" => now - @jwt_iat_backdate_seconds,
        "exp" => now + @jwt_ttl_seconds,
        "iss" => app_id
      }

      signing_input =
        b64url(Jason.encode!(header)) <> "." <> b64url(Jason.encode!(claims))

      try do
        signature = :public_key.sign(signing_input, :sha256, key)
        {:ok, signing_input <> "." <> b64url(signature)}
      rescue
        _ -> :error
      end
    end
  end

  defp decode_private_key(pem) when is_binary(pem) do
    try do
      case :public_key.pem_decode(pem) do
        [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp decode_private_key(_), do: :error

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  # ---------------------------------------------------------------------------
  # Response extraction
  # ---------------------------------------------------------------------------

  defp extract_token(body) when is_map(body), do: Map.get(body, "token")

  defp extract_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"token" => t}} -> t
      _ -> nil
    end
  end

  defp extract_token(_), do: nil

  # Real GitHub returns `expires_at` (ISO8601), NOT `expires_in`; installation
  # tokens live ~1 h. Prefer a valid `expires_in` (some mocks/proxies send it),
  # then derive the TTL from `expires_at`, then fall back to the ~1 h default.
  defp extract_ttl(body) when is_map(body), do: ttl_from_map(body)

  defp extract_ttl(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> ttl_from_map(map)
      _ -> @default_expires_in
    end
  end

  defp extract_ttl(_), do: @default_expires_in

  defp ttl_from_map(map) do
    cond do
      is_integer(map["expires_in"]) and map["expires_in"] > 0 ->
        map["expires_in"]

      is_binary(map["expires_at"]) ->
        ttl_from_expires_at(map["expires_at"])

      true ->
        @default_expires_in
    end
  end

  defp ttl_from_expires_at(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        secs = DateTime.diff(dt, DateTime.utc_now())
        # A positive span is trusted verbatim — the call-site safety margin
        # self-heals a tiny remainder into an immediate refetch. A non-positive
        # span means a broken/skewed timestamp with no usable TTL; fall back to
        # the known ~1 h installation-token life rather than poison the cache
        # with a negative expiry (the 401-refresh path recovers if truly dead).
        if secs > 0, do: secs, else: @default_expires_in

      _ ->
        @default_expires_in
    end
  end

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  @doc false
  # Resolved creds map (env-wins → encrypted "github" plugin_settings row).
  # Kept public + delegating so any caller/test that reached in for the raw
  # config now transparently gets the DB-bridged resolution.
  def config, do: Settings.get_credentials()

  defp api_base(cfg) do
    case cfg[:api_base] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @default_api_base
    end
  end

  defp user_agent do
    "Barkpark/#{Application.spec(:barkpark, :vsn) |> to_string()} (GithubMirror)"
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp exception_reason(%{reason: reason}), do: reason
  defp exception_reason(other), do: other
end
