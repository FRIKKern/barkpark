defmodule Barkpark.Plugins.OnixEdit.Bokbasen.Settings do
  @moduledoc """
  Typed wrapper around `Barkpark.Plugins.Settings` for the `"bokbasen"`
  plugin row. Resolves Bokbasen credentials in this order:

    1. Application env (`config :barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, ...`),
       which `runtime.exs` populates from OS env vars at boot.
    2. The encrypted `plugin_settings` row keyed by `"bokbasen"` (Phase 1
       infrastructure — no new migration, no new encryption code).

  The 5 required keys:

    * `:client_id`        — OAuth2 client id (encrypted at rest in DB)
    * `:client_secret`    — OAuth2 client secret (encrypted at rest in DB)
    * `:api_base`         — base URL for the Bokbasen metadata import API
    * `:oauth_token_url`  — OAuth2 token endpoint URL
    * `:client_role`      — `"publisher"` (default) or `"distributor"`

  WI2 ships only credentials + plumbing. The HTTP client (WI3) and Oban
  worker (WI4) call `get_credentials/0` and trust the resolved map.
  """

  alias Barkpark.Plugins.Settings

  @plugin_name "bokbasen"
  @app :barkpark
  @env_module __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  @keys [:client_id, :client_secret, :api_base, :oauth_token_url, :client_role]
  @valid_roles ~w(publisher distributor)
  @default_role "publisher"

  @typedoc "Bokbasen credentials map. Any field may be `nil` if unconfigured."
  @type credentials :: %{
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          api_base: String.t() | nil,
          oauth_token_url: String.t() | nil,
          client_role: String.t()
        }

  @doc "The plugin row name used in `plugin_settings`."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "Default `client_role` per Phase 7 plan (Q-J): Barkpark = Publisher."
  @spec default_client_role() :: String.t()
  def default_client_role, do: @default_role

  @doc "Required key atoms."
  @spec required_keys() :: [atom()]
  def required_keys, do: @keys

  @doc """
  Returns the resolved credentials map. Per-field resolution: env wins,
  DB falls back, otherwise `nil` (and `client_role` defaults to
  `"publisher"`). Never raises on missing settings — callers should
  call `valid?/1` before performing network operations.
  """
  @spec get_credentials() :: credentials()
  def get_credentials do
    env = Application.get_env(@app, @env_module, [])
    db = load_db_settings()

    @keys
    |> Enum.map(fn key -> {key, resolve(key, env, db)} end)
    |> Map.new()
    |> apply_defaults()
  end

  @doc """
  Persist credentials to the encrypted `plugin_settings` row. Only string
  keys/values are stored. Validates the map first; returns the same shape
  `Settings.put/3` returns on success, or `{:error, reason}` on validation
  failure.
  """
  @spec put_credentials(map(), keyword()) ::
          {:ok, Barkpark.Plugins.SettingsRecord.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:invalid, [atom()]}}
  def put_credentials(map, opts \\ []) when is_map(map) do
    typed = normalize(map)

    case valid?(typed) do
      true ->
        Settings.put(@plugin_name, stringify(typed), opts)

      {:invalid, missing} ->
        {:error, {:invalid, missing}}
    end
  end

  @doc """
  Returns `true` if the map has the required string keys with non-empty
  binary values and a recognised `client_role`. Otherwise returns
  `{:invalid, [reason]}` listing the offending fields.
  """
  @spec valid?(map()) :: true | {:invalid, [atom()]}
  def valid?(map) when is_map(map) do
    typed = normalize(map)

    missing =
      @keys
      |> Enum.filter(fn key ->
        key != :client_role and not non_empty_binary?(Map.get(typed, key))
      end)

    role_ok? = Map.get(typed, :client_role, @default_role) in @valid_roles

    cond do
      missing != [] -> {:invalid, missing}
      not role_ok? -> {:invalid, [:client_role]}
      true -> true
    end
  end

  defp resolve(key, env, db) do
    cond do
      v = present(env_value(env, key)) -> v
      v = present(Map.get(db, Atom.to_string(key))) -> v
      v = present(Map.get(db, key)) -> v
      true -> nil
    end
  end

  defp env_value(env, key) when is_list(env), do: Keyword.get(env, key)
  defp env_value(env, key) when is_map(env), do: Map.get(env, key)
  defp env_value(_, _), do: nil

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v) when is_binary(v), do: v
  defp present(_), do: nil

  defp apply_defaults(%{client_role: nil} = m), do: %{m | client_role: @default_role}
  defp apply_defaults(%{client_role: ""} = m), do: %{m | client_role: @default_role}
  defp apply_defaults(m), do: m

  defp load_db_settings do
    case Settings.get(@plugin_name) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp normalize(map) do
    @keys
    |> Enum.map(fn key ->
      v = Map.get(map, key) || Map.get(map, Atom.to_string(key))
      {key, v}
    end)
    |> Map.new()
  end

  defp stringify(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), to_string(v)} end)
  end

  defp non_empty_binary?(v) when is_binary(v) and byte_size(v) > 0, do: true
  defp non_empty_binary?(_), do: false
end
