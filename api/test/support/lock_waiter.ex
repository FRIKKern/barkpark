defmodule Barkpark.LockWaiter do
  @moduledoc """
  A race test's call under test, run on its own real connection, and a wait
  check that counts only that connection (task-4ee516f1f7d4178b).

  A race test releases its holder transaction only once the call under test is
  waiting on the holder's row lock. Counting lock waiters across the whole
  Postgres cluster let a waiter in another database (another worktree's test
  run on a shared machine) satisfy that check: the holder was released early,
  the call never waited, and the test passed with the lock it pins deleted.
  Here the call reports its own backend pid before it runs, and the check
  counts only that pid, in this database.

      {task, backend} = LockWaiter.start(fn -> StudioChat.cancel_pending_approvals(sid) end)
      LockWaiter.await_lock!(backend)
      release(holder)
      Task.await(task)
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Barkpark.Repo

  @waiting """
  SELECT count(*) FROM pg_stat_activity
  WHERE pid = $1 AND datname = current_database() AND wait_event_type = 'Lock'
  """

  @doc "Runs `fun` in a task on an unboxed connection; returns `{task, backend_pid}`."
  @spec start((-> any())) :: {Task.t(), integer()}
  def start(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Barkpark.Unboxed.run(Repo, fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {__MODULE__, self(), backend})
          fun.()
        end)
      end)

    receive do
      {__MODULE__, pid, backend} when pid == task.pid -> {task, backend}
    after
      5_000 -> flunk("the call under test never reported its backend pid")
    end
  end

  @doc """
  Waits until `backend` is waiting on a lock in this database, or flunks.

  The check reads on a connection of its own, in a process of its own. A race
  test calls this inside its own `unboxed_run`, and an `unboxed_run` in the
  caller's process would check that connection in: the rest of the test then
  ran in the sandbox, so its cleanup rolled back and its committed rows stayed
  (task-23b6ba92b28c809a).
  """
  @spec await_lock!(integer(), non_neg_integer()) :: :ok
  def await_lock!(backend, tries \\ 250) do
    waiting =
      Task.async(fn ->
        %{rows: [[n]]} = Barkpark.Unboxed.run(Repo, fn -> Repo.query!(@waiting, [backend]) end)
        n
      end)
      |> Task.await()

    cond do
      waiting == 1 ->
        :ok

      tries == 0 ->
        flunk("backend #{backend} never waited on a lock in this database")

      true ->
        Process.sleep(20)
        await_lock!(backend, tries - 1)
    end
  end
end
