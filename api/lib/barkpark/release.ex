defmodule Barkpark.Release do
  @moduledoc "Release tasks (run migrations without Mix)."

  @app :barkpark

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, :up, all: true),
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
  Assert the migrate step actually applied the tree: every migration version in
  the release's `priv/repo/migrations` is present in `schema_migrations`, and no
  two files claim the same version. Raises, naming the version, otherwise.

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
    # DELIBERATELY `start_app/0`, not `load_app/0`. Unlike migrate, the seed
    # bodies are ordinary application code: `Barkpark.Seeds.run/0` reaches
    # `Plugins.Bootstrap.register_all_schemas/0` (needs the live
    # `Plugins.Registry` GenServer, populated by the `SchemaBootstrap` boot
    # child), `Content.upsert_schema/2` and `Tenancy`/`Auth` writes (PubSub +
    # `Barkpark.TaskSupervisor` + `Barkpark.Vault`), and the codelist seeders.
    # Starting a hand-picked subset here would fork the boot order away from
    # `Barkpark.Application.child_specs/4` and silently change what a seeded
    # instance contains. api/** is auto-deploy-exposed (charter D9): the seed
    # RESULT must not move. Narrowing this step is tracked separately — the
    # crash storm this module was filed for belongs entirely to `migrate/0`,
    # which runs FIRST and is what a first-ever boot hits against an empty
    # schema.
    start_app()

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

  Only `seed/0` needs this; see the comment there for why. Kept as a named
  function so the two release steps differ by one obvious call and a reader
  can see which one boots a tree.
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
