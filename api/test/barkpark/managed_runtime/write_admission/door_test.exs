defmodule Barkpark.ManagedRuntime.WriteAdmission.DoorTest do
  use ExUnit.Case, async: false

  # A spawned writer/holder reports the reply of a DETS-journaled GenServer
  # call (checkout, checkin, begin_hold, reopen) or its own death as a message;
  # that message is the only sync point, so the bound is the contract. Sized
  # for a slow fsync under CI load, not ExUnit's 100ms default, which reddened
  # main (run 36574063509, task-5381a4e7a1724185). It only costs time on a red.
  @sync_ms 5_000
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.ManagedRuntime.WriteAdmission.Door

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)
    on_exit(fn -> restore(previous) end)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-door-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    journal = Path.join(root, "admission.dets")
    %{journal: journal}
  end

  test "disabled admission is a passthrough that never touches a coordinator" do
    Application.put_env(:barkpark, :write_admission, enabled: false)
    assert Door.admit(fn -> {:ok, :wrote} end) == {:ok, :wrote}
    assert Door.admit_or_skip(fn -> :persisted end, :skipped) == :persisted
    refute Door.enabled?()
  end

  test "enabled without a running coordinator fails closed", %{} do
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: "door-missing")

    assert Door.admit(fn -> flunk("must not write") end) ==
             {:error, {:write_admission, :unavailable}}

    assert Door.admit_or_skip(fn -> flunk("must not write") end, :skipped) == :skipped
  end

  test "enabled without an instance id refuses" do
    Application.put_env(:barkpark, :write_admission, enabled: true)

    assert Door.admit(fn -> flunk("must not write") end) ==
             {:error, {:write_admission, :unconfigured}}
  end

  test "admitted writes settle, hooks in child tasks join, and a hold refuses later writes", %{
    journal: journal
  } do
    gate = start(journal, "door-live")
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: "door-live")

    assert Door.admit(fn ->
             # A hook fan-out inside the write inherits admission through $callers.
             [:ok] =
               Task.async_stream([1], fn _ -> Door.admit(fn -> :ok end) end)
               |> Enum.map(fn {:ok, v} -> v end)

             {:ok, :wrote}
           end) == {:ok, :wrote}

    assert Admission.status(gate).pending == 0

    {:ok, :held, hold} = Admission.begin_hold(gate, "switch", Admission.status(gate).generation)

    assert Door.admit(fn -> flunk("must not write while held") end) ==
             {:error, {:write_admission, :admission_closed}}

    assert Door.admit_or_skip(fn -> flunk("must not persist while held") end, :derived) ==
             :derived

    assert true == Admission.held?(gate, hold)
    :ok = Admission.reopen(gate, hold)
    assert Door.admit(fn -> :again end) == :again
  end

  test "a raise settles as failed: ordinary while open, recovery while closing", %{
    journal: journal
  } do
    gate = start(journal, "door-raise")
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: "door-raise")

    assert_raise RuntimeError, "boom", fn -> Door.admit(fn -> raise "boom" end) end
    assert Admission.status(gate).phase == :open
    assert Admission.status(gate).pending == 0

    parent = self()

    writer =
      spawn(fn ->
        Door.admit(fn ->
          send(parent, :admitted)

          receive do
            :fail -> raise "boom"
          end
        end)
      end)

    assert_receive :admitted, @sync_ms

    {:ok, :closing, _hold} =
      Admission.begin_hold(gate, "switch", Admission.status(gate).generation)

    send(writer, :fail)
    await_phase(gate, :recovery_required)
    assert Admission.status(gate).pending == 0
  end

  test "a returned error is a controlled outcome and settles", %{journal: journal} do
    gate = start(journal, "door-error")
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: "door-error")
    assert Door.admit(fn -> {:error, :validation_failed} end) == {:error, :validation_failed}
    assert Admission.status(gate).pending == 0
    assert Admission.status(gate).phase == :open
  end

  defp start(journal, instance) do
    {:ok, gate} = Admission.start_link(journal: journal, instance_id: instance, initialize: true)
    Process.unlink(gate)
    on_exit(fn -> if Process.alive?(gate), do: GenServer.stop(gate) end)
    gate
  end

  defp restore(nil), do: Application.delete_env(:barkpark, :write_admission)
  defp restore(previous), do: Application.put_env(:barkpark, :write_admission, previous)

  # Poll to the same @sync_ms deadline as the message waits, not a fixed 500ms.
  defp await_phase(gate, phase),
    do: await_phase(gate, phase, System.monotonic_time(:millisecond) + @sync_ms)

  defp await_phase(gate, phase, deadline) do
    cond do
      Admission.status(gate).phase == phase ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        assert Admission.status(gate).phase == phase

      true ->
        Process.sleep(5)
        await_phase(gate, phase, deadline)
    end
  end
end
