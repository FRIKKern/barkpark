defmodule Barkpark.BootModeLeakFormatterTest do
  @moduledoc """
  task-e6a070e903a72c37: the formatter reads `:boot_mode` when it gets to a
  `:module_finished` cast, which can be after the next module has started.
  `Barkpark.ApplicationBootModeTest` sets the key inside its sandbox and puts
  it back, so a late read of a sandbox's own value must not be reported. A
  real leak is never put back, so it is still set at `:suite_finished`.

  The `step/3` tests drive the formatter's decision with the key's value as an
  argument. The "process" tests run the formatter itself and force the order
  of the race with the real key: the cast is held (`:sys.suspend/1`) until
  another module's sandbox has set the key. They write the key only through
  `BootModeSandbox.sandboxed/1`, and report a leak to the test instead of
  arming the run's exit (`:on_leak`).
  """
  # The process tests set the node-global key (inside a sandbox).
  use ExUnit.Case, async: false

  alias Barkpark.BootModeLeakFormatter, as: F
  alias Barkpark.BootModeSandbox

  defp run(events) do
    {:ok, state} = F.init([])

    Enum.reduce(events, {state, []}, fn {event, now}, {state, reports} ->
      {state, report} = F.step(state, event, now)
      {state, if(report, do: reports ++ [report], else: reports)}
    end)
    |> elem(1)
  end

  test "a sandbox's value read late after another module finished is not a leak" do
    # Run 43390762489: the bench module finished clean, the read came while
    # ApplicationBootModeTest's sandbox held :nope; the sandbox put it back.
    assert run([
             {{:module_finished, Some.Bench}, {:ok, :nope}},
             {{:module_finished, Barkpark.ApplicationBootModeTest}, :error},
             {:suite_finished, :error}
           ]) == []
  end

  test "a key still set when the suite ends names the first module that left it set" do
    assert run([
             {{:module_finished, Clean.One}, :error},
             {{:module_finished, The.Writer}, {:ok, :one_shot}},
             {{:module_finished, A.Witness}, {:ok, :one_shot}},
             {:suite_finished, {:ok, :one_shot}}
           ]) == [{The.Writer, :one_shot}]
  end

  test "a late read that was put back does not take the blame for a later real leak" do
    assert run([
             {{:module_finished, Some.Bench}, {:ok, :nope}},
             {{:module_finished, Barkpark.ApplicationBootModeTest}, :error},
             {{:module_finished, The.Writer}, {:ok, :one_shot}},
             {:suite_finished, {:ok, :one_shot}}
           ]) == [{The.Writer, :one_shot}]
  end

  test "a clean run reports nothing" do
    assert run([{{:module_finished, Clean.One}, :error}, {:suite_finished, :error}]) == []
  end

  describe "the formatter process, the race forced" do
    setup do
      me = self()

      {:ok, pid} =
        GenServer.start_link(F, on_leak: fn name, mode -> send(me, {:leak, name, mode}) end)

      %{pid: pid}
    end

    # Module A finished clean; its cast is handled only once module B's
    # sandbox has set the key.
    defp a_finishes_then_b_sandbox_opens(pid, value) do
      :ok = :sys.suspend(pid)
      GenServer.cast(pid, {:module_finished, %{name: Module.A}})

      BootModeSandbox.sandboxed(fn set ->
        set.(value)
        :ok = :sys.resume(pid)
        # The cast is handled now, while the sandbox holds `value`.
        _ = :sys.get_state(pid)
      end)
    end

    test "module A finishes, B's sandbox opens before the cast is handled: no blame", %{pid: pid} do
      # Nothing reported to the test, and nothing printed either.
      printed =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          a_finishes_then_b_sandbox_opens(pid, :nope)

          GenServer.cast(pid, {:module_finished, %{name: Module.B}})
          GenServer.cast(pid, {:suite_finished, %{}})
          _ = :sys.get_state(pid)
        end)

      refute_received {:leak, _, _}
      refute printed =~ "NODE-GLOBAL LEAK"
    end

    test "a real leak after it is still caught, and named", %{pid: pid} do
      a_finishes_then_b_sandbox_opens(pid, :nope)
      GenServer.cast(pid, {:module_finished, %{name: Module.B}})
      _ = :sys.get_state(pid)

      # The writer leaves the key set and nothing puts it back before the
      # suite ends (the sandbox stands in for the rest of the run).
      BootModeSandbox.sandboxed(fn set ->
        set.(:one_shot)
        GenServer.cast(pid, {:module_finished, %{name: The.Writer}})
        GenServer.cast(pid, {:module_finished, %{name: A.Witness}})
        GenServer.cast(pid, {:suite_finished, %{}})
        _ = :sys.get_state(pid)
      end)

      assert_received {:leak, The.Writer, :one_shot}
      refute_received {:leak, _, _}
    end
  end
end
