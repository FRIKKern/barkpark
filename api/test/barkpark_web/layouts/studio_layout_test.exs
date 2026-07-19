defmodule BarkparkWeb.Layouts.StudioLayoutTest do
  @moduledoc """
  Verifies the WI1 Studio layout split: `studio.html.heex` is bound to all
  Studio + admin live_sessions and renders the canonical Studio chrome
  anchors. Per Boss revision, admin/ops routes (e.g. `/admin/bokbasen`)
  also keep the Studio chrome — this guards the Task #9 nav-disappears
  fix.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @admin_token "studio-layout-admin-test-token"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    :ok
  end

  describe "Studio chrome on /studio/:dataset" do
    test "renders all chrome anchors on /studio/production", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      # Outer shell + topbar
      assert html =~ ~s|<div class="studio-shell">|
      assert html =~ ~s|<div class="studio-bar">|

      # Brand (Sanity-style): the WORKSPACE is the identity — its avatar
      # (initial) lives in the scope chip; the standalone "B" square +
      # "Barkpark" wordmark render only when no workspace resolves
      # (StudioChrome gives every studio-layout surface one, so never here).
      assert html =~ ~s|class="scope-avatar"|
      refute html =~ ~s|<div class="sidebar-brand-icon">B</div>|
      assert html =~ ~s|class="scope-switcher"|

      # Scope title (Sanity-style): ONE bar button opens the scope menu; the
      # active dataset rides the title trail as its slug. Markup-only
      # anchors — the page <style> block also mentions .scope-title*.
      assert html =~ ~s|phx-click="scope-menu-toggle"|
      assert html =~ ~r|scope-title-trail">[^<]+<|
      assert html =~ ~r|scope-dataset-badge">production<|

      # Nav tabs (Structure active for StudioLive) — hrefs are scoped (P3)
      assert html =~ ~s|<a href="#{scoped_studio("/d/production/studio")}"| and
               html =~ "Structure"

      assert html =~ ~s|href="#{scoped_studio("/d/production/studio/media")}"|
      # Task barkpark-7xne: the rich `/api-tester` LV was restored after
      # the misjudged route-removal in commit f1e5a21; the "API" tab
      # points back at `/api-tester`.
      assert html =~ ~s|href="#{scoped_studio("/d/production/studio/api-tester")}"|

      # Sign-out form (rendered when @api_token is assigned)
      assert html =~ ~s|action="/logout"|
      assert html =~ ~s|aria-label="Sign out"|
    end
  end

  describe "Studio chrome leaks intentionally to /admin (Task #9 regression guard)" do
    test "renders shell + topbar + brand + sign-out on /admin/onixedit/bokbasen", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      # /admin/bokbasen now 301s to /admin/onixedit/bokbasen (LV moved into
      # the OnixEdit plugin namespace, G3.s4). The chrome guard asserts on the
      # live mount point, which keeps the Studio chrome per the Boss revision.
      {:ok, _view, html} = live(conn, "/admin/onixedit/bokbasen")

      # Studio chrome must be present (Boss revision: admin keeps chrome
      # so the Task #9 nav-disappears fix does not regress).
      assert html =~ ~s|<div class="studio-shell">|
      assert html =~ ~s|<div class="studio-bar">|
      # Workspace avatar carries the brand on admin too (same chrome).
      assert html =~ ~s|class="scope-avatar"|
      assert html =~ ~s|class="scope-switcher"|

      # Sign-out form is conditional on @api_token, which the :ops
      # on_mount assigns. It must be present for admin routes too.
      assert html =~ ~s|action="/logout"|
      assert html =~ ~s|aria-label="Sign out"|

      # Page title from BokbasenLive's render — confirms the inner
      # content rendered inside the Studio chrome.
      assert html =~ "Bokbasen Submissions"
    end
  end

  describe "emitted design tokens in the Studio root layout (au-w2-studio-sweep, W2.6)" do
    # The root layout <style> is rendered on the dead (disconnected) HTTP render,
    # so a plain GET carries the whole generated token block + the swept chrome.
    defp studio_dead_html(conn) do
      conn
      |> init_test_session(%{"api_token" => @admin_token})
      |> get(scoped_studio("/d/production/studio"))
      |> html_response(200)
    end

    test "generated block emits --primary-hover/-hsl/-soft for BOTH light and dark", %{conn: conn} do
      html = studio_dead_html(conn)

      # AC4: both theme scopes render (light :root + dark attribute block).
      assert html =~ ~s|:root {|
      assert html =~ ~s|html[data-theme="dark"] {|

      # AC5: emitted evergreen --primary-hover, both themes (darker in light,
      # lighter in dark). The hand-authored blue --primary-hover is gone.
      assert html =~ "--primary-hover: hsl(151.96 71.81% 23.22%);"
      assert html =~ "--primary-hover: hsl(152.92 60% 60.94%);"
      refute html =~ "--primary-hover: hsl(217.2 91.2% 50%);"
      refute html =~ "--primary-hover: hsl(240 5.9% 22%);"

      # -hsl/-soft machinery so blue accent tints bind to an evergreen soft token.
      assert html =~ "--primary-hsl: 151.96 71.81% 29.22%;"
      assert html =~ "--primary-soft: hsl(var(--primary-hsl) / 0.15);"
      assert html =~ "--primary-hsl: 152.92 60% 52.94%;"
      assert html =~ "--primary-soft: hsl(var(--primary-hsl) / 0.2);"
    end

    test "swept chrome consumes role/status tokens, not primary-blue literals", %{conn: conn} do
      html = studio_dead_html(conn)

      # A few representative migrations (evergreen primary + semantic status).
      assert html =~ ".flash-info { background: var(--info-soft);"
      assert html =~ ".badge-active { background: var(--primary-soft);"
      assert html =~ ".history-action-publish { background: var(--ok-soft);"

      # No primary-role blue channel literal survived in the swept chrome.
      refute html =~ "hsl(217.2 91.2% 59.8% / 0.15)"
      refute html =~ "hsl(217.2 91.2% 59.8% / 0.12)"
    end
  end

  describe "self-update chrome (isu-4)" do
    test "update bar is absent by default (Checker not running in test env)", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      # In test env the SelfUpdate Checker is not supervised, so
      # `SelfUpdate.status/0` reports `state: :disabled` and the bar
      # must not render — even for an admin session.
      refute html =~ ~s|id="bp-update-bar"|
    end

    test "footer renders the build-version span", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      assert html =~ ~s|class="studio-footer"|
      assert html =~ ~s|id="bp-build-version"|
      # BuildInfo yields a dotted version in a git checkout and the
      # literal "unknown" outside one — accept either.
      assert html =~ ~r/Barkpark v(\d+\.\d+[\d.]*|unknown)/
    end
  end
end
