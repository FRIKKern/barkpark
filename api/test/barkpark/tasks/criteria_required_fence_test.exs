defmodule Barkpark.Tasks.CriteriaRequiredFenceTest do
  @moduledoc """
  The criteria-required birth fence, OPT-IN PER PARENT
  (dr-w33-bl-task-create-refuses-criteria-less-rows).

  MEASURED OPEN, THREE TIMES IN TWENTY-FOUR HOURS before this fence existed:
  seven zero-criteria rows censused 2026-08-08 and backfilled, then SIX
  BRAND-NEW ones on 2026-08-09 with zero overlap — four filed within nine
  hours, one p0. `dr-w19`'s own prose named the cause: "the census COUNTS the
  disease; nothing REFUSES the write." Nothing did:
  `Plugins.Tasks.warn_if_create_zero/1` logs and SAVES, and
  `Validation.check_acceptance_criteria/2` returns `errors` untouched on `nil`.

  THE REFUSAL TEST BELOW IS MUTATION-PROVEN: collapsing
  `CriteriaRequiredFence.check/6` to `:ok` reds "a criteria-less BIRTH under a
  flagged parent is REFUSED" and ONLY that test — the six control tests, which
  pin what the fence must NOT break, stay green either way. That is the point:
  a guard that cannot lose was never measuring anything.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "criteria_required_fence_test"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

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

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp content(extra) do
    %{"kind" => "task", "lifecycle_status" => "open"}
    |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # The Writer seam — the door every raw document write funnels through. A
  # create lands as `drafts.<id>`, which is exactly the population the fence
  # must see: the rail counts drafts (dr-bl-w6-phantom-draft-twins).
  defp write(doc_id, extra, scope) do
    Content.create_document(
      "task",
      %{
        "doc_id" => doc_id,
        "title" => "criteria-required fence fixture #{doc_id}",
        "content" => content(extra)
      },
      @dataset,
      scope
    )
  end

  defp some_criteria, do: [%{"criterion" => "the child states what would prove it done"}]

  # A parent that has opted IN. It carries its own criteria so its own birth is
  # never the thing under test.
  defp flagged_parent!(doc_id, scope) do
    {:ok, parent} =
      write(
        doc_id,
        %{"require_criteria" => true, "acceptance_criteria" => some_criteria()},
        scope
      )

    assert parent.content["require_criteria"] == true
    parent
  end

  # ── (a) THE HOLE — refused ───────────────────────────────────────────────

  test "a criteria-less BIRTH under a flagged parent is REFUSED, naming the field " <>
         "and the parent's flag",
       %{scope: scope} do
    flagged_parent!("crf-parent-refuse", scope)

    result = write("crf-child-refuse", %{"parent_id" => "crf-parent-refuse"}, scope)

    assert {:error, {:invalid_task_content, details}} = result
    message = details["acceptance_criteria"] |> List.first()
    assert message =~ "require_criteria"
    assert message =~ "crf-parent-refuse"
    assert message =~ "unfalsifiable"

    # And the row was not born.
    assert {:error, _} =
             Content.get_document("drafts.crf-child-refuse", "task", @dataset, scope)
  end

  test "an EMPTY criteria list is the same population as an absent one — also REFUSED",
       %{scope: scope} do
    flagged_parent!("crf-parent-empty", scope)

    assert {:error, {:invalid_task_content, details}} =
             write(
               "crf-child-empty",
               %{"parent_id" => "crf-parent-empty", "acceptance_criteria" => []},
               scope
             )

    assert details["acceptance_criteria"] |> List.first() =~ "require_criteria"
  end

  # ── (b) THE ESCAPE — a well-formed child still lands ─────────────────────

  test "a child that STATES its criteria lands under the same flagged parent",
       %{scope: scope} do
    flagged_parent!("crf-parent-ok", scope)

    assert {:ok, doc} =
             write(
               "crf-child-ok",
               %{"parent_id" => "crf-parent-ok", "acceptance_criteria" => some_criteria()},
               scope
             )

    assert doc.content["acceptance_criteria"] |> length() == 1
  end

  # ── (c) THE OPT-IN — everything else is byte-for-byte unaffected ─────────

  test "OPT-IN: a criteria-less child of an UNFLAGGED parent still lands — the whole " <>
         "reason this is per-parent and not global",
       %{scope: scope} do
    {:ok, _} = write("crf-parent-off", %{"acceptance_criteria" => some_criteria()}, scope)

    assert {:ok, doc} = write("crf-child-off", %{"parent_id" => "crf-parent-off"}, scope)
    assert doc.content["parent_id"] == "crf-parent-off"
  end

  test "OPT-IN: a criteria-less ROOT row still lands, and pays no parent read",
       %{scope: scope} do
    assert {:ok, doc} = write("crf-root", %{}, scope)
    assert doc.content["acceptance_criteria"] == nil
  end

  test "an UPDATE of an already criteria-less child under a flagged parent still lands — " <>
         "the fence is about the BIRTH, and mutate merges patches BEFORE it validates",
       %{scope: scope} do
    # Born BEFORE the parent opted in: the exact mid-flight row the row warned a
    # global refusal would strand.
    {:ok, _} = write("crf-parent-late", %{"acceptance_criteria" => some_criteria()}, scope)
    {:ok, _} = write("crf-child-late", %{"parent_id" => "crf-parent-late"}, scope)

    {:ok, parent} =
      Content.get_document("drafts.crf-parent-late", "task", @dataset, scope)

    {:ok, _} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => parent.doc_id,
          "title" => parent.title,
          "content" => Map.put(parent.content, "require_criteria", true)
        },
        @dataset,
        scope
      )

    {:ok, child} = Content.get_document("drafts.crf-child-late", "task", @dataset, scope)

    assert {:ok, updated} =
             Content.upsert_document(
               "task",
               %{
                 "doc_id" => child.doc_id,
                 "title" => child.title,
                 "content" => Map.put(child.content, "blocked_reason", "still unrelated")
               },
               @dataset,
               scope
             )

    assert updated.content["blocked_reason"] == "still unrelated"
  end

  # ── (d) THE FLAG'S OWN SHAPE — a typo must not silently disarm the fence ──

  test "`require_criteria` must be a boolean: a typo'd \"true\" is REFUSED rather than " <>
         "read as absent",
       %{scope: scope} do
    assert {:error, {:invalid_task_content, details}} =
             write(
               "crf-typo",
               %{"require_criteria" => "true", "acceptance_criteria" => some_criteria()},
               scope
             )

    assert details["require_criteria"] |> List.first() =~ "must be a boolean when set"
  end
end
