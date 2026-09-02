defmodule Barkpark.Content.PaperRevisionHistoryTest do
  @moduledoc """
  A published paper can no longer be REPLACED without a revision-history entry,
  and a cited `_rev` hash can be resolved back to the content it names.
  (task-8d4b1f2c7a0e3591)

  ## What was broken

  Every generic content type gets a `revisions` row for free: its write result
  is tapped by `Broadcast.tap_broadcast/7`. FOUR paper write paths bypassed that
  tap and wrote a bare `Repo.update/1`:

    * `Papers.BlockOps.persist_blocks_doc/8` — the whole-document paper upsert
      (`bp paper set`, Bulldocs ingest, the Studio whole-doc save). It hard-codes
      `status: "published"`, so it replaces the ENTIRE content of an
      already-published paper — every block, the cached `body_html`, the title —
      and left `GET /v1/data/history/:dataset/paper/:slug` EMPTY.
    * `Papers.BackfillBlockIds.persist/2`
    * `Papers.DoctrineBackfill.persist/2`
    * `Papers.CompositionMigration.persist/2` — the three corpus-wide offline
      migrations, each driven by a Mix task that sweeps every `type:"paper"` row
      in every workspace/project/dataset in ONE pass. A single `--apply` could
      rewrite dozens of published papers in seconds and leave no trace.

  After the fact a legitimate migration and an accidental clobber were literally
  indistinguishable — the corpus held no row saying either had happened.

  ## RED-without / GREEN-with

  Every `history` assertion below is a direct mutation probe: revert the module
  under test to its bare `Repo.update(changeset)` and the assertion goes from
  one (or more) `revisions` row to ZERO. `history_actions/1` counts ONLY the
  rows the test's own paper produced, so the shared test database's other rows
  can never satisfy it.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.{BackfillBlockIds, CompositionMigration, DoctrineBackfill}

  # Every revision row this slug's paper owns, oldest first, as action strings.
  # Scoped to the doc_id the test created — never a whole-table read.
  defp history_actions(slug) do
    Content.list_revisions(slug, "paper", "production", limit: 50)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.map(& &1.action)
  end

  defp seed_paper(slug, blocks) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, style: "article", blocks: blocks})
      )

    Content.get_paper(slug)
  end

  # ── The whole-document paper upsert ───────────────────────────────────────

  describe "BlockOps.persist_blocks_doc/8 — the whole-paper replace" do
    test "a FIRST save records a `create` revision" do
      slug = "revhist-create-#{System.unique_integer([:positive])}"
      seed_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "one"}])

      assert history_actions(slug) == ["create"]
    end

    test "REPLACING an already-published paper records an `update` revision carrying the OLD content" do
      slug = "revhist-replace-#{System.unique_integer([:positive])}"
      seed_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "ORIGINAL"}])

      # The clobber: a whole-document replace of a published paper.
      seed_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "REPLACED"}])

      # RED WITHOUT THE FIX: this list was `[]` — both writes were bare
      # Repo.update/insert and produced no revision at all.
      assert history_actions(slug) == ["create", "update"]

      # And the history is USEFUL, not just present: the first entry still holds
      # the content the replace destroyed.
      [create_rev, update_rev] =
        Content.list_revisions(slug, "paper", "production", limit: 50)
        |> Enum.sort_by(& &1.inserted_at, DateTime)

      assert inspect(create_rev.content) =~ "ORIGINAL"
      assert inspect(update_rev.content) =~ "REPLACED"
    end

    test "the revision is bound to the document, so `current_revision_id` advances" do
      slug = "revhist-bound-#{System.unique_integer([:positive])}"
      seed_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "a"}])
      first = Content.get_paper(slug)
      assert first.current_revision_id

      seed_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "b"}])
      second = Content.get_paper(slug)

      assert second.current_revision_id != first.current_revision_id
    end
  end

  # ── The three offline corpus migrations ───────────────────────────────────

  describe "offline migrations write history" do
    test "BackfillBlockIds --apply records a `migrate:backfill_block_ids` revision" do
      slug = "revhist-bbi-#{System.unique_integer([:positive])}"

      doc =
        seed_paper(slug, [
          %{"id" => "p1", "type" => "paragraph", "text" => "a"},
          %{"id" => "p2", "type" => "paragraph", "text" => "b"}
        ])

      # Strip the ids back out — the legacy corpus the backfill repairs.
      stripped = Enum.map(doc.content["blocks"], &Map.delete(&1, "id"))

      doc
      |> Document.changeset(%{"content" => Map.put(doc.content, "blocks", stripped)})
      |> Repo.update!()

      before = history_actions(slug)

      {:ok, stats} = BackfillBlockIds.run(dry_run: false)
      assert stats.changed_papers >= 1

      # RED WITHOUT THE FIX: the list was UNCHANGED by the sweep — the paper's
      # blocks were rewritten and nothing recorded it.
      assert history_actions(slug) == before ++ ["migrate:backfill_block_ids"]
    end

    test "DoctrineBackfill --apply records a `migrate:doctrine_backfill` revision" do
      slug = "revhist-doctrine-#{System.unique_integer([:positive])}"

      seed_paper(slug, [
        %{"id" => "p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "b"}]}
      ])

      before = history_actions(slug)

      {:ok, stats} = DoctrineBackfill.run(dry_run: false)
      assert stats.changed_papers >= 1

      assert history_actions(slug) == before ++ ["migrate:doctrine_backfill"]
    end

    test "CompositionMigration --apply records a `migrate:composition_migration` revision" do
      slug = "revhist-compmig-#{System.unique_integer([:positive])}"

      seed_paper(slug, [
        %{
          "id" => "cm-1",
          "type" => "cards",
          "items" => [%{"title" => "Alpha", "text" => "First card", "tone" => "info"}]
        }
      ])

      before = history_actions(slug)

      {:ok, stats} = CompositionMigration.run(dry_run: false)
      assert stats.changed_papers >= 1

      assert history_actions(slug) == before ++ ["migrate:composition_migration"]
    end

    test "a DRY run still writes nothing — no content change, no history entry" do
      slug = "revhist-dry-#{System.unique_integer([:positive])}"

      seed_paper(slug, [
        %{"id" => "p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "b"}]}
      ])

      before_content = Content.get_paper(slug).content
      before_history = history_actions(slug)

      {:ok, _} = DoctrineBackfill.run(dry_run: true)

      assert Content.get_paper(slug).content == before_content
      assert history_actions(slug) == before_history
    end
  end

  # ── Resolving a cited `_rev` hash ─────────────────────────────────────────

  describe "Content.get_revision_by_rev/3" do
    test "resolves an OLDER rev hash to the content that rev named" do
      slug = "revhist-byrev-#{System.unique_integer([:positive])}"

      # Two revisions of the same document through the generic write path (the
      # one that persists mutation_events).
      {:ok, first} =
        Content.upsert_document(
          "post",
          %{"doc_id" => slug, "title" => "V1", "body" => "FIRST"},
          "production"
        )

      {:ok, second} =
        Content.upsert_document(
          "post",
          %{"doc_id" => slug, "title" => "V2", "body" => "SECOND"},
          "production"
        )

      assert first.rev != second.rev

      # The live row is V2 …
      assert second.content["body"] == "SECOND"

      # … and the OLDER hash still resolves to the content it named.
      # RED WITHOUT THE FIX: `get_revision_by_rev/3` did not exist, and the only
      # revision read keyed on the `revisions` row UUID — a `_rev` was
      # unresolvable through any surface in the API.
      assert {:ok, snapshot} = Content.get_revision_by_rev(first.rev, "production")
      assert snapshot.rev == first.rev
      # The event carries the row's OWN doc_id — an `upsert_document` write
      # targets the `drafts.`-prefixed row, so normalize before comparing.
      assert Content.published_id(snapshot.doc_id) == slug
      assert snapshot.type == "post"
      assert snapshot.document["body"] == "FIRST"
      assert snapshot.document["_rev"] == first.rev

      # The newer hash resolves to the newer content — the read is per-rev, not
      # "whatever the document is now".
      assert {:ok, newer} = Content.get_revision_by_rev(second.rev, "production")
      assert newer.document["body"] == "SECOND"
    end

    test "an unknown hash, a non-hash, and a wrong dataset are all not_found" do
      assert {:error, :not_found} =
               Content.get_revision_by_rev(String.duplicate("a", 32), "production")

      # Not a 32-char lowercase hex token — never reaches the query.
      assert {:error, :not_found} = Content.get_revision_by_rev("not-a-rev", "production")
      assert {:error, :not_found} = Content.get_revision_by_rev("", "production")
      assert {:error, :not_found} = Content.get_revision_by_rev(nil, "production")

      slug = "revhist-ds-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.upsert_document("post", %{"doc_id" => slug, "title" => "T"}, "production")

      assert {:error, :not_found} = Content.get_revision_by_rev(doc.rev, "staging")
      assert {:ok, _} = Content.get_revision_by_rev(doc.rev, "production")
    end
  end
end
