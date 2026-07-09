defmodule Barkpark.Plugins.EnablementTest do
  @moduledoc """
  Covers the per-workspace plugin enablement layer (ssp-w1-plugin-enablement):

    * the two declaration callbacks + their `use Barkpark.Plugin` defaults,
    * `Barkpark.Plugins.Enablement.effective/1` (declaration defaults merged
      with `workspaces.settings["plugins"]` overrides),
    * the `Tenancy.workspace_plugin_settings/1` / `set_workspace_plugin_settings/2`
      accessors (theme-preserving), and
    * the resolver-chain surfacing filter — `collect_desk_items/1`,
      `collect_top_menu_entries/1`, and the attributed collector skip
      per-workspace-disabled plugins only when `ctx` carries a `workspace_id`.

  Uses `DataCase` for the Repo sandbox and resets the singleton Registry in
  setup (the two leak channels `RegistryCase` documents) so fake-plugin
  registrations don't bleed across tests.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0]

  alias Barkpark.Plugins.{Enablement, Registry}
  alias Barkpark.Tenancy

  # ── Fake plugins ───────────────────────────────────────────────────────────
  # Bare modules (no `use Barkpark.Plugin`) that export the enablement
  # declaration callbacks directly — `Enablement` reads them via
  # `function_exported?`, so the macro is not required.

  defmodule MainEnabledPlugin do
    def default_enabled?, do: true
    def structure_placement, do: :main
    def desk_items(_dataset), do: [%{type: :link, label: "Main link", path: "/admin/main"}]
  end

  defmodule OffPlugin do
    def default_enabled?, do: false
    def structure_placement, do: :plugins
    def desk_items(_dataset), do: [%{type: :link, label: "Off link", path: "/admin/off"}]
  end

  defmodule TopMenuPlugin do
    def default_enabled?, do: true
    def structure_placement, do: :top_menu
    def top_menu_entries, do: [%{label: "TopFake", path: "/admin/topfake", order: 100}]
  end

  defmodule BarePlugin do
    # Exports neither callback — must default to enabled + :plugins.
    def desk_items(_dataset), do: [%{type: :link, label: "Bare link", path: "/admin/bare"}]
  end

  setup do
    Application.delete_env(:barkpark, :plugins)
    Registry.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark, :plugins)
      Registry.reset()
    end)

    :ok
  end

  defp register!(module, name) do
    :ok = Registry.register(module, %{"plugin_name" => name})
    name
  end

  # ── Declaration callbacks + defaults ───────────────────────────────────────

  describe "declaration callbacks" do
    test "use Barkpark.Plugin supplies the defaults" do
      assert Barkpark.Plugins.Bulldocs.default_enabled?() == true
    end

    test "the :main trio declares structure_placement :main" do
      assert Barkpark.Plugins.Bulldocs.structure_placement() == :main
      assert Barkpark.Plugins.Sheets.structure_placement() == :main
      assert Barkpark.Plugins.Tasks.structure_placement() == :main
    end

    test "media declares :top_menu placement, enabled by default" do
      assert Barkpark.Plugins.Media.structure_placement() == :top_menu
      assert Barkpark.Plugins.Media.default_enabled?() == true
    end

    test "onixedit/tickets/pulse/frt/github are off by default under :plugins" do
      for mod <- [
            Barkpark.Plugins.OnixEdit,
            Barkpark.Plugins.Tickets,
            Barkpark.Plugins.Pulse,
            Barkpark.Plugins.Frt,
            Barkpark.Plugins.Github
          ] do
        assert mod.default_enabled?() == false, "#{inspect(mod)} should be off by default"
        assert mod.structure_placement() == :plugins, "#{inspect(mod)} should place under :plugins"
      end
    end
  end

  # ── effective/1 ────────────────────────────────────────────────────────────

  describe "effective/1 — declaration defaults" do
    test "nil workspace resolves to declaration defaults only (no Repo read)" do
      main = register!(MainEnabledPlugin, "fake-main-#{unique()}")
      off = register!(OffPlugin, "fake-off-#{unique()}")

      eff = Enablement.effective(nil)

      assert eff[main] == %{enabled: true, placement: :main}
      assert eff[off] == %{enabled: false, placement: :plugins}
    end

    test "a bare plugin (no callbacks) defaults to enabled + :plugins" do
      bare = register!(BarePlugin, "fake-bare-#{unique()}")
      eff = Enablement.effective(nil)
      assert eff[bare] == %{enabled: true, placement: :plugins}
    end

    test "a workspace with no plugin settings resolves to defaults" do
      off = register!(OffPlugin, "fake-off-#{unique()}")
      ws = create_workspace!()

      eff = Enablement.effective(ws.id)
      assert eff[off] == %{enabled: false, placement: :plugins}
    end

    test "an unknown/unregistered workspace id resolves to defaults" do
      main = register!(MainEnabledPlugin, "fake-main-#{unique()}")
      eff = Enablement.effective(Ecto.UUID.generate())
      assert eff[main] == %{enabled: true, placement: :main}
    end
  end

  describe "effective/1 — workspace overrides" do
    test "an override enables an off-by-default plugin and can promote it" do
      off = register!(OffPlugin, "fake-off-#{unique()}")
      ws = create_workspace!()

      {:ok, _} =
        Tenancy.set_workspace_plugin_settings(ws.id, %{
          off => %{"enabled" => true, "placement" => "main"}
        })

      eff = Enablement.effective(ws.id)
      assert eff[off] == %{enabled: true, placement: :main}
    end

    test "an override disables an enabled-by-default plugin" do
      main = register!(MainEnabledPlugin, "fake-main-#{unique()}")
      ws = create_workspace!()

      {:ok, _} =
        Tenancy.set_workspace_plugin_settings(ws.id, %{main => %{"enabled" => false}})

      eff = Enablement.effective(ws.id)
      # placement default preserved; only enabled flipped
      assert eff[main] == %{enabled: false, placement: :main}
    end

    test "a partial/malformed override field leaves the declaration value" do
      main = register!(MainEnabledPlugin, "fake-main-#{unique()}")
      ws = create_workspace!()

      {:ok, _} =
        Tenancy.set_workspace_plugin_settings(ws.id, %{
          main => %{"placement" => "not-a-placement"}
        })

      eff = Enablement.effective(ws.id)
      assert eff[main] == %{enabled: true, placement: :main}
    end

    test "an override for an unknown plugin resolves to enabled + :plugins baseline" do
      ws = create_workspace!()

      {:ok, _} =
        Tenancy.set_workspace_plugin_settings(ws.id, %{
          "never-registered" => %{"placement" => "main"}
        })

      eff = Enablement.effective(ws.id)
      assert eff["never-registered"] == %{enabled: true, placement: :main}
    end
  end

  describe "enabled?/2 and placement/2" do
    test "unknown plugin reads as enabled + :plugins" do
      assert Enablement.enabled?(%{}, "nope") == true
      assert Enablement.placement(%{}, "nope") == :plugins
    end
  end

  # ── Tenancy accessors ──────────────────────────────────────────────────────

  describe "Tenancy plugin-settings accessors" do
    test "read defaults to empty map on a fresh workspace" do
      ws = create_workspace!()
      assert Tenancy.workspace_plugin_settings(ws) == %{}
      assert Tenancy.workspace_plugin_settings(nil) == %{}
    end

    test "set then read round-trips the map" do
      ws = create_workspace!()
      payload = %{"acme" => %{"enabled" => true, "placement" => "plugins"}}
      {:ok, updated} = Tenancy.set_workspace_plugin_settings(ws.id, payload)
      assert Tenancy.workspace_plugin_settings(updated) == payload
    end

    test "setting plugin settings preserves an existing theme" do
      ws = create_workspace!()
      {:ok, _} = Tenancy.set_workspace_theme(ws.id, "evergreen")
      {:ok, _} = Tenancy.set_workspace_plugin_settings(ws.id, %{"acme" => %{"enabled" => false}})

      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.workspace_theme(reloaded) == "evergreen"
      assert Tenancy.workspace_plugin_settings(reloaded) == %{"acme" => %{"enabled" => false}}
    end

    test "setting a theme preserves existing plugin settings" do
      ws = create_workspace!()
      {:ok, _} = Tenancy.set_workspace_plugin_settings(ws.id, %{"acme" => %{"enabled" => false}})
      {:ok, _} = Tenancy.set_workspace_theme(ws.id, "evergreen")

      reloaded = Tenancy.get_workspace_by_id(ws.id)
      assert Tenancy.workspace_plugin_settings(reloaded) == %{"acme" => %{"enabled" => false}}
    end

    test "a non-map plugins payload is rejected without touching the DB" do
      ws = create_workspace!()
      assert Tenancy.set_workspace_plugin_settings(ws.id, "nope") == {:error, :invalid_plugins}
    end

    test "a missing workspace id returns not_found" do
      assert Tenancy.set_workspace_plugin_settings(Ecto.UUID.generate(), %{}) ==
               {:error, :not_found}
    end
  end

  # ── Resolver-chain surfacing filter ────────────────────────────────────────

  describe "collect_desk_items/1 enablement filter" do
    test "without a workspace_id every plugin's items appear (byte-identical legacy)" do
      register!(MainEnabledPlugin, "fake-main-#{unique()}")
      register!(OffPlugin, "fake-off-#{unique()}")

      labels =
        Registry.collect_desk_items(baseline: [], ctx: %{dataset: "production"})
        |> Enum.map(& &1.label)

      assert "Main link" in labels
      assert "Off link" in labels
    end

    test "with a workspace_id a disabled plugin's items are skipped" do
      register!(MainEnabledPlugin, "fake-main-#{unique()}")
      register!(OffPlugin, "fake-off-#{unique()}")
      ws = create_workspace!()

      labels =
        Registry.collect_desk_items(baseline: [], ctx: %{dataset: "production", workspace_id: ws.id})
        |> Enum.map(& &1.label)

      assert "Main link" in labels
      # OffPlugin is off by default → filtered out under a workspace
      refute "Off link" in labels
    end

    test "a workspace override re-surfaces an off plugin" do
      register!(MainEnabledPlugin, "fake-main-#{unique()}")
      off = register!(OffPlugin, "fake-off-#{unique()}")
      ws = create_workspace!()
      {:ok, _} = Tenancy.set_workspace_plugin_settings(ws.id, %{off => %{"enabled" => true}})

      labels =
        Registry.collect_desk_items(baseline: [], ctx: %{dataset: "production", workspace_id: ws.id})
        |> Enum.map(& &1.label)

      assert "Off link" in labels
    end
  end

  describe "collect_top_menu_entries/1 enablement filter" do
    test "a disabled top_menu plugin's tab is dropped under a workspace" do
      # TopMenuPlugin is enabled by default, so disable it via override.
      top = register!(TopMenuPlugin, "fake-top-#{unique()}")
      ws = create_workspace!()
      {:ok, _} = Tenancy.set_workspace_plugin_settings(ws.id, %{top => %{"enabled" => false}})

      labels_no_ws =
        Registry.collect_top_menu_entries(baseline: [], ctx: %{dataset: "production"})
        |> Enum.map(& &1.label)

      labels_ws =
        Registry.collect_top_menu_entries(
          baseline: [],
          ctx: %{dataset: "production", workspace_id: ws.id}
        )
        |> Enum.map(& &1.label)

      assert "TopFake" in labels_no_ws
      refute "TopFake" in labels_ws
    end
  end

  describe "collect_desk_items_attributed/1" do
    test "returns host baseline and per-plugin attributed nodes" do
      main = register!(MainEnabledPlugin, "fake-main-#{unique()}")
      baseline = [%{type: :link, label: "Host", path: "/host"}]

      result =
        Registry.collect_desk_items_attributed(
          baseline: baseline,
          ctx: %{dataset: "production"}
        )

      assert result.host == baseline
      assert {^main, [%{label: "Main link"}]} = List.keyfind(result.plugins, main, 0)
    end

    test "filters disabled plugins under a workspace" do
      register!(MainEnabledPlugin, "fake-main-#{unique()}")
      off = register!(OffPlugin, "fake-off-#{unique()}")
      ws = create_workspace!()

      result =
        Registry.collect_desk_items_attributed(
          baseline: [],
          ctx: %{dataset: "production", workspace_id: ws.id}
        )

      names = Enum.map(result.plugins, fn {name, _} -> name end)
      refute off in names
    end

    test "drops plugins that contribute no nodes" do
      # A registered plugin with no desk_items must not appear in :plugins.
      top = register!(TopMenuPlugin, "fake-top-#{unique()}")

      result =
        Registry.collect_desk_items_attributed(baseline: [], ctx: %{dataset: "production"})

      names = Enum.map(result.plugins, fn {name, _} -> name end)
      refute top in names
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
