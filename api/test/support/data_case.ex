defmodule Barkpark.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Barkpark.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  require Logger

  using do
    quote do
      alias Barkpark.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Barkpark.DataCase
    end
  end

  setup tags do
    Barkpark.DataCase.setup_sandbox(tags)
    Barkpark.DataCase.ensure_default_tenancy()
    Barkpark.DataCase.reset_plugins_env()
    :ok
  end

  @doc """
  Force the `:barkpark, :plugins` Application env back to its boot baseline
  (UNSET — config declares no `:plugins`).

  Several plugin tests set this env to a non-empty load-order list, which
  makes `Barkpark.Plugins.Registry.load_ordered_plugins/0` walk ONLY the
  listed names. When such a value leaks across tests, an otherwise-correct
  reader (Studio settings UI, resolver-output integration, media asset
  hooks) sees a registry that excludes the very plugins it just registered
  in its own setup — an order-dependent flake. Restoring the unset baseline
  here (case-template setup runs before the test module's own setup) means
  every DataCase test starts from the same registry-iteration source of
  truth. Tests that legitimately set the env in their body still restore it
  via their own `on_exit/1`.
  """
  def reset_plugins_env do
    Application.delete_env(:barkpark, :plugins)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  The on_exit drains this test's fire-and-forget tasks BEFORE stopping the
  sandbox owner. App code spawns async DB work on the global
  `Barkpark.TaskSupervisor` / `Barkpark.WebhookDeliverySupervisor` (webhook
  fan-out, media delivery, audit bridge); those tasks inherit this test's
  sandbox connection through `$callers`. Stopping the owner while such a task
  is mid-query kills the Postgrex connection ("owner exited" disconnect), and
  because the pool has no slack (pool_size == max concurrent tests) every
  killed connection starves whichever test is checking out during the
  reconnect window — the cross-file flake cluster. Draining is scoped to THIS
  test's own tasks (matched via `$callers`), so concurrent tests never block
  on someone else's work.

  THEN the long-lived PubSub singletons are quiesced, because `$callers` cannot
  reach them. `Barkpark.Quiz.Bridge` is a boot-time GenServer subscribed to
  `documents:<dataset>`; it is not a `Task`, is not rooted at this test's pid,
  and so `drain_owned_tasks/3` is structurally blind to it. A test that
  publishes a `quiz` document hands it a SHARED-mode connection implicitly, and
  stopping the owner underneath that read is what produced 1,310 failures in CI
  run 29710726459. See `Barkpark.PubSubSingletons`.

  ORDER IS LOAD-BEARING: tasks drain FIRST, because a draining task can itself
  broadcast the mutation that wakes a singleton. Quiescing the singletons before
  the tasks that feed them would leave exactly the in-flight read this exists to
  prevent.
  """
  def setup_sandbox(tags) do
    # A test that legitimately holds its connection longer than DBConnection's
    # 15s default (e.g. the full EDItEUR/Thema codelist seed under suite load)
    # can raise the ceiling with `@moduletag ownership_timeout: ms` — otherwise
    # the ownership monitor force-disconnects mid-query, poisoning a pool
    # connection exactly like the orphan-task leak this module drains.
    opts =
      case tags[:ownership_timeout] do
        nil -> [shared: not tags[:async]]
        ms -> [shared: not tags[:async], ownership_timeout: ms]
      end

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Barkpark.Repo, opts)
    test_pid = self()

    on_exit(fn ->
      drain_owned_tasks(test_pid, tags)
      Barkpark.PubSubSingletons.drain!()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)
  end

  @task_supervisors [Barkpark.TaskSupervisor, Barkpark.WebhookDeliverySupervisor]
  @drain_deadline_ms 10_000

  @doc """
  Await (bounded) every task on the global task supervisors whose `$callers`
  chain includes `test_pid` — work this test's own code fired-and-forgot.
  Loops because a draining task may spawn more (webhook fan-out spawns
  per-delivery tasks). On deadline the stragglers are killed so the sandbox
  owner never stops underneath a live query.
  """
  def drain_owned_tasks(test_pid, tags, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @drain_deadline_ms

    case owned_tasks(test_pid) do
      [] ->
        :ok

      pids ->
        if System.monotonic_time(:millisecond) > deadline do
          Logger.warning(
            "DataCase drain deadline: killing #{length(pids)} leaked task(s) from " <>
              "#{inspect(tags[:module])} #{inspect(tags[:test])}"
          )

          Enum.each(pids, &Process.exit(&1, :kill))
          await_down(pids)
        else
          await_down(pids)
          drain_owned_tasks(test_pid, tags, deadline)
        end
    end
  end

  defp owned_tasks(test_pid) do
    for sup <- @task_supervisors,
        pid <- Task.Supervisor.children(sup),
        callers = process_callers(pid),
        test_pid in callers,
        do: pid
  end

  # `$callers` is stamped by Task.Supervisor at spawn, so a task fired by the
  # test (or by one of its tasks, transitively) always carries the test pid.
  defp process_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      nil -> []
    end
  end

  defp await_down(pids) do
    refs = Enum.map(pids, &Process.monitor/1)

    Enum.each(refs, fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        @drain_deadline_ms -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  @doc """
  Guarantee the seeded Default Workspace/Project exist inside the per-test
  sandbox. The backfill migration (20260527110200) seeds them at the schema
  level, so this is a no-op read in the normal case — but a per-test sandbox
  that started before/without that committed data gets them created here, so
  the flat back-compat (Default-scope) reads and the tenancy fixtures behave.
  Idempotent: only inserts when absent.
  """
  def ensure_default_tenancy do
    _ = Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
