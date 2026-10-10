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

  # task-6f820118621e0f9d: the hit's type label is the schema TITLE the desk
  # shows ("Publication" here, "Utgivelse" on an agency desk), not its id.
  test "each hit names its type by the schema title", %{conn: conn, ws: ws, proj: proj} do
    {view, _} = desk(conn, ws, proj)
    html = type_in(view, "nor")

    subs =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([data-test-id="desk-search-hit"] .pane-doc-sub))
      |> Enum.map(&LazyHTML.text/1)
      |> Enum.sort()

    assert subs == ["Author", "Publication"]
  end

  # task-b4e6fba573777ba3: a type whose schema is a SHARED row (workspace_id
  # NULL, as a plugin registers it) was missing from the listed catalog, so the
  # hit read its raw id ("paper").
  test "a hit whose type is a shared schema row is labelled by that schema's title",
       %{conn: conn, ws: ws, proj: proj, scope: scope} do
    {:ok, _} =
      %Barkpark.Content.SchemaDefinition{}
      |> Barkpark.Content.SchemaDefinition.changeset(%{
        "name" => "deskshared",
        "title" => "Shared Things",
        "dataset" => @dataset,
        "visibility" => "public",
        "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
      })
      |> Barkpark.Repo.insert()

    {:ok, _} =
      Content.upsert_document(
        "deskshared",
        %{"doc_id" => "shared-nord", "title" => "Nordlys", "status" => "published"},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {view, _} = desk(conn, ws, proj)
    html = type_in(view, "nordlys")

    subs =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([data-test-id="desk-search-hit"] .pane-doc-sub))
      |> Enum.map(&LazyHTML.text/1)

    assert subs == ["Shared Things"]
  end

  # Stranger walk, 2026-09-30: a never-published document was unsearchable.
  # Its hit links by the PUBLISHED id, the address every Studio path uses —
  # never the `drafts.` row id.
  test "a never-published document is a hit linked by its published id", %{
    conn: conn,
    ws: ws,
    proj: proj,
    scope: scope
  } do
    {:ok, _} =
      Content.upsert_document(
        "publication",
        %{"doc_id" => "drafts.pub-fresh", "title" => "Zulukladd draft only", "status" => "draft"},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {view, _} = desk(conn, ws, proj)
    html = type_in(view, "zulukladd")

    assert html =~ "Zulukladd draft only"
    prefix = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    assert html =~ ~s(href="#{prefix}/publication/pub-fresh")
    refute html =~ "drafts.pub-fresh"
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

  # task-0ad7fed4370a5978: the hits were silent to a screen reader.
  # task-b78dddf5135d8bbf: so were "type more" and "no match" — each arrived as a
  # NEW status element already holding its text, which a screen reader often
  # skips. One region is on the desk from mount and every state's message lands
  # in it; the visible notices are not live regions, so nothing is read twice.
  test "one status region, present before any typing, announces every search state", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {view, html} = desk(conn, ws, proj)
    count = ~s([data-test-id="desk-search-count"][role="status"])

    assert has_element?(view, count), "the region must exist before the first keystroke"
    # Keyed by id, so the DOM patch updates it in place instead of swapping in a
    # new, already-filled region when the clear button appears before it.
    assert has_element?(view, ~s(#desk-search-status[role="status"]))
    assert html |> status_regions() |> length() == 1
    assert render(view |> element(count)) =~ ~r/>\s*<\/div>/

    html = type_in(view, "N")
    assert view |> element(count) |> render() =~ "Type at least 2 characters"
    assert status_regions(html) == ["desk-search-count"]

    type_in(view, "nor")
    assert view |> element(count) |> render() =~ "2 results"

    html = type_in(view, "zzzzz")
    assert view |> element(count) |> render() =~ "No documents match “zzzzz”"
    assert status_regions(html) == ["desk-search-count"]
  end

  defp status_regions(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(
      ~s([data-test-id="desk-search"] [role="status"], [data-test-id="desk-search-results"] [role="status"])
    )
    |> LazyHTML.attribute("data-test-id")
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
