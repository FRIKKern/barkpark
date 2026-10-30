defmodule Mix.Tasks.Barkpark.MigrateCheckoutTimeoutTest do
  @moduledoc """
  `mix ecto.migrate` (aliased to `mix barkpark.migrate`) must finish a
  migration that holds `repo().checkout/1` longer than the repo's `:timeout`.
  `deploy/instance-deploy.sh` migrates through this task, and on 2026-10-30 gyl's
  deploy failed with exit 13 when DBConnection cut the checkout of
  `20261027020000_add_revisions_doc_history_index` at the 15 s default.
  `test/barkpark/release/migrate_checkout_timeout_test.exs` explains the
  mechanism; this covers the Mix path, set up as
  `barkpark.migrate_statement_timeout_test.exs` sets up its peer.

  The peer's repo has `timeout: 200`. The probe migration sleeps 1 s inside
  `repo().checkout/1`. After the run, the repo env is back to `timeout: 200`.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @repo Barkpark.Repo

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    db = "barkpark_mix_checkoutto_#{suffix}"

    storage =
      Application.fetch_env!(:barkpark, @repo)
      |> Keyword.drop([:pool, :pool_size, :ownership_timeout, :queue_target, :queue_interval])
      |> Keyword.merge(database: db, pool: DBConnection.ConnectionPool)

    :ok = Ecto.Adapters.Postgres.storage_up(storage)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(storage) end)

    # Only the peer's repo gets the tiny timeout; CREATE DATABASE above needs more.
    # Connect and handshake keep their own bound so a slow runner cannot fail
    # the connection before the checkout starts.
    config =
      Keyword.merge(storage, timeout: 200, connect_timeout: 15_000, handshake_timeout: 15_000)

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

  test "mix ecto.migrate finishes a migration that holds a checkout past the timeout",
       %{peer: peer, migrations: migrations, repo_config: repo_config} do
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:mix])
    :ok = :peer.call(peer, Mix.TasksServer, :put, [{:task, "app.config", nil}])

    args = ["-r", "Barkpark.Repo", "--quiet", "--migrations-path", migrations]

    :ok =
      :peer.call(
        peer,
        Mix.Tasks.Barkpark.Migrate,
        :run,
        [
          args,
          &Mix.Tasks.Ecto.Migrate.run/1,
          [priv_root: Path.dirname(migrations)]
        ],
        60_000
      )

    assert :peer.call(peer, :persistent_term, :get, [:mix_checkoutto_probe, :not_run]) ==
             :finished

    assert :peer.call(peer, Application, :get_env, [:barkpark, @repo]) == repo_config
  end

  defp write_probe_migration!(dir, version) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{version}_mix_checkoutto_probe.exs"), """
    defmodule Barkpark.MixCheckoutToProbe#{version} do
      use Ecto.Migration

      @disable_ddl_transaction true
      @disable_migration_lock true

      def up do
        repo().checkout(fn ->
          repo().query!("SELECT pg_sleep(1)", [], timeout: :infinity)
          :persistent_term.put(:mix_checkoutto_probe, :finished)
        end)
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
