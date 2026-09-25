defmodule Barkpark.Release do
  @moduledoc "Release tasks (run migrations without Mix)."

  @app :barkpark

  @doc """
  Run every pending migration in the enabled directory set
  (`run_migrations/2`) against each repo, started repo-only by
  `Ecto.Migrator.with_repo/3`.

  `bin/barkpark eval "Barkpark.Release.migrate()"` calls it with no options.
  The options exist for the fixture-plugin test: `:with_repo` replaces
  `Ecto.Migrator.with_repo/3` (a running test repo must not be restarted), and
  the rest goes to `run_migrations/2`.
  """
  def migrate(opts \\ []) do
    load_app()
    {with_repo, run_opts} = Keyword.pop(opts, :with_repo, &Ecto.Migrator.with_repo/3)

    for repo <- repos() do
      {:ok, _, _} =
        with_repo.(
          repo,
          &run_migrations(&1, run_opts),
          # `with_repo/3` starts the repo with the SAME config, so a migration
          # connection would otherwise inherit prod's 30 s `statement_timeout`
          # (config/runtime.exs) — and a backfill or a `CREATE INDEX
          # CONCURRENTLY` that Postgres CANCELS at 30 s leaves an INVALID index
          # behind. A migration is an operator-supervised, offline-shaped step:
          # its bound is the deploy window, not a request budget. These opts are
          # passed through to `repo.start_link/1`, where they REPLACE the
          # `:parameters` from config (nothing else sets that key).
          #
          # NOTE, and it is the load-bearing half: `make deploy` migrates via
          # `mix ecto.migrate` (Makefile), not through this function, so this
          # override does not cover the live path. A long migration must still
          # disable the wall itself — see `Barkpark.Repo`'s @moduledoc for the
          # `repo().checkout` + `SET statement_timeout = 0` shape.
          parameters: [statement_timeout: "0"]
        )
    end
  end

  @doc """
  Apply every pending migration in `Barkpark.MigrationPaths.enabled/1` to
  `repo`: the core directory plus the migrations folder of each plugin and
  capability switched on by `BARKPARK_PLUGINS` and `BARKPARK_CAPABILITIES_OFF`.

  `migrate/1` runs this inside `Ecto.Migrator.with_repo/3`. With no plugin or
  capability folder holding migrations the list is the core directory alone,
  `Ecto.Migrator.migrations_path(repo)`, which is exactly what
  `Ecto.Migrator.run(repo, :up, all: true)` reads.

  `opts` takes the `Barkpark.MigrationPaths` options (`:priv_root`, `:plugins`,
  `:capability_enabled?`); anything else goes to `Ecto.Migrator.run/4`. Tests
  use both; `bin/barkpark eval "Barkpark.Release.migrate()"` passes none.
  """
  @spec run_migrations(Ecto.Repo.t(), keyword()) :: [integer()]
  def run_migrations(repo, opts \\ []) do
    {path_opts, migrator_opts} = Keyword.split(opts, [:priv_root, :plugins, :capability_enabled?])

    Ecto.Migrator.run(
      repo,
      Barkpark.MigrationPaths.enabled(path_opts),
      :up,
      Keyword.put(migrator_opts, :all, true)
    )
  end

  @doc """
  Assert the migrate step actually applied the tree: every migration version in
  the directories `Barkpark.MigrationPaths.enabled/1` returns (the release's
  `priv/repo/migrations` plus any enabled plugin or capability folder) is
  present in `schema_migrations`, and no two files claim the same version.
  Raises, naming the version, otherwise.

  The same `Barkpark.MigrationIntegrity.check/1` the test suite runs — a release
  has no `mix test` alias to migrate for it, so an operator runs this after
  `bin/barkpark eval 'Barkpark.Release.migrate()'`. It is NOT wired into boot:
  a node refusing to start is a worse outcome than a named failure an operator
  reads. Returns the checked/applied counts so the denominator is visible.
  """
  def verify_migrations! do
    load_app()

    for repo <- repos() do
      {:ok, counts, _} =
        Ecto.Migrator.with_repo(repo, fn started ->
          Barkpark.MigrationIntegrity.check!(repo: started)
        end)

      counts
    end
  end

  # `seed_script` is `priv_path_for/2`: the OTP app's own `:code.priv_dir`
  # joined with the compile-time literals "repo" and "seeds.exs". No runtime
  # input reaches `Code.eval_file/1`, and `seed/0` is an operator-invoked
  # release task (`bin/barkpark eval`), never a request path.
  #
  # Inline rather than a `.sobelow-skips` row on purpose: a baseline entry is
  # pinned to a LINE, so any edit above the call silently kills the waiver and
  # the finding returns as new — which is exactly how the row this replaces
  # (the `RCE.CodeModule` row for `seed/0`) died. The annotation binds by AST adjacency
  # and survives line moves.
  # sobelow_skip ["RCE.CodeModule"]
  def seed do
    # DELIBERATELY a booted tree, not `load_app/0`. Unlike migrate, the seed
    # bodies are ordinary application code: `Barkpark.Seeds.run/0` reaches
    # `Plugins.Bootstrap.register_all_schemas/0` (needs the live
    # `Plugins.Registry` GenServer, populated by the `SchemaBootstrap` boot
    # child), `Content.upsert_schema/2` and `Tenancy`/`Auth` writes (PubSub +
    # `Barkpark.TaskSupervisor` + `Barkpark.Vault`), and the codelist seeders.
    # Starting a hand-picked subset HERE would fork the boot order away from
    # `Barkpark.Application.child_specs/4` and silently change what a seeded
    # instance contains. api/** is auto-deploy-exposed (charter D9): the seed
    # RESULT must not move.
    #
    # `seed_boot!/0` is the NARROWING that comment used to defer ("tracked
    # separately"): it does not hand-pick children, it sets the boot mode and
    # lets the composition root FILTER its own canonical list — same children,
    # same order, minus the listener, with Oban inert. The crash storm this
    # module was filed for belongs entirely to `migrate/0`, which runs FIRST
    # and is what a first-ever boot hits against an empty schema.
    seed_boot!()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seed_script = priv_path_for(repo, "seeds.exs")

          if File.regular?(seed_script) do
            Code.eval_file(seed_script)
          end
        end)
    end
  end

  @doc """
  Boot the tree the way a SEED eval must: everything `Barkpark.Seeds.run/0`
  reaches, and neither a listener nor a queue consumer.

  Sets `:barkpark, :boot_mode` to `:seed` BEFORE starting the app, so
  `Barkpark.Application.start/2` builds its children from
  `Barkpark.Application.child_specs/5` in `:seed` mode — the canonical list
  minus `BarkparkWeb.Endpoint`, with Oban started inert (`queues: false,
  plugins: false`). The seam lives in the composition root on purpose: picking
  a child subset HERE would fork the boot order from the canonical list and
  can silently change what a seeded instance contains (charter D9 — `api/**`
  is auto-deploy-exposed).

  Why not repo-only, the way `migrate/0` is: the seed bodies are ordinary
  application code. `Barkpark.Seeds.run/0` reaches
  `Plugins.Bootstrap.register_all_schemas/0` (needs the live `Plugins.Registry`
  GenServer, populated by the `SchemaBootstrap` boot child),
  `Content.upsert_schema/2` and `Tenancy`/`Auth` writes (PubSub +
  `Barkpark.TaskSupervisor` + `Barkpark.Vault` + the validation registries),
  and document mutations that call `Oban.insert/1`, which raises with no Oban
  instance running. An INERT Oban still accepts those inserts — the jobs stay
  queued for the serving node — while starting no producer and no plugin.

  `persistent: true` matters: `Application.load/1` (which
  `ensure_all_started/1` performs) re-applies the `.app` file's env over
  non-persistent values.
  """
  @spec seed_boot!() :: {:ok, [atom()]}
  def seed_boot! do
    Application.put_env(@app, :boot_mode, :seed, persistent: true)
    {:ok, _apps} = Application.ensure_all_started(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @doc """
  LOAD `:barkpark` without STARTING it.

  `Application.load/1` makes the app's environment (`:ecto_repos`, every
  `repo.config()`, `:code.priv_dir`) and its modules readable; it runs no
  `start/2` callback, so no supervision tree exists afterwards. That is the
  whole point: `bin/barkpark eval "Barkpark.Release.migrate()"` is the FIRST
  thing `entrypoint.sh` runs, against a database that on a first-ever boot has
  no tables at all. The previous `Application.ensure_all_started(@app)` booted
  the entire tree there — `BarkparkWeb.Endpoint`, `Oban`, the plugin tier — so
  a stranger's first log was a crash storm (`undefined_table` on `workspaces`
  and `plugin_settings`, `DrainWorker` terminating) emitted BEFORE the
  migrations that create those tables had run.

  The repo itself is started by `Ecto.Migrator.with_repo/3` at each call site:
  it starts `:ecto_sql` (plus `:start_apps_before_migration`) and the repo
  only, and stops what it started when the function returns. Repo-only is
  exactly what a migration needs.

  Public because it is the reusable "read config, start nothing" step for any
  one-shot task that then wraps its work in `Ecto.Migrator.with_repo/3`.
  Idempotent: an already-loaded app returns `:ok`.
  """
  @spec load_app() :: :ok
  def load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
      {:error, reason} -> raise "could not load #{@app}: #{inspect(reason)}"
    end
  end

  @doc """
  Load AND start `:barkpark` — the full supervision tree.

  Superseded for `seed/0` by `seed_boot!/0`, which boots the same tree in
  `:seed` mode (no `BarkparkWeb.Endpoint`, Oban inert). Kept as the plain
  "load AND start everything" step for any other one-shot task, and so the
  release steps still differ by one obvious call: `load_app/0` starts nothing,
  `start_app/0` starts the FULL tree, `seed_boot!/0` starts the seed tree.
  """
  @spec start_app() :: {:ok, [atom()]} | {:error, term()}
  def start_app do
    Application.ensure_all_started(@app)
  end

  defp priv_path_for(repo, filename) do
    app = Keyword.get(repo.config(), :otp_app)
    priv_dir = "#{:code.priv_dir(app)}"
    Path.join([priv_dir, "repo", filename])
  end
end
