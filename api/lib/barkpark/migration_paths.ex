defmodule Barkpark.MigrationPaths do
  @moduledoc """
  The migration directories a migrate run applies: the core directory plus the
  migrations folder of every plugin and capability that is switched on for this
  instance.

  ## Where plugin migrations live

  A plugin keeps its migrations in a folder next to its manifest:

      priv/plugins/<name>/migrations/<version>_<name>.exs

  A capability (`Barkpark.Capability`, the non-plugin subsystems) uses the same
  shape under its own root:

      priv/capabilities/<capability>/migrations/<version>_<name>.exs

  This is a folder convention, not a `Barkpark.Plugin` callback. The migrator
  runs without starting the application, so it cannot ask a plugin module
  anything; it can only read the disk and the configuration.

  ## What switches a folder on

  Only the two instance-wide switches that exist before the app starts:

    * `BARKPARK_PLUGINS`, which `config/runtime.exs` turns into
      `config :barkpark, :plugins` (`Barkpark.Plugins.EnvConfig`). Unset means
      every plugin on disk, `""` means none, and a list is a whitelist matched
      against the manifest's `plugin_name`. This is the same rule
      `Barkpark.Plugins.Registry.Discovery.discover_and_register/0` applies at
      boot, so the tables a plugin needs exist exactly when the plugin loads.
    * `BARKPARK_CAPABILITIES_OFF`, read through `Barkpark.Capability.enabled?/1`,
      which also honours a capability's dependencies.

  Per-workspace enablement (`Barkpark.Plugins.Enablement`) is deliberately not
  consulted. Tables are instance-wide: a workspace that hides a plugin still
  shares the database with a workspace that shows it.

  ## Who reads this

  Every place that runs or checks migrations reads one of the two functions
  here, so they cannot disagree about the directory set:

    * `enabled/1`: `Barkpark.Release.migrate/0`, the `mix ecto.migrate` alias
      (`Mix.Tasks.Barkpark.Migrate`), `Barkpark.MigrationIntegrity` and
      `Barkpark.Status.migration_state/1`.
    * `all/1`: the migration MANIFEST test. A file that is switched off on this
      box is switched on elsewhere, so an in-place edit to it is still a hazard.
      `scripts/migration-version-collision-check.sh` applies the same folder
      rule in shell.

  With no plugin or capability folder holding a `migrations` directory, both
  return exactly `[core]`, which is the single directory every migrate path used
  before this module existed.
  """

  alias Barkpark.Plugins.Registry.Discovery

  @doc """
  The directories to migrate, core first, then enabled plugin folders sorted by
  plugin name, then enabled capability folders sorted by capability name. Only
  existing directories are returned.

  Options (defaults read the running configuration):

    * `:priv_root` - the `priv` directory to read (default: the app's `priv`)
    * `:plugins` - the `:plugins` switch value (default:
      `Application.get_env(:barkpark, :plugins, :unset)`)
    * `:capability_enabled?` - a one-argument predicate over capability names
      (default: `&Barkpark.Capability.enabled?/1`)
  """
  @spec enabled(keyword()) :: [Path.t()]
  def enabled(opts \\ []) do
    priv_root = priv_root(opts)
    plugins = Keyword.get_lazy(opts, :plugins, &plugins_switch/0)
    capability_enabled? = Keyword.get(opts, :capability_enabled?, &Barkpark.Capability.enabled?/1)

    plugin_dirs =
      for {name, manifest, dir} <- plugin_folders(priv_root),
          plugin_enabled?(name, manifest, plugins),
          do: dir

    capability_dirs =
      for {name, dir} <- capability_folders(priv_root),
          capability_enabled?.(name),
          do: dir

    [core_dir_for(opts, priv_root) | plugin_dirs ++ capability_dirs]
  end

  # With no explicit `:priv_root`, the core directory is the one Ecto itself
  # reads, `Ecto.Migrator.migrations_path(Barkpark.Repo)`, which honours the
  # repo's `:priv` config. Rebuilding it from `Application.app_dir(:barkpark,
  # "priv")` matched only while `:priv` was unset: a repo configured with its
  # own `:priv` (the release statement_timeout probe does exactly that) had its
  # migrations silently skipped. Plugin and capability folders stay under the
  # app's priv root.
  defp core_dir_for(opts, priv_root) do
    if Keyword.has_key?(opts, :priv_root),
      do: core_dir(priv_root),
      else: Ecto.Migrator.migrations_path(Barkpark.Repo)
  end

  @doc """
  Every migrations directory on disk, whatever the switches say: core, every
  `priv/plugins/*/migrations` and every `priv/capabilities/*/migrations`.
  Takes the `:priv_root` option.
  """
  @spec all(keyword()) :: [Path.t()]
  def all(opts \\ []) do
    priv_root = priv_root(opts)
    [core_dir(priv_root) | folders(priv_root, "plugins") ++ folders(priv_root, "capabilities")]
  end

  @doc "The core migrations directory under `priv_root`."
  @spec core_dir(Path.t()) :: Path.t()
  def core_dir(priv_root), do: Path.join([priv_root, "repo", "migrations"])

  @doc """
  The directories `enabled/1` returns beyond core. Empty means a migrate run
  reads the core directory alone.
  """
  @spec extra(keyword()) :: [Path.t()]
  def extra(opts \\ []), do: opts |> enabled() |> tl()

  # The default priv root is the one Ecto reads: `Ecto.Migrator.migrations_path/1`
  # is `Application.app_dir(:barkpark, "priv/repo/migrations")` for this repo,
  # so `core_dir(priv_root())` is byte-for-byte the directory
  # `Ecto.Migrator.run/3` used before this module existed.
  defp priv_root(opts) do
    Keyword.get_lazy(opts, :priv_root, fn -> Application.app_dir(:barkpark, "priv") end)
  end

  defp plugins_switch, do: Application.get_env(:barkpark, :plugins, :unset)

  # A plugin folder counts only when it holds a plugin.json with a non-empty
  # `plugin_name`, the same test `Registry.Discovery` applies before it
  # registers a plugin. A folder Discovery would skip must not migrate either.
  defp plugin_folders(priv_root) do
    root = Path.join(priv_root, "plugins")

    for name <- sorted_entries(root),
        plugin_dir <- [Path.join(root, name)],
        migrations <- [Path.join(plugin_dir, "migrations")],
        File.dir?(migrations),
        {:ok, %{"plugin_name" => plugin_name} = manifest} <- [read_manifest(plugin_dir)],
        is_binary(plugin_name) and plugin_name != "" do
      {plugin_name, manifest, migrations}
    end
  end

  defp capability_folders(priv_root) do
    root = Path.join(priv_root, "capabilities")
    known = Map.new(Barkpark.Capability.names(), &{Atom.to_string(&1), &1})

    for name <- sorted_entries(root),
        Map.has_key?(known, name),
        migrations <- [Path.join([root, name, "migrations"])],
        File.dir?(migrations) do
      {Map.fetch!(known, name), migrations}
    end
  end

  defp folders(priv_root, kind) do
    root = Path.join(priv_root, kind)

    for name <- sorted_entries(root),
        migrations <- [Path.join([root, name, "migrations"])],
        File.dir?(migrations),
        do: migrations
  end

  defp sorted_entries(root) do
    case File.ls(root) do
      {:ok, names} -> Enum.sort(names)
      {:error, _} -> []
    end
  end

  # The path is a priv root we own plus a directory entry listed under it; no
  # caller-supplied segment reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_manifest(plugin_dir) do
    with {:ok, raw} <- File.read(Path.join(plugin_dir, "plugin.json")),
         {:ok, %{} = manifest} <- Jason.decode(raw) do
      {:ok, manifest}
    else
      _ -> :error
    end
  end

  # The same three shapes `Registry.Discovery` accepts in the `:plugins` switch:
  # `:unset` or a non-list is everything on disk, `[]` is nothing, and a list is
  # a whitelist of plugin names, modules or `{name, module}` pairs.
  defp plugin_enabled?(_name, _manifest, []), do: false

  defp plugin_enabled?(name, manifest, configured) when is_list(configured) do
    module =
      case Discovery.resolve_module(manifest) do
        {:ok, module} -> module
        _ -> nil
      end

    Enum.any?(configured, fn
      entry when is_binary(entry) -> entry == name
      {entry, _module} when is_binary(entry) -> entry == name
      entry when is_atom(entry) and not is_nil(entry) -> entry == module
      _ -> false
    end)
  end

  defp plugin_enabled?(_name, _manifest, _unset), do: true
end
