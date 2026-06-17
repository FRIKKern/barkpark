defmodule Barkpark.Plugins.Indx.Auth do
  @moduledoc """
  JWT token cache for the dedicated single-tenant Indx instance.

  Single-process GenServer cache so concurrent callers de-duplicate
  in-flight logins automatically (GenServer serialises calls; the second
  caller sees the cached token populated by the first). Mirrors the
  OnixEdit/Bokbasen OAuth token-cache GenServer precedent.

  ## Public API

    * `token/0`       — `{:ok, jwt}` | `{:error, %AuthError{}}`
    * `invalidate/0`  — drop cached token; next `token/0` re-logs-in.

  ## Login

  `POST <api_base>/api/Login` with body
  `{"UserEmail": ..., "UserPassWord": ...}`, expecting `{"token": "<jwt>"}`.
  Credentials come from `Barkpark.Plugins.Indx.Settings.get/0` (env wins
  over the encrypted `plugin_settings` row).

  ## Token TTL

  Indx does NOT return an `expires_in`, so the cache holds the JWT for a
  fixed `@default_ttl_seconds` window (minus a small safety margin). The
  client calls `invalidate/0` on any 401 and retries once, so an
  expired-early token self-heals on the next request rather than relying
  on the TTL alone.

  ## Lifecycle

  Started under the host supervision tree via the plugin's
  `register_workers/1`. Does NOT eagerly log in at boot — the first
  `token/0` call triggers the first login.
  """

  use GenServer

  alias Barkpark.Plugins.Indx.Errors.AuthError
  alias Barkpark.Plugins.Indx.Settings

  @default_ttl_seconds 3600
  @safety_margin_seconds 60
  @login_path "/api/Login"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the GenServer. Registered under the module name."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns a cached or freshly-fetched JWT.

  Concurrent callers serialise on the GenServer; only one login is in
  flight at a time per credential set.
  """
  @spec token() :: {:ok, String.t()} | {:error, AuthError.t()}
  def token, do: GenServer.call(__MODULE__, :token, 35_000)

  @doc "Drop cached token. Next `token/0` will re-login."
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
        case login() do
          {:ok, jwt} ->
            new_state = %{
              token: jwt,
              expires_at: now + @default_ttl_seconds - @safety_margin_seconds
            }

            {:reply, {:ok, jwt}, new_state}

          {:error, %AuthError{}} = err ->
            {:reply, err, %{state | token: nil, expires_at: 0}}
        end
    end
  end

  def handle_call(:invalidate, _from, _state) do
    {:reply, :ok, %{token: nil, expires_at: 0}}
  end

  # ---------------------------------------------------------------------------
  # Internal: HTTP login
  # ---------------------------------------------------------------------------

  defp login do
    settings = Settings.get()

    cond do
      # v5: a static JWT API token from the portal (/Account/ApiKey) is used
      # directly as the Bearer — no `/api/Login` round-trip. Set via env
      # `INDX_API_TOKEN`. Takes precedence when present.
      present?(settings.api_token) ->
        {:ok, settings.api_token}

      not present?(settings.api_base) ->
        {:error, %AuthError{status: 0, endpoint: nil, message: "Indx api_base not configured"}}

      not present?(settings.user_email) ->
        {:error, %AuthError{status: 0, endpoint: nil, message: "Indx user_email not configured"}}

      not present?(settings.user_password) ->
        {:error,
         %AuthError{status: 0, endpoint: nil, message: "Indx user_password not configured"}}

      true ->
        do_login(settings)
    end
  end

  defp do_login(settings) do
    url = base(settings.api_base) <> @login_path

    body =
      Jason.encode!(%{
        "UserEmail" => settings.user_email,
        "UserPassWord" => settings.user_password
      })

    req =
      Req.new(
        url: url,
        method: :post,
        headers: [{"content-type", "application/json"}],
        body: body,
        receive_timeout: 30_000,
        retry: false,
        decode_body: false
      )

    case safe_request(req) do
      {:ok, %{status: 200, body: resp_body}} ->
        case extract_token(resp_body) do
          jwt when is_binary(jwt) and jwt != "" ->
            {:ok, jwt}

          _ ->
            {:error,
             %AuthError{status: 200, endpoint: url, message: "Indx login response missing token"}}
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, %AuthError{status: status, endpoint: url, message: "Indx credentials rejected"}}

      {:ok, %{status: status}} ->
        {:error,
         %AuthError{
           status: status,
           endpoint: url,
           message: "Indx login returned unexpected status"
         }}

      {:error, exception} ->
        {:error,
         %AuthError{
           status: 0,
           endpoint: url,
           message: "Indx login failed: #{inspect_reason(exception)}"
         }}
    end
  end

  defp safe_request(req) do
    Req.request(req)
  rescue
    e -> {:error, e}
  end

  defp extract_token(body) when is_map(body), do: Map.get(body, "token")

  defp extract_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"token" => t}} -> t
      _ -> nil
    end
  end

  defp extract_token(_), do: nil

  defp base(url), do: String.trim_trailing(url, "/")

  defp present?(v) when is_binary(v) and byte_size(v) > 0, do: true
  defp present?(_), do: false

  defp inspect_reason(%{reason: reason}), do: reason
  defp inspect_reason(other), do: other
end
