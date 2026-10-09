defmodule BarkparkWeb.Studio.StudioLiveDeleteFocusTest do
  @moduledoc """
  task-bad96a2a1c3da132: deleting a document closed the editor that held focus,
  so focus fell to <body>. After a delete Studio now tells the client which
  type's list the document sat in and at which row, so the layout's listener
  can focus the row that takes its place (or the New button).
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
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for {id, title} <- [{"focus-a", "Alpha"}, {"focus-b", "Bravo"}, {"focus-c", "Charlie"}] do
      {:ok, _} =
        Content.create_document(@schema_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {:ok, conn: conn}
  end

  defp row_ids(html) do
    ~r/phx-click="select"[^>]*phx-value-id="([^"]+)"|phx-value-id="([^"]+)"[^>]*phx-click="select"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn parts -> Enum.find(parts, &(&1 != "")) end)
    |> Enum.uniq()
  end

  test "a confirmed delete pushes the deleted row's place in its list", %{conn: conn} do
    {:ok, view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@schema_name}/focus-b"))

    ids = row_ids(html)
    index = Enum.find_index(ids, &(Content.published_id(&1) == "focus-b"))
    assert is_integer(index), "precondition: the list pane shows the open document"

    render_click(view, "delete-doc", %{})
    render_click(view, "confirm-delete", %{})

    assert_push_event(view, "bp:focus-after-delete", %{
      type: @schema_name,
      id: "focus-b",
      index: ^index
    })
  end

  test "the Studio layout listens for it and never focuses the deleted row" do
    root = File.read!("lib/barkpark_web/layouts/root.html.heex")
    assert root =~ ~s|window.addEventListener("phx:bp:focus-after-delete"|
    assert root =~ "!sameDoc(b.getAttribute(\"phx-value-id\"))"
  end
end
