defmodule BarkparkWeb.Studio.SettingsFlashSingleSinkTest do
  @moduledoc """
  sup-w5bk — ONE flash sink for the Studio settings surface.

  `SettingsLive` used to render its OWN `role=status` / `role=alert` blocks
  while the `:studio` live layout it mounts under ALSO renders
  `<.studio_flash flash={@flash} />` (nav.ex). One `put_flash/3` therefore
  painted TWO banners and announced TWICE to assistive tech.

  The layout sink is now the single owner. These tests count ELEMENTS with
  `LazyHTML` (the LiveViewTest DOM dep — Floki is not a dependency) rather
  than substring-matching the whole page: the page inlines CSS and style
  attributes, so `html =~ "…"` would happily match a comment or a rule and
  cannot tell one banner from two.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth

  @admin_token "settings-flash-sink-admin-token"
  @settings_path "/w/default/p/default/studio/settings"

  setup %{conn: conn} do
    ensure_default_scope!()

    {:ok, _} =
      Auth.create_token(@admin_token, "flash sink admin", "production", [
        "read",
        "write",
        "admin"
      ])

    conn = init_test_session(conn, %{"api_token" => @admin_token})
    {:ok, view, _html} = live(conn, @settings_path)
    {:ok, view: view}
  end

  # Every element in the rendered document carrying `role`, whose own text
  # contains `msg`. Returned as {role, class, aria_live, text} tuples so a
  # duplicate under EITHER role is counted, not just under the expected one.
  defp announcements(html, msg) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[role]")
    |> Enum.map(fn el ->
      frag = LazyHTML.from_fragment(LazyHTML.to_html(el))

      %{
        role: frag |> LazyHTML.attribute("role") |> List.first(),
        class: frag |> LazyHTML.attribute("class") |> List.first() || "",
        aria_live: frag |> LazyHTML.attribute("aria-live") |> List.first(),
        text: frag |> LazyHTML.text() |> String.trim()
      }
    end)
    |> Enum.filter(&String.contains?(&1.text, msg))
  end

  defp set_theme(view, theme) do
    render_change(element(view, "form[phx-change=set_workspace_theme]"), %{theme: theme})
  end

  describe "a settings action announces EXACTLY ONCE" do
    test "an :info flash paints one polite status region, not two", %{view: view} do
      msg = "Workspace theme set to evergreen"
      html = set_theme(view, "evergreen")

      assert [only] = announcements(html, msg),
             """
             expected EXACTLY ONE element announcing the :info flash, got \
             #{length(announcements(html, msg))}: \
             #{inspect(announcements(html, msg))}
             """

      # …and it is the LAYOUT sink (nav.ex studio_flash), not a page-local copy.
      assert only.role == "status"
      assert only.aria_live == "polite"
      assert only.class =~ "flash-info"
    end

    test "an :error flash paints one assertive alert region, not two", %{view: view} do
      msg = "Unknown theme"
      html = set_theme(view, "forged-9000")

      assert [only] = announcements(html, msg),
             """
             expected EXACTLY ONE element announcing the :error flash, got \
             #{length(announcements(html, msg))}: \
             #{inspect(announcements(html, msg))}
             """

      assert only.role == "alert"
      assert only.aria_live == "assertive"
      assert only.class =~ "flash-error"
    end

    test "the settings body itself renders NO flash element — the layout owns it",
         %{view: view} do
      msg = "Workspace theme set to evergreen"
      _ = set_theme(view, "evergreen")

      body = view |> element("div.settings-live") |> render()

      assert announcements(body, msg) == [],
             "SettingsLive re-grew a page-local flash sink; the :studio layout already owns it"
    end
  end

  describe "dismissal" do
    test "clearing the :info flash removes the single banner", %{view: view} do
      msg = "Workspace theme set to evergreen"
      assert [_only] = announcements(set_theme(view, "evergreen"), msg)

      dismissed = render_click(view, "lv:clear-flash", %{"key" => "info"})

      assert announcements(dismissed, msg) == []
    end

    test "clearing the :error flash removes the single banner", %{view: view} do
      msg = "Unknown theme"
      assert [_only] = announcements(set_theme(view, "forged-9000"), msg)

      dismissed = render_click(view, "lv:clear-flash", %{"key" => "error"})

      assert announcements(dismissed, msg) == []
    end
  end
end
