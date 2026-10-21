defmodule BarkparkWeb.Studio.DocumentViewsArrayRefTest do
  @moduledoc """
  A document view whose `by` path names an ARRAY of references.

  Sanity lists the subcategories of a category with `$id in
  parentCategories[]._ref`. A view read with `eq` on an array matches nothing,
  and `_references` also matches documents that point at the category from
  another field. A `by` ending in `[]._ref` reads with `has` on that one array.

  This also pins the list's read: one scoped document query per page, the
  desk list's own rows, and "Show more" for a list longer than one page.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.QueryCounter
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Handlers.Views

  @dataset "production"

  defp ref(id, key), do: %{"_type" => "reference", "_ref" => id, "_key" => key}

  defp make_workspace(prefix) do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{prefix}-#{suffix}", name: prefix})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {ws, proj, [workspace_id: ws.id, project_id: proj.id]}
  end

  defp put_schemas!(scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "category",
          "title" => "Category",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "parentCategories",
              "title" => "Parents",
              "type" => "array",
              "of" => [%{"type" => "reference", "to" => [%{"type" => "category"}]}]
            },
            %{
              "name" => "menuItems",
              "title" => "Menu",
              "type" => "array",
              "of" => [%{"type" => "reference", "to" => [%{"type" => "category"}]}]
            }
          ],
          "list_preview" => %{"subtitle" => "code"},
          "desk" => %{
            "views" => [
              %{
                "id" => "subcategories",
                "title" => "Subcategories",
                "type" => "category",
                "by" => "content.parentCategories[]._ref",
                "orderings" => [%{"field" => "title", "direction" => "asc"}]
              }
            ]
          }
        },
        @dataset,
        scope
      )
  end

  defp put_doc!(scope, id, title, content) do
    {:ok, _} =
      Content.upsert_document(
        "category",
        %{"doc_id" => id, "title" => title, "status" => "published", "content" => content},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, doc} = Content.publish_document(id, "category", @dataset, scope)
    doc
  end

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    {ws, proj, scope} = make_workspace("viewsarr")

    raw = "views-arr-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "views-arr", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    put_schemas!(scope)

    root = put_doc!(scope, "cat-root", "Root", %{})
    other = put_doc!(scope, "cat-other", "Other", %{})

    # Two children hold the root in their parents array, one among others.
    put_doc!(scope, "cat-b", "Beta", %{
      "code" => "B-1",
      "parentCategories" => [ref("cat-root", "k1")]
    })

    put_doc!(scope, "cat-a", "Alpha", %{
      "code" => "A-1",
      "parentCategories" => [ref("cat-other", "k1"), ref("cat-root", "k2")]
    })

    # Points at the root from ANOTHER array: `_references` would list it.
    put_doc!(scope, "cat-menu", "Menu holder", %{"menuItems" => [ref("cat-root", "k1")]})
    # A child of another category only.
    put_doc!(scope, "cat-c", "Gamma", %{"parentCategories" => [ref("cat-other", "k1")]})

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, scope: scope, root: root, other: other}
  end

  defp open_view!(conn, ws, proj, doc_id) do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/category/#{doc_id}")

    html =
      view
      |> element(~s([data-test-id="document-view-tab"][data-view-id="subcategories"]))
      |> render_click()

    {view, html}
  end

  defp row_ids(html) do
    ~r/id="view-doc-([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
  end

  test "a view by an array of references lists exactly the documents whose array holds it",
       %{conn: conn, ws: ws, proj: proj, root: root} do
    {_view, html} = open_view!(conn, ws, proj, root.doc_id)

    # Ordered by title; the menuItems holder and the other category's child
    # are not in it.
    assert row_ids(html) == ["cat-a", "cat-b"]

    # The desk list's own row: the declared subtitle, linked by URL.
    assert html =~ "A-1"
    prefix = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    assert html =~ ~s(href="#{prefix}/category/cat-a")
    assert html =~ ~s(class="bp-doc-row-body")
  end

  test "the other category's view lists its own children", %{
    conn: conn,
    ws: ws,
    proj: proj,
    other: other
  } do
    {_view, html} = open_view!(conn, ws, proj, other.doc_id)
    assert row_ids(html) == ["cat-a", "cat-c"]
  end

  test "the list is one document query", %{conn: conn, ws: ws, proj: proj, root: root} do
    {:ok, view, _html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/category/#{root.doc_id}")

    {html, sqls} =
      QueryCounter.capture(fn ->
        QueryCounter.own(view.pid)

        view
        |> element(~s([data-test-id="document-view-tab"][data-view-id="subcategories"]))
        |> render_click()
      end)

    assert row_ids(html) == ["cat-a", "cat-b"]
    doc_reads = Enum.filter(sqls, &(&1.source == "documents"))
    assert length(doc_reads) == 1, "document reads: #{inspect(Enum.map(doc_reads, & &1.query))}"
  end

  test "a document in another workspace that holds the same id is not listed", %{
    conn: conn,
    ws: ws,
    proj: proj,
    root: root
  } do
    {_ws2, _proj2, scope2} = make_workspace("viewsarr-other")
    put_schemas!(scope2)

    put_doc!(scope2, "cat-foreign", "Foreign", %{
      "parentCategories" => [ref(root.doc_id, "k1")]
    })

    {_view, html} = open_view!(conn, ws, proj, root.doc_id)
    assert row_ids(html) == ["cat-a", "cat-b"]
  end

  test "a list longer than one page offers Show more and reads the next page", %{
    conn: conn,
    ws: ws,
    proj: proj,
    scope: scope
  } do
    page = PaneBuilder.desk_page()
    put_doc!(scope, "cat-big", "Big", %{})

    for i <- 1..(page + 1) do
      n = String.pad_leading("#{i}", 3, "0")

      {:ok, _} =
        Content.upsert_document(
          "category",
          %{
            "doc_id" => "cat-big-#{n}",
            "title" => "Child #{n}",
            "status" => "published",
            "content" => %{"parentCategories" => [ref("cat-big", "k1")]}
          },
          @dataset,
          Keyword.put(scope, :source, :api)
        )
    end

    {view, html} = open_view!(conn, ws, proj, "cat-big")
    assert length(row_ids(html)) == page
    assert html =~ ~s(data-test-id="document-view-more")

    html = view |> element(~s([data-test-id="document-view-more"])) |> render_click()
    assert length(row_ids(html)) == page + 1
    refute html =~ ~s(data-test-id="document-view-more")
  end

  describe "filter_map/2" do
    test "an array path reads with has, any other path with eq" do
      assert Views.filter_map("content.parentCategories[]._ref", "c1") ==
               %{"content.parentCategories" => %{"has" => "c1"}}

      assert Views.filter_map("content.tags[]", "c1") == %{"content.tags" => %{"has" => "c1"}}
      assert Views.filter_map("content.series", "s1") == %{"content.series" => %{"eq" => "s1"}}
    end
  end

  describe "schema validation of by" do
    defp changeset(by) do
      SchemaDefinition.changeset(%SchemaDefinition{}, %{
        name: "category",
        title: "Category",
        dataset: @dataset,
        fields: [],
        desk: %{
          "views" => [%{"id" => "v", "title" => "V", "type" => "category", "by" => by}]
        }
      })
    end

    test "accepts an array marker at the end" do
      refute Keyword.has_key?(changeset("content.parentCategories[]._ref").errors, :desk)
      refute Keyword.has_key?(changeset("content.tags[]").errors, :desk)
      refute Keyword.has_key?(changeset("content.series").errors, :desk)
    end

    test "refuses [] anywhere else" do
      assert Keyword.has_key?(changeset("content.contributors[].person._ref").errors, :desk)
      assert Keyword.has_key?(changeset("[]._ref").errors, :desk)
    end
  end
end
