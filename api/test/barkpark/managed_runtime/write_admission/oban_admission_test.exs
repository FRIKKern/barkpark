defmodule Barkpark.ManagedRuntime.WriteAdmission.ObanAdmissionTest do
  # Every Oban job is an admitted writer while write admission is enabled, and
  # the ordered hold pauses queues before closing admission (C083 slice 3).
  use ExUnit.Case, async: false

  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.ManagedRuntime.WriteAdmission.{ObanAdmission, Operation}

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

    assert_receive {:started, ^pid}
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
    assert_receive {:finished, ^pid}
    assert Admission.status(gate).pending == 0
    assert Admission.status(gate).phase == :held

    assert :ok = Operation.reopen(hold)
    assert Admission.status(gate).phase == :open
  end

  test "a job that raises while closing leaves the instance in recovery", %{gate: gate} do
    pid = job(gate, :exception)
    {:ok, :closing, _hold} = Operation.hold("switch")
    send(pid, :finish)
    assert_receive {:finished, ^pid}
    assert Admission.status(gate).phase == :recovery_required
  end

  test "a job that raises while open is an ordinary failure", %{gate: gate} do
    pid = job(gate, :exception)
    send(pid, :finish)
    assert_receive {:finished, ^pid}
    assert Admission.status(gate).phase == :open
    assert Admission.status(gate).pending == 0
  end

  test "the hold refuses and leaves queues alone when admission is disabled" do
    Application.put_env(:barkpark, :write_admission, enabled: false)
    assert {:error, :write_admission_disabled} = Operation.hold("switch")
  end

  test "a job started while held runs unadmitted and is logged, never counted", %{gate: gate} do
    {:ok, :held, hold} = Operation.hold("switch")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        job(gate, :stop)
        |> then(fn pid ->
          send(pid, :finish)
          assert_receive {:finished, ^pid}
        end)
      end)

    assert log =~ "refused an Oban job"
    assert Admission.status(gate).pending == 0
    assert Admission.status(gate).phase == :held
    :ok = Operation.reopen(hold)
  end
end
