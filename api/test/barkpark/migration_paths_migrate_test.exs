defmodule Barkpark.MigrationPathsMigrateTest do
  @moduledoc """
  A fixture plugin migration under `priv/plugins/<name>/migrations` runs when
  the plugin is enabled and is skipped when it is disabled, through both
  migrate paths:

    * `Barkpark.Release.migrate/1`, the body `bin/barkpark eval` runs. Only
      `Ecto.Migrator.with_repo/3` is replaced, because it would restart the
      running test repo.
    * `mix ecto.migrate`, which `api/mix.exs` aliases to
      `Mix.Tasks.Barkpark.Migrate`. The task's real argument list goes through
      ecto's own path reader (`Mix.EctoSQL.ensure_migrations_paths/2`) into
      `Ecto.Migrator.run/4`; only the repo start/stop is left out.

  The fixture tree lives in the system tmp dir with `repo/migrations` symlinked
  to the real core directory, so every core version is already applied and the
  fixture migration is the only pending one. Everything runs inside the test's
  sandbox transaction (DataCase shared mode) and is rolled back.
  `migration_lock: false` keeps the migrator's task from waiting on the
  connection the test already holds (see
  test/barkpark/repo/migrations/codelist_issue_version_test.exs).
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.MigrationPathsFixture, as: Fixture
  alias Barkpark.Repo

  @migrator_opts [log: false, migration_lock: false]

  setup do
    fx = Fixture.build(core: Ecto.Migrator.migrations_path(Repo))
    on_exit(fn -> Fixture.cleanup(fx) end)
    {:ok, fx: fx}
  end

  defp applied?(fx) do
    table? = Repo.query!("SELECT to_regclass($1)", [fx.table]).rows != [[nil]]

    row? =
      Repo.query!("SELECT 1 FROM schema_migrations WHERE version = $1", [fx.version]).rows != []

    # The table and the version row move together or the run is not what it
    # claims to be.
    assert table? == row?
    table?
  end

  defp release_migrate(fx, plugins) do
    in_process = fn repo, fun, _opts -> {:ok, fun.(repo), []} end

    Barkpark.Release.migrate(
      [with_repo: in_process, priv_root: fx.priv_root, plugins: plugins] ++ @migrator_opts
    )
  end

  # What `Mix.Tasks.Ecto.Migrate.run/2` does with its argv, minus with_repo.
  defp ecto_migrate_in_process(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [migrations_path: :keep, quiet: :boolean])
    paths = Mix.EctoSQL.ensure_migrations_paths(Repo, opts)
    Ecto.Migrator.run(Repo, paths, :up, [all: true] ++ @migrator_opts)
  end

  defp mix_migrate(fx, plugins) do
    Mix.Tasks.Barkpark.Migrate.run(
      ["--quiet"],
      &ecto_migrate_in_process/1,
      priv_root: fx.priv_root,
      plugins: plugins
    )
  end

  describe "Release.migrate" do
    test "runs the fixture migration when the plugin is enabled", %{fx: fx} do
      refute applied?(fx)
      release_migrate(fx, :unset)
      assert applied?(fx)
    end

    test "runs it when a whitelist names the plugin", %{fx: fx} do
      release_migrate(fx, ["migfixture", "media"])
      assert applied?(fx)
    end

    test "skips it when BARKPARK_PLUGINS is empty", %{fx: fx} do
      release_migrate(fx, [])
      refute applied?(fx)
    end

    test "skips it when the whitelist leaves the plugin out", %{fx: fx} do
      release_migrate(fx, ["bulldocs", "media"])
      refute applied?(fx)
    end
  end

  describe "mix ecto.migrate" do
    test "runs the fixture migration when the plugin is enabled", %{fx: fx} do
      refute applied?(fx)
      assert mix_migrate(fx, :unset) == [fx.version]
      assert applied?(fx)
    end

    test "skips it when BARKPARK_PLUGINS is empty", %{fx: fx} do
      assert mix_migrate(fx, []) == []
      refute applied?(fx)
    end

    test "skips it when the whitelist leaves the plugin out", %{fx: fx} do
      assert mix_migrate(fx, ["bulldocs", "media"]) == []
      refute applied?(fx)
    end
  end

  describe "Status.migration_state" do
    test "reads the directory set the migrator runs" do
      assert Barkpark.Status.migration_state() ==
               Barkpark.Status.migration_state(Barkpark.MigrationPaths.enabled())
    end

    test "counts an enabled plugin folder's unapplied migration as pending", %{fx: fx} do
      core = Ecto.Migrator.migrations_path(Repo)

      assert %{pending: 0} = Barkpark.Status.migration_state([core])
      assert %{pending: 1} = Barkpark.Status.migration_state([core, fx.plugin_dir])
    end
  end

  describe "the ecto.migrate argument list" do
    alias Mix.Tasks.Barkpark.Migrate

    test "is unchanged when only the core directory is enabled", %{fx: fx} do
      assert Migrate.migrate_args(["--quiet"], priv_root: fx.priv_root, plugins: []) ==
               ["--quiet"]
    end

    test "is unchanged when the caller names --migrations-path", %{fx: fx} do
      argv = ["--migrations-path", "somewhere"]
      assert Migrate.migrate_args(argv, priv_root: fx.priv_root, plugins: :unset) == argv

      assert Migrate.migrate_args(["--migrations-path=x"], priv_root: fx.priv_root) == [
               "--migrations-path=x"
             ]
    end

    test "names core first, then each enabled folder", %{fx: fx} do
      assert Migrate.migrate_args(["--quiet"], priv_root: fx.priv_root, plugins: :unset) == [
               "--quiet",
               "--migrations-path",
               Path.join(fx.priv_root, "repo/migrations"),
               "--migrations-path",
               fx.plugin_dir
             ]
    end

    test "the default root gives the core directory ecto.migrate reads by default" do
      assert Barkpark.MigrationPaths.core_dir(Path.dirname(Mix.EctoSQL.source_repo_priv(Repo))) ==
               Path.join(Mix.EctoSQL.source_repo_priv(Repo), "migrations")
    end
  end
end
