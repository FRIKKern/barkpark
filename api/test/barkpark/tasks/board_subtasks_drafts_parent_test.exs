defmodule Barkpark.Tasks.BoardSubtasksDraftsParentTest do
  @moduledoc """
  The board's `:sub` summary counts a child parented at `drafts.<epic>`
  (task-56bc2039bae5010f).

  `Board.attach_subtasks/1` buckets children by `parent_id` and looks the bucket
  up by `card.doc_id`. `to_card/4` already normalises the LOOKUP side —
  `doc_id: Content.published_id(doc.doc_id)` — but `parent_id` is the RAW stored
  value, and every write through `/v1/data/mutate` lands in the draft shadow, so
  a child filed against a drafts-shaped epic stores
  `parent_id: "drafts.<epic>"`. Grouped raw, that child keys a bucket no card's
  doc_id can ever match: the epic's `sub` reads `nil` (or under-counts) while the
  child sits right there on the same board.

  Every sibling rail reader already strips the prefix on both sides
  (`Tasks.Query.maybe_filter_parent_id/2`, `Tasks.Rail.rail_children/2`,
  `TasksController.Params.batch_child_counts/2`); this is the same rule applied
  to the in-memory snapshot.

  NOT LATENT, contrary to the filing. Measured 2026-09-12 over the whole
  guerrilla `production` ledger (`bp task ls --all`, 9,160 task rows): 25 rows
  (17 of them not cancelled) carry a `drafts.`-prefixed `parent_id`, across five
  distinct epics — `drafts.codebase-quality-goal` (9), `drafts.unified-aesthetic-goal`
  (7), `drafts.rail-awareness-goal` (6), `drafts.security-hardening-goal` (2),
  `drafts.probe-rail-move` (1). All five epics exist as draft-only documents, so
  each renders as a board card under its PUBLISHED id and every one of those
  children is invisible to its `sub` count today.

  ## What reds these tests

  Reverting `attach_subtasks/1` to group on the raw `parent_id` makes
  `sub` nil on the first two tests. The third is the no-regression control: a
  plainly-parented child must keep counting, so the fix cannot be "ignore
  parent_id".
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Board

  @dataset "production"

  setup do
    # Same hermetic guard board_test uses: `snapshot/1` reads the WHOLE
    # `type:task` corpus, so a stray committed fixture would poison the counts.
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

  test "a child parented at drafts.<epic> is counted in the PUBLISHED epic's sub.total" do
    task!("epic-one", "Epic one", %{})
    task!("child-a", "Child A", %{"parent_id" => "drafts.epic-one"})

    board = Board.snapshot(dataset: @dataset)
    epic = board.cards_by_id["epic-one"]

    assert epic, "the epic must be on the board at its published id"

    assert epic.sub,
           "the epic's sub summary is nil — the drafts.-parented child was bucketed " <>
             "under a key no card's doc_id can match"

    assert epic.sub.total == 1
    assert epic.sub.done == 0
  end

  test "the live shape: a DRAFT-ONLY epic with a drafts.-parented child counts it" do
    # This is what the five live epics look like: the epic exists only as a
    # `drafts.` document, so `to_card/4` renders it under the published id while
    # the child still stores the drafts-shaped parent.
    task!("drafts.epic-two", "Epic two", %{}, "draft")
    task!("drafts.child-b", "Child B", %{"parent_id" => "drafts.epic-two"}, "draft")

    task!("drafts.child-c", "Child C", %{
      "parent_id" => "drafts.epic-two",
      "lifecycle_status" => "done"
    })

    board = Board.snapshot(dataset: @dataset)
    epic = board.cards_by_id["epic-two"]

    assert epic, "the draft-only epic must render under its published id"
    assert epic.sub, "the draft-only epic's sub summary is nil"
    assert epic.sub.total == 2
    assert epic.sub.done == 1
  end

  test "CONTROL: a plainly-parented child still counts, and a mixed pair counts BOTH" do
    task!("epic-three", "Epic three", %{})
    task!("child-plain", "Child plain", %{"parent_id" => "epic-three"})
    task!("child-drafted", "Child drafted", %{"parent_id" => "drafts.epic-three"})

    board = Board.snapshot(dataset: @dataset)
    epic = board.cards_by_id["epic-three"]

    assert epic.sub.total == 2

    # And the card still reports the parent_id the document actually STORES —
    # the normalisation belongs to the grouping key, not to the rendered field.
    assert board.cards_by_id["child-drafted"].parent_id == "drafts.epic-three"
    assert board.cards_by_id["child-plain"].parent_id == "epic-three"
  end
end
