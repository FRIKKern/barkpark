defmodule Barkpark.LockWaiterTest do
  @moduledoc """
  `Barkpark.LockWaiter.await_lock!/1` counts only the call under test's own
  backend, in this database (task-4ee516f1f7d4178b). The race tests' first
  helper counted lock waiters across the whole cluster by query text, so a
  waiter in another database on a shared machine could satisfy it.

  Each foreign waiter is real: two connections contend for one advisory lock,
  and the waiting query carries `chat_`, the text the old helper matched on.
  One pair sits in the `postgres` database, one in this test database on
  connections that are not the call under test's.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.LockWaiter

  for where <- [:another_database, :this_database] do
    test "a lock waiter on another connection, in #{where}, does not satisfy the wait check" do
      with_foreign_waiter(unquote(where), fn ->
        assert cluster_chat_waiters() >= 1, "no foreign waiter: the old helper would see nothing"

        {task, backend} = LockWaiter.start(fn -> :not_waiting end)
        assert Task.await(task) == :not_waiting

        assert_raise ExUnit.AssertionError, ~r/never waited on a lock in this database/, fn ->
          LockWaiter.await_lock!(backend, 5)
        end
      end)
    end
  end

  # task-23b6ba92b28c809a: `unboxed_run` checks in whatever its process holds,
  # so an `await_lock!/1` that ran one inside a race test's own `unboxed_run`
  # released the test's connection. The rest of the test ran in the sandbox:
  # its cleanup rolled back and the rows it had committed stayed behind.
  test "a wait inside the caller's unboxed_run leaves its cleanup committed, so nothing stays" do
    slug = "lock-waiter-residue-#{System.unique_integer([:positive])}"
    assert committed_workspaces(slug) == 0

    unboxed(fn ->
      ws = Barkpark.TenancyFixtures.create_workspace!(slug)

      try do
        holder = hold_row(ws.id)
        {waiter, backend} = LockWaiter.start(fn -> lock_row(ws.id) end)
        LockWaiter.await_lock!(backend)
        send(holder.pid, :release)
        Task.await(holder, 10_000)
        Task.await(waiter, 10_000)
      after
        {:ok, _} = Barkpark.Tenancy.delete_workspace(ws)
      end
    end)

    assert committed_workspaces(slug) == 0, "the caller's cleanup rolled back: residue committed"
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp lock_row(id),
    do: Repo.one!(from w in Barkpark.Tenancy.Workspace, where: w.id == ^id, lock: "FOR UPDATE")

  defp hold_row(id) do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            lock_row(id)
            send(parent, :held)

            receive do
              :release -> :ok
            after
              10_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive :held, 5_000
    holder
  end

  # Read on a connection of its own, so only committed rows count.
  defp committed_workspaces(slug) do
    Task.async(fn ->
      unboxed(fn ->
        Repo.aggregate(from(w in Barkpark.Tenancy.Workspace, where: w.slug == ^slug), :count)
      end)
    end)
    |> Task.await()
  end

  defp with_foreign_waiter(where, fun) do
    database = if where == :this_database, do: Repo.config()[:database], else: "postgres"

    cfg =
      Repo.config()
      |> Keyword.take([:hostname, :username, :password, :port, :socket_dir])
      |> Keyword.put(:database, database)

    key = System.unique_integer([:positive]) + :erlang.phash2(self())
    {:ok, holder} = Postgrex.start_link(cfg)
    {:ok, waiter} = Postgrex.start_link(cfg)
    Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [key])

    foreign =
      Task.async(fn ->
        Postgrex.query!(waiter, "SELECT pg_advisory_lock($1) /* chat_ */", [key], timeout: 30_000)
      end)

    try do
      await_foreign(key)
      fun.()
    after
      Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [key])
      Task.await(foreign, 10_000)
      GenServer.stop(holder)
      GenServer.stop(waiter)
    end
  end

  defp cluster_chat_waiters do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query ILIKE '%chat_%'"
      )

    n
  end

  defp await_foreign(key, tries \\ 250) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = $1 AND NOT granted",
        [rem(key, 4_294_967_296)]
      )

    cond do
      n >= 1 -> :ok
      tries == 0 -> flunk("the foreign waiter never queued on its advisory lock")
      true -> Process.sleep(20) && await_foreign(key, tries - 1)
    end
  end
end
