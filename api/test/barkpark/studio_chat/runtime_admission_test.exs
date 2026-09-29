defmodule Barkpark.StudioChat.RuntimeAdmissionTest do
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.RuntimeAdmission

  setup do
    name = String.to_atom("runtime_admission_test_#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :unique, name: name})
    %{registry: name}
  end

  test "a configured cap rejects N+1 and release is idempotent", %{registry: registry} do
    opts = opts(registry, 2)

    assert {:ok, first} = RuntimeAdmission.acquire("session-1", opts)
    assert {:ok, second} = RuntimeAdmission.acquire("session-2", opts)

    assert {:error, {:managed_runtime_capacity, 2}} =
             RuntimeAdmission.acquire("session-3", opts)

    assert RuntimeAdmission.active_count(registry) == 2
    assert :ok = RuntimeAdmission.release(first)
    assert :ok = RuntimeAdmission.release(first)
    assert RuntimeAdmission.active_count(registry) == 1
    assert {:ok, _replacement} = RuntimeAdmission.acquire("session-3", opts)
    assert RuntimeAdmission.active_count(registry) == 2
    assert :ok = RuntimeAdmission.release(second)
  end

  test "a foreign process cannot release another Recorder's lease", %{registry: registry} do
    assert {:ok, lease} = RuntimeAdmission.acquire("session-1", opts(registry, 1))

    task = Task.async(fn -> RuntimeAdmission.release(lease) end)
    assert :ok = Task.await(task)
    assert RuntimeAdmission.active_count(registry) == 1
  end

  test "owner termination releases capacity without a decrement race", %{registry: registry} do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = RuntimeAdmission.acquire("session-1", opts(registry, 1))
        send(parent, {:lease_result, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:lease_result, {:ok, _lease}}
    assert RuntimeAdmission.active_count(registry) == 1
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_eventually(fn -> RuntimeAdmission.active_count(registry) == 0 end)
    assert {:ok, _lease} = RuntimeAdmission.acquire("session-2", opts(registry, 1))
  end

  test "registered-host work bypasses the local cap", %{registry: registry} do
    assert {:ok, :not_managed} =
             RuntimeAdmission.acquire("remote", %{
               execution_target: "registered_host",
               admission_registry: registry,
               managed_runtime_limit: 1
             })

    assert RuntimeAdmission.active_count(registry) == 0
  end

  test "invalid limits fall back to the conservative default", %{registry: registry} do
    opts = opts(registry, 0)

    assert {:ok, _} = RuntimeAdmission.acquire("session-1", opts)
    assert {:ok, _} = RuntimeAdmission.acquire("session-2", opts)
    assert {:ok, _} = RuntimeAdmission.acquire("session-3", opts)

    assert {:error, {:managed_runtime_capacity, 3}} =
             RuntimeAdmission.acquire("session-4", opts)
  end

  # THE CEILING THE SUITE ITSELF MUST NOT REACH (task-232ca4f298258788).
  # Every other test here passes an explicit `managed_runtime_limit`, so none of
  # them measures the limit a REAL `Recorder.ensure/1` gets — and that limit is
  # the module's production default of 3 unless config/test.exs raises it. Three
  # is below ExUnit's own fan-out, so a fourth async test holding a Recorder reds
  # with `{:error, {:managed_runtime_capacity, 3}}` on an unrelated diff (seen on
  # `Elixir gate` runs 35515018409 and 35249228901 at chat_live_test.exs:6661).
  # Read the effective limit off a lease taken with NO limit opt, against a
  # PRIVATE registry so this assertion holds zero node-global slots of its own.
  test "the test-env admission ceiling clears the suite's concurrency", %{registry: registry} do
    assert {:ok, lease} =
             RuntimeAdmission.acquire("ceiling-probe", %{
               execution_target: "managed",
               admission_registry: registry
             })

    floor = max(System.schedulers_online() * 2, 8)

    assert lease.limit >= floor,
           "config/test.exs must raise max_managed_runtimes above the async suite's " <>
             "fan-out; got #{lease.limit}, need >= #{floor}"
  end

  defp opts(registry, limit) do
    %{
      execution_target: "managed",
      admission_registry: registry,
      managed_runtime_limit: limit
    }
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
