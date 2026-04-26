defmodule Barkpark.Validation.PluginCheckerLoader do
  @moduledoc """
  Bridges Phase 2's plugin contract to Phase 3's validation registry.

  On boot (or whenever invoked), walks every plugin registered with
  `Barkpark.Plugins.Registry`, calls each plugin module's optional
  `checkers/0` callback, and registers each `{name, module}` entry under
  the namespaced key `"plugin:<plugin_name>:<name>"` in
  `Barkpark.Validation.Registry`.

  Idempotent — running a second time silently re-registers each checker
  (last writer wins). Plugins that don't export `checkers/0` (or return
  an empty list) contribute nothing.
  """

  require Logger

  alias Barkpark.Plugins.Registry, as: PluginRegistry
  alias Barkpark.Validation.Registry, as: ValidationRegistry

  @doc """
  Load checkers from every plugin currently registered in
  `Barkpark.Plugins.Registry`.

  Returns the list of registered names, in iteration order.
  """
  @spec load_all() :: [String.t()]
  def load_all do
    PluginRegistry.all()
    |> Enum.flat_map(&load_plugin/1)
  end

  @doc """
  Load checkers from a single plugin entry (the shape returned by
  `Barkpark.Plugins.Registry.all/0`).
  """
  @spec load_plugin(map()) :: [String.t()]
  def load_plugin(%{module: module, name: plugin_name}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :checkers, 0) do
      module.checkers()
      |> List.wrap()
      |> Enum.flat_map(&register_checker(plugin_name, &1))
    else
      []
    end
  end

  def load_plugin(_), do: []

  # ── Internals ──────────────────────────────────────────────────────────

  defp register_checker(plugin_name, {name, module})
       when is_binary(name) and is_atom(module) do
    full_name = "plugin:#{plugin_name}:#{name}"

    case ValidationRegistry.register(full_name, module) do
      :ok ->
        [full_name]

      {:error, reason} ->
        Logger.warning(
          "Barkpark.Validation.PluginCheckerLoader: skipping #{inspect({plugin_name, name, module})} — #{inspect(reason)}"
        )

        []
    end
  end

  defp register_checker(plugin_name, other) do
    Logger.warning(
      "Barkpark.Validation.PluginCheckerLoader: invalid checker entry from plugin #{inspect(plugin_name)}: #{inspect(other)}"
    )

    []
  end
end
