defmodule Mix.Tasks.Barkpark.Migrate do
  @shortdoc "Runs ecto.migrate over the core and enabled plugin migration directories"

  @moduledoc """
  `mix ecto.migrate` for Barkpark: the same task, pointed at the directory set
  `Barkpark.MigrationPaths.enabled/1` returns.

  `api/mix.exs` aliases `ecto.migrate` to this task, so every caller that runs
  `mix ecto.migrate` (the Makefile, `scripts/deploy-rebuild.sh`,
  `deploy/instance-deploy.sh`, CI, the `test` and `ecto.setup` aliases) reads
  the same directories as `Barkpark.Release.migrate/0`.

  The arguments reach `Mix.Tasks.Ecto.Migrate` unchanged in two cases:

    * no plugin or capability folder holds migrations, so the set is the core
      directory alone, which is what `ecto.migrate` reads by default;
    * the caller passed `--migrations-path` itself, which is an explicit
      choice this task does not override.

  Otherwise it appends one `--migrations-path` per directory, core first.

  The run happens inside `Barkpark.Release.with_statement_timeout_lifted/2`, so
  every migration connection starts with `statement_timeout = 0` instead of
  prod's 30 s wall — the same lift `Barkpark.Release.migrate/0` applies. It
  wraps the ecto.migrate call only: the config is loaded first (so the lift
  lands on the runtime config), and the repo's app env is restored when the
  run returns, before anything after it in an alias (`mix test`) starts the
  repo.
  """

  use Mix.Task

  alias Barkpark.MigrationPaths

  @impl Mix.Task
  def run(args), do: run(args, &Mix.Tasks.Ecto.Migrate.run/1)

  @doc """
  Loads the configuration exactly as `ecto.migrate` does (`app.config` with the
  same arguments; Mix runs it once), then hands `ecto_migrate` the resolved
  argument list with `statement_timeout` lifted on the repos `ecto.migrate`
  will start (`Mix.Ecto.parse_repo/1`, the same reader it uses). `ecto_migrate`
  and `opts` (the `migrate_args/2` options) exist for tests.
  """
  @spec run([String.t()], ([String.t()] -> term()), keyword()) :: term()
  def run(args, ecto_migrate, opts \\ []) when is_function(ecto_migrate, 1) do
    Mix.Task.run("app.config", args)
    apply_configured_log_level(args)
    migrate_args = migrate_args(args, opts)

    Barkpark.Release.with_statement_timeout_lifted(Mix.Ecto.parse_repo(args), fn ->
      ecto_migrate.(migrate_args)
    end)
  end

  @doc """
  Sets Logger to the configured `:logger` level unless `args` give
  `--log-level`.

  `ecto.migrate` does not start the application, so the configured level
  never applies and Logger stays at `:debug`. A prod migration then printed
  every SQL query, and the free-disk probe in
  `20261013180000_add_documents_groq_pushdown_indexes.exs` printed
  `[debug] QUERY ERROR ... SHOW data_directory` on every fresh install: a
  non-superuser role may not read that setting, the migration falls back to
  `/var/lib/postgresql`, and the line only reads like a failure.
  """
  @spec apply_configured_log_level([String.t()]) :: :ok
  def apply_configured_log_level(args) do
    given? = Enum.any?(args, &(&1 == "--log-level" or String.starts_with?(&1, "--log-level=")))

    case Application.get_env(:logger, :level) do
      level when is_atom(level) and not is_nil(level) and not given? ->
        Logger.configure(level: level)

      _ ->
        :ok
    end
  end

  @doc """
  The argument list `ecto.migrate` receives. Takes the `Barkpark.MigrationPaths`
  options; `:priv_root` defaults to the project's source `priv`, the directory
  `ecto.migrate` itself reads.
  """
  @spec migrate_args([String.t()], keyword()) :: [String.t()]
  def migrate_args(args, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :priv_root, &source_priv_root/0)

    cond do
      explicit_paths?(args) ->
        args

      MigrationPaths.extra(opts) == [] ->
        args

      true ->
        args ++ Enum.flat_map(MigrationPaths.enabled(opts), &["--migrations-path", &1])
    end
  end

  defp explicit_paths?(args) do
    Enum.any?(args, &(&1 == "--migrations-path" or String.starts_with?(&1, "--migrations-path=")))
  end

  # `ecto.migrate`'s default directory is `<source priv>/repo/migrations`
  # (`Mix.EctoSQL.source_repo_priv/1`). Reading the same root keeps the core
  # entry identical to what the task would have read on its own.
  defp source_priv_root do
    Barkpark.Repo |> Mix.EctoSQL.source_repo_priv() |> Path.dirname()
  end
end
