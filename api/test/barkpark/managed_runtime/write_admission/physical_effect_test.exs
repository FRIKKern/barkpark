defmodule Barkpark.ManagedRuntime.WriteAdmission.PhysicalEffectTest do
  use ExUnit.Case, async: false
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  @wait 5_000

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bp-physical-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    File.mkdir_p!(root)
    journal = Path.join(root, "admission.dets")
    instance = "physical-fixture"
    {:ok, gate} = Admission.start_link(journal: journal, instance_id: instance, initialize: true)
    Process.unlink(gate)
    on_exit(fn -> if Process.alive?(gate), do: GenServer.stop(gate) end)
    %{gate: gate, journal: journal, instance: instance}
  end

  test "a physical owner death while open retains the root across restart", ctx do
    parent = self()

    writer =
      spawn(fn ->
        {:ok, _} = Admission.checkout_effect(ctx.gate)
        send(parent, {:admitted, self()})

        receive do
          :die -> exit(:kill)
        end
      end)

    assert_receive {:admitted, ^writer}, @wait
    send(writer, :die)
    await(ctx.gate, :recovery_required)
    assert %{pending: 1, writers: 0, dead_writers: 1} = Admission.status(ctx.gate)
    assert {:error, :admission_closed} = Admission.checkout(ctx.gate)
    before = Admission.status(ctx.gate)
    assert {:error, :unreconciled} = Admission.recover(ctx.gate, before.generation, 0)
    GenServer.stop(ctx.gate)
    {:ok, next} = Admission.start_link(journal: ctx.journal, instance_id: ctx.instance)
    Process.unlink(next)
    on_exit(fn -> if Process.alive?(next), do: GenServer.stop(next) end)
    assert %{phase: :recovery_required, pending: 1} = Admission.status(next)
  end

  test "a completed physical effect does not taint a new independent root", %{gate: gate} do
    {:ok, effect} = Admission.checkout_effect(gate)
    assert :ok = Admission.checkin(gate, effect)
    assert %{phase: :open, pending: 0} = Admission.status(gate)
    parent = self()

    writer =
      spawn(fn ->
        {:ok, _} = Admission.checkout(gate)
        send(parent, {:ordinary, self()})

        receive do
          :die -> exit(:kill)
        end
      end)

    assert_receive {:ordinary, ^writer}, @wait
    send(writer, :die)
    await_pending(gate, 0)
    assert Admission.status(gate).phase == :open
  end

  test "an upgraded outer root retains effect uncertainty after its inner ticket settled", %{
    gate: gate
  } do
    parent = self()

    writer =
      spawn(fn ->
        {:ok, _outer} = Admission.checkout(gate)
        {:ok, inner} = Admission.checkout_effect(gate)
        :ok = Admission.checkin(gate, inner)
        send(parent, {:upgraded, self()})

        receive do
          :die -> exit(:kill)
        end
      end)

    assert_receive {:upgraded, ^writer}, @wait
    send(writer, :die)
    await(gate, :recovery_required)
    assert Admission.status(gate).pending == 1
  end

  test "failed physical settlement retains its ticket; a forged failure cannot poison state", %{
    gate: gate
  } do
    {:ok, ticket} = Admission.checkout_effect(gate)
    assert {:error, :invalid_ticket} = Admission.checkin(gate, {:forged, 1, "x"}, :failed)
    assert %{phase: :open, pending: 1} = Admission.status(gate)
    assert :ok = Admission.checkin(gate, ticket, :failed)
    assert %{phase: :recovery_required, pending: 1} = Admission.status(gate)
  end

  test "a physical child death retains a live ordinary parent root", %{gate: gate} do
    test = self()

    parent =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        {:ok, _} = Admission.checkout(gate)

        child =
          Task.async(fn ->
            {:ok, _} = Admission.checkout_effect(gate)
            send(test, {:child_effect, self()})

            receive do
              :die -> exit(:kill)
            end
          end)

        send(test, {:parent, self(), child.pid})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(parent), do: Process.exit(parent, :kill) end)
    assert_receive {:parent, ^parent, child}, @wait
    assert_receive {:child_effect, ^child}, @wait
    send(child, :die)
    await(gate, :recovery_required)
    assert %{pending: 1, writers: 1, dead_writers: 1} = Admission.status(gate)
    state = Admission.status(gate)
    assert {:error, :writers_present} = Admission.recover(gate, state.generation, 1)
    send(parent, :stop)
  end

  test "held admission rejects a new physical effect", %{gate: gate} do
    {:ok, :held, hold} =
      Admission.begin_hold(gate, "physical-hold", Admission.status(gate).generation)

    assert {:error, :admission_closed} = Admission.checkout_effect(gate)
    assert :ok = Admission.reopen(gate, hold)
  end

  defp await(gate, phase), do: wait(fn -> Admission.status(gate).phase == phase end)
  defp await_pending(gate, count), do: wait(fn -> Admission.status(gate).pending == count end)
  defp wait(fun), do: wait(fun, System.monotonic_time(:millisecond) + @wait)

  defp wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        assert fun.()

      true ->
        Process.sleep(5)
        wait(fun, deadline)
    end
  end
end
