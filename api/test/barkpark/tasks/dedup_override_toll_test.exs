defmodule Barkpark.Tasks.DedupOverrideTollTest do
  @moduledoc """
  The `distinct_from` override COSTS SOMETHING once it is used against more
  than one existing row with the same normalized title (task-d0960476e03c0c30).

  THE MEASURED INCIDENT. Four copies of one task were created inside 127
  seconds on 2026-08-02, each naming its predecessors in its own
  `distinct_from`, all four carrying the identical title:

      11:25:41  drafts.task-834b13e3…  distinct_from = []
      11:26:52  drafts.task-3a889e08…  distinct_from = [834b13e3]
      11:27:12  drafts.task-d2954ebb…  distinct_from = [834b13e3, 3a889e08]
      11:27:48  task-42ad3595…         distinct_from = [834b13e3, 3a889e08, d2954ebb]

  The wall fired correctly at every copy and was told to stand down every time.
  This is NOT the wall-sensitivity defect (a detector that fails to fire) — that
  is a different row on a different lane, and nothing here touches detection.
  Every test below drives the OVERRIDE path with the wall working.

  ## What reds each test

  `the third copy` and `a repeated reason` red if `override_toll/5` stops
  refusing — delete the `@free_same_title_overrides` comparison, or widen it,
  and the create is allowed with no explanation, which is the shipped defect.

  The three CONTROLS red if the toll over-reaches: one same-title override, a
  differently-titled override, and same-title epic siblings must all stay free,
  because charging those would tax ordinary practice rather than the incident.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  # The incident's own shape: one title, several rows.
  @title "The eight stranded PRs get a verdict each: merged, refused in writing, or re-filed"
  @desc "walk the eight stranded PRs and give each one a written disposition"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp create(doc_id, title, scope, extra) do
    content =
      Map.merge(%{"kind" => "task", "lifecycle_status" => "open", "description" => @desc}, extra)

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      scope
    )
  end

  describe "a second same-title assertion has to be explained" do
    test "the third copy of one title, overriding two predecessors with no reason, is REFUSED",
         %{scope: scope} do
      # Copy 1 — nothing to override yet.
      assert {:ok, _} = create("copy-one", @title, scope, %{"parent_id" => "epic-a"})

      # Copy 2 — the wall fires once, one bare id waves it through. FREE.
      assert {:ok, _} =
               create("copy-two", @title, scope, %{
                 "parent_id" => "epic-b",
                 "distinct_from" => ["copy-one"]
               })

      # Copy 3 — the wall fires twice and the author dismisses both with bare
      # ids. This is the 11:27:12 row from the incident, and it is REFUSED.
      assert {:error, {:duplicate_task, payload}} =
               create("copy-three", @title, scope, %{
                 "parent_id" => "epic-c",
                 "distinct_from" => ["copy-one", "copy-two"]
               })

      assert payload.message =~ "SAME normalized title"
      assert payload.message =~ "distinct_from_reason"
      assert payload.message =~ "NO REASON GIVEN FOR"
      assert payload.message =~ "copy-one"
      assert payload.message =~ "copy-two"

      # The refusal names the rows it is talking about, so the author can act.
      assert MapSet.new(payload.similar, & &1.id) == MapSet.new(["copy-one", "copy-two"])
    end

    test "the same create SUCCEEDS once each id carries its own reason", %{scope: scope} do
      assert {:ok, _} = create("r-one", @title, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} =
               create("r-two", @title, scope, %{
                 "parent_id" => "epic-b",
                 "distinct_from" => ["r-one"]
               })

      assert {:ok, doc} =
               create("r-three", @title, scope, %{
                 "parent_id" => "epic-c",
                 "distinct_from" => ["r-one", "r-two"],
                 "distinct_from_reason" => %{
                   "r-one" => "r-one is the API half; this row is the CLI half",
                   "r-two" => "r-two was cancelled upstream and covers the docs only"
                 }
               })

      # The justification persists on the document, next to the trail it explains.
      assert doc.content["distinct_from_reason"]["r-one"] =~ "API half"
    end

    test "one reason copy-pasted across both ids is REFUSED as the bulk assertion it is",
         %{scope: scope} do
      assert {:ok, _} = create("d-one", @title, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} =
               create("d-two", @title, scope, %{
                 "parent_id" => "epic-b",
                 "distinct_from" => ["d-one"]
               })

      assert {:error, {:duplicate_task, payload}} =
               create("d-three", @title, scope, %{
                 "parent_id" => "epic-c",
                 "distinct_from" => ["d-one", "d-two"],
                 "distinct_from_reason" => %{
                   "d-one" => "different scope",
                   "d-two" => "Different scope  "
                 }
               })

      assert payload.message =~ "THE SAME REASON IS REUSED FOR"
      assert payload.message =~ "d-one"
      assert payload.message =~ "d-two"
    end

    test "an empty-string reason is no reason at all", %{scope: scope} do
      assert {:ok, _} = create("b-one", @title, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} =
               create("b-two", @title, scope, %{
                 "parent_id" => "epic-b",
                 "distinct_from" => ["b-one"]
               })

      assert {:error, {:duplicate_task, payload}} =
               create("b-three", @title, scope, %{
                 "parent_id" => "epic-c",
                 "distinct_from" => ["b-one", "b-two"],
                 "distinct_from_reason" => %{
                   "b-one" => "   ",
                   "b-two" => "genuinely the observability slice, not the ingest one"
                 }
               })

      assert payload.message =~ "NO REASON GIVEN FOR: b-one"
      refute payload.message =~ "NO REASON GIVEN FOR: b-one, b-two"
    end
  end

  describe "controls — the toll does not tax ordinary practice" do
    test "ONE same-title override stays free", %{scope: scope} do
      assert {:ok, _} = create("c1-one", @title, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} =
               create("c1-two", @title, scope, %{
                 "parent_id" => "epic-b",
                 "distinct_from" => ["c1-one"]
               })
    end

    test "two overrides against DIFFERENT titles stay free", %{scope: scope} do
      # Both rows score high enough to refuse (same description, near titles)
      # but neither shares the new row's normalized title, so neither is tolled.
      assert {:ok, _} = create("c2-one", "Give the eight stranded PRs a verdict", scope, %{})
      assert {:ok, _} = create("c2-two", "Verdicts for the eight stranded PRs", scope, %{})

      assert {:ok, _} =
               create("c2-three", "Stranded PR verdicts, written down", scope, %{
                 "distinct_from" => ["c2-one", "c2-two"]
               })
    end

    test "same-title EPIC SIBLINGS stay free even when named in distinct_from", %{scope: scope} do
      # `Similarity.score/6` checks the distinct set BEFORE the structural
      # relation, so a sibling named in `distinct_from` is reported as excluded
      # too — but structure, not the override, is what saved it. The
      # 50-identical-card fixtures in `TasksControllerTest` are exactly this
      # shape, and the toll must not touch them.
      assert {:ok, _} = create("s-one", @title, scope, %{"parent_id" => "phase-shared"})
      assert {:ok, _} = create("s-two", @title, scope, %{"parent_id" => "phase-shared"})

      assert {:ok, _} =
               create("s-three", @title, scope, %{
                 "parent_id" => "phase-shared",
                 "distinct_from" => ["s-one", "s-two"]
               })
    end
  end

  describe "the toll is on the OVERRIDE path only" do
    test "a create refused on its merits still gets the ordinary refusal", %{scope: scope} do
      assert {:ok, _} = create("m-one", @title, scope, %{"parent_id" => "epic-a"})

      assert {:error, {:duplicate_task, payload}} =
               create("m-two", @title, scope, %{"parent_id" => "epic-b"})

      assert payload.message =~ "this task looks like an existing one"
      refute payload.message =~ "distinct_from_reason"
    end
  end
end
