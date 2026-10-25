defmodule BarkparkWeb.Studio.DeskItemViewsTest do
  @moduledoc """
  A declared desk list attaches views to the documents it opens
  (task-ea2e544fec8ee6db), as Sanity's
  `S.document().views([S.view.form(), S.view.component(...).title("Products")])`.

  The list item names `views` with the shape of a schema's `desk.views`. A
  document opened from that list shows those tabs instead of its schema's,
  and the same document opened from a list that names none keeps the schema's.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"

  defp schema!(scope, attrs) do
    {:ok, _} =
      Content.upsert_schema(Map.merge(%{"visibility" => "public"}, attrs), @dataset, scope)
  end

  defp doc!(scope, type, id, title, content) do
    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => id, "title" => title, "status" => "published", "content" => content},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, doc} = Content.publish_document(id, type, @dataset, scope)
    doc
  end

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "deskviews-#{suffix}", name: "Desk views"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "desk-views-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "desk-views", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    schema!(scope, %{
      "name" => "code",
      "title" => "Code",
      "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
      "desk" => %{
        "views" => [
          %{
            "id" => "schema-view",
            "title" => "Schema view",
            "type" => "code",
            "by" => "content.x"
          }
        ]
      }
    })

    schema!(scope, %{
      "name" => "product",
      "title" => "Product",
      "fields" => [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "code", "title" => "Code", "type" => "reference", "to" => ["code"]}
      ]
    })

    schema!(scope, %{
      "name" => "deskStructure",
      "title" => "Desk",
      "singleton" => true,
      "visibility" => "private",
      "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
    })

    code = doc!(scope, "code", "code-1", "Code one", %{})
    doc!(scope, "code", "code-2", "Code two", %{})

    # `codes` is an array of references: Alpha holds code-1 among others.
    for {id, title, ref, codes} <- [
          {"prod-b", "Bravo", "code-1", []},
          {"prod-a", "Alpha", "code-1", ["code-2", "code-1"]},
          {"prod-c", "Charlie", "code-2", ["code-2"]}
        ] do
      doc!(scope, "product", id, title, %{
        "code" => %{"_type" => "reference", "_ref" => ref},
        "codes" =>
          codes
          |> Enum.with_index()
          |> Enum.map(fn {c, i} -> %{"_type" => "reference", "_ref" => c, "_key" => "k#{i}"} end)
      })
    end

    items = [
      %{
        "kind" => "documentTypeList",
        "id" => "used-codes",
        "type" => "code",
        "title" => "Used on products",
        "views" => [
          %{
            "id" => "products",
            "title" => "Products",
            "type" => "product",
            "by" => "content.code._ref",
            "orderings" => [%{"field" => "title", "direction" => "asc"}]
          }
        ]
      },
      %{"kind" => "documentTypeList", "id" => "all-codes", "type" => "code", "title" => "All"},
      %{
        "kind" => "documentTypeList",
        "id" => "array-codes",
        "type" => "code",
        "title" => "In product code lists",
        "views" => [
          %{
            "id" => "products",
            "title" => "Products",
            "type" => "product",
            "by" => "content.codes[]._ref"
          }
        ]
      },
      %{
        "kind" => "documentTypeList",
        "id" => "bad-views",
        "type" => "code",
        "title" => "Bad views",
        "views" => [%{"id" => "no-by", "title" => "No by", "type" => "product"}]
      }
    ]

    doc!(scope, "deskStructure", "deskStructure", "Desk", %{"items" => items})

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, scope: scope, code: code}
  end

  defp open!(conn, ws, proj, path) do
    {:ok, view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{path}")
    refute html =~ "Studio could not open this document"
    {view, html}
  end

  defp tab_ids(html) do
    ~r/data-test-id="document-view-tab"[^>]*data-view-id="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
  end

  test "a document opened from a list that declares views shows those tabs", %{
    conn: conn,
    ws: ws,
    proj: proj,
    code: code
  } do
    {view, html} = open!(conn, ws, proj, "used-codes/#{code.doc_id}")

    # The item's views replace the schema's.
    assert tab_ids(html) == ["products"]
    assert html =~ "Products"
    assert html =~ ~s(id="editor-form")

    html =
      view
      |> element(~s([data-test-id="document-view-tab"][data-view-id="products"]))
      |> render_click()

    [_, list] = String.split(html, ~s(data-test-id="document-view-list"), parts: 2)
    prefix = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    assert list =~ ~s(href="#{prefix}/product/prod-a")
    assert list =~ ~s(href="#{prefix}/product/prod-b")
    refute list =~ "prod-c"
    refute html =~ ~s(id="editor-form")
  end

  test "the same document opened from a list without views keeps the schema's", %{
    conn: conn,
    ws: ws,
    proj: proj,
    code: code
  } do
    {_view, html} = open!(conn, ws, proj, "all-codes/#{code.doc_id}")
    assert tab_ids(html) == ["schema-view"]
  end

  test "a list's view by an array of references lists the documents whose array holds it", %{
    conn: conn,
    ws: ws,
    proj: proj,
    code: code
  } do
    {view, _html} = open!(conn, ws, proj, "array-codes/#{code.doc_id}")

    html =
      view
      |> element(~s([data-test-id="document-view-tab"][data-view-id="products"]))
      |> render_click()

    [_, list] = String.split(html, ~s(data-test-id="document-view-list"), parts: 2)
    ids = ~r/id="view-doc-([^"]+)"/ |> Regex.scan(list) |> Enum.map(fn [_, id] -> id end)
    assert ids == ["prod-a"]
  end

  test "a malformed view entry is left out and named on the desk item", %{scope: scope} do
    {_panes, editor} = PaneBuilder.build(@dataset, ["bad-views", "code-1"], scope: scope)
    assert editor.views == []

    node =
      @dataset
      |> Barkpark.Structure.build(scope)
      |> Map.get(:items)
      |> Enum.find(&(&1.id == "bad-views"))

    assert node.error =~ "views entries need"
  end
end
