defmodule Barkpark.EdgeProjector.Settings do
  @moduledoc """
  Typed-settings wrapper for the content-graph edge projector. Mirrors the
  `Barkpark.Plugins.Indx.Settings` precedent — env wins, then the encrypted
  `plugin_settings` row, then the module default.

  The one key today:

    * `:incremental_project` — default `true` (task-6e2552cdeb223fa2; it was
      `false`). It gates the per-doc UPSERT path on `:after_save`:

        - ON (the DEFAULT) → a save enqueues a per-document `upsert_record/2`
          job, which diffs ONE doc's outbound edges against stored.
        - OFF → a save enqueues the full per-scope REBUILD for the doc's type
          (delete the scope's edges, re-extract the published corpus, bulk
          add). One rebuild per save made a bulk import cost a type-wide
          rebuild per document.

      A draft's edges can now reach the table from its draft row; the public
      graph reads drop draft sources (`Content.Graph` `published_only: true`).

      Turn it off with the env var `EDGE_PROJECTOR_INCREMENTAL=0` (any value
      outside "1"/"true"/"yes"/"on", case-insensitive, reads as off).

  Settings stored under the `"edge_projector"` plugin row. There is no
  network connection to configure (the projector writes the local
  `content_edges` table), so unlike Indx there are no required keys.
  """

  alias Barkpark.Plugins.Settings

  @plugin_name "edge_projector"
  @app :barkpark
  @env_module __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  @default_incremental_project true

  @typedoc "Resolved edge-projector settings map."
  @type settings :: %{
          incremental_project: boolean()
        }

  @doc "The plugin row name used in `plugin_settings`."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  Returns the resolved settings map. Per-field resolution: env wins, DB
  falls back, otherwise the module default. Never raises — a misconfigured
  DB read degrades to the default so a lifecycle hook can call this safely.
  """
  @spec get() :: settings()
  def get do
    env = Application.get_env(@app, @env_module, [])
    db = load_db_settings()

    %{
      incremental_project: resolve_incremental_project(env, db)
    }
  end

  @doc """
  Persist settings to the encrypted `plugin_settings` row. The boolean
  `:incremental_project` is stringified the same way Indx stringifies its
  flag for the row.
  """
  @spec put(map(), keyword()) ::
          {:ok, Barkpark.Plugins.SettingsRecord.t()}
          | {:error, Ecto.Changeset.t()}
  def put(map, opts \\ []) when is_map(map) do
    Settings.put(@plugin_name, stringify(map), opts)
  end

  # Precedence: OS env EDGE_PROJECTOR_INCREMENTAL > app env
  # (config :barkpark, Barkpark.EdgeProjector, incremental_project:) > DB row >
  # module default (true). Any source value is coerced to a boolean so a
  # string "true"/"1" reads as true.
  defp resolve_incremental_project(env, db) do
    cond do
      v = System.get_env("EDGE_PROJECTOR_INCREMENTAL") -> coerce_bool(v)
      not is_nil(raw = env_value(env, :incremental_project)) -> coerce_bool(raw)
      not is_nil(raw = Map.get(db, "incremental_project")) -> coerce_bool(raw)
      not is_nil(raw = Map.get(db, :incremental_project)) -> coerce_bool(raw)
      true -> @default_incremental_project
    end
  end

  defp coerce_bool(v) when is_boolean(v), do: v

  defp coerce_bool(v) when is_binary(v) do
    String.downcase(String.trim(v)) in ["1", "true", "yes", "on"]
  end

  defp coerce_bool(_), do: false

  defp env_value(env, key) when is_list(env), do: Keyword.get(env, key)
  defp env_value(env, key) when is_map(env), do: Map.get(env, key)
  defp env_value(_, _), do: nil

  defp load_db_settings do
    case Settings.get(@plugin_name) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp stringify(map) do
    case Map.get(map, :incremental_project) || Map.get(map, "incremental_project") do
      nil -> %{}
      v -> %{"incremental_project" => to_string(v)}
    end
  end
end
