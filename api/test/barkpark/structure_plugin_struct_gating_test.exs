defmodule Barkpark.StructurePluginStructGatingTest do
  @moduledoc """
  Pins two `Structure.build/2` invariants added in the desk-structure review:

    * a `%Structure.Node{}` a plugin's `resolve_desk_items/2` override returns
      is a PLUGIN contribution and rides `scope_plugin_nodes/4` workspace
      gating — pre-fix the host/plugin partition classified on struct-ness,
      so any struct-returning plugin bypassed gating and leaked its nodes
      into every workspace's desk;

    * the built tree is deterministic across rebuilds — divider ids are
      positional, never `System.unique_integer/1`, so LiveView keyed diffs
      don't churn and `/v1/structure` responses byte-compare for the TUI.

  async: false — registers a fake plugin in the global Registry.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Registry
  alias Barkpark.Structure

  @dataset "struct_gate_test"

  defmodule StructReturningPlugin do
    @moduledoc false
    # Simulates a plugin whose resolve_desk_items/2 override hands back a
    # full %Node{} struct instead of a desk-item map.
    def resolve_desk_items(prev, _ctx) do
      prev ++
        [
          %Barkpark.Structure.Node{
            id: "struct-plugin-gated",
            title: "Gated struct list",
            type: :plugin_document_list,
            type_name: "gated_type",
            filter: %{}
          }
        ]
    end
  end

  setup do
    Registry.reset()
    on_exit(fn -> Registry.reset() end)

    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  defp scope(ws, proj), do: [workspace_id: ws.id, project_id: proj.id]

  defp register_schema!(name, title, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => title, "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )
  end

  defp type_names(%Structure.Node{items: items}), do: items |> collect([]) |> MapSet.new()

  defp collect(items, acc) do
    Enum.reduce(items, acc, fn node, acc ->
      acc = if node.type_name, do: [node.type_name | acc], else: acc
      collect(node.items || [], acc)
    end)
  end

  test "a %Node{} returned by a plugin override is workspace-gated like any plugin item",
       ctx do
    # `gated_type` exists in the catalog but is registered ONLY in workspace A.
    register_schema!("gated_type", "Gated", scope(ctx.ws_a, ctx.proj_a))
    # Workspace B owns some content so its desk isn't empty.
    register_schema!("post", "Posts", scope(ctx.ws_b, ctx.proj_b))

    :ok =
      Registry.register(StructReturningPlugin, %{
        "plugin_name" => "fake-struct-desk-#{System.unique_integer([:positive])}"
      })

    a_types = Structure.build(@dataset, scope(ctx.ws_a, ctx.proj_a)) |> type_names()
    b_types = Structure.build(@dataset, scope(ctx.ws_b, ctx.proj_b)) |> type_names()

    assert "gated_type" in a_types,
           "workspace A registered gated_type → the plugin's struct node is kept"

    refute "gated_type" in b_types,
           "workspace B has no gated_type schema → the plugin's %Node{} must be " <>
             "gated out, not smuggled past scope_plugin_nodes/4 as a host struct"
  end

  test "the built tree is deterministic across rebuilds (stable divider ids)", ctx do
    register_schema!("post", "Posts", scope(ctx.ws_a, ctx.proj_a))
    register_schema!("author", "Authors", scope(ctx.ws_a, ctx.proj_a))
    register_schema!("siteSettings", "Site Settings", scope(ctx.ws_a, ctx.proj_a))

    scope_kw = scope(ctx.ws_a, ctx.proj_a)

    assert Structure.build(@dataset, scope_kw) == Structure.build(@dataset, scope_kw)
    assert Structure.build(@dataset) == Structure.build(@dataset)
  end
end
