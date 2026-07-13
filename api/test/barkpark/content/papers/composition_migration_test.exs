defmodule Barkpark.Content.Papers.CompositionMigrationTest do
  @moduledoc """
  Coverage for the legacy-composite → widget-composition corpus migration
  (ct-rollout):

    * `plan/1` (pure classifier) — cards → section{grid} of card widgets under
      the PROVEN model-B equivalence (asserted against the REAL emitters, not
      the plan's own claim); notes → note widgets and pipeline → stage widgets
      under STRICT per-item byte-parity; the skip paths (missing id, unknown
      keys, nested-in-container, empty items); the fixture/wave exclusions;
      idempotence (plan over the plan's own output → :conforms).
    * `run/1` (DB scan + apply) — dry-run default writes nothing; `--apply`
      migrates a legacy paper (re-rendering body_html like the real writer) and
      a second dry-run plans 0 (idempotent).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.CompositionMigration
  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.Render.Components

  # A hand-built paper Document (no DB) for the pure `plan/1` surface.
  defp paper(blocks, slug \\ "p") do
    %Document{
      doc_id: slug,
      type: "paper",
      dataset: "production",
      title: "T",
      content: %{"blocks" => blocks}
    }
  end

  defp legacy_cards(id \\ "cb-1") do
    %{
      "id" => id,
      "type" => "cards",
      "items" => [
        %{"title" => "Alpha", "text" => "First card", "tone" => "info"},
        %{"title" => "Beta", "text" => "Second card"}
      ]
    }
  end

  defp legacy_notes(id \\ "nb-1") do
    %{
      "id" => id,
      "type" => "notes",
      "items" => [
        %{"label" => "L1", "lead" => "Lead", "text" => "Body text"},
        %{"label" => "L2", "text" => "No lead"}
      ]
    }
  end

  defp legacy_pipeline(id \\ "pb-1") do
    %{
      "id" => id,
      "type" => "pipeline",
      "nodes" => [
        %{"kind" => "source", "title" => "Ingest", "detail" => "raw", "source" => true},
        %{"kind" => "emit", "title" => "Render", "files" => "render.ex"}
      ]
    }
  end

  # ── plan/1 — cards → section-of-cards (model-B equivalence) ────────────────

  describe "plan/1 cards" do
    test "migrates cards to a grid section of card widgets, id preserved, children derived" do
      assert {:change, [section], meta} = CompositionMigration.plan(paper([legacy_cards()]))

      assert section["type"] == "section"
      assert section["id"] == "cb-1"
      assert section["layout"] == %{"mode" => "grid", "tracks" => 2, "gap" => "sm"}

      assert [c1, c2] = section["blocks"]
      assert c1["id"] == "cb-1-card1" and c2["id"] == "cb-1-card2"
      assert c1["type"] == "card" and c2["type"] == "card"

      # tone is present-only chrome: kept on the toned card, absent on the other.
      assert c1["tone"] == "info"
      refute Map.has_key?(c2, "tone")

      # The smoke/cards.mjs CARD fixture slot shape.
      assert c1["slots"]["title"] == [%{"type" => "heading", "text" => "Alpha"}]

      assert c1["slots"]["body"] == [
               %{
                 "type" => "paragraph",
                 "content" => [%{"type" => "text", "value" => "First card"}]
               }
             ]

      assert [%{id: "cb-1", from: "cards", children: 2, parity: :model_b_equivalence}] =
               meta.migrated

      assert meta.skipped == []
    end

    test "the model-B equivalence is REAL: widget bytes == legacy item bytes under the 2-rule chrome map" do
      # Proven against the real emitters, not the plan's own claim: container div
      # + tone class byte-identical; only bp-card__t→<h2> and bp-card__d→<p> move.
      assert {:change, [section], _} = CompositionMigration.plan(paper([legacy_cards()]))

      legacy_full = Components.cards_html(legacy_cards())

      expected_items =
        legacy_full
        |> String.replace_prefix(~s(<div class="bp-cards">), "")
        |> String.replace_suffix("</div>", "")
        |> String.replace(~r|<div class="bp-card__t">([^<]*)</div>|, "<h2>\\1</h2>")
        |> String.replace(~r|<div class="bp-card__d">([^<]*)</div>|, "<p>\\1</p>")

      migrated_items = section["blocks"] |> Enum.map(&Components.card_html/1) |> Enum.join("")

      assert migrated_items == expected_items
      # Non-vacuous: the tone class and both escaped texts really are in there.
      assert migrated_items =~ ~s(<div class="bp-card bp-card--info">)
      assert migrated_items =~ "<h2>Alpha</h2>"
      assert migrated_items =~ "<p>Second card</p>"
    end

    test "escaped content survives the proof (entities on both sides)" do
      block = %{
        "id" => "cb-esc",
        "type" => "cards",
        "items" => [%{"title" => "A < B", "text" => "Fish & chips"}]
      }

      assert {:change, [section], _} = CompositionMigration.plan(paper([block]))
      [card] = section["blocks"]
      html = Components.card_html(card)
      assert html =~ "<h2>A &lt; B</h2>"
      assert html =~ "<p>Fish &amp; chips</p>"
    end
  end

  # ── plan/1 — notes / pipeline (strict byte parity) ──────────────────────────

  describe "plan/1 notes" do
    test "migrates notes to a 1-track section of note widgets with STRICT per-item byte-parity" do
      assert {:change, [section], meta} = CompositionMigration.plan(paper([legacy_notes()]))

      assert section["id"] == "nb-1"
      assert section["layout"] == %{"mode" => "grid", "tracks" => 1, "gap" => "sm"}
      assert [%{id: "nb-1", from: "notes", children: 2, parity: :byte_equal}] = meta.migrated

      # THE byte proof, against the real emitters: the legacy render is exactly
      # the bp-notes wrapper around the migrated widgets' joined bytes.
      migrated = section["blocks"] |> Enum.map(&Components.note_item_html/1) |> Enum.join("")

      assert Components.notes_html(legacy_notes()) ==
               ~s(<div class="bp-notes">) <> migrated <> "</div>"

      # Non-vacuous: real content in the bytes.
      assert migrated =~ ~s(<span class="bp-note__k">L1</span>)
      assert migrated =~ "<b>Lead</b> Body text"
    end

    test "note widgets persist the canonical dual form (flat fields + slots), lead present-only" do
      assert {:change, [section], _} = CompositionMigration.plan(paper([legacy_notes()]))
      [n1, n2] = section["blocks"]

      assert n1["label"] == "L1" and n1["lead"] == "Lead" and n1["text"] == "Body text"
      assert is_map(n1["slots"]) and Map.has_key?(n1["slots"], "lead")
      # No lead on item 2 → the key is absent on BOTH sides (never "").
      refute Map.has_key?(n2, "lead")
      refute Map.has_key?(n2["slots"], "lead")
    end
  end

  describe "plan/1 pipeline" do
    test "migrates pipeline to an N-track section of stage widgets with STRICT per-item byte-parity" do
      assert {:change, [section], meta} = CompositionMigration.plan(paper([legacy_pipeline()]))

      assert section["id"] == "pb-1"
      assert section["layout"] == %{"mode" => "grid", "tracks" => 2, "gap" => "sm"}
      assert [%{id: "pb-1", from: "pipeline", children: 2, parity: :byte_equal}] = meta.migrated

      # THE byte proof: each stage renders the IDENTICAL pnode cell its legacy
      # node renders (the arrows + scroll wrapper are the documented equivalence).
      [s1, s2] = section["blocks"]
      [n1, n2] = legacy_pipeline()["nodes"]

      assert Components.stage_html(s1) ==
               Components.pipeline_html(%{"nodes" => [n1]})
               |> String.replace_prefix(~s(<div class="bp-pipe-scroll"><div class="bp-pipe">), "")
               |> String.replace_suffix("</div></div>", "")

      assert Components.stage_html(s2) ==
               Components.pipeline_html(%{"nodes" => [n2]})
               |> String.replace_prefix(~s(<div class="bp-pipe-scroll"><div class="bp-pipe">), "")
               |> String.replace_suffix("</div></div>", "")

      # Non-vacuous: the source accent + files chrome really survive.
      assert Components.stage_html(s1) =~ "bp-pnode--src"
      assert Components.stage_html(s2) =~ ~s(<div class="bp-pnode__f">render.ex</div>)
    end
  end

  # ── plan/1 — the skip + exclusion paths (the safety law) ────────────────────

  describe "plan/1 skips and exclusions" do
    test "a legacy block with no id is SKIPPED (anchors must survive), never migrated" do
      block = Map.delete(legacy_cards(), "id")
      assert {:skips_only, [skip]} = CompositionMigration.plan(paper([block]))
      assert skip.type == "cards"
      assert skip.reason =~ "no id"
    end

    test "a legacy block carrying unknown keys is SKIPPED — semantics we do not understand" do
      block = Map.put(legacy_cards(), "mystery", true)
      assert {:skips_only, [skip]} = CompositionMigration.plan(paper([block]))
      assert skip.reason =~ "outside the legacy vocabulary"
    end

    test "an item carrying unknown keys is SKIPPED with the item index" do
      block = %{
        "id" => "cb-x",
        "type" => "cards",
        "items" => [%{"title" => "ok", "text" => "ok"}, %{"title" => "bad", "href" => "/x"}]
      }

      assert {:skips_only, [skip]} = CompositionMigration.plan(paper([block]))
      assert skip.reason =~ "item 2"
    end

    test "a legacy block NESTED inside a container is SKIPPED and reported, never migrated in place" do
      nested = %{
        "id" => "sec-1",
        "type" => "section",
        "blocks" => [legacy_cards("cb-deep")]
      }

      assert {:skips_only, [skip]} = CompositionMigration.plan(paper([nested]))
      assert skip.id == "cb-deep"
      assert skip.reason =~ "nested inside a container"
    end

    test "an empty-items legacy block is SKIPPED (legacy render is already empty — nothing provable)" do
      block = %{"id" => "cb-e", "type" => "cards", "items" => []}
      assert {:skips_only, [skip]} = CompositionMigration.plan(paper([block]))
      assert skip.reason =~ "empty or missing items"
    end

    test "one provable + one unprovable block: the provable one migrates, the other is reported" do
      bad = Map.put(legacy_notes("nb-bad"), "mystery", 1)

      assert {:change, [section, kept], meta} =
               CompositionMigration.plan(paper([legacy_cards(), bad]))

      assert section["type"] == "section"
      # The unprovable block is left BYTE-IDENTICAL in place.
      assert kept == bad
      assert [%{id: "cb-1"}] = meta.migrated
      assert [%{id: "nb-bad", type: "notes"}] = meta.skipped
    end

    test "portabledoc-showcase is EXCLUDED — its legacy blocks are an intentional fixture" do
      assert {:excluded, reason} =
               CompositionMigration.plan(paper([legacy_cards()], "portabledoc-showcase"))

      assert reason =~ "fixture"
    end

    test "wave papers are EXCLUDED" do
      assert {:excluded, reason} =
               CompositionMigration.plan(
                 paper([legacy_cards()], "composition-doctrine-wave-2026-07-10")
               )

      assert reason =~ "wave"
    end

    test "a derived child id colliding with an existing block id REFUSES the whole plan" do
      squatter = %{"id" => "cb-1-card1", "type" => "paragraph", "text" => "taken"}

      assert {:skips_only, skipped} = CompositionMigration.plan(paper([legacy_cards(), squatter]))
      assert Enum.any?(skipped, &(&1.reason =~ "unique"))
    end
  end

  # ── plan/1 — idempotence + conformance ───────────────────────────────────────

  describe "plan/1 idempotence" do
    test "a paper with no legacy composite blocks conforms (left byte-identical)" do
      assert :conforms =
               CompositionMigration.plan(
                 paper([%{"id" => "p1", "type" => "paragraph", "text" => "x"}])
               )
    end

    test "an HTML-only paper (no block list) conforms — not this migration's concern" do
      doc = %Document{
        doc_id: "h",
        type: "paper",
        dataset: "production",
        content: %{"html" => "<p>x</p>"}
      }

      assert :conforms = CompositionMigration.plan(doc)
    end

    test "plan over the plan's own output conforms (second dry-run plans 0)" do
      assert {:change, new_blocks, _} =
               CompositionMigration.plan(
                 paper([legacy_cards(), legacy_notes(), legacy_pipeline()])
               )

      assert :conforms = CompositionMigration.plan(paper(new_blocks))
      # And the migrated shape still passes the doctrine template gate.
      assert Template.validate(new_blocks) == []
    end
  end

  # ── run/1 — DB scan, dry-run default, apply, idempotence ────────────────────

  defp seed_legacy_paper(slug, blocks) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, style: "article", blocks: blocks})
      )

    slug
  end

  describe "run/1 dry-run (default, safe)" do
    test "defaults to dry-run — a bare call writes nothing" do
      slug = "compmig-default-#{System.unique_integer([:positive])}"
      seed_legacy_paper(slug, [legacy_cards("cm-c1")])

      before = Content.get_paper(slug).content
      {:ok, stats} = CompositionMigration.run()
      assert stats.dry_run == true
      assert Enum.any?(stats.changes, &(&1.slug == slug))
      assert Content.get_paper(slug).content == before
    end
  end

  describe "run/1 --apply" do
    test "migrates a legacy paper (blocks + re-rendered body_html + bumped revs), then a second dry-run plans 0" do
      slug = "compmig-apply-#{System.unique_integer([:positive])}"
      seed_legacy_paper(slug, [legacy_cards("cm-a1"), legacy_notes("cm-a2")])

      before = Content.get_paper(slug)

      {:ok, stats} = CompositionMigration.run(dry_run: false)
      assert stats.dry_run == false
      change = Enum.find(stats.changes, &(&1.slug == slug))
      assert length(change.migrated) == 2

      doc = Content.get_paper(slug)
      after_content = doc.content
      blocks = after_content["blocks"]

      # The legacy blocks are GONE; their sections carry the inherited ids.
      types = Enum.map(blocks, & &1["type"])
      refute "cards" in types
      refute "notes" in types
      assert Enum.any?(blocks, &(&1["id"] == "cm-a1" and &1["type"] == "section"))
      assert Enum.any?(blocks, &(&1["id"] == "cm-a2" and &1["type"] == "section"))

      # The cached render was refreshed like the real writer: section grid +
      # widget bytes in body_html, legacy wrappers gone.
      assert after_content["body_html"] =~ "bp-section__grid"
      assert after_content["body_html"] =~ "<h2>Alpha</h2>"
      assert after_content["body_html"] =~ ~s(<span class="bp-note__k">L1</span>)
      refute after_content["body_html"] =~ ~s(<div class="bp-cards">)
      refute after_content["body_html"] =~ ~s(<div class="bp-notes">)

      # Both revs moved (streaming content rev + opaque row rev).
      assert after_content["rev"] != before.content["rev"]
      assert doc.rev != before.rev

      # Idempotent: the second (dry) run plans ZERO changes anywhere.
      {:ok, stats2} = CompositionMigration.run()
      assert stats2.changed_papers == 0
    end

    test "a conforming paper is left BYTE-IDENTICAL by --apply" do
      slug = "compmig-conform-#{System.unique_integer([:positive])}"

      seed_legacy_paper(slug, [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "plain"}]
        }
      ])

      before = :erlang.term_to_binary(Content.get_paper(slug).content)
      {:ok, _} = CompositionMigration.run(dry_run: false)
      assert :erlang.term_to_binary(Content.get_paper(slug).content) == before
    end
  end
end
