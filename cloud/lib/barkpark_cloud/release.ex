defmodule BarkparkCloud.Release do
  @moduledoc """
  Release tasks the running container invokes via `bin/barkpark_cloud eval`.

  In a Mix release there is no `mix` and no `Mix.Tasks.Ecto.Migrate` — Mix is a
  build-time tool, absent from the runtime image. This is the standard Ecto
  release-migration pattern: load the app (so its config + Repo are available),
  then drive `Ecto.Migrator` directly against the on-disk migrations.

  The Dockerfile's CMD runs `migrate/0` before `bin/barkpark_cloud start`, so the
  schema is current before Bandit serves a single request.
  """

  @app :barkpark_cloud

  @doc """
  Run every pending migration for each configured Repo, then stop.

  Boots the app's dependencies (NOT the full supervision tree — the Repo is
  started in isolation for the migration, then shut down) and runs migrations
  to `:up`. Invoked as: `bin/barkpark_cloud eval "BarkparkCloud.Release.migrate()"`.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Roll the default Repo back to a given migration version."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
