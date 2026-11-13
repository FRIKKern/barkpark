defmodule BarkparkWeb.Studio.DeskListMenuTest do
  @moduledoc """
  A desk list's "…" menu (J25 J55), as the TanStack Studio's: "List options"
  offers the type's own orderings (or its title field), Last Edited, Created
  and Default sort; a pick re-reads the list and sticks per type in the
  editor's `studio.lists` pref, the one the TanStack Studio keeps.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.UserPrefs
  alias BarkparkWeb.Studio.Desk.ListMenu
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"
  @post "dlm_post"
  @note "dlm_note"

  setup %{conn: conn} do
    fields = [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "rating", "title" => "Rating", "type" => "string"}
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @post,
          "title" => "Menu posts",
          "visibility" => "public",
          "fields" => fields,
          "desk" => %{
            "orderings" => [
              %{
                "name" => "ratingDesc",
                "title" => "Rating, highest",
                "field" => "rating",
                "direction" => "desc"
              }
            ]
          }
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @note, "title" => "Menu notes", "visibility" => "public", "fields" => fields},
        @dataset
      )

    # Created in this order; the declared order (rating, highest) is another.
    for {id, title, rating} <- [
          {"dlm-g", "Gamma", "1"},
          {"dlm-a", "Alpha", "3"},
          {"dlm-b", "Beta", "2"}
        ] do
      {:ok, _} =
        Content.create_document(
          @post,
          %{"doc_id" => id, "title" => title, "content" => %{"rating" => rating}},
          @dataset
        )

      Process.sleep(5)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, user} =
      Accounts.register_user(%{
        email: "dlm-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, conn: conn, base: base, ws: Tenancy.get_default_workspace(), user: user}
  end

  # An admin token; with `owner`, an editor's own (the prefs key by it).
  defp sign_in(conn, owner \\ nil) do
    raw = "dlm-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    opts = if owner, do: [owner_user_id: owner.id], else: []

    if owner,
      do: {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, owner.id, "admin", "user")

    {:ok, _} = Auth.create_token(raw, "dlm", @dataset, ["read", "write", "admin"], ws.id, opts)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  defp titles(view) do
    view
    |> element(~s([data-pane-index="1"] .pane-body))
    |> render()
    |> then(&Regex.scan(~r/<span class="dk-row-title">([^<]+?)</, &1))
    |> Enum.map(fn [_, title] -> title end)
  end

  # A pick re-reads the list in its own task: poll for the order itself.
  defp await_titles(view, want, tries \\ 50) do
    render_async(view, 5_000)
    got = titles(view)

    if got == want or tries == 0,
      do: got,
      else: Process.sleep(50) && await_titles(view, want, tries - 1)
  end

  defp pick(view, label) do
    view
    |> element(~s([data-pane-index="1"] [role="menu"] [role="menuitemradio"]), label)
    |> render_click()
  end

  defp items(view) do
    view
    |> element(~s([data-pane-index="1"] [role="menu"]))
    |> render()
    |> then(&Regex.scan(~r/role="menuitemradio"[^>]*>\s*([^<]+?)\s*</, &1))
    |> Enum.map(fn [_, label] -> label end)
  end

  test "List options offers the type's orderings, Last Edited, Created and Default sort", %{
    conn: conn,
    base: base
  } do
    view = open(sign_in(conn), "#{base}/#{@post}")

    assert has_element?(
             view,
             ~s([data-pane-index="1"] .pane-header button[aria-label="List options"][aria-haspopup="menu"][popovertarget])
           )

    assert items(view) == [
             "Sort by Rating, highest",
             "Sort by Last Edited",
             "Sort by Created",
             "Default sort"
           ]

    # A type that declares no orderings: its title field.
    view = open(sign_in(conn), "#{base}/#{@note}")
    assert hd(items(view)) == "Sort by Title"
  end

  defp checked(view) do
    view
    |> element(~s([data-pane-index="1"] [role="menu"]))
    |> render()
    |> then(&Regex.scan(~r/aria-checked="true"[^>]*>\s*([^<]+?)\s*</, &1))
    |> Enum.map(fn [_, label] -> label end)
  end

  @in_use ~s([role="menuitemradio"][aria-disabled="true"][data-tip="Already using the default sort order"])

  # Ruling (c): with no pick, a type that declares orderings reads in its
  # first, as PaneBuilder and the old Studio do, and that choice carries the
  # check; "Default sort" is in use, hoverable for its tip, and clicks nothing.
  test "with no pick, a type's first declared ordering is checked and Default sort is in use", %{
    conn: conn,
    base: base
  } do
    view = open(sign_in(conn), "#{base}/#{@post}")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]
    assert checked(view) == ["Sort by Rating, highest"]

    in_use = ~s([data-pane-index="1"] [role="menu"] ) <> @in_use
    assert has_element?(view, in_use, "Default sort")
    refute has_element?(view, in_use <> "[phx-click]")
    refute has_element?(view, in_use <> "[popovertarget]")

    # Another pick: the default is no longer in use.
    pick(view, "Sort by Created")
    assert await_titles(view, ["Beta", "Alpha", "Gamma"]) == ["Beta", "Alpha", "Gamma"]
    refute has_element?(view, @in_use)
    assert has_element?(view, ~s([role="menuitemradio"][phx-click="sort"]), "Default sort")

    # Picking the default's own choice is the default again.
    pick(view, "Sort by Rating, highest")
    assert has_element?(view, @in_use, "Default sort")
  end

  # Ruling (c): a type that declares no orderings reads by last edit, as the
  # TanStack Studio reads its default ("updated"), and "Sort by Last Edited"
  # carries the check.
  test "with no pick, a type that declares none reads by last edit, and that is checked", %{
    conn: conn,
    base: base
  } do
    for {id, title} <- [{"dlm-n1", "Older"}, {"dlm-n2", "Newer"}] do
      {:ok, _} = Content.create_document(@note, %{"doc_id" => id, "title" => title}, @dataset)
      Process.sleep(5)
    end

    view = open(sign_in(conn), "#{base}/#{@note}")
    assert await_titles(view, ["Newer", "Older"]) == ["Newer", "Older"]
    assert checked(view) == ["Sort by Last Edited"]
    assert has_element?(view, @in_use, "Default sort")

    pick(view, "Sort by Title")
    assert await_titles(view, ["Newer", "Older"]) == ["Newer", "Older"]
    assert checked(view) == ["Sort by Title"]
    refute has_element?(view, @in_use)
  end

  test "the default a list reads in, as a menu sort" do
    menus = ListMenu.menus(@dataset, [])
    assert menus[@post].default == "rating:desc"
    assert menus[@note].default == "updated"

    # A list's own desk node declares its own (or none, an empty list: by last edit).
    node = %{orderings: [%{"field" => "title", "direction" => "asc"}]}
    assert ListMenu.default("rating:desc", node) == "title:asc"
    assert ListMenu.default("rating:desc", %{orderings: []}) == "updated"
    assert ListMenu.default("rating:desc", %{orderings: nil}) == "rating:desc"
    assert ListMenu.default("rating:desc", nil) == "rating:desc"
  end

  test "a pick re-reads the list in that order; Default sort goes back", %{conn: conn, base: base} do
    view = open(sign_in(conn), "#{base}/#{@post}")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]

    pick(view, "Sort by Created")
    assert await_titles(view, ["Beta", "Alpha", "Gamma"]) == ["Beta", "Alpha", "Gamma"]
    assert has_element?(view, ~s([role="menuitemradio"][aria-checked="true"]), "Sort by Created")

    pick(view, "Default sort")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]
    assert checked(view) == ["Sort by Rating, highest"]
  end

  test "a pick sticks across a reload in the editor's studio.lists pref", %{
    conn: conn,
    base: base,
    ws: ws,
    user: user
  } do
    # What the TanStack Studio wrote: an order expression, and a view the desk keeps.
    {:ok, _} =
      UserPrefs.put(user.id, ws.id, @dataset, "studio.lists", %{
        @post => %{"sort" => "title:desc", "view" => "detailed"}
      })

    conn = sign_in(conn, user)
    view = open(conn, "#{base}/#{@post}")
    assert await_titles(view, ["Gamma", "Beta", "Alpha"]) == ["Gamma", "Beta", "Alpha"]

    pick(view, "Sort by Created")
    assert await_titles(view, ["Beta", "Alpha", "Gamma"]) == ["Beta", "Alpha", "Gamma"]

    assert UserPrefs.get(user.id, ws.id, @dataset, "studio.lists") == %{
             @post => %{"sort" => "created", "view" => "detailed"}
           }

    # A reload: the dead render and the connected mount both read it so.
    {:ok, view, html} = live(conn, "#{base}/#{@post}")
    render_async(view, 5_000)
    assert html =~ ~s(aria-checked="true")
    assert await_titles(view, ["Beta", "Alpha", "Gamma"]) == ["Beta", "Alpha", "Gamma"]

    pick(view, "Default sort")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]

    assert UserPrefs.get(user.id, ws.id, @dataset, "studio.lists") == %{
             @post => %{"view" => "detailed"}
           }
  end

  # A list's page read ahead of it (a hover's warm read, or the first render's
  # `ListFirst` hand-off, which is off in :test) is kept for 30 s. The pick
  # re-drew the page, the pane took that page while its sorted read was out,
  # and the list stayed in the old order (list.spec.ts on guerrilla).
  defp hover_open(view, base) do
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => "#{base}/#{@post}"})
    render_async(view, 5_000)

    render_patch(view, "#{base}/#{@post}")

    render_async(view, 5_000)
    view
  end

  test "a pick on a list opened from a read ahead of it re-reads in that order", %{
    conn: conn,
    base: base
  } do
    view = conn |> sign_in() |> open(base) |> hover_open(base)
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]

    pick(view, "Sort by Created")
    assert await_titles(view, ["Beta", "Alpha", "Gamma"]) == ["Beta", "Alpha", "Gamma"]
  end

  test "a list read ahead of it is read in the sort the editor keeps", %{
    conn: conn,
    base: base,
    ws: ws,
    user: user
  } do
    {:ok, _} =
      UserPrefs.put(user.id, ws.id, @dataset, "studio.lists", %{@post => %{"sort" => "created"}})

    view = conn |> sign_in(user) |> open(base) |> hover_open(base)
    assert await_titles(view, ["Beta", "Alpha", "Gamma"]) == ["Beta", "Alpha", "Gamma"]
  end

  test "a type's ordering keeps ties in creation order, as the TanStack Studio's", %{
    conn: conn,
    base: base
  } do
    # Six more of the highest rating, after Alpha: the same rating, created in turn.
    tied = for n <- 1..6, do: "Tied #{n}"

    for title <- tied do
      {:ok, _} =
        Content.create_document(
          @post,
          %{"doc_id" => "dlm-t#{title}", "title" => title, "content" => %{"rating" => "3"}},
          @dataset
        )

      Process.sleep(5)
    end

    view = open(sign_in(conn), "#{base}/#{@post}")
    pick(view, "Sort by Rating, highest")
    want = ["Alpha"] ++ tied ++ ["Beta", "Gamma"]
    assert await_titles(view, want) == want
  end

  test "a pick the type does not offer is ignored: the order stays, nothing is kept", %{
    conn: conn,
    base: base,
    ws: ws,
    user: user
  } do
    view = open(sign_in(conn, user), "#{base}/#{@post}")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]

    # What a page could push for a field the type does not sort by.
    view
    |> element(~s([data-pane-index="1"] [role="menu"] [role="menuitemradio"]), "Sort by Created")
    |> render_click(%{"sort" => "secret_field:asc"})

    Process.sleep(100)
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]
    assert checked(view) == ["Sort by Rating, highest"]
    assert UserPrefs.get(user.id, ws.id, @dataset, "studio.lists") == nil
  end

  test "a kept sort the type does not offer reads in the default order", %{
    conn: conn,
    base: base,
    ws: ws,
    user: user
  } do
    {:ok, _} =
      UserPrefs.put(user.id, ws.id, @dataset, "studio.lists", %{
        @post => %{"sort" => "secret_field:asc"}
      })

    view = open(sign_in(conn, user), "#{base}/#{@post}")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]
    assert checked(view) == ["Sort by Rating, highest"]
  end

  describe "the :list_orders seam (R20)" do
    defp built(opts) do
      {_ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: Tenancy.get_default_workspace().id, project_id: proj.id]

      {panes, _editor} =
        PaneBuilder.build(@dataset, [@post], [scope: scope, scope_prefix: ""] ++ opts)

      list = List.last(panes)
      {for(%{type: :doc} = item <- list.items, do: item.title), Map.delete(list, :items)}
    end

    test "with the key absent or empty the list pane is the same" do
      assert {["Alpha", "Beta", "Gamma"], _} = built([])
      assert built([]) == built(list_orders: %{})
      assert built([]) == built(list_orders: %{"another_type" => :created_at_desc})
    end

    test "an order in it wins over the type's declared order" do
      assert {["Beta", "Alpha", "Gamma"], _} = built(list_orders: %{@post => :created_at_desc})
    end
  end

  test "a sort reads as a Content order, and nothing it cannot read" do
    assert Rows.order("title") == [{:field, "title", :asc}]
    assert Rows.order("updated") == :updated_at_desc
    assert Rows.order("created") == :created_at_desc

    # Ties in creation order, as the TanStack Studio's (`_createdAt:asc`).
    assert Rows.order("rating:desc,author.name:asc") ==
             [{:field, "rating", :desc}, {:field, "author.name", :asc}, :created_at_asc]

    sorts = ["rating:desc", "title:asc", "updated"]
    assert ListMenu.pick("updated", sorts) == "updated"
    assert ListMenu.pick("secret_field:asc", sorts) == nil
    assert ListMenu.pick(nil, sorts) == nil

    for junk <- [
          nil,
          "",
          "rating",
          "rating:up",
          "rat ing:asc",
          "a;b:asc",
          "rating:desc,",
          "1x:asc"
        ] do
      assert Rows.order(junk) == nil, inspect(junk)
    end
  end
end
