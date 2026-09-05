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
  alias BarkparkWeb.Studio.StudioLive.DocActions

  @dataset "production"
  @admin_token "doc-actions-admin"

  # `bulk-publish` / `bulk-unpublish` are ADMIN-tier Caps events
  # (arpss-schema-action-write-tier-ruling), and the :admin tier is enforced on
  # EVERY Studio socket including the anonymous public-demo one. This suite is
  # about the ACTION, not the gate, so it mounts an admin principal.
  defp admin_conn(conn) do
    {:ok, _} =
      Barkpark.Auth.create_token(@admin_token, "doc actions admin", @dataset, [
        "read",
        "write",
        "admin"
      ])

    Plug.Test.init_test_session(conn, %{"api_token" => @admin_token})
  end

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
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

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
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))
      assert html =~ ~s(phx-click="duplicate-doc")
      assert html =~ ~s(data-test-id="duplicate-doc")
    end
  end

  describe "E2: Open in new pane" do
    test "open-secondary-picker shows the modal with candidates", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

      html = render_click(view, "open-secondary-picker", %{})

      assert html =~ ~s(data-test-id="secondary-picker-modal")
      # The current doc is excluded from candidates; the other two appear.
      assert html =~ "Second"
      assert html =~ "Third"
      refute html =~ ~s(data-test-id="secondary-candidate-p1")
    end

    test "select-secondary loads a read-only card and closes the picker", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

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
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

      _ = render_click(view, "open-secondary-picker", %{})
      _ = render_click(view, "select-secondary", %{"id" => "p2"})
      html = render_click(view, "close-secondary", %{})

      refute html =~ ~s(data-test-id="secondary-pane")
    end
  end

  describe "E3: Bulk publish" do
    test "toggle-doc-checkbox flips bulk-action-bar visibility", %{conn: conn} do
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))

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
      {:ok, view, _html} = live(admin_conn(conn), scoped_studio("/d/#{@dataset}/studio/post"))

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
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))

      _ = render_click(view, "toggle-doc-checkbox", %{"id" => "p1"})
      _ = render_click(view, "toggle-doc-checkbox", %{"id" => "p2"})
      html = render_click(view, "bulk-clear", %{})

      refute html =~ ~s(data-test-id="bulk-action-bar")
    end
  end

  describe "E4: default_doc_actions ordering (misclick safety)" do
    # sup-w5-doc-actions-order — the destructive Delete used to sit at index 1,
    # wedged between History and the Publish CTA, right in the misclick zone.
    # It must now trail the whole benign list so a stray click near Publish
    # can't destroy the doc. This asserts the base order directly off
    # `DocActions.default_doc_actions/2` (no LiveView mount needed) so the
    # ordering contract is protected independent of render.
    defp draft_action_names do
      assigns = %{
        editor_doc: %{doc_id: "p1"},
        editor_schema: nil,
        editor_is_draft: true,
        published_doc: nil,
        content_preview_visible: false,
        content_preview_rendered: nil,
        diff_visible: false
      }

      assigns
      |> DocActions.default_doc_actions(%{})
      |> Enum.map(&Map.get(&1, "name"))
    end

    test "Publish leads and Delete trails — Publish index < Delete index" do
      names = draft_action_names()

      publish_idx = Enum.find_index(names, &(&1 == "publish"))
      delete_idx = Enum.find_index(names, &(&1 == "delete-doc"))

      assert publish_idx != nil, "expected a publish action for a draft doc"
      assert delete_idx != nil, "expected a delete-doc action"

      assert publish_idx < delete_idx,
             "Publish (##{publish_idx}) must precede Delete (##{delete_idx}); " <>
               "order was #{inspect(names)}"
    end

    test "Publish is the first action and Delete is the last benign-list action" do
      names = draft_action_names()

      assert List.first(names) == "publish",
             "Publish must lead the overflow menu; order was #{inspect(names)}"

      # Delete trails every built-in action (schema actions, if any, append
      # after — there are none for this nil-schema fixture).
      assert List.last(names) == "delete-doc",
             "Delete must be held to the tail; order was #{inspect(names)}"
    end
  end

  describe "a schema-declared action whose icon names no glyph" do
    # `icon/1` RAISES on an unknown name in :test — that is the icons tripwire's
    # teeth, and it is right for a name a developer wrote down. A plugin's or a
    # workspace schema's icon string is not that: it is unbounded data from
    # outside the tree, so `drawable_icon/1` guards it at the call site. Without
    # that guard any workspace could crash its own editor by typing a glyph name
    # we happen not to carry.
    setup do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Post",
            "icon" => "file-text",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "body", "title" => "Body", "type" => "text"}
            ],
            "actions" => [
              %{
                "name" => "ghost-glyph",
                "label" => "Ghost Glyph",
                "kind" => "event",
                "opts" => %{"event" => "ghost-glyph", "icon" => "definitely-not-a-glyph"}
              }
            ]
          },
          @dataset
        )

      :ok
    end

    test "renders the editor instead of crashing, and falls back to the label", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

      # The action is present and usable...
      assert html =~ "Ghost Glyph"
      # ...and the unknown name never reached icon/1, so no <svg> was drawn for
      # it and, critically, the render did not raise.
      refute html =~ "definitely-not-a-glyph"
    end
  end
end
