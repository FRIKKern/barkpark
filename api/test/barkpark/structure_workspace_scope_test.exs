defmodule Barkpark.StructureWorkspaceScopeTest do
  @moduledoc """
  Pins that `Structure.build/3` scopes the Studio desk to the requesting
  workspace:

    * host groups gate on the workspace's OWN schemas — a workspace with a
      `paper` schema but no `post` shows Papers, never Posts; and
    * plugin desk contributions are filtered to the workspace's types — a
      globally-registered plugin node (frt's game groups, the tasks list)
      whose type exists in the catalog but is absent from the scope is
      dropped, so it can't leak into a workspace that never registered it.

  Regression guard for the workspace-desk-leak fix: pre-fix `build/2` called
  `list_schemas/1` unscoped and ran the plugin chain without scope, so every
  workspace rendered the Default workspace's entire catalog (post, page, the
  frt game types, …) regardless of which workspace was being viewed.
  """

  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Structure

  @dataset "test"

  defp scope(ws, proj), do: [workspace_id: ws.id, project_id: proj.id]

  defp register_schema!(name, title, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => title, "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )
  end

  # Every `type_name` in the tree, walking nested groups — the set of content
  # types the desk would surface.
  defp type_names(%Structure.Node{items: items}), do: items |> collect([]) |> MapSet.new()

  defp collect(items, acc) do
    Enum.reduce(items, acc, fn node, acc ->
      acc = if node.type_name, do: [node.type_name | acc], else: acc
      collect(node.items || [], acc)
    end)
  end

  # Every node title in the tree, walking nested groups.
  defp titles(%Structure.Node{items: items}), do: items |> collect_titles([]) |> MapSet.new()

  defp collect_titles(items, acc) do
    Enum.reduce(items, acc, fn node, acc ->
      acc = if node.title, do: [node.title | acc], else: acc
      collect_titles(node.items || [], acc)
    end)
  end

  setup do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  test "host groups are scoped to the workspace's own schemas", ctx do
    register_schema!("paper", "Papers", scope(ctx.ws_a, ctx.proj_a))
    register_schema!("post", "Posts", scope(ctx.ws_b, ctx.proj_b))

    a_types = Structure.build(@dataset, nil, scope(ctx.ws_a, ctx.proj_a)) |> type_names()
    b_types = Structure.build(@dataset, nil, scope(ctx.ws_b, ctx.proj_b)) |> type_names()

    assert "paper" in a_types
    refute "post" in a_types, "workspace A must not show workspace B's post type"

    assert "post" in b_types
    refute "paper" in b_types, "workspace B must not show workspace A's paper type"
  end

  test "plugin desk nodes are filtered to the workspace's types", ctx do
    # `task` registered ONLY in workspace A. The Tasks plugin contributes a
    # "Tasks" desk node for the dataset (its gate is dataset-, not
    # workspace-scoped), so the host-level scope filter is what must keep it
    # out of workspace B.
    register_schema!("task", "Tasks", scope(ctx.ws_a, ctx.proj_a))

    a_types = Structure.build(@dataset, nil, scope(ctx.ws_a, ctx.proj_a)) |> type_names()
    b_types = Structure.build(@dataset, nil, scope(ctx.ws_b, ctx.proj_b)) |> type_names()

    assert "task" in a_types, "workspace A registered task → Tasks desk node kept"
    refute "task" in b_types, "workspace B has no task schema → Tasks desk node dropped"
  end

  test "a plugin's schema-less nodes are gated by their requires_schema tag", ctx do
    # OnixEdit's Bokbasen contribution (a divider + an admin-page link, neither
    # carrying a schema type) is tagged `requires_schema: "book"`. It must
    # appear only in a workspace that registered the `book` schema.
    register_schema!("book", "Book (ONIX 3.0)", scope(ctx.ws_a, ctx.proj_a))

    a_titles = Structure.build(@dataset, nil, scope(ctx.ws_a, ctx.proj_a)) |> titles()
    b_titles = Structure.build(@dataset, nil, scope(ctx.ws_b, ctx.proj_b)) |> titles()

    assert "Pending submissions" in a_titles,
           "workspace A registered book → Bokbasen desk nodes kept"

    refute "Pending submissions" in b_titles,
           "workspace B has no book schema → Bokbasen desk nodes dropped"

    refute "Bokbasen" in b_titles, "the Bokbasen divider must drop with its link"
  end

  test "an unscoped build keeps legacy (unfiltered) behaviour", ctx do
    register_schema!("paper", "Papers", scope(ctx.ws_a, ctx.proj_a))
    register_schema!("post", "Posts", scope(ctx.ws_b, ctx.proj_b))

    # No :workspace_id → the flat / Default desk → no scoping, both surface.
    types = Structure.build(@dataset) |> type_names()

    assert "paper" in types
    assert "post" in types
  end
end
