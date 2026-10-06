defmodule BarkparkWeb.Studio.StudioNewDocFocusTest do
  @moduledoc """
  task-92e2615cf6ec27e6 — a document made with "+" opens with the caret in it.

  Focus stayed on the "+" after a create, so a keyboard user tabbed through
  every list row to reach the new document's first field. The create now
  pushes `bp:focus-new-doc` with the new id; root.html.heex focuses that
  editor's first field once it renders (its jsdom test covers that half).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @type_name "focusart"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Focus Articles",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  defp doc_ids do
    @type_name
    |> Content.list_documents(@dataset, perspective: :raw)
    |> Enum.map(&Content.published_id(&1.doc_id))
    |> MapSet.new()
  end

  test "a + create pushes focus to the document it made, and a re-press to the same one", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
    before = doc_ids()

    render_click(view, "new-document", %{"type" => @type_name})

    [id] = MapSet.difference(doc_ids(), before) |> MapSet.to_list()
    assert_push_event(view, "bp:focus-new-doc", %{id: ^id})

    # The second press inside the retry window reopens the same draft; it
    # must land the caret there too, not leave it on "+".
    render_click(view, "new-document", %{"type" => @type_name})
    assert MapSet.difference(doc_ids(), before) |> MapSet.size() == 1
    assert_push_event(view, "bp:focus-new-doc", %{id: ^id})
  end

  test "opening an existing row does not move focus", %{conn: conn} do
    {:ok, doc} = Content.create_document(@type_name, %{"title" => "Existing"}, @dataset)
    id = Content.published_id(doc.doc_id)

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{@type_name}"))
    assert has_element?(view, "#doc-#{id}"), "the row must render, or the refute is vacuous"

    view |> element(~s(#doc-#{id} [phx-click="select"])) |> render_click()
    assert render(view) =~ ~s(id="doc-field-#{id}-), "the row press must open the editor"
    refute_push_event(view, "bp:focus-new-doc", %{})
  end
end
