defmodule BarkparkWeb.Studio.DeskListNamesTest do
  @moduledoc """
  The names a desk pane carries in the page, shared with the TanStack Studio
  (`app/src/components/Structure.tsx` in barkpark-studio), so one set of
  journey specs reads both desks (J01, J02, J19, J21, J41).

  Each test is one name: the pane's classes, the list and its rows, and the
  mark on the row of the open document.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_lnames_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Named notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    ids = for i <- 1..3, do: "dln-#{i}-#{n}"

    for id <- ids do
      {:ok, _doc} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => "Note " <> id}, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, ids: ids}
  end

  defp admin(conn) do
    raw = "desk-list-names-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-list-names", @dataset, ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(admin(conn), path)
    render_async(view, 5_000)
    view
  end

  test "a pane is a `pane` of its kind", %{conn: conn, base: base, ids: [id | _]} do
    view = open(conn, "#{base}/#{@type_name};#{id}")

    assert has_element?(view, ~s(section.pane.types[data-pane-index="0"])),
           "the root pane is section.pane.types"

    assert has_element?(view, ~s(section.pane.list[data-pane-index="1"])),
           "a document list is section.pane.list"
  end

  test "a document list scrolls in `.list-rows`, a list named after its pane", %{
    conn: conn,
    base: base
  } do
    view = open(conn, "#{base}/#{@type_name}")
    list = ~s(section.pane.list .pane-body.list-rows [role="list"][aria-label="Named notes"])

    assert has_element?(view, list), "the rows sit in #{list}"

    for pos <- 1..3 do
      row = ~s(#{list} [role="listitem"][aria-posinset="#{pos}"] a[data-desk-row])
      assert has_element?(view, row), "row #{pos} is a listitem that holds its link (#{row})"
    end

    refute has_element?(view, ~s(section.pane.types [role="list"])),
           "the root pane's links are not a document list"
  end

  test "the row of the open document carries data-selected", %{
    conn: conn,
    base: base,
    ids: [first, second | _]
  } do
    view = open(conn, "#{base}/#{@type_name};#{second}")
    list = ~s(section.pane.list)

    assert has_element?(view, ~s(#{list} a[data-desk-row][data-selected][href$=";#{second}"])),
           "the open document's row has data-selected"

    refute has_element?(view, ~s(#{list} a[data-desk-row][data-selected][href$=";#{first}"])),
           "a row that is not open has no data-selected"

    # The mark and aria-current are one fact, in every pane.
    assert has_element?(view, ~s(a[data-desk-row][aria-current="true"])), "a row is current"

    refute has_element?(view, ~s|a[data-desk-row][aria-current="true"]:not([data-selected])|),
           "every current row has data-selected"
  end

  # The specs find a row and a search hit by its title alone
  # (`getByText('Fixture post 12', {exact: true})`, keyboard.spec.ts:59). With
  # the subtitle in the same element as a bare title the element read
  # "Fixture post 12 Post", and no element was the title.
  test "a row's and a search hit's title is an element of its own, beside its subtitle", %{
    conn: conn,
    base: base
  } do
    type = "desk_lnames_kicker"

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Kicker notes",
          "visibility" => "public",
          "list_preview" => %{"subtitle" => "kicker"},
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "kicker", "title" => "Kicker", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dlk-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Kicked note", "kicker" => "Small print"},
        @dataset
      )

    view = open(conn, "#{base}/#{type}")
    row = ~s(section.pane.list a[data-desk-row][href$=";#{id}"])
    assert has_element?(view, row <> " .dk-row-sub", "Small print")
    assert title_of(view, row) == ["Kicked note"]

    view |> form("#desk-search-form") |> render_change(%{"value" => "Kicked note"})
    hit = ~s(#desk-search-hits a[data-desk-hit][href$=";#{id}"])
    render_async(view, 5_000)
    assert has_element?(view, hit <> " .dk-row-sub", "Kicker notes")
    assert title_of(view, hit) == ["Kicked note"]
  end

  # The text of the element that holds only the title, as getByText(exact) reads it.
  defp title_of(view, link) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(link <> " .dk-row-title")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
