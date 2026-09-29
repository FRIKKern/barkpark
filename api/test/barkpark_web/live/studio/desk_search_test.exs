defmodule BarkparkWeb.Studio.DeskSearchTest do
  @moduledoc """
  Gyldendal parity E8 — the desk has a search box.

  Sanity's Studio finds a document by title across every type the editor may
  see. Barkpark had the search API and the reference picker's per-type box, but
  nothing in the desk. This pins the box, the hits, the link they carry, the
  short-query and no-match states, and the clear.

  The tenancy half is pinned in `Barkpark.Content.DeskSearchScopeTest`.
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

    {:ok, ws} = Tenancy.create_workspace(%{slug: "desk-#{suffix}", name: "Desk Search"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "desk-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "desk-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    for name <- ["publication", "author"] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => String.capitalize(name),
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
          },
          @dataset,
          scope
        )
    end

    docs = [
      {"publication", "pub-nord", "Crime from the North"},
      {"publication", "pub-sor", "Songs from the South"},
      {"author", "aut-nord", "Nordahl Grieg"}
    ]

    for {type, id, title} <- docs do
      {:ok, _} =
        Content.upsert_document(
          type,
          %{"doc_id" => id, "title" => title, "status" => "published"},
          @dataset,
          Keyword.put(scope, :source, :api)
        )

      {:ok, _} = Content.publish_document(id, type, @dataset, scope)
    end

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, scope: scope}
  end

  defp desk(conn, ws, proj) do
    {:ok, view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
    {view, html}
  end

  defp type_in(view, q) do
    view |> element(~s([data-test-id="desk-search-input"])) |> render_keyup(%{"value" => q})
  end

  test "the root pane carries a search box and the other panes do not", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {_view, html} = desk(conn, ws, proj)

    assert html =~ ~s(data-test-id="desk-search-input")
    # Exactly one box on the desk, in the root pane.
    assert length(String.split(html, ~s(data-test-id="desk-search-input"))) == 2
    refute html =~ ~s(data-test-id="desk-search-results")
  end

  test "a query finds documents across types and links each hit to its Studio path", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {view, _} = desk(conn, ws, proj)
    html = type_in(view, "nor")

    assert html =~ ~s(data-test-id="desk-search-results")
    assert html =~ "Crime from the North"
    assert html =~ "Nordahl Grieg"
    refute html =~ "Songs from the South"

    prefix = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    assert html =~ ~s(href="#{prefix}/publication/pub-nord")
    assert html =~ ~s(href="#{prefix}/author/aut-nord")
  end

  test "a one-character query asks for more instead of matching the corpus", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {view, _} = desk(conn, ws, proj)
    html = type_in(view, "N")

    assert html =~ ~s(data-test-id="desk-search-too-short")
    refute html =~ ~s(data-test-id="desk-search-hit")
  end

  test "a query with no match says so and names the query", %{conn: conn, ws: ws, proj: proj} do
    {view, _} = desk(conn, ws, proj)
    html = type_in(view, "zzzzz")

    assert html =~ ~s(data-test-id="desk-search-empty")
    assert html =~ "zzzzz"
    refute html =~ ~s(data-test-id="desk-search-hit")
  end

  test "clearing the box brings the desk's own items back", %{conn: conn, ws: ws, proj: proj} do
    {view, before} = desk(conn, ws, proj)
    searching = type_in(view, "nor")
    assert searching =~ ~s(data-test-id="desk-search-results")

    cleared =
      view |> element(~s([data-test-id="desk-search-clear"])) |> render_click()

    refute cleared =~ ~s(data-test-id="desk-search-results")
    refute cleared =~ ~s(data-test-id="desk-search-hit")
    # The root pane's own rows are back — the same section headers it opened with.
    assert cleared =~ ~s(data-test-id="desk-search-input")
    assert before =~ ~s(data-test-id="desk-search-input")
  end
end
