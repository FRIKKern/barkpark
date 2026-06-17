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
    * `:team` — v5: the Indx team that owns the datasets; when set, the client
      uses v5 team-scoped routes (`/api/teams/<team>/datasets/...`). Env `INDX_TEAM`.
    * `:api_token` — v5: a static JWT API token (Indx portal /Account/ApiKey)
      used directly as the Bearer; replaces the `/api/Login` flow. Env `INDX_API_TOKEN`.
    * `:weight_high` / `:weight_medium` / `:weight_low` — searchable-field
      weights. v5: FLOAT multipliers (practical range 0.5–3.0, higher = more
      influence; the ratio between fields is what matters). Defaults
      3.0 / 1.5 / 1.0. (The old 0/1/2, 0=High scale is gone.)
    * `:incremental_upsert` — feature flag (default `false`). OFF →
      after_save/after_publish take the blue/green full rebuild (today's
      behaviour, byte-identical). ON → they route to the per-document
      incremental upsert op. Env override `INDX_INCREMENTAL_UPSERT`
      (truthy: "1"/"true"/"yes"/"on", case-insensitive).

  Mirrors the OnixEdit/Bokbasen typed-settings-wrapper precedent.
  """

  alias Barkpark.Plugins.Settings

  @plugin_name "indx"
  @app :barkpark
  @env_module __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  @string_keys [:api_base, :user_email, :user_password, :dataset_prefix, :team, :api_token]
  @weight_keys [:weight_high, :weight_medium, :weight_low]

  @default_api_base "http://127.0.0.1:5001"
  @default_user_email "admin@indx.co"
  @default_dataset_prefix "bp"
  # v5 field weights are FLOAT multipliers (practical range 0.5–3.0, higher =
  # more influence). The old 0/1/2 scale (0 = High) is gone — under v5 a weight
  # of 0 zeroes the field's contribution. title 3.0 ≫ author/category/body 1.5 >
  # slug 1.0. See `Indexer.default_weights/1`.
  @default_weight_high 3.0
  @default_weight_medium 1.5
  @default_weight_low 1.0
  @default_incremental_upsert false

  @typedoc "Resolved Indx settings map."
  @type settings :: %{
          api_base: String.t(),
          user_email: String.t(),
          user_password: String.t() | nil,
          dataset_prefix: String.t(),
          team: String.t() | nil,
          api_token: String.t() | nil,
          weight_high: float(),
          weight_medium: float(),
          weight_low: float(),
          incremental_upsert: boolean()
        }

  @doc "The plugin row name used in `plugin_settings`."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  True when the v5 contract should be used: team-scoped routes
  (`/api/teams/<team>/datasets/...`) + static-token auth. Activated purely by
  configuring a `team` (env `INDX_TEAM` / DB), so the code-deploy and the
  engine cutover can happen independently. Falsy → legacy v5-alpha routes +
  `/api/Login` auth.
  """
  @spec v5?() :: boolean()
  def v5?, do: non_empty_binary?(get().team)

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
      # v5: the team that owns the datasets (route scope) + a static JWT API
      # token from the Indx portal. When `team` is set, the client routes the
      # v5 way (`/api/teams/<team>/datasets/...`) and auths with `api_token`.
      team: resolve_string(:team, env, db),
      api_token: resolve_string(:api_token, env, db),
      weight_high: resolve_weight(:weight_high, env, db, @default_weight_high),
      weight_medium: resolve_weight(:weight_medium, env, db, @default_weight_medium),
      weight_low: resolve_weight(:weight_low, env, db, @default_weight_low),
      incremental_upsert: resolve_incremental_upsert(env, db)
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

  # Weights coerce from env/DB strings to FLOATS, then clamp to the v5 practical
  # range 0.5–3.0 (the ratio between fields is what matters).
  defp resolve_weight(key, env, db, default) do
    raw = env_value(env, key) || Map.get(db, Atom.to_string(key)) || Map.get(db, key)

    raw
    |> coerce_float(default)
    |> clamp_weight()
  end

  defp coerce_float(n, _default) when is_number(n), do: n * 1.0

  defp coerce_float(v, default) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {f, _} -> f
      :error -> default
    end
  end

  defp coerce_float(_v, default), do: default

  # Resolve the incremental-upsert flag. Precedence: OS env
  # INDX_INCREMENTAL_UPSERT > app env (config :barkpark, Indx,
  # incremental_upsert:) > DB row > module default (false). Any
  # source value is coerced to a boolean via coerce_bool/1 so a string
  # "true"/"1" from env or DB reads as true.
  defp resolve_incremental_upsert(env, db) do
    cond do
      v = System.get_env("INDX_INCREMENTAL_UPSERT") -> coerce_bool(v)
      not is_nil(raw = env_value(env, :incremental_upsert)) -> coerce_bool(raw)
      not is_nil(raw = Map.get(db, "incremental_upsert")) -> coerce_bool(raw)
      not is_nil(raw = Map.get(db, :incremental_upsert)) -> coerce_bool(raw)
      true -> @default_incremental_upsert
    end
  end

  defp coerce_bool(v) when is_boolean(v), do: v

  defp coerce_bool(v) when is_binary(v) do
    String.downcase(String.trim(v)) in ["1", "true", "yes", "on"]
  end

  defp coerce_bool(_), do: false

  defp clamp_weight(n) when is_number(n) and n < 0.5, do: 0.5
  defp clamp_weight(n) when is_number(n) and n > 3.0, do: 3.0
  defp clamp_weight(n) when is_number(n), do: n * 1.0

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
