defmodule BarkparkWeb.Studio.DeskNavbarDrawerTest do
  @moduledoc """
  The desk navbar's perspective picker and its phone drawer, as the TanStack
  Studio's (`Navbar.tsx` `PerspectivePicker`, `NavDrawer`; barkpark-studio
  `e2e/journeys/navbar.spec.ts` J46 at phone width, J63):

  - the Perspective pill reads Drafts, or Published at `?perspective=published`,
    and its menu's two radios patch the page to the other one, the same URL
    the edit pane's Draft and Published pills switch;
  - "Open menu" opens a dialog named Menu with the tools (the page's own
    current), Help and resources, the appearance and Sign out;
  - the stylesheet shows the drawer's button under 900 px, hides the tools
    and the user menu there, keeps the bar one row under 600 px, and makes
    every target 44 px on a touch screen.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.PerspectivePicker

  @dataset "production"
  @picker ~s(#studio-bar button#dk-perspective[aria-label="Perspective"][popovertarget="dk-perspective-menu"])
  @menu ~s(#studio-bar #dk-perspective-menu[popover][role="menu"])
  @drawer ~s(#studio-bar #dk-drawer-wrap[phx-update="ignore"] dialog#dk-drawer[aria-label="Menu"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "dnd_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Drawer posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-navbar-drawer-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "dnd-me", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     type: type,
     n: n}
  end

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> String.replace(~r/<[^>]+>/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

  describe "the perspective picker" do
    test "reads Drafts, and its menu offers Published and Drafts as radios", %{
      conn: conn,
      base: base
    } do
      {:ok, view, _html} = live(conn, base)

      assert text(view, @picker) == "Drafts"
      assert has_element?(view, @picker <> " .dot.draft-ring")

      published = ~s(#{@menu} button[role="menuitemradio"][data-desk-perspective="published"])
      drafts = ~s(#{@menu} button[role="menuitemradio"][data-desk-perspective="drafts"])

      assert has_element?(
               view,
               published <>
                 ~s([aria-checked="false"][phx-click*='"href":"#{base}?perspective=published"']),
               "Published"
             )

      assert has_element?(
               view,
               drafts <> ~s([aria-checked="true"][phx-click*='"href":"#{base}"']),
               "Drafts"
             )
    end

    test "picking Published patches the page to it, and Drafts back", %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, base)

      view |> element(~s(#{@menu} [data-desk-perspective="published"])) |> render_click()
      assert_patch(view, base <> "?perspective=published")
      assert text(view, @picker) == "Published"

      assert has_element?(
               view,
               ~s(#studio-bar .menu-wrap.perspective[data-perspective="published"])
             )

      assert has_element?(
               view,
               ~s(#{@menu} [data-desk-perspective="published"][aria-checked="true"])
             )

      view |> element(~s(#{@menu} [data-desk-perspective="drafts"])) |> render_click()
      assert_patch(view, base)
      assert text(view, @picker) == "Drafts"
    end

    test "it is the edit pane's perspective: the pane's pills follow the navbar's pick", c do
      id = "dnd-#{c.n}"
      {:ok, _} = Content.create_document(c.type, %{"doc_id" => id, "title" => "P"}, @dataset)
      {:ok, _} = Content.publish_document(id, c.type, @dataset)
      path = "#{c.base}/#{c.type};#{id}"

      {:ok, view, _html} = live(c.conn, path)
      render_async(view, 5_000)
      pill = ~s([data-pane-editing] button.dk-chip[aria-pressed="true"])
      assert view |> element(pill) |> render() =~ "Draft"

      view |> element(~s(#{@menu} [data-desk-perspective="published"])) |> render_click()
      assert_patch(view, path <> "?perspective=published")
      assert view |> element(pill) |> render() =~ "Published"

      # And the pane's pill switches the navbar's.
      view |> element(~s([data-pane-editing] button.dk-chip), "Draft") |> render_click()
      assert_patch(view, path)
      assert text(view, @picker) == "Drafts"
    end

    test "a pick keeps the rest of the query and sets or drops only the perspective" do
      uri = "http://x.test/d/production/studio/_desk/post;a?inspect=history&perspective=published"

      assert PerspectivePicker.href(uri, :drafts) ==
               "/d/production/studio/_desk/post;a?inspect=history"

      assert PerspectivePicker.href(uri, :published) ==
               "/d/production/studio/_desk/post;a?inspect=history&perspective=published"

      assert PerspectivePicker.href("http://x.test/_desk", :published) ==
               "/_desk?perspective=published"

      assert PerspectivePicker.href("http://x.test/_desk?perspective=published", :drafts) ==
               "/_desk"

      assert PerspectivePicker.href(nil, :drafts) == nil
    end
  end

  describe "the drawer" do
    test "Open menu opens a dialog named Menu, before the logo", %{conn: conn, base: base} do
      {:ok, view, html} = live(conn, base)

      assert has_element?(
               view,
               ~s(#studio-bar button#dk-drawer-open[aria-label="Open menu"][aria-haspopup="dialog"][aria-expanded="false"][aria-controls="dk-drawer"])
             )

      assert has_element?(view, @drawer)
      {open, _} = :binary.match(html, ~s(id="dk-drawer-open"))
      {logo, _} = :binary.match(html, ~s(<span class="logo" aria-hidden="true">))
      assert open < logo
    end

    test "it lists the tools, the page's own current, with Help, the appearance and Sign out",
         %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, base)

      tools = ~s(#{@drawer} nav[aria-label="Tools"])

      assert has_element?(
               view,
               tools <> ~s( a.drawer-item.on[aria-current="page"][href="#{base}"]),
               "Structure"
             )

      assert has_element?(view, tools <> " a.drawer-item", "Media")
      assert has_element?(view, tools <> " a.drawer-item", "API")
      refute has_element?(view, tools <> ~s( a[aria-current="page"]), "Media")

      foot = @drawer <> " .drawer-foot"
      assert has_element?(view, foot <> " button[data-desk-drawer-help]", "Help and resources")

      for {value, name} <- [
            {"system", "Use system appearance"},
            {"dark", "Use dark appearance"},
            {"light", "Use light appearance"}
          ] do
        assert has_element?(
                 view,
                 foot <>
                   ~s( button[data-desk-appearance="#{value}"][aria-pressed][aria-label="#{name}"])
               )
      end

      assert has_element?(
               view,
               foot <> ~s( form[action="/logout"] button[type="submit"]),
               "Sign out"
             )

      assert has_element?(
               view,
               ~s(#{@drawer} header button[aria-label="Close menu"][data-desk-drawer-close])
             )
    end
  end

  describe "the stylesheet" do
    @css BarkparkWeb.Studio.Desk.NavDrawerStyle.sheet(%{}) |> rendered_to_string()

    defp block(media) do
      [_, body] = Regex.run(~r/@media #{Regex.escape(media)} \{(.*?)\n\s*\}/s, @css)
      body
    end

    test "under 900 px the drawer's button shows and the tools and the user menu give way" do
      assert @css =~
               ".studio-shell:has(.dk) .navbar .nav-drawer-wrap { display: none; background: none; }"

      narrow = block("(max-width: 899px)")
      assert narrow =~ ".navbar .nav-drawer-wrap { display: flex; }"

      assert narrow =~
               ".navbar .dk-nav, .studio-shell:has(.dk) .navbar #dk-user { display: none; }"
    end

    test "under 600 px the bar is one row, search at the far right and Help in the drawer" do
      phone = block("(max-width: 599px)")
      assert phone =~ ".studio-bar.navbar { display: flex; flex-wrap: nowrap;"
      assert phone =~ ".navbar .studio-bar-brand { display: contents; }"
      assert phone =~ ".navbar .scope-switcher { flex: 1 1 0; min-width: 64px; }"
      assert phone =~ ".navbar .nav-search { order: 3;"
      assert phone =~ ".navbar #dk-help > #help-menu { display: none; }"
    end

    # The pill's ring, as TanStack's: a token the bar itself defines. The
    # document pane's `--dk-line-strong` is not set up here, so it drew none.
    test "the picker's ring is the bar's border token, set in both themes" do
      [picker] = Regex.run(~r/\.navbar \.perspective-picker \{[^}]*\}/, @css)
      assert picker =~ "box-shadow: inset 0 0 0 1px var(--dk-nav-border);"
      refute @css =~ "--dk-line-strong"

      bar = rendered_to_string(BarkparkWeb.Studio.Desk.Style.sheet(%{}))
      assert bar =~ ~r/\.studio-shell:has\(\.dk\) \.studio-bar \{[^}]*--dk-nav-border:/

      assert bar =~
               ~r/html\[data-theme="dark"\] \.studio-shell:has\(\.dk\) \.studio-bar \{[^}]*--dk-nav-border:/
    end

    test "on a touch screen the picker and the drawer's items are 44 px" do
      assert block("(max-width: 768px) and (pointer: coarse)") =~
               ".navbar .perspective-picker { min-height: 44px; }"

      assert block("(pointer: coarse)") =~ ".navbar .drawer-item { min-height: 44px; }"
    end
  end
end
