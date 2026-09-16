defmodule BarkparkWeb.Studio.DocumentViewsTest do
  @moduledoc """
  Gyldendal parity E10 — the tabs Sanity's `defaultDocumentNode` puts beside
  «Felt» on an open document: «Bøker i serien» on a series, «Bøker av
  forfatteren» on an author.

  A schema declares them under `desk.views`. This pins the tab row, the form
  swap, the related list and its links, the draft pill, the empty state, and
  the silence of a schema that declares none.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "views-#{suffix}", name: "Views"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "views-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "views-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "series",
          "title" => "Serie",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}],
          "desk" => %{
            "views" => [
              %{
                "id" => "boker-i-serien",
                "title" => "Bøker i serien",
                "type" => "publication",
                "by" => "content.series",
                "orderings" => [%{"field" => "title", "direction" => "asc"}]
              }
            ]
          }
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "series", "title" => "Serie", "type" => "reference", "to" => ["series"]}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_document(
        "series",
        %{"doc_id" => "ser-krim", "title" => "Krimserien", "status" => "published"},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, series} = Content.publish_document("ser-krim", "series", @dataset, scope)

    {:ok, _} =
      Content.upsert_document(
        "series",
        %{"doc_id" => "ser-tom", "title" => "Tom serie", "status" => "published"},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, empty} = Content.publish_document("ser-tom", "series", @dataset, scope)

    for {id, title} <- [{"pub-b", "Blodspor"}, {"pub-a", "Askeregn"}] do
      {:ok, _} =
        Content.upsert_document(
          "publication",
          %{
            "doc_id" => id,
            "title" => title,
            "status" => "published",
            "content" => %{"series" => "ser-krim"}
          },
          @dataset,
          Keyword.put(scope, :source, :api)
        )

      {:ok, _} = Content.publish_document(id, "publication", @dataset, scope)
    end

    # A DRAFT-only book in the same series: Sanity's panes read the drafts
    # perspective, so an unpublished book still shows in the series list.
    {:ok, _} =
      Content.upsert_document(
        "publication",
        %{
          "doc_id" => "drafts.pub-c",
          "title" => "Cirkel",
          "status" => "draft",
          "content" => %{"series" => "ser-krim"}
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, series: series, empty: empty}
  end

  defp open!(conn, ws, proj, type, doc_id) do
    {:ok, view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{doc_id}")

    refute html =~ "Studio could not open this document"
    {view, html}
  end

  test "a declared view renders a tab beside the form, and the form is what opens",
       %{conn: conn, ws: ws, proj: proj, series: series} do
    {_view, html} = open!(conn, ws, proj, "series", series.doc_id)

    assert html =~ ~s(data-test-id="document-views")
    assert html =~ "Bøker i serien"
    assert html =~ ~s(data-test-id="document-view-form")
    # The form is the open tab; the related list is not rendered yet.
    assert html =~ ~s(id="editor-form")
    refute html =~ ~s(data-test-id="document-view-list")
  end

  test "selecting the view swaps the form for the related documents, ordered and linked",
       %{conn: conn, ws: ws, proj: proj, series: series} do
    {view, _} = open!(conn, ws, proj, "series", series.doc_id)

    html =
      view
      |> element(~s([data-test-id="document-view-tab"][data-view-id="boker-i-serien"]))
      |> render_click()

    assert html =~ ~s(data-test-id="document-view-list")
    refute html =~ ~s(id="editor-form")

    titles =
      Regex.scan(~r/class="pane-doc-title">([^<]+)</, html) |> Enum.map(fn [_, t] -> t end)

    # asc by title, and the draft-only book rides along (drafts perspective).
    assert titles == ["Askeregn", "Blodspor", "Cirkel"]

    prefix = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    assert html =~ ~s(href="#{prefix}/publication/pub-a")
    assert html =~ ~s(href="#{prefix}/publication/pub-c")
    # The draft-only row says so.
    assert html =~ "status-draft"
  end

  test "clicking the Fields tab brings the form back", %{
    conn: conn,
    ws: ws,
    proj: proj,
    series: series
  } do
    {view, _} = open!(conn, ws, proj, "series", series.doc_id)

    view
    |> element(~s([data-test-id="document-view-tab"][data-view-id="boker-i-serien"]))
    |> render_click()

    html = view |> element(~s([data-test-id="document-view-form"])) |> render_click()

    assert html =~ ~s(id="editor-form")
    refute html =~ ~s(data-test-id="document-view-list")
  end

  test "a view with no related documents says so instead of rendering nothing", %{
    conn: conn,
    ws: ws,
    proj: proj,
    empty: empty
  } do
    {view, _} = open!(conn, ws, proj, "series", empty.doc_id)

    html =
      view
      |> element(~s([data-test-id="document-view-tab"][data-view-id="boker-i-serien"]))
      |> render_click()

    assert html =~ ~s(data-test-id="document-view-empty")
    refute html =~ ~s(data-test-id="document-view-row")
  end

  test "a schema that declares no views renders no tab row at all", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {_view, html} = open!(conn, ws, proj, "publication", "pub-a")

    refute html =~ ~s(data-test-id="document-views")
    assert html =~ ~s(id="editor-form")
  end
end
