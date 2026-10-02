defmodule Barkpark.ManagedRuntime.WriteAdmission.SyncDoorTest do
  # C083 slice 5: sync bookkeeping (push cursor, pull drain) is admitted per tick;
  # a held instance halts with the cursor frozen and resumes after reopen.
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.Repo
  alias Barkpark.Sync.{PushCursor, PushWorker, Settings, Worker}

  @dataset "test"

  # The pull worker reconnects asynchronously (a spawned stream process sends
  # :connected), and each reconnect passes the door, which journals to DETS
  # before replying. There is no sync point but the message, so the bound IS
  # the contract: sized for a slow fsync under CI load, not ExUnit's 100ms.
  @reconnect_ms 2_000

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

    hold = hold(gate)

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

    release(gate, hold)

    # First admitted tick bootstraps to head, skipping every pre-open event.
    send(pid, :drain_tick)
    state = :sys.get_state(pid)
    assert state.bootstrapped?
    assert state.attempt == 0
    refute_received {:pushed, _}
    assert PushCursor.get(source, @dataset) == e1.id

    e2 = insert_event!("b")
    send(pid, :drain_tick)
    # The tick runs inside handle_info (door checkout journals to DETS, then
    # push_fun sends), so :sys.get_state returning means the push already
    # happened — no race against a receive timeout.
    _ = :sys.get_state(pid)
    assert_received {:pushed, id}
    assert id == e2.id
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

    hold = hold(gate)

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

    assert_receive {:connected, ref1, 0}, @reconnect_ms
    # The chunk is refused before parsing: the stream is torn down and reconnects.
    assert_receive {:connected, ref2, 0}, @reconnect_ms
    assert ref1 != ref2
    assert :sys.get_state(pid).halted_reason == {:write_admission, :admission_closed}

    release(gate, hold)

    # After reopen the same keepalive applies cleanly and the stream stays up.
    assert_receive {:connected, ref3, 0}, @reconnect_ms
    assert ref3 != ref2
    Process.sleep(50)
    assert %{stream: %{ref: ^ref3}, halted_reason: nil} = :sys.get_state(pid)
  end

  # The test process owns the hold itself. begin_hold/reopen are synchronous
  # calls that journal to DETS before replying, so there is no event to wait
  # for: the old unlinked holder process re-published their replies as
  # messages and raced them against assert_receive's 100ms default, which CI
  # load outran (task-61201dc0c83b9a0c). A hold's owner only needs to be a
  # live non-writer; the workers under test never inherit it (only writers
  # are inherited through `$callers`), and a failed call now names itself
  # instead of surfacing as "mailbox empty".
  defp hold(gate) do
    assert {:ok, :held, ticket} =
             Admission.begin_hold(gate, "switch", Admission.status(gate).generation)

    ticket
  end

  defp release(gate, ticket), do: assert(Admission.reopen(gate, ticket) == :ok)

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
