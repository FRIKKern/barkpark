defmodule BarkparkWeb.Studio.DeskVisionTest do
  @moduledoc """
  The desk's Vision (`Desk.Vision`, J37 and J46): a tool in the navbar after
  Structure, in More and in the phone drawer, that opens the query tool on
  the desk's own page. The query itself runs in the browser
  (`bp-desk-vision.js`, `__desk_vision.test.mjs`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dvis-token-" <> Ecto.UUID.generate()
    workspace = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "dvis", @dataset, ["read", "write", "admin"], workspace.id)

    prefix = "/w/#{ws.slug}/p/#{proj.slug}"
    studio = prefix <> "/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     prefix: prefix,
     base: studio <> "/_desk",
     vision: studio <> "/_desk/_tools/vision",
     workspace: workspace}
  end

  defp links(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(fn el ->
      frag = LazyHTML.from_fragment(LazyHTML.to_html(el))

      {frag |> LazyHTML.text() |> String.trim(),
       frag |> LazyHTML.attribute("href") |> List.first()}
    end)
  end

  test "the desk's tools carry Vision after Structure: the bar, More and the drawer", c do
    {:ok, view, html} = live(c.conn, c.base)

    bar = links(html, "#studio-bar .dk-nav > a.dk-nav-tab")
    assert Enum.take(bar, 2) == [{"Structure", c.base}, {"Vision", c.vision}]

    narrow = links(html, "#dk-nav-more[popover] > a.dk-nav-narrow")
    assert {"Vision", c.vision} in narrow

    drawer = links(html, ~s(#dk-drawer nav a.drawer-item))
    assert Enum.take(drawer, 2) == [{"Structure", c.base}, {"Vision", c.vision}]

    # The old bar has no Vision: the page's tab set (nav parity) stays as it was.
    refute has_element?(view, ~s(a[data-test-id="top-menu-tab"][href$="/vision"]))

    # On the desk, Structure is the page; Vision is not.
    assert has_element?(view, ~s(.dk-nav > a.dk-nav-tab.active[aria-current="page"]), "Structure")
    refute has_element?(view, ~s(.dk-nav > a.dk-nav-tab[aria-current="page"][href$="/vision"]))
  end

  test "Vision opens the query tool on the desk's page, with the desk's navbar", c do
    {:ok, view, html} = live(c.conn, c.vision)

    assert page_title(view) =~ "Vision"
    assert has_element?(view, "h1", "Vision")

    # Vision is the page now, Structure is not.
    assert has_element?(view, ~s(.dk-nav > a.dk-nav-tab.active[aria-current="page"]), "Vision")
    refute has_element?(view, ~s(.dk-nav > a.dk-nav-tab[aria-current="page"]), "Structure")
    assert has_element?(view, ~s(#dk-drawer nav a.drawer-item.on[aria-current="page"]), "Vision")

    # The query tool in place of the panes; the desk's dialogs stay.
    root = ~s(#desk-panes #dk-vision[phx-update="ignore"][data-desk-vision])
    assert has_element?(view, root)
    refute has_element?(view, "#desk-panes .dk-pane")
    assert has_element?(view, "#dk-search-dialog")

    # It reads the dataset through the scoped /v1/data reads, as the page's own editor.
    assert has_element?(
             view,
             ~s(#dk-vision[data-api="#{c.prefix}/v1/data"][data-dataset="#{@dataset}"])
           )

    # The query, Fetch (and Ctrl/Cmd+Enter), the perspective, the result.
    assert has_element?(view, ~s(label[for="dk-vision-query"]), "Query")

    assert has_element?(
             view,
             ~s(textarea#dk-vision-query[aria-keyshortcuts="Control+Enter Meta+Enter"])
           )

    assert has_element?(view, "#dk-vision button[data-vision-fetch]", "Fetch")
    assert has_element?(view, ~s(#dk-vision section[aria-label="Result"]))
    assert has_element?(view, "#dk-vision [data-vision-ms]", "Execution: n/a")

    options = links(html, "#dk-vision select[data-vision-perspective] option")
    assert Enum.map(options, &elem(&1, 0)) == ["No perspective (raw)", "published", "drafts"]

    assert has_element?(
             view,
             ~s(select[data-vision-perspective] option[value="drafts"][selected])
           )

    # Save result as JSON, the query URL and its copy, hidden until a result.
    assert has_element?(
             view,
             ~s([data-vision-save][hidden] a[download="vision-#{@dataset}.json"]),
             "JSON"
           )

    assert has_element?(view, "[data-vision-url][hidden] input#dk-vision-url[readonly]")

    # How a run went is said (WCAG 4.1.3).
    assert has_element?(view, ~s(#dk-vision [role="status"][data-testid="announcer"]))

    # The script that runs it is the desk hook's to load.
    assert html =~ ~r/data-desk-vision-js="[^"]*bp-desk-vision[^"]*\.js"/
  end

  test "Vision is the desk's: anyone but a workspace admin lands on the Studio", c do
    raw = "dvis-read-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "dvis-read", @dataset, ["read"], c.workspace.id)
    conn = Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, c.vision)
    refute to =~ "_desk"
  end
end
