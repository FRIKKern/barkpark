defmodule Barkpark.Plugins.Indx.Settings do
  @moduledoc """
  Typed wrapper around `Barkpark.Plugins.Settings` for the `"indx"` plugin
  row. Resolves Indx connection settings in this order:

    1. Application env (`config :barkpark, Barkpark.Plugins.Indx, ...`),
       which `runtime.exs` populates from `INDX_*` OS env vars at boot
       (env wins).
    2. The encrypted `plugin_settings` row keyed by `"indx"` (Phase 1
       infrastructure — no new migration, no new encryption code).
    3. Module defaults.

  The keys:

    * `:api_base`        — base URL for the dedicated single-tenant Indx
      (default `"http://127.0.0.1:5001"`). The `/api` segment is appended
      by the client, NOT stored here.
    * `:user_email`      — Indx login email (default `"admin@indx.co"`)
    * `:user_password`   — Indx login password (encrypted at rest in DB)
    * `:dataset_prefix`  — prefix for blue/green dataset names
      (default `"bp"`); rebuilds produce `<prefix>_<scope>_v<n>`.
    * `:weight_high` / `:weight_medium` / `:weight_low` — searchable-field
      weights. Indx requires 0..2 (0=High, 1=Med, 2=Low); a weight of 3
      yields a 500 IndexOutOfRange, so we pin defaults to the valid band.

  Mirrors the OnixEdit/Bokbasen typed-settings-wrapper precedent.
  """

  alias Barkpark.Plugins.Settings

  @plugin_name "indx"
  @app :barkpark
  @env_module __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  @string_keys [:api_base, :user_email, :user_password, :dataset_prefix]
  @weight_keys [:weight_high, :weight_medium, :weight_low]

  @default_api_base "http://127.0.0.1:5001"
  @default_user_email "admin@indx.co"
  @default_dataset_prefix "bp"
  @default_weight_high 0
  @default_weight_medium 1
  @default_weight_low 2

  @typedoc "Resolved Indx settings map."
  @type settings :: %{
          api_base: String.t(),
          user_email: String.t(),
          user_password: String.t() | nil,
          dataset_prefix: String.t(),
          weight_high: 0..2,
          weight_medium: 0..2,
          weight_low: 0..2
        }

  @doc "The plugin row name used in `plugin_settings`."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "Required string-key atoms that must be present to talk to Indx."
  @spec required_keys() :: [atom()]
  def required_keys, do: [:api_base, :user_email, :user_password]

  @doc """
  Returns the resolved settings map. Per-field resolution: env wins, DB
  falls back, otherwise the module default. `user_password` has no
  default (nil when unconfigured). Never raises — callers should call
  `valid?/1` before performing network operations.
  """
  @spec get() :: settings()
  def get do
    env = Application.get_env(@app, @env_module, [])
    db = load_db_settings()

    %{
      api_base: resolve_string(:api_base, env, db) || @default_api_base,
      user_email: resolve_string(:user_email, env, db) || @default_user_email,
      user_password: resolve_string(:user_password, env, db),
      dataset_prefix: resolve_string(:dataset_prefix, env, db) || @default_dataset_prefix,
      weight_high: resolve_weight(:weight_high, env, db, @default_weight_high),
      weight_medium: resolve_weight(:weight_medium, env, db, @default_weight_medium),
      weight_low: resolve_weight(:weight_low, env, db, @default_weight_low)
    }
  end

  @doc """
  Persist settings to the encrypted `plugin_settings` row. Validates the
  map first; returns the same shape `Settings.put/3` returns on success,
  or `{:error, {:invalid, missing}}` on validation failure.
  """
  @spec put(map(), keyword()) ::
          {:ok, Barkpark.Plugins.SettingsRecord.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:invalid, [atom()]}}
  def put(map, opts \\ []) when is_map(map) do
    case valid?(map) do
      true -> Settings.put(@plugin_name, stringify(map), opts)
      {:invalid, missing} -> {:error, {:invalid, missing}}
    end
  end

  @doc """
  Returns `true` if the required string keys (`api_base`, `user_email`,
  `user_password`) are present as non-empty binaries, otherwise
  `{:invalid, [reason]}` listing the offending fields.
  """
  @spec valid?(map()) :: true | {:invalid, [atom()]}
  def valid?(map) when is_map(map) do
    missing =
      required_keys()
      |> Enum.filter(fn key ->
        not non_empty_binary?(Map.get(map, key) || Map.get(map, Atom.to_string(key)))
      end)

    case missing do
      [] -> true
      _ -> {:invalid, missing}
    end
  end

  defp resolve_string(key, env, db) do
    cond do
      v = present(env_value(env, key)) -> v
      v = present(Map.get(db, Atom.to_string(key))) -> v
      v = present(Map.get(db, key)) -> v
      true -> nil
    end
  end

  # Weights coerce from env/DB strings to ints, then clamp to 0..2 so a
  # stray weight of 3 (Indx 500 IndexOutOfRange) can never reach the wire.
  defp resolve_weight(key, env, db, default) do
    raw = env_value(env, key) || Map.get(db, Atom.to_string(key)) || Map.get(db, key)

    raw
    |> coerce_int(default)
    |> clamp_weight()
  end

  defp coerce_int(n, _default) when is_integer(n), do: n

  defp coerce_int(v, default) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp coerce_int(_v, default), do: default

  defp clamp_weight(n) when is_integer(n) and n < 0, do: 0
  defp clamp_weight(n) when is_integer(n) and n > 2, do: 2
  defp clamp_weight(n) when is_integer(n), do: n

  defp env_value(env, key) when is_list(env), do: Keyword.get(env, key)
  defp env_value(env, key) when is_map(env), do: Map.get(env, key)
  defp env_value(_, _), do: nil

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v) when is_binary(v), do: v
  defp present(_), do: nil

  defp load_db_settings do
    case Settings.get(@plugin_name) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp stringify(map) do
    (@string_keys ++ @weight_keys)
    |> Enum.map(fn key -> {key, Map.get(map, key) || Map.get(map, Atom.to_string(key))} end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), to_string(v)} end)
  end

  defp non_empty_binary?(v) when is_binary(v) and byte_size(v) > 0, do: true
  defp non_empty_binary?(_), do: false
end
