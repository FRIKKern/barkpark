defmodule Barkpark.ManagedRuntime.WriteAdmission.ObanAdmissionTest do
  # Every Oban job is an admitted writer while write admission is enabled, and
  # the ordered hold pauses queues before closing admission (C083 slice 3).
  use ExUnit.Case, async: false

  # A spawned writer/holder reports the reply of a DETS-journaled GenServer
  # call (checkout, checkin, begin_hold, reopen) or its own death as a message;
  # that message is the only sync point, so the bound is the contract. Sized
  # for a slow fsync under CI load, not ExUnit's 100ms default, which reddened
  # main (run 36574063509, task-5381a4e7a1724185). It only costs time on a red.
  @sync_ms 5_000

  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.ManagedRuntime.WriteAdmission.{Door, ObanAdmission, Operation}

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-oban-admission-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "oban-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)
    :ok = ObanAdmission.attach()

    on_exit(fn ->
      ObanAdmission.detach()

      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    %{gate: gate}
  end

  defp job_meta, do: %{job: %Oban.Job{}, worker: "Fixture.Worker", queue: "default"}

  defp job(gate_owner, script) do
    parent = self()

    pid =
      spawn(fn ->
        :telemetry.execute([:oban, :job, :start], %{system_time: 0}, job_meta())
        send(parent, {:started, self()})

        receive do
          :finish ->
            :telemetry.execute([:oban, :job, script], %{duration: 1}, job_meta())
            send(parent, {:finished, self()})
        end
      end)

    assert_receive {:started, ^pid}, @sync_ms
    _ = gate_owner
    pid
  end

  test "a job is admitted at start and settled at stop; a hold waits for it", %{gate: gate} do
    pid = job(gate, :stop)
    assert Admission.status(gate).pending == 1

    {:ok, :closing, hold} = Operation.hold("switch")
    refute Operation.held?(hold) == true
    assert Admission.status(gate).phase == :closing

    send(pid, :finish)
    assert_receive {:finished, ^pid}, @sync_ms
    assert Admission.status(gate).pending == 0
    assert Admission.status(gate).phase == :held

    assert :ok = Operation.reopen(hold)
    assert Admission.status(gate).phase == :open
  end

  test "a job that raises while closing leaves the instance in recovery", %{gate: gate} do
    pid = job(gate, :exception)
    {:ok, :closing, _hold} = Operation.hold("switch")
    send(pid, :finish)
    assert_receive {:finished, ^pid}, @sync_ms
    assert Admission.status(gate).phase == :recovery_required
  end

  test "a job that raises while open is an ordinary failure", %{gate: gate} do
    pid = job(gate, :exception)
    send(pid, :finish)
    assert_receive {:finished, ^pid}, @sync_ms
    assert Admission.status(gate).phase == :open
    assert Admission.status(gate).pending == 0
  end

  test "the hold refuses and leaves queues alone when admission is disabled" do
    Application.put_env(:barkpark, :write_admission, enabled: false)
    assert {:error, :write_admission_disabled} = Operation.hold("switch")
  end

  test "a job started while held runs unadmitted and is logged, never counted", %{gate: gate} do
    hold = hold_until_held!(gate)
    assert_held_job_is_logged_never_counted(gate, hold)
  end

  # task-49941017ee745753. The door is GLOBAL while this file runs: the
  # `:write_admission` env names this test's gate, so any writer in the VM that
  # passes `Door.admit/1` (a paper access-log write, an edge projection, a sync
  # worker a previous test left running) checks out from it. One still in
  # flight when the hold begins makes `begin_hold` answer `:closing`, not
  # `:held`, and the old `{:ok, :held, hold} = Operation.hold(...)` raised a
  # MatchError. Closing-then-held is the order the coordinator is built for,
  # so the test waits for `:held` instead of assuming it.
  test "a writer in flight when the hold begins delays :held; the held arm still holds",
       %{gate: gate} do
    parent = self()

    foreign =
      spawn(fn ->
        Door.admit(fn ->
          send(parent, :foreign_admitted)

          receive do
            :settle -> :ok
          end
        end)

        send(parent, :foreign_settled)
      end)

    assert_receive :foreign_admitted, @sync_ms
    assert Admission.status(gate).pending == 1

    {:ok, :closing, hold} = Operation.hold("switch")
    send(foreign, :settle)
    assert_receive :foreign_settled, @sync_ms

    assert_held_job_is_logged_never_counted(gate, wait_held!(gate, hold))
  end

  defp hold_until_held!(gate) do
    case Operation.hold("switch") do
      {:ok, :held, hold} ->
        hold

      {:ok, :closing, hold} ->
        wait_held!(gate, hold)

      other ->
        flunk("Operation.hold/1 answered #{inspect(other)}; status #{inspect(status(gate))}")
    end
  end

  defp wait_held!(gate, hold, waited \\ 0) do
    cond do
      Operation.held?(hold) == true ->
        hold

      waited >= @sync_ms ->
        flunk(
          "the hold never reached :held within #{@sync_ms}ms; status #{inspect(status(gate))}"
        )

      true ->
        Process.sleep(20)
        wait_held!(gate, hold, waited + 20)
    end
  end

  defp assert_held_job_is_logged_never_counted(gate, hold) do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        job(gate, :stop)
        |> then(fn pid ->
          send(pid, :finish)
          assert_receive {:finished, ^pid}, @sync_ms
        end)
      end)

    # Every message names the state it saw, so a red under load is its own
    # capture (the 2026-09-29 reds kept only the header line).
    status = status(gate)

    assert log =~ "refused an Oban job",
           "no refusal logged; status #{inspect(status)}; log #{inspect(log)}"

    assert status.pending == 0,
           "the held job was counted; status #{inspect(status)}; log #{inspect(log)}"

    assert status.phase == :held,
           "the hold did not stay held; status #{inspect(status)}; log #{inspect(log)}"

    :ok = Operation.reopen(hold)
  end

  defp status(gate), do: Admission.status(gate)
end
