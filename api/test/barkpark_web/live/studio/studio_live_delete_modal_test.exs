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

  test "a delete that fails flashes an error instead of silently navigating away",
       %{conn: conn} do
    # Regression for [studio-delete-swallows-errors]: confirm_delete's old
    # catch-all `_ ->` treated a generic {:error, _} identically to success —
    # closing the modal and navigating away with no flash, so the user believed
    # a doc was deleted when it wasn't. Force the failure by deleting the doc
    # out-of-band AFTER the editor loaded it, so the handler's own
    # delete_document call returns {:error, :not_found}.
    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/del-target"))

    _ = render_click(view, "delete-doc", %{})

    # Drop the underlying rows straight through Repo (NOT Content.delete_document,
    # whose broadcast would make the LiveView react and clear editor_doc). The
    # editor still holds the doc, so the handler's own delete re-reads and gets
    # {:error, :not_found} — the generic-error branch we're exercising.
    import Ecto.Query

    Barkpark.Repo.delete_all(
      from(d in Barkpark.Content.Document,
        where: d.doc_id in ["del-target", "drafts.del-target"] and d.dataset == @dataset
      )
    )

    html = render_click(view, "confirm-delete", %{})

    assert html =~ "Failed to delete",
           "a failed delete must surface an error flash, not pretend it succeeded"
  end
end
