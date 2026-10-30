defmodule Barkpark.Release.MigrateCheckoutTimeoutTest do
  @moduledoc """
  A migration that holds `repo().checkout/1` longer than the repo's `:timeout`
  must still finish when it runs through `Barkpark.Release.migrate/0`.

  `repo().checkout/1` with no options takes its `:timeout` from the repo config
  (`Ecto.Adapters.SQL.checkout_or_transaction/4` appends the adapter meta's
  `Keyword.take(config, [:timeout, ...])`). DBConnection then arms a deadline on
  the held connection (`DBConnection.Holder`, default 15_000 ms) and disconnects
  it when the deadline fires. A `timeout: :infinity` on each query inside the
  checkout does not move that deadline. On 2026-10-30 this cancelled
  `20261027020000_add_revisions_doc_history_index` on gyl after 15 s, while
  `CREATE INDEX CONCURRENTLY` was still reading a 1.9 GB `revisions` table.

  Measured on a fresh BEAM (`:peer`), as in `MigrateStatementTimeoutTest`: the
  test node already runs `Barkpark.Repo` on the sandbox pool. The peer's repo
  has `timeout: 200` and a `:priv` holding one migration that sleeps 1 s inside
  `repo().checkout/1` with `timeout: :infinity` on the query, the shape of the
  two revisions index migrations.

    * CONTROL: the same checkout and sleep under a plain `with_repo/2` raises,
      so the 200 ms timeout really reaches the checkout.
    * The release path finishes the migration and records it.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @repo Barkpark.Repo

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    db = "barkpark_release_checkoutto_#{suffix}"

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
      Keyword.merge(storage,
        timeout: 200,
        connect_timeout: 15_000,
        handshake_timeout: 15_000,
        priv: relative_to_app_dir(tmp_dir)
      )

    write_probe_migration!(Path.join(tmp_dir, "migrations"), suffix)

    {:ok, peer, _node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        connection: :standard_io,
        args: [~c"-pa" | :code.get_path()]
      })

    on_exit(fn -> try_stop(peer) end)
    seed_peer_config(peer, config)
    {:ok, peer: peer}
  end

  test "control: a checkout held past the configured 200 ms is cut off", %{peer: peer} do
    {result, _binding} =
      :peer.call(
        peer,
        Code,
        :eval_string,
        [
          """
          Ecto.Migrator.with_repo(Barkpark.Repo, fn r ->
            try do
              r.checkout(fn -> r.query!("SELECT pg_sleep(1)", [], timeout: :infinity) end)
              :finished
            rescue
              e in [DBConnection.ConnectionError, Postgrex.Error] -> {:cut_off, Exception.message(e)}
            end
          end)
          """
        ],
        60_000
      )

    assert {:ok, {:cut_off, _message}, _} = result
  end

  test "Release.migrate/0 finishes a migration that holds a checkout past the timeout",
       %{peer: peer} do
    :peer.call(peer, Barkpark.Release, :migrate, [], 60_000)

    assert :peer.call(peer, :persistent_term, :get, [:release_checkoutto_probe, :not_run]) ==
             :finished
  end

  defp write_probe_migration!(dir, version) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{version}_release_checkoutto_probe.exs"), """
    defmodule Barkpark.ReleaseCheckoutToProbe#{version} do
      use Ecto.Migration

      @disable_ddl_transaction true
      @disable_migration_lock true

      def up do
        repo().checkout(fn ->
          repo().query!("SELECT pg_sleep(1)", [], timeout: :infinity)
          :persistent_term.put(:release_checkoutto_probe, :finished)
        end)
      end

      def down, do: :ok
    end
    """)
  end

  # `Ecto.Migrator.migrations_path/2` joins `:priv` UNDER the app dir, so an
  # absolute tmp path has to be spelled relative to it.
  defp relative_to_app_dir(abs) do
    ups = Application.app_dir(:barkpark) |> Path.split() |> tl() |> Enum.map(fn _ -> ".." end)
    Path.join(ups ++ tl(Path.split(abs)))
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
