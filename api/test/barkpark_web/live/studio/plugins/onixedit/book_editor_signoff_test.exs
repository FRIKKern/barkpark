defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookEditorSignoffTest do
  @moduledoc """
  Phase 8 WI3 — sign-off gate visualization tests.

  Covers the three gating behaviors the editor adds once Bokbasen has
  accepted a submission (`bp_status.signed_off == true`):

    * Sign-off badge in the toolbar (truncated submission id, copy link).
    * Re-publish (UPDATE) button — hidden when clean, shown when the form
      has been edited since acceptance, click → modal → confirm enqueues
      `PublishWorker` with `notificationType=04` persisted.
    * Edit-warning modal — explicit Save events on a signed-off doc
      surface a confirm modal before persisting; dismiss leaves disk
      untouched, confirm persists and suppresses the warning for the rest
      of the session.

  Setup mirrors the WI5 describe block in `book_editor_test.exs` (private
  schema, single-doc seed). The signed-off fixture seeds the
  `bp_export_status` composite directly with `signed_off=true` so the
  derived flag in `Status.read/1` returns the expected shape without
  requiring a real Bokbasen round-trip.
  """

  use BarkparkWeb.ConnCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker

  @dataset "production"
  @signed_doc_id "book-signed"
  @unsigned_doc_id "book-unsigned"

  @signed_status %{
    "state" => "accepted",
    "submission_id" => "sub_abc12345xyz",
    "accepted_at" => "2026-04-30T10:00:00Z",
    "signed_off" => true
  }

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book (ONIX 3.0)",
          "icon" => "book",
          "visibility" => "private",
          "fields" => [
            %{"name" => "notificationType", "title" => "Notification type", "type" => "string"},
            %{
              "name" => "bp_export_status",
              "title" => "Export status",
              "type" => "composite",
              "fields" => [%{"name" => "state", "type" => "string"}]
            }
          ]
        },
        @dataset
      )

    {:ok, _signed} =
      Content.create_document(
        "book",
        %{
          "doc_id" => @signed_doc_id,
          "title" => "Signed Book",
          "content" => %{"bp_export_status" => @signed_status}
        },
        @dataset
      )

    {:ok, _unsigned} =
      Content.create_document(
        "book",
        %{
          "doc_id" => @unsigned_doc_id,
          "title" => "Unsigned Book",
          "content" => %{}
        },
        @dataset
      )

    {:ok, conn: conn}
  end

  defp open_signed(conn) do
    live(conn, "/studio/#{@dataset}/onixedit/book/#{@signed_doc_id}")
  end

  defp open_unsigned(conn) do
    live(conn, "/studio/#{@dataset}/onixedit/book/#{@unsigned_doc_id}")
  end

  describe "sign-off badge" do
    test "renders when signed_off=true with truncated submission id and tooltip", %{conn: conn} do
      {:ok, view, html} = open_signed(conn)

      assert has_element?(view, ~s|[data-test-id="bokbasen-signoff-badge"]|)
      assert has_element?(view, ~s|[data-test-id="bokbasen-signoff-submission-id"]|, "sub_abc1…")
      assert has_element?(view, ~s|[data-test-id="bokbasen-signoff-copy"]|)
      # Tooltip surfaces accepted_at + full submission id (read off `title=`).
      assert html =~ "2026-04-30T10:00:00Z"
      assert html =~ "sub_abc12345xyz"
    end

    test "absent when signed_off=false (no bp_export_status)", %{conn: conn} do
      {:ok, view, _html} = open_unsigned(conn)
      refute has_element?(view, ~s|[data-test-id="bokbasen-signoff-badge"]|)
    end

    test "copy link carries full submission id in data-clipboard-text", %{conn: conn} do
      {:ok, _view, html} = open_signed(conn)
      assert html =~ ~s|data-clipboard-text="sub_abc12345xyz"|
    end
  end

  describe "re-publish button + modal" do
    test "hidden on a clean signed-off doc", %{conn: conn} do
      {:ok, view, _html} = open_signed(conn)
      refute has_element?(view, ~s|[data-test-id="bokbasen-republish-button"]|)
    end

    test "appears after a form edit (autosave dirties the gate)", %{conn: conn} do
      {:ok, view, _html} = open_signed(conn)

      view
      |> form("#book-editor-form", %{"doc" => %{"notificationType" => "03"}})
      |> render_change()

      assert has_element?(view, ~s|[data-test-id="bokbasen-republish-button"]|)
    end

    test "click opens the modal; cancel closes it without enqueueing", %{conn: conn} do
      {:ok, view, _html} = open_signed(conn)

      view
      |> form("#book-editor-form", %{"doc" => %{"notificationType" => "03"}})
      |> render_change()

      view |> element(~s|[data-test-id="bokbasen-republish-button"]|) |> render_click()
      assert has_element?(view, ~s|[data-test-id="republish-modal"]|)

      view |> element(~s|[data-test-id="republish-modal-cancel"]|) |> render_click()
      refute has_element?(view, ~s|[data-test-id="republish-modal"]|)

      refute_enqueued(worker: PublishWorker)
    end

    test "confirm persists notificationType=04 and enqueues PublishWorker", %{conn: conn} do
      {:ok, view, _html} = open_signed(conn)

      view
      |> form("#book-editor-form", %{"doc" => %{"notificationType" => "03"}})
      |> render_change()

      view |> element(~s|[data-test-id="bokbasen-republish-button"]|) |> render_click()
      view |> element(~s|[data-test-id="republish-modal-confirm"]|) |> render_click()

      # Newly-created docs land as drafts — the worker is enqueued against the
      # draft id and notificationType=04 is persisted on the draft content.
      draft_id = "drafts.#{@signed_doc_id}"

      assert_enqueued(
        worker: PublishWorker,
        args: %{"document_id" => draft_id, "type" => "book", "dataset" => @dataset}
      )

      {:ok, doc} = Content.get_document(draft_id, "book", @dataset)
      assert doc.content["notificationType"] == "04"

      # Modal closes after confirm.
      refute has_element?(view, ~s|[data-test-id="republish-modal"]|)
    end
  end

  describe "edit-warning modal" do
    # `Content.create_document/3` always creates as a draft, so the fixture's
    # signed-off doc lives at `drafts.book-signed`. Saves through the LiveView
    # write to that same draft id; the published id `book-signed` never
    # exists in these tests.
    @draft_id "drafts." <> @signed_doc_id

    test "save on a signed-off doc opens the warning modal and does NOT persist", %{conn: conn} do
      {:ok, view, _html} = open_signed(conn)

      # Pre-condition: draft exists, no notificationType yet.
      {:ok, before} = Content.get_document(@draft_id, "book", @dataset)
      refute Map.has_key?(before.content || %{}, "notificationType")

      view
      |> form("#book-editor-form", %{"doc" => %{"notificationType" => "03"}})
      |> render_submit()

      # Modal visible.
      assert has_element?(view, ~s|[data-test-id="edit-warning-modal"]|)

      # Disk untouched — the explicit save was intercepted before do_save ran.
      {:ok, after_save} = Content.get_document(@draft_id, "book", @dataset)
      refute Map.has_key?(after_save.content || %{}, "notificationType")
    end

    test "dismiss closes the modal and leaves disk untouched", %{conn: conn} do
      {:ok, view, _html} = open_signed(conn)

      view
      |> form("#book-editor-form", %{"doc" => %{"notificationType" => "03"}})
      |> render_submit()

      view |> element(~s|[data-test-id="edit-warning-modal-cancel"]|) |> render_click()
      refute has_element?(view, ~s|[data-test-id="edit-warning-modal"]|)

      {:ok, doc} = Content.get_document(@draft_id, "book", @dataset)
      refute Map.has_key?(doc.content || %{}, "notificationType")
    end

    test "confirm persists the pending save and suppresses warning on subsequent saves",
         %{conn: conn} do
      {:ok, view, _html} = open_signed(conn)

      view
      |> form("#book-editor-form", %{"doc" => %{"notificationType" => "03"}})
      |> render_submit()

      view |> element(~s|[data-test-id="edit-warning-modal-confirm"]|) |> render_click()
      refute has_element?(view, ~s|[data-test-id="edit-warning-modal"]|)

      {:ok, draft} = Content.get_document(@draft_id, "book", @dataset)
      assert draft.content["notificationType"] == "03"

      # Subsequent save bypasses the warning (edit_warning_dismissed=true).
      view
      |> form("#book-editor-form", %{"doc" => %{"notificationType" => "04"}})
      |> render_submit()

      refute has_element?(view, ~s|[data-test-id="edit-warning-modal"]|)
      {:ok, draft2} = Content.get_document(@draft_id, "book", @dataset)
      assert draft2.content["notificationType"] == "04"
    end
  end
end
