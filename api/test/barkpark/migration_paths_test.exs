defmodule Barkpark.MigrationPathsTest do
  @moduledoc """
  `Barkpark.MigrationPaths.enabled/1` against tmp-dir fixture trees: which
  plugin and capability migration folders a migrate run reads under each
  setting of `BARKPARK_PLUGINS` (the `:plugins` switch) and
  `BARKPARK_CAPABILITIES_OFF` (`Barkpark.Capability`).
  """

  # async: false — two tests change `:barkpark, :plugins` and the
  # `Barkpark.Capability` config to prove enabled/0 reads them.
  use ExUnit.Case, async: false

  alias Barkpark.MigrationPaths
  alias Barkpark.MigrationPathsFixture, as: Fixture
  alias Barkpark.Plugins.EnvConfig

  setup do
    fx = Fixture.build(capabilities: [:studio_chat, :cycle_fleet])
    on_exit(fn -> Fixture.cleanup(fx) end)
    core = Path.join(fx.priv_root, "repo/migrations")
    cap = &Path.join([fx.priv_root, "capabilities", &1, "migrations"])
    {:ok, fx: fx, core: core, studio_chat: cap.("studio_chat"), cycle_fleet: cap.("cycle_fleet")}
  end

  defp enabled(fx, opts) do
    MigrationPaths.enabled(
      [priv_root: fx.priv_root, capability_enabled?: fn _ -> true end] ++ opts
    )
  end

  describe "BARKPARK_PLUGINS" do
    test "unset: every plugin folder on disk is read", %{fx: fx, core: core} = ctx do
      assert EnvConfig.parse(nil) == :unset

      assert enabled(fx, plugins: :unset) ==
               [core, fx.plugin_dir, ctx.cycle_fleet, ctx.studio_chat]
    end

    test "empty string: the kill switch reads no plugin folder", %{fx: fx, core: core} = ctx do
      assert enabled(fx, plugins: EnvConfig.parse("")) ==
               [core, ctx.cycle_fleet, ctx.studio_chat]
    end

    test "a whitelist reads only the named plugins", %{fx: fx, core: core} = ctx do
      assert enabled(fx, plugins: EnvConfig.parse("migfixture")) ==
               [core, fx.plugin_dir, ctx.cycle_fleet, ctx.studio_chat]

      # EnvConfig unions "media" into every whitelist; the fixture is still out.
      assert enabled(fx, plugins: EnvConfig.parse("bulldocs")) ==
               [core, ctx.cycle_fleet, ctx.studio_chat]
    end

    test "a whitelist accepts {name, module} pairs and module atoms", %{fx: fx} do
      assert fx.plugin_dir in enabled(fx, plugins: [{"migfixture", SomeModule}])
      assert fx.plugin_dir in enabled(fx, plugins: [Barkpark.Plugins.Migfixture])
      refute fx.plugin_dir in enabled(fx, plugins: [Barkpark.Plugins.Other])
    end

    test "enabled/0 reads the :plugins switch that runtime.exs sets", %{fx: fx} do
      # Every load-order SETTER goes through Barkpark.PluginEnv (the
      # plugin_order_setter_guard_test census); capture/restore puts absence
      # back as absence, never as [].
      prior = Barkpark.PluginEnv.capture()
      on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

      Barkpark.PluginEnv.put!([])
      refute fx.plugin_dir in MigrationPaths.enabled(priv_root: fx.priv_root)

      # Unset (the discover-everything default) is the :unset snapshot.
      Barkpark.PluginEnv.restore(:unset)
      assert fx.plugin_dir in MigrationPaths.enabled(priv_root: fx.priv_root)
    end
  end

  describe "BARKPARK_CAPABILITIES_OFF" do
    test "an OFF capability's folder is not read", %{fx: fx, core: core} = ctx do
      off = Keyword.keys(Barkpark.Capability.parse_off_list("studio_chat"))

      assert MigrationPaths.enabled(
               priv_root: fx.priv_root,
               plugins: :unset,
               capability_enabled?: &(&1 not in off)
             ) == [core, fx.plugin_dir, ctx.cycle_fleet]
    end

    test "enabled/0 reads Barkpark.Capability, including dependencies", %{fx: fx} = ctx do
      previous = Application.fetch_env(:barkpark, Barkpark.Capability)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:barkpark, Barkpark.Capability, value)
          :error -> Application.delete_env(:barkpark, Barkpark.Capability)
        end
      end)

      # cycle_fleet requires epic_fleet, so turning epic_fleet off drops the
      # cycle_fleet folder too.
      Application.put_env(
        :barkpark,
        Barkpark.Capability,
        Barkpark.Capability.parse_off_list("epic_fleet")
      )

      dirs = MigrationPaths.enabled(priv_root: fx.priv_root, plugins: :unset)
      refute ctx.cycle_fleet in dirs
      assert ctx.studio_chat in dirs
    end
  end

  describe "folder convention" do
    test "a folder without plugin.json is not a plugin and is never read" do
      fx = Fixture.build(plugin: "nomanifest", plugin_json: false)
      on_exit(fn -> Fixture.cleanup(fx) end)

      assert MigrationPaths.enabled(priv_root: fx.priv_root, plugins: :unset) ==
               [Path.join(fx.priv_root, "repo/migrations")]

      # It still exists on disk, so the static checks (MANIFEST, collisions) see it.
      assert fx.plugin_dir in MigrationPaths.all(priv_root: fx.priv_root)
    end

    test "with no plugin or capability folder the set is the core directory alone" do
      fx = Fixture.build(plugin: nil)
      on_exit(fn -> Fixture.cleanup(fx) end)
      core = Path.join(fx.priv_root, "repo/migrations")

      assert MigrationPaths.enabled(priv_root: fx.priv_root, plugins: :unset) == [core]
      assert MigrationPaths.all(priv_root: fx.priv_root) == [core]
      assert MigrationPaths.extra(priv_root: fx.priv_root) == []
    end

    test "the default core entry is the directory Ecto.Migrator.run/3 reads" do
      assert hd(MigrationPaths.enabled()) == Ecto.Migrator.migrations_path(Barkpark.Repo)
    end
  end
end
