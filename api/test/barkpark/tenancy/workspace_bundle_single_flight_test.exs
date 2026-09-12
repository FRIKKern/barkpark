defmodule Barkpark.Tenancy.WorkspaceBundleSingleFlightTest do
  @moduledoc """
  THE EXPORT ROUTE'S ADMISSION CONTROL (PDS-D719,
  task `pds-bl-export-single-flight-guard`).

  These are UNIT proofs of the guard itself; the wire shape a refused caller
  actually receives is pinned in `workspace_controller_test.exs`. Nothing here
  starts a second export, a load generator, or any real COPY: a slot is held by
  an ordinary process that calls `acquire/1` and then waits, which is exactly
  what a live export's request process does and costs nothing.

  What is proved, and why each one exists:

    * the SAME workspace cannot double-book — the base claim;
    * a DIFFERENT workspace is refused on capacity, and the refusal does NOT
      carry the in-flight slug (the cross-tenant leak control — the refused
      caller proved `workspace_admin?/2` on THEIR workspace and on nothing
      else);
    * the NEGATIVE CONTROL: raise the limit to 2 and two different workspaces
      both admit while the same workspace is STILL refused. This is the arm
      that proves the two keys are independent — a guard that refused
      everything would pass every test above it;
    * a release frees the slot, and a release from a non-owner does not;
    * A KILLED HOLDER FREES ITS SLOT. `after` cannot run for
      `Process.exit(pid, :kill)`, and a wedged slot would make the route
      permanently 409 with no operator signal at all — strictly worse than the
      unbounded fan-out the guard replaced. Proved, not argued;
    * `limit: 0` disables the guard entirely.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Tenancy.WorkspaceBundle.SingleFlight

  setup do
    original = Application.get_env(:barkpark, :export_concurrency_limit)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :export_concurrency_limit)
        value -> Application.put_env(:barkpark, :export_concurrency_limit, value)
      end

      # Never leave a slot held for the next test file.
      Enum.each(SingleFlight.in_flight(), fn {_slug, pid, _started} ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      wait_until(fn -> SingleFlight.in_flight() == [] end)
    end)

    :ok
  end

  defp slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A stand-in for a live export's request process: takes the slot, then waits.
  defp holder(slug) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:acquired, self(), SingleFlight.acquire(slug)})

        receive do
          {:release, from} ->
            SingleFlight.release(slug)
            send(from, {:released, self()})
        end
      end)

    assert_receive {:acquired, ^pid, :ok}, 2_000
    pid
  end

  defp release(pid) do
    send(pid, {:release, self()})
    assert_receive {:released, ^pid}, 2_000
    :ok
  end

  # Bounded poll, NOT a sleep: the guard's reclaim runs on a `:DOWN` inside the
  # GenServer, so the test cannot observe it synchronously from outside.
  defp wait_until(fun, deadline \\ 2_000) do
    if fun.() do
      true
    else
      if deadline <= 0 do
        false
      else
        Process.sleep(10)
        wait_until(fun, deadline - 10)
      end
    end
  end

  describe "acquire/1 with the shipped default limit of 1" do
    setup do
      Application.put_env(:barkpark, :export_concurrency_limit, 1)
      :ok
    end

    test "the SAME workspace cannot double-book, and the refusal names it back" do
      s = slug("sf-same")
      pid = holder(s)

      assert {:error, {:export_in_flight, info}} = SingleFlight.acquire(s)
      assert info.reason == :workspace_export_in_flight
      assert info.workspace_slug == s
      assert info.limit == 1
      assert info.retry_after_seconds > 0
      assert is_integer(info.running_for_seconds) and info.running_for_seconds >= 0

      release(pid)
    end

    test "a DIFFERENT workspace is refused on capacity, and the refusal never carries the in-flight slug" do
      held = slug("sf-held")
      other = slug("sf-other")
      pid = holder(held)

      assert {:error, {:export_in_flight, info}} = SingleFlight.acquire(other)
      assert info.reason == :export_capacity_reached

      # THE LEAK CONTROL. The refused caller administers `other` and has proved
      # nothing about `held`; the guard must not hand them its existence.
      assert info.workspace_slug == nil
      refute inspect(info) =~ held

      release(pid)
    end

    test "releasing frees the slot for the next caller" do
      s = slug("sf-release")
      pid = holder(s)
      assert {:error, _} = SingleFlight.acquire(s)

      release(pid)

      assert SingleFlight.acquire(s) == :ok
      assert SingleFlight.release(s) == :ok
    end

    test "a release from a process that does not hold the slot is a no-op" do
      s = slug("sf-foreign-release")
      pid = holder(s)

      # This test process is not the owner.
      assert SingleFlight.release(s) == :ok

      assert {:error, {:export_in_flight, %{reason: :workspace_export_in_flight}}} =
               SingleFlight.acquire(s)

      release(pid)
    end

    test "A KILLED HOLDER FREES ITS SLOT — a crashed export cannot wedge the route" do
      s = slug("sf-crash")
      pid = holder(s)
      assert {:error, _} = SingleFlight.acquire(s)

      ref = Process.monitor(pid)
      # `after` CANNOT run for this. Only the guard's own monitor can.
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      assert wait_until(fn -> SingleFlight.acquire(s) == :ok end),
             "the slug stayed wedged after its holder was killed: #{inspect(SingleFlight.in_flight())}"

      assert SingleFlight.release(s) == :ok
    end
  end

  describe "the limit is real configuration, not a hardcoded 1" do
    test "NEGATIVE CONTROL: at limit 2 two DIFFERENT workspaces both admit, while the SAME one is still refused" do
      Application.put_env(:barkpark, :export_concurrency_limit, 2)

      a = slug("sf-a")
      b = slug("sf-b")

      pid_a = holder(a)
      pid_b = holder(b)

      # Both in flight at once — the guard is not simply refusing everything.
      assert length(SingleFlight.in_flight()) == 2

      # And the per-workspace key still bites independently of capacity.
      assert {:error, {:export_in_flight, %{reason: :workspace_export_in_flight}}} =
               SingleFlight.acquire(a)

      # The third DIFFERENT workspace now hits the raised ceiling.
      assert {:error, {:export_in_flight, %{reason: :export_capacity_reached, limit: 2}}} =
               SingleFlight.acquire(slug("sf-c"))

      release(pid_a)
      release(pid_b)
    end

    test "limit 0 disables admission control entirely" do
      Application.put_env(:barkpark, :export_concurrency_limit, 0)

      s = slug("sf-disabled")
      pid = holder(s)

      assert SingleFlight.acquire(s) == :ok
      # Nothing was recorded, so nothing can wedge.
      assert SingleFlight.in_flight() == []
      assert SingleFlight.release(s) == :ok

      send(pid, {:release, self()})
      assert_receive {:released, ^pid}, 2_000
    end
  end
end
