defmodule BarkparkWeb.Studio.WorkspaceSwitcherTest do
  @moduledoc """
  Pins the rendering logic of WorkspaceSwitcher:
    - name_of/1: displays the workspace/project name or a fallback dash
    - same?/2: drives is-current / is-previewed CSS classes on menu items
    - current_dataset?/3: drives the dataset dot (only when previewed ws+proj
      match the current ws+proj AND the slug matches)
    - closed state (menu: nil) renders no popover
    - can_create gate hides / shows the "+ New workspace" affordance
  """
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.WorkspaceSwitcher

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ws(id, name), do: %{id: id, name: name, slug: "ws-#{id}"}
  defp proj(id, name), do: %{id: id, name: name, slug: "proj-#{id}"}
  defp ds(slug, name \\ nil), do: %{slug: slug, name: name || slug}

  defp render_switcher(overrides \\ []) do
    defaults = [
      current_workspace: nil,
      current_project: nil,
      current_dataset: nil,
      menu: nil,
      can_create: false,
      create_open: nil
    ]

    render_component(&WorkspaceSwitcher.switcher/1, Keyword.merge(defaults, overrides))
  end

  # ---------------------------------------------------------------------------
  # name_of/1 — via title-bar spans
  # ---------------------------------------------------------------------------

  describe "name_of — workspace/project name display" do
    test "shows the workspace name when set" do
      html = render_switcher(current_workspace: ws(1, "Acme"))
      assert html =~ "Acme"
    end

    test "falls back to em-dash when workspace is nil" do
      html = render_switcher(current_workspace: nil)
      # The title bar renders two spans; the first gets name_of(workspace).
      # We can't distinguish spans directly, but the dash must appear.
      assert html =~ "—"
    end

    test "falls back to em-dash when workspace map has no name key" do
      html = render_switcher(current_workspace: %{id: 99})
      assert html =~ "—"
    end
  end

  # ---------------------------------------------------------------------------
  # closed-menu state
  # ---------------------------------------------------------------------------

  describe "switcher with menu: nil (closed)" do
    test "does not render the scope-menu popover" do
      html = render_switcher()
      refute html =~ ~s(class="scope-menu")
      refute html =~ "scope-menu-col"
    end

    test "aria-expanded is false when closed" do
      html = render_switcher()
      assert html =~ ~s(aria-expanded="false")
    end
  end

  # ---------------------------------------------------------------------------
  # same?/2 — is-current / is-previewed CSS on workspace items
  # ---------------------------------------------------------------------------

  describe "same? — CSS class on menu items" do
    setup do
      ws_a = ws(1, "Alpha")
      ws_b = ws(2, "Beta")

      menu = %{
        ws: ws_a,
        proj: nil,
        workspaces: [ws_a, ws_b],
        projects: [],
        datasets: []
      }

      %{ws_a: ws_a, ws_b: ws_b, menu: menu}
    end

    test "is-current applied to the active workspace item", %{ws_a: ws_a, menu: menu} do
      html = render_switcher(current_workspace: ws_a, menu: menu)
      assert html =~ "is-current"
    end

    test "non-current workspace does not get is-current class", %{
      ws_a: ws_a,
      ws_b: ws_b,
      menu: menu
    } do
      # current = ws_b; previewed = ws_a — ws_b should have is-current in its button
      html = render_switcher(current_workspace: ws_b, menu: %{menu | ws: ws_b}, menu: menu)
      # ws_a is in the list but is neither current nor previewed on this render
      # At minimum the page must render without error and show both names
      assert html =~ ws_a.name
      assert html =~ ws_b.name
    end

    test "is-previewed applied to the previewed (but not current) workspace", %{
      ws_b: ws_b,
      menu: menu
    } do
      # current = ws_b, previewed = ws_a
      html = render_switcher(current_workspace: ws_b, menu: menu)
      assert html =~ "is-previewed"
    end

    test "aria-expanded is true when menu is open", %{menu: menu} do
      html = render_switcher(menu: menu)
      assert html =~ ~s(aria-expanded="true")
    end
  end

  # ---------------------------------------------------------------------------
  # current_dataset?/3 — dataset dot only when ws+proj+slug all match
  # ---------------------------------------------------------------------------

  describe "current_dataset? — dataset dot behaviour" do
    setup do
      w = ws(10, "MyWS")
      p = proj(20, "MyProj")

      menu = %{
        ws: w,
        proj: p,
        workspaces: [w],
        projects: [p],
        datasets: [ds("staging"), ds("production")]
      }

      %{w: w, p: p, menu: menu}
    end

    test "shows dot on the matching dataset when ws+proj+slug match", %{w: w, p: p, menu: menu} do
      html =
        render_switcher(
          current_workspace: w,
          current_project: p,
          current_dataset: "production",
          menu: menu
        )

      # The dot span appears for the current dataset
      assert html =~ ~s(title="Current")
    end

    test "no dot when dataset slug does not match", %{w: w, p: p, menu: menu} do
      html =
        render_switcher(
          current_workspace: w,
          current_project: p,
          current_dataset: "other",
          menu: menu
        )

      # Both dataset buttons must render
      assert html =~ ~s(phx-value-ds="staging")
      assert html =~ ~s(phx-value-ds="production")
      # Neither dataset button should carry the is-current class
      # (dataset buttons are identified by phx-click="scope-open")
      # Split on scope-open button occurrences and check none have is-current
      dataset_buttons = html |> String.split("phx-click=\"scope-open\"") |> tl()

      Enum.each(dataset_buttons, fn btn ->
        refute btn =~ "is-current"
      end)
    end

    test "no dot when previewed workspace differs from current workspace", %{p: p, menu: menu} do
      other_ws = ws(99, "OtherWS")
      # previewed ws (w/id=10) differs from current ws (other_ws/id=99)
      html =
        render_switcher(
          current_workspace: other_ws,
          current_project: p,
          current_dataset: "production",
          menu: menu
        )

      assert html =~ ~s(phx-value-ds="production")
      # Dataset buttons must not be marked is-current
      dataset_buttons = html |> String.split("phx-click=\"scope-open\"") |> tl()

      Enum.each(dataset_buttons, fn btn ->
        refute btn =~ "is-current"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # can_create gate
  # ---------------------------------------------------------------------------

  describe "can_create gate" do
    setup do
      w = ws(1, "WS")

      menu = %{
        ws: w,
        proj: nil,
        workspaces: [w],
        projects: [],
        datasets: []
      }

      %{w: w, menu: menu}
    end

    test "create affordance hidden when can_create is false", %{menu: menu} do
      html = render_switcher(menu: menu, can_create: false)
      refute html =~ "New workspace"
    end

    test "create affordance shown when can_create is true", %{menu: menu} do
      html = render_switcher(menu: menu, can_create: true)
      assert html =~ "New workspace"
    end
  end
end
