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
