defmodule BarkparkWeb.Studio.DeskListOrderingsTest do
  @moduledoc """
  J55 (barkpark-studio JOURNEYS.md): schema orderings. The list's "…" menu
  offers the type's own orderings by their titles, and a desk list opens in
  its declared one.

  A type's orderings are its schema's `desk.sortOrderings`; the declared
  order is `desk.orderings` (Sanity's `defaultOrdering`). The menu is
  `[data-desk-list-menu]`; a sort item is `button[phx-click="sort"]` with
  `phx-value-sort=<ordering name>` (empty: the default), `aria-checked` on
  the one in use.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_list_ord_book"
  @menu ~s([data-pane-kind="list"] [data-desk-list-menu])

  # {id, title, year, rating}: each order below puts a different book first.
  @books [
    {"ord-1", "Engines of Thought", 1990, 3},
    {"ord-2", "Binary Tales", 2005, 5},
    {"ord-3", "Cipher Days", 1999, 4},
    {"ord-4", "Atlas Hours", 2010, 1},
    {"ord-5", "Delta Notes", 2001, 2}
  ]
  @by_year ~w(ord-4 ord-2 ord-5 ord-3 ord-1)
  @by_rating ~w(ord-2 ord-3 ord-1 ord-5 ord-4)

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Books",
          "visibility" => "public",
          "desk" => %{
            "orderings" => [%{"field" => "year", "direction" => "desc"}],
            "sortOrderings" => [
              %{
                "name" => "yearDesc",
                "title" => "Year, newest",
                "by" => [%{"field" => "year", "direction" => "desc"}]
              },
              %{
                "name" => "ratingDesc",
                "title" => "Rating, highest",
                "by" => [%{"field" => "rating", "direction" => "desc"}]
              }
            ]
          },
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "year", "title" => "Year", "type" => "number"},
            %{"name" => "rating", "title" => "Rating", "type" => "number"}
          ]
        },
        @dataset
      )

    for {id, title, year, rating} <- @books do
      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"year" => year, "rating" => rating}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: admin(conn), base: base}
  end

  defp admin(conn) do
    raw = "desk-list-ord-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-list-ord", @dataset, ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open_list(conn, base) do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name}")
    render_async(view, 5_000)
    view
  end

  # The list's rows, top to bottom, by document id.
  defp order(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-pane-kind="list"] a[data-desk-row]))
    |> LazyHTML.attribute("href")
    |> Enum.map(&(&1 |> String.split(";") |> List.last() |> String.split(",") |> hd()))
  end

  # A read is async: wait for the order itself.
  defp await_order(view, want, tries \\ 50) do
    render_async(view, 5_000)

    case order(view) do
      ^want -> want
      got when tries == 0 -> got
      _ -> await_order(view, want, tries - 1)
    end
  end

  defp item(sort), do: @menu <> ~s( button[phx-click="sort"][phx-value-sort="#{sort}"])

  test "a desk list opens in its declared ordering", %{conn: conn, base: base} do
    view = open_list(conn, base)
    assert order(view) == @by_year
  end

  test "the list menu offers the type's own orderings by their titles", %{conn: conn, base: base} do
    view = open_list(conn, base)
    assert has_element?(view, item("yearDesc"), "Year, newest")
    assert has_element?(view, item("ratingDesc"), "Rating, highest")
  end

  test "picking an ordering in the list menu reorders the list", %{conn: conn, base: base} do
    view = open_list(conn, base)
    view |> element(item("ratingDesc")) |> render_click()
    assert await_order(view, @by_rating) == @by_rating
  end

  test "the menu marks the declared ordering as the one in use when the list opens", %{
    conn: conn,
    base: base
  } do
    view = open_list(conn, base)
    assert has_element?(view, item("yearDesc") <> ~s([aria-checked="true"]))
    refute has_element?(view, item("ratingDesc") <> ~s([aria-checked="true"]))
  end

  test "Default sort in the menu returns the list to its declared ordering", %{
    conn: conn,
    base: base
  } do
    view = open_list(conn, base)
    view |> element(item("ratingDesc")) |> render_click()
    assert await_order(view, @by_rating) == @by_rating

    view |> element(item("")) |> render_click()
    assert await_order(view, @by_year) == @by_year
  end
end
