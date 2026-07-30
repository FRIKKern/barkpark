defmodule BarkparkWeb.Studio.EditorEmptyStateTypeEnumerationTest do
  @moduledoc """
  spd-w19 — the never-blank contract is GENERALISED, and this file is the part
  that proves it rather than asserting it.

  THE VACUOUS GREEN THIS EXISTS TO KILL. The obvious guard — "enumerate the
  document types, assert the count is non-zero, walk them" — passes while
  measuring almost nothing. A pristine CI database (`mix ecto.create &&
  mix ecto.migrate`, no seed step before `mix test` — .github/workflows/elixir.yml)
  holds exactly ONE `production` schema row, `paper`, from
  `20260524120000_move_papers_to_production.exs`. Locally the same query returns
  37, because boot registration wrote them once as RUNTIME RESIDUE (test config
  turns boot registration off). So a single `count > 0` over the UNION passes in
  CI off arm 1's single row and can never notice that arm 2 or arm 3 died.

  Hence: THREE ARMS, EACH ASSERTED NON-ZERO SEPARATELY.

    1. `Content.list_schemas/1` with the dataset PINNED to "production" — the
       installed rows. Returns [] for any other dataset, so the pin is load-bearing.
    2. The plugin `register_schemas/1` walk — pure code, identical in CI and
       locally. `task` and `listener` are HERE (plugins/tasks.ex ->
       Tasks.schema_definitions/1), not in arm 3.
    3. The host bootstrap's core `tag` schema — `SchemaBootstrap.init/1` ->
       `TagRegistry.register!/1`, deliberately OUTSIDE the plugin walk.
       Contributes exactly one type.

  And FLOOR MEMBERSHIP (paper, sheet, task, session + a fabricated schemaless
  orphan) is drawn from ARM 2, never from arm 1: sheet/task/session are absent
  from a pristine database, so asserting them against `list_schemas` would go
  green locally on residue rows and RED in CI.

  THE HONEST BOUND. This derivation covers types a CODE registry declares.
  guerrilla serves 39 types and prod 47, including a user-created `metric` and a
  `place` that no code registry contains — so the enumeration is a FLOOR, not a
  completeness claim. The contract itself is type-agnostic (it reports whatever
  `type_name` the pane carried), which is why an unregistered type is covered in
  behaviour even though it cannot be enumerated here.
  """

  use Barkpark.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.TagRegistry
  alias Barkpark.Plugins.Registry
  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.PaneBuilder
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias BarkparkWeb.StudioComponents.Editor

  # sheet/task/session are plugin-declared and absent from a pristine migrated
  # database; `paper` is the one row a pristine database DOES hold. Membership is
  # asserted against ARM 2 only.
  @floor ~w(paper sheet task session)

  defp arm1_installed_schema_types do
    Content.list_schemas("production") |> Enum.map(& &1.name)
  end

  defp arm2_plugin_declared_types do
    Registry.all()
    |> Enum.flat_map(fn %{module: module} ->
      try do
        module.register_schemas([]) |> Enum.map(& &1.name)
      rescue
        # Bootstrap logs-and-skips a raising plugin; the enumeration mirrors that
        # rather than letting one plugin take the whole guard down.
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp arm3_host_bootstrap_types, do: [TagRegistry.schema_attrs()["name"]]

  defp insert_schema!(name, dataset) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(%{
      name: name,
      title: name,
      icon: "file-text",
      visibility: "public",
      dataset: dataset,
      fields: [%{"name" => "title", "type" => "string"}]
    })
    |> Repo.insert!()
  end

  defp walk(path, root, dataset) do
    root_pane = %{
      title: root.title,
      role: :nav,
      priority: 0,
      items: [],
      selected: Enum.at(path, 0)
    }

    PaneBuilder.walk_path(path, 0, root, [root_pane], nil, dataset, [])
  end

  describe "arm 1 — installed schema rows, dataset pinned to production" do
    test "is non-zero on its own" do
      arm1 = arm1_installed_schema_types()

      assert length(arm1) > 0,
             "arm 1 (Content.list_schemas(\"production\")) contributed nothing — " <>
               "count=#{length(arm1)}"

      assert "paper" in arm1,
             "the one row a pristine migrated database holds is `paper` " <>
               "(migration 20260524120000_move_papers_to_production.exs)"
    end

    test "the `production` pin is load-bearing — any other dataset returns nothing" do
      assert Content.list_schemas("spdw19_no_such_dataset") == [],
             "unpinned, this arm silently contributes zero and the union hides it"
    end
  end

  describe "arm 2 — the plugin register_schemas walk" do
    test "is non-zero on its own, and carries task + listener" do
      arm2 = arm2_plugin_declared_types()

      assert length(arm2) > 0,
             "arm 2 (the plugin walk) contributed nothing — count=#{length(arm2)}"

      # These two live in the plugin walk, NOT in the host bootstrap arm.
      assert "task" in arm2, "plugins/tasks.ex -> Tasks.schema_definitions/1"
      assert "listener" in arm2, "same plugin, same walk"
    end

    test "FLOOR membership comes from arm 2, not from arm 1" do
      arm2 = arm2_plugin_declared_types()

      for type <- @floor do
        assert type in arm2,
               "#{type} must be enumerable from the plugin walk; asserting it against " <>
                 "list_schemas would red on a pristine CI database"
      end
    end
  end

  describe "arm 3 — the host bootstrap core schema" do
    test "contributes exactly one type, `tag`" do
      assert arm3_host_bootstrap_types() == ["tag"],
             "SchemaBootstrap.init/1 -> TagRegistry.register!/1 — one type, outside the plugin walk"
    end
  end

  describe "the union" do
    test "is non-zero and at least as large as its largest arm" do
      arm1 = arm1_installed_schema_types()
      arm2 = arm2_plugin_declared_types()
      arm3 = arm3_host_bootstrap_types()

      union = Enum.uniq(arm1 ++ arm2 ++ arm3)

      assert length(union) > 0
      assert length(union) >= length(arm2)
      assert length(union) >= length(arm1)

      # The counts, printed so a reviewer sees the vacuous green in the numbers
      # rather than taking the derivation on trust: locally arm1 == arm2 == 37
      # (residue), in CI arm1 == 1.
      IO.puts(
        "\n[spd-w19 enumeration] arm1(list_schemas production)=#{length(arm1)} " <>
          "arm2(plugin walk)=#{length(arm2)} arm3(tag bootstrap)=#{length(arm3)} " <>
          "union=#{length(union)}"
      )
    end

    test "EVERY enumerated type gets a NAMED reason, never a shrug" do
      union =
        Enum.uniq(
          arm1_installed_schema_types() ++
            arm2_plugin_declared_types() ++ arm3_host_bootstrap_types()
        )

      assert length(union) > 0

      for type <- union do
        panes = [
          %{role: :nav, priority: 0, items: [], selected: type},
          %{role: :list, priority: :active, type_name: type, items: [], selected: "ghost-#{type}"}
        ]

        st = Shared.empty_editor_state(panes, [type, "ghost-#{type}"])

        assert st == %{reason: :not_found, doc_id: "ghost-#{type}", doc_type: type}

        html =
          render_component(&Editor.unresolved_document_notice/1, %{
            reason: st.reason,
            doc_id: st.doc_id,
            doc_type: st.doc_type,
            list_href: "/d/production/studio/#{type}",
            desk_href: "/d/production/studio"
          })

        assert html =~ "ghost-#{type}", "#{type}: the id must be named"
        assert html =~ type, "#{type}: the REAL type must be named"
        refute html =~ "Select a document to edit", "#{type}: the shrug must be unreachable"
      end
    end
  end

  describe "the floor, driven through the real walk (not hand-built panes)" do
    test "paper, sheet, task and session each reach :not_found through PaneBuilder.walk_path" do
      dataset = "spdw19_floor"

      for type <- @floor, do: insert_schema!(type, dataset)

      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items:
          for type <- @floor do
            %Node{id: type, title: type, type: :document_type_list, type_name: type}
          end
      }

      for type <- @floor do
        {panes, editor} = walk([type, "ghost-#{type}"], root, dataset)

        assert editor == nil, "#{type}: fixture must not resolve"

        assert Shared.empty_editor_state(panes, [type, "ghost-#{type}"]) == %{
                 reason: :not_found,
                 doc_id: "ghost-#{type}",
                 doc_type: type
               }
      end
    end

    test "a FABRICATED schemaless orphan reaches :no_schema through the same walk" do
      dataset = "spdw19_floor_orphan"

      # Registered by no plugin, present in no schema table — the fifth floor
      # member, and the one that proves the contract does not need a schema to
      # answer honestly.
      root = %Node{
        id: "root",
        title: "Content",
        type: :list,
        items: [
          %Node{
            id: "rest",
            title: "…Rest",
            type: :list,
            items: [
              %Node{
                id: "orphan",
                title: "Orphan",
                type: :document,
                type_name: "spdw19FabricatedOrphan"
              }
            ]
          }
        ]
      }

      {panes, editor} = walk(["rest", "spdw19FabricatedOrphan"], root, dataset)
      assert editor == nil

      assert Shared.empty_editor_state(panes, ["rest", "spdw19FabricatedOrphan"]) == %{
               reason: :no_schema,
               doc_id: "spdw19FabricatedOrphan",
               doc_type: "spdw19FabricatedOrphan"
             }

      refute "spdw19FabricatedOrphan" in arm2_plugin_declared_types()
      refute "spdw19FabricatedOrphan" in arm1_installed_schema_types()
    end
  end
end
