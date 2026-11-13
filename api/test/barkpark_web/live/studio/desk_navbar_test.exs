defmodule BarkparkWeb.Studio.DeskNavbarTest do
  @moduledoc """
  The Studio top bar on the desk, as the TanStack Studio's navbar (LOOKS PR 5,
  2026-11-13): Structure, Media and API as text tabs, every other tab in one
  More popover at the end. The old Studio's bar is unchanged, and both bars
  carry the same tabs in the same order.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dnb-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "dnb",
        @dataset,
        ["read", "write", "admin"],
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    studio = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, base: studio <> "/_desk", studio: studio}
  end

  defp tabs(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(fn el ->
      frag = LazyHTML.from_fragment(LazyHTML.to_html(el))
      aria = frag |> LazyHTML.attribute("aria-label") |> List.first()
      text = frag |> LazyHTML.text() |> String.trim()
      href = frag |> LazyHTML.attribute("href") |> List.first()
      {if(aria && aria != "", do: aria, else: text), text, href}
    end)
  end

  test "the desk's bar shows Structure, Media and API as text and the rest under More", %{
    conn: conn,
    base: base,
    studio: studio
  } do
    {:ok, view, html} = live(conn, base)

    bar = tabs(html, ~s(#studio-bar .dk-nav > a[data-test-id="top-menu-tab"]))
    assert Enum.map(bar, &elem(&1, 1)) == ["Structure", "Media", "API"]

    # Structure is the desk itself, and the page it is on.
    assert {_, _, ^base} = hd(bar)
    assert has_element?(view, ~s(.dk-nav > a.dk-nav-tab.active[aria-current="page"]), "Structure")

    # The More button opens the popover that holds every other tab.
    assert has_element?(
             view,
             ~s(.dk-nav > button.dk-nav-more[popovertarget="dk-nav-more"][aria-label="More sections"] svg[data-desk-glyph="ellipsis-horizontal"])
           )

    more = tabs(html, ~s(#dk-nav-more[popover] [data-test-id="top-menu-tab"]))
    assert more != [], "an admin has tabs past Structure, Media and API"

    # Every tab keeps its name and its link, in the old bar's order.
    {:ok, _studio_view, studio_html} = live(conn, studio <> "/media")
    old = tabs(studio_html, ~s(#studio-bar [data-test-id="top-menu-tab"]))
    assert Enum.map(bar ++ more, &elem(&1, 0)) == Enum.map(old, &elem(&1, 0))

    # The flat tabs carry `?return_to=` the page they are left from, so only
    # the path before it is compared.
    path = fn href -> href |> String.split("?") |> hd() end

    for {{label, _, href}, {label, _, old_href}} <- Enum.zip(tl(bar) ++ more, tl(old)) do
      assert path.(href) == path.(old_href), label
    end
  end

  # At 640 the bar wrapped to two rows (89 px). Under 900 px TanStack's bar
  # moves its tools into its menu: the desk's More lists the three text tabs
  # first, and the stylesheet hides the bar's own there.
  test "More lists Structure, Media and API first, for a narrow bar", %{conn: conn, base: base} do
    {:ok, _view, html} = live(conn, base)

    bar = tabs(html, ~s(#studio-bar .dk-nav > a.dk-nav-tab))
    narrow = tabs(html, ~s(#dk-nav-more[popover] > a.dk-nav-item.dk-nav-narrow))
    assert narrow == bar
    assert Enum.map(narrow, &elem(&1, 1)) == ["Structure", "Media", "API"]

    first = tabs(html, "#dk-nav-more[popover] > :is(a, span)")
    assert Enum.take(first, 3) == narrow, "the three come first in More"

    # The copies are no tabs of their own: the page's tab set stays one of each.
    copies = html |> LazyHTML.from_document() |> LazyHTML.query(~s(.dk-nav-narrow[data-test-id]))
    assert Enum.count(copies) == 0
  end

  test "the old Studio's bar keeps its icon tabs and has no More", %{conn: conn, studio: studio} do
    {:ok, view, html} = live(conn, studio <> "/media")

    refute has_element?(view, "#studio-bar .dk-nav")
    refute has_element?(view, "#dk-nav-more")
    old = tabs(html, ~s(#studio-bar .studio-bar-tabs > a.studio-tab[data-test-id="top-menu-tab"]))
    assert Enum.all?(old, fn {_, text, _} -> text == "" end), "icon tabs carry no text"
    assert length(old) > 3
  end

  describe "the stylesheet" do
    @css BarkparkWeb.Studio.Desk.Style.sheet(%{}) |> rendered_to_string()

    defp rule(selector) do
      # Every rule with exactly this selector (the tokens and the look are two).
      case Regex.scan(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, @css) do
        [] -> flunk("no rule for #{selector} in the desk stylesheet")
        found -> Enum.map_join(found, " ", fn [_, body] -> body end)
      end
    end

    test "the bar is TanStack's navbar, only where a desk is" do
      bar = rule(".studio-shell:has(.dk) .studio-bar")
      assert bar =~ "height: 52px; min-height: 52px; padding-inline: 12px;"
      assert bar =~ "font-size: 13px; line-height: 19px; font-weight: 500;"
      assert bar =~ "border-bottom: 1px solid var(--dk-nav-border)"

      tab = rule(".studio-shell:has(.dk) .dk-nav .dk-nav-tab")
      assert tab =~ "padding: 3px 8px; border-radius: 3px; color: var(--dk-nav-fg)"
      assert @css =~ "--dk-nav-border: #e3e4e8;"
      assert @css =~ "--dk-nav-bg: #13141b;"
    end

    test "under 900 px the text tabs give way to their copies in More, also on touch" do
      hide = rule(".studio-shell:has(.dk) .dk-nav-more-list .dk-nav-item.dk-nav-narrow")
      assert hide =~ "display: none;"
      assert hide =~ "display: flex;"

      hidden = ".studio-shell:has(.dk) .dk-nav .dk-nav-tab { display: none; }"
      assert @css =~ ~r/@media \(max-width: 899px\) \{\s*#{Regex.escape(hidden)}/

      # After the touch block, whose tabs are inline-flex, or a phone keeps them.
      touch =
        ".studio-shell:has(.dk) .dk-nav .dk-nav-tab { min-height: 44px; display: inline-flex;"

      {coarse, _} = :binary.match(@css, touch)
      {at, _} = :binary.match(@css, hidden)
      assert at > coarse
    end
  end
end
