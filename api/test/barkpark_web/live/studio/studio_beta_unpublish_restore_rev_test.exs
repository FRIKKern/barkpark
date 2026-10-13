defmodule BarkparkWeb.Studio.StudioBetaUnpublishRestoreRevTest do
  # Unpublish and history Restore rewrite the open document behind the Beta
  # editors, which are phx-update="ignore" and save against the revision they
  # last saw. Each action must tell them the new revision (and, for Restore,
  # the restored blocks), or the next edit pauses for review
  # (task-494fc7f91abd01bd).
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.Content
  @dataset "production"
  @type_name "unpubrev"
  @path "/d/#{@dataset}/studio/#{@type_name}/unpubrev-1"

  defp body(text) do
    %{
      "blocks" => [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      ]
    }
  end

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "body", "title" => "Tekst", "type" => "richText"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{
          "doc_id" => "unpubrev-1",
          "content" => %{"title" => "Fjellet", "body" => body("Først")}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("unpubrev-1", @type_name, @dataset)
    :ok
  end

  defp open_beta(conn) do
    {:ok, view, _} = live(conn, scoped_studio(@path))
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    view
  end

  defp current(id) do
    {:ok, doc} = Content.get_document(id, @type_name, @dataset)
    doc
  end

  test "a Beta unpublish announces the new revision", %{conn: conn} do
    view = open_beta(conn)
    before = current("unpubrev-1").rev

    view
    |> element(~s([data-test-id="studio-beta-doc-actions"] [phx-click="unpublish"]))
    |> render_click()

    rev = :sys.get_state(view.pid).socket.assigns.editor_doc.rev
    refute rev == before

    assert_push_event(view, "bp:document-revision", %{
      rev: ^rev,
      document_key: "production:unpubrev:unpubrev-1"
    })
  end

  test "a Beta history restore pushes the restored blocks and revision", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{
          "doc_id" => "drafts.unpubrev-1",
          "content" => %{"title" => "Fjellet", "body" => body("Utkast")}
        },
        @dataset
      )

    revisions = Content.list_revisions("unpubrev-1", @type_name, @dataset)

    %{id: rev_id} =
      Enum.find(revisions, fn r ->
        get_in(r.content || %{}, [
          "body",
          "blocks",
          Access.at(0),
          "content",
          Access.at(0),
          "value"
        ]) ==
          "Først"
      end)

    view = open_beta(conn)
    render_click(view, "restore-revision", %{"id" => rev_id})

    %{rev: rev} = current("drafts.unpubrev-1")

    assert_push_event(view, "bp:block-update", %{
      block_id: "p-1",
      rev: ^rev,
      request_id: nil,
      block: %{"content" => [%{"value" => "Først"}]}
    })

    assert_push_event(view, "bp:document-revision", %{rev: ^rev})
  end
end
