defmodule BarkparkWeb.Studio.StudioOpenTwinShapesTest do
  @moduledoc """
  task-592dee75ffef0c06 and task-cca3c6d48e57097e. The gyldendal.no twin's
  product, page, category and frontPage documents answered HTTP 500 in the
  Studio, and every document open took 9 to 11 s on gyl.

    * An `arrayOf` whose `of` is a LIST of named member types (the page
      builder's `landingPageSections`, the product's `tilleggsressurser`)
      reached `Adapter.stringify/1`, which takes a map only. The document
      route raised `FunctionClauseError`.
    * A desk filter value that is a JSON boolean or number
      (`{"content.isCustom": {"neq": true}}`, `{"content.hitCount": {"gt": 0}}`)
      reached Postgrex as a text parameter. The list pane raised, and so did
      every document opened under it.
    * Inlining named object types looked each one up again per reference,
      and the dead render built the inlined catalog once per desk filter.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  @sections [
    %{
      "_key" => "s1",
      "_type" => "contentSection",
      "heading" => "Om Salto",
      "body" => [
        %{
          "_key" => "b1",
          "_type" => "block",
          "style" => "normal",
          "children" => [%{"_key" => "c1", "_type" => "span", "text" => "Hei", "marks" => []}],
          "markDefs" => []
        }
      ]
    },
    %{"_key" => "s2", "_type" => "ctaSection", "title" => "Bestill nå", "href" => "/bestill"},
    %{"_key" => "s3", "_type" => "retiredSection", "note" => "no schema for this member"}
  ]

  @resources [
    %{"_key" => "r1", "_type" => "tilleggsressurs", "title" => "Lærerveiledning", "url" => "https://x"},
    %{"_key" => "r2", "_type" => "tilleggsressursFil", "title" => "Fasit", "file" => %{"asset" => %{"_ref" => "file-1"}}}
  ]

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "open-twin-#{suffix}", name: "Open Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "open-twin-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "open-twin", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    for {name, title, fields} <- [
          {"themeStyling", "Tema", [%{"name" => "theme", "type" => "string"}]},
          {"contentSection", "Tekstinnhold",
           [
             %{"name" => "heading", "type" => "string"},
             %{"name" => "body", "type" => "richText"},
             %{"name" => "styling", "type" => "themeStyling"}
           ]},
          {"ctaSection", "Handlingsknapp",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "href", "type" => "string"},
             %{"name" => "styling", "type" => "themeStyling"}
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "kind" => "object", "title" => title, "fields" => fields},
          @dataset,
          scope
        )
    end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "page",
          "title" => "Side",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "styling", "title" => "Tema", "type" => "themeStyling"},
            %{
              "name" => "landingPageSections",
              "title" => "Seksjoner",
              "type" => "arrayOf",
              "of" => [
                %{"name" => "contentSection", "type" => "contentSection"},
                %{"name" => "ctaSection", "type" => "ctaSection"}
              ]
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "product",
          "title" => "Produkt",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "tilleggsressurser",
              "title" => "Tilleggsressurser",
              "type" => "arrayOf",
              "of" => [
                %{
                  "name" => "tilleggsressurs",
                  "type" => "composite",
                  "title" => "Lenke",
                  "fields" => [
                    %{"name" => "title", "type" => "string"},
                    %{"name" => "url", "type" => "url"}
                  ]
                },
                %{
                  "name" => "tilleggsressursFil",
                  "type" => "composite",
                  "title" => "Fil",
                  "fields" => [
                    %{"name" => "title", "type" => "string"},
                    %{"name" => "file", "type" => "file"}
                  ]
                }
              ]
            },
            %{"name" => "isCustom", "title" => "Egen", "type" => "boolean"},
            %{"name" => "hitCount", "title" => "Treff", "type" => "number"}
          ]
        },
        @dataset,
        scope
      )

    page = publish!("page", "salto-landing", %{"title" => "Salto", "landingPageSections" => @sections}, scope)

    product =
      publish!(
        "product",
        "onix.product-1",
        %{"title" => "Makta", "tilleggsressurser" => @resources, "isCustom" => false, "hitCount" => 3},
        scope
      )

    _custom =
      publish!("product", "onix.product-2", %{"title" => "Egen", "isCustom" => true, "hitCount" => 0}, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, page: page, product: product, scope: scope}
  end

  defp publish!(type, id, content, scope) do
    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => id, "title" => content["title"], "status" => "published", "content" => content},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, doc} = Content.publish_document(id, type, @dataset, scope)
    doc
  end

  defp doc_path(ws, proj, type, id), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{id}"

  describe "a list of named member types (page builder sections)" do
    test "the page opens by URL, dead render and connected", %{conn: conn, ws: ws, proj: proj} do
      path = doc_path(ws, proj, "page", "salto-landing")

      assert html_response(get(conn, path), 200) =~ "Seksjoner"

      {:ok, _view, html} = live(conn, path)
      refute html =~ "Studio could not open this document"
      assert html =~ ~s(data-typed-array)
      # Each row names its member and shows the row's own text.
      assert html =~ ~s(data-member-type="contentSection")
      assert html =~ ~s(data-member-type="ctaSection")
      assert html =~ "Om Salto"
      assert html =~ "Bestill nå"
      # A row whose member the schema no longer declares still shows.
      assert html =~ ~s(data-member-type="retiredSection")
      # Read-only: no input posts the list, so a save cannot rewrite it.
      refute html =~ ~s(name="doc[landingPageSections])
    end

    test "editing another field keeps the section list byte-identical",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "page", "salto-landing"))

      view
      |> form("#editor-form", %{"doc[styling].theme" => "mørk"})
      |> render_change(%{"_target" => ["doc[styling].theme"]})

      # The autosave wrote the draft: the edited subfield, and the section list
      # exactly as stored.
      {:ok, doc} = Content.get_document("drafts.salto-landing", "page", @dataset, scope)
      assert doc.content["styling"]["theme"] == "mørk"
      assert doc.content["landingPageSections"] == @sections
    end
  end

  test "a list of inline composite members (product resources) opens",
       %{conn: conn, ws: ws, proj: proj} do
    {:ok, _view, html} = live(conn, doc_path(ws, proj, "product", "onix.product-1"))
    refute html =~ "Studio could not open this document"
    assert html =~ ~s(data-member-type="tilleggsressurs")
    assert html =~ ~s(data-member-type="tilleggsressursFil")
    assert html =~ "Lærerveiledning"
  end

  describe "desk filters with JSON boolean and number values" do
    test "neq true and gt 0 filter instead of raising", %{scope: scope} do
      not_custom =
        Content.list_documents("product", @dataset,
          Keyword.merge(scope, filter_map: %{"content.isCustom" => %{"neq" => true}})
        )

      assert Enum.map(not_custom, & &1.doc_id) == ["onix.product-1"]

      hit =
        Content.list_documents("product", @dataset,
          Keyword.merge(scope, filter_map: %{"content.hitCount" => %{"gt" => 0}})
        )

      assert Enum.map(hit, & &1.doc_id) == ["onix.product-1"]

      custom =
        Content.list_documents("product", @dataset,
          Keyword.merge(scope, filter_map: %{"content.isCustom" => %{"eq" => true}})
        )

      assert Enum.map(custom, & &1.doc_id) == ["onix.product-2"]
    end
  end

  describe "named object type inlining" do
    test "a catalog resolves each object type once, however many fields name it", %{scope: scope} do
      for i <- 1..6 do
        {:ok, _} =
          Content.upsert_schema(
            %{
              "name" => "landing#{i}",
              "title" => "Landing #{i}",
              "fields" => [
                %{"name" => "a", "type" => "themeStyling"},
                %{"name" => "b", "type" => "contentSection"},
                %{"name" => "c", "type" => "ctaSection"}
              ]
            },
            @dataset,
            scope
          )
      end

      queries = count_schema_queries(fn -> Content.Schema.list_schemas(@dataset, scope) end)

      # One catalog read, then at most three scope rungs (two queries each: the
      # dataset id and the row) for each of the three object types. Before, each
      # of the 6 x 3 references and each nested `styling` resolved on its own.
      assert queries <= 1 + 3 * 3 * 2, "expected at most 19 queries, got #{queries}"

      catalog = Content.Schema.list_schemas(@dataset, scope)
      landing = Enum.find(catalog, &(&1.name == "landing1"))
      section = Enum.find(landing.fields, &(&1["name"] == "b"))
      assert section["type"] == "composite"
      assert section["namedType"] == "contentSection"
      assert Enum.find(section["fields"], &(&1["name"] == "styling"))["namedType"] == "themeStyling"
    end
  end

  defp count_schema_queries(fun) do
    ref = make_ref()
    parent = self()
    id = "studio-open-twin-#{inspect(ref)}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _e, _m, meta, _ ->
        if self() == parent and meta[:source] in ["schema_definitions", "datasets"],
          do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    count_messages(ref, 0)
  end

  defp count_messages(ref, n) do
    receive do
      {^ref, :query} -> count_messages(ref, n + 1)
    after
      0 -> n
    end
  end
end
