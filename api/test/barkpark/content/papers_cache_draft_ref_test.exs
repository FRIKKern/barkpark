defmodule Barkpark.Content.PapersCacheDraftRefTest do
  @moduledoc """
  pbw-backlog-cache-draft-ref-leak — the PERSISTED body_html cache resolves
  `field-reference` titles under the PUBLISHED principal.

  The live anonymous reader was sealed first (`BulldocsLive.reader_resolvers/3`
  threads `published_only: true`, pinned by bulldocs_live_test's
  "a field-reference to a DRAFT-ONLY doc still renders the raw value"). The
  CACHE was not: `Labels.render_opts/2` forwarded the writer's scope verbatim
  into `Labels.reference_title/4`, and the writer's scope carries no
  `published_only`. So a privileged author saving a paper that references a
  draft-only doc baked that doc's DRAFT TITLE into `content["body_html"]` —
  the exact string the public web reader injects into `.bp-paper-surface`
  (web/components/document-detail.tsx) and the share-link static page serves.
  A title visible only in a draft crossed principals through a durable
  artifact, on a surface the live reader refuses to render.

  METHOD: every assertion is on STATE — the reloaded paper row's stored
  content, not a rendered response — so nothing here can pass by re-rendering
  the blocks under a different principal than the one that wrote the cache.

  The positive control is not decoration: with the gate applied to BOTH
  targets, a test that only refuted the draft title would also pass if
  reference resolution were simply broken. The published reference must still
  resolve its title in the same cached bytes.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Papers

  @draft_id "pbw-cache-draft-target"
  @pub_id "pbw-cache-published-target"
  @draft_title "Secret Draft Title"
  @pub_title "Published Target Title"

  setup do
    {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    dataset = Content.paper_default_dataset()

    # NEVER published — only the `drafts.` twin exists.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => @draft_id, "title" => @draft_title},
        dataset,
        workspace_id: ws.id
      )

    # The positive control: created AND published.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => @pub_id, "title" => @pub_title},
        dataset,
        workspace_id: ws.id
      )

    {:ok, _} = Content.publish_document(@pub_id, "post", dataset, workspace_id: ws.id)

    %{ws: ws, dataset: dataset}
  end

  defp paper_attrs(slug) do
    Barkpark.LabelFixtures.paper_attrs(%{
      slug: slug,
      style: "article",
      blocks: [
        %{"type" => "heading", "role" => "title", "text" => "Cache Reference Host"},
        %{"type" => "paragraph", "text" => "Body copy to clear the hollow gate."},
        %{
          "id" => "the-draft-ref",
          "type" => "field-reference",
          "label" => "Draft related",
          "value" => @draft_id
        },
        %{
          "id" => "the-published-ref",
          "type" => "field-reference",
          "label" => "Published related",
          "value" => @pub_id
        }
      ]
    })
  end

  describe "body_html cache / field-reference resolution principal" do
    test "a draft-only referenced title never lands in the cached published projection",
         %{ws: ws, dataset: dataset} do
      slug = "pbw-cache-draft-ref-paper"
      {:ok, _} = Content.upsert_paper(paper_attrs(slug))

      paper = Papers.get_paper(slug, dataset, workspace_id: ws.id)
      refute is_nil(paper), "the paper row must exist for this to measure anything"

      content = paper.content || %{}
      body_html = Map.get(content, "body_html")

      assert is_binary(body_html) and body_html != "",
             "the write path must have rendered a body_html cache"

      # THE LEAK: a title that exists only on a `drafts.` row must not be
      # readable from the durable public projection.
      refute body_html =~ @draft_title
      # …and the reference degrades to its raw id, exactly as the live reader
      # renders it (bulldocs_live_test's draft-only case).
      assert body_html =~ @draft_id

      # POSITIVE CONTROL — resolution itself still works in the same bytes.
      assert body_html =~ @pub_title
    end

    test "the projected content[\"body\"][\"html\"] applies the same principal",
         %{ws: ws, dataset: dataset} do
      slug = "pbw-cache-draft-ref-projection"
      {:ok, _} = Content.upsert_paper(paper_attrs(slug))

      paper = Papers.get_paper(slug, dataset, workspace_id: ws.id)
      projected = get_in(paper.content || %{}, ["body", "html"])

      assert is_binary(projected) and projected != "",
             "the projection must have written content[\"body\"][\"html\"]"

      refute projected =~ @draft_title
      assert projected =~ @draft_id
      assert projected =~ @pub_title
    end
  end
end
