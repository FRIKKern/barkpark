defmodule Barkpark.ManagedRuntime.WriteAdmission.TaskBoardDoorTest do
  # C083 slice 4: the task-board write primitive is a door; a held instance refuses by raising.
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.ManagedRuntime.WriteAdmission, as: Admission
  alias Barkpark.ManagedRuntime.WriteAdmission.Refused
  alias Barkpark.Tasks.Internal

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:barkpark, :write_admission)

    root =
      Path.join(
        System.tmp_dir!(),
        "bp-taskdoor-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(root)
    instance = "taskdoor-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

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
      Content.create_document("post", %{"_id" => "task-door", "title" => "before"}, "test")

    %{gate: gate, doc: doc}
  end

  test "open admits the fenced write and the event; held refuses both by raising", %{
    gate: gate,
    doc: doc
  } do
    content = Map.put(doc.content || %{}, "note", "open")
    assert {:ok, stored} = Internal.fenced_content_write(doc, doc.rev, content, "rev-open")
    assert stored.rev == "rev-open"

    assert %Barkpark.Content.MutationEvent{} =
             Internal.insert_mutation_event!(stored, "patch", doc.rev)

    assert Admission.status(gate).pending == 0

    holder = hold(gate)

    assert_raise Refused, fn ->
      Internal.fenced_content_write(
        stored,
        stored.rev,
        Map.put(content, "note", "held"),
        "rev-held"
      )
    end

    assert_raise Refused, fn -> Internal.insert_mutation_event!(stored, "patch", stored.rev) end
    {:ok, unchanged} = Content.get_document("drafts.task-door", "post", "test")
    assert unchanged.rev == "rev-open"
    assert Admission.status(gate).phase == :held
    send(holder, :release)
    assert_receive {:released, :ok}
    assert {:ok, _} = Internal.fenced_content_write(stored, stored.rev, content, "rev-after")
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
end
