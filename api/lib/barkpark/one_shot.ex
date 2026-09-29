defmodule Barkpark.OneShot do
  @moduledoc """
  The boot step every operator ONE-SHOT mix task takes instead of
  `Mix.Task.run("app.start")`.

  ## The incident

  FOUND 2026-09-02 08:28–08:35Z on guerrilla. `mix barkpark.edges.backfill`
  called `Mix.Task.run("app.start")`, which boots the ENTIRE Barkpark
  application with whatever runtime env the shell happens to carry. Run from
  the live slot's environment — `PHX_SERVER` set — `BarkparkWeb.Endpoint` tried
  to bind the port the SERVING node already held:

      Running BarkparkWeb.Endpoint with Bandit 1.12.0 at http failed,
      port 4001 already in use

  The supervisor died, and the backfill never started. The same boot also put up
  a second `Oban` draining the live queues, the Github `DrainWorker` (which
  raised an `Oban.Registry` error before Oban was up), and `SchemaBootstrap`'s
  onixedit codelist seeders (one hit `ERROR 57014 query_canceled` under the
  60 s statement_timeout). None of that is anything a backfill needs.

  ## What this does instead

  Sets `:barkpark, :boot_mode` to `:one_shot` BEFORE starting the app, so
  `Barkpark.Application.start/2` builds its children from
  `Barkpark.Application.child_specs/5` in `:one_shot` mode — the canonical list
  minus `BarkparkWeb.Endpoint`, minus `Oban`, minus `Barkpark.SchemaBootstrap`,
  and with no plugin boot workers, no sync children and no self-update children.

  The seam lives in the composition root on purpose, exactly as
  `Barkpark.Release.seed_boot!/0` does: hand-picking a child subset HERE would
  fork the boot ORDER away from the canonical list and can silently change what
  a one-shot sees (charter D9 — `api/**` is auto-deploy-exposed). A one-shot
  that quietly projected a DIFFERENT edge set than the serving node would be a
  worse defect than the one this replaces.

  Why not repo-only, the way `Barkpark.Release.migrate/0` is: the sweep's edge
  set is not repo-shaped. `Barkpark.Content.Graph` folds every PLUGIN's
  projected edges through the `:edge_extractor_collector` seam, and that seam is
  installed by `Barkpark.Application.start/2` and resolved against the live
  `Barkpark.Plugins.Registry` GenServer. Booting repo-only would skip both, and
  the backfill would write a corpus missing every plugin edge — silently, with
  exit status 0. So the application DOES start; it just starts narrowed.

  ## Using it from a mix task

      @impl Mix.Task
      def run(args) do
        Mix.Task.run("app.config")
        Barkpark.OneShot.boot!()
        ...
      end

  `app.config` compiles the project and evaluates `config/runtime.exs` without
  starting anything, which is what makes the `put_env` below land before
  `Barkpark.Application.start/2` reads it.

  ## Running it against a live box

  See `docs/ops/PROD_OPS.md` §Operator one-shots for the invocation an operator
  actually types (`MIX_BUILD_ROOT` pointed at the active slot's build root,
  `nice -n 19`, and where the env comes from).
  """

  @app :barkpark

  @doc """
  Boot the narrowed tree and return `:ok`.

  Idempotent only in the sense `Application.ensure_all_started/1` is: calling it
  on an already-started `:barkpark` returns `:ok` WITHOUT re-reading the boot
  mode, because the tree is already up. That is why the `put_env` comes first
  and why nothing calls this from inside a running node.
  """
  @spec boot!() :: :ok
  def boot! do
    Application.put_env(@app, :boot_mode, :one_shot, persistent: true)
    {:ok, _apps} = Application.ensure_all_started(@app)
    :ok
  end
end
