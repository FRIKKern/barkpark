defmodule Barkpark.ContentProjectionTest do
  @moduledoc """
  Exp-P2 (barkpark-emxg) — project-on-write through the paper write path, with
  the DB. Confirms:

    * editing a bound title block updates content["title"], and the Classic
      query (Envelope) returns it at the top level;
    * doc.body resolves as a first-class %{"blocks", "html"} from free blocks;
    * lazy synthesis for a legacy doc (no content["blocks"]) is byte-equal —
      the synthesized→projected values match the originals, and the stored row
      is NOT rewritten by a read.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Envelope
  alias Barkpark.PortableDoc.Projection

  @dataset "production"

  setup do
    # A post-style "paper" schema with an explicit Expectation layout (title →
    # slug → featuredImage → body region), so synthesis has fields + layout to
    # work from — mirroring the real `post` schema's Exp-P1 layout.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"},
            %{"name" => "featuredImage", "title" => "Featured Image", "type" => "image"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "slug"},
            %{"kind" => "field", "name" => "featuredImage"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    :ok
  end

  describe "project-on-write through upsert_paper/1" do
    test "bound blocks project to content[fieldName]; free blocks → content[\"body\"]" do
      slug = "exp-projection-#{System.unique_integer([:positive])}"

      blocks = [
        %{
          "id" => "t",
          "type" => "field-string",
          "fieldName" => "title",
          "value" => "Projected Title"
        },
        %{
          "id" => "s",
          "type" => "field-slug",
          "fieldName" => "slug",
          "value" => "projected-title"
        },
        %{
          "id" => "i",
          "type" => "field-image",
          "fieldName" => "featuredImage",
          "value" => "/hero.jpg"
        },
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Free body text."}]
        }
      ]

      {:ok, doc} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
        )

      assert doc.content["title"] == "Projected Title"
      assert doc.content["slug"] == "projected-title"
      assert doc.content["featuredImage"] == "/hero.jpg"

      # doc.body is first-class: free-block JSON + rendered HTML.
      assert doc.content["body"]["blocks"] == [List.last(blocks)]
      assert doc.content["body"]["html"] =~ "Free body text."
      # the bound paragraph is NOT in the body
      refute Enum.any?(doc.content["body"]["blocks"], &(&1["id"] in ["t", "s", "i"]))

      # Classic query (Envelope) surfaces the projected fields + body at top level.
      rendered = Envelope.render(doc)
      assert rendered["title"] == "Projected Title"
      assert rendered["slug"] == "projected-title"
      assert rendered["featuredImage"] == "/hero.jpg"
      assert rendered["body"]["html"] =~ "Free body text."
    end

    test "stamps content[\"preview\"] beside content[\"body\"] — write-time manifest (pc-w1)" do
      slug = "exp-preview-#{System.unique_integer([:positive])}"

      blocks = [
        %{
          "id" => "t",
          "type" => "field-string",
          "fieldName" => "title",
          "value" => "Preview Title"
        },
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Lead paragraph."}]
        }
      ]

      # The publish wall (authoring-excellence D26) requires a ≥20-char
      # description + registered weighted tags on every walled paper birth. The
      # preview manifest mirrors BOTH (description + extensions.tags), and the
      # re-save below asserts byte-identical recomputation — so the labels must
      # be EXPLICIT and stable across both writes (paper_attrs would otherwise
      # inject fresh unique-per-call tag names + description each time). Register
      # the tags once; wrap in paper_attrs so a bare labelled map still flows
      # through the one test-side spelling.
      Barkpark.LabelFixtures.register_tags!(@dataset, ["pc-w1-lead", "pc-w1-manifest"])

      paper = %{
        slug: slug,
        dataset: @dataset,
        blocks: blocks,
        description: "Lead paragraph, spelled out past the twenty-char wall.",
        tags: [
          %{
            "tag" => "pc-w1-lead",
            "strength" => 90,
            "rationale" => "Write-time preview manifest fixture."
          },
          %{
            "tag" => "pc-w1-manifest",
            "strength" => 60,
            "rationale" => "Write-time preview manifest fixture."
          }
        ]
      }

      {:ok, doc} = Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(paper))

      # The injected :preview render_opts (epic preview-contract) stamp an
      # OpenGraph-shaped manifest on every block-bearing paper write.
      preview = doc.content["preview"]
      assert preview["type"] == "paper"
      assert preview["url"] == "/papers/#{slug}"
      assert preview["title"] == "Preview Title"
      assert preview["description"] == "Lead paragraph, spelled out past the twenty-char wall."

      # Re-save with the same blocks + the same explicit labels: the manifest
      # recomputes byte-identically (same no-drift guarantee as content["body"]).
      {:ok, doc2} = Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(paper))

      assert doc2.content["preview"] == preview
    end
  end

  describe "project-on-write through upsert_document/4" do
    test "uses the row title when free blocks provide no preview title" do
      slug = "exp-row-preview-#{System.unique_integer([:positive])}"

      blocks = [
        %{
          "id" => "h",
          "type" => "heading",
          "level" => 1,
          "text" => "A visual heading that is not the canonical title"
        },
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Lead paragraph."}]
        }
      ]

      attrs = %{
        "doc_id" => slug,
        "title" => "Canonical row title",
        "content" => %{"blocks" => blocks}
      }

      {:ok, created} = Content.create_document("paper", attrs, @dataset)
      assert created.content["preview"]["title"] == "Canonical row title"

      {:ok, doc} = Content.upsert_document("paper", attrs, @dataset)

      assert doc.content["preview"]["title"] == "Canonical row title"

      {:ok, resaved} = Content.upsert_document("paper", attrs, @dataset)
      assert resaved.content["preview"] == doc.content["preview"]
    end

    test "a title-role block keeps precedence over the row-title fallback" do
      slug = "exp-role-preview-#{System.unique_integer([:positive])}"

      attrs = %{
        "doc_id" => slug,
        "title" => "Canonical row fallback",
        "content" => %{
          "blocks" => [
            %{
              "id" => "h",
              "type" => "heading",
              "level" => 1,
              "role" => "title",
              "text" => "Authored title block"
            }
          ]
        }
      }

      {:ok, doc} = Content.upsert_document("paper", attrs, @dataset)
      assert doc.content["preview"]["title"] == "Authored title block"
    end
  end

  describe "editing a bound title block via apply_paper_block_op/3" do
    test "updates content[\"title\"] and the query returns the new value" do
      slug = "exp-edit-#{System.unique_integer([:positive])}"

      blocks = [
        %{"id" => "t", "type" => "field-string", "fieldName" => "title", "value" => "Before"},
        %{
          "id" => "p",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "body"}]
        }
      ]

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
        )

      op = %{"op" => "patch-block", "id" => "t", "patch" => %{"value" => "After"}}
      {:ok, _frame} = Content.apply_paper_block_op(slug, op, @dataset)

      doc = Content.get_paper(slug, @dataset)
      assert doc.content["title"] == "After"

      # The Classic read path reflects it.
      {:ok, fetched} = Content.get_document(slug, "paper", @dataset)
      assert Envelope.render(fetched)["title"] == "After"
    end
  end

  describe "lazy synthesis (resolve_blocks_for_edit/3)" do
    test "synthesizes in memory for a legacy doc, byte-equal round-trip, no rewrite" do
      slug = "exp-legacy-#{System.unique_integer([:positive])}"

      # A LEGACY paper: HTML-only write (body_html, NO blocks). The classic
      # field values live directly under content; body is a richText string.
      {:ok, legacy} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: @dataset,
            body_html: "<p>legacy</p>"
          })
        )

      # Manually stamp classic field values to simulate a real legacy post that
      # never went through the block editor (upsert_paper with no blocks does
      # not project, so content[fieldName] is untouched — exactly the legacy
      # shape we synthesize FROM).
      legacy =
        legacy
        |> Ecto.Changeset.change(
          content:
            Map.merge(legacy.content, %{
              "slug" => slug,
              "featuredImage" => "/legacy.png",
              "body" => "Legacy prose."
            })
        )
        |> Barkpark.Repo.update!()

      refute Map.has_key?(legacy.content, "blocks")
      stored_before = legacy.content

      {blocks, synthesized?} = Content.resolve_blocks_for_edit(legacy, "paper", @dataset)
      assert synthesized?, "a doc with no content[blocks] must synthesize"

      # Byte-equal round-trip: projecting the synthesized blocks reproduces the
      # original classic field values exactly.
      projected = Projection.project(%{}, blocks)
      assert projected["title"] == legacy.title
      assert projected["slug"] == legacy.content["slug"]
      assert projected["featuredImage"] == legacy.content["featuredImage"]
      assert projected["body"]["html"] =~ "Legacy prose."

      # NO REWRITE: resolving blocks for edit must not persist anything.
      reloaded = Content.get_paper(slug, @dataset)
      assert reloaded.content == stored_before
      refute Map.has_key?(reloaded.content, "blocks")
    end

    test "returns stored blocks verbatim when content[\"blocks\"] already exists" do
      slug = "exp-stored-#{System.unique_integer([:positive])}"

      blocks = [
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "x"}]}
      ]

      {:ok, doc} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
        )

      {resolved, synthesized?} = Content.resolve_blocks_for_edit(doc, "paper", @dataset)
      refute synthesized?
      assert resolved == blocks
    end
  end
end
