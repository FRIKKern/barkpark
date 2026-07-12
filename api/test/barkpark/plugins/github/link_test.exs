defmodule Barkpark.Plugins.Github.LinkTest do
  @moduledoc """
  Wave-1 slice-5: the `content.github` Link helper (epic D3).

  Round-trips `content.github` through `Link.get/put`, asserts the write is
  stamped `source="github"` on the emitted `mutation_events` row (D4 cut #2),
  patch-merges rather than clobbers, and that `synced?/1` is true ONLY when the
  stored `synced_rev` equals the task's current `_rev` (D4 cut #3).
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Link, Outbox}

  @dataset "production"

  setup do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

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

  defp mk_task!(doc_id, scope) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" =>
            Barkpark.LabelFixtures.with_labels(%{"kind" => "task", "lifecycle_status" => "open"})
        },
        @dataset,
        scope
      )

    doc
  end

  # A task that is CREATED then PUBLISHED — the collapse path's precondition.
  defp mk_published_task!(doc_id, scope) do
    _draft = mk_task!(doc_id, scope)
    {:ok, published} = Content.publish_document(doc_id, "task", @dataset, scope)
    published
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp github_events(doc_id) do
    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^doc_id and e.source == "github",
        order_by: e.id
    )
  end

  defp max_event_id(dataset) do
    Repo.one(from(e in MutationEvent, where: e.dataset == ^dataset, select: max(e.id))) || 0
  end

  describe "get/1" do
    test "returns nil when the task has never been mirrored", %{scope: scope} do
      task = mk_task!(uniq("gh"), scope)
      assert Link.get(task) == nil
    end

    test "reads back what put/4 wrote", %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)

      {:ok, doc} =
        Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 42, state: "synced"}, scope)

      assert %{"repo" => "FRIKKern/barkpark", "issue" => 42, "state" => "synced"} = Link.get(doc)
    end
  end

  describe "put/4" do
    test "stamps source=\"github\" on the emitted mutation_event", %{scope: scope} do
      id = uniq("gh")
      task = mk_task!(id, scope)

      {:ok, doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 7}, scope)

      events = github_events(doc.doc_id)
      assert length(events) == 1
      [ev] = events
      assert ev.source == "github"
      # The bookkeeping write must not disturb the task's own content contract.
      refute doc.rev == task.rev
      assert doc.content["kind"] == "task"
      assert doc.content["lifecycle_status"] == "open"
    end

    test "patch-merges into existing content.github (partial write preserves rest)",
         %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)

      {:ok, _} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 99}, scope)
      # A later partial write of only synced_rev must keep repo + issue.
      {:ok, doc} = Link.put(id, @dataset, %{synced_rev: "abc123"}, scope)

      assert %{
               "repo" => "FRIKKern/barkpark",
               "issue" => 99,
               "synced_rev" => "abc123"
             } = Link.get(doc)
    end

    test "returns {:error, :not_found} for an unknown task", %{scope: scope} do
      assert {:error, :not_found} =
               Link.put(uniq("ghost"), @dataset, %{repo: "x/y", issue: 1}, scope)
    end

    test "leaves a never-published task a DRAFT (no force-publish under a user)",
         %{scope: scope} do
      id = uniq("gh")
      _draft = mk_task!(id, scope)

      {:ok, _doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 11}, scope)

      # No published row was conjured — the bookkeeping lives on the draft.
      assert {:error, :not_found} =
               Content.get_document(Content.published_id(id), "task", @dataset, scope)

      {:ok, draft} = Content.get_document(Content.draft_id(id), "task", @dataset, scope)
      assert %{"repo" => "FRIKKern/barkpark", "issue" => 11} = Link.get(draft)
    end

    test "collapses the draft twin back into an ALREADY-published task (D12)",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_published_task!(id, scope)

      {:ok, _doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 9}, scope)

      # No permanent draft twin remains — the stamp was collapsed into published.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(id), "task", @dataset, scope)

      # The bookkeeping landed on the surviving published row.
      {:ok, published} = Content.get_document(Content.published_id(id), "task", @dataset, scope)
      assert %{"repo" => "FRIKKern/barkpark", "issue" => 9} = Link.get(published)
      assert published.status == "published"
    end
  end

  describe "loop immunity (D12 capstone)" do
    test "neither the stamp NOR the collapse-publish is drainable by the Outbox",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_published_task!(id, scope)

      # Everything the setup emitted is <= max_id; only the bookkeeping path's
      # events fall strictly after it.
      max_id = max_event_id(@dataset)

      {:ok, _doc} =
        Link.put(
          id,
          @dataset,
          %{repo: "FRIKKern/barkpark", issue: 7, synced_rev: "rev-a", state: "synced"},
          scope
        )

      # HARD invariant: every mutation_event the bookkeeping path emitted — the
      # draft stamp AND the collapse publish — carries source="github", so the
      # Outbox excludes them ALL. The mirror can never re-drain its own write.
      assert Outbox.fetch(@dataset, max_id, 100) == []

      # And the (formerly-published) task carries no permanent draft twin.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(id), "task", @dataset, scope)
    end
  end

  describe "synced?/1" do
    test "false when content.github is absent", %{scope: scope} do
      task = mk_task!(uniq("gh"), scope)
      refute Link.synced?(task)
    end

    test "false when the stored synced_rev lags the doc's current _rev", %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)

      # The stamp write ITSELF bumps the rev, so the returned doc's _rev never
      # equals the synced_rev it just stored — documents the D4-cut-#3 reality
      # (the source=github outbox exclusion, not this equality, is the loop's
      # primary guard; this check catches coalesced/duplicate MirrorJobs).
      {:ok, doc} = Link.put(id, @dataset, %{synced_rev: "whatever"}, scope)
      refute Link.synced?(doc)
    end

    test "true exactly when synced_rev == _rev (envelope form)" do
      gh = %{"repo" => "FRIKKern/barkpark", "issue" => 3, "synced_rev" => "rev-xyz"}

      matched = %{"content" => %{"github" => gh}, "_rev" => "rev-xyz"}
      assert Link.synced?(matched)

      mismatched = %{"content" => %{"github" => gh}, "_rev" => "rev-other"}
      refute Link.synced?(mismatched)
    end

    test "true on a %Document{} whose rev matches its stored synced_rev", %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)
      {:ok, doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 5}, scope)

      # Read the live row, then hand-build a Document carrying synced_rev == its
      # own rev — proving synced?/1 keys off the %Document{}.rev field.
      {:ok, current} = Content.get_document(Content.draft_id(id), "task", @dataset, scope)
      github = Link.get(current) |> Map.put("synced_rev", current.rev)
      synced_doc = %{current | content: Map.put(current.content, "github", github)}

      assert Link.synced?(synced_doc)
      refute Link.synced?(current)
      refute Link.synced?(doc)
    end
  end
end
