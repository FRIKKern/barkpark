defmodule Barkpark.Content.Papers.DoctrineBackfillTest do
  @moduledoc """
  Coverage for the doctrine-template corpus backfill (pdd-t5):

    * `plan/1` (pure classifier) — title synthesis via BOTH heuristics (doc.title,
      first-heading), sourced-heading consumption (no duplicate title text, even
      when the heading is not block 0), featured skip-when-no-image /
      promote-when-image / never-promote-a-bound-image, conformer detection,
      `Template.validate/1` passes after a plan, the duplicate-id refusal,
      idempotence, and the unfixable classes (HTML-only, no derivable title,
      misplaced title).
    * `run/1` (DB scan + apply) — dry-run default writes nothing; `--apply`
      backfills a legacy paper (refreshing body_html, the projection, and both
      revs like the real writer) and re-runs to a no-op (idempotent); a
      CONFORMING paper is left BYTE-IDENTICAL (the D3 contract, asserted by
      serializing content before/after); the scan is tenancy-complete.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.{DoctrineBackfill, Template}

  # A hand-built paper Document (no DB) for the pure `plan/1` surface.
  defp paper(title, blocks) do
    %Document{
      doc_id: "p",
      type: "paper",
      dataset: "production",
      title: title,
      content: %{"blocks" => blocks}
    }
  end

  # ── plan/1 — title synthesis heuristics ───────────────────────────────────

  describe "plan/1 title synthesis" do
    test "synthesizes the title from doc.title (heuristic 1) as a locked seed-shape heading at block 0" do
      doc = paper("My Row Title", [%{"id" => "p1", "type" => "paragraph", "text" => "body"}])

      assert {:change, [title | _rest], meta} = DoctrineBackfill.plan(doc)
      assert meta.title_source == :doc_title
      assert meta.title_text == "My Row Title"

      # Stamped EXACTLY per the template seed shape.
      assert title == %{
               "id" => "tpl-title",
               "type" => "heading",
               "level" => 1,
               "role" => "title",
               "locked" => true,
               "text" => "My Row Title"
             }
    end

    test "synthesizes the title from the first heading (heuristic 2) when doc.title is blank" do
      # Block 0 is a heading → it is REPLACED by the title block (dedup, no double H1).
      doc =
        paper(nil, [
          %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Heading Title"},
          %{"id" => "p1", "type" => "paragraph", "text" => "body"}
        ])

      assert {:change, [title, second], meta} = DoctrineBackfill.plan(doc)
      assert meta.title_source == :first_heading
      assert meta.title_text == "Heading Title"
      assert title["role"] == "title" and title["locked"] == true
      assert title["text"] == "Heading Title"
      # The legacy heading was consumed (replaced), not duplicated.
      assert second["id"] == "p1"
    end

    test "doc.title wins over a differing first heading (precedence)" do
      doc =
        paper("Row Wins", [
          %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Heading Loses"}
        ])

      assert {:change, [title | _], meta} = DoctrineBackfill.plan(doc)
      assert meta.title_source == :doc_title
      assert title["text"] == "Row Wins"
    end

    test "preserves a block-0 heading that is NOT the title (differing text → prepend, no data loss)" do
      # doc.title differs from the first heading → the heading is real content
      # (e.g. an intro/section heading), so it must survive, not be replaced.
      doc =
        paper("Row Wins", [
          %{"id" => "h1", "type" => "heading", "level" => 2, "text" => "Introduction"},
          %{"id" => "p1", "type" => "paragraph", "text" => "body"}
        ])

      assert {:change, [title, kept | _], _meta} = DoctrineBackfill.plan(doc)
      assert title["id"] == "tpl-title" and title["text"] == "Row Wins"
      # The differing heading is preserved verbatim.
      assert kept["id"] == "h1" and kept["text"] == "Introduction"
    end

    test "prepends the title when block 0 is NOT a heading" do
      doc =
        paper("T", [
          %{"id" => "p1", "type" => "paragraph", "text" => "first"},
          %{"id" => "p2", "type" => "paragraph", "text" => "second"}
        ])

      assert {:change, blocks, _meta} = DoctrineBackfill.plan(doc)
      # Title prepended → the original paragraphs are preserved after it.
      assert Enum.map(blocks, & &1["id"]) == ["tpl-title", "p1", "p2"]
    end

    test "consumes the sourced first heading even when it is NOT block 0 (no duplicate title text)" do
      # A legacy paper often opens with an image before its heading; the heading
      # the title was synthesized FROM must not survive as a second render of
      # the same text.
      doc =
        paper(nil, [
          %{"id" => "img", "type" => "image", "src" => "https://c/x.png"},
          %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Deep Title"},
          %{"id" => "p1", "type" => "paragraph", "text" => "body"}
        ])

      assert {:change, blocks, meta} = DoctrineBackfill.plan(doc)
      assert meta.title_source == :first_heading
      assert meta.title_text == "Deep Title"
      # title@0, promoted featured image@1, paragraph — the sourced heading is gone.
      assert Enum.map(blocks, & &1["id"]) == ["tpl-title", "img", "p1"]
      assert Enum.count(blocks, &(&1["type"] == "heading")) == 1
    end

    test "replaces a block-0 heading equal to doc.title modulo surrounding whitespace" do
      doc =
        paper("My Title", [
          %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "  My Title  "},
          %{"id" => "p1", "type" => "paragraph", "text" => "body"}
        ])

      assert {:change, [title, p1], _meta} = DoctrineBackfill.plan(doc)
      assert title["id"] == "tpl-title" and title["text"] == "My Title"
      assert p1["id"] == "p1"
    end
  end

  # ── plan/1 — featured image ───────────────────────────────────────────────

  describe "plan/1 featured image" do
    test "SKIPS the featured block when the paper has no image asset" do
      doc = paper("T", [%{"id" => "p1", "type" => "paragraph", "text" => "no image here"}])

      assert {:change, blocks, meta} = DoctrineBackfill.plan(doc)
      assert meta.featured == :skipped
      refute Enum.any?(blocks, &(&1["role"] == "featured"))
      # No asset was invented — no image block at all.
      refute Enum.any?(blocks, &(&1["type"] == "image"))
    end

    test "an image block with a BLANK src is not treated as an asset (skipped)" do
      doc =
        paper("T", [
          %{"id" => "p1", "type" => "paragraph", "text" => "x"},
          %{"id" => "img", "type" => "image", "src" => "   "}
        ])

      assert {:change, _blocks, meta} = DoctrineBackfill.plan(doc)
      assert meta.featured == :skipped
    end

    test "promotes an existing image asset to the locked featured block at index 1 (moved, not duplicated)" do
      doc =
        paper("T", [
          %{"id" => "p1", "type" => "paragraph", "text" => "intro"},
          %{"id" => "img", "type" => "image", "src" => "https://cdn/x.png", "alt" => "X"},
          %{"id" => "p2", "type" => "paragraph", "text" => "outro"}
        ])

      assert {:change, [title, featured, p1, p2], meta} = DoctrineBackfill.plan(doc)
      assert meta.featured == :inserted
      assert title["role"] == "title"

      # The featured block IS the promoted image (src/alt preserved) + role/locked.
      assert featured["type"] == "image"
      assert featured["role"] == "featured"
      assert featured["locked"] == true
      assert featured["src"] == "https://cdn/x.png"
      assert featured["alt"] == "X"

      # Moved, not duplicated — the image no longer sits in the body.
      assert p1["id"] == "p1" and p2["id"] == "p2"
      assert Enum.count([title, featured, p1, p2], &(&1["type"] == "image")) == 1
    end

    test "a field-BOUND image is never promoted to featured (it belongs to its field)" do
      doc =
        paper("T", [
          %{"id" => "p1", "type" => "paragraph", "text" => "x"},
          %{"id" => "img", "type" => "image", "src" => "https://c/x.png", "fieldName" => "cover"}
        ])

      assert {:change, blocks, meta} = DoctrineBackfill.plan(doc)
      assert meta.featured == :skipped
      refute Enum.any?(blocks, &(&1["role"] == "featured"))
      # The bound image is untouched, in place.
      assert Enum.map(blocks, & &1["id"]) == ["tpl-title", "p1", "img"]
    end
  end

  # ── plan/1 — validate passes / conforms / idempotence ─────────────────────

  describe "plan/1 template invariants" do
    test "every backfill plan passes Template.validate/1" do
      docs = [
        paper("T", [%{"id" => "p1", "type" => "paragraph", "text" => "x"}]),
        paper("T", [
          %{"id" => "p1", "type" => "paragraph"},
          %{"id" => "img", "type" => "image", "src" => "https://c/x.png"}
        ]),
        paper(nil, [%{"id" => "h", "type" => "heading", "text" => "H"}])
      ]

      for doc <- docs do
        assert {:change, blocks, _} = DoctrineBackfill.plan(doc)
        assert Template.validate(blocks) == [], "plan output must pass the template gate"
      end
    end

    test "a paper that already conforms returns :conforms (byte-stable, untouched)" do
      # The exact shape --apply produces: locked title@0 + a body paragraph.
      [title_block, _featured] = Template.template_blocks("Conforming")

      doc =
        paper("Conforming", [
          title_block,
          %{"id" => "p1", "type" => "paragraph", "text" => "body"}
        ])

      assert DoctrineBackfill.plan(doc) == :conforms
    end

    test "a conforming paper WITH a featured image at index 1 returns :conforms" do
      [title_block, _] = Template.template_blocks("With Featured")

      featured = %{
        "id" => "f",
        "type" => "image",
        "role" => "featured",
        "locked" => true,
        "src" => "https://c/x.png"
      }

      doc = paper("With Featured", [title_block, featured, %{"id" => "p", "type" => "paragraph"}])
      assert DoctrineBackfill.plan(doc) == :conforms
    end

    test "idempotence — re-planning a backfilled paper is a no-op (:conforms)" do
      doc =
        paper("T", [
          %{"id" => "p1", "type" => "paragraph", "text" => "intro"},
          %{"id" => "img", "type" => "image", "src" => "https://c/x.png"}
        ])

      assert {:change, backfilled, _} = DoctrineBackfill.plan(doc)

      # Feed the output back in as a fresh paper → it now conforms (no second diff).
      re = paper("T", backfilled)
      assert DoctrineBackfill.plan(re) == :conforms
    end
  end

  # ── plan/1 — unfixable classes ────────────────────────────────────────────

  describe "plan/1 unfixable" do
    test "an HTML-only paper (no block list) is unfixable, never crashes" do
      doc = %Document{
        doc_id: "h",
        type: "paper",
        dataset: "production",
        title: "T",
        content: %{"body_html" => "<p>hi</p>"}
      }

      assert {:unfixable, reason} = DoctrineBackfill.plan(doc)
      assert reason =~ "html-only"
    end

    test "a paper with no doc.title AND no heading is unfixable (no title to synthesize)" do
      doc = paper(nil, [%{"id" => "p1", "type" => "paragraph", "text" => "body only"}])
      assert {:unfixable, reason} = DoctrineBackfill.plan(doc)
      assert reason =~ "derive a title"
    end

    test "a block already squatting on the template id is unfixable (duplicate ids never written)" do
      doc = paper("T", [%{"id" => "tpl-title", "type" => "paragraph", "text" => "x"}])

      assert {:unfixable, reason} = DoctrineBackfill.plan(doc)
      assert reason =~ "unique"
    end

    test "a paper that already has a role:title block but not at block 0 is unfixable (manual review)" do
      doc =
        paper("T", [
          %{"id" => "p1", "type" => "paragraph", "text" => "intro"},
          %{"id" => "t", "type" => "heading", "role" => "title", "locked" => true, "text" => "T"}
        ])

      assert {:unfixable, reason} = DoctrineBackfill.plan(doc)
      assert reason =~ "manual review"
    end
  end

  # ── run/1 — DB scan + apply ───────────────────────────────────────────────

  # Seed a paper through the canonical write path, then strip it back to a LEGACY
  # (pre-doctrine) shape via a direct Repo write — the corpus the backfill repairs.
  defp seed_legacy_paper(slug, blocks) do
    {:ok, _} = Content.upsert_paper(%{slug: slug, style: "article", blocks: blocks})
    slug
  end

  describe "run/1 dry-run (default, safe)" do
    test "defaults to dry-run — a bare call writes nothing" do
      slug = "doctrine-default-#{System.unique_integer([:positive])}"
      seed_legacy_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "x"}])

      before = Content.get_paper(slug).content
      {:ok, stats} = DoctrineBackfill.run()
      assert stats.dry_run == true
      assert Content.get_paper(slug).content == before
    end

    test "--dry-run reports the change but writes nothing" do
      slug = "doctrine-dry-#{System.unique_integer([:positive])}"
      seed_legacy_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "x"}])

      before = Content.get_paper(slug).content
      {:ok, stats} = DoctrineBackfill.run(dry_run: true)
      assert Enum.any?(stats.changes, &(&1.slug == slug))
      assert Content.get_paper(slug).content == before
    end
  end

  describe "run/1 --apply" do
    test "backfills a legacy paper: title@0, passes the template gate, body_html gains the title" do
      slug = "doctrine-apply-#{System.unique_integer([:positive])}"

      seed_legacy_paper(slug, [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "body"}]
        }
      ])

      {:ok, stats} = DoctrineBackfill.run(dry_run: false)
      assert stats.changed_papers >= 1

      after_content = Content.get_paper(slug).content
      new_blocks = after_content["blocks"]

      # Block 0 is the locked doctrine title, and the full gate is clean.
      assert [%{"type" => "heading", "role" => "title", "locked" => true, "text" => title} | _] =
               new_blocks

      assert Template.validate(new_blocks) == []
      # The re-rendered cache reflects the new title (render parity).
      assert after_content["body_html"] =~ title
    end

    test "promotes an image asset to the featured block on apply" do
      slug = "doctrine-featured-#{System.unique_integer([:positive])}"

      seed_legacy_paper(slug, [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "intro"}]
        },
        %{"id" => "img", "type" => "image", "src" => "https://cdn/hero.png", "alt" => "Hero"}
      ])

      {:ok, _} = DoctrineBackfill.run(dry_run: false)

      blocks = Content.get_paper(slug).content["blocks"]
      featured = Enum.at(blocks, 1)
      assert featured["role"] == "featured"
      assert featured["locked"] == true
      assert featured["src"] == "https://cdn/hero.png"
      # Only one image total (moved, not duplicated).
      assert Enum.count(blocks, &(&1["type"] == "image")) == 1
    end

    test "apply refreshes the projection and bumps both revs like the real writer" do
      slug = "doctrine-proj-#{System.unique_integer([:positive])}"

      seed_legacy_paper(slug, [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "body"}]
        }
      ])

      before_doc = Content.get_paper(slug)

      {:ok, _} = DoctrineBackfill.run(dry_run: false)

      after_doc = Content.get_paper(slug)

      # The streaming content rev bumped by one, the opaque row rev regenerated —
      # a changed body must never hide under an unchanged rev.
      assert after_doc.content["rev"] == before_doc.content["rev"] + 1
      refute after_doc.rev == before_doc.rev

      # The projected body (content["body"], written by Projection.project like
      # the real write path) was re-rendered and now carries the synthesized
      # title — not the stale pre-doctrine structure.
      assert after_doc.content["body"]["html"] =~ after_doc.title
      assert [%{"role" => "title"} | _] = after_doc.content["body"]["blocks"]
    end

    test "is idempotent — a second --apply writes nothing for the same paper" do
      slug = "doctrine-idem-#{System.unique_integer([:positive])}"
      seed_legacy_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "x"}])

      {:ok, first} = DoctrineBackfill.run(dry_run: false)
      assert Enum.any?(first.changes, &(&1.slug == slug))
      after_first = Content.get_paper(slug).content

      {:ok, second} = DoctrineBackfill.run(dry_run: false)
      refute Enum.any?(second.changes, &(&1.slug == slug))
      assert Content.get_paper(slug).content == after_first
    end
  end

  describe "run/1 byte-stability for conformers (D3)" do
    test "a paper that already conforms is left BYTE-IDENTICAL by --apply" do
      slug = "doctrine-conform-#{System.unique_integer([:positive])}"

      [title_block, _featured] = Template.template_blocks("Already Doctrine")

      # Seed an ALREADY-conforming paper (title@0 + body). upsert_paper preserves
      # the locked title (single role:title @0) and validates clean.
      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          style: "article",
          blocks: [
            title_block,
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "b"}]
            }
          ]
        })

      before = Content.get_paper(slug).content
      before_bytes = Jason.encode!(before)

      {:ok, stats} = DoctrineBackfill.run(dry_run: false)
      # This paper is NOT in the changed set — it conformed.
      refute Enum.any?(stats.changes, &(&1.slug == slug))
      assert stats.conforms >= 1

      after_content = Content.get_paper(slug).content
      # Byte-for-byte identical (term equality AND serialized bytes).
      assert after_content == before
      assert Jason.encode!(after_content) == before_bytes
    end
  end

  describe "run/1 tenancy + report shape" do
    test "the report carries the full stat shape" do
      slug = "doctrine-shape-#{System.unique_integer([:positive])}"
      seed_legacy_paper(slug, [%{"id" => "p1", "type" => "paragraph", "text" => "x"}])

      {:ok, stats} = DoctrineBackfill.run(dry_run: true)

      for key <- [
            :scanned,
            :conforms,
            :changed_papers,
            :titles_synthesized,
            :featured_inserted,
            :featured_skipped,
            :dry_run,
            :changes,
            :unfixable
          ] do
        assert Map.has_key?(stats, key), "stats missing #{key}"
      end
    end

    test "repairs a paper in a NON-default workspace too (tenancy-complete)" do
      ws = Barkpark.TenancyFixtures.create_workspace!("doctrine-other")
      project = Barkpark.TenancyFixtures.create_project!(ws, "doctrine-other-p")

      slug = "doctrine-tenant-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          style: "article",
          workspace_id: ws.id,
          project_id: project.id,
          blocks: [%{"id" => "p1", "type" => "paragraph", "text" => "tenant body"}]
        })

      {:ok, _} = DoctrineBackfill.run(dry_run: false)

      repaired = Repo.get_by!(Document, doc_id: slug, type: "paper")
      assert repaired.workspace_id == ws.id
      assert [%{"role" => "title", "locked" => true} | _] = repaired.content["blocks"]
      assert Template.validate(repaired.content["blocks"]) == []
    end
  end
end
