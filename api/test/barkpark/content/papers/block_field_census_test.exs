defmodule Barkpark.Content.Papers.BlockFieldCensusTest do
  @moduledoc """
  The silent-content-loss write gate, EXTENDED to the census siblings of note/card
  (pt-backlog-block-field-census, the follow-up to #5731).

  Two block families whose renderer historically returned an EMPTY STRING (not
  a visible "no data" placeholder) when their content key was absent are covered
  by the `Slots.field_vocab/1` + `Slots.lossy_shape?/1` narrow rule:

    * `callout` — its body comes from the legacy `content` inline array (or the
      materialized `body` slot) via `callout_body_inline/1`, plus an optional
      `title`. The production repair established prose under `text` as a
      deterministic legacy dialect, so readers consume it and write boundaries
      canonicalize it to `content` instead of rejecting or dropping it.
    * `pipeline` — its flow comes from `nodes: [%{kind,title,detail,files}]`.
      A node list stranded under a mis-keyed container (`steps`/`stages`/…) makes
      `pipeline_html/1` return "" — a totally invisible loss.

  The rule stays NARROW (the #5731 argument): a callout/pipeline whose CONSUMED
  key is populated is never flagged however many chrome keys ride along, and the
  write-side ratchet only refuses a NEWLY-lossy block (existing losses persist).

  Tier-2 types (stat/stats/heatmap/chart/table/figure/task-board) are DELIBERATELY
  left ungated: their empty state renders a VISIBLE `"<kind> — no data"`
  placeholder, so an author gets a signal — that is honest empty-state rendering,
  not silent total loss. Tier-3 types (stage/notes/terminal) already read a legacy
  scalar fallback. See the census on the task for the full per-type ruling.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.PortableDoc.Slots
  alias Barkpark.Repo

  @dataset "production"

  # ── fixtures ────────────────────────────────────────────────────────────

  defp locked_title(text) do
    %{
      "id" => "tpl-title",
      "type" => "heading",
      "level" => 1,
      "role" => "title",
      "locked" => true,
      "text" => text
    }
  end

  defp para(text, id \\ "p1") do
    %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
  end

  # A callout in the proven legacy text dialect. Readers consume it and writers
  # canonicalize it to `content`.
  defp text_callout(id \\ "co1"),
    do: %{"id" => id, "type" => "callout", "text" => "Legacy callout prose"}

  # A clean callout — body authored under the consumed `content` inline array.
  defp clean_callout(id \\ "co1") do
    %{
      "id" => id,
      "type" => "callout",
      "tone" => "info",
      "content" => [%{"type" => "text", "value" => "A real callout body"}]
    }
  end

  # A pipeline in the LOSSY shape: empty `nodes`, prose stranded under `steps`.
  defp lossy_pipeline(id \\ "pl1") do
    %{
      "id" => id,
      "type" => "pipeline",
      "nodes" => [],
      "steps" => [%{"title" => "Stranded stage", "detail" => "gone"}]
    }
  end

  # A clean pipeline — real nodes carrying prose.
  defp clean_pipeline(id \\ "pl1") do
    %{
      "id" => id,
      "type" => "pipeline",
      "nodes" => [%{"kind" => "source", "title" => "ingest", "detail" => "reads rows"}]
    }
  end

  defp fresh_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ── Slots.lossy_shape?/1 — callout ──────────────────────────────────────

  describe "Slots.lossy_shape?/1 — callout" do
    test "a callout with prose under `text` is consumed by the legacy fallback" do
      callout = text_callout()

      refute Slots.lossy_shape?(callout)

      assert Slots.callout_body_inline(callout) == [
               %{"type" => "text", "value" => "Legacy callout prose"}
             ]
    end

    test "NO FALSE ALARM: a callout with a real `content` body is NOT lossy" do
      refute Slots.lossy_shape?(clean_callout())
    end

    test "NO FALSE ALARM: a callout with only a `title` (no body) is NOT lossy" do
      refute Slots.lossy_shape?(%{"id" => "co2", "type" => "callout", "title" => "Heads up"})
    end

    test "NO FALSE ALARM: a callout with a materialized `body` slot is NOT lossy" do
      callout = %{
        "id" => "co3",
        "type" => "callout",
        "tone" => "warning",
        "slots" => %{
          "body" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}]
        }
      }

      refute Slots.lossy_shape?(callout)
    end

    test "a genuinely empty callout (no unknown loud key) is NOT lossy — empty, not LOSS" do
      refute Slots.lossy_shape?(%{"id" => "co0", "type" => "callout"})
    end

    test "a callout carrying only chrome (tone/collapsed) is NOT lossy" do
      refute Slots.lossy_shape?(%{
               "id" => "co0",
               "type" => "callout",
               "tone" => "info",
               "collapsed" => false
             })
    end
  end

  # ── Slots.lossy_shape?/1 — pipeline ─────────────────────────────────────

  describe "Slots.lossy_shape?/1 — pipeline" do
    test "a pipeline with empty nodes and prose stranded under `steps` is lossy" do
      assert Slots.lossy_shape?(lossy_pipeline())
    end

    test "NO FALSE ALARM: a pipeline with real nodes is NOT lossy" do
      refute Slots.lossy_shape?(clean_pipeline())
    end

    test "NO FALSE ALARM: a pipeline with real nodes AND an extra chrome key is NOT lossy" do
      refute Slots.lossy_shape?(Map.put(clean_pipeline(), "note", "authoring hint"))
    end

    test "a genuinely empty pipeline (nodes: [], no loud key) is NOT lossy — empty, not LOSS" do
      refute Slots.lossy_shape?(%{"id" => "pl0", "type" => "pipeline", "nodes" => []})
    end

    test "a pipeline with NO nodes key at all and no loud key is NOT lossy" do
      refute Slots.lossy_shape?(%{"id" => "pl0", "type" => "pipeline"})
    end
  end

  # ── upsert_paper — NEW lossy write is refused ───────────────────────────

  describe "upsert_paper census gate" do
    test "a NEW text-dialect callout is canonicalized without losing its prose" do
      slug = fresh_slug("legacy-callout")

      assert {:ok, saved} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Callouts",
                   blocks: [locked_title("Callouts"), para("Real body."), text_callout()]
                 })
               )

      callout = Enum.find(saved.content["blocks"], &(&1["id"] == "co1"))
      refute Map.has_key?(callout, "text")
      assert callout["content"] == [%{"type" => "text", "value" => "Legacy callout prose"}]
    end

    test "a NEW lossy pipeline is rejected too" do
      slug = fresh_slug("loss-pipeline")

      assert {:error, {:halted, msg}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Pipelines",
                   blocks: [locked_title("Pipelines"), lossy_pipeline()]
                 })
               )

      assert msg =~ "renderer ignores"
      assert Content.get_paper(slug, @dataset) == nil
    end

    test "NO FALSE ALARM: a real callout + a real pipeline save cleanly" do
      slug = fresh_slug("ok-census")

      assert {:ok, doc} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "OK",
                   blocks: [locked_title("OK"), clean_callout(), clean_pipeline()]
                 })
               )

      assert doc.status == "published"
    end
  end

  # ── the RATCHET — existing losses do not brick ──────────────────────────

  defp seed_stored_text_callout! do
    slug = fresh_slug("ratchet-callout")

    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          title: "Ratchet",
          blocks: [locked_title("Ratchet"), para("Body block.", "p1")]
        })
      )

    blocks = [locked_title("Ratchet"), para("Body block.", "p1"), text_callout("co1")]

    {:ok, _} =
      doc
      |> Document.changeset(%{"content" => Map.put(doc.content, "blocks", blocks)})
      |> Repo.update()

    slug
  end

  describe "upsert_paper ratchet" do
    test "RATCHET: an already-stored text callout re-saves and canonicalizes" do
      slug = seed_stored_text_callout!()
      doc = Content.get_paper(slug, @dataset)
      callout = Enum.find(doc.content["blocks"], &(&1["id"] == "co1"))
      assert callout["text"] == "Legacy callout prose"
      refute Map.has_key?(callout, "content")

      assert {:ok, saved} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Ratchet",
                   blocks: doc.content["blocks"]
                 })
               )

      assert saved.status == "published"
      callout = Enum.find(saved.content["blocks"], &(&1["id"] == "co1"))
      refute Map.has_key?(callout, "text")
      assert callout["content"] == [%{"type" => "text", "value" => "Legacy callout prose"}]
    end

    test "RATCHET: a clean callout can be replaced by the text dialect without loss" do
      slug = fresh_slug("ratchet-clean-callout")

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            title: "Clean",
            blocks: [locked_title("Clean"), para("Body."), clean_callout("co1")]
          })
        )

      assert {:ok, saved} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   title: "Clean",
                   blocks: [locked_title("Clean"), para("Body."), text_callout("co1")]
                 })
               )

      callout = Enum.find(saved.content["blocks"], &(&1["id"] == "co1"))
      assert callout["content"] == [%{"type" => "text", "value" => "Legacy callout prose"}]
    end
  end

  describe "apply_paper_block_op census edge (canvas)" do
    test "editing a clean callout into the text dialect canonicalizes the patch" do
      slug = fresh_slug("op-callout")

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            title: "Op",
            blocks: [locked_title("Op"), para("Body."), clean_callout("co1")]
          })
        )

      # Blank the canonical `content` and supply the proven legacy `text` dialect.
      op = %{
        "op" => "patch-block",
        "id" => "co1",
        "patch" => %{"content" => [], "text" => "Legacy canvas prose"}
      }

      assert {:ok, _receipt} = Content.apply_paper_block_op(slug, op, @dataset)

      doc = Content.get_paper(slug, @dataset)
      callout = Enum.find(doc.content["blocks"], &(&1["id"] == "co1"))
      refute Slots.lossy_shape?(callout)
      refute Map.has_key?(callout, "text")
      assert callout["content"] == [%{"type" => "text", "value" => "Legacy canvas prose"}]
    end
  end
end
