defmodule BarkparkWeb.Studio.StudioLiveDeleteModalTest do
  @moduledoc """
  Regression for the delete-with-reference-check modal
  (`Handlers.Delete.delete_doc`).

  Contract: the modal previews the documents that reference the doc about to be
  deleted. It must PROBE via `Content.Graph.reverse_referencers/2` — the
  arrayOf-aware inbound-edge query over `content_edges` — NOT the scalar-only
  `Content.find_referencing_docs/3`, which undercounts `arrayOf`-of-`reference`
  referencers. The pre-fix scalar scan made the editor see FEWER affected
  documents than the disconnect/delete actually touches. (Same source the
  unpublish guard already uses — this brings the delete path into agreement.)
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @schema_name "post"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @schema_name,
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _target} =
      Content.create_document(
        @schema_name,
        %{"doc_id" => "del-target", "title" => "Target Post", "content" => %{"body" => "t"}},
        @dataset
      )

    {:ok, conn: conn}
  end

  test "delete modal lists an inbound referencer that lives only in content_edges (arrayOf-aware probe)",
       %{conn: conn} do
    # A referencer whose link to the target lives ONLY as a content_edges row —
    # the shape a materialised `arrayOf`-of-`reference` edge takes, with no
    # scalar `reference` content field. The old scalar-scan probe
    # (`find_referencing_docs`) cannot see this; `reverse_referencers` (over
    # `content_edges`) can. Pre-fix this test fails — the modal lists nothing.
    {:ok, ref_draft} =
      Content.create_document(
        @schema_name,
        %{"doc_id" => "del-referrer", "title" => "Referrer Post", "content" => %{"body" => "r"}},
        @dataset
      )

    {:ok, _} =
      Content.publish_document(Content.published_id(ref_draft.doc_id), @schema_name, @dataset)

    # Materialise the inbound edge straight into content_edges (add_edge resolves
    # the slugs to documents.id UUIDs) — exactly what the edge projector writes
    # for an arrayOf reference, and exactly what the scalar field scan misses.
    {:ok, _edge} =
      Content.add_edge("del-referrer", "del-target", "references",
        dataset: @dataset,
        plugin_source: nil
      )

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/del-target"))

    html = render_click(view, "delete-doc", %{})

    assert html =~ "delete-modal", "expected the delete-with-reference-check modal to open"

    assert html =~ "Referrer Post",
           "delete modal must list the inbound referencer surfaced by the arrayOf-aware " <>
             "reverse_referencers probe — the old scalar find_referencing_docs undercounted it"
  end
end
