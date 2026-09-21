defmodule Barkpark.Plugins.Registry.TopMenuDisabledEntriesTest do
  @moduledoc """
  task-e34595f816cd4bd2 — a plugin the CURRENT workspace does not surface, but
  another workspace DOES, must reach the Studio top menu as an explicit
  disabled entry instead of vanishing.

  The asymmetry under test is the flat-vs-scoped one from the row: workspace
  `a` enables plugin P, workspace `default` disables it. Collecting scoped to
  `a` yields P enabled; collecting scoped to `default` — which is what a flat
  `/studio/*` route resolves to — used to yield NOTHING for P, and now yields
  P with `disabled: true` and a reason naming `a`.

  `async: false` + `Registry.reset/0`: the registry is a process-global
  singleton whose state only grows.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures, only: [create_workspace!: 1]

  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Registry.ResolverChain
  alias Barkpark.Tenancy

  # ── Fake plugins ────────────────────────────────────────────────────────
  # Bare modules exporting the declaration callbacks directly; `Enablement`
  # and the resolver chain both read them via `function_exported?`.

  # Off by DECLARATION and enabled by override in exactly one workspace, so
  # "the workspace that enables it" is unambiguous: any other workspace in the
  # test DB (the seeded Default Workspace included) leaves it off.
  defmodule ScopedTopMenuPlugin do
    def default_enabled?, do: false
    def structure_placement, do: :top_menu
    def top_menu_entries, do: [%{label: "ScopedTab", path: "/admin/scoped", order: 90}]
  end

  defmodule EverywhereTopMenuPlugin do
    def default_enabled?, do: true
    def structure_placement, do: :top_menu
    def top_menu_entries, do: [%{label: "EverywhereTab", path: "/admin/every", order: 91}]
  end

  defmodule NowhereTopMenuPlugin do
    def default_enabled?, do: false
    def structure_placement, do: :plugins
    def top_menu_entries, do: [%{label: "NowhereTab", path: "/admin/nowhere", order: 92}]
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

  defp register!(module, prefix) do
    name = "#{prefix}-#{System.unique_integer([:positive])}"
    :ok = Registry.register(module, %{"plugin_name" => name})
    name
  end

  defp entry(entries, label), do: Enum.find(entries, &(&1.label == label))

  # Two workspaces: `a` surfaces the scoped plugin, `default` does not.
  defp two_workspaces(scoped_name) do
    a = create_workspace!("tmde-a-#{System.unique_integer([:positive])}")
    default = create_workspace!("tmde-default-#{System.unique_integer([:positive])}")

    {:ok, _} = Tenancy.set_workspace_plugin_settings(a.id, %{scoped_name => %{"enabled" => true}})

    {:ok, _} =
      Tenancy.set_workspace_plugin_settings(default.id, %{scoped_name => %{"enabled" => false}})

    {a, default}
  end

  defp collect(workspace) do
    ResolverChain.compute_top_menu_entries([], %{
      dataset: "production",
      workspace_id: workspace.id
    })
  end

  describe "compute_top_menu_entries/2 — disabled-but-enabled-elsewhere" do
    test "the disabling workspace gets the entry with disabled: true and a reason naming the enabling workspace" do
      scoped = register!(ScopedTopMenuPlugin, "tmde-scoped")
      {a, default} = two_workspaces(scoped)

      tab = entry(collect(default), "ScopedTab")

      assert tab,
             "expected the per-workspace-disabled plugin to SURFACE as a disabled entry, not vanish"

      assert tab.disabled == true
      assert is_binary(tab.reason)
      assert tab.reason =~ a.name
      assert tab.reason =~ "Disabled in this workspace"
      # The entry keeps its declared placement in the order tier.
      assert tab.order == 90
      assert tab.path == "/admin/scoped"
    end

    test "the enabling workspace gets the same entry with disabled: false" do
      scoped = register!(ScopedTopMenuPlugin, "tmde-scoped")
      {a, _default} = two_workspaces(scoped)

      tab = entry(collect(a), "ScopedTab")

      assert tab, "expected the enabling workspace to surface the tab"
      assert tab.disabled == false
      assert tab.reason == nil
    end

    test "CONTROL: a plugin enabled everywhere renders enabled on both workspaces" do
      scoped = register!(ScopedTopMenuPlugin, "tmde-scoped")
      register!(EverywhereTopMenuPlugin, "tmde-every")
      {a, default} = two_workspaces(scoped)

      for ws <- [a, default] do
        tab = entry(collect(ws), "EverywhereTab")
        assert tab, "expected the always-enabled plugin to surface in #{ws.slug}"
        assert tab.disabled == false
        assert tab.reason == nil
      end
    end

    test "CONTROL: a plugin disabled EVERYWHERE still vanishes (no dead tab)" do
      scoped = register!(ScopedTopMenuPlugin, "tmde-scoped")
      register!(NowhereTopMenuPlugin, "tmde-nowhere")
      {a, default} = two_workspaces(scoped)

      for ws <- [a, default] do
        labels = collect(ws) |> Enum.map(& &1.label)

        refute "NowhereTab" in labels,
               "an off-by-default plugin no workspace enables must NOT surface a disabled tab"
      end
    end

    test "CONTROL: a workspace-less ctx is unchanged — no disabled entries, no Repo read" do
      scoped = register!(ScopedTopMenuPlugin, "tmde-scoped")
      {_a, _default} = two_workspaces(scoped)

      entries = ResolverChain.compute_top_menu_entries([], %{})

      assert Enum.all?(entries, &(&1.disabled == false)),
             "the registration-path snapshot must carry no disabled entries"

      assert ResolverChain.disabled_top_menu_entries(%{}) == []
    end

    test "every entry carries the disabled/reason pair so nav.ex reads one shape" do
      register!(EverywhereTopMenuPlugin, "tmde-every")

      entries = ResolverChain.compute_top_menu_entries([%{label: "Host", path: "/host"}], %{})

      assert entries != []

      for e <- entries do
        assert Map.has_key?(e, :disabled), "entry #{e.label} is missing :disabled"
        assert Map.has_key?(e, :reason), "entry #{e.label} is missing :reason"
      end
    end
  end
end
