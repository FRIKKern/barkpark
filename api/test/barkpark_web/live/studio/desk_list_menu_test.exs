defmodule BarkparkWeb.Studio.DeskListMenuTest do
  @moduledoc """
  J25 (barkpark-studio JOURNEYS.md): the list's "…" menu sorts by created or
  last edited and switches compact / detailed view, and both stick per type.

  Controls named here, for the builder:

    * the menu: `[data-desk-list-menu]` in the list pane, opened by
      `button[aria-label="List options"]`;
    * a sort item: `button[phx-click="sort"][phx-value-sort=<name>]`, the
      pane's existing `"sort"` event and `%{"sort" => name}` payload;
      `updated` is Sanity's "Sort by Last Edited", `created` its "Sort by
      Created", `aria-checked="true"` on the one in use;
    * a layout item: `button[phx-click="view"][phx-value-view=compact|detailed]`;
    * the pane body says its layout: `[data-desk-view="compact|detailed"]`.

  Stickiness is asked with the `"sort"` event sent to the list pane itself,
  so those tests do not depend on the menu's markup.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_list_menu_book"
  @other "desk_list_menu_film"
  @list ~s([data-pane-kind="list"])
  @menu @list <> " [data-desk-list-menu]"

  # {id, title, rating, created hours ago, last edited hours ago}
  @books [
    {"lm-1", "Engines of Thought", 3, 50, 2},
    {"lm-2", "Binary Tales", 5, 40, 9},
    {"lm-3", "Cipher Days", 4, 30, 0},
    {"lm-4", "Atlas Hours", 1, 20, 7},
    {"lm-5", "Delta Notes", 2, 10, 1}
  ]
  # Declared order: title ascending. Each order below starts with another book.
  @by_title ~w(lm-4 lm-2 lm-3 lm-5 lm-1)
  @by_edited ~w(lm-3 lm-5 lm-1 lm-4 lm-2)
  @by_created ~w(lm-5 lm-4 lm-3 lm-2 lm-1)
  @by_rating ~w(lm-2 lm-3 lm-1 lm-5 lm-4)

  setup %{conn: conn} do
    for {name, title, prefix} <- [{@type_name, "Books", "lm"}, {@other, "Films", "fm"}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => title,
            "visibility" => "public",
            "desk" => %{
              "orderings" => [%{"field" => "title", "direction" => "asc"}],
              # The same ordering name on both types: a pick on one is not the other's.
              "sortOrderings" => [
                %{
                  "name" => "ratingDesc",
                  "title" => "Rating, highest",
                  "by" => [%{"field" => "rating", "direction" => "desc"}]
                }
              ]
            },
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "rating", "title" => "Rating", "type" => "number"}
            ]
          },
          @dataset
        )

      for {id, doc_title, rating, created, edited} <- @books do
        id = String.replace_prefix(id, "lm", prefix)

        {:ok, _} =
          Content.create_document(
            name,
            %{"doc_id" => id, "title" => doc_title, "content" => %{"rating" => rating}},
            @dataset
          )

        Repo.query!(
          "UPDATE documents SET inserted_at = $1, updated_at = $2 WHERE doc_id = $3",
          [hours_ago(created), hours_ago(edited), id]
        )
      end
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: conn, base: base}
  end

  defp hours_ago(h), do: DateTime.add(DateTime.utc_now(), -h * 3_600 - 60, :second)

  defp admin(conn) do
    raw = "desk-list-menu-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-list-menu", @dataset, ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  # One editor (a token owned by an account), so a pref has someone to belong to.
  defp editor(conn) do
    ws = Tenancy.get_default_workspace()
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "desk-list-menu-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "admin", "user")
    raw = "desk-list-menu-owned-#{n}"

    {:ok, _} =
      Auth.create_token(raw, "desk-list-menu", @dataset, ~w(read write admin), ws.id,
        owner_user_id: user.id
      )

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  # The list's rows, top to bottom, by document id.
  defp order(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(@list <> " a[data-desk-row]")
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

  # The list pane's own "sort" event, whatever control sends it.
  defp sort(view, name) do
    view |> with_target(@list) |> render_hook("sort", %{"sort" => name})
    render_async(view, 5_000)
  end

  defp item(attr, value),
    do: @menu <> ~s( button[phx-click="#{attr}"][phx-value-#{attr}="#{value}"])

  test "the list header has a … menu with sort by last edited, created, and the two layouts", %{
    conn: conn,
    base: base
  } do
    view = open(admin(conn), "#{base}/#{@type_name}")
    assert order(view) == @by_title

    assert has_element?(view, @menu <> ~s( button[aria-label="List options"]))
    assert has_element?(view, item("sort", "updated"))
    assert has_element?(view, item("sort", "created"))
    assert has_element?(view, item("view", "compact"))
    assert has_element?(view, item("view", "detailed"))
  end

  test "sort by last edited lists the most recently edited first", %{conn: conn, base: base} do
    view = open(admin(conn), "#{base}/#{@type_name}")
    sort(view, "updated")
    assert await_order(view, @by_edited) == @by_edited
  end

  test "sort by created lists the newest first", %{conn: conn, base: base} do
    view = open(admin(conn), "#{base}/#{@type_name}")
    sort(view, "created")
    assert await_order(view, @by_created) == @by_created
  end

  test "the menu marks the sort in use", %{conn: conn, base: base} do
    view = open(admin(conn), "#{base}/#{@type_name}")
    sort(view, "ratingDesc")
    assert await_order(view, @by_rating) == @by_rating

    assert has_element?(view, item("sort", "ratingDesc") <> ~s([aria-checked="true"]))
    refute has_element?(view, item("sort", "updated") <> ~s([aria-checked="true"]))
  end

  test "a list opens compact; detailed view and back to compact switch its layout", %{
    conn: conn,
    base: base
  } do
    view = open(admin(conn), "#{base}/#{@type_name}")
    assert has_element?(view, @list <> ~s( [data-desk-view="compact"]))

    view |> element(item("view", "detailed")) |> render_click()
    assert has_element?(view, @list <> ~s( [data-desk-view="detailed"]))

    view |> element(item("view", "compact")) |> render_click()
    assert has_element?(view, @list <> ~s( [data-desk-view="compact"]))
  end

  test "a sort stays while a document opens beside the list", %{conn: conn, base: base} do
    view = open(admin(conn), "#{base}/#{@type_name}")
    sort(view, "ratingDesc")
    assert await_order(view, @by_rating) == @by_rating

    view |> element(@list <> ~s( a[data-desk-row][href$=";lm-5"])) |> render_click()
    assert_patch(view, "#{base}/#{@type_name};lm-5")
    assert await_order(view, @by_rating) == @by_rating
  end

  test "a sort stays when the list is closed and opened again", %{conn: conn, base: base} do
    view = open(admin(conn), "#{base}/#{@type_name}")
    sort(view, "ratingDesc")
    assert await_order(view, @by_rating) == @by_rating

    render_patch(view, base)
    refute has_element?(view, @list)
    render_patch(view, "#{base}/#{@type_name}")
    assert await_order(view, @by_rating) == @by_rating
  end

  test "a sort survives a reload, for the same editor", %{conn: conn, base: base} do
    conn = editor(conn)
    view = open(conn, "#{base}/#{@type_name}")
    # Precondition: this editor's desk draws the list, in its declared order.
    assert order(view) == @by_title
    sort(view, "ratingDesc")
    assert await_order(view, @by_rating) == @by_rating

    reloaded = open(conn, "#{base}/#{@type_name}")
    assert await_order(reloaded, @by_rating) == @by_rating
  end

  test "a layout survives a reload, for the same editor", %{conn: conn, base: base} do
    conn = editor(conn)
    view = open(conn, "#{base}/#{@type_name}")
    view |> element(item("view", "detailed")) |> render_click()
    assert has_element?(view, @list <> ~s( [data-desk-view="detailed"]))

    reloaded = open(conn, "#{base}/#{@type_name}")
    assert has_element?(reloaded, @list <> ~s( [data-desk-view="detailed"]))
  end

  test "a sort is the type's own: another type's list keeps its declared order", %{
    conn: conn,
    base: base
  } do
    conn = admin(conn)
    view = open(conn, "#{base}/#{@type_name}")
    sort(view, "ratingDesc")
    assert await_order(view, @by_rating) == @by_rating

    films = Enum.map(@by_title, &String.replace_prefix(&1, "lm", "fm"))
    render_patch(view, "#{base}/#{@other}")
    assert await_order(view, films) == films
  end
end
