defmodule BarkparkWeb.Studio.StyleguideLiveTest do
  @moduledoc """
  Guards the unified-aesthetic W2.7 Studio token-adoption edit. Two halves:

    * mount — the admin-gated /studio/styleguide LiveView renders without error
      and paints its swatches with `var(--…)` straight from the GENERATED token
      block (no hand-copied hex). This exercises the whole root.html.heex CSS
      edit through a real render.

    * static regression guards — read root.html.heex directly (same technique as
      the tmux hook-wiring guard) to pin the exact CSS/font contract W2.7 owns:
      evergreen primary is emitted + cascades (no blue/zinc override survives),
      chrome aliases reference emitted tokens, and Inter is self-hosted with the
      fonts.googleapis.com CDN <link> removed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.PortableDoc.Render.Palettes
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.TokensGen

  @admin_token "styleguide-admin-test-token"

  @root_layout "lib/barkpark_web/layouts/root.html.heex"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "styleguide admin", "production", ["read", "write", "admin"])

    {:ok, conn: conn}
  end

  describe "mount" do
    test "admin renders the living style guide without error", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, "/studio/styleguide")

      # swatches are painted from the emitted tokens, never inlined hex
      assert html =~ "var(--primary)"
      assert html =~ "var(--surface)"
      # the top-menu chrome mounted around it (studio layout)
      assert html =~ "studio-tab"
    end

    test "non-admin is redirected off the admin-gated route", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/styleguide")
    end
  end

  describe "living sources (every section renders from a generated source)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, "/studio/styleguide")
      {:ok, view: view, html: html, region: styleguide_region(html)}
    end

    test "palette / status / chrome render via var(--…), not applied hex", %{region: region} do
      # base palette + derived soft tint
      assert region =~ "background: var(--primary)"
      assert region =~ "var(--primary-soft)"
      # status role: solid fill + on-fill foreground pairing
      assert region =~ "background: var(--ok)"
      assert region =~ "color: var(--ok-fg)"
      # zinc/chrome ladder
      assert region =~ "background: var(--bg-accent)"
      assert region =~ "var(--fg-dim)"
    end

    test "type ladder is sized from the emitted --text-* scale (no px literal)", %{region: region} do
      for step <- ~w(2xl xl lg base sm xs) do
        assert region =~ "font-size: var(--text-#{step})"
        assert region =~ "var(--text-#{step}-lh)"
      end
    end

    test "lifecycle row renders from TokensGen.lifecycle/0 + var(--life-*)", %{region: region} do
      # every state's glyph is coloured by the emitted CSS var, never inline hex
      for %{state: state, glyph: glyph} <- TokensGen.lifecycle() do
        assert region =~ "color: var(--life-#{state})"
        assert region =~ glyph
      end

      # braille frames come from the generated frame set
      for f <- TokensGen.lifecycle_frames(), do: assert(region =~ f)

      # the teal done/closed hue is shown as a CONTENT label (allowed) — and the
      # applied-style assertion below proves it is NOT painted inline.
      assert region =~ "#0d9488"
    end

    test "categorical swatches apply generated hex (the documented exception)", %{region: region} do
      # presence + Sheets-CF hex is applied inline straight from TokensGen
      for hex <- TokensGen.presence_palette(), do: assert(region =~ "background: #{hex}")
    end

    # sup-w1 — the control-kit gallery: every interactive control-kit class from
    # root.html.heex rendered as a labelled specimen, so the page doubles as the
    # living control spec a human signs off on (light + dark).
    test "Controls section renders the class-based control-kit specimens", %{region: region} do
      # the section header + its anchor
      assert region =~ ~s(data-test-id="sg-controls")
      assert region =~ ">Controls</h2>"

      # buttons — the variants, enabled + disabled
      assert region =~ ~s(class="btn btn-primary")
      assert region =~ ~s(class="btn btn-ghost")
      assert region =~ ~s(class="btn btn-destructive")
      assert region =~ ~s(class="btn btn-sm")
      assert region =~ ~s(class="btn btn-icon")
      assert region =~ "disabled"

      # inputs — the Controls kit (bp_input/bp_select/bp_textarea) now renders
      # these, so the DOM carries the kit's name=/id=/value= attributes. Pinned
      # in the exact kit attribute order (sup-w3 D22: gallery DOM IS component DOM).
      assert region =~
               ~s(type="text" name="sg-text-input" id="sg-text-input" value="Fleet at a glance" class="form-input")

      assert region =~ ~s(<select name="sg-select" id="sg-select" class="form-input")

      assert region =~
               ~s(<textarea name="sg-textarea" id="sg-textarea" rows="6" class="form-input")

      # bp_select documents BOTH of its non-obvious paths — the prompt affordance
      # (a disabled, value-less lead option) and a nested <optgroup>.
      assert region =~ ~s(<option value="" disabled)
      assert region =~ ~s(<optgroup label="Live">)

      # toggles — checkbox + radio + the labelled switch (track + on/off state)
      assert region =~ ~s(class="form-checkbox")
      assert region =~ ~s(class="form-radio")
      assert region =~ ~s(class="form-switch")
      assert region =~ ~s(class="form-switch-track")
      assert region =~ "form-switch-state"

      # card with its divided header
      assert region =~ ~s(class="card")
      assert region =~ ~s(class="card-header")

      # badge family + the segmented perspective tabs
      assert region =~ ~s(class="badge badge-published")
      assert region =~ ~s(class="badge badge-active")
      assert region =~ ~s(class="perspective-tabs")
      assert region =~ ~s(class="perspective-tab active")

      # every specimen is documented by its class name in muted mono
      assert region =~ ~s(data-test-id="sg-control-group")
    end

    # AC2 — the non-vacuous drift gate. Every hex that appears in an APPLIED style
    # attribute must be a generated CATEGORICAL value; a role colour painted with a
    # literal hex (instead of var(--…)) would land here and fail. Hex-as-CONTENT
    # (the doc value labels) lives outside style="…" and is intentionally allowed.
    test "no role hex is applied inline — only generated categorical hex", %{region: region} do
      applied =
        Regex.scan(~r/style="([^"]*)"/, region)
        |> Enum.flat_map(fn [_, style] ->
          Regex.scan(~r/#[0-9a-fA-F]{6}/, style) |> Enum.map(fn [h] -> String.downcase(h) end)
        end)

      # The mail-chrome showroom rows apply email-skin hex inline (bytes a mail
      # client renders, not CSS vars) — generated + theme-keyed from
      # Palettes.email_skin/1, the same documented exception as the categorical
      # swatches. Whitelist every known theme's skin values.
      mail_hex =
        Tenancy.known_themes()
        |> Enum.flat_map(fn theme -> Map.values(Palettes.email_skin(theme)) end)
        |> Enum.filter(&is_binary/1)
        |> Enum.filter(&String.match?(&1, ~r/^#[0-9a-fA-F]{6}$/))

      categorical =
        (TokensGen.presence_palette() ++
           TokensGen.sheet_cf_backgrounds() ++ TokensGen.sheet_tab_colors() ++ mail_hex)
        |> Enum.map(&String.downcase/1)

      # non-vacuous: the categorical swatches DID apply hex inline
      assert applied != []

      Enum.each(applied, fn hex ->
        assert hex in categorical,
               "applied-style hex #{hex} is not a generated categorical value — role/status/lifecycle colours must render via var(--…)"
      end)
    end
  end

  describe "AC3 — both themes provable from one page" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, "/studio/styleguide")
      {:ok, view: view, html: html}
    end

    test "mounts in light and flips to dark via the wrapper toggle", %{view: view, html: html} do
      # light on mount — the wrapper carries the theme + the SgTheme hook mirrors it
      assert html =~ ~s(data-theme="light")
      assert html =~ "phx-hook=\"SgTheme\""
      assert render(view) =~ "background: var(--primary)"

      # flip → dark, still renders every section
      dark = view |> element("[data-test-id='sg-theme-toggle']") |> render_click()
      assert dark =~ ~s(data-theme="dark")
      assert dark =~ "background: var(--primary)"
      assert dark =~ "var(--text-2xl)"

      # flip back → light
      light = view |> element("[data-test-id='sg-theme-toggle']") |> render_click()
      assert light =~ ~s(data-theme="light")
    end
  end

  # Isolate the styleguide subtree (everything from the wrapper on) so the
  # applied-style scan doesn't see unrelated Studio chrome above it.
  defp styleguide_region(html) do
    case String.split(html, ~s(id="sg-root"), parts: 2) do
      [_, tail] -> tail
      _ -> html
    end
  end

  describe "theme showroom (ts-w5d — every theme × both modes on one screen)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, "/studio/styleguide")
      {:ok, view: view, html: html, region: styleguide_region(html)}
    end

    test "renders one iframe cell per known theme × [light, dark]", %{region: region} do
      themes = Tenancy.known_themes()

      # cell count follows the enumeration — grows to N×2 with no code edit when a
      # theme registers (the zero-edit-growth property).
      cells = Regex.scan(~r/data-test-id="sg-theme-cell"/, region)
      assert length(cells) == length(themes) * 2

      # each theme × mode pairs to a swatch iframe on the admin-gated route
      for theme <- themes, mode <- ~w(light dark) do
        assert region =~ ~s(data-cell-theme="#{theme}" data-cell-mode="#{mode}")
        assert region =~ "/studio/styleguide/swatch?theme=#{theme}&amp;mode=#{mode}"
      end
    end

    test "matrix cells auto-fit their content instead of a fixed-height internal scroll", %{
      region: region
    } do
      # ssp-w1: every swatch iframe is wired to the SgFit hook and starts at a
      # min-height (grown to contentDocument.scrollHeight client-side), with
      # overflow:hidden + scrolling="no" as the no-JS fallback — so no cell
      # scrolls internally. The old hard `height: 340px` is gone.
      assert region =~ ~s(phx-hook="SgFit")
      assert region =~ "min-height: 320px"
      assert region =~ "overflow: hidden"
      assert region =~ ~s(scrolling="no")

      refute region =~ "height: 340px",
             "the fixed 340px swatch height (internal-scroll bug) must be replaced by the SgFit autofit"

      # the hook that does the same-origin fit is defined in the root layout
      root = File.read!(@root_layout)
      assert root =~ "Hooks.SgFit = {"
      assert root =~ "contentDocument"
      assert root =~ "scrollHeight"
    end

    test "mail-chrome row per theme paints generated email_skin hex (no hand-copied hex)", %{
      region: region
    } do
      # one mail row region per theme, and the applied hex is the generated skin
      assert Regex.scan(~r/data-test-id="sg-theme-row"/, region) |> length() ==
               length(Tenancy.known_themes())

      for theme <- Tenancy.known_themes() do
        skin = Palettes.email_skin(theme)
        assert region =~ "background: #{skin.brand}"
        assert region =~ "background: #{skin.page_bg}"
      end
    end
  end

  describe "swatch cell (the iframe target — its own <html data-bp-theme>)" do
    setup %{conn: conn} do
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "admin renders a swatch that forces the requested mode + paints via var(--…)", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/studio/styleguide/swatch?theme=evergreen&mode=dark")

      # the mode is forced client-side (data-theme is otherwise client-owned).
      # BYTE-EXACT form matters: #3545 allow-lists this script by sha256 in
      # BarkparkWeb.CSP (no spaces around =) — keep the assertion in lockstep
      # with CSP.swatch_theme_script/1.
      assert html =~ ~s(document.documentElement.dataset.theme="dark")
      # samples paint through shipped CSS vars, never inline role hex
      assert html =~ "background: var(--primary)"
      assert html =~ "background: var(--ok)"
      assert html =~ "class=\"bp-paper-surface\""
      assert html =~ "var(--paper-ink)"
      # the cell records its identity for the matrix
      assert html =~ ~s(data-swatch-theme="evergreen")
      assert html =~ ~s(data-swatch-mode="dark")
    end

    test "unknown theme / mode degrade to defaults (never 500)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/styleguide/swatch?theme=bogus&mode=sideways")
      assert html =~ ~s(data-swatch-theme="#{Tenancy.default_theme()}")
      assert html =~ ~s(data-swatch-mode="light")
    end

    test "non-admin is redirected off the swatch route", %{conn: _conn} do
      anon = init_test_session(build_conn(), %{})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(anon, "/studio/styleguide/swatch?theme=evergreen&mode=light")
    end
  end

  describe "W2.7 token-adoption regression guards" do
    setup do
      {:ok, root: File.read!(@root_layout)}
    end

    test "GENERATED block emits the evergreen primary for light and dark", %{root: root} do
      # light :root primary + ring are evergreen (design/tokens.json color.primary/ring.light)
      assert root =~ "--primary: hsl(151.96 71.81% 29.22%);"
      assert root =~ "--ring: hsl(163 42% 30%);"
      # dark base is keyed on the data-theme toggle (the emitter extension), not @media
      assert root =~ ~s(html[data-theme="dark"] {)
      assert root =~ "--primary: hsl(152.92 60% 52.94%);"
    end

    test "no hand-authored block re-declares --primary/--ring in the old blue/zinc", %{root: root} do
      refute root =~ "--primary:       hsl(217.2 91.2% 59.8%)",
             "dark --primary must cascade from the GENERATED evergreen, not the old blue override"

      refute root =~ "--primary:       hsl(240 5.9% 10%)",
             "light --primary must cascade from the GENERATED evergreen, not the old zinc override"

      refute root =~ "--ring:          hsl(217.2 91.2% 59.8%)",
             "--ring must cascade from the GENERATED evergreen ring, not the old blue override"
    end

    test "Studio chrome aliases reference emitted tokens, not copied hex", %{root: root} do
      assert root =~ "--fg:            var(--text);"
      assert root =~ "--fg-muted:      var(--muted-text);"
      assert root =~ "--bg-card:       var(--surface);"
      assert root =~ "--bg-muted:      var(--muted-surface);"
      assert root =~ "--destructive:       var(--danger);"
      assert root =~ "--success:       var(--ok);"
      assert root =~ "--success-bg:    var(--ok-soft);"
      assert root =~ "--destructive-bg: var(--danger-soft);"
    end

    test "Inter is self-hosted and the Google Fonts CDN link is gone", %{root: root} do
      assert root =~ "@font-face"
      assert root =~ "url('/fonts/Inter-var.woff2')"
      assert root =~ "font-family: 'Inter'"

      refute root =~ ~s(<link href="https://fonts.googleapis.com),
             "the fonts.googleapis.com CDN stylesheet <link> must be removed (self-hosted Inter)"

      # edit-on-the-link: the layout links exactly ONE stylesheet now — the
      # same-origin editor shell (/assets/bp-paper-editor-shell.css), lifted out
      # of the inline <style> so the public paper reader can link the same bytes.
      # The guard is about OFF-ORIGIN font/CSS CDNs, so it pins the whole list
      # rather than refuting the attribute outright.
      stylesheet_links =
        ~r|<link[^>]*rel="stylesheet"[^>]*>|
        |> Regex.scan(root)
        |> List.flatten()

      assert stylesheet_links == [
               ~s(<link rel="stylesheet" href="/assets/bp-paper-editor-shell.css" />)
             ],
             "the Studio root layout's only stylesheet <link> is the same-origin " <>
               "editor shell; an external/CDN stylesheet must not come back"
    end
  end
end
