defmodule BarkparkWeb.Studio.StudioNewDocumentPanePathTest do
  # task-c06799c87b8d4964: with a document open, the pane's "New <type>"
  # appended the new id after the OPEN one (`nav_path ++ [id]`), so the editor
  # kept the old document and the new one sat orphaned in the list. The press
  # now builds on the pressed pane's own path, as a row click does (#35b).
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.Content

  @dataset "production"
  @type_name "newdocpane"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "newdocpane-open", "title" => "Åpen", "content" => %{"title" => "Åpen"}},
        @dataset
      )

    :ok
  end

  defp editor_doc_id(view), do: :sys.get_state(view.pid).socket.assigns.editor_doc.doc_id

  test "New with a document open opens the new document", %{conn: conn} do
    {:ok, view, _} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@type_name}/newdocpane-open"))

    assert editor_doc_id(view) =~ "newdocpane-open"

    view
    |> element(~s(button[phx-click="new-document"][phx-value-type="#{@type_name}"]))
    |> render_click()

    path = assert_patch(view)
    [_, new_id] = Regex.run(~r{/#{@type_name}/(#{@type_name}-[0-9a-f]+)$}, path)
    refute path =~ "newdocpane-open"
    assert editor_doc_id(view) == "drafts." <> new_id
  end
end
