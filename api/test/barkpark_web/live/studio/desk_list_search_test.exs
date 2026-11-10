defmodule BarkparkWeb.Studio.DeskListSearchTest do
  @moduledoc """
  J24 (barkpark-studio JOURNEYS.md): a list's own search filters its rows as
  you type, and a list says so when nothing matches or when it holds nothing.
  The reference is the TanStack Studio's ListPane (`app/src/components/
  Structure.tsx`) and its spec `e2e/journeys/list.spec.ts`.

  Each test is one thing an editor sees in the desk's list pane. The search
  box these tests name is `form.dk-list-search` with an `input[name="q"]`:
  typing is the form's change event, one per key.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_lsearch_note"
  @empty_type "desk_lsearch_empty"

  @list ~s([data-pane-kind="list"])
  @rows @list <> " a[data-desk-row]"
  @search @list <> " form.dk-list-search"

  setup %{conn: conn} do
    for {name, title} <- [{@type_name, "Search notes"}, {@empty_type, "Nothing here"}] do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => title,
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "summary", "title" => "Summary", "type" => "text"}
            ]
          },
          @dataset
        )
    end

    n = System.unique_integer([:positive])

    # "Delta memo" is made the last edited below, so the list's default order
    # puts it on top: a title match has to win over it on merit.
    docs = [
      {"Alpha note", "About the first letter"},
      {"Beta note", "About the second letter"},
      {"Gamma memo", "Mentions a zebra, which no title does"},
      {"Delta memo", "Written by a beta tester"}
    ]

    for {{title, summary}, i} <- Enum.with_index(docs) do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "dls-#{i}-#{n}", "title" => title, "content" => %{"summary" => summary}},
          @dataset
        )
    end

    # Inside the test's transaction every write shares one timestamp.
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    {_, _} =
      Repo.update_all(
        from(d in Document, where: d.type == ^@type_name and d.title == "Delta memo"),
        set: [updated_at: later]
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base}
  end

  defp admin(conn) do
    raw = "desk-list-search-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-list-search", @dataset, ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open(conn, base, type \\ @type_name) do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{type}")
    render_async(view, 5_000)
    view
  end

  # The row titles as the pane draws them, top to bottom.
  defp titles(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(@rows <> " .pane-item-label")
    |> Enum.map(fn label ->
      label |> LazyHTML.child_nodes() |> LazyHTML.text() |> String.trim()
    end)
    |> Enum.map(&(&1 |> String.split("\n") |> hd() |> String.trim()))
  end

  defp type_in(view, q) do
    assert has_element?(view, @search <> ~s( input[name="q"])),
           "the list pane has no search box (#{@search} input[name=q])"

    view |> element(@search) |> render_change(%{"q" => q})
  end

  # A search may read in the pane's own task: wait for the rows themselves.
  defp rows_become(view, expected) do
    Enum.any?(1..250, fn _ ->
      render_async(view, 5_000)
      titles(view) == expected or (Process.sleep(20) && false)
    end)

    titles(view)
  end

  test "the list pane has a search box", %{conn: conn, base: base} do
    view = open(conn, base)
    assert length(titles(view)) == 4

    assert has_element?(view, @search <> ~s( input[name="q"])),
           "J24: a list has its own search box above its rows (#{@search} input[name=q])"
  end

  test "typing narrows the rows key by key", %{conn: conn, base: base} do
    view = open(conn, base)
    assert Enum.sort(titles(view)) == ["Alpha note", "Beta note", "Delta memo", "Gamma memo"]

    type_in(view, "no")

    assert Enum.sort(rows_become(view, ["Alpha note", "Beta note"])) == [
             "Alpha note",
             "Beta note"
           ]

    type_in(view, "note b")
    assert rows_become(view, ["Beta note"]) == ["Beta note"]
  end

  test "a word found only in another field of the document still finds it", %{
    conn: conn,
    base: base
  } do
    view = open(conn, base)
    type_in(view, "zebra")
    assert rows_become(view, ["Gamma memo"]) == ["Gamma memo"]
  end

  test "a title that matches comes before a newer row that matches elsewhere", %{
    conn: conn,
    base: base
  } do
    view = open(conn, base)
    # Precondition: unsearched, the newer row is above the title match.
    assert hd(titles(view)) == "Delta memo"

    type_in(view, "beta")
    assert rows_become(view, ["Beta note", "Delta memo"]) == ["Beta note", "Delta memo"]
  end

  test "nothing matching says 'No results found', not that the list is empty", %{
    conn: conn,
    base: base
  } do
    view = open(conn, base)
    type_in(view, "zzzz")
    assert rows_become(view, []) == []

    assert has_element?(view, @list <> " .dk-note", "No results found"),
           "J24: a search with no hits says 'No results found'"

    refute has_element?(view, @list <> " .dk-note", "No documents")
  end

  test "clearing the search brings every row back", %{conn: conn, base: base} do
    view = open(conn, base)
    type_in(view, "beta")
    assert length(rows_become(view, ["Beta note", "Delta memo"])) == 2

    type_in(view, "")
    all = rows_become(view, ["Delta memo", "Gamma memo", "Beta note", "Alpha note"])
    assert Enum.sort(all) == ["Alpha note", "Beta note", "Delta memo", "Gamma memo"]
    refute has_element?(view, @list <> " .dk-note", "No results found")
  end

  test "a save by someone else keeps the list searched", %{conn: conn, base: base} do
    view = open(conn, base)
    type_in(view, "beta")
    assert length(rows_become(view, ["Beta note", "Delta memo"])) == 2

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "dls-new-#{System.unique_integer([:positive])}", "title" => "Epsilon note"},
        @dataset
      )

    heard? = fn -> MapSet.size(:sys.get_state(view.pid).socket.assigns.stale) > 0 end

    assert Enum.any?(1..200, fn _ -> heard?.() or (Process.sleep(10) && false) end),
           "the page never heard of the save"

    send(view.pid, :desk_refresh)
    # Let the refresh's re-read land, then look: the new row matches nothing.
    Process.sleep(200)
    render_async(view, 5_000)

    assert titles(view) == ["Beta note", "Delta memo"],
           "after a live refresh the list still shows only what matches the search"
  end

  test "an empty type says it holds no documents", %{conn: conn, base: base} do
    view = open(conn, base, @empty_type)
    assert titles(view) == []
    assert has_element?(view, @list <> " .dk-note", "No documents")
    refute has_element?(view, @list <> " .dk-note", "No results")
  end
end
