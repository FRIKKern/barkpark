defmodule Barkpark.Plugins.Bootstrap do
  @moduledoc """
  Boot-time installer for plugin-declared schemas.

  Walks `Barkpark.Plugins.Registry.all/0`, calls each plugin module's
  `register_schemas/1` callback, and persists every emitted
  `%Barkpark.Content.SchemaDefinition{}` via
  `Barkpark.Content.upsert_schema/2`.

  Idempotent against the `(:name, :dataset)` composite unique index on
  `schema_definitions` — re-running this function on an already-bootstrapped
  database performs `Repo.update` for existing rows and returns the same
  `:ok` count with zero new inserts.

  Safe: per-plugin `try/rescue` keeps a single bad plugin from killing the
  whole sweep. The bootstrap function NEVER raises — failures are logged
  via `Logger.warning` / `Logger.error` and surfaced in the return tuple.

  Two callers expected:

    * `Barkpark.Application.start/2` post-boot Task (auto-install on every
      server start)
    * `priv/repo/seeds.exs` (so `mix ecto.reset` produces a fully populated
      DB, including plugin-declared schemas alongside the v1 seeds)

  Both invoke the same `register_all_schemas/0` so behaviour stays in sync.

  Covers boot-time-registered plugins only. If a future feature dynamically
  calls `Plugins.Registry.register/2` after boot, an operator must invoke
  `register_all_schemas/0` again from a remote console for the new plugin's
  schemas to land.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.RunStatus
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @drop_keys [:__meta__, :id, :inserted_at, :updated_at]

  @doc """
  Walks the plugin registry and upserts every schema each plugin declares.

  Returns:
    * `{:ok, count}` when every upsert succeeded — `count` is the number of
      schema rows installed or refreshed.
    * `{:error, errors}` when any plugin or upsert failed — `errors` is a
      list of `{plugin_name :: String.t(), reason :: term()}` pairs.
      Successful upserts in the same sweep still landed in the DB.

  Idempotent: re-invoke freely. Each call routes through
  `Content.upsert_schema/2`, which reads first and updates existing rows in
  place (no duplicate inserts, no constraint violations).
  """
  @spec register_all_schemas() ::
          {:ok, non_neg_integer()} | {:error, [{String.t(), term()}]}
  def register_all_schemas do
    scope = default_scope()
    plugins = Registry.all()

    {ok_count, errors} =
      Enum.reduce(plugins, {0, []}, fn plugin, {ok_acc, err_acc} ->
        case install_for_plugin(plugin, scope) do
          {:ok, n} -> {ok_acc + n, err_acc}
          {:error, reason} -> {ok_acc, [{plugin.name, reason} | err_acc]}
        end
      end)

    case errors do
      [] -> {:ok, ok_count}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  # Resolve the Default Workspace/Project so bootstrap-registered plugin schemas
  # land under the same tenant as the v1 seeds. Returns
  # `{workspace_id, project_id}` or `{nil, nil}` when the backfill hasn't run —
  # in which case scope stamping is a no-op and the schema lands unscoped
  # (matching legacy pre-tenancy behaviour). Read-only; never raises — a missing
  # tenancy table (boot before the tenancy migration) degrades to unscoped.
  defp default_scope do
    case Tenancy.get_default_workspace() do
      nil ->
        {nil, nil}

      ws ->
        project_id =
          case Tenancy.get_default_project() do
            nil -> nil
            project -> project.id
          end

        {ws.id, project_id}
    end
  rescue
    e ->
      Logger.warning(
        "Plugins.Bootstrap: could not resolve Default tenancy scope — schemas land unscoped: #{Exception.message(e)}"
      )

      {nil, nil}
  end

  @doc """
  Looks up `plugin_name` in the registry and runs `register_schemas/1`
  against just that plugin. Used by the plugin admin LV to power the
  per-plugin Reload button.

  Returns the same shape as `register_all_schemas/0`'s per-plugin result:
  `{:ok, count}` or `{:error, reason}`. The result is also recorded into
  `Barkpark.Plugins.RunStatus` keyed by plugin name.
  """
  @spec install_by_name(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def install_by_name(plugin_name) when is_binary(plugin_name) do
    case Registry.lookup(plugin_name) do
      {:ok, entry} -> install_for_plugin(entry, default_scope())
      :error -> {:error, :unknown_plugin}
    end
  end

  # ─── Per-plugin install ────────────────────────────────────────────────

  @doc """
  Runs the given plugin's `register_schemas/1` callback and upserts every
  emitted schema. Public so the plugin admin LV can call it directly for
  one plugin without re-walking the whole registry.

  Records the result into `RunStatus` under `:bootstrap`.
  """
  @spec install_for_plugin(map(), {binary() | nil, binary() | nil}) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def install_for_plugin(plugin, scope \\ {nil, nil})

  def install_for_plugin(%{name: name, module: module}, scope) do
    result = do_install_for_plugin(name, module, scope)
    RunStatus.record(:bootstrap, name, result)
    result
  end

  defp do_install_for_plugin(name, module, scope) do
    cond do
      not Code.ensure_loaded?(module) ->
        Logger.warning(
          "Plugins.Bootstrap: plugin #{inspect(name)} module #{inspect(module)} failed to load — skipping"
        )

        {:ok, 0}

      not function_exported?(module, :register_schemas, 1) ->
        {:ok, 0}

      true ->
        try do
          schemas = module.register_schemas([])
          upsert_schemas(name, schemas, scope)
        rescue
          e ->
            Logger.error(
              "Plugins.Bootstrap: plugin #{inspect(name)} (#{inspect(module)}) raised in register_schemas/1: #{Exception.message(e)}"
            )

            {:error, {:raised, Exception.message(e)}}
        end
    end
  end

  defp upsert_schemas(plugin_name, schemas, scope) when is_list(schemas) do
    Enum.reduce_while(schemas, {:ok, 0}, fn schema, {:ok, n} ->
      case upsert_one(plugin_name, schema, scope) do
        :ok -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_schemas(plugin_name, other, _scope) do
    Logger.error(
      "Plugins.Bootstrap: plugin #{inspect(plugin_name)} returned non-list from register_schemas/1: #{inspect(other)}"
    )

    {:error, {:invalid_return, other}}
  end

  defp upsert_one(plugin_name, %SchemaDefinition{} = schema, scope) do
    # Normalise to a fully string-keyed map BEFORE handing to
    # `Content.upsert_schema/2`. The struct's keys are atoms but plugin
    # `register_schemas/1` impls typically build :fields from
    # JSON-decoded plugin manifests (string-keyed nested maps); plus
    # `Content.upsert_schema/2` itself force-injects `"dataset"` (string)
    # alongside our `:dataset` (atom), producing a top-level mixed-key
    # map that `Ecto.Changeset.cast/3` rejects with
    # `expected params to be a map with atoms or string keys`.
    attrs =
      schema
      |> Map.from_struct()
      |> Map.drop(@drop_keys)
      |> stringify_keys()

    dataset = schema.dataset || "production"

    case Content.upsert_schema(attrs, dataset) do
      {:ok, %SchemaDefinition{} = saved} ->
        stamp_scope(saved, scope)

        Logger.info(
          "Plugins.Bootstrap: registered schema #{inspect(saved.name)} (dataset=#{inspect(saved.dataset)}, visibility=#{inspect(saved.visibility)}) from plugin #{inspect(plugin_name)}"
        )

        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning(
          "Plugins.Bootstrap: upsert_schema failed for plugin #{inspect(plugin_name)} schema #{inspect(Map.get(attrs, "name"))}: #{inspect(changeset.errors)}"
        )

        {:error, {:changeset, changeset.errors}}
    end
  end

  defp upsert_one(plugin_name, other, _scope) do
    Logger.warning(
      "Plugins.Bootstrap: plugin #{inspect(plugin_name)} register_schemas/1 returned non-SchemaDefinition entry: #{inspect(other)} — skipping"
    )

    {:error, {:invalid_entry, other}}
  end

  # Stamp the Default tenancy scope onto a freshly upserted schema row.
  # `Content.upsert_schema/2` routes through `SchemaDefinition.changeset/2`,
  # which does NOT cast the tenancy FKs, so the saved row carries nil scope.
  # Force the columns here via `Ecto.Changeset.change/2` so bootstrap-registered
  # schemas live under the same Default workspace/project as the v1 seeds.
  # No-ops when no Default exists (backfill not run) or when the row is already
  # scoped — keeps the bootstrap idempotent and never re-stamps an
  # operator-moved schema.
  defp stamp_scope(_saved, {nil, _project_id}), do: :ok

  defp stamp_scope(%SchemaDefinition{workspace_id: ws} = saved, {ws_id, project_id})
       when is_nil(ws) do
    saved
    |> Ecto.Changeset.change(%{workspace_id: ws_id, project_id: project_id})
    |> Repo.update!()

    :ok
  end

  defp stamp_scope(_saved, _scope), do: :ok

  # ─── Key normalisation ─────────────────────────────────────────────────

  # Recursively walks a term and converts atom keys to strings inside maps
  # and lists. Tagged structs (DateTime, Date, Time, NaiveDateTime, and any
  # other `%StructName{}`) are returned unchanged — their keys are part of
  # the struct's contract, not free-form params, and Ecto handles them
  # natively. Scalars and binaries pass through.
  #
  # Idempotent: a fully string-keyed term re-stringifies to itself
  # (`to_string("name") == "name"`).
  defp stringify_keys(%{__struct__: _} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  defp stringify_keys(other), do: other
end
