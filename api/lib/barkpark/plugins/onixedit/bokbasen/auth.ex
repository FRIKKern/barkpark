defmodule Barkpark.Plugins.OnixEdit.Bokbasen.Auth do
  @moduledoc """
  OAuth2 client_credentials token cache for Bokbasen.

  Single-process GenServer cache so concurrent callers de-duplicate
  in-flight token fetches automatically (GenServer serialises calls;
  the second caller sees the cached token populated by the first).

  ## Public API

    * `token/0`       — `{:ok, bearer}` | `{:error, %AuthError{}}`
    * `invalidate/0`  — drop cached token; next `token/0` refetches.

  ## Credential resolution

  Reads via `Barkpark.Plugins.OnixEdit.Bokbasen.Settings.get_credentials/0`.
  If `oauth_token_url` is missing from Settings, falls back to
  `<api_base>/oauth2/token`.

  ## Token TTL

  `expires_at = monotonic_seconds() + expires_in - 60` (60 s safety
  margin). Defaults to 3600 s if Bokbasen omits `expires_in`. See
  `docs/spec/bokbasen-api-contract.md` §2.2.

  ## Lifecycle

  Started under `Barkpark.Application` supervision tree. Does NOT eagerly
  fetch a token at boot — the first `token/0` call triggers the first
  fetch.
  """

  use GenServer

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.AuthError
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Settings

  @safety_margin_seconds 60
  @default_expires_in 3600

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the GenServer. Registered under the module name."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns a cached or freshly-fetched bearer token.

  Concurrent callers serialise on the GenServer; only one HTTP fetch is
  in flight at a time per credential set.
  """
  @spec token() :: {:ok, String.t()} | {:error, AuthError.t()}
  def token, do: GenServer.call(__MODULE__, :token, 35_000)

  @doc "Drop cached token. Next `token/0` will re-fetch."
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
  # Internal: HTTP fetch
  # ---------------------------------------------------------------------------

  defp fetch_token do
    creds = credentials()

    cond do
      is_nil(creds.client_id) or creds.client_id == "" ->
        {:error,
         %AuthError{status: 0, endpoint: nil, message: "Bokbasen credentials not configured"}}

      is_nil(creds.client_secret) or creds.client_secret == "" ->
        {:error,
         %AuthError{status: 0, endpoint: nil, message: "Bokbasen credentials not configured"}}

      is_nil(creds.oauth_token_url) ->
        {:error, %AuthError{status: 0, endpoint: nil, message: "OAuth token URL not configured"}}

      true ->
        do_fetch(creds)
    end
  end

  defp do_fetch(creds) do
    body =
      URI.encode_query(%{
        "client_id" => creds.client_id,
        "client_secret" => creds.client_secret,
        "grant_type" => "client_credentials"
      })

    req =
      Req.new(
        url: creds.oauth_token_url,
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: body,
        receive_timeout: 30_000,
        retry: false
      )

    case Req.post(req) do
      {:ok, %{status: 200, body: resp_body}} ->
        access_token = extract_token(resp_body)
        ttl = extract_ttl(resp_body)

        if is_binary(access_token) and access_token != "" do
          {:ok, access_token, ttl}
        else
          {:error,
           %AuthError{
             status: 200,
             endpoint: creds.oauth_token_url,
             message: "OAuth response missing access_token"
           }}
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error,
         %AuthError{
           status: status,
           endpoint: creds.oauth_token_url,
           message: "OAuth credentials rejected"
         }}

      {:ok, %{status: status}} ->
        {:error,
         %AuthError{
           status: status,
           endpoint: creds.oauth_token_url,
           message: "OAuth token endpoint returned unexpected status"
         }}

      {:error, exception} ->
        {:error,
         %AuthError{
           status: 0,
           endpoint: creds.oauth_token_url,
           message: "OAuth token fetch failed: #{inspect_reason(exception)}"
         }}
    end
  end

  defp extract_token(body) when is_map(body), do: Map.get(body, "access_token")

  defp extract_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => t}} -> t
      _ -> nil
    end
  end

  defp extract_token(_), do: nil

  defp extract_ttl(body) when is_map(body) do
    case Map.get(body, "expires_in") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_expires_in
    end
  end

  defp extract_ttl(_), do: @default_expires_in

  defp inspect_reason(exception) do
    case exception do
      %{reason: reason} -> reason
      other -> other
    end
  end

  @doc """
  Returns the resolved Bokbasen credentials map. If
  `oauth_token_url` is missing from Settings, derives it as
  `<api_base>/oauth2/token`.
  """
  @spec credentials() :: %{
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          api_base: String.t() | nil,
          oauth_token_url: String.t() | nil,
          client_role: String.t()
        }
  def credentials do
    base = Settings.get_credentials()

    case base.oauth_token_url do
      nil ->
        if is_binary(base.api_base) and base.api_base != "" do
          %{base | oauth_token_url: trim_trailing_slash(base.api_base) <> "/oauth2/token"}
        else
          base
        end

      "" ->
        if is_binary(base.api_base) and base.api_base != "" do
          %{base | oauth_token_url: trim_trailing_slash(base.api_base) <> "/oauth2/token"}
        else
          base
        end

      _ ->
        base
    end
  end

  defp trim_trailing_slash(url), do: String.trim_trailing(url, "/")
end
