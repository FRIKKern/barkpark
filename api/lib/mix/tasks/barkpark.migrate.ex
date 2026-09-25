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
  """

  use Mix.Task

  alias Barkpark.MigrationPaths

  @impl Mix.Task
  def run(args), do: run(args, &Mix.Tasks.Ecto.Migrate.run/1)

  @doc """
  Loads the configuration exactly as `ecto.migrate` does (`app.config` with the
  same arguments; Mix runs it once), then hands `ecto_migrate` the resolved
  argument list. `ecto_migrate` and `opts` (the `migrate_args/2` options) exist
  for tests.
  """
  @spec run([String.t()], ([String.t()] -> term()), keyword()) :: term()
  def run(args, ecto_migrate, opts \\ []) when is_function(ecto_migrate, 1) do
    Mix.Task.run("app.config", args)
    args |> migrate_args(opts) |> ecto_migrate.()
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
