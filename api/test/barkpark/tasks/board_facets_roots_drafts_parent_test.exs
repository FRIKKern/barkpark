defmodule Barkpark.Tasks.BoardFacetsRootsDraftsParentTest do
  @moduledoc """
  The board's GOAL CHIP, ROOT TEST and GOAL SWIMLANE resolve `parent_id` through
  the published-id rule (task-dee8b2c71e2282d9).

  PR #17952 fixed exactly one of five readers — `Board.attach_subtasks/1` — because
  its criterion named only that one. `card.parent_id` is deliberately RAW (the
  operator sees what the document stores), so every OTHER reader that used it as a
  KEY stayed broken:

    * `facets/1` — the goal chip menu, keyed on the raw parent.
    * `card_matches?/2` — the chip menu's OTHER half, which matches a card against
      a chosen chip. **Named by nothing in the filing or the brief.** Fixing
      `facets/1` alone would have made this strictly worse: a normalised chip
      matched against a raw parent selects NOTHING.
    * `family_fold/1` — BOTH the child index and the `Map.has_key?(ids, …)` root
      test. `cards_by_id` is keyed by the PUBLISHED doc_id, so a `drafts.<epic>`
      parent found no key and the child fell out as its own top-level card.
    * `group_cards/2`'s `:goal` clause — the goal swimlane, via `lane_key/1`.

  All five now go through the single private `parent_key/1`, which delegates to
  `Content.published_id/1` (`@canonical capability:draft-published-id`) rather than
  re-spelling the prefix strip.

  NOT LATENT. The population is the one #17952 measured on guerrilla `production`:
  25 rows (17 not cancelled) carrying a `drafts.`-shaped `parent_id` across five
  draft-only epics.

  ## What reds these tests

  Reverting any ONE of the five call sites to the raw `card.parent_id`. The
  CONTROL test pins the other direction: a plainly-parented child must keep
  working and the card must still RENDER the stored `drafts.` value, so the fix
  can never be "normalise at `to_card/5`" or "ignore `parent_id`".
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Board

  @dataset "production"

  setup do
    # `snapshot/1` reads the WHOLE `type:task` corpus, so a stray committed
    # fixture would poison the facet lists and the root set. Same hermetic guard
    # board_test.exs and board_subtasks_drafts_parent_test.exs use.
    Repo.delete_all(from(d in Document, where: d.type == "task"))
    :ok
  end

  defp task!(doc_id, title, content, status \\ "published") do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "task",
      dataset: @dataset,
      status: status,
      title: title,
      rev: "rev-#{doc_id}",
      content: Map.put_new(content, "lifecycle_status", "open")
    })
  end

  defp root_ids(view) do
    view.lanes
    |> Enum.flat_map(fn lane -> lane.columns |> Map.values() |> List.flatten() end)
    |> Enum.map(& &1.doc_id)
    |> MapSet.new()
  end

  describe "a child parented at drafts.<epic>" do
    setup do
      task!("epic-one", "Epic one", %{})
      task!("child-drafted", "Child drafted", %{"parent_id" => "drafts.epic-one"})
      %{board: Board.snapshot(dataset: @dataset)}
    end

    test "is NOT a root — it folds into the epic's family card", %{board: board} do
      view = Board.view(board)

      assert view.family?, "group_by :none with no filters must be the family view"

      ids = root_ids(view)

      refute MapSet.member?(ids, "child-drafted"),
             "the drafts.-parented child rendered as its OWN top-level card — " <>
               "family_fold/1 read the raw parent_id, which matches no cards_by_id key"

      assert MapSet.member?(ids, "epic-one")

      epic =
        view.lanes
        |> Enum.flat_map(fn lane -> lane.columns |> Map.values() |> List.flatten() end)
        |> Enum.find(&(&1.doc_id == "epic-one"))

      assert epic.family, "the epic carries no family mini-tree"
      assert epic.family.stats.total == 1
      assert Enum.map(epic.family.rows, & &1.doc_id) == ["child-drafted"]
    end

    test "lands in its EPIC's goal lane, not a lane of its own", %{board: board} do
      view = Board.view(board, group_by: :goal)

      keys = Enum.map(view.lanes, & &1.key)

      refute "drafts.epic-one" in keys,
             "a phantom drafts.epic-one swimlane — group_cards/2 :goal keyed the raw parent"

      lane = Enum.find(view.lanes, &(&1.key == "epic-one"))
      assert lane, "no epic-one goal lane: expected the child to land there"

      lane_ids =
        lane.columns |> Map.values() |> List.flatten() |> Enum.map(& &1.doc_id)

      assert "child-drafted" in lane_ids
    end

    test "is counted by the EPIC's goal facet chip, and that chip selects it", %{board: board} do
      facets = Board.facets(board)

      assert "epic-one" in facets.goals

      refute "drafts.epic-one" in facets.goals,
             "the chip menu offered TWO goals for one epic — facets/1 read the raw parent_id"

      # The other half of the pair, and the site nothing in the filing named:
      # the offered chip has to MATCH the card, or the menu sells a dead filter.
      assert Board.card_matches?(board.cards_by_id["child-drafted"], %{goal: ["epic-one"]}),
             "card_matches?/2 refused the very chip facets/1 offers for this card"

      view = Board.view(board, filters: %{goal: ["epic-one"]})
      assert "child-drafted" in MapSet.to_list(root_ids(view))
    end
  end

  test "the live shape: a DRAFT-ONLY epic is one goal chip, one lane, one root" do
    task!("drafts.epic-two", "Epic two", %{}, "draft")
    task!("drafts.child-b", "Child B", %{"parent_id" => "drafts.epic-two"}, "draft")

    board = Board.snapshot(dataset: @dataset)

    assert Board.facets(board).goals == ["epic-two"]

    view = Board.view(board)
    refute MapSet.member?(root_ids(view), "child-b")
    assert MapSet.member?(root_ids(view), "epic-two")
  end

  # ── the named control arm ───────────────────────────────────────────────────
  #
  # GREEN ON origin/main AND GREEN WITH THE CHANGE, by construction: every
  # assertion below is about behaviour `parent_key/1` must NOT move. It exists so
  # a rig that reds everything is distinguishable from one that discriminates —
  # if this test ever flips with the production change, the change reached
  # further than the key.
  test "CONTROL: the rendered parent_id stays the STORED value and plain parents are untouched" do
    task!("epic-three", "Epic three", %{})
    task!("child-plain", "Child plain", %{"parent_id" => "epic-three"})
    task!("child-drafted", "Child drafted", %{"parent_id" => "drafts.epic-three"})

    board = Board.snapshot(dataset: @dataset)

    # The operator still reads what the document stores. A fix at `to_card/5`
    # would pass every other assertion in this file and fail this one.
    assert board.cards_by_id["child-drafted"].parent_id == "drafts.epic-three"
    assert board.cards_by_id["child-plain"].parent_id == "epic-three"

    # The plainly-parented child is unaffected in every one of the five readers.
    assert "epic-three" in Board.facets(board).goals
    assert Board.card_matches?(board.cards_by_id["child-plain"], %{goal: ["epic-three"]})
    refute Board.card_matches?(board.cards_by_id["child-plain"], %{goal: ["epic-four"]})
    refute MapSet.member?(root_ids(Board.view(board)), "child-plain")

    plain_lane =
      Board.view(board, group_by: :goal).lanes |> Enum.find(&(&1.key == "epic-three"))

    assert plain_lane

    assert "child-plain" in (plain_lane.columns
                             |> Map.values()
                             |> List.flatten()
                             |> Enum.map(& &1.doc_id))
  end

  test "a mixed epic reads as ONE chip, ONE lane and ONE root" do
    task!("epic-three", "Epic three", %{})
    task!("child-plain", "Child plain", %{"parent_id" => "epic-three"})
    task!("child-drafted", "Child drafted", %{"parent_id" => "drafts.epic-three"})

    board = Board.snapshot(dataset: @dataset)

    assert Board.facets(board).goals == ["epic-three"]

    # Two lanes and no more: the epic's own goal lane, and the trailing
    # none-lane that holds the parentless epic itself. A third, `"drafts.epic-three"`,
    # is exactly the defect.
    view = Board.view(board, group_by: :goal)
    assert Enum.map(view.lanes, & &1.key) == ["epic-three", nil]

    lane_ids =
      view.lanes
      |> hd()
      |> Map.fetch!(:columns)
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.doc_id)

    assert Enum.sort(lane_ids) == ["child-drafted", "child-plain"]
    assert MapSet.to_list(root_ids(Board.view(board))) == ["epic-three"]
  end
end
