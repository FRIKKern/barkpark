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
      {:ok, _view, html} = live(conn, "/studio/production")

      # Outer shell + topbar
      assert html =~ ~s|<div class="studio-shell">|
      assert html =~ ~s|<div class="studio-bar">|

      # Brand
      assert html =~ ~s|<div class="sidebar-brand-icon">B</div>|
      assert html =~ ~s|<span style="font-weight: 700; font-size: 15px;">Barkpark</span>|

      # Dataset switcher (rendered when @dataset is assigned)
      assert html =~ ~s|class="dataset-switcher-select"|

      # Nav tabs (Structure active for StudioLive)
      assert html =~ ~s|<a href="/studio/production"| and html =~ "Structure"
      assert html =~ ~s|href="/studio/production/media"|
      # Task barkpark-7xne: the rich `/api-tester` LV was restored after
      # the misjudged route-removal in commit f1e5a21; the "API" tab
      # points back at `/api-tester`.
      assert html =~ ~s|href="/studio/production/api-tester"|

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
      assert html =~ ~s|<div class="sidebar-brand-icon">B</div>|
      assert html =~ ~s|<span style="font-weight: 700; font-size: 15px;">Barkpark</span>|

      # Sign-out form is conditional on @api_token, which the :ops
      # on_mount assigns. It must be present for admin routes too.
      assert html =~ ~s|action="/logout"|
      assert html =~ ~s|aria-label="Sign out"|

      # Page title from BokbasenLive's render — confirms the inner
      # content rendered inside the Studio chrome.
      assert html =~ "Bokbasen Submissions"
    end
  end
end
