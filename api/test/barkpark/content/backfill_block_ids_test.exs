defmodule Barkpark.Content.Papers.BackfillBlockIdsTest do
  @moduledoc """
  Coverage for the id-less block backfill + ingest hardening (R2 corpus fix):

    * `BlockOps.ensure_block_ids/1` — fills an ABSENT id, a BLANK id, and a
      NESTED (section-child) id-less block, and NEVER overwrites a present id.
    * `BackfillBlockIds.run/1` — a legacy paper carrying id-less blocks gets
      every block an id; content is otherwise byte-identical; a second run is a
      no-op (idempotent); `--dry-run` writes nothing; the scan is
      tenancy-complete (a non-default-scoped paper is repaired too).
    * The ingest chokepoint — saving a document with id-less `content["blocks"]`
      through the PRODUCTION write path (`Content.create_document`, the path the
      Sanity-shaped mutations + legacy create controller use) stores blocks that
      all carry ids.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.Content.Papers.BackfillBlockIds

  # ── ensure_block_ids/1 — the chokepoint itself ────────────────────────────

  describe "BlockOps.ensure_block_ids/1" do
    test "fills an ABSENT id key" do
      [block] = BlockOps.ensure_block_ids([%{"type" => "paragraph", "text" => "hi"}])
      assert block["id"] == "block-0"
    end

    test "fills a BLANK id (empty string)" do
      [block] = BlockOps.ensure_block_ids([%{"type" => "paragraph", "id" => ""}])
      assert block["id"] == "block-0"
    end

    test "fills a nil id" do
      [block] = BlockOps.ensure_block_ids([%{"type" => "paragraph", "id" => nil}])
      assert block["id"] == "block-0"
    end

    test "NEVER overwrites a present non-blank id (idempotent on a fixed list)" do
      blocks = [%{"type" => "paragraph", "id" => "keepme"}]
      assert BlockOps.ensure_block_ids(blocks) == blocks
      # Second pass is byte-identical too.
      assert blocks |> BlockOps.ensure_block_ids() |> BlockOps.ensure_block_ids() == blocks
    end

    test "fills a NESTED (section-child) id-less block, keeping it unique" do
      blocks = [
        %{
          "type" => "section",
          "id" => "sec",
          "blocks" => [
            %{"type" => "paragraph", "text" => "child A"},
            %{"type" => "paragraph", "id" => "", "text" => "child B"}
          ]
        }
      ]

      [section] = BlockOps.ensure_block_ids(blocks)
      [a, b] = section["blocks"]

      assert a["id"] == "sec-0"
      assert b["id"] == "sec-1"
      assert a["id"] != b["id"]
    end

    test "a present nested child id survives while its id-less sibling is filled" do
      blocks = [
        %{
          "type" => "section",
          "id" => "sec",
          "blocks" => [
            %{"type" => "paragraph", "id" => "child-keep"},
            %{"type" => "paragraph"}
          ]
        }
      ]

      [section] = BlockOps.ensure_block_ids(blocks)
      [a, b] = section["blocks"]

      assert a["id"] == "child-keep"
      assert is_binary(b["id"]) and b["id"] != ""
      assert b["id"] != "child-keep"
    end

    # ── Collision-safe mint (the BLOCKER) ───────────────────────────────────

    test "MIXED list: an id-less block whose positional slot is ALREADY taken by a literal id gets a UNIQUE id" do
      # The id-bearing block literally owns "block-1" — the positional slot the
      # id-less block at index 1 would otherwise mint. Pre-fix → DUPLICATE.
      blocks = [
        %{"type" => "paragraph", "id" => "block-1", "text" => "literal owns slot 1"},
        %{"type" => "paragraph", "text" => "id-less at index 1"}
      ]

      out = BlockOps.ensure_block_ids(blocks)
      ids = Enum.map(out, &Map.get(&1, "id"))

      # The literal id is preserved exactly.
      assert Enum.at(ids, 0) == "block-1"
      # The id-less block got SOMETHING non-blank that is NOT a duplicate.
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(ids) == ids
    end

    test "TWO id-less blocks that would mint the same slot both end up UNIQUE" do
      # Block at index 0 is id-less → mints "block-0". The id-bearing block at
      # index 1 literally owns "block-0" too. Plus a third id-less block. All
      # three must end up unique.
      blocks = [
        %{"type" => "paragraph", "text" => "id-less idx 0"},
        %{"type" => "paragraph", "id" => "block-0", "text" => "literal block-0"},
        %{"type" => "paragraph", "text" => "id-less idx 2"}
      ]

      out = BlockOps.ensure_block_ids(blocks)
      ids = Enum.map(out, &Map.get(&1, "id"))

      assert "block-0" in ids
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(ids) == ids, "ids not unique: #{inspect(ids)}"
    end

    test "NESTED collision: a section child id-less block whose slot is taken by a literal sibling stays UNIQUE" do
      blocks = [
        %{
          "type" => "section",
          "id" => "block",
          "blocks" => [
            # The literal "block-1" owns the slot the id-less child at index 1
            # would mint (prefix is the parent id "block").
            %{"type" => "paragraph", "id" => "block-1", "text" => "literal child"},
            %{"type" => "paragraph", "text" => "id-less child idx 1"}
          ]
        }
      ]

      [section] = BlockOps.ensure_block_ids(blocks)
      child_ids = Enum.map(section["blocks"], &Map.get(&1, "id"))

      assert "block-1" in child_ids
      assert Enum.all?(child_ids, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(child_ids) == child_ids, "nested ids not unique: #{inspect(child_ids)}"
    end

    test "post-condition: ALL ids unique across a deep mixed tree" do
      blocks = [
        %{"type" => "paragraph", "id" => "block-1"},
        %{"type" => "paragraph"},
        %{
          "type" => "section",
          "blocks" => [
            %{"type" => "paragraph", "id" => "x-0"},
            %{"type" => "paragraph"},
            %{"type" => "paragraph", "id" => ""}
          ]
        },
        %{"type" => "paragraph", "id" => ""}
      ]

      out = BlockOps.ensure_block_ids(blocks)

      flat =
        Enum.flat_map(out, fn b ->
          [b["id"] | Enum.map(Map.get(b, "blocks", []), & &1["id"])]
        end)

      assert Enum.all?(flat, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(flat) == flat, "duplicate ids in tree: #{inspect(flat)}"
    end
  end

  # ── The backfill task over real paper rows ────────────────────────────────

  describe "BackfillBlockIds.run/1" do
    # Seed a paper through the canonical path (so scope columns are valid), then
    # STRIP the ids from its stored blocks via a direct Repo write — exactly the
    # legacy id-less corpus the backfill must repair.
    defp seed_legacy_idless_paper(slug, blocks, opts \\ []) do
      {:ok, _} = Content.upsert_paper(%{slug: slug, blocks: blocks, style: "article"})

      doc = Content.get_paper(slug)
      stored = doc.content["blocks"]
      stripped = Enum.map(stored, &Map.delete(&1, "id"))

      doc
      |> Document.changeset(%{"content" => Map.put(doc.content, "blocks", stripped)})
      |> Repo.update!()

      # Optionally re-stamp the row's tenancy to a non-default scope so the
      # tenancy-completeness assertion has a non-default-scoped paper to repair.
      case Keyword.get(opts, :scope) do
        nil ->
          :ok

        {ws_id, project_id} ->
          Content.get_paper(slug)
          |> Document.changeset(%{"workspace_id" => ws_id, "project_id" => project_id})
          |> Repo.update!()
      end

      slug
    end

    test "a legacy id-less paper gets every block an id; content otherwise byte-identical" do
      slug = "backfill-basic-#{System.unique_integer([:positive])}"

      blocks = [
        %{"type" => "heading", "level" => 1, "text" => "Title"},
        %{"type" => "paragraph", "text" => "First"},
        %{"type" => "paragraph", "text" => "Second"}
      ]

      seed_legacy_idless_paper(slug, blocks)

      before = Content.get_paper(slug).content
      assert Enum.all?(before["blocks"], &(Map.get(&1, "id") in [nil]))

      {:ok, stats} = BackfillBlockIds.run(dry_run: false)
      assert stats.changed_papers >= 1
      assert stats.blocks_filled >= 3

      after_content = Content.get_paper(slug).content
      new_blocks = after_content["blocks"]

      # Every block now carries a unique, non-blank id.
      ids = Enum.map(new_blocks, &Map.get(&1, "id"))
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(ids) == ids

      # ADDITIVE: the ONLY change is the added "id" key. Strip ids from both
      # sides → byte-identical. Nothing else in content changed (body_html, rev,
      # other keys).
      assert Enum.map(new_blocks, &Map.delete(&1, "id")) == before["blocks"]
      assert Map.delete(after_content, "blocks") == Map.delete(before, "blocks")
    end

    test "is idempotent — a second run writes nothing" do
      slug = "backfill-idem-#{System.unique_integer([:positive])}"

      seed_legacy_idless_paper(slug, [
        %{"type" => "paragraph", "text" => "A"},
        %{"type" => "paragraph", "text" => "B"}
      ])

      {:ok, first} = BackfillBlockIds.run(dry_run: false)
      assert first.changed_papers >= 1

      after_first = Content.get_paper(slug).content

      {:ok, second} = BackfillBlockIds.run(dry_run: false)
      # This paper is no longer in the changed set.
      refute Enum.any?(second.changes, &(&1.slug == slug))

      # And the stored content is untouched by the second run.
      assert Content.get_paper(slug).content == after_first
    end

    test "--dry-run reports the change but writes nothing" do
      slug = "backfill-dry-#{System.unique_integer([:positive])}"

      seed_legacy_idless_paper(slug, [%{"type" => "paragraph", "text" => "A"}])

      before = Content.get_paper(slug).content

      {:ok, stats} = BackfillBlockIds.run(dry_run: true)
      assert stats.dry_run == true
      assert Enum.any?(stats.changes, &(&1.slug == slug))

      # Nothing was written — the stored blocks are still id-less.
      after_content = Content.get_paper(slug).content
      assert after_content == before
      assert Enum.all?(after_content["blocks"], &(Map.get(&1, "id") in [nil]))
    end

    test "run/1 defaults to dry-run (safe) — a bare call writes nothing" do
      slug = "backfill-default-safe-#{System.unique_integer([:positive])}"
      seed_legacy_idless_paper(slug, [%{"type" => "paragraph", "text" => "A"}])

      before = Content.get_paper(slug).content
      {:ok, stats} = BackfillBlockIds.run()
      assert stats.dry_run == true
      assert Content.get_paper(slug).content == before
    end

    test "an HTML-only paper (no block list) is skipped, never errors" do
      slug = "backfill-htmlonly-#{System.unique_integer([:positive])}"
      {:ok, _} = Content.upsert_paper(%{slug: slug, body_html: "<article>hi</article>"})

      {:ok, stats} = BackfillBlockIds.run(dry_run: false)
      refute Enum.any?(stats.changes, &(&1.slug == slug))
    end

    test "tenancy-complete — repairs a paper in a NON-default workspace too" do
      ws = Barkpark.TenancyFixtures.create_workspace!("other")
      project = Barkpark.TenancyFixtures.create_project!(ws, "other-p")

      slug = "backfill-tenant-#{System.unique_integer([:positive])}"

      seed_legacy_idless_paper(
        slug,
        [%{"type" => "paragraph", "text" => "tenant block"}],
        scope: {ws.id, project.id}
      )

      # The seeded paper now lives in the non-default workspace.
      doc = Repo.get_by!(Document, doc_id: slug, type: "paper")
      assert doc.workspace_id == ws.id

      {:ok, _stats} = BackfillBlockIds.run(dry_run: false)

      repaired = Repo.get_by!(Document, doc_id: slug, type: "paper")
      ids = Enum.map(repaired.content["blocks"], &Map.get(&1, "id"))
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
    end
  end

  # ── The ingest chokepoint over the production document write path ──────────

  describe "ingest chokepoint (production document write path)" do
    # A freeform type with NO seeded layout schema → the write takes the
    # apply_initial_values path (no scaffold), so the caller's blocks pass
    # straight through the chokepoint to storage. This is the exact shape a
    # Sanity-style `create`/`createOrReplace` mutation produces.
    defp idless_block_attrs(doc_id) do
      %{
        "doc_id" => doc_id,
        "title" => "Choke",
        "content" => %{
          "blocks" => [
            %{"type" => "paragraph", "text" => "no id A"},
            %{"type" => "paragraph", "id" => "", "text" => "blank id B"},
            %{
              "type" => "section",
              "blocks" => [%{"type" => "paragraph", "text" => "nested no id"}]
            }
          ]
        }
      }
    end

    defp assert_all_blocks_have_ids(blocks) do
      top_ids = Enum.map(blocks, &Map.get(&1, "id"))
      assert Enum.all?(top_ids, &(is_binary(&1) and &1 != "")), "top-level ids: #{inspect(top_ids)}"

      # The nested section child got an id too.
      section = Enum.find(blocks, &(Map.get(&1, "type") == "section"))
      [child] = section["blocks"]
      assert is_binary(child["id"]) and child["id"] != ""
    end

    test "create_document stores id-less blocks WITH ids (Sanity create path)" do
      type = "freenote#{System.unique_integer([:positive])}"
      doc_id = "chokepoint-create-#{System.unique_integer([:positive])}"

      {:ok, _doc} =
        Content.create_document(type, idless_block_attrs(doc_id), "production", source: :api)

      {:ok, stored} = Content.get_document(Content.draft_id(doc_id), type, "production")
      assert_all_blocks_have_ids(stored.content["blocks"])
    end

    test "upsert_document stores id-less blocks WITH ids (Sanity patch / autosave path)" do
      type = "freenote#{System.unique_integer([:positive])}"
      doc_id = "chokepoint-upsert-#{System.unique_integer([:positive])}"

      {:ok, _doc} =
        Content.upsert_document(type, idless_block_attrs(doc_id), "production", source: :api)

      {:ok, stored} = Content.get_document(Content.draft_id(doc_id), type, "production")
      assert_all_blocks_have_ids(stored.content["blocks"])
    end
  end

  # ── The op-fold chokepoint (apply_paper_block_op / _ops) — MAJOR 1 ─────────

  describe "op-fold chokepoint (paper block ops)" do
    test "apply_paper_block_op: an inserted block with NO id is STORED with an id" do
      slug = "opfold-single-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          blocks: [%{"id" => "anchor", "type" => "paragraph", "text" => "anchor"}]
        })

      # append-block whose payload carries NO id (clients normally mint one).
      op = %{"op" => "append-block", "block" => %{"type" => "paragraph", "text" => "appended no-id"}}
      assert {:ok, frame} = Content.apply_paper_block_op(slug, op)

      stored = Content.get_paper(slug).content["blocks"]
      ids = Enum.map(stored, &Map.get(&1, "id"))
      assert Enum.all?(ids, &(is_binary(&1) and &1 != "")), "stored ids: #{inspect(ids)}"
      assert Enum.uniq(ids) == ids

      # The broadcast frame reports the freshly-minted id, not nil.
      assert is_binary(frame.block_id) and frame.block_id != ""
    end

    test "apply_paper_block_ops (batch): an inserted block with NO id is STORED with an id" do
      slug = "opfold-batch-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          blocks: [%{"id" => "anchor", "type" => "paragraph", "text" => "anchor"}]
        })

      ops = [
        %{
          "op" => "insert-after",
          "afterId" => "anchor",
          "block" => %{"type" => "paragraph", "text" => "inserted no-id"}
        }
      ]

      assert {:ok, _receipt} = Content.apply_paper_block_ops(slug, ops)

      stored = Content.get_paper(slug).content["blocks"]
      ids = Enum.map(stored, &Map.get(&1, "id"))
      assert Enum.all?(ids, &(is_binary(&1) and &1 != "")), "stored ids: #{inspect(ids)}"
      assert Enum.uniq(ids) == ids
    end
  end

  # ── The create/scaffold chokepoint — MAJOR 2 ──────────────────────────────

  describe "create/scaffold chokepoint (Expectation-bearing create)" do
    # An Expectation-bearing type: a schema carrying an explicit `layout` flips
    # the create onto the scaffold path. We provide an id-less body in
    # content["body"] so scaffold_body_blocks reuses those blocks VERBATIM — the
    # exact shape that lands id-less body blocks AFTER the early chokepoint.
    test "scaffold path: id-less body blocks supplied on create are STORED with ids" do
      type = "expnote#{System.unique_integer([:positive])}"
      dataset = "production"

      # Seed a schema with an explicit layout (one title field + a body region).
      # `upsert_schema` keys the schema by "name" (the type discriminator).
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Exp Note",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "body", "type" => "richText"}
            ],
            "layout" => [
              %{"kind" => "field", "name" => "title"},
              %{"kind" => "region", "name" => "body"}
            ]
          },
          dataset
        )

      doc_id = "scaffold-idless-#{System.unique_integer([:positive])}"

      # The create carries an id-less body region (reused verbatim by scaffold).
      attrs = %{
        "doc_id" => doc_id,
        "title" => "Scaffolded",
        "content" => %{
          "title" => "Scaffolded",
          "body" => %{
            "blocks" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "no id body"}]}
            ]
          }
        }
      }

      {:ok, _doc} = Content.create_document(type, attrs, dataset, source: :api)

      {:ok, stored} = Content.get_document(Content.draft_id(doc_id), type, dataset)
      blocks = stored.content["blocks"]

      ids = Enum.map(blocks, &Map.get(&1, "id"))
      assert Enum.all?(ids, &(is_binary(&1) and &1 != "")), "stored block ids: #{inspect(ids)}"
      assert Enum.uniq(ids) == ids

      # The projected body mirror carries the SAME ids as content["blocks"] —
      # ensure_block_ids ran BEFORE projection, so the two are in sync.
      body_blocks = get_in(stored.content, ["body", "blocks"]) || []
      body_ids = Enum.map(body_blocks, &Map.get(&1, "id"))
      assert Enum.all?(body_ids, &(is_binary(&1) and &1 != ""))
      # Every body id is also present in the top-level block ids (same objects).
      assert Enum.all?(body_ids, &(&1 in ids))
    end
  end

  # ── Backfill uniqueness post-condition — MINOR ────────────────────────────

  describe "BackfillBlockIds uniqueness post-condition" do
    test "a healthy corpus reports an EMPTY skipped_duplicates list" do
      slug = "backfill-postcond-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          blocks: [
            %{"type" => "paragraph", "text" => "a"},
            %{"type" => "paragraph", "text" => "b"}
          ]
        })

      # Strip ids → legacy id-less, then backfill.
      doc = Content.get_paper(slug)
      stripped = Enum.map(doc.content["blocks"], &Map.delete(&1, "id"))

      doc
      |> Document.changeset(%{"content" => Map.put(doc.content, "blocks", stripped)})
      |> Repo.update!()

      {:ok, stats} = BackfillBlockIds.run(dry_run: false)

      # The post-condition stat exists and is clean (collision-safe mint => no dupes).
      assert Map.has_key?(stats, :skipped_duplicates)
      assert stats.skipped_duplicates == []

      # And the repaired paper has unique ids.
      ids = Enum.map(Content.get_paper(slug).content["blocks"], &Map.get(&1, "id"))
      assert Enum.uniq(ids) == ids
    end
  end
end
