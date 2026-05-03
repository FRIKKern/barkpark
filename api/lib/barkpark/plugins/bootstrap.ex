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
    plugins = Registry.all()

    {ok_count, errors} =
      Enum.reduce(plugins, {0, []}, fn plugin, {ok_acc, err_acc} ->
        case install_for_plugin(plugin) do
          {:ok, n} -> {ok_acc + n, err_acc}
          {:error, reason} -> {ok_acc, [{plugin.name, reason} | err_acc]}
        end
      end)

    case errors do
      [] -> {:ok, ok_count}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  # ─── Per-plugin install ────────────────────────────────────────────────

  defp install_for_plugin(%{name: name, module: module}) do
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
          upsert_schemas(name, schemas)
        rescue
          e ->
            Logger.error(
              "Plugins.Bootstrap: plugin #{inspect(name)} (#{inspect(module)}) raised in register_schemas/1: #{Exception.message(e)}"
            )

            {:error, {:raised, Exception.message(e)}}
        end
    end
  end

  defp upsert_schemas(plugin_name, schemas) when is_list(schemas) do
    Enum.reduce_while(schemas, {:ok, 0}, fn schema, {:ok, n} ->
      case upsert_one(plugin_name, schema) do
        :ok -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_schemas(plugin_name, other) do
    Logger.error(
      "Plugins.Bootstrap: plugin #{inspect(plugin_name)} returned non-list from register_schemas/1: #{inspect(other)}"
    )

    {:error, {:invalid_return, other}}
  end

  defp upsert_one(plugin_name, %SchemaDefinition{} = schema) do
    attrs =
      schema
      |> Map.from_struct()
      |> Map.drop(@drop_keys)

    dataset = Map.get(attrs, :dataset) || "production"

    case Content.upsert_schema(attrs, dataset) do
      {:ok, %SchemaDefinition{} = saved} ->
        Logger.info(
          "Plugins.Bootstrap: registered schema #{inspect(saved.name)} (dataset=#{inspect(saved.dataset)}, visibility=#{inspect(saved.visibility)}) from plugin #{inspect(plugin_name)}"
        )

        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning(
          "Plugins.Bootstrap: upsert_schema failed for plugin #{inspect(plugin_name)} schema #{inspect(Map.get(attrs, :name))}: #{inspect(changeset.errors)}"
        )

        {:error, {:changeset, changeset.errors}}
    end
  end

  defp upsert_one(plugin_name, other) do
    Logger.warning(
      "Plugins.Bootstrap: plugin #{inspect(plugin_name)} register_schemas/1 returned non-SchemaDefinition entry: #{inspect(other)} — skipping"
    )

    {:error, {:invalid_entry, other}}
  end
end
