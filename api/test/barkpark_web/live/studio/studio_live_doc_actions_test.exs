defmodule BarkparkWeb.Studio.StudioLiveDocActionsTest do
  @moduledoc """
  Coverage for the three Sanity-style document actions wired in
  Task barkpark-3yq:

    * E1 Duplicate — `duplicate-doc` event clones the editor's open
      doc to a fresh draft and patches nav into it.
    * E2 Open in new pane — `open-secondary-picker`, `select-secondary`,
      `close-secondary` toggle the read-only secondary editor card.
    * E3 Bulk publish — `toggle-doc-checkbox` flips a MapSet selection,
      `bulk-publish` / `bulk-unpublish` run the action across the set.

  Mounts a real LiveView against the seeded `post` type so the full
  Structure → pane builder → editor pipeline is exercised. Events are
  dispatched via `Phoenix.LiveViewTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _post_schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
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

    {:ok, _p1} =
      Content.create_document(
        "post",
        %{"doc_id" => "p1", "title" => "First", "content" => %{"body" => "one"}},
        @dataset
      )

    {:ok, _p2} =
      Content.create_document(
        "post",
        %{"doc_id" => "p2", "title" => "Second", "content" => %{"body" => "two"}},
        @dataset
      )

    {:ok, _p3} =
      Content.create_document(
        "post",
        %{"doc_id" => "p3", "title" => "Third", "content" => %{"body" => "three"}},
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "E1: Duplicate" do
    test "duplicate-doc clones the open doc into a fresh draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}/post/p1"))

      pre_count = length(Content.list_documents("post", @dataset))

      # Fire the duplicate event; the LV redirects to the new doc.
      _html = render_click(view, "duplicate-doc", %{})

      post_count = length(Content.list_documents("post", @dataset))
      assert post_count == pre_count + 1

      # Confirm the cloned title carries the (copy) suffix.
      drafts = Content.list_documents("post", @dataset, perspective: :drafts)
      assert Enum.any?(drafts, fn d -> d.title == "First (copy)" end)
    end

    test "duplicate button is rendered in the editor header", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/studio/#{@dataset}/post/p1"))
      assert html =~ ~s(phx-click="duplicate-doc")
      assert html =~ ~s(data-test-id="duplicate-doc")
    end
  end

  describe "E2: Open in new pane" do
    test "open-secondary-picker shows the modal with candidates", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}/post/p1"))

      html = render_click(view, "open-secondary-picker", %{})

      assert html =~ ~s(data-test-id="secondary-picker-modal")
      # The current doc is excluded from candidates; the other two appear.
      assert html =~ "Second"
      assert html =~ "Third"
      refute html =~ ~s(data-test-id="secondary-candidate-p1")
    end

    test "select-secondary loads a read-only card and closes the picker", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}/post/p1"))

      _ = render_click(view, "open-secondary-picker", %{})
      html = render_click(view, "select-secondary", %{"id" => "p2"})

      assert html =~ ~s(data-test-id="secondary-pane")
      # body field surfaces in the read-only k/v table
      assert html =~ "two"
      # picker modal closed
      refute html =~ ~s(data-test-id="secondary-picker-modal")
      # close button present
      assert html =~ ~s(data-test-id="close-secondary")
    end

    test "close-secondary clears the card", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}/post/p1"))

      _ = render_click(view, "open-secondary-picker", %{})
      _ = render_click(view, "select-secondary", %{"id" => "p2"})
      html = render_click(view, "close-secondary", %{})

      refute html =~ ~s(data-test-id="secondary-pane")
    end
  end

  describe "E3: Bulk publish" do
    test "toggle-doc-checkbox flips bulk-action-bar visibility", %{conn: conn} do
      {:ok, view, html} = live(conn, scoped_studio("/studio/#{@dataset}/post"))

      refute html =~ ~s(data-test-id="bulk-action-bar")

      html = render_click(view, "toggle-doc-checkbox", %{"id" => "p1"})
      assert html =~ ~s(data-test-id="bulk-action-bar")
      assert html =~ "1 selected"

      html = render_click(view, "toggle-doc-checkbox", %{"id" => "p2"})
      assert html =~ "2 selected"

      # Toggle p1 off
      html = render_click(view, "toggle-doc-checkbox", %{"id" => "p1"})
      assert html =~ "1 selected"
    end

    test "bulk-publish publishes every selected draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}/post"))

      _ = render_click(view, "toggle-doc-checkbox", %{"id" => "p1"})
      _ = render_click(view, "toggle-doc-checkbox", %{"id" => "p2"})
      _ = render_click(view, "bulk-publish", %{})

      # Both p1 and p2 should now have a published row (drafts deleted).
      assert {:ok, %{doc_id: "p1", status: "published"}} =
               Content.get_document("p1", "post", @dataset)

      assert {:ok, %{doc_id: "p2", status: "published"}} =
               Content.get_document("p2", "post", @dataset)
    end

    test "bulk-clear empties the selection set", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/studio/#{@dataset}/post"))

      _ = render_click(view, "toggle-doc-checkbox", %{"id" => "p1"})
      _ = render_click(view, "toggle-doc-checkbox", %{"id" => "p2"})
      html = render_click(view, "bulk-clear", %{})

      refute html =~ ~s(data-test-id="bulk-action-bar")
    end
  end
end
