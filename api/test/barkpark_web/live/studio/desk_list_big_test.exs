defmodule BarkparkWeb.Studio.DeskListBigTest do
  @moduledoc """
  J41: a desk list longer than a page grows as it is scrolled, as the
  TanStack Studio's (and Sanity's) list does: the last row reaching the
  bottom reads the next 100 below the rows it holds, up to 2,000, and then
  the list says "Displaying a maximum of 2000 documents".

  The next page is read by offset (`:list_offsets`, ruling R9), never by
  reading the whole list again with a bigger limit, which the query layer
  stops at 1,000.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"
  @type_name "dlb_item"
  @count 2_050

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Big items",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Each one edited a second before the next: the list's newest-first
    # order is the reverse of their numbers, and no two rows tie.
    rows =
      for i <- 1..@count do
        at = DateTime.add(now, i - @count, :second)
        num = String.pad_leading("#{i}", 4, "0")

        %{
          doc_id: "dlb-#{num}",
          type: @type_name,
          dataset: @dataset,
          workspace_id: ws.id,
          project_id: proj.id,
          title: "Big item #{num}",
          status: "published",
          content: %{"title" => "Big item #{num}"},
          rev: "rev-dlb-#{num}",
          inserted_at: at,
          updated_at: at
        }
      end

    for chunk <- Enum.chunk_every(rows, 500), do: Repo.insert_all(Document, chunk)

    raw = "dlb-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "dlb",
        @dataset,
        ["read", "write", "admin"],
        Tenancy.get_default_workspace().id
      )

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     scope: [workspace_id: ws.id, project_id: proj.id]}
  end

  defp built_titles(scope, opts) do
    opts = [scope: scope, scope_prefix: ""] ++ opts
    {panes, _editor} = PaneBuilder.build(@dataset, [@type_name], opts)
    for %{type: :doc} = item <- List.last(panes).items, do: item.title
  end

  test "the list read pages by offset; with no offset the page is the same", %{scope: scope} do
    first_200 = built_titles(scope, list_limits: %{@type_name => 200})
    assert length(first_200) == 200

    assert built_titles(scope, list_limits: %{@type_name => 100}) == Enum.take(first_200, 100)

    assert built_titles(scope, list_limits: %{@type_name => 100}, list_offsets: %{}) ==
             Enum.take(first_200, 100)

    assert built_titles(scope,
             list_limits: %{@type_name => 100},
             list_offsets: %{@type_name => 0}
           ) ==
             Enum.take(first_200, 100)

    # Rows 101 to 200 of the same order.
    assert built_titles(scope,
             list_limits: %{@type_name => 100},
             list_offsets: %{@type_name => 100}
           ) ==
             Enum.drop(first_200, 100)
  end

  test "a list holding more than the query layer reads at once reads it page after page", %{
    scope: scope
  } do
    read = Rows.read(@type_name, %{path: [@type_name], limit: 2_000, sort: nil}, @dataset, scope)
    assert length(read.entries) == 2_000
    assert read.more? == true
    assert hd(read.entries).title == "Big item 2050"
    assert List.last(read.entries).title == "Big item 0051"
    assert read.entries |> Enum.map(& &1.title) |> Enum.uniq() |> length() == 2_000
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  @list ~s([data-pane-index="1"] [role="list"])

  defp rows(view),
    do: view |> render() |> then(&Regex.scan(~r/aria-posinset="(\d+)"/, &1)) |> length()

  # Each page is read in its own task: wait for the rows themselves.
  defp await_rows(view, want, tries \\ 100) do
    render_async(view, 5_000)
    got = rows(view)

    if got == want or tries == 0,
      do: got,
      else: Process.sleep(20) && await_rows(view, want, tries - 1)
  end

  defp scroll_to_bottom(view),
    do: view |> element(@list <> ~s([phx-viewport-bottom="more"])) |> render_hook("more", %{})

  test "scrolling to the bottom grows the list a page at a time up to 2,000, then says so", %{
    conn: conn,
    base: base
  } do
    view = open(conn, "#{base}/#{@type_name}")
    assert await_rows(view, 100) == 100
    refute has_element?(view, "[data-pane-index=\"1\"] .dk-list-max")

    for want <- 200..2_000//100 do
      scroll_to_bottom(view)
      assert await_rows(view, want) == want
    end

    # Newest first, each row once, the 2,000th the 51st oldest.
    html = view |> element(@list) |> render()
    assert html =~ ~s(aria-posinset="2000")
    refute html =~ ~s(aria-posinset="2001")
    assert html =~ "Big item 0051"
    refute html =~ "Big item 0050"

    assert has_element?(
             view,
             ~s([data-pane-index="1"] .dk-list-max),
             "Displaying a maximum of 2000 documents"
           )

    # At the most it holds, a scroll to the bottom reads nothing more.
    scroll_to_bottom(view)
    Process.sleep(100)
    assert await_rows(view, 2_000) == 2_000
  end

  test "a list that ends before 2,000 grows to its end and says nothing", %{
    conn: conn,
    base: base
  } do
    Repo.delete_all(from d in Document, where: d.type == @type_name and d.doc_id > "dlb-0150")

    view = open(conn, "#{base}/#{@type_name}")
    assert await_rows(view, 100) == 100
    scroll_to_bottom(view)
    assert await_rows(view, 150) == 150
    scroll_to_bottom(view)
    Process.sleep(100)
    assert await_rows(view, 150) == 150
    refute has_element?(view, "[data-pane-index=\"1\"] .dk-list-max")
  end
end
