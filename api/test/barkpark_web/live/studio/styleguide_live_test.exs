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

      categorical =
        (TokensGen.presence_palette() ++
           TokensGen.sheet_cf_backgrounds() ++ TokensGen.sheet_tab_colors())
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

  describe "W2.7 token-adoption regression guards" do
    setup do
      {:ok, root: File.read!(@root_layout)}
    end

    test "GENERATED block emits the evergreen primary for light and dark", %{root: root} do
      # light :root primary + ring are evergreen (design/tokens.json color.primary/ring.light)
      assert root =~ "--primary: hsl(163 46% 22%);"
      assert root =~ "--ring: hsl(163 42% 30%);"
      # dark base is keyed on the data-theme toggle (the emitter extension), not @media
      assert root =~ ~s(html[data-theme="dark"] {)
      assert root =~ "--primary: hsl(160 42% 62%);"
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

      refute root =~ ~s(rel="stylesheet"),
             "no external stylesheet <link> should remain in the Studio root layout"
    end
  end
end
