defmodule Barkpark.MigrationPathsFixture do
  @moduledoc """
  Builds a throwaway `priv` tree in the system tmp dir for the
  `Barkpark.MigrationPaths` tests: a core `repo/migrations` directory plus
  optional plugin and capability folders, each holding one migration that
  creates a uniquely named table.

  Nothing here ships: the tree lives under `System.tmp_dir!/0` and the caller
  removes it with `cleanup/1`.
  """

  @doc """
  Create the tree and return `%{priv_root, plugin_dir, table, version}`.

  Options:

    * `:core` - `:empty` (default) makes an empty core directory; a path makes
      `repo/migrations` a symlink to it, so a migrate run over the real core
      finds every core version already applied.
    * `:plugin` - the plugin folder name (default `"migfixture"`); `nil` skips it.
    * `:plugin_json` - `true` (default) writes `plugin.json`.
    * `:capabilities` - capability names to give a migrations folder.
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    n = System.unique_integer([:positive])
    priv_root = Path.join(System.tmp_dir!(), "bp-migpaths-#{n}")
    File.mkdir_p!(Path.join(priv_root, "repo"))

    case Keyword.get(opts, :core, :empty) do
      :empty -> File.mkdir_p!(Path.join(priv_root, "repo/migrations"))
      real when is_binary(real) -> File.ln_s!(real, Path.join(priv_root, "repo/migrations"))
    end

    table = "migpaths_fixture_#{n}"
    version = 29_990_101_000_000 + rem(n, 1_000_000)

    plugin_dir =
      case Keyword.get(opts, :plugin, "migfixture") do
        nil ->
          nil

        name ->
          dir = Path.join([priv_root, "plugins", name])
          File.mkdir_p!(Path.join(dir, "migrations"))

          if Keyword.get(opts, :plugin_json, true) do
            File.write!(Path.join(dir, "plugin.json"), ~s({"plugin_name": "#{name}"}))
          end

          write_migration(Path.join(dir, "migrations"), version, table, n)
          Path.join(dir, "migrations")
      end

    for cap <- Keyword.get(opts, :capabilities, []) do
      dir = Path.join([priv_root, "capabilities", to_string(cap), "migrations"])
      File.mkdir_p!(dir)
      write_migration(dir, version + 1, "#{table}_#{cap}", n)
    end

    %{priv_root: priv_root, plugin_dir: plugin_dir, table: table, version: version}
  end

  @spec cleanup(map()) :: :ok
  def cleanup(%{priv_root: priv_root}) do
    File.rm_rf!(priv_root)
    :ok
  end

  defp write_migration(dir, version, table, n) do
    File.write!(Path.join(dir, "#{version}_create_#{table}.exs"), """
    defmodule Barkpark.MigrationPathsFixture.Create#{Macro.camelize(table)}#{n} do
      use Ecto.Migration

      def change do
        create table(:#{table}, primary_key: false) do
          add :id, :integer
        end
      end
    end
    """)
  end
end
