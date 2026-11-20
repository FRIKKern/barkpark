defmodule BarkparkWeb.Studio.DeskNavbarWhoMenuTest do
  @moduledoc """
  task-78fe37a4f2bfc752: on a touch phone at 360 px, the desk navbar drew an
  avatar per other person beside your own, and with three others they sat
  over the search button and past the window's edge. The desk's bar now has
  TanStack's "who is here" (`WhoIsOnline`): one button with a dot when
  anyone else is here, and a menu of them. Under 600 px your own presence
  pill gives way, as TanStack's phone bar draws no avatar of yours. The old
  Studio keeps its avatars.

  The browser half (every control in the bar inside the window, none
  overlapping, taps of 44 px, the menu inside the window with a row per
  person, at 360, 375 and 390 with one to five others) was checked in
  Chrome.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.NavbarStyle
  alias BarkparkWeb.StudioComponents.EditorFields

  @dataset "production"
  @type_name "desk_who_menu"
  @button ~s(#presence-hook[phx-hook="PresenceIdentity"] button#dk-who.who)

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk who notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "dwho-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "Alpha who"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    url = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{@type_name};#{id}"

    {:ok, conn: conn, url: url, id: id}
  end

  defp person(conn, name) do
    raw = "desk-who-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-who", @dataset, ["read", "write", "admin"], ws.id)

    conn
    |> Plug.Test.init_test_session(%{"api_token" => raw})
    |> put_connect_params(%{"user_id" => "who-#{name}-#{System.unique_integer([:positive])}"})
  end

  defp open(conn, url) do
    {:ok, view, _html} = live(conn, url)
    render_async(view, 5_000)
    view
  end

  defp eventually(fun),
    do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#dk-who-menu[popover][role="menu"] button.who-row[role="menuitem"]))
  end

  test "with someone else here the bar has one button with a dot, and its menu lists them", c do
    va = open(person(c.conn, "a"), c.url)
    _vb = open(person(BarkparkWeb.ConnCase.scoped_conn(), "b"), c.url)

    assert eventually(fn -> Enum.count(rows(va)) == 1 end)

    assert has_element?(
             va,
             ~s(#{@button}[aria-label="Global presence"][data-tip="Who is here"][aria-haspopup="menu"][popovertarget="dk-who-menu"])
           )

    assert has_element?(va, "#{@button} .who-dot")

    [row] = Enum.to_list(rows(va))
    assert LazyHTML.attribute(row, "phx-click") == ["jump-to-user"]
    assert LazyHTML.attribute(row, "phx-value-doc-id") == [c.id]
    assert row |> LazyHTML.query(".who-doc") |> LazyHTML.text() == "Alpha who"

    # No avatar of theirs in the bar itself.
    refute has_element?(va, ".presence-nav .presence-avatar")
  end

  test "alone, the button has no dot and the menu says no one else is here", c do
    view = open(person(c.conn, "a"), c.url)

    # TanStack's order: who is here, then Help, then the user.
    html = render(view)

    [who, help, user] =
      Enum.map(["id=\"dk-who\"", "id=\"help-menu\"", "id=\"dk-user\""], &:binary.match(html, &1))

    assert elem(who, 0) < elem(help, 0) and elem(help, 0) < elem(user, 0)

    assert has_element?(view, @button)
    refute has_element?(view, "#{@button} .who-dot")
    assert has_element?(view, "#dk-who-menu .who-empty", "No one else is here")

    assert has_element?(
             view,
             "#dk-who-menu .who-empty",
             "Invite people to the project to see their online status."
           )

    assert Enum.count(rows(view)) == 0
  end

  test "someone in no document has a disabled row; the old Studio keeps its avatars" do
    browsing = %{user_id: "u-2", name: "grace", color: "#cc3300", doc_id: nil, type: nil}

    assigns = %{
      user_id: "me-1",
      user_name: "Ada",
      user_color: "#336699",
      presences: [browsing],
      editor_doc: nil,
      dataset: @dataset
    }

    desk =
      render_component(&EditorFields.presence_nav/1, Map.put(assigns, :desk, true))
      |> LazyHTML.from_fragment()

    [row] = desk |> LazyHTML.query("#dk-who-menu .who-row[disabled]") |> Enum.to_list()
    assert LazyHTML.attribute(row, "phx-click") == []
    assert row |> LazyHTML.query(".who-name") |> LazyHTML.text() == "grace"
    assert row |> LazyHTML.query(".avatar") |> LazyHTML.text() |> String.trim() == "G"
    assert row |> LazyHTML.query(".who-doc") |> LazyHTML.text() == "Not in a document"

    studio = render_component(&EditorFields.presence_nav/1, assigns) |> LazyHTML.from_fragment()
    assert studio |> LazyHTML.query(".presence-avatar") |> Enum.count() == 1
    assert studio |> LazyHTML.query("#dk-who") |> Enum.count() == 0
  end

  test "under 600 px your own presence pill gives way in the desk's bar" do
    css = render_component(&NavbarStyle.sheet/1, %{})
    [_, phone] = String.split(css, "@media (max-width: 599px) {", parts: 2)
    phone = phone |> String.split("}\n      }", parts: 2) |> hd()
    assert phone =~ ".studio-shell:has(.dk) .navbar .presence-me-group { display: none; }"
  end
end
