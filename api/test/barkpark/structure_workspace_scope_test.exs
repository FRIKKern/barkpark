defmodule Barkpark.StructureWorkspaceScopeTest do
  @moduledoc """
  Pins that `Structure.build/2` scopes the Studio desk to the requesting
  workspace:

    * host groups gate on the workspace's OWN schemas — a workspace with a
      `paper` schema but no `post` shows Papers, never Posts; and
    * plugin desk contributions are filtered to the workspace's types — a
      globally-registered plugin node (frt's game groups, the tasks list)
      whose type is plugin-owned but absent from the scope is dropped, so it
      can't leak into a workspace that never registered it — and ANOTHER
      workspace's catalog never decides that gate.

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

    a_types = Structure.build(@dataset, scope(ctx.ws_a, ctx.proj_a)) |> type_names()
    b_types = Structure.build(@dataset, scope(ctx.ws_b, ctx.proj_b)) |> type_names()

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

    a_types = Structure.build(@dataset, scope(ctx.ws_a, ctx.proj_a)) |> type_names()
    b_types = Structure.build(@dataset, scope(ctx.ws_b, ctx.proj_b)) |> type_names()

    assert "task" in a_types, "workspace A registered task → Tasks desk node kept"
    refute "task" in b_types, "workspace B has no task schema → Tasks desk node dropped"
  end

  # Plugins-off: asserts on what enabled plugins contribute (registry, schemas, desk nodes, manifest commands)
  @tag :requires_plugins
  test "another workspace's schema never decides this workspace's plugin nodes", ctx do
    # task-5ae31d6d9f13965f. frt contributes its game-type nodes UNCONDITIONALLY
    # (no presence check), so the host gate alone decides them. The gate used to
    # classify against the UNSCOPED catalog — every workspace's types in the
    # dataset — so workspace A's `rune` node flipped from shown to hidden the
    # moment workspace B registered `rune`: a cross-tenant existence oracle.
    # It now classifies against plugin-owned types (code), so A's desk is the
    # same either way — and `rune` (frt-owned, absent from A) is gated out.
    {:ok, _} =
      Barkpark.Tenancy.set_workspace_plugin_settings(ctx.ws_a.id, %{
        "frt" => %{"enabled" => true}
      })

    a_scope = scope(ctx.ws_a, ctx.proj_a)
    before = Structure.build(@dataset, a_scope)

    register_schema!("rune", "Runes", scope(ctx.ws_b, ctx.proj_b))
    after_b = Structure.build(@dataset, a_scope)

    assert titles(before) == titles(after_b),
           "workspace B registering `rune` changed workspace A's desk: " <>
             inspect(MapSet.difference(titles(before), titles(after_b)))

    refute "rune" in type_names(before),
           "frt-owned `rune` is absent from workspace A → its desk node is gated out"

    # A's OWN registration still passes the gate.
    register_schema!("rune", "Runes", a_scope)
    assert "rune" in (Structure.build(@dataset, a_scope) |> type_names())
  end

  # Plugins-off: asserts on what enabled plugins contribute (registry, schemas, desk nodes, manifest commands)
  @tag :requires_plugins
  test "a plugin's schema-less nodes are gated by their requires_schema tag", ctx do
    # OnixEdit's Bokbasen contribution (a divider + an admin-page link, neither
    # carrying a schema type) is tagged `requires_schema: "book"`. It must
    # appear only in a workspace that registered the `book` schema.
    #
    # OnixEdit ships default_enabled?: false (studio-structure-polish) —
    # enable it in BOTH workspaces so this test isolates the requires_schema
    # gate, not the enablement filter.
    for ws <- [ctx.ws_a, ctx.ws_b] do
      {:ok, _} =
        Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{
          "onixedit" => %{"enabled" => true}
        })
    end

    register_schema!("book", "Book (ONIX 3.0)", scope(ctx.ws_a, ctx.proj_a))

    a_titles = Structure.build(@dataset, scope(ctx.ws_a, ctx.proj_a)) |> titles()
    b_titles = Structure.build(@dataset, scope(ctx.ws_b, ctx.proj_b)) |> titles()

    assert "Pending submissions" in a_titles,
           "workspace A registered book → Bokbasen desk nodes kept"

    refute "Pending submissions" in b_titles,
           "workspace B has no book schema → Bokbasen desk nodes dropped"

    refute "Bokbasen" in b_titles, "the Bokbasen divider must drop with its link"
  end

  # task-90c3a512181b8537. The Tasks and Tickets plugins used to decide their
  # desk list with an UNSCOPED `Content.get_schema/2` — "does ANY workspace
  # have this type in the dataset". So workspace A's plugin output flipped
  # from no list to a list the moment workspace B registered the type: a read
  # of B's catalog on A's behalf. Under a workspace scope the plugin no longer
  # probes. It emits the list, and the host gate decides against A's own
  # catalog.
  #
  # Quiz and Forms ran the same probe (filed by the run-5 lane D sweep) and now
  # take the same rule.
  for {plugin, type, label} <- [
        {Barkpark.Plugins.Tasks, "task", "Tasks"},
        {Barkpark.Plugins.Tickets, "ticket", "Tickets"},
        {Barkpark.Plugins.Quiz, "quiz", "Quizzes"},
        {Barkpark.Plugins.Forms, Barkpark.Plugins.Forms.Contract.submission_type(),
         "Form submissions"}
      ] do
    @plugin plugin
    @type_name type
    @label label

    test "#{inspect(plugin)}'s desk presence check never reads another workspace's schema",
         ctx do
      a_scope = scope(ctx.ws_a, ctx.proj_a)
      desk_ctx = %{dataset: @dataset, current_path: nil, scope: a_scope}
      labels = fn -> @plugin.resolve_desk_items([], desk_ctx) |> Enum.map(& &1.label) end

      before_plugin = labels.()
      before_desk = Structure.build(@dataset, a_scope)

      register_schema!(@type_name, @label, scope(ctx.ws_b, ctx.proj_b))

      assert labels.() == before_plugin,
             "workspace B registering `#{@type_name}` changed what #{inspect(@plugin)} " <>
               "contributes to workspace A's desk"

      assert titles(Structure.build(@dataset, a_scope)) == titles(before_desk)

      # The host gate still keeps the list out of A, which has no such schema.
      refute @type_name in type_names(Structure.build(@dataset, a_scope))
    end
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
