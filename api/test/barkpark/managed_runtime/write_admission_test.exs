defmodule Barkpark.ManagedRuntime.WriteAdmissionTest do
  use ExUnit.Case, async: false
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission

  setup do
    Process.flag(:trap_exit, true)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-admission-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
      )

    File.mkdir_p!(root)
    journal = Path.join(root, "admission.dets")
    # Preserve private test journals for failure diagnosis. No user data is used.
    {:ok, gate} =
      Admission.start_link(journal: journal, instance_id: "fixture-A", initialize: true)

    Process.unlink(gate)
    on_exit(fn -> stop(gate) end)
    %{gate: gate, journal: journal, root: root}
  end

  test "admission survives clean settlement and changes generation on restart", %{
    gate: gate,
    journal: journal
  } do
    before = Admission.status(gate)
    assert {:ok, ticket} = Admission.checkout(gate)
    assert Admission.status(gate).pending == 1
    assert :ok = Admission.checkin(gate, ticket)
    assert {:error, :invalid_ticket} = Admission.checkin(gate, ticket)
    stop(gate)
    next = restart(journal)
    assert Admission.status(next).phase == :open
    assert Admission.status(next).generation > before.generation
    refute Admission.status(next).boot == before.boot
    assert {:error, :invalid_ticket} = Admission.checkin(next, ticket)
  end

  test "close refuses later writers and waits for every admitted effect", %{gate: gate} do
    parent = self()

    writer =
      spawn(fn ->
        {:ok, ticket} = Admission.checkout(gate)
        send(parent, {:admitted, self()})

        receive do
          :settle -> send(parent, {:settled, Admission.checkin(gate, ticket)})
        end
      end)

    assert_receive {:admitted, ^writer}
    assert {:ok, :closing, hold} = begin_hold(gate, "operation-1")
    assert {:error, :admission_closed} = Admission.checkout(gate)
    assert false == Admission.held?(gate, hold)
    assert {:error, :invalid_hold} = Admission.reopen(gate, hold)
    send(writer, :settle)
    assert_receive {:settled, :ok}
    assert true == Admission.held?(gate, hold)
    assert :ok = Admission.reopen(gate, hold)
    assert {:error, :invalid_hold} = Admission.reopen(gate, hold)
    assert {:ok, ticket} = Admission.checkout(gate)
    assert :ok = Admission.checkin(gate, ticket)
  end

  test "nested work can settle while closing; duplicate settlement cannot release its sibling", %{
    gate: gate
  } do
    parent = self()

    writer =
      spawn(fn ->
        {:ok, outer} = Admission.checkout(gate)
        send(parent, {:admitted, self()})

        receive do
          :nest ->
            {:ok, inner} = Admission.checkout(gate)
            :ok = Admission.checkin(gate, inner)
            send(parent, {:duplicate, Admission.checkin(gate, inner)})

            receive do
              :settle -> send(parent, {:settled, Admission.checkin(gate, outer)})
            end
        end
      end)

    assert_receive {:admitted, ^writer}
    {:ok, :closing, hold} = begin_hold(gate, "nested")
    send(writer, :nest)
    assert_receive {:duplicate, {:error, :invalid_ticket}}
    assert false == Admission.held?(gate, hold)
    assert Admission.status(gate).pending == 1
    send(writer, :settle)
    assert_receive {:settled, :ok}
    assert true == Admission.held?(gate, hold)
  end

  test "a writer cannot begin a hold that waits for itself", %{gate: gate} do
    {:ok, ticket} = Admission.checkout(gate)
    assert {:error, :caller_has_write} = begin_hold(gate, "self-deadlock")
    assert :ok = Admission.checkin(gate, ticket)
  end

  test "tickets and hold handles cannot be transferred to another process", %{gate: gate} do
    {:ok, ticket} = Admission.checkout(gate)

    assert Task.async(fn -> Admission.checkin(gate, ticket) end) |> Task.await() ==
             {:error, :invalid_ticket}

    :ok = Admission.checkin(gate, ticket)
    {:ok, :held, hold} = begin_hold(gate, "owned")

    assert Task.async(fn -> Admission.reopen(gate, hold) end) |> Task.await() ==
             {:error, :invalid_hold}

    assert Task.async(fn -> Admission.held?(gate, hold) end) |> Task.await() ==
             {:error, :invalid_hold}

    assert {:error, :admission_closed} = begin_hold(gate, "different")
    assert {:ok, :held, ^hold} = begin_hold(gate, "owned")
    assert :ok = Admission.reopen(gate, hold)
  end

  test "a dead admitted writer leaves uncertainty and never completes the drain", %{
    gate: gate,
    journal: journal
  } do
    parent = self()

    writer =
      spawn(fn ->
        {:ok, _} = Admission.checkout(gate)
        send(parent, :admitted)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :admitted
    {:ok, :closing, hold} = begin_hold(gate, "lost-writer")
    send(writer, :die)
    await_phase(gate, :recovery_required)
    assert Admission.status(gate).pending == 1
    assert false == Admission.held?(gate, hold)
    assert {:error, :invalid_hold} = Admission.reopen(gate, hold)
    stop(gate)
    next = restart(journal)
    assert Admission.status(next).phase == :recovery_required
    assert Admission.status(next).pending == 1
    assert {:error, :admission_closed} = Admission.checkout(next)
  end

  test "holder death remains blocked even with no writers", %{gate: gate} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, :held, _} = begin_hold(gate, "lost-holder")
        send(parent, :held)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :held
    send(owner, :die)
    await_phase(gate, :recovery_required)
    assert {:error, :admission_closed} = Admission.checkout(gate)
    assert {:error, :admission_closed} = begin_hold(gate, "lost-holder")
  end

  for phase <- [:open, :closing, :held] do
    test "coordinator death in #{phase} cannot reopen interrupted work", %{
      gate: gate,
      journal: journal
    } do
      assert_crash(unquote(phase), gate, journal)
    end
  end

  defp assert_crash(phase, gate, journal) do
    parent = self()

    writer =
      if phase != :held do
        spawn(fn ->
          {:ok, _} = Admission.checkout(gate)
          send(parent, :admitted)

          receive do
            :stop -> :ok
          end
        end)
      end

    if writer, do: assert_receive(:admitted)

    hold =
      if phase != :open do
        {:ok, ^phase, hold} = begin_hold(gate, "interrupted")
        hold
      end

    ref = Process.monitor(gate)
    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^ref, :process, ^gate, :killed}
    next = restart(journal)
    assert Admission.status(next).phase == :recovery_required
    assert {:error, :admission_closed} = Admission.checkout(next)
    if hold, do: assert({:error, :invalid_hold} == Admission.reopen(next, hold))
    if writer, do: send(writer, :stop)
  end

  test "missing and foreign journals refuse; initialization never replaces an existing file", %{
    gate: gate,
    journal: journal,
    root: root
  } do
    assert {:error, :journal_missing} =
             Admission.start_link(
               journal: Path.join(root, "absent"),
               instance_id: "fixture-missing"
             )

    stop(gate)
    bytes = File.read!(journal)

    assert {:error, :journal_exists} =
             Admission.start_link(journal: journal, instance_id: "fixture-A", initialize: true)

    assert {:error, :invalid_journal} =
             Admission.start_link(journal: journal, instance_id: "fixture-B")

    assert File.read!(journal) == bytes
  end

  test "duplicate coordinator cannot share the live journal", %{gate: gate, journal: journal} do
    assert {:error, {:already_started, ^gate}} =
             Admission.start_link(journal: journal, instance_id: "fixture-A")

    assert Admission.status(gate).phase == :open

    assert {:error, :journal_owned} =
             Admission.start_link(journal: journal, instance_id: "another-instance")
  end

  test "corrupt journal is not repaired or replaced", %{gate: gate, journal: journal} do
    stop(gate)
    File.write!(journal, "broken fixture")
    assert {:error, _} = Admission.start_link(journal: journal, instance_id: "fixture-A")
    assert File.read!(journal) == "broken fixture"
  end

  test "malformed persistent state refuses", %{gate: gate, journal: journal} do
    stop(gate)
    table = make_ref()
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(journal), repair: false)
    :ok = :dets.insert(table, {:state, %{instance_id: "fixture-A", version: 99}})
    :ok = :dets.close(table)

    assert {:error, :invalid_journal} =
             Admission.start_link(journal: journal, instance_id: "fixture-A")
  end

  test "status exposes no write or hold ticket", %{gate: gate} do
    {:ok, :held, hold} = begin_hold(gate, "inspection")
    refute Map.has_key?(Admission.status(gate), :holder)
    refute inspect(Admission.status(gate)) =~ elem(hold, 2)
  end

  test "a delayed begin request cannot close a reopened generation", %{gate: gate} do
    generation = Admission.status(gate).generation
    {:ok, :held, hold} = Admission.begin_hold(gate, "delayed", generation)
    :ok = Admission.reopen(gate, hold)
    assert {:error, :stale_generation} = Admission.begin_hold(gate, "delayed", generation)
    assert Admission.status(gate).phase == :open
  end

  test "a foreign holder cannot reuse an operation identity", %{gate: gate} do
    {:ok, :held, _} = begin_hold(gate, "same-operation")

    assert Task.async(fn -> begin_hold(gate, "same-operation") end) |> Task.await() ==
             {:error, :admission_closed}
  end

  test "independent instances do not share tickets or admission", %{gate: gate, root: root} do
    {:ok, other} =
      Admission.start_link(
        journal: Path.join(root, "other.dets"),
        instance_id: "fixture-B",
        initialize: true
      )

    Process.unlink(other)
    on_exit(fn -> stop(other) end)
    {:ok, ticket} = Admission.checkout(gate)
    assert {:error, :invalid_ticket} = Admission.checkin(other, ticket)
    {:ok, :held, _} = begin_hold(other, "B-hold")
    assert Admission.status(gate).phase == :open
    assert :ok = Admission.checkin(gate, ticket)
  end

  test "missing initialization and invalid identities never create a journal", %{root: root} do
    journal = Path.join(root, "unprovisioned.dets")

    assert {:error, :invalid_instance} =
             Admission.start_link(journal: journal, instance_id: "", initialize: true)

    refute File.exists?(journal)

    assert {:error, :journal_missing} =
             Admission.start_link(journal: journal, instance_id: "fixture-unprovisioned")

    refute File.exists?(journal)
  end

  test "one instance cannot acquire a second journal", %{root: root} do
    journal = Path.join(root, "duplicate.dets")

    assert {:error, {:already_started, _}} =
             Admission.start_link(journal: journal, instance_id: "fixture-A", initialize: true)

    refute File.exists?(journal)
  end

  test "explicit uncertain effects cannot be cleared by later settlement", %{
    gate: gate,
    journal: journal
  } do
    {:ok, ticket} = Admission.checkout(gate)
    assert :ok = Admission.uncertain(gate, ticket)
    assert Admission.status(gate).phase == :recovery_required
    assert {:error, :admission_closed} = Admission.checkout(gate)
    assert :ok = Admission.checkin(gate, ticket)
    assert Admission.status(gate).pending == 0
    assert Admission.status(gate).phase == :recovery_required
    stop(gate)
    next = restart(journal)
    assert Admission.status(next).phase == :recovery_required
  end

  test "held state waits for all independently admitted writers", %{gate: gate} do
    parent = self()

    writers =
      for _ <- 1..3 do
        spawn(fn ->
          {:ok, ticket} = Admission.checkout(gate)
          send(parent, {:ready, self()})

          receive do
            :settle -> send(parent, {:settled, self(), Admission.checkin(gate, ticket)})
          end
        end)
      end

    for writer <- writers, do: assert_receive({:ready, ^writer})
    {:ok, :closing, hold} = begin_hold(gate, "three-writers")
    assert {:ok, :closing, ^hold} = begin_hold(gate, "three-writers")

    for writer <- Enum.take(writers, 2) do
      send(writer, :settle)
      assert_receive {:settled, ^writer, :ok}
      assert false == Admission.held?(gate, hold)
    end

    last = List.last(writers)
    send(last, :settle)
    assert_receive {:settled, ^last, :ok}
    assert true == Admission.held?(gate, hold)
  end

  test "abrupt VM halt preserves held exclusion without journal repair", %{root: root} do
    journal = Path.join(root, "child.dets")
    source = Path.expand("../../../lib/barkpark/managed_runtime/write_admission.ex", __DIR__)

    expression = """
    journal = System.fetch_env!("BP_ADMISSION_TEST_JOURNAL")
    {:ok, gate} = Barkpark.ManagedRuntime.WriteAdmission.start_link(journal: journal, instance_id: "child-fixture", initialize: true)
    generation = Barkpark.ManagedRuntime.WriteAdmission.status(gate).generation
    {:ok, :held, _} = Barkpark.ManagedRuntime.WriteAdmission.begin_hold(gate, "halt", generation)
    System.halt(23)
    """

    executable = System.find_executable("elixir") || flunk("Elixir executable is required")
    script = Path.join(root, "halt.exs")
    File.write!(script, expression)

    {output, result} =
      System.cmd(executable, ["-r", source, script],
        env: [{"BP_ADMISSION_TEST_JOURNAL", journal}],
        stderr_to_stdout: true
      )

    assert result == 23, output
    {:ok, gate} = Admission.start_link(journal: journal, instance_id: "child-fixture")
    Process.unlink(gate)
    on_exit(fn -> stop(gate) end)
    assert Admission.status(gate).phase == :recovery_required
    assert {:error, :admission_closed} = Admission.checkout(gate)
  end

  test "failed persistence does not acknowledge an admitted write", %{
    gate: gate,
    journal: journal
  } do
    # Close DETS from its actual owner to simulate an unavailable journal. No
    # injected success callback can make this test pass without a disk store.
    table = {Admission, Path.expand(journal)}

    :sys.replace_state(gate, fn state ->
      :ok = :dets.close(table)
      state
    end)

    ref = Process.monitor(gate)
    assert {:error, :journal_unavailable} = Admission.checkout(gate)
    assert_receive {:DOWN, ^ref, :process, ^gate, _}
    next = restart(journal)
    assert Admission.status(next).pending == 0
    # No ticket was returned and no work began. This is not settlement of an
    # already acknowledged write; that case must retain its pending record.
  end

  test "failed settlement persistence retains uncertainty on restart", %{
    gate: gate,
    journal: journal
  } do
    {:ok, ticket} = Admission.checkout(gate)
    table = {Admission, Path.expand(journal)}

    :sys.replace_state(gate, fn state ->
      :ok = :dets.close(table)
      state
    end)

    ref = Process.monitor(gate)
    assert {:error, :journal_unavailable} = Admission.checkin(gate, ticket)
    assert_receive {:DOWN, ^ref, :process, ^gate, _}
    next = restart(journal)
    assert Admission.status(next).phase == :recovery_required
    assert Admission.status(next).pending == 1
  end

  defp begin_hold(gate, operation),
    do: Admission.begin_hold(gate, operation, Admission.status(gate).generation)

  defp restart(journal) do
    {:ok, gate} = Admission.start_link(journal: journal, instance_id: "fixture-A")
    Process.unlink(gate)
    on_exit(fn -> stop(gate) end)
    gate
  end

  defp stop(gate) do
    if Process.alive?(gate), do: GenServer.stop(gate)
  end

  defp await_phase(gate, phase, attempts \\ 100)
  defp await_phase(gate, phase, 0), do: assert(Admission.status(gate).phase == phase)

  defp await_phase(gate, phase, attempts) do
    if Admission.status(gate).phase != phase do
      Process.sleep(5)
      await_phase(gate, phase, attempts - 1)
    end
  end
end
