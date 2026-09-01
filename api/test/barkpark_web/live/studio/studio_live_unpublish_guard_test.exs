defmodule BarkparkWeb.Studio.StudioLiveUnpublishGuardTest do
  @moduledoc """
  Coverage for the Phase-5 blast-radius unpublish guard
  (Goal `ges/graph-edge-seam`).

  Contract:
    * `handle_event("unpublish", …)` PROBES via
      `Content.Graph.reverse_referencers/2` — the arrayOf-aware inbound-edge
      query over `content_edges` — NOT the scalar-only
      `Content.find_referencing_docs/3` (which undercounts arrayOf).
    * With NO inbound referencers → the unpublish proceeds inline (no modal,
      the doc transitions to draft).
    * With inbound referencers → the guard modal opens listing each
      soon-to-dangle referencer by title + via_field; the doc stays published
      until the editor confirms.
    * `confirm-unpublish` runs the real `Content.unpublish_document`.
    * `close-unpublish-guard` cancels with no state change.

  VERIFICATION CEILING: the Cytoscape pane + bp-graph.js are LiveView/JS, not
  headlessly testable beyond these LiveViewTest assigns assertions. This test
  asserts the SERVER-SIDE guard logic (probe → reverse_referencers →
  show_unpublish_guard) — the visual graph layer is implemented but not
  headlessly verified here.
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
            %{"name" => "body", "title" => "Body", "type" => "text"},
            # A scalar reference field so a referencing post → target post edge
            # is a real materialisable content_edges row.
            %{"name" => "rel", "title" => "Related", "type" => "reference", "refType" => "post"}
          ]
        },
        @dataset
      )

    # The TARGET that gets unpublished (and referenced).
    {:ok, target_draft} =
      Content.create_document(
        @schema_name,
        %{"doc_id" => "ug-target", "title" => "Target Post", "content" => %{"body" => "t"}},
        @dataset
      )

    {:ok, _} =
      Content.publish_document(Content.published_id(target_draft.doc_id), @schema_name, @dataset)

    {:ok, conn: conn}
  end

  describe "no referencers → unpublish proceeds inline" do
    test "no modal; the document leaves the published lens", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ug-target"))

      html = render_click(view, "unpublish", %{})

      refute html =~ ~s(data-test-id="unpublish-guard-modal"),
             "expected NO guard modal when the doc has no inbound referencers"

      # The published row is gone (unpublish coalesces back to draft).
      assert {:error, _} = Content.get_document("ug-target", @schema_name, @dataset)
    end
  end

  describe "inbound referencers → guard modal" do
    setup do
      # A referencing post and a materialised inbound edge (referrer → target).
      {:ok, ref_draft} =
        Content.create_document(
          @schema_name,
          %{
            "doc_id" => "ug-referrer",
            "title" => "Referrer Post",
            "content" => %{"body" => "r", "rel" => "ug-target"}
          },
          @dataset
        )

      {:ok, _} =
        Content.publish_document(Content.published_id(ref_draft.doc_id), @schema_name, @dataset)

      # Materialise the inbound edge straight into content_edges so the probe
      # (reverse_referencers over the table) finds it. add_edge resolves the
      # slugs to documents.id UUIDs.
      {:ok, _edge} =
        Content.add_edge("ug-referrer", "ug-target", "references",
          dataset: @dataset,
          plugin_source: nil
        )

      :ok
    end

    test "the guard modal opens and lists the referencer; the doc stays published",
         %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ug-target"))

      html = render_click(view, "unpublish", %{})

      assert html =~ ~s(data-test-id="unpublish-guard-modal"),
             "expected the blast-radius guard modal when an inbound referencer exists"

      assert html =~ "Referrer Post",
             "expected the referencing doc's title in the guard modal"

      assert html =~ ~s(data-test-id="unpublish-ref")

      # The probe must NOT have unpublished yet — the doc is still published.
      assert {:ok, pub} = Content.get_document("ug-target", @schema_name, @dataset)
      assert pub.status == "published"
    end

    test "confirm-unpublish runs the real unpublish", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ug-target"))

      _ = render_click(view, "unpublish", %{})
      _ = render_click(view, "confirm-unpublish", %{})

      fetched = Content.get_document("ug-target", @schema_name, @dataset)

      assert match?({:error, _}, fetched),
             "confirm-unpublish must run the real Content.unpublish_document (#{inspect(fetched)})"
    end

    test "close-unpublish-guard cancels with the doc still published", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/ug-target"))

      _ = render_click(view, "unpublish", %{})
      html = render_click(view, "close-unpublish-guard", %{})

      refute html =~ ~s(data-test-id="unpublish-guard-modal")

      assert {:ok, pub} = Content.get_document("ug-target", @schema_name, @dataset)
      assert pub.status == "published"
    end
  end
end
