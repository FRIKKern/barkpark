defmodule BarkparkWeb.Studio.DeskSearchOptionsTest do
  @moduledoc """
  The desk's search box is a combobox over its hits, as the TanStack Studio's
  (keyboard.spec.ts J19): the focus stays in the box, the hits are options in
  a listbox, the first is lit as they come (`aria-activedescendant`).
  ArrowDown and ArrowUp move the light in the browser with nothing sent
  (`bp-desk.js`, `__desk_search_light.test.mjs`); Enter sends the lit index
  in the form's `lit` field and opens that hit.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "dso_note"
  @input "#desk-search-input"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Option notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for {id, title} <- [{"dso-a", "Optic one"}, {"dso-b", "Optic two"}, {"dso-c", "Optic three"}] do
      {:ok, _} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dso-token-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "dso", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp searched(conn, base, q) do
    {:ok, view, _html} = live(conn, base)
    render_async(view, 5_000)
    view |> form("#desk-search-form") |> render_change(%{"value" => q})
    view
  end

  defp attr(view, selector, name) do
    view
    |> element(selector)
    |> render()
    |> then(&Regex.run(~r/^<[^>]*\s#{name}="([^"]*)"/, &1))
    |> then(&(&1 && List.last(&1)))
  end

  defp lit(view), do: attr(view, @input, "aria-activedescendant")

  defp options(view) do
    view
    |> element(~s(#desk-search-hits [role="listbox"]))
    |> render()
    |> then(&Regex.scan(~r/<a[^>]*role="option"[^>]*>/, &1))
    |> Enum.map(fn [tag] ->
      {Regex.run(~r/id="([^"]+)"/, tag) |> List.last(),
       Regex.run(~r/aria-selected="([^"]+)"/, tag) |> List.last()}
    end)
  end

  test "the box is a combobox, its hits options in a listbox, the first lit", %{
    conn: conn,
    base: base
  } do
    view = searched(conn, base, "optic")

    assert attr(view, @input, "role") == "combobox"
    assert attr(view, @input, "aria-expanded") == "true"
    listbox = attr(view, ~s(#desk-search-hits [role="listbox"]), "id")
    assert attr(view, @input, "aria-controls") == listbox

    assert [{first, "true"}, {_, "false"}, {_, "false"}] = options(view)
    assert lit(view) == first
  end

  test "the keys stay in the browser: the box sends no key event, the form carries the light",
       %{conn: conn, base: base} do
    view = searched(conn, base, "optic")

    assert attr(view, @input, "phx-keydown") == nil
    assert attr(view, "#desk-search-form #desk-search-lit", "name") == "lit"
    assert attr(view, "#desk-search-form #desk-search-lit", "value") == "0"
  end

  test "Enter opens the lit hit", %{conn: conn, base: base} do
    view = searched(conn, base, "optic")
    [_, {second, _}, _] = options(view)
    href = attr(view, "#" <> second, "href")

    # The browser moved the light down one: the form says so.
    view |> form("#desk-search-form") |> render_submit(%{"value" => "optic", "lit" => "1"})
    assert_patch(view, href)
    # Its first field takes the focus once its editor is drawn (`bp-desk.js`).
    assert_push_event(view, "bp:focus-new-doc", %{id: "dso-" <> _})
  end

  test "an empty box is no combobox list: nothing expanded, nothing lit", %{
    conn: conn,
    base: base
  } do
    {:ok, view, _html} = live(conn, base)
    render_async(view, 5_000)
    assert attr(view, @input, "aria-expanded") == "false"
    assert lit(view) == nil
  end

  test "a lit index that is no hit opens the first", %{conn: conn, base: base} do
    view = searched(conn, base, "optic")
    first = attr(view, "#" <> lit(view), "href")

    view |> form("#desk-search-form") |> render_submit(%{"value" => "optic", "lit" => "9"})
    assert_patch(view, first)
  end
end
