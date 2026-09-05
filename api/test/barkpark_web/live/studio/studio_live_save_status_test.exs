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

  Layer 1 is exercised at the handler seam (a direct `StudioLive.handle_event/3`,
  the `array_op` pattern) because the paper pane does not render `save_status`
  inline; layer 2 is a full `live/2` mount where the form editor's `save-status`
  span is on screen.

  spd-w19: layer 1's socket is now taken FROM a real mount rather than built by
  hand — see `paper_socket/2`.
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
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
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
      )

    paper
  end

  # A paper-pane editor socket the paper handlers accept: editor_view :paper
  # routes paper_op → paper_pane_op (NOT the Beta document_op branch), and
  # paper_block_by_id reads the block list off paper_doc.content.
  #
  # spd-w19 — taken from a REAL `live/2` mount instead of hand-built. The
  # accepted-write arm of `paper_pane_op/2` now re-derives the pane through
  # `Shared.Paper.refetch_paper/1` when it is not already in block mode, and that
  # calls `stream/3` → `attach_hook`, which reaches into `socket.private`'s
  # `:lifecycle` and into `assigns.streams`. A `%Phoenix.LiveView.Socket{}`
  # literal carries neither (`** (KeyError) key :lifecycle not found in:
  # %{live_temp: %{}}`), and papering over that with a fake `:lifecycle` would be
  # asserting against a socket LiveView never builds. The mount gives the real
  # one; the seam-level precision of this suite (a direct `handle_event/3`, no
  # DOM in the way) is unchanged.
  defp paper_view(conn, paper) do
    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{paper.doc_id}"))

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp stored_intro_text do
    case Content.get_public_paper(@slug, @dataset) do
      %{content: %{"blocks" => [%{"content" => [%{"value" => value} | _]} | _]}} -> value
      _ -> nil
    end
  end

  describe "paper block autosave truthfulness (#8)" do
    setup %{conn: conn} do
      seed_paper_schema!()
      paper = seed_block_paper!()
      view = paper_view(conn, paper)
      {:ok, paper: paper, view: view, socket: socket_of(view)}
    end

    test "a clean edit reports Auto-saved", %{socket: socket} do
      {:reply, %{saved: true}, socket} =
        StudioLive.handle_event(
          "paper-block-autosave",
          %{"block_id" => "b-intro", "text" => "Edited body."},
          socket
        )

      assert socket.assigns.save_status == "Auto-saved"
    end

    test "a FAILED edit (paper deleted behind the view) reports failure, never Auto-saved",
         %{socket: socket} do
      # Delete the row the LiveView still holds in-memory — the next persist
      # attempt hits the DB and comes back {:error, :not_found}.
      {:ok, _} = Content.delete_document(@slug, "paper", @dataset)

      {:reply, %{saved: false}, socket} =
        StudioLive.handle_event(
          "paper-block-autosave",
          %{"block_id" => "b-intro", "text" => "Edited body."},
          socket
        )

      # The pre-fix bug: an unconditional "Auto-saved" beside the red flash.
      refute socket.assigns.save_status == "Auto-saved"
      assert socket.assigns.save_status == "Save failed"
      assert socket.assigns.flash["error"] == "Edit failed"
    end

    test "paper-op replies true after persistence and false after a rejected retry", %{
      socket: socket
    } do
      op = %{
        "op" => "patch-block",
        "id" => "b-intro",
        "patch" => %{
          "content" => [%{"type" => "text", "value" => "Direct paper op."}]
        }
      }

      assert {:reply, %{saved: true}, saved_socket} =
               StudioLive.handle_event("paper-op", op, socket)

      assert saved_socket.assigns.last_paper_save_ok? == true
      assert stored_intro_text() == "Direct paper op."

      {:ok, _} = Content.delete_document(@slug, "paper", @dataset)

      assert {:reply, %{saved: false}, failed_socket} =
               StudioLive.handle_event("paper-op", op, saved_socket)

      assert failed_socket.assigns.last_paper_save_ok? == false
      assert failed_socket.assigns.save_status == "Save failed"
      assert stored_intro_text() == nil
    end

    test "paper-op and paper-block-autosave reject malformed payloads with saved false", %{
      socket: socket
    } do
      assert {:reply, %{saved: false}, _socket} =
               StudioLive.handle_event("paper-op", %{}, socket)

      assert {:reply, %{saved: false}, _socket} =
               StudioLive.handle_event("paper-block-autosave", %{}, socket)

      assert stored_intro_text() == "Original body."
    end

    test "a correlated component save persists and acknowledges its exact request", %{
      view: view
    } do
      send(view.pid, {
        :paper_op,
        %{
          "op" => "patch-block",
          "id" => "b-intro",
          "patch" => %{
            "content" => [%{"type" => "text", "value" => "Correlated Studio edit."}]
          }
        },
        "studio-field-accepted"
      })

      assert_push_event(view, "bp:paper-field-save-result", %{
        request_id: "studio-field-accepted",
        saved: true
      })

      assert stored_intro_text() == "Correlated Studio edit."
      assert socket_of(view).assigns.last_paper_save_ok? == true
    end

    test "a failed correlated component save acknowledges false and keeps the row absent", %{
      view: view
    } do
      {:ok, _} = Content.delete_document(@slug, "paper", @dataset)

      send(view.pid, {
        :paper_op,
        %{
          "op" => "patch-block",
          "id" => "b-intro",
          "patch" => %{
            "content" => [%{"type" => "text", "value" => "Must not land."}]
          }
        },
        "studio-field-failed"
      })

      assert_push_event(view, "bp:paper-field-save-result", %{
        request_id: "studio-field-failed",
        saved: false
      })

      assert stored_intro_text() == nil
      assert socket_of(view).assigns.last_paper_save_ok? == false
    end

    test "paper-ops replies saved true only after the batch persisted", %{socket: socket} do
      assert {:reply, %{saved: true}, socket} =
               StudioLive.handle_event(
                 "paper-ops",
                 %{
                   "ops" => [
                     %{
                       "op" => "patch-block",
                       "id" => "b-intro",
                       "patch" => %{
                         "content" => [
                           %{"type" => "text", "value" => "Acknowledged Studio batch."}
                         ]
                       }
                     }
                   ]
                 },
                 socket
               )

      assert socket.assigns.last_paper_save_ok? == true
      assert stored_intro_text() == "Acknowledged Studio batch."
    end

    test "paper-ops replies saved false for a rejected batch, never stale success", %{
      socket: socket
    } do
      # Prove the attempt resets its own result rather than inheriting a prior
      # successful status from this socket.
      socket = Phoenix.Component.assign(socket, :last_paper_save_ok?, true)
      {:ok, _} = Content.delete_document(@slug, "paper", @dataset)

      assert {:reply, %{saved: false}, socket} =
               StudioLive.handle_event(
                 "paper-ops",
                 %{
                   "ops" => [
                     %{
                       "op" => "patch-block",
                       "id" => "b-intro",
                       "patch" => %{
                         "content" => [
                           %{"type" => "text", "value" => "Rejected Studio batch."}
                         ]
                       }
                     }
                   ]
                 },
                 socket
               )

      assert socket.assigns.last_paper_save_ok? == false
      assert socket.assigns.save_status == "Save failed"
      assert stored_intro_text() == nil
    end

    test "paper-ops rejects malformed or empty payloads with saved false", %{socket: socket} do
      assert {:reply, %{saved: false}, _socket} =
               StudioLive.handle_event("paper-ops", %{"ops" => []}, socket)

      assert {:reply, %{saved: false}, _socket} =
               StudioLive.handle_event("paper-ops", %{}, socket)

      assert stored_intro_text() == "Original body."
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

      assert html_a =~ ~s(class="save-status" role="status" aria-live="polite">Saved)

      # Navigate the editor to doc B (same LiveView, push_patch — no remount).
      html_b = render_patch(view, scoped_studio("/d/#{@dataset}/studio/page/about"))

      # Doc B must NOT inherit doc A's "Saved" — the status resets to blank.
      refute html_b =~ ~s(class="save-status" role="status" aria-live="polite">Saved)
      assert html_b =~ ~s(class="save-status" role="status" aria-live="polite"><)
    end
  end

  describe "save-status span announces to screen readers (a11y live region)" do
    setup %{conn: conn} do
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
        Content.create_document(
          "post",
          %{"doc_id" => "p1", "title" => "Post One", "content" => %{"body" => "aaa"}},
          @dataset
        )

      {:ok, conn: conn}
    end

    # The status text is what changes; screen readers only voice it if the
    # span is a polite live region. This asserts the live-region attrs travel
    # with the save-status span (RED before role/aria-live were added).
    test "the save-status span is a polite live region", %{conn: conn} do
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))
      assert html =~ ~s(id="editor-form")

      html_saved =
        render_hook(view, "autosave", %{"doc" => %{"title" => "Post One", "body" => "aaa-x"}})

      assert html_saved =~ ~s(<span class="save-status" role="status" aria-live="polite">Saved)
    end
  end

  describe "studio_flash sink announces to screen readers (nav.ex live regions)" do
    # nav.ex studio_flash is the single LAYOUT flash sink rendered by BOTH
    # studio.html.heex and app.html.heex, so these live-region attrs upgrade
    # every layout-rendered Studio flash. No aria assertion existed for it
    # before this slice.
    test "an :info flash is a polite status region" do
      html =
        render_component(&BarkparkWeb.StudioComponents.Nav.studio_flash/1,
          flash: %{"info" => "Saved your changes"}
        )

      assert html =~ ~s(class="flash flash-info")
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      assert html =~ "Saved your changes"
    end

    test "an :error flash is an assertive alert region" do
      html =
        render_component(&BarkparkWeb.StudioComponents.Nav.studio_flash/1,
          flash: %{"error" => "Something broke"}
        )

      assert html =~ ~s(class="flash flash-error")
      assert html =~ ~s(role="alert")
      assert html =~ ~s(aria-live="assertive")
      assert html =~ "Something broke"
    end
  end
end
