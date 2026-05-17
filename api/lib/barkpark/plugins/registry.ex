defmodule Barkpark.Plugins.Registry do
  @moduledoc """
  Boot-time registry of `use Barkpark.Plugin` modules.

  Populated by `discover_and_register/1` from `Barkpark.Application`'s
  supervisor `start/2` callback. Lookup keyed by `plugin_name` (decision D20).

  Discovery walks two roots by default:

    * `Application.app_dir(:barkpark, "priv/plugins")` — bundled plugins
    * `Mix.Project.deps_path/0` — when Mix is loaded (dev/test)

  Each subdirectory containing a `plugin.json` is treated as a plugin. The
  module to register is derived from the manifest's `module` field if
  present, otherwise from `plugin_name` (PascalCased under
  `Barkpark.Plugins.<Name>`). Modules that fail to load are logged and
  skipped — discovery NEVER raises.
  """

  use GenServer
  require Logger

  @name __MODULE__

  # ─── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec register(module(), map()) :: :ok | {:error, :no_plugin_name}
  def register(module, manifest) when is_atom(module) and is_map(manifest) do
    GenServer.call(@name, {:register, module, manifest})
  end

  @spec lookup(String.t()) ::
          {:ok, %{module: module(), manifest: map(), name: String.t()}} | :error
  def lookup(plugin_name) when is_binary(plugin_name) do
    GenServer.call(@name, {:lookup, plugin_name})
  end

  @spec all() :: [%{module: module(), manifest: map(), name: String.t()}]
  def all do
    GenServer.call(@name, :all)
  end

  @doc """
  Walks every registered plugin, calls `action_handlers/0`, and merges the
  results into a single `%{action_name => handler_fn}` map.

  Iteration order is alphabetical by plugin name so collisions are
  resolved deterministically — the lexicographically latest plugin wins.

  Plugins that don't implement the optional callback (or whose callback
  raises) contribute nothing.
  """
  @spec collect_action_handlers() :: %{optional(String.t()) => Barkpark.Plugin.action_handler()}
  def collect_action_handlers do
    all()
    |> Enum.sort_by(& &1.name)
    |> Enum.reduce(%{}, fn entry, acc ->
      handlers = safe_call(entry.module, :action_handlers, [], %{})
      if is_map(handlers), do: Map.merge(acc, handlers), else: acc
    end)
  end

  @doc """
  Walks every registered plugin, calls `external_sync_entries/0`, and
  merges the resulting registry maps into one.

  Iteration order is alphabetical by plugin name. On collision, the
  lexicographically latest plugin wins — host-side entries (passed in
  via `merge_into/1`) take precedence over plugin-supplied keys.

  Plugins that don't implement the optional callback (or whose callback
  raises) contribute nothing.
  """
  @spec collect_external_sync_entries() :: %{optional(String.t()) => map()}
  def collect_external_sync_entries do
    all()
    |> Enum.sort_by(& &1.name)
    |> Enum.reduce(%{}, fn entry, acc ->
      entries = safe_call(entry.module, :external_sync_entries, [], %{})
      if is_map(entries), do: Map.merge(acc, entries), else: acc
    end)
  end

  @doc """
  Walks every registered plugin, calls `codelist_seeders/0` to get a
  list of zero-arg functions, and invokes each one in registration
  order (alphabetical by plugin name).

  Each seeder is wrapped in `try/rescue` so one failing plugin's seeder
  doesn't abort the rest. Failures log a warning. Returns `:ok` always.
  """
  @spec run_all_codelist_seeders() :: :ok
  def run_all_codelist_seeders do
    all()
    |> Enum.sort_by(& &1.name)
    |> Enum.each(fn entry ->
      seeders = safe_call(entry.module, :codelist_seeders, [], [])

      if is_list(seeders) do
        Enum.each(seeders, fn seeder ->
          try do
            cond do
              is_function(seeder, 0) -> seeder.()
              true -> :noop
            end
          rescue
            e ->
              Logger.warning(
                "Barkpark.Plugins.Registry: codelist seeder #{inspect(seeder)} from plugin " <>
                  "#{entry.name} raised — #{Exception.message(e)}"
              )
          catch
            kind, reason ->
              Logger.warning(
                "Barkpark.Plugins.Registry: codelist seeder #{inspect(seeder)} from plugin " <>
                  "#{entry.name} threw #{kind} #{inspect(reason)}"
              )
          end
        end)
      end
    end)

    :ok
  end

  # Invoke `module.function(args)` only when exported. Errors / non-export
  # fall back to the supplied default. Centralised so all three collectors
  # share the same defensive shape.
  defp safe_call(module, fun, args, default) do
    try do
      if Code.ensure_loaded?(module) and function_exported?(module, fun, length(args)) do
        apply(module, fun, args)
      else
        default
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry: #{inspect(module)}.#{fun}/#{length(args)} raised — " <>
            Exception.message(e)
        )

        default
    end
  end

  @doc """
  Walks the default discovery roots and registers every plugin found.

  Safe to call once during boot; logs warnings (never raises) on per-plugin
  errors.
  """
  @spec discover_and_register() :: :ok
  def discover_and_register, do: discover_and_register(default_paths())

  @doc """
  Walks the given list of root directories and registers every plugin found.

  Each root is scanned non-recursively for immediate subdirectories
  containing a `plugin.json`. Useful in tests with an explicit fixture
  root.
  """
  @spec discover_and_register([Path.t()]) :: :ok
  def discover_and_register(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.each(&try_register_plugin_dir/1)

    :ok
  end

  # ─── Discovery internals ────────────────────────────────────────────────

  defp default_paths do
    bundled = Application.app_dir(:barkpark, "priv/plugins")

    deps =
      if Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :deps_path, 0) do
        try do
          [Mix.Project.deps_path()]
        rescue
          _ -> []
        end
      else
        []
      end

    [bundled | deps]
  end

  defp plugin_dirs_in(root) do
    case File.ls(root) do
      {:ok, entries} ->
        for entry <- entries,
            dir = Path.join(root, entry),
            File.dir?(dir),
            File.exists?(Path.join(dir, "plugin.json")),
            do: dir

      _ ->
        []
    end
  end

  defp try_register_plugin_dir(dir) do
    manifest_path = Path.join(dir, "plugin.json")

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         {:ok, module} <- resolve_module(manifest),
         true <- Code.ensure_loaded?(module) || {:module_not_loaded, module} do
      register(module, manifest)
    else
      reason ->
        Logger.warning("Barkpark.Plugins.Registry: skipping #{inspect(dir)} — #{inspect(reason)}")

        :error
    end
  end

  defp resolve_module(%{"module" => mod}) when is_binary(mod) and mod != "" do
    {:ok, Module.concat([mod])}
  end

  defp resolve_module(%{"plugin_name" => name}) when is_binary(name) and name != "" do
    pascal =
      name
      |> String.split(~r/[_\-\s]+/, trim: true)
      |> Enum.map_join("", &Macro.camelize/1)

    {:ok, Module.concat([Barkpark, Plugins, pascal])}
  end

  defp resolve_module(_), do: {:error, :no_plugin_name}

  # ─── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{plugins: %{}}}
  end

  @impl true
  def handle_call({:register, module, manifest}, _from, state) do
    case manifest["plugin_name"] do
      name when is_binary(name) and name != "" ->
        entry = %{name: name, module: module, manifest: manifest}
        {:reply, :ok, %{state | plugins: Map.put(state.plugins, name, entry)}}

      _ ->
        {:reply, {:error, :no_plugin_name}, state}
    end
  end

  def handle_call({:lookup, name}, _from, state) do
    case Map.fetch(state.plugins, name) do
      {:ok, entry} -> {:reply, {:ok, entry}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:all, _from, state) do
    {:reply, Map.values(state.plugins), state}
  end
end
