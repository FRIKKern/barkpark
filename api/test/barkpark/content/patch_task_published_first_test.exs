defmodule Barkpark.Content.PatchTaskPublishedFirstTest do
  @moduledoc """
  task-b9c618482e688500 — a `patch` on a `type:task` must land on the row the
  task API reads.

  `Content.Mutations.get_patch_base/4` resolved EVERY patch base through
  `DraftId.draft_id/1` (draft-first) while the task read door
  (`tasks_controller.ex find_task_by_doc_id/2`, the board, the ready queue)
  resolves PUBLISHED-first with a `drafts.` fallback. The two doors disagreed
  about which row `task-…` names, silently: measured live on guerrilla
  2026-09-02, a patch carrying the rev `GET /v1/tasks/<id>` served 412'd (the
  actual rev being the twin's) and a patch carrying the TWIN's rev returned 200
  writing `drafts.task-…` while every reader kept serving the old row.

  These tests pin the repair AT THE RESOLVER, which is where the row asks for
  it. The load-bearing case is `a patch whose twin exists`: with a twin
  present, draft-first and published-first return DIFFERENT documents, so
  reverting `get_patch_base/4` to `DraftId.draft_id(id)`-first turns the
  refusal into a 200 and reds these tests. Without a twin the two resolvers
  agree on the base and only the LANDING differs — pinned separately by the
  no-twin test's read-back of the published row.

  The last two tests are the fence: an ordinary content type and an explicitly
  draft-addressed id keep draft-first semantics byte for byte.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.DraftId

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content(extra) do
    %{"kind" => "task", "lifecycle_status" => "open"}
    |> Map.merge(extra)
    |> LabelFixtures.with_registered_labels(@dataset)
  end

  # A task that really lives at its BARE (published) doc_id, with NO draft twin
  # left behind — `publish_document/4` deletes the draft it published.
  defp mk_published_task!(scope, extra) do
    id = uniq("pfp-task")

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => id, "title" => id, "content" => task_content(extra)},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, "task", @dataset, scope)

    assert {:error, :not_found} =
             Content.get_document(DraftId.draft_id(id), "task", @dataset, scope)

    id
  end

  defp patch(id, set_fields, scope, extra \\ %{}) do
    op = Map.merge(%{"id" => id, "type" => "task", "set" => set_fields}, extra)
    Content.apply_mutations([%{"patch" => op}], @dataset, [source: :api] ++ scope)
  end

  describe "get_patch_base/4 resolves a bare type:task PUBLISHED-first" do
    test "a patch carrying the PUBLISHED row's rev lands on the published row", %{scope: scope} do
      id = mk_published_task!(scope, %{"note" => "before"})
      {:ok, published} = Content.get_document(id, "task", @dataset, scope)

      # The rev the task API serves (`Params.render_doc` → `rev: doc.rev` off
      # `find_task_by_doc_id/2`'s published-first read) is the precondition.
      assert {:ok, {_tx, [result]}} =
               patch(id, %{"note" => "after"}, scope, %{"ifRevisionID" => published.rev})

      assert result[:id] == id or result["id"] == id,
             "the receipt must name the PUBLISHED id, not the twin: #{inspect(result)}"

      {:ok, reread} = Content.get_document(id, "task", @dataset, scope)
      assert reread.content["note"] == "after"

      assert {:error, :not_found} =
               Content.get_document(DraftId.draft_id(id), "task", @dataset, scope),
             "landing publishes the draft it wrote — no twin may survive the patch"
    end

    test "an EXISTING draft twin is refused, and the refusal NAMES it", %{scope: scope} do
      id = mk_published_task!(scope, %{"note" => "published"})

      # Re-create the twin alongside the published row (the state 22 live rows
      # were found in). Under a draft-first resolver THIS is the merge base.
      {:ok, twin} =
        Content.create_document(
          "task",
          %{"doc_id" => id, "title" => id, "content" => task_content(%{"note" => "stale twin"})},
          @dataset,
          scope
        )

      assert twin.doc_id == DraftId.draft_id(id)

      assert {:error, {:invalid_task_content, details}} =
               patch(id, %{"note" => "after"}, scope)

      [message] = details["_id"]
      assert message =~ DraftId.draft_id(id)
      assert message =~ "discardDraft"

      {:ok, reread} = Content.get_document(id, "task", @dataset, scope)
      assert reread.content["note"] == "published", "a refused patch writes nothing"

      {:ok, twin_after} = Content.get_document(DraftId.draft_id(id), "task", @dataset, scope)
      assert twin_after.content["note"] == "stale twin", "the twin must not be destroyed either"
    end

    test "a task with NO published row still resolves and writes draft-first", %{scope: scope} do
      id = uniq("pfp-unpub")

      {:ok, draft} =
        Content.create_document(
          "task",
          %{"doc_id" => id, "title" => id, "content" => task_content(%{"note" => "before"})},
          @dataset,
          scope
        )

      assert {:ok, {_tx, [_result]}} =
               patch(id, %{"note" => "after"}, scope, %{"ifRevisionID" => draft.rev})

      {:ok, reread} = Content.get_document(DraftId.draft_id(id), "task", @dataset, scope)
      assert reread.content["note"] == "after"

      assert {:error, :not_found} = Content.get_document(id, "task", @dataset, scope),
             "no published row existed and none may be minted — this is find_task_by_doc_id's own fallback"
    end
  end

  describe "the fence: everything else keeps draft-first semantics" do
    test "an ordinary content type still patches its draft twin", %{scope: scope} do
      id = uniq("pfp-post")

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => id, "content" => %{"note" => "before"}},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(id, "post", @dataset, scope)

      assert {:ok, {_tx, [_result]}} =
               Content.apply_mutations(
                 [%{"patch" => %{"id" => id, "type" => "post", "set" => %{"note" => "after"}}}],
                 @dataset,
                 [source: :api] ++ scope
               )

      {:ok, published} = Content.get_document(id, "post", @dataset, scope)

      assert published.content["note"] == "before",
             "a post patch is a DRAFT edit — publishing it on write would turn the CMS into publish-on-write"

      {:ok, draft} = Content.get_document(DraftId.draft_id(id), "post", @dataset, scope)
      assert draft.content["note"] == "after"
    end

    test "a task patch addressed to `drafts.<id>` still edits the twin", %{scope: scope} do
      id = mk_published_task!(scope, %{"note" => "published"})

      {:ok, _twin} =
        Content.create_document(
          "task",
          %{"doc_id" => id, "title" => id, "content" => task_content(%{"note" => "twin"})},
          @dataset,
          scope
        )

      assert {:ok, {_tx, [_result]}} =
               patch(DraftId.draft_id(id), %{"note" => "twin edited"}, scope)

      {:ok, twin_after} = Content.get_document(DraftId.draft_id(id), "task", @dataset, scope)
      assert twin_after.content["note"] == "twin edited"

      {:ok, published} = Content.get_document(id, "task", @dataset, scope)
      assert published.content["note"] == "published"
    end
  end
end
