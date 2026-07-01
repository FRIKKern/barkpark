defmodule Barkpark.Content.WikilinkTaskChipTest do
  @moduledoc """
  lvw-t7 — the TYPE-DISPATCHED wikilink resolver behind the live task chip
  (wire §4/§5 as amended):

    1. `resolve_wikilink/3` falls through paper → task, growing the hit to
       `%{id, title, kind, status, priority, criteria}` for tasks.
    2. Paper PRECEDENCE — a title naming both stays a paper link.
    3. `criteria` is the garbage-tolerant `{met, total}` count (met === true),
       nil when absent (renderers then omit the segment — never 0/0).
    4. `resolve_wikilinks_in_blocks/3` collects id-pinned `docId`s into
       `{:id, id}` palette keys (both draft/published spellings resolve), all
       through the batched per-type query.
    5. D5 — `published_only: true` (the anonymous-surface gate): a draft-only
       task does NOT resolve (no title/state leak; the link degrades), a
       published task does.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Tasks}

  @dataset "wikilink_task_chip_test"

  setup do
    Content.upsert_schema(
      %{
        "name" => "paper",
        "title" => "Paper",
        "visibility" => "public",
        "fields" => [%{"name" => "aliases", "type" => "arrayOf", "of" => %{"type" => "string"}}]
      },
      @dataset
    )

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    :ok
  end

  defp paper!(id, title, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        "paper",
        Map.merge(%{"_id" => id, "title" => title}, attrs),
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, "paper", @dataset)
    doc
  end

  defp task!(id, title, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset
      )

    doc
  end

  test "a task-titled target resolves to the full chip hit" do
    task!("t-chip", "Fix the resolver", %{
      "lifecycle_status" => "in_progress",
      "priority" => 1,
      "acceptance_criteria" => [
        %{"criterion" => "a", "met" => true},
        %{"criterion" => "b", "met" => false},
        %{"criterion" => "c", "met" => true}
      ]
    })

    assert %{
             id: "t-chip",
             title: "Fix the resolver",
             kind: "task",
             status: "in_progress",
             priority: 1,
             criteria: %{met: 2, total: 3}
           } = Content.resolve_wikilink("Fix the resolver", @dataset)
  end

  test "paper hits carry kind: \"paper\" and keep the historical shape" do
    paper!("p-1", "A Paper")

    assert %{id: "p-1", title: "A Paper", kind: "paper"} =
             Content.resolve_wikilink("A Paper", @dataset)
  end

  test "paper PRECEDENCE: a title naming both a paper and a task stays a paper" do
    paper!("p-shared", "Shared Title")
    task!("t-shared", "Shared Title")

    assert %{id: "p-shared", kind: "paper"} = Content.resolve_wikilink("Shared Title", @dataset)
  end

  test "criteria are garbage-tolerant: non-boolean / missing met count as unmet" do
    # (A non-map ENTRY can't even be persisted — validation.ex enforces
    # "list of maps" at write time; the resolver additionally tolerates it.)
    task!("t-garbage", "Garbage Criteria", %{
      "acceptance_criteria" => [
        %{"criterion" => "ok", "met" => true},
        %{"criterion" => "stringy", "met" => "yes"},
        %{"criterion" => "truthy-string", "met" => "true"},
        %{"criterion" => "missing"}
      ]
    })

    assert %{criteria: %{met: 1, total: 4}} =
             Content.resolve_wikilink("Garbage Criteria", @dataset)
  end

  test "criteria-absent resolves criteria: nil (renderers omit the segment)" do
    task!("t-bare", "Bare Task")

    assert %{kind: "task", criteria: nil, priority: nil} =
             Content.resolve_wikilink("Bare Task", @dataset)
  end

  test "in_blocks: id-pinned docId lands under an {:id, id} palette key, both spellings" do
    task!("t-pin", "Pinned Task", %{"priority" => 0})

    blocks = [
      %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [
          # The wire §4 chip node: target = the task doc id, docId pinned,
          # alias set, children empty.
          %{
            "type" => "wikilink",
            "target" => "t-pin",
            "docId" => "t-pin",
            "alias" => "the pinned task",
            "children" => []
          }
        ]
      }
    ]

    map = Content.resolve_wikilinks_in_blocks(blocks, @dataset)

    assert %{kind: "task", id: "t-pin", priority: 0} = Map.fetch!(map, {:id, "t-pin"})

    # The drafts. spelling pins to the same task (rows live as drafts.<id>).
    draft_blocks =
      put_in(blocks, [Access.at(0), "content", Access.at(0), "docId"], "drafts.t-pin")

    draft_map = Content.resolve_wikilinks_in_blocks(draft_blocks, @dataset)
    assert %{kind: "task", id: "t-pin"} = Map.fetch!(draft_map, {:id, "drafts.t-pin"})
  end

  test "in_blocks: title-keyed task target rides the same batched map" do
    task!("t-title", "Titled Task")

    blocks = [
      %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [
          %{
            "type" => "wikilink",
            "target" => "Titled Task",
            "children" => [%{"type" => "text", "value" => "x"}]
          }
        ]
      }
    ]

    map = Content.resolve_wikilinks_in_blocks(blocks, @dataset)
    assert %{kind: "task", id: "t-title", status: "open"} = Map.fetch!(map, "Titled Task")
  end

  test "D5: published_only hides a DRAFT-only task entirely (no title/state leak)" do
    task!("t-draft", "Secret Draft Task")

    # Authorized surface (Studio): resolves.
    assert %{kind: "task"} = Content.resolve_wikilink("Secret Draft Task", @dataset)

    # Anonymous surface: the draft-only task does NOT resolve — the wikilink
    # degrades to its alias/children downstream, leaking nothing.
    assert Content.resolve_wikilink("Secret Draft Task", @dataset, published_only: true) == nil

    blocks = [
      %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [
          %{
            "type" => "wikilink",
            "target" => "Secret Draft Task",
            "docId" => "t-draft",
            "children" => []
          }
        ]
      }
    ]

    map = Content.resolve_wikilinks_in_blocks(blocks, @dataset, published_only: true)
    assert map == %{}
  end

  test "D5: a PUBLISHED task resolves rich state through published_only" do
    task!("t-pub", "Published Task", %{"priority" => 2})
    {:ok, _} = Content.publish_document("t-pub", "task", @dataset)

    assert %{kind: "task", id: "t-pub", status: "open", priority: 2} =
             Content.resolve_wikilink("Published Task", @dataset, published_only: true)
  end

  test "D5: published_only also gates papers fail-closed" do
    # Papers are published on upsert, but a hand-created draft-only paper must
    # not leak either — the gate is type-agnostic.
    {:ok, _} =
      Content.create_document("paper", %{"_id" => "p-draft", "title" => "Draft Paper"}, @dataset)

    assert Content.resolve_wikilink("Draft Paper", @dataset, published_only: true) == nil
    assert %{kind: "paper"} = Content.resolve_wikilink("Draft Paper", @dataset)
  end
end
