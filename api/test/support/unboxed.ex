defmodule Barkpark.Unboxed do
  @moduledoc """
  The one way test code runs `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`. It
  raises when the calling process is already inside one (task-8cda3662a8eb6dc2).

  `unboxed_run/2` checks in whatever the process holds, checks out a real
  connection, and checks it in again when `fun` returns (deps ecto_sql
  sandbox.ex:624-633). Nested in the same process, the inner call checks in the
  OUTER connection. The rest of the outer `fun` then runs in the shared sandbox:
  its cleanup deletes roll back with the test while the rows it created on the
  real connection stay committed. A committed second workspace makes
  `Tenancy.multi_tenant?/0` true for every later test in that database
  (task-23b6ba92b28c809a, task-74ffcd7ebc02ac94).

  A read that must not touch the caller's connection runs in a process of its
  own, which has its own checkout:

      Task.async(fn -> Barkpark.Unboxed.run(fn -> Repo.query!(sql) end) end)
      |> Task.await()

  `test/barkpark/unboxed_guard_test.exs` fails any test file or support module
  that calls `unboxed_run` other than through this module.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @doc "Runs `fun` on a real connection of `repo`; raises if already inside one."
  @spec run(module(), (-> result)) :: result when result: any()
  def run(repo \\ Barkpark.Repo, fun) when is_function(fun, 0) do
    key = {__MODULE__, repo}

    if Process.get(key) do
      raise ArgumentError, """
      Barkpark.Unboxed.run/2 called inside another unboxed run in the same process.

      The inner call would check in the outer connection, so the outer fun's
      later writes and cleanup run in the sandbox and roll back, while its
      earlier rows stay committed. Use the connection you are already on, or
      run the inner work in a Task of its own.
      """
    end

    Process.put(key, true)

    try do
      Sandbox.unboxed_run(repo, fun)
    after
      Process.delete(key)
    end
  end
end
