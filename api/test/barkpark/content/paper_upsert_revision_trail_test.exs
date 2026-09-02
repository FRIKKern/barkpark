defmodule Barkpark.Content.PaperUpsertRevisionTrailTest do
  @moduledoc """
  [paper-upsert-unlogged-clobber] The published-Paper write path replaced content
  without appending a revision-history row.

  ## The hole

  Two publish paths reach a published paper, and only one of them logged.

    * `Content.upsert_document/4` (writer.ex) pipes its result through
      `Broadcast.tap_broadcast/7`, which calls `save_revision/5`
      UNCONDITIONALLY. Every write leaves a snapshot.
    * `Content.upsert_paper/2` → `BlockOps.persist_blocks_doc/9` writes
      `status: "published"` + a whole new `content` + a fresh opaque `rev` over
      an EXISTING row with a bare `Repo.update`, then called
      `broadcast_paper_update/1` — a PubSub fan-out that saves NO revision.

  So a paper republished through `upsert_paper` moved to new content under a new
  `_rev` while `bp doc history` stood still. The prior published state was not
  merely hard to find — it was never captured, so it is gone. That makes every
  seal citing a paper revision unverifiable after the fact, and makes a
  legitimate bulk migration indistinguishable from an accidental clobber.

  Corpus evidence — lead-corpus, 2026-09-02, from one `bp doc query paper --all`
  dump of all 1050 published papers (ledger row `task-45307192c1b0e1ef`; its
  ORIGINAL description undercounts by an order of magnitude because it sampled a
  single 30-paper wave cohort, and was corrected in a later stage note, so these
  are the figures that stand):

    * 485 of 1050 published papers rewritten inside a 46-second window on
      2026-08-17 (15:40:09.987Z → 15:40:55.791Z) — about 46% of the corpus.
    * Further bulk sweeps on 08-23 (131 + 54), 08-25 (153) and 09-02 (51).
    * Sampling every 53rd paper by id, 20 papers split with NO middle band: 5
      logged (`_updatedAt` within ~1s of the newest revision row), 14 unlogged
      (weeks apart), 1 with no history at all. `_updatedAt` vs
      `max(revision.timestamp)` is the clean instrument, which is why 20 was
      enough to characterise it.
    * `pds-wave-4-2026-07-19` is the sharpest case: 25 revision entries, newest a
      publish at 2026-07-31T08:15:36Z, `_updatedAt` 2026-09-02. Thirty-three days
      of writes left no entry.
    * `intuition-atlas-verdict` is live and published with a history of count 0.

  Not one runaway script: `barkpark-changelog-2026-07-17` has history through
  2026-08-24T17:12Z and then an unlogged write on 08-25 — a different day, a
  different batch. Several callers reach this one low-level write, so the fix
  belongs at the write, not at any caller.

  Stated precisely: what was measured is that this path DID NOT RECORD WHAT IT
  CHANGED. Whether it was obliged to was never independently established — this
  commit decides that question by making it log.

  ## Why LOG and not FORBID

  `upsert_paper` is the legitimate Bulldocs ingest / `bp paper` publish entry
  point. Forbidding a republish would break authoring outright. A migration must
  stay possible — it must just leave a trace. So the update leg now records a
  revision exactly as the writer path does, and the insert leg records the
  paper's birth (closing the count-0 case).

  ## `_rev` had no read

  The `revisions` table carried no `rev` column at all, so a `_rev` hash was
  structurally unresolvable — `get_revision/3` keys on the revision's own UUID.
  A revision cited by an acceptance criterion was neither live nor retrievable.
  `save_revision/5` now stamps `rev`, and `Revisions.get_revision_by_rev/3`
  resolves it. Covered by `paper_revision_rev_lookup_test.exs`.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Revision
  alias Barkpark.Repo

  defp dataset, do: Content.paper_default_dataset()

  defp upsert(slug, text) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [%{"type" => "paragraph", "text" => text, "id" => "b1"}],
          style: "article"
        })
      )

    doc
  end

  # Read the trail straight off the table, keyed on the paper's slug. Deliberately
  # NOT via `list_revisions/4`: that read applies dataset/workspace/grant scoping,
  # and a scoping mismatch would make an ABSENT row look identical to a filtered
  # one. The defect is absence, so the assertion must be able to see everything.
  defp trail(slug) do
    Revision
    |> where([r], r.doc_id == ^slug and r.type == "paper")
    |> order_by([r], asc: r.inserted_at)
    |> Repo.all()
  end

  describe "upsert_paper/2 leaves an audit trail" do
    test "republishing an existing published paper appends a revision" do
      slug = "rev-trail-replace-#{System.unique_integer([:positive])}"

      first = upsert(slug, "the sealed text")
      assert first.status == "published"
      before = length(trail(slug))

      second = upsert(slug, "the replacement text")

      # The clobber really happened: same row, new content, new opaque rev.
      assert second.id == first.id
      assert second.rev != first.rev
      assert second.content != first.content

      after_ = trail(slug)

      assert length(after_) == before + 1,
             "republishing a PUBLISHED paper wrote no revision row — the prior " <>
               "published state is unrecoverable and the seal citing it is " <>
               "unverifiable (had #{before}, now #{length(after_)})"

      assert List.last(after_).action == "update"
    end

    test "the recorded snapshot carries the content that was published" do
      slug = "rev-trail-snapshot-#{System.unique_integer([:positive])}"

      upsert(slug, "generation one")
      upsert(slug, "generation two")

      # The whole point of the trail: generation one must still be readable
      # AFTER generation two replaced it.
      texts =
        trail(slug)
        |> Enum.map(fn r -> r.content |> Map.get("blocks") |> hd() |> Map.get("text") end)

      assert "generation one" in texts,
             "the replaced published content was not captured anywhere — got #{inspect(texts)}"
    end

    test "creating a paper records its birth (the count-0 case)" do
      slug = "rev-trail-birth-#{System.unique_integer([:positive])}"

      upsert(slug, "hello")

      # Bound first: a pattern match on the right of `assert/2` raises MatchError
      # before assert/2 runs, which would make this message dead code.
      rows = trail(slug)

      assert length(rows) == 1,
             "a paper born through upsert_paper had a revision history of count " <>
               "#{length(rows)} — count 0 is exactly the live `intuition-atlas-verdict` shape"

      [rev] = rows

      assert rev.action == "create"
      assert rev.status == "published"
    end

    test "the trail is scoped and readable through the surfaced history read" do
      slug = "rev-trail-scoped-#{System.unique_integer([:positive])}"

      doc = upsert(slug, "one")
      upsert(slug, "two")

      opts = [workspace_id: doc.workspace_id, project_id: doc.project_id]
      revisions = Content.list_revisions(slug, "paper", dataset(), opts)

      assert length(revisions) == 2,
             "the rows exist but the surfaced `bp doc history` read cannot see them"
    end
  end
end
