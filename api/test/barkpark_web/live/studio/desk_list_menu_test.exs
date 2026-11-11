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
  alias BarkparkWeb.Studio.Desk.Rows

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
    |> then(&Regex.scan(~r/<span class="pane-item-label">\s*([^<\s][^<]*?)\s*</, &1))
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

  test "a pick re-reads the list in that order; Default sort goes back", %{conn: conn, base: base} do
    view = open(sign_in(conn), "#{base}/#{@post}")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]

    pick(view, "Sort by Created")
    assert await_titles(view, ["Beta", "Alpha", "Gamma"]) == ["Beta", "Alpha", "Gamma"]
    assert has_element?(view, ~s([role="menuitemradio"][aria-checked="true"]), "Sort by Created")

    pick(view, "Default sort")
    assert await_titles(view, ["Alpha", "Beta", "Gamma"]) == ["Alpha", "Beta", "Gamma"]
    refute has_element?(view, ~s([role="menuitemradio"][aria-checked="true"]))
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

  test "a sort reads as a Content order, and nothing it cannot read" do
    assert Rows.order("title") == [{:field, "title", :asc}]
    assert Rows.order("updated") == :updated_at_desc
    assert Rows.order("created") == :created_at_desc

    assert Rows.order("rating:desc,author.name:asc") ==
             [{:field, "rating", :desc}, {:field, "author.name", :asc}]

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
