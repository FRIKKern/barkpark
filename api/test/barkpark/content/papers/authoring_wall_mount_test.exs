defmodule Barkpark.Content.Papers.AuthoringWallMountTest do
  @moduledoc """
  The fifth and LAST publish-wall mount (authoring-excellence D26):
  `Content.upsert_paper/2` births PUBLISHED papers via direct Repo writes, so
  it runs the shared `Barkpark.Content.AuthoringWall` chain on a synthesized
  ref BEFORE the row write.

  Pins:

    * a tagless NEW paper birth is refused with the RAW
      `{:error, {:label_spine, details}}` tuple (never flattened into
      `{:halted, _}`) and writes NOTHING;
    * a compliant birth publishes AND gains the D7 `main_tag` stamp;
    * a grandfathered `(slug, dataset)` paper republishes unchanged via the
      exemption ledger — and keeps its exemption (spine did not pass, so the
      ratchet must not fire);
    * a self-id republish never trips E4 (the slug IS the published id and
      reaches DedupWall's incumbent exclusion);
    * `bypass_wall: true` (the audited internal-projection escape) skips
      wall AND stamp;
    * the D28 fixed semantics this extraction carries: recompute-else-drop
      main_tag (a stale key is deleted, never republished) and
      clear-on-FULL-pass (an E3-rejected weighted adoption keeps the
      grandfathering).
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.AuthoringWall
  alias Barkpark.Content.{Document, Exemptions}
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @dataset "production"

  defp fresh_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp blocks(title, body) do
    [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => title
      },
      %{"id" => "p1", "type" => "paragraph", "content" => [%{"type" => "text", "value" => body}]}
    ]
  end

  defp epic_blocks(title) do
    [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => title
      },
      %{
        "id" => "ingress",
        "type" => "ingress",
        "content" => [
          %{"type" => "text", "value" => "Why this wave exists and what the evidence changes."}
        ]
      },
      %{
        "id" => "stats",
        "type" => "stats",
        "items" => [%{"label" => "criteria proved", "value" => "7"}]
      },
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "The verified argument begins here."}]
      }
    ]
  end

  defp epic_attrs(slug, blocks) do
    LabelFixtures.register_tags!(@dataset, ["epic-cycle-wave-paper"])

    attrs =
      LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "dataset" => @dataset,
        "blocks" => blocks
      })

    [strongest | rest] = attrs["tags"]

    Map.put(attrs, "tags", [
      Map.put(strongest, "tag", "epic-cycle-wave-paper")
      | rest
    ])
  end

  defp paper_row(slug) do
    Repo.one(
      from(d in Document,
        where: d.doc_id == ^slug and d.type == "paper" and d.dataset == @dataset
      )
    )
  end

  describe "the wall at the paper birth seam" do
    test "a tagless NEW paper birth returns the RAW {:error, {:label_spine, details}} and writes nothing" do
      slug = fresh_slug("wall-tagless")

      assert {:error, {:label_spine, details}} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "dataset" => @dataset,
                 "blocks" => blocks("Tagless birth", "Real body content, no labels.")
               })

      # The details read like documentation (field/rule/fix), and the tuple is
      # RAW — a {:halted, _} flattening would mis-route the 422 to the 409 head.
      assert %{field: _, rule: _, fix: _} = details
      refute paper_row(slug)
    end

    test "a compliant birth publishes AND gains the D7 main_tag stamp (ingest-born papers are denormalized)" do
      slug = fresh_slug("wall-ok")

      attrs =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "blocks" => blocks("Compliant birth", "Real body content with labels.")
        })

      assert {:ok, doc} = Content.upsert_paper(attrs)
      assert doc.status == "published"

      # main_tag = the strength argmax of the fixture tags (first = strongest).
      [%{"tag" => strongest} | _] = attrs["tags"]
      assert doc.content["main_tag"] == strongest
      assert doc.content["tags"] == attrs["tags"]
      assert doc.content["description"] == attrs["description"]
    end

    test "a self-id republish never trips E4 — same slug, same title, republished unchanged" do
      slug = fresh_slug("wall-self")

      attrs =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "blocks" => blocks("Self republish paper title", "First write of the body.")
        })

      assert {:ok, _} = Content.upsert_paper(attrs)

      # Identical title + tags again: the only published row sharing every
      # token is the incumbent ITSELF — excluded by doc_id == slug, so the
      # wall passes instead of 409ing the paper against its own row.
      assert {:ok, doc} = Content.upsert_paper(attrs)
      assert doc.content["rev"] == 2
    end

    test "an unregistered weighted tag is refused with the RAW {:error, {:unknown_tag, payload}} (E3)" do
      slug = fresh_slug("wall-e3")

      attrs = %{
        "slug" => slug,
        "dataset" => @dataset,
        "blocks" => blocks("E3 refusal", "Body content for the E3 case."),
        "description" => "A perfectly honest description, long enough for the spine.",
        "tags" => LabelFixtures.named_weighted_labels(["never-registered-tag-xq1"])["tags"]
      }

      assert {:error, {:unknown_tag, %{unknown: ["never-registered-tag-xq1"]}}} =
               Content.upsert_paper(attrs)

      refute paper_row(slug)
    end

    test "bypass_wall: true (audited escape) skips wall AND stamp" do
      slug = fresh_slug("wall-bypass")

      assert {:ok, doc} =
               Content.upsert_paper(
                 %{
                   "slug" => slug,
                   "dataset" => @dataset,
                   "blocks" => blocks("Bypassed projection", "Plan-paper-like content.")
                 },
                 bypass_wall: true
               )

      assert doc.status == "published"
      refute Map.has_key?(doc.content, "main_tag")
    end

    test "a canonical Epic birth that uses an empty spacer is rejected and writes nothing" do
      slug = fresh_slug("wall-epic-gap")

      attrs =
        epic_attrs(
          slug,
          epic_blocks("Gap-heavy Epic") ++
            [%{"id" => "blank-layout", "type" => "paragraph", "content" => []}]
        )

      assert {:error, {:invalid_epic_paper_quality, details}} =
               Content.upsert_paper(attrs)

      assert details["failures"] == ["empty_paragraph_spacer"]
      refute paper_row(slug)
    end

    test "a canonical Epic birth using a LAUNDERED spacer (an empty inline leaf) is still rejected and writes nothing" do
      slug = fresh_slug("wall-epic-laundered")

      attrs =
        epic_attrs(
          slug,
          epic_blocks("Laundered-gap Epic") ++
            [
              %{
                "id" => "blank-layout",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "   "}]
              }
            ]
        )

      assert {:error, {:invalid_epic_paper_quality, details}} = Content.upsert_paper(attrs)

      assert details["failures"] == ["empty_paragraph_spacer"]
      refute paper_row(slug)
    end

    test "a canonical Epic birth whose prose rides the value key PUBLISHES - the wall reads text, not key shape" do
      slug = fresh_slug("wall-epic-value")

      attrs =
        epic_attrs(
          slug,
          epic_blocks("Value-keyed Epic") ++
            [
              %{
                "id" => "value-leaf",
                "type" => "paragraph",
                "content" => [
                  %{
                    "type" => "paragraph",
                    "value" =>
                      "A4 (media /meta) CONFIRMED LIVE: anonymous GET /media/:id/meta returned a private asset's filename, path and size to an unauthenticated caller - the live felix-pristine-wave-14 leaf shape."
                  }
                ]
              }
            ]
        )

      assert {:ok, doc} = Content.upsert_paper(attrs)
      assert doc.status == "published"
      assert doc.content["main_tag"] == "epic-cycle-wave-paper"
    end

    test "a reference-shaped canonical Epic birth clears the shared wall" do
      slug = fresh_slug("wall-epic-ok")

      assert {:ok, doc} =
               Content.upsert_paper(epic_attrs(slug, epic_blocks("Reference-shaped Epic")))

      assert doc.status == "published"
      assert doc.content["main_tag"] == "epic-cycle-wave-paper"
    end

    test "a declared five-reader suite fails closed when one reader is not passing" do
      slug = fresh_slug("wall-epic-reader")

      attrs =
        slug
        |> epic_attrs(epic_blocks("Reader-failed Epic"))
        |> Map.put("reader_checks", %{
          "public" => "pass",
          "studio" => "pass",
          "tui80" => "pass",
          "email" => "fail",
          "cli_api" => "pass"
        })

      assert {:error, {:invalid_epic_paper_quality, details}} =
               Content.upsert_paper(attrs)

      assert details["failures"] == ["reader_email_failed"]
      refute paper_row(slug)
    end

    test "the canonical Epic tag does not impose Paper composition rules on tasks" do
      slug = fresh_slug("epic-tagged-task")
      LabelFixtures.register_tags!(@dataset, ["epic-cycle-wave-paper"])

      content = %{
        "description" => "A task may share the Epic taxonomy without becoming a Paper.",
        "tags" => [
          %{
            "tag" => "epic-cycle-wave-paper",
            "strength" => 90,
            "rationale" => "This task is part of the canonical Epic Paper campaign."
          }
        ],
        "blocks" => []
      }

      ref = %Document{
        doc_id: slug,
        type: "task",
        title: "Epic-tagged task #{slug}",
        content: content,
        dataset: @dataset
      }

      assert {:ok, stamped} =
               AuthoringWall.enforce(ref, "task", slug, @dataset)

      assert stamped["main_tag"] == "epic-cycle-wave-paper"
    end
  end

  describe "grandfathering — the (slug, dataset) exemption ledger" do
    test "a pre-wall paper republishes unchanged via exemption AND keeps its ledger row (D28 clear-on-FULL-pass)" do
      slug = fresh_slug("wall-legacy")

      # Birth the pre-wall row exactly as history did: unwalled.
      assert {:ok, _} =
               Content.upsert_paper(
                 %{
                   "slug" => slug,
                   "dataset" => @dataset,
                   "blocks" => blocks("Legacy paper", "Pre-wall content, no labels.")
                 },
                 bypass_wall: true
               )

      LabelFixtures.exempt!([slug], @dataset)

      # A tagless UPDATE (walled, no bypass) — the spine fails, the exemption
      # carries it through the WHOLE wall unchanged.
      assert {:ok, doc} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "dataset" => @dataset,
                 "blocks" => blocks("Legacy paper", "Pre-wall content, edited later.")
               })

      assert doc.content["rev"] == 2
      # The spine did NOT pass, so the ratchet must not have fired.
      assert Exemptions.member?(slug, @dataset)
    end

    test "ratchet: a FULL-pass republish clears the exemption; stripping the labels then re-hits the wall" do
      slug = fresh_slug("wall-ratchet")

      assert {:ok, _} =
               Content.upsert_paper(
                 %{
                   "slug" => slug,
                   "dataset" => @dataset,
                   "blocks" => blocks("Ratchet paper", "Pre-wall content.")
                 },
                 bypass_wall: true
               )

      LabelFixtures.exempt!([slug], @dataset)

      # Opt into the new world: a fully compliant republish.
      assert {:ok, _} =
               Content.upsert_paper(
                 LabelFixtures.paper_attrs(%{
                   "slug" => slug,
                   "dataset" => @dataset,
                   "blocks" => blocks("Ratchet paper", "Now with honest labels.")
                 })
               )

      refute Exemptions.member?(slug, @dataset)

      # From the NEXT write on the doc is held to the wall like any new one —
      # a label-stripping update is refused. (tags/description absent from
      # attrs leave the stored labels untouched, so strip explicitly.)
      assert {:error, {:label_spine, _}} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "dataset" => @dataset,
                 "blocks" => blocks("Ratchet paper", "Stripped again."),
                 "tags" => [],
                 "description" => ""
               })
    end

    test "D28 clear-on-FULL-pass: an E3-rejected weighted adoption does NOT cost the grandfathering" do
      slug = fresh_slug("wall-e3-exempt")

      assert {:ok, _} =
               Content.upsert_paper(
                 %{
                   "slug" => slug,
                   "dataset" => @dataset,
                   "blocks" => blocks("Adopting paper", "Pre-wall content.")
                 },
                 bypass_wall: true
               )

      LabelFixtures.exempt!([slug], @dataset)

      # The spine PASSES (compliant shape) but E3 rejects the unregistered
      # vocabulary — the publish FAILED, so the ledger row must survive (the
      # old clear-at-spine-pass would have charged the exemption here).
      attrs = %{
        "slug" => slug,
        "dataset" => @dataset,
        "blocks" => blocks("Adopting paper", "Trying a weighted vocabulary."),
        "description" => "A description long enough to satisfy the label spine.",
        "tags" => LabelFixtures.named_weighted_labels(["never-registered-tag-xq2"])["tags"]
      }

      assert {:error, {:unknown_tag, _}} = Content.upsert_paper(attrs)
      assert Exemptions.member?(slug, @dataset)

      # And the doc still republishes tag-less via its retained exemption.
      assert {:ok, _} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "dataset" => @dataset,
                 "blocks" => blocks("Adopting paper", "Back to the legacy shape."),
                 "tags" => [],
                 "description" => ""
               })
    end

    test "D28 recompute-else-drop: a stale main_tag key is DELETED on an exempt tagless republish, never re-persisted" do
      slug = fresh_slug("wall-stale-mt")

      # A backfilled-then-degraded row: content carries a main_tag stamp but
      # the tags were later edited down to a shape that derives none.
      assert {:ok, first} =
               Content.upsert_paper(
                 %{
                   "slug" => slug,
                   "dataset" => @dataset,
                   "blocks" => blocks("Stale stamp paper", "Pre-wall content.")
                 },
                 bypass_wall: true
               )

      stale_content =
        first.content
        |> Map.put("main_tag", "stale-tag")
        |> Map.put("tags", ["old-flat"])

      {:ok, _} =
        first
        |> Document.changeset(%{"content" => stale_content})
        |> Repo.update()

      LabelFixtures.exempt!([slug], @dataset)

      # A walled republish (exempt, tagless): the stamp recomputes, derives
      # nothing, and DROPS the stale key rather than republishing it.
      assert {:ok, doc} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "dataset" => @dataset,
                 "blocks" => blocks("Stale stamp paper", "Edited under exemption.")
               })

      refute Map.has_key?(doc.content, "main_tag")
    end
  end
end
