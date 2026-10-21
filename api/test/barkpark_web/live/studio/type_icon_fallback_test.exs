defmodule BarkparkWeb.Studio.TypeIconFallbackTest do
  @moduledoc """
  task-835fe5219585ca80: Sanity Studio draws a schema type's icon in a preview
  row that has no media. The built-in Studio drew an empty box, or nothing.

  A row with no media now draws its type's icon on the desk list, in a
  document view's related rows, in the desk search hits, in the reference
  picker's hits (the shell's `data-type-icons` map) and on an array item. A
  type with no icon keeps the row it had.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.StudioComponents.Panes

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "icon-#{suffix}", name: "Type Icons"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "icon-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "icon-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    title = %{"name" => "title", "title" => "Title", "type" => "string"}
    cover = %{"name" => "cover", "title" => "Cover", "type" => "image"}

    schemas = [
      # An icon, no media declaration.
      %{"name" => "widget", "title" => "Widget", "icon" => "basket", "fields" => [title]},
      # No icon at all.
      %{"name" => "gadget", "title" => "Gadget", "fields" => [title]},
      # An icon and a media declaration.
      %{
        "name" => "poster",
        "title" => "Poster",
        "icon" => "tags",
        "fields" => [title, cover],
        "list_preview" => %{"media" => "cover"}
      },
      # A named object type with an icon, and a document with an array of it.
      %{
        "name" => "panel",
        "title" => "Panel",
        "kind" => "object",
        "icon" => "document",
        "fields" => [title]
      },
      %{
        "name" => "board",
        "title" => "Board",
        "fields" => [
          title,
          %{
            "name" => "panels",
            "title" => "Panels",
            "type" => "arrayOf",
            "of" => [%{"name" => "panel", "type" => "panel"}]
          }
        ]
      }
    ]

    for s <- schemas do
      {:ok, _} = Content.upsert_schema(Map.put(s, "visibility", "public"), @dataset, scope)
    end

    docs = [
      {"widget", "wid-1", "Widget one", %{}},
      {"gadget", "gad-1", "Gadget one", %{}},
      {"poster", "pos-img", "Poster with cover",
       %{"cover" => %{"assetId" => "a1", "url" => "/media/files/d/x/cover.jpg"}}},
      {"poster", "pos-bare", "Poster without cover", %{}}
    ]

    for {type, id, t, content} <- docs do
      {:ok, _} =
        Content.upsert_document(
          type,
          %{"doc_id" => id, "title" => t, "status" => "published", "content" => content},
          @dataset,
          Keyword.put(scope, :source, :api)
        )

      {:ok, _} = Content.publish_document(id, type, @dataset, scope)
    end

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, scope: scope}
  end

  defp studio(conn, ws, proj, path) do
    {:ok, view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio" <> path)
    {view, html}
  end

  defp row(html, doc_id) do
    [row] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([id="doc-#{doc_id}"]))
      |> Enum.to_list()

    LazyHTML.to_html(row)
  end

  describe "desk list rows" do
    test "a row with no media draws its type's icon", %{conn: conn, ws: ws, proj: proj} do
      {_view, html} = studio(conn, ws, proj, "/widget")
      widget = row(html, "wid-1")

      assert widget =~ ~s(class="pane-doc-media pane-doc-media-icon")
      assert widget =~ ~s(data-type-icon="basket")
      assert widget =~ "<svg"
    end

    test "a type with no icon keeps its row", %{conn: conn, ws: ws, proj: proj} do
      {_view, html} = studio(conn, ws, proj, "/gadget")
      refute row(html, "gad-1") =~ "pane-doc-media"
    end

    test "an image wins over the icon, and the icon fills the empty slot", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      {_view, html} = studio(conn, ws, proj, "/poster")
      with_cover = row(html, "pos-img")
      bare = row(html, "pos-bare")

      assert with_cover =~ ~s(src="/media/files/d/x/cover.jpg")
      refute with_cover =~ "data-type-icon"
      assert bare =~ ~s(data-type-icon="tags")
      refute bare =~ "pane-doc-media-empty"
    end
  end

  test "a document view's rows carry the type icon", %{scope: scope} do
    {:ok, schema} = Content.resolve_schema("widget", @dataset, scope)
    docs = Content.list_documents("widget", @dataset, [perspective: :drafts] ++ scope)

    assert [%{type_icon: "basket"}] = PaneBuilder.view_rows(docs, schema, @dataset, scope)

    {:ok, gadget} = Content.resolve_schema("gadget", @dataset, scope)
    gadgets = Content.list_documents("gadget", @dataset, [perspective: :drafts] ++ scope)
    assert [%{type_icon: nil}] = PaneBuilder.view_rows(gadgets, gadget, @dataset, scope)
  end

  test "desk search hits draw their type's icon", %{conn: conn, ws: ws, proj: proj} do
    {view, _} = studio(conn, ws, proj, "")

    html =
      view
      |> element(~s([data-test-id="desk-search-input"]))
      |> render_keyup(%{"value" => "one"})

    hits =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([data-test-id="desk-search-hit"]))
      |> Enum.map(&LazyHTML.to_html/1)

    widget = Enum.find(hits, &(&1 =~ "Widget one"))
    gadget = Enum.find(hits, &(&1 =~ "Gadget one"))

    assert widget =~ ~s(data-type-icon="basket")
    refute gadget =~ "data-type-icon"
  end

  test "the shell gives the reference picker each type's icon", %{conn: conn, ws: ws, proj: proj} do
    {_view, html} = studio(conn, ws, proj, "")

    [json] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-type-icons]")
      |> LazyHTML.attribute("data-type-icons")

    icons = Jason.decode!(json)
    assert icons["widget"] =~ "<svg"
    assert icons["poster"] =~ "<svg"
    refute Map.has_key?(icons, "gadget")
  end

  describe "array items" do
    test "a named object type's icon rides into the inlined member", %{scope: scope} do
      {:ok, board} = Content.resolve_schema("board", @dataset, scope)
      panels = Enum.find(board.fields, &(&1["name"] == "panels"))
      assert [%{"namedType" => "panel", "icon" => "document"}] = panels["of"]
    end

    test "an item with no media draws its member type's icon" do
      item = %{
        type: "composite",
        name: "panel",
        title: "Panel",
        fields: [],
        raw: %{"icon" => "document"}
      }

      assert %{icon: "document", media: nil} = ArrayField.item_preview(item, %{"title" => "A"})

      bare = %{type: "composite", name: "panel", title: "Panel", fields: [], raw: %{}}
      assert %{icon: nil} = ArrayField.item_preview(bare, %{"title" => "A"})
    end
  end

  describe "pane_doc_item/1" do
    defp item(extra) do
      render_component(
        &Panes.pane_doc_item/1,
        Map.merge(%{title: "T", doc_id: "d1", status: "published"}, extra)
      )
    end

    test "draws the type icon only when the row has no media" do
      assert item(%{type_icon: "tags"}) =~ ~s(data-type-icon="tags")

      with_media = item(%{type_icon: "tags", media: "/m.jpg", media_slot: true})
      assert with_media =~ ~s(src="/m.jpg")
      refute with_media =~ "data-type-icon"
    end

    test "with no type icon the row is as before" do
      assert item(%{media_slot: true}) =~ "pane-doc-media-empty"
      refute item(%{}) =~ "pane-doc-media"
    end
  end
end
