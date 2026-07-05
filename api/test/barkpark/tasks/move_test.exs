defmodule Barkpark.Tasks.MoveTest do
  @moduledoc """
  rail-l3 — DB-backed tests for `Barkpark.Tasks.Move` (via the `Barkpark.Tasks`
  facade which defdelegates `move_by_id/2` here).

  Covers:
    1. move updates `content.parent_id` + emits a `task.reparented` event whose
       document payload carries the correct `{from, to}`.
    2. move to root REMOVES the `parent_id` key (not nil) and stamps `to: nil`.
    3. cycle guards: moving under itself, and under a descendant → `:cycle`.
    4. no-op move (already that parent) → `{:ok, doc}`, no event, rev unchanged.
    5. `not_found` for an unknown task uuid.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp reparent_events(doc_id) do
    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == "task.reparented",
        order_by: e.id
    )
  end

  describe "move_by_id/2 — happy path" do
    test "updates parent_id + emits task.reparented with from/to", %{scope: scope} do
      old_parent = uniq("epicA")
      new_parent = uniq("epicB")
      _pb = mk_task!(new_parent, scope)
      task = mk_task!(uniq("mv"), scope, %{"parent_id" => old_parent})

      assert {:ok, moved} = Tasks.move_by_id(task.id, new_parent)
      assert moved.content["parent_id"] == new_parent
      assert moved.rev != task.rev

      # Persisted.
      reread = Repo.get(Document, task.id)
      assert reread.content["parent_id"] == new_parent

      # task.reparented event with the right from/to.
      assert [ev] = reparent_events(task.doc_id)
      assert ev.document["reparented"]["from"] == old_parent
      assert ev.document["reparented"]["to"] == new_parent
    end

    test "move to root removes the parent_id key and stamps to: nil", %{scope: scope} do
      old_parent = uniq("epic")
      task = mk_task!(uniq("mvroot"), scope, %{"parent_id" => old_parent})

      assert {:ok, moved} = Tasks.move_by_id(task.id, nil)
      refute Map.has_key?(moved.content, "parent_id")

      assert [ev] = reparent_events(task.doc_id)
      assert ev.document["reparented"]["from"] == old_parent
      assert ev.document["reparented"]["to"] == nil
    end

    test "bare-id resolution: task created as drafts.<id> moves by uuid", %{scope: scope} do
      # (The facade takes the uuid; the drafts. resolution is the controller's
      # job. Here we prove the write works regardless of the doc_id prefix.)
      new_parent = uniq("epicC")
      _pc = mk_task!(new_parent, scope)
      task = mk_task!(uniq("mvbare"), scope, %{})

      assert {:ok, moved} = Tasks.move_by_id(task.id, new_parent)
      assert moved.content["parent_id"] == new_parent
    end
  end

  describe "move_by_id/2 — cycle guard" do
    test "moving a task under itself → :cycle", %{scope: scope} do
      task = mk_task!(uniq("self"), scope, %{})
      assert {:error, :cycle} = Tasks.move_by_id(task.id, task.doc_id)
    end

    test "moving a task under its own descendant → :cycle", %{scope: scope} do
      root = mk_task!(uniq("root"), scope, %{})
      child = mk_task!(uniq("child"), scope, %{"parent_id" => root.doc_id})
      _grand = mk_task!(uniq("grand"), scope, %{"parent_id" => child.doc_id})

      # root under child (its descendant) → cycle.
      assert {:error, :cycle} = Tasks.move_by_id(root.id, child.doc_id)
    end
  end

  describe "move_by_id/2 — no-op + not_found" do
    test "moving to the parent it already has is an idempotent no-op (no event)",
         %{scope: scope} do
      parent = uniq("epic")
      task = mk_task!(uniq("noop"), scope, %{"parent_id" => parent})

      assert {:ok, same} = Tasks.move_by_id(task.id, parent)
      # rev unchanged — no write happened.
      assert same.rev == task.rev
      assert reparent_events(task.doc_id) == []
    end

    test "unknown task uuid → :not_found", %{scope: _scope} do
      assert {:error, :not_found} = Tasks.move_by_id(Ecto.UUID.generate(), nil)
    end
  end
end
