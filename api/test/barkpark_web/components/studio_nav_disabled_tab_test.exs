defmodule BarkparkWeb.StudioComponents.NavDisabledTabTest do
  @moduledoc """
  task-e34595f816cd4bd2 — the RENDER half. `Nav.studio_tabs/1` must paint a
  per-workspace-disabled plugin tab as a non-navigable, explained affordance
  rather than dropping it (the vanish) or emitting a plain enabled `<a>`.

  Rendering only: `render_component/2` drives the function component directly,
  which is the whole surface the row names. No LiveView mount, no route.

  `async: false` + `Registry.reset/0`: the plugin registry is a process-global
  singleton whose state only grows.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Barkpark.TenancyFixtures, only: [create_workspace!: 1]

  alias Barkpark.Plugins.Registry
  alias Barkpark.Tenancy
  alias BarkparkWeb.StudioComponents.Nav

  # Off by declaration, enabled by override in exactly ONE workspace — so the
  # reason's workspace name is unambiguous (see the collector test).
  defmodule ScopedNavPlugin do
    def default_enabled?, do: false
    def structure_placement, do: :top_menu
    def top_menu_entries, do: [%{label: "ScopedNavTab", path: "/admin/scoped-nav", order: 90}]
  end

  setup do
    Application.delete_env(:barkpark, :plugins)
    Registry.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark, :plugins)
      Registry.reset()
    end)

    name = "navdt-scoped-#{System.unique_integer([:positive])}"
    :ok = Registry.register(ScopedNavPlugin, %{"plugin_name" => name})

    enabling = create_workspace!("navdt-a-#{System.unique_integer([:positive])}")
    disabling = create_workspace!("navdt-default-#{System.unique_integer([:positive])}")

    {:ok, _} = Tenancy.set_workspace_plugin_settings(enabling.id, %{name => %{"enabled" => true}})

    {:ok, _} =
      Tenancy.set_workspace_plugin_settings(disabling.id, %{name => %{"enabled" => false}})

    %{plugin_name: name, enabling: enabling, disabling: disabling}
  end

  defp render_tabs(workspace) do
    render_component(&Nav.studio_tabs/1, %{
      dataset: "production",
      scope_prefix: "",
      current_path: "/studio/production",
      admin?: false,
      workspace_id: workspace.id
    })
  end

  describe "studio_tabs/1 — per-workspace-disabled plugin" do
    test "the disabling workspace renders a disabled, explained affordance", %{
      disabling: disabling,
      enabling: enabling
    } do
      html = render_tabs(disabling)

      assert html =~ "top-menu-tab-disabled",
             "expected a disabled tab affordance; got:\n#{html}"

      assert html =~ "aria-disabled=\"true\""
      assert html =~ "studio-tab-disabled"
      assert html =~ "ScopedNavTab"
      assert html =~ "Disabled in this workspace"
      assert html =~ enabling.name
    end

    test "the disabled tab is NOT a navigable link", %{disabling: disabling} do
      html = render_tabs(disabling)

      refute html =~ "/admin/scoped-nav",
             "the disabled tab must carry no href to the plugin route"

      assert html =~ ~r/<span[^>]*top-menu-tab-disabled/,
             "the disabled tab must be a <span>, not an anchor"

      refute html =~ ~r/<a[^>]*top-menu-tab-disabled/,
             "the disabled tab must not render as an <a> at all"
    end

    test "CONTROL: the enabling workspace renders a plain enabled link", %{enabling: enabling} do
      html = render_tabs(enabling)

      assert html =~ "/admin/scoped-nav"
      assert html =~ "data-test-id=\"top-menu-tab\""
      refute html =~ "top-menu-tab-disabled"
      refute html =~ "aria-disabled"
    end
  end
end
