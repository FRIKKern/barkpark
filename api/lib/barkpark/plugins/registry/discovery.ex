defmodule Barkpark.Plugins.Registry.Discovery do
  @moduledoc """
  Disk discovery + manifest→module resolution for `Barkpark.Plugins.Registry`.

  Extracted (Goal modularity-registry) as a behavior-preserving facade split:
  the public `Barkpark.Plugins.Registry.{discover_and_register,resolve_module}`
  functions delegate here. Boot order, kill-switch semantics, and per-plugin
  error isolation are unchanged — this is module location only, NO logic change.

  Discovery walks two roots by default:

    * `Application.app_dir(:barkpark, "priv/plugins")` — bundled plugins
    * `Mix.Project.deps_path/0` — when Mix is loaded (dev/test)

  Each subdirectory containing a `plugin.json` is treated as a plugin. The
  module to register is derived from the manifest's `module` field if present,
  otherwise from `plugin_name` (PascalCased under `Barkpark.Plugins.<Name>`).
  Modules that fail to load are logged and skipped — discovery NEVER raises.
  """

  require Logger

  alias Barkpark.Plugins.Registry

  @doc """
  Walks the default discovery roots and registers every plugin found.

  Safe to call once during boot; logs warnings (never raises) on per-plugin
  errors.

  ## `:plugins` env interaction (Goal barkpark-G5 task s2)

  The Application env `:barkpark, :plugins` is the kill switch — this
  zero-arg head MUST respect it so the fresh-install invariant locked by
  `plugin_free_boot_test.exs` holds end-to-end:

    * `:unset` (env absent) — disk discovery proceeds as before.
      Production default; fresh installs fold bundled plugins in.
    * `[]` (explicit empty list) — short-circuit: nothing is registered.
      This is the kill switch. `Application.put_env(:barkpark, :plugins, [])`
      followed by `Application.ensure_all_started(:barkpark)` boots a
      plugin-free Barkpark.
    * `[<plugin_name>, …]` (non-empty list) — whitelist mode: walk disk
      but only register plugins whose `plugin_name` matches an entry in
      the list. Module atoms and `{name, module}` tuples are accepted
      and normalised to their string `plugin_name` for the match.

  The explicit-paths arity (`discover_and_register/1`) is the unconditional
  variant used by tests with a fixture root — it does NOT consult the env.
  """
  @spec discover_and_register() :: :ok
  def discover_and_register do
    case Application.get_env(:barkpark, :plugins, :unset) do
      [] ->
        # Explicit empty list = kill switch. Load nothing.
        :ok

      :unset ->
        # No env set = discover from disk (production / fresh-install default).
        discover_and_register(default_paths())

      configured when is_list(configured) ->
        # Whitelist: walk disk but only register plugins on the list.
        # Build a name-only whitelist; module / `{name, module}` entries
        # are normalised to their plugin_name by reading the manifest off
        # disk so we never depend on the (not-yet-populated) GenServer
        # state during boot.
        whitelist = whitelist_names_from_config(configured)
        discover_and_register(default_paths(), whitelist)

      _other ->
        # Defensive: a non-list value (someone misconfigured) falls back
        # to disk discovery rather than silently swallowing.
        discover_and_register(default_paths())
    end

    # Eagerly freeze the post-discovery plugin set as the reset baseline.
    # Must come AFTER the inner discover_and_register variants above have
    # finished registering plugins, so the baseline captures the real boot
    # set — not an empty map and not a test-stub-polluted set.
    # Idempotent: a second call is a no-op (baseline already frozen).
    Registry.capture_baseline()
  end

  @doc """
  Walks the given list of root directories and registers every plugin found.

  Each root is scanned non-recursively for immediate subdirectories
  containing a `plugin.json`. Useful in tests with an explicit fixture
  root. Unlike the zero-arg head, this variant does NOT consult the
  `:plugins` env — callers that want the kill switch use `discover_and_register/0`.
  """
  @spec discover_and_register([Path.t()]) :: :ok
  def discover_and_register(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.each(&try_register_plugin_dir/1)

    :ok
  end

  # Whitelist-aware discovery: same disk walk as the public arity but only
  # registers plugins whose manifest `plugin_name` is in `whitelist`.
  defp discover_and_register(paths, %MapSet{} = whitelist) when is_list(paths) do
    paths
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.each(&try_register_plugin_dir_in_whitelist(&1, whitelist))

    :ok
  end

  # Normalise the :plugins env to a MapSet of plugin_name strings.
  # Accepts binary names, `{name, module}` tuples, and bare module atoms.
  # Module atoms are reverse-mapped by reading every plugin.json on disk
  # — we cannot consult the live Registry here because this runs during
  # boot, before discovery has populated state.
  defp whitelist_names_from_config(configured) do
    name_set =
      configured
      |> Enum.flat_map(fn
        name when is_binary(name) -> [name]
        {name, _module} when is_binary(name) -> [name]
        module when is_atom(module) and not is_nil(module) -> manifest_names_for_module(module)
        _ -> []
      end)
      |> MapSet.new()

    name_set
  end

  defp manifest_names_for_module(module) do
    default_paths()
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.flat_map(fn dir ->
      with {:ok, raw} <- File.read(Path.join(dir, "plugin.json")),
           {:ok, manifest} <- Jason.decode(raw),
           {:ok, ^module} <- resolve_module(manifest),
           name when is_binary(name) and name != "" <- manifest["plugin_name"] do
        [name]
      else
        _ -> []
      end
    end)
  end

  defp try_register_plugin_dir_in_whitelist(dir, whitelist) do
    manifest_path = Path.join(dir, "plugin.json")

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         name when is_binary(name) and name != "" <- manifest["plugin_name"],
         true <- MapSet.member?(whitelist, name) || :not_whitelisted,
         {:ok, module} <- resolve_module(manifest),
         true <- Code.ensure_loaded?(module) || {:module_not_loaded, module} do
      Registry.register(module, manifest)
    else
      :not_whitelisted ->
        Logger.debug(
          "Barkpark.Plugins.Registry: skipping #{inspect(dir)} — not in :plugins whitelist"
        )

        :error

      reason ->
        Logger.warning("Barkpark.Plugins.Registry: skipping #{inspect(dir)} — #{inspect(reason)}")

        :error
    end
  end

  # ─── Discovery internals ────────────────────────────────────────────────

  @doc false
  @spec default_paths() :: [Path.t()]
  def default_paths do
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

  @doc false
  @spec plugin_dirs_in(Path.t()) :: [Path.t()]
  def plugin_dirs_in(root) do
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
      Registry.register(module, manifest)
    else
      reason ->
        Logger.warning("Barkpark.Plugins.Registry: skipping #{inspect(dir)} — #{inspect(reason)}")

        :error
    end
  end

  @doc """
  Resolves the Elixir module a manifest maps to.

  Prefers an explicit `"module"` key; otherwise derives
  `Barkpark.Plugins.<Pascal>` from `"plugin_name"` (per-segment
  `Macro.camelize`). Returns `{:ok, module}` or `{:error, :no_plugin_name}`.

  Public so the plugin generator's test can assert that the manifest it
  emits resolves to the module its generated `lib/` file defines — the
  exact discovery match that was previously broken.
  """
  @spec resolve_module(map()) :: {:ok, module()} | {:error, :no_plugin_name}
  def resolve_module(%{"module" => mod}) when is_binary(mod) and mod != "" do
    {:ok, Module.concat([mod])}
  end

  def resolve_module(%{"plugin_name" => name}) when is_binary(name) and name != "" do
    pascal =
      name
      |> String.split(~r/[_\-\s]+/, trim: true)
      |> Enum.map_join("", &Macro.camelize/1)

    {:ok, Module.concat([Barkpark, Plugins, pascal])}
  end

  def resolve_module(_), do: {:error, :no_plugin_name}
end
