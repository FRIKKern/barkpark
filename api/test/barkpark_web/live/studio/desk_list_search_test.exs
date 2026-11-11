defmodule BarkparkWeb.Studio.DeskListSearchTest do
  @moduledoc """
  J24 (barkpark-studio JOURNEYS.md): a list's own search box narrows its rows
  as you type, over the whole list on the server, and says so when nothing
  matches. The reference is the TanStack Studio's ListPane (`app/src/
  components/Structure.tsx`) and its specs `e2e/journeys/list.spec.ts` (the
  two J24 tests) and `big-list.spec.ts` (a match past the loaded rows).

  The names are the spec's: a combobox named "Search list" (also its
  placeholder) whose `aria-activedescendant` names the lit row's element
  (`…-item-<n>`, the element around the row's link), "No results found", and a
  button named "Clear search".
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
  @big_type "desk_lsearch_big"

  @list ~s(section.pane.list)
  @rows @list <> " a[data-desk-row]"
  @box @list <> ~s( input[role="combobox"][aria-label="Search list"])
  @form @list <> " .dk-list-search form"

  setup %{conn: conn} do
    for {name, title} <- [{@type_name, "Search notes"}, {@big_type, "Big list"}] do
      {:ok, _schema} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => title,
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "summary", "title" => "Summary", "type" => "text"},
              %{
                "name" => "body",
                "title" => "Body",
                "type" => "array",
                "of" => [%{"type" => "block"}]
              }
            ]
          },
          @dataset
        )
    end

    n = System.unique_integer([:positive])

    # "Delta memo" is made the last edited below, so the list's default order
    # puts it on top: a title match has to win over it on merit.
    docs = [
      {"Alpha note", "About the first letter", nil},
      {"Beta note", "About the second letter", nil},
      {"Gamma memo", "Mentions a zebra, which no title does", nil},
      {"Delta memo", "Written by a beta tester", nil},
      {"Epsilon memo", "Plain", "A Heading inside a rich-text block"}
    ]

    for {{title, summary, block}, i} <- Enum.with_index(docs) do
      content = %{"summary" => summary}
      content = if block, do: Map.put(content, "body", [block(block)]), else: content

      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "dls-#{i}-#{n}", "title" => title, "content" => content},
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

    {:ok, conn: conn, base: base, n: n}
  end

  defp block(text) do
    %{
      "_type" => "block",
      "_key" => "k1",
      "style" => "normal",
      "children" => [%{"_type" => "span", "_key" => "s1", "text" => text, "marks" => []}]
    }
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

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  # The row titles as the pane draws them, top to bottom.
  defp titles(view) do
    view
    |> doc()
    |> LazyHTML.query(@rows <> " .pane-item-label")
    |> Enum.map(fn label ->
      label |> LazyHTML.child_nodes() |> LazyHTML.text() |> String.trim()
    end)
    |> Enum.map(&(&1 |> String.split("\n") |> hd() |> String.trim()))
  end

  defp box_attr(view, name) do
    case view |> doc() |> LazyHTML.query(@box) |> LazyHTML.attribute(name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp type_in(view, q) do
    assert has_element?(view, @box),
           "the list pane has no search box (#{@box})"

    view |> element(@form) |> render_change(%{"q" => q})
  end

  defp key(view, key),
    do: view |> element(@box) |> render_keydown(%{"key" => key})

  # A search reads in the pane's own task: wait for the rows themselves.
  defp rows_become(view, expected) do
    Enum.any?(1..250, fn _ ->
      render_async(view, 5_000)
      titles(view) == expected or (Process.sleep(20) && false)
    end)

    titles(view)
  end

  defp wait_for(fun) do
    Enum.any?(1..250, fn _ -> fun.() or (Process.sleep(20) && false) end)
  end

  test "the list pane has a combobox named Search list", %{conn: conn, base: base} do
    view = open(conn, base)
    assert length(titles(view)) == 5

    assert has_element?(view, @box <> ~s([placeholder="Search list"][type="search"])),
           "J24: a list has its own search box, a combobox named and placeholdered Search list (#{@box})"

    # It controls the pane's rows, and lights nothing before a search.
    rows_id = box_attr(view, "aria-controls")
    assert rows_id && has_element?(view, ~s([id="#{rows_id}"] a[data-desk-row]))
    assert box_attr(view, "aria-activedescendant") == nil
    # Outside the scrolling rows, so Tab from the box enters the list (J19).
    refute has_element?(view, @list <> " .list-rows input[role=combobox]")
  end

  test "typing narrows the rows key by key", %{conn: conn, base: base} do
    view = open(conn, base)

    assert Enum.sort(titles(view)) == [
             "Alpha note",
             "Beta note",
             "Delta memo",
             "Epsilon memo",
             "Gamma memo"
           ]

    type_in(view, "not")

    assert Enum.sort(rows_become(view, ["Alpha note", "Beta note"])) == [
             "Alpha note",
             "Beta note"
           ]

    # Every word must match; a title whose words start with more of them comes
    # first ("b" is in Alpha's "About", but only Beta's title has a b-word).
    type_in(view, "note b")
    assert rows_become(view, ["Beta note", "Alpha note"]) == ["Beta note", "Alpha note"]

    type_in(view, "note bet")
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

  test "a word in a rich-text block finds its document", %{conn: conn, base: base} do
    view = open(conn, base)
    type_in(view, "Heading")
    assert rows_become(view, ["Epsilon memo"]) == ["Epsilon memo"]
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

  test "Clear search empties the box, gives it the focus and brings every row back", %{
    conn: conn,
    base: base
  } do
    view = open(conn, base)
    refute has_element?(view, @list <> ~s( button[aria-label="Clear search"]))
    type_in(view, "zzzz")
    assert rows_become(view, []) == []

    clear = @list <> ~s( button[aria-label="Clear search"])
    assert has_element?(view, clear), "J24: a searched box has a button named Clear search"

    # The browser half: a reset button (the browser empties the focused box),
    # and the focus goes back into the box.
    [js] = view |> doc() |> LazyHTML.query(clear) |> LazyHTML.attribute("phx-click")
    assert has_element?(view, clear <> ~s([type="reset"]))
    # By an attribute selector: a pane's id holds a `:`, which `#id` cannot spell.
    input = ~s([id="#{box_attr(view, "id")}"])
    ops = Jason.decode!(js)

    assert ["focus", %{"to" => input}] in ops,
           "Clear search puts the focus back in the box: #{js}"

    assert ["set_attr", %{"attr" => ["value", ""], "to" => input}] in ops,
           "Clear search empties the box's reset value: #{js}"

    view |> element(clear) |> render_click()

    all =
      rows_become(view, ["Delta memo", "Epsilon memo", "Gamma memo", "Beta note", "Alpha note"])

    assert length(all) == 5
    assert box_attr(view, "value") == ""
    refute has_element?(view, clear)
    refute has_element?(view, @list <> " .dk-note", "No results found")
  end

  test "the first result is lit, ArrowDown moves the light, Enter opens the lit row", %{
    conn: conn,
    base: base
  } do
    view = open(conn, base)
    type_in(view, "note")
    assert wait_for(fn -> Enum.sort(rows_become(view, [])) == ["Alpha note", "Beta note"] end)
    pane = box_attr(view, "aria-controls") |> String.replace_suffix("-rows", "")

    lit = box_attr(view, "aria-activedescendant")
    assert lit == pane <> "-item-0", "J24: typing lights the first result"
    # The id is on the row element around the row's link, and that row is lit.
    assert has_element?(view, ~s([id="#{lit}"].dk-row.dk-lit > a[data-desk-row]))

    # LiveView fires a key binding on the event's own target only, and
    # debounces an element's events in one cycle: the keys sit on the box,
    # which has no phx-debounce (a debounced box drops the text typed just
    # before an ArrowDown).
    assert has_element?(view, @box <> ~s([phx-keydown="list-search-key"]))
    refute has_element?(view, @box <> "[phx-debounce]")

    key(view, "ArrowDown")
    lit = box_attr(view, "aria-activedescendant")
    assert lit == pane <> "-item-1", "ArrowDown lights the next result"
    assert has_element?(view, ~s([id="#{lit}"].dk-lit a[data-desk-row]))
    assert view |> doc() |> LazyHTML.query(@list <> " .dk-lit") |> Enum.count() == 1

    key(view, "ArrowDown")

    assert box_attr(view, "aria-activedescendant") == pane <> "-item-1",
           "the light stops at the last row"

    key(view, "ArrowUp")
    assert box_attr(view, "aria-activedescendant") == pane <> "-item-0"
    key(view, "ArrowDown")

    [href] =
      view
      |> doc()
      |> LazyHTML.query(~s([id="#{pane}-item-1"] a[data-desk-row]))
      |> LazyHTML.attribute("href")

    view |> element(@form) |> render_submit(%{"q" => "note"})
    assert assert_patch(view, 1_000) == href, "Enter opens the lit row"
  end

  test "Enter typed before the answer opens the first result once it lands", %{
    conn: conn,
    base: base,
    n: n
  } do
    view = open(conn, base)
    assert has_element?(view, @box), "the list pane has no search box (#{@box})"
    view |> element(@form) |> render_submit(%{"q" => "zebra"})
    path = assert_patch(view, 5_000)
    assert String.ends_with?(path, ";dls-2-#{n}"), "Enter opens Gamma memo: #{path}"
  end

  test "search finds a document past the rows the list has loaded", %{conn: conn, base: base} do
    for i <- 1..105 do
      {:ok, _} =
        Content.create_document(
          @big_type,
          %{"doc_id" => "dlb-#{i}", "title" => "Filler row #{i}"},
          @dataset
        )
    end

    {:ok, _} =
      Content.create_document(
        @big_type,
        %{"doc_id" => "dlb-far", "title" => "Zephyr far"},
        @dataset
      )

    # The far one is the oldest edit, so the newest-first list puts it last.
    earlier = DateTime.add(DateTime.utc_now(), -3600, :second)

    {_, _} =
      Repo.update_all(
        from(d in Document, where: d.type == ^@big_type and d.title == "Zephyr far"),
        set: [updated_at: earlier]
      )

    view = open(conn, base, @big_type)
    loaded = titles(view)
    # Precondition: the list holds its first page, without the far one.
    assert length(loaded) == 100
    refute "Zephyr far" in loaded

    type_in(view, "zephyr")
    assert rows_become(view, ["Zephyr far"]) == ["Zephyr far"], "J24: search reads the whole list"
  end

  test "a save by someone else keeps the list searched", %{conn: conn, base: base} do
    view = open(conn, base)
    type_in(view, "beta")
    assert length(rows_become(view, ["Beta note", "Delta memo"])) == 2

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "dls-new-#{System.unique_integer([:positive])}", "title" => "Omega note"},
        @dataset
      )

    heard? = fn -> MapSet.size(:sys.get_state(view.pid).socket.assigns.stale) > 0 end
    assert wait_for(heard?), "the page never heard of the save"

    send(view.pid, :desk_refresh)
    # Let the refresh's re-read land, then look: the new row matches nothing.
    Process.sleep(200)
    render_async(view, 5_000)

    assert titles(view) == ["Beta note", "Delta memo"],
           "after a live refresh the list still shows only what matches the search"
  end
end
