defmodule BarkparkWeb.Studio.StudioLiveDiscardDraftTest do
  @moduledoc """
  Coverage for the "Discard draft" action added in the studio parity gap.

  Contract:
    * The "Discard draft" button appears ONLY when the editor is on a draft
      that has a published twin (has_published_twin == true).
    * The button is NOT present when editing a draft that has NO published
      twin (new document, never published).
    * Confirming the discard removes the draft row; the published doc remains.
    * On success the editor navigates to the published doc and shows a flash.
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

    # Create a published document (create → publish)
    {:ok, draft} =
      Content.create_document(
        @schema_name,
        %{"doc_id" => "dd-p1", "title" => "Has Twin", "content" => %{"body" => "original"}},
        @dataset
      )

    {:ok, _published} =
      Content.publish_document(
        Content.published_id(draft.doc_id),
        @schema_name,
        @dataset
      )

    # After publish the draft is gone — unpublish creates a new draft twin
    # so we can test the "has published twin" path.  Alternatively, create a
    # new draft by updating the document so both rows co-exist.  The simplest
    # way that matches real usage: create an extra draft by calling
    # create_document with the draft ID directly.
    {:ok, _new_draft} =
      Content.create_document(
        @schema_name,
        %{
          "doc_id" => Content.draft_id("dd-p1"),
          "title" => "Has Twin (draft)",
          "content" => %{"body" => "edited"}
        },
        @dataset
      )

    # Create a draft-only document (never published).
    {:ok, _draft_only} =
      Content.create_document(
        @schema_name,
        %{"doc_id" => "dd-p2", "title" => "No Twin", "content" => %{"body" => "new"}},
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "discard draft button visibility" do
    test "button present when draft has a published twin", %{conn: conn} do
      # Open the draft (drafts. prefix → editor sees is_draft=true)
      {:ok, _view, html} =
        live(
          conn,
          scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/#{Content.draft_id("dd-p1")}")
        )

      assert html =~ ~s(data-test-id="discard-draft"),
             "expected discard-draft button when draft has a published twin"
    end

    test "button absent when draft has NO published twin", %{conn: conn} do
      {:ok, _view, html} =
        live(
          conn,
          scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/#{Content.draft_id("dd-p2")}")
        )

      refute html =~ ~s(data-test-id="discard-draft"),
             "expected no discard-draft button for a draft-only document"
    end
  end

  describe "confirm-discard" do
    test "removes the draft and keeps the published doc", %{conn: conn} do
      {:ok, view, _html} =
        live(
          conn,
          scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/#{Content.draft_id("dd-p1")}")
        )

      # Open the modal
      html = render_click(view, "discard-draft", %{})
      assert html =~ ~s(data-test-id="discard-draft-modal")

      # Confirm
      _html = render_click(view, "confirm-discard", %{})

      # Draft row must be gone
      assert {:error, _} = Content.get_document(Content.draft_id("dd-p1"), @schema_name, @dataset)

      # Published twin must survive
      assert {:ok, pub} = Content.get_document("dd-p1", @schema_name, @dataset)
      assert pub.status == "published"
    end

    test "flash confirms success after discard", %{conn: conn} do
      {:ok, view, _html} =
        live(
          conn,
          scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/#{Content.draft_id("dd-p1")}")
        )

      _ = render_click(view, "discard-draft", %{})
      html = render_click(view, "confirm-discard", %{})

      assert html =~ "Draft discarded"
    end

    test "close-discard cancels without removing the draft", %{conn: conn} do
      {:ok, view, _html} =
        live(
          conn,
          scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/#{Content.draft_id("dd-p1")}")
        )

      _ = render_click(view, "discard-draft", %{})
      html = render_click(view, "close-discard", %{})

      # Modal closed
      refute html =~ ~s(data-test-id="discard-draft-modal")

      # Draft still exists
      assert {:ok, _draft} =
               Content.get_document(Content.draft_id("dd-p1"), @schema_name, @dataset)
    end
  end
end
