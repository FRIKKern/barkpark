defmodule Mix.Tasks.Barkpark.MigrateStatementTimeoutTest do
  @moduledoc """
  `mix ecto.migrate` (aliased in `api/mix.exs` to `mix barkpark.migrate`) must
  run its migrations with `statement_timeout` lifted to 0, even when the repo
  is configured with prod's 30 s wall (`config/runtime.exs` sends
  `parameters: [statement_timeout: "30s"]`). This is the path the prod box
  migrates through: `scripts/deploy-rebuild.sh` and `make migrate` run
  `MIX_ENV=prod mix ecto.migrate`.

  Measured on a FRESH BEAM (`:peer`), for the reason
  test/barkpark/release/migrate_statement_timeout_test.exs gives: the test
  node's `Barkpark.Repo` is already started on the sandbox pool, so
  `Ecto.Migrator.with_repo/3` would find it running and measure the sandbox.
  The peer gets this node's config with the repo pointed at a scratch
  database, a real pool, the 30 s parameter, and ONE generated migration that
  records `SHOW statement_timeout` from inside its own `up/0`. It then runs
  `Mix.Tasks.Barkpark.Migrate.run/3` with the REAL `Mix.Tasks.Ecto.Migrate.run/1`
  — repo parsing, `with_repo/3` start and stop, `Ecto.Migrator.run/4` — not a
  stand-in.

  The peer has no Mix project, so `app.config` (which would load this
  project's config over the seeded one) is marked as already run; in a real
  `mix ecto.migrate` it has run by then too, and the task's own call is the
  same no-op. `--migrations-path` is explicit so the source-priv default,
  which needs a project, is never read.

  CONTROL: after the run, a plain `with_repo/2` query on the same peer reads
  "30s" — the wall really reaches connections, so the "0" is the lift's
  doing, and the lift did not outlive the migration run.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @repo Barkpark.Repo

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    db = "barkpark_mix_stmtto_#{suffix}"

    config =
      Application.fetch_env!(:barkpark, @repo)
      |> Keyword.drop([:pool, :pool_size, :ownership_timeout, :queue_target, :queue_interval])
      |> Keyword.merge(
        database: db,
        pool: DBConnection.ConnectionPool,
        parameters: [statement_timeout: "30s"]
      )

    :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)

    migrations = Path.join(tmp_dir, "migrations")
    write_probe_migration!(migrations, suffix)

    {:ok, peer, _node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        connection: :standard_io,
        args: [~c"-pa" | :code.get_path()]
      })

    on_exit(fn -> try_stop(peer) end)
    seed_peer_config(peer, config)
    {:ok, peer: peer, migrations: migrations, repo_config: config}
  end

  test "a migration run through mix ecto.migrate sees statement_timeout = 0; the wall is back after",
       %{peer: peer, migrations: migrations, repo_config: repo_config} do
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:mix])
    :ok = :peer.call(peer, Mix.TasksServer, :put, [{:task, "app.config", nil}])

    args = ["-r", "Barkpark.Repo", "--quiet", "--migrations-path", migrations]

    # Evaluated ON the peer: a capture of this (in-memory) test module cannot
    # be loaded there, but `&Mix.Tasks.Ecto.Migrate.run/1` is a remote capture.
    :ok =
      :peer.call(peer, Mix.Tasks.Barkpark.Migrate, :run, [
        args,
        &Mix.Tasks.Ecto.Migrate.run/1,
        [priv_root: Path.dirname(migrations)]
      ])

    assert :peer.call(peer, :persistent_term, :get, [:mix_stmtto_probe, :not_run]) == "0"

    # CONTROL, and the restore: the repo env is what it was, and a connection
    # started outside the migration run carries the 30 s wall.
    assert :peer.call(peer, Application, :get_env, [:barkpark, @repo]) == repo_config

    {result, _binding} =
      :peer.call(peer, Code, :eval_string, [
        ~s|Ecto.Migrator.with_repo(Barkpark.Repo, fn r -> r.query!("SHOW statement_timeout") end)|
      ])

    assert {:ok, %Postgrex.Result{rows: [["30s"]]}, _} = result
  end

  defp write_probe_migration!(dir, version) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{version}_mix_stmtto_probe.exs"), """
    defmodule Barkpark.MixStmtToProbe#{version} do
      use Ecto.Migration

      def up do
        %{rows: [[value]]} = repo().query!("SHOW statement_timeout")
        :persistent_term.put(:mix_stmtto_probe, value)
      end

      def down, do: :ok
    end
    """)
  end

  defp seed_peer_config(peer, repo_config) do
    for {app, _, _} <- Application.loaded_applications() do
      _ = :peer.call(peer, :application, :load, [app])
    end

    env =
      for {app, _, _} <- Application.loaded_applications(),
          do: {app, Application.get_all_env(app)}

    :ok = :peer.call(peer, Application, :put_all_env, [env])
    :ok = :peer.call(peer, Application, :put_env, [:barkpark, @repo, repo_config])
  end

  defp try_stop(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end
end
