defmodule BarkparkWeb.Studio.StudioNewDocumentUntitledTest do
  @moduledoc """
  A document made with + is born without a title (task-79e28148d9925097).

  Found dogfooding as a member editor: the Studio stored the literal
  "Untitled" as every new document's title. A required title then passed, so
  + then Publish shipped a document called "Untitled"; and a titleless type
  (author, `list_preview.title = name`) never got its title from the name,
  because `TitleDerivation.maybe_derive` fills only a BLANK title.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "title",
              "title" => "Tittel",
              "type" => "string",
              "validation" => %{"required" => true}
            },
            %{"name" => "ingress", "title" => "Ingress", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Forfatter",
          "visibility" => "public",
          "list_preview" => %{"title" => "name"},
          "fields" => [%{"name" => "name", "title" => "Navn", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  defp create!(conn, type) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{type}"))
    render_click(view, "new-document", %{"type" => type})

    [draft] =
      type
      |> Content.list_documents(@dataset, perspective: :raw)
      |> Enum.filter(&Content.draft?(&1.doc_id))

    {view, draft}
  end

  test "a new document stores no title, and a required title refuses Publish until one is typed",
       %{conn: conn} do
    {view, draft} = create!(conn, "publication")

    assert draft.title == nil
    refute render(view) =~ ~s(value="Untitled")

    html = render_click(view, "publish", %{})
    assert html =~ "Fix validation errors before publishing"

    pub_id = Content.published_id(draft.doc_id)
    assert {:error, :not_found} = Content.get_document(pub_id, "publication", @dataset)

    view
    |> form("#editor-form", %{"doc" => %{"title" => "Fjellet"}})
    |> render_change()

    render_click(view, "publish", %{})
    assert {:ok, %{title: "Fjellet"}} = Content.get_document(pub_id, "publication", @dataset)
  end

  test "a titleless type takes its title from the name on the first autosave",
       %{conn: conn} do
    {view, draft} = create!(conn, "author")

    html =
      view
      |> form("#editor-form", %{"doc" => %{"name" => "Kari Bakke"}})
      |> render_change()

    assert {:ok, %{title: "Kari Bakke"}} =
             Content.get_document(draft.doc_id, "author", @dataset)

    assert html =~ ~s(<span class="pane-header-title">Kari Bakke</span>)
  end
end
