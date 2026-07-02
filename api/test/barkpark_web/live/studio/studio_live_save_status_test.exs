defmodule BarkparkWeb.Studio.StudioLiveSaveStatusTest do
  @moduledoc """
  Save-status TRUTHFULNESS on the Studio editor header (merges findings #8+#9).

  Two invariants the indicator must uphold:

    1. A paper block edit reports the status of what ACTUALLY persisted. A
       failed `paper-block-autosave` (the paper row deleted behind the
       LiveView's back) must NOT claim "Auto-saved" — it emits an "Edit failed"
       flash AND a "Save failed" status, never a green success beside a red
       flash. A clean edit still reports "Auto-saved" (the shared
       `paper_pane_op` seam now owns the status, not the handler).

    2. `save_status` does not leak across a document switch. After a doc's
       header shows "Saved", navigating the editor to a DIFFERENT doc must
       reset the header to blank (the pane rebuild gates the carry on doc
       identity, exactly like `editor_mode`).

  Layer 1 is exercised at the handler seam (a hand-built socket + a direct
  `StudioLive.handle_event/3`, the `array_op` pattern) because the paper pane
  does not render `save_status` inline; layer 2 is a full `live/2` mount where
  the form editor's `save-status` span is on screen.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive

  @dataset "production"
  @slug "2026-07-02-save-status-paper"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  defp seed_block_paper! do
    {:ok, paper} =
      Content.upsert_paper(%{
        slug: @slug,
        dataset: @dataset,
        blocks: [
          %{
            "id" => "b-intro",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Original body."}]
          }
        ]
      })

    paper
  end

  # A paper-pane editor socket the paper handlers accept: editor_view :paper
  # routes paper_op → paper_pane_op (NOT the Beta document_op branch), and
  # paper_block_by_id reads the block list off paper_doc.content.
  defp paper_socket(paper) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        editor_view: :paper,
        editor_mode: :classic,
        editor_doc: nil,
        paper_doc: paper,
        dataset: @dataset,
        save_status: ""
      }
    }
  end

  describe "paper block autosave truthfulness (#8)" do
    setup do
      seed_paper_schema!()
      paper = seed_block_paper!()
      {:ok, paper: paper}
    end

    test "a clean edit reports Auto-saved", %{paper: paper} do
      {:noreply, socket} =
        StudioLive.handle_event(
          "paper-block-autosave",
          %{"block_id" => "b-intro", "text" => "Edited body."},
          paper_socket(paper)
        )

      assert socket.assigns.save_status == "Auto-saved"
    end

    test "a FAILED edit (paper deleted behind the view) reports failure, never Auto-saved",
         %{paper: paper} do
      # Delete the row the LiveView still holds in-memory — the next persist
      # attempt hits the DB and comes back {:error, :not_found}.
      {:ok, _} = Content.delete_document(@slug, "paper", @dataset)

      {:noreply, socket} =
        StudioLive.handle_event(
          "paper-block-autosave",
          %{"block_id" => "b-intro", "text" => "Edited body."},
          paper_socket(paper)
        )

      # The pre-fix bug: an unconditional "Auto-saved" beside the red flash.
      refute socket.assigns.save_status == "Auto-saved"
      assert socket.assigns.save_status == "Save failed"
      assert socket.assigns.flash["error"] == "Edit failed"
    end
  end

  describe "save_status does not leak across a document switch (#9)" do
    setup %{conn: conn} do
      # A `post` schema with an Expectation layout (create_document's scaffold
      # gate) + a plain `page` — the two form-editor doc types the editor tests
      # rely on to route through the Structure desk.
      {:ok, _} =
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
            "layout" => [
              %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
              %{"kind" => "region", "name" => "body"}
            ]
          },
          @dataset
        )

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "page",
            "title" => "Page",
            "icon" => "file",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "body", "title" => "Body", "type" => "text"}
            ]
          },
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "p1", "title" => "Post One", "content" => %{"body" => "aaa"}},
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "page",
          %{"doc_id" => "about", "title" => "About", "content" => %{"body" => "bbb"}},
          @dataset
        )

      {:ok, conn: conn}
    end

    test "navigating from a saved doc to another doc blanks the header status", %{conn: conn} do
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))
      assert html =~ ~s(id="editor-form")

      # Autosave doc A → the header reports "Saved".
      html_a =
        render_hook(view, "autosave", %{"doc" => %{"title" => "Post One", "body" => "aaa-edited"}})

      assert html_a =~ ~s(class="save-status">Saved)

      # Navigate the editor to doc B (same LiveView, push_patch — no remount).
      html_b = render_patch(view, scoped_studio("/d/#{@dataset}/studio/page/about"))

      # Doc B must NOT inherit doc A's "Saved" — the status resets to blank.
      refute html_b =~ ~s(class="save-status">Saved)
      assert html_b =~ ~s(class="save-status"><)
    end
  end
end
