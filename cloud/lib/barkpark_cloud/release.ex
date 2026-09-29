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

  @doc """
  RE-TAKE THE POST-REGIME DRAIN DISTRIBUTION and print it
  (dr-w13-bl-waiting-alert-population-is-empty, charter D190/D211(b)).

      bin/barkpark_cloud eval 'BarkparkCloud.Release.drain_distribution("24h")'
      bin/barkpark_cloud eval 'BarkparkCloud.Release.drain_distribution("72h")'

  ## Why this lives here and not in a Mix task

  `DeployLedger.DrainDistribution` landed with the whole measurement and NO
  caller in `cloud/lib` — reachable from its own suite and from nowhere else,
  which is the D245 disease the deploy ledger's own reachability census exists
  to name. Prod runs a Mix RELEASE, and a release has no `mix`, so a
  `Mix.Tasks.*` entry point would have been unreachable on the one machine that
  holds the population the row asks about. `eval` is the door that exists there,
  and this module is what `eval` can call. This is the module's one external
  caller; the recipe stops being a thing a human pastes into `psql` five times.

  The Repo is started the same way `migrate/0` starts it — `Ecto.Migrator.with_repo/2`,
  which brings up the Repo and its dependencies and stops them again — rather
  than `Application.ensure_all_started/1`, because starting the full tree inside
  `eval` would try to bind the port the LIVE node is already serving on. When
  the Repo is ALREADY running (a `remote_console` attached to that live node, or
  the test suite), it is reused: starting a second Repo under the same name is
  the one way this call could take the site down.

  Returns the rendered lines as well as printing them, so a caller that wants to
  record the reading does not have to scrape stdout.
  """
  @spec drain_distribution(binary()) :: [binary()]
  def drain_distribution(mark \\ "24h") do
    lines = with_repo(fn -> BarkparkCloud.DeployLedger.DrainDistribution.retake(mark) end)
    Enum.each(lines, &IO.puts/1)
    lines
  end

  defp with_repo(fun) do
    if Process.whereis(BarkparkCloud.Repo) do
      fun.()
    else
      load_app()
      {:ok, result, _apps} = Ecto.Migrator.with_repo(BarkparkCloud.Repo, fn _repo -> fun.() end)
      result
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
