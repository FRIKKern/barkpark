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
