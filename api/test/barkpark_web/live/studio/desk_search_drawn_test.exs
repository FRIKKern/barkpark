defmodule BarkparkWeb.Studio.DeskSearchDrawnTest do
  @moduledoc """
  The desk's search draws its first 40 hits, then more as the list's end
  scrolls near, as the TanStack Studio's (`Search.tsx` `ROWS_STEP`; rig
  search-filters.spec "global search draws its first 40 results, then more
  as the list scrolls"). It asks for 50, as TanStack's text search. The
  desk drew 20 and stopped: the Studio's own search asks for 20.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "dsd_note"
  @options ~s(#desk-search-options [role="option"])

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Drawn notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for n <- 1..55 do
      id = "dsd-#{String.pad_leading("#{n}", 2, "0")}"
      title = "Plenty #{String.pad_leading("#{n}", 2, "0")}"

      {:ok, _} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dsd-token-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "dsd", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp searched(conn, base, q) do
    {:ok, view, _html} = live(conn, base)
    render_async(view, 5_000)
    view |> form("#desk-search-form") |> render_change(%{"value" => q})
    view
  end

  defp drawn(view),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(@options) |> Enum.count()

  defp more?(view),
    do: has_element?(view, ~s(#desk-search-options[phx-viewport-bottom="desk-search-more"]))

  test "the first 40 hits are drawn, then the rest as the end scrolls near", %{conn: c, base: b} do
    view = searched(c, b, "Plenty")

    assert drawn(view) == 40
    assert more?(view), "the list asks for more when its end scrolls near"

    render_hook(view, "desk-search-more", %{})

    assert drawn(view) == 50, "the search asks for 50, as TanStack's text search"
    refute more?(view), "with every hit drawn there is nothing more to ask for"
  end

  test "a new search starts again from its first 40", %{conn: c, base: b} do
    view = searched(c, b, "Plenty")
    render_hook(view, "desk-search-more", %{})
    assert drawn(view) == 50

    view |> form("#desk-search-form") |> render_change(%{"value" => "Plenty 0"})
    assert drawn(view) == 9

    view |> form("#desk-search-form") |> render_change(%{"value" => "Plenty"})
    assert drawn(view) == 40
  end
end
