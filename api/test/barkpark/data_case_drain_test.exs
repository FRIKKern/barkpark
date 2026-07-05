defmodule Barkpark.DataCaseDrainTest do
  # Guards the sandbox-drain in Barkpark.DataCase.setup_sandbox/1 — the fix
  # for the content-writepath flake cluster (EnvelopeTest / EventLogTest /
  # FlatWriteScopeLeakTest / OwnerScopedTest reddening under full-suite
  # concurrency). App code fire-and-forgets DB work on the global task
  # supervisors (webhook fan-out, media delivery, audit bridge); such a task
  # inherits the spawning test's sandbox connection via `$callers`, and
  # stopping the owner mid-query killed the Postgrex connection ("owner
  # exited" disconnect) — each kill starved a concurrently starting test out
  # of the zero-slack pool. The drain awaits exactly the test's own tasks
  # before stop_owner. These tests pin both properties directly.
  use Barkpark.DataCase, async: true

  test "drain awaits a task this test fired-and-forgot (caller-chained)" do
    {:ok, task} =
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        Process.sleep(150)
      end)

    # the task is attributed to us through $callers…
    assert task in caller_chained_children(self())

    # …and draining blocks until it has finished, so stop_owner can never
    # fire underneath one of our live queries.
    Barkpark.DataCase.drain_owned_tasks(self(), %{})
    refute Process.alive?(task)
  end

  test "drain follows transitive spawns (task-of-task, webhook fan-out shape)" do
    {:ok, outer} =
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        # mirrors Dispatcher.fan_out: the outer task spawns per-delivery
        # tasks on the delivery supervisor and blocks on them
        Barkpark.WebhookDeliverySupervisor
        |> Task.Supervisor.async_stream_nolink([50, 50], &Process.sleep/1, ordered: false)
        |> Stream.run()
      end)

    Barkpark.DataCase.drain_owned_tasks(self(), %{})
    refute Process.alive?(outer)
    assert caller_chained_children(self()) == []
  end

  test "drain never blocks on another test's tasks (scoped by $callers)" do
    parent = self()

    # a raw spawn does NOT propagate $callers, so the task this middleman
    # fires is attributed to the middleman only — exactly like a concurrent
    # test's orphan from this drain's point of view
    spawn(fn ->
      {:ok, task} =
        Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
          Process.sleep(2_000)
        end)

      send(parent, {:foreign_task, task})
    end)

    assert_receive {:foreign_task, foreign}, 1_000
    refute foreign in caller_chained_children(self())

    {micros, :ok} =
      :timer.tc(fn -> Barkpark.DataCase.drain_owned_tasks(self(), %{}) end)

    # the foreign 2s task must not have been awaited
    assert micros < 500_000
    assert Process.alive?(foreign)
    Process.exit(foreign, :kill)
  end

  defp caller_chained_children(test_pid) do
    for sup <- [Barkpark.TaskSupervisor, Barkpark.WebhookDeliverySupervisor],
        pid <- Task.Supervisor.children(sup),
        {:dictionary, dict} <- [Process.info(pid, :dictionary)],
        test_pid in Keyword.get(dict, :"$callers", []),
        do: pid
  end
end
