defmodule Barkpark.ManagedRuntime.WriteAdmission.EdgeDoorTest do
  # C083 slice 5: writers adjacent to the content doors and the lazy media/key writes
  # are doors of their own; a held instance refuses each and admits again on reopen.
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{Broadcast, Edges}
  alias Barkpark.Crypto.DataKeys
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.ManagedRuntime.WriteAdmission.Refused
  alias Barkpark.Plugins.Bulldocs.Events

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-edgedoor-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "edgedoor-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

    {:ok, gate} =
      Admission.start_link(
        journal: Path.join(root, "admission.dets"),
        instance_id: instance,
        initialize: true
      )

    Process.unlink(gate)
    Application.put_env(:barkpark, :write_admission, enabled: true, instance_id: instance)

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :write_admission, previous),
        else: Application.delete_env(:barkpark, :write_admission)

      if Process.alive?(gate), do: GenServer.stop(gate)
    end)

    {:ok, doc} =
      Content.create_document("post", %{"_id" => "edge-door", "title" => "before"}, "test")

    %{gate: gate, doc: doc}
  end

  test "held refuses every edge writer; reopen admits them", %{gate: gate, doc: doc} do
    scope = "edge-door-#{System.unique_integer([:positive])}"
    hold = hold(gate)

    assert_raise Refused, fn -> Broadcast.save_event(doc, "post", "test", "update", doc.rev) end
    assert_raise Refused, fn -> Edges.disconnect_references(doc.doc_id, "test") end
    assert_raise Refused, fn -> DataKeys.active_dek(scope) end

    assert {:error, {:write_admission, :admission_closed}} =
             Events.create_event(%{
               "event_type" => "comment",
               "paper_slug" => "edge-door",
               "body" => "held"
             })

    assert Admission.status(gate).phase == :held
    release(gate, hold)

    assert %Barkpark.Content.MutationEvent{} =
             Broadcast.save_event(doc, "post", "test", "update", doc.rev)

    assert :ok == Edges.disconnect_references(doc.doc_id, "test")
    assert {1, dek} = DataKeys.active_dek(scope)
    assert byte_size(dek) == 32
    assert Admission.status(gate).pending == 0
  end

  # The test process owns the hold. begin_hold/reopen are synchronous calls
  # that journal to DETS before replying; a spawned holder re-published those
  # replies as messages raced against assert_receive's 100ms default, which
  # CI load outran (main run 36574063509, task-5381a4e7a1724185). The owner
  # only needs to be a live non-writer: the test process holds no admission
  # while the hold begins, and nothing it spawns inherits the hold.
  defp hold(gate) do
    assert {:ok, :held, ticket} =
             Admission.begin_hold(gate, "switch", Admission.status(gate).generation)

    ticket
  end

  defp release(gate, ticket), do: assert(Admission.reopen(gate, ticket) == :ok)
end
