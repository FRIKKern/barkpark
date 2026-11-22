defmodule BarkparkWeb.Studio.DeskNavbarMenusTest do
  @moduledoc """
  The desk navbar as the TanStack Studio's (J37, J46, J53, B02): the brand
  (the workspace's name as the switcher's button), Help and resources with its version dialog and What's new, and the user menu.
  The switcher offers only the principal's own places and checks a pick
  again on the server. The old Studio's bar keeps its own pieces.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.BuildInfo
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    other_ds = "dnm-other-#{n}"
    {:ok, _} = Tenancy.create_dataset(proj.id, %{slug: other_ds, name: other_ds})

    type = "dnm_post_#{n}"

    for ds <- [@dataset, other_ds] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Navbar posts",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          ds
        )
    end

    # One document in both datasets, one only here.
    {:ok, _} = Content.create_document(type, %{"doc_id" => "both-#{n}", "title" => "B"}, @dataset)
    {:ok, _} = Content.create_document(type, %{"doc_id" => "both-#{n}", "title" => "B"}, other_ds)
    {:ok, _} = Content.create_document(type, %{"doc_id" => "here-#{n}", "title" => "H"}, @dataset)

    # A workspace this token is no member of, with a dataset of its own.
    foreign = TenancyFixtures.create_workspace!("dnm-foreign-#{n}")
    foreign_proj = TenancyFixtures.create_project!(foreign, "fp-#{n}")

    {:ok, _} =
      Tenancy.create_dataset(foreign_proj.id, %{slug: "secret-#{n}", name: "secret-#{n}"})

    raw = "dnm-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "dnm-me", @dataset, ~w(read write admin), ws.id)
    # Someone else's token in the same workspace: never named on this page.
    {:ok, _} =
      Auth.create_token(
        "dnm-x-" <> Ecto.UUID.generate(),
        "dnm-someone-else",
        @dataset,
        ~w(read),
        ws.id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    studio = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     ws: ws,
     proj: proj,
     n: n,
     type: type,
     other_ds: other_ds,
     foreign: foreign,
     foreign_proj: foreign_proj,
     studio: studio,
     base: studio <> "/_desk"}
  end

  describe "the brand and the tools" do
    test "the bar is TanStack's .navbar: the logo, the workspace's name as the switcher", c do
      {:ok, view, _html} = live(c.conn, c.base)

      assert has_element?(view, "#studio-bar.navbar .studio-bar-brand > .logo")
      assert has_element?(view, ".navbar .scope-button .brand-name", c.ws.name)

      label = "Workspace #{c.ws.slug}, project #{c.proj.slug}, dataset #{@dataset}. Switch"

      assert has_element?(
               view,
               ~s(.navbar button.scope-button[aria-haspopup="dialog"][aria-label="#{label}"])
             )

      # The desk's Vision tool (`Desk.Vision`, `DeskVisionTest`) is a tool link.
      assert has_element?(view, ~s([role="navigation"] a[href$="/_desk/_tools/vision"]), "Vision")
    end

    test "the old Studio keeps its own bar: no .navbar, the old switcher, the theme toggle and Sign out",
         c do
      {:ok, view, html} = live(c.conn, c.studio <> "/media")

      assert html =~ ~s(<div class="studio-bar" id="studio-bar")
      refute has_element?(view, ".navbar")
      refute has_element?(view, "#user-menu")
      refute has_element?(view, "#help-menu")
      assert has_element?(view, "#scope-switcher")
      assert has_element?(view, "#studio-theme-toggle")
      assert has_element?(view, ~s(form[action="/logout"] button[aria-label="Sign out"]))
    end
  end

  describe "the user menu" do
    test "#user-menu opens who you are, the appearance as radios and a sign out that POSTs with CSRF",
         c do
      {:ok, view, html} = live(c.conn, c.base)

      assert has_element?(
               view,
               ~s(#user-menu.icon-btn.user-btn[aria-label="Open user menu"][aria-haspopup="menu"][popovertarget="dk-user-menu"])
             )

      menu =
        ~s(#dk-user[phx-update="ignore"] #dk-user-menu[popover][role="menu"][aria-labelledby="user-menu"])

      assert has_element?(view, menu)

      for name <- ["Use system appearance", "Use dark appearance", "Use light appearance"] do
        assert has_element?(
                 view,
                 ~s(#{menu} [role="menuitemradio"][aria-label="#{name}"][aria-checked])
               )
      end

      # Sign out is the Studio's own: a POST to /logout carrying the CSRF token.
      assert has_element?(
               view,
               ~s(#{menu} form[action="/logout"][method="post"] input[name="_csrf_token"])
             )

      assert has_element?(
               view,
               ~s(#{menu} form[action="/logout"] button[type="submit"][role="menuitem"]),
               "Sign out"
             )

      # Who you are: this token, its role here; nobody else.
      assert has_element?(view, "#{menu} .user-name", "dnm-me")
      assert has_element?(view, "#{menu} .user-role")
      refute html =~ "dnm-someone-else"

      # The old bar's theme toggle and sign-out button are the menu's now.
      refute has_element?(view, "#studio-theme-toggle")

      refute has_element?(
               view,
               ~s(.studio-bar-right > .studio-bar-actions form[action="/logout"])
             )
    end

    test "an account is named by its name and email" do
      user = %Barkpark.Accounts.User{display_name: "Kari Admin", email: "kari@example.test"}

      assert %{name: "Kari Admin", email: "kari@example.test", role: nil} =
               BarkparkWeb.Studio.Desk.UserMenu.me(%{current_user: user})

      assert BarkparkWeb.Studio.Desk.UserMenu.me(%{}) == nil
    end
  end

  describe "Help and resources" do
    test "the menu names this build, opens the version dialog and What's new, and links the changelog",
         c do
      {:ok, view, _html} = live(c.conn, c.base)

      assert has_element?(
               view,
               ~s(#help-menu.icon-btn[aria-label="Help and resources"][data-tip="Help and resources"][popovertarget="dk-help-menu"])
             )

      wrap = ~s(#dk-help[phx-update="ignore"][data-build="#{BuildInfo.commit()}"])
      assert has_element?(view, wrap)
      menu = ~s(#{wrap} #dk-help-menu[popover][role="menu"])

      assert has_element?(
               view,
               ~s(#{menu} [role="menuitem"][data-desk-version]),
               "Barkpark Studio"
             )

      assert has_element?(
               view,
               ~s(#{menu} [data-desk-version] [data-desk-version-state]),
               "Up to date"
             )

      assert has_element?(
               view,
               ~s(#{menu} a[role="menuitem"][href^="https://github.com/"]),
               "Changelog"
             )

      assert has_element?(
               view,
               ~s(#{menu} a[role="menuitem"][href*="/issues/new"]),
               "Report a problem"
             )

      assert has_element?(
               view,
               ~s(#{menu} [role="menuitem"][data-desk-nav-dialog="dk-whats-new"]),
               "What's new"
             )

      assert has_element?(
               view,
               ~s(dialog#dk-version-dialog[aria-label="Studio version"]),
               "Up to date"
             )

      assert has_element?(
               view,
               ~s(dialog#dk-version-dialog button[data-desk-nav-dialog-close]),
               "OK"
             )

      assert has_element?(
               view,
               ~s(dialog#dk-whats-new[aria-label="What's new"] a[href^="https://github.com/"]),
               "Full changelog"
             )

      # Its own attribute: `data-desk-dialog` marks an open document dialog.
      refute has_element?(view, "[data-desk-dialog]")

      # The script that opens them and asks for a newer build, for the first load.
      assert has_element?(view, ~s(#{wrap} script[data-desk-navbar][src*="bp-desk-navbar.js"]))
    end

    test "GET /api/version answers the build, and nothing else", %{conn: conn} do
      body = conn |> get("/api/version") |> json_response(200)
      assert body == %{"build" => BuildInfo.commit()}
    end
  end

  describe "the workspace, project and dataset switcher" do
    defp open_switcher(view) do
      view |> element(".navbar button.scope-button") |> render_click()

      assert has_element?(
               view,
               ~s(#dk-scope-card.scope-popover[role="dialog"][aria-label="Switch workspace, project or dataset"] .scope-place)
             )

      view
    end

    test "it lists where you are first and checked, your own places only, and closes in the browser",
         c do
      {:ok, view, _html} = live(c.conn, c.base)

      # The card is a popover: the browser opens it at once and closes it on a
      # click outside and on Escape. Its places are read when it first opens.
      assert has_element?(
               view,
               ~s(#dk-scope-button[popovertarget="dk-scope-card"][phx-click="desk-scope-load"])
             )

      assert has_element?(view, ~s(#dk-scope-card[popover][role="dialog"]))
      refute has_element?(view, ".scope-place")
      open_switcher(view)

      first = ".scope-popover section:first-of-type"
      assert has_element?(view, ~s(#{first}[aria-label="#{c.ws.name} / #{c.proj.name}"]))

      assert has_element?(
               view,
               ~s(#{first} .scope-place[aria-current="true"] .scope-place-title),
               @dataset
             )

      assert has_element?(
               view,
               ~s|#{first} .scope-place:not([aria-current]) .scope-place-title|,
               c.other_ds
             )

      assert has_element?(view, ~s(#{first} .scope-place-sub), "#{c.ws.slug} / #{c.other_ds}")

      assert view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query(~s(.scope-place[aria-current="true"]))
             |> Enum.count() == 1

      # A workspace this token is no member of is not offered.
      refute render(view) =~ "secret-#{c.n}"
      refute render(view) =~ c.foreign.slug
    end

    test "a pick opens the same panes there, as far as the target has them", c do
      {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};both-#{c.n}")
      render_async(view, 5_000)

      # A document row is TanStack's `pane-item` (the B02 journey follows one).
      assert has_element?(
               view,
               ~s(a.pane-item[data-testid="pane-item"][href="#{c.base}/#{c.type};here-#{c.n}"])
             )

      open_switcher(view)

      target = "/w/#{c.ws.slug}/p/#{c.proj.slug}/d/#{c.other_ds}/studio/_desk"

      assert {:error, {:redirect, %{to: to}}} =
               view
               |> element(~s(.scope-place[phx-value-ds="#{c.other_ds}"]))
               |> render_click()

      assert to == "#{target}/#{c.type};both-#{c.n}"

      # A document that is not there closes; its list stays.
      {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};here-#{c.n}")
      open_switcher(view)

      assert {:error, {:redirect, %{to: ^target <> "/" <> _ = to}}} =
               view
               |> element(~s(.scope-place[phx-value-ds="#{c.other_ds}"]))
               |> render_click()

      assert to == "#{target}/#{c.type}"
    end

    test "a forged pick of a place the principal cannot reach is refused on the server", c do
      {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type}")
      open_switcher(view)

      html =
        render_click(view, "desk-scope-go", %{
          "ws" => c.foreign.slug,
          "proj" => c.foreign_proj.slug,
          "ds" => "secret-#{c.n}"
        })

      assert html =~ "Could not open that place"
      # Nothing of that place is shown, and the page stays where it was.
      refute html =~ "secret-#{c.n}"

      # Nor a dataset that is not in the project.
      render_click(view, "desk-scope-go", %{
        "ws" => c.ws.slug,
        "proj" => c.proj.slug,
        "ds" => "nope-#{c.n}"
      })

      assert render(view) =~ "Could not open that place"
    end

    test "a dataset-bound token sees the others greyed and cannot go there", c do
      raw = "dnm-bound-" <> Ecto.UUID.generate()

      {:ok, _} =
        Auth.create_token(raw, "dnm-bound", @dataset, ~w(read write admin), c.ws.id,
          dataset_bound: true
        )

      conn = Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})
      {:ok, view, _html} = live(conn, c.base)
      open_switcher(view)

      assert has_element?(view, ~s(.scope-place[phx-value-ds="#{c.other_ds}"][disabled]))
      refute has_element?(view, ~s(.scope-place[phx-value-ds="#{@dataset}"][disabled]))

      assert has_element?(
               view,
               ".scope-note",
               "This token can only open the dataset #{@dataset}."
             )

      html =
        render_click(view, "desk-scope-go", %{
          "ws" => c.ws.slug,
          "proj" => c.proj.slug,
          "ds" => c.other_ds
        })

      assert html =~ "Could not open that place"
    end
  end
end
