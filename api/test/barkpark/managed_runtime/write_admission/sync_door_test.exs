defmodule Barkpark.ManagedRuntime.WriteAdmission.SyncDoorTest do
  # C083 slice 5: sync bookkeeping (push cursor, pull drain) is admitted per tick;
  # a held instance halts with the cursor frozen and resumes after reopen.
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.Repo
  alias Barkpark.Sync.{PushCursor, PushWorker, Settings, Worker}

  @dataset "test"

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-syncdoor-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "syncdoor-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    %{gate: gate}
  end

  test "push tick under hold freezes the cursor and pushes nothing; reopen drains", %{gate: gate} do
    test_pid = self()
    source = "door-#{System.unique_integer([:positive])}"
    pre = insert_event!("pre")

    push_fun = fn _ctx, event, _base ->
      send(test_pid, {:pushed, event.id})
      {:ok, "remote-#{event.doc_id}"}
    end

    holder = hold(gate)

    {:ok, pid} =
      PushWorker.start_link(
        name: nil,
        settings: %Settings{
          source: source,
          dataset: @dataset,
          push_batch_size: 50,
          push_interval_ms: 60_000
        },
        ctx: %{source: source, dataset: @dataset},
        push_fun: push_fun,
        tick_fun: fn _pid, _delay -> :ok end
      )

    # Held at boot: the bootstrap is deferred, nothing is written.
    state = :sys.get_state(pid)
    refute state.bootstrapped?
    assert PushCursor.get(source, @dataset) == 0

    e1 = insert_event!("a")
    send(pid, :drain_tick)
    state = :sys.get_state(pid)
    refute_received {:pushed, _}
    assert PushCursor.get(source, @dataset) == 0
    assert state.attempt == 1
    assert Admission.status(gate).phase == :held

    send(holder, :release)
    assert_receive {:released, :ok}

    # First admitted tick bootstraps to head, skipping every pre-open event.
    send(pid, :drain_tick)
    state = :sys.get_state(pid)
    assert state.bootstrapped?
    assert state.attempt == 0
    refute_received {:pushed, _}
    assert PushCursor.get(source, @dataset) == e1.id

    e2 = insert_event!("b")
    send(pid, :drain_tick)
    assert_receive {:pushed, id}
    assert id == e2.id
    _ = :sys.get_state(pid)
    assert PushCursor.get(source, @dataset) == e2.id
    refute_received {:pushed, _}
    assert pre.id < e1.id
  end

  test "pull drain under hold halts the stream and reconnects after reopen", %{gate: gate} do
    test_pid = self()

    fake = fn parent, ref, _settings, since ->
      send(test_pid, {:connected, ref, since})
      send(parent, {:sse_chunk, ref, ": keepalive\n\n"})
      Process.sleep(:infinity)
    end

    holder = hold(gate)

    {:ok, pid} =
      Worker.start_link(
        name: nil,
        settings: %Settings{
          source: "door-#{System.unique_integer([:positive])}",
          dataset: @dataset,
          workspace: nil,
          max_attempts: 5
        },
        stream_fun: fake,
        backoff_fun: fn _ -> 0 end
      )

    assert_receive {:connected, ref1, 0}
    # The chunk is refused before parsing: the stream is torn down and reconnects.
    assert_receive {:connected, ref2, 0}
    assert ref1 != ref2
    assert :sys.get_state(pid).halted_reason == {:write_admission, :admission_closed}

    send(holder, :release)
    assert_receive {:released, :ok}

    # After reopen the same keepalive applies cleanly and the stream stays up.
    assert_receive {:connected, ref3, 0}
    assert ref3 != ref2
    Process.sleep(50)
    assert %{stream: %{ref: ^ref3}, halted_reason: nil} = :sys.get_state(pid)
  end

  defp hold(gate) do
    parent = self()

    holder =
      spawn(fn ->
        {:ok, :held, ticket} =
          Admission.begin_hold(gate, "switch", Admission.status(gate).generation)

        send(parent, :held)

        receive do
          :release -> send(parent, {:released, Admission.reopen(gate, ticket)})
        end
      end)

    assert_receive :held
    holder
  end

  defp insert_event!(doc_id) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: @dataset,
      type: "post",
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => "post", "_rev" => "r-#{doc_id}"},
      source: "api",
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
