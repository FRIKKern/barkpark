defmodule Barkpark.Release.MigrateStatementTimeoutTest do
  @moduledoc """
  `Barkpark.Release.migrate/0` must run its migrations with `statement_timeout`
  lifted to 0, even when the repo is configured with prod's 30 s wall
  (`config/runtime.exs` sends `parameters: [statement_timeout: "30s"]`).

  Measured on a FRESH BEAM (`:peer`), because the test node has already started
  `Barkpark.Repo` on the SQL sandbox pool: `Ecto.Migrator.with_repo/3` would
  find it `:already_started` and the measurement would describe the sandbox,
  not the release path. The peer gets this node's config with the repo pointed
  at a scratch database, a real connection pool, the 30 s parameter, and a
  `:priv` holding ONE generated migration that records `SHOW statement_timeout`
  from inside its own `up/0`.

  Two arms:

    * CONTROL — a plain `with_repo/2` query on the same peer and config reads
      "30s", so the wall really reaches connections and the "0" below is the
      override's doing, not an unconfigured repo.
    * the MUTATION ARM, run by hand and quoted in the PR: restoring the old
      `with_repo(repo, fun, parameters: [...])` call (ecto_sql 3.13.5 reads only
      `:mode` and `:pool_size` from that keyword) reds the migrate test with
      "30s".
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @repo Barkpark.Repo

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    db = "barkpark_release_stmtto_#{suffix}"

    config =
      Application.fetch_env!(:barkpark, @repo)
      |> Keyword.drop([:pool, :pool_size, :ownership_timeout, :queue_target, :queue_interval])
      |> Keyword.merge(
        database: db,
        pool: DBConnection.ConnectionPool,
        parameters: [statement_timeout: "30s"],
        priv: relative_to_app_dir(tmp_dir)
      )

    :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)

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

  test "control: the configured 30 s wall reaches a with_repo connection", %{peer: peer} do
    # Evaluated ON the peer: a closure or capture of this (in-memory) test
    # module cannot be loaded there.
    {result, _binding} =
      :peer.call(peer, Code, :eval_string, [
        ~s|Ecto.Migrator.with_repo(Barkpark.Repo, fn r -> r.query!("SHOW statement_timeout") end)|
      ])

    assert {:ok, %Postgrex.Result{rows: [["30s"]]}, _} = result
  end

  test "a migration run through Release.migrate/0 sees statement_timeout = 0", %{peer: peer} do
    :peer.call(peer, Barkpark.Release, :migrate, [])

    assert :peer.call(peer, :persistent_term, :get, [:release_stmtto_probe, :not_run]) == "0"
  end

  defp write_probe_migration!(dir, version) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{version}_release_stmtto_probe.exs"), """
    defmodule Barkpark.ReleaseStmtToProbe#{version} do
      use Ecto.Migration

      def up do
        %{rows: [[value]]} = repo().query!("SHOW statement_timeout")
        :persistent_term.put(:release_stmtto_probe, value)
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
