defmodule Barkpark.SingleFlightTest do
  @moduledoc "Barkpark.SingleFlight: one computation per key across concurrent askers (am-w2-s4)."
  use ExUnit.Case, async: false

  alias Barkpark.SingleFlight

  setup do
    SingleFlight.evict(:all)
    on_exit(fn -> SingleFlight.evict(:all) end)
    %{key: {:sf_test, System.unique_integer([:positive])}}
  end

  defp counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  defp slow_fun(agent, value) do
    fn ->
      Agent.update(agent, &(&1 + 1))
      Process.sleep(150)
      value
    end
  end

  test "concurrent askers share ONE computation and all get its value", %{key: key} do
    calls = counter()

    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> SingleFlight.run(key, 0, slow_fun(calls, :v)) end) end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert results == List.duplicate(:v, 10)
    assert Agent.get(calls, & &1) == 1
  end

  test "a fresh result is served without computing; ttl 0 recomputes", %{key: key} do
    calls = counter()
    assert SingleFlight.run(key, 60_000, slow_fun(calls, :a)) == :a
    assert SingleFlight.run(key, 60_000, slow_fun(calls, :b)) == :a
    assert Agent.get(calls, & &1) == 1

    key2 = {key, :ttl0}
    assert SingleFlight.run(key2, 0, slow_fun(calls, :c)) == :c
    assert SingleFlight.run(key2, 0, slow_fun(calls, :d)) == :d
    assert Agent.get(calls, & &1) == 3
  end

  test "evict forgets a key", %{key: key} do
    assert SingleFlight.run(key, 60_000, fn -> :old end) == :old
    SingleFlight.evict(key)
    assert SingleFlight.run(key, 60_000, fn -> :new end) == :new
  end

  test "a leader that raises does not strand its waiters", %{key: key} do
    parent = self()

    leader =
      Task.async(fn ->
        try do
          SingleFlight.run(key, 0, fn ->
            send(parent, :leading)
            Process.sleep(150)
            raise "boom"
          end)
        rescue
          _ -> :raised
        end
      end)

    assert_receive :leading, 1_000
    waiter = Task.async(fn -> SingleFlight.run(key, 0, fn -> :waiter_computed end) end)

    assert Task.await(leader, 5_000) == :raised
    assert Task.await(waiter, 5_000) == :waiter_computed

    # And the key is free again: a later ask leads and completes.
    assert SingleFlight.run(key, 0, fn -> :after end) == :after
  end

  test "a leader that dies does not strand its waiters", %{key: key} do
    parent = self()

    leader =
      spawn(fn ->
        SingleFlight.run(key, 0, fn ->
          send(parent, :leading)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :leading, 1_000
    waiter = Task.async(fn -> SingleFlight.run(key, 0, fn -> :waiter_computed end) end)
    Process.sleep(50)
    Process.exit(leader, :kill)

    assert Task.await(waiter, 5_000) == :waiter_computed
  end
end
