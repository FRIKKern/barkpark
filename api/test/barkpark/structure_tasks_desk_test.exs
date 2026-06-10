defmodule Barkpark.StructureTasksDeskTest do
  @moduledoc """
  Pins that the Tasks plugin contributes a "Tasks" desk entry through the
  plugin desk-item highway (`Barkpark.Plugins.Tasks.desk_items/1` →
  `Registry.collect_desk_items/1` → `Structure.build_desk_items/3`'s
  `plugin_item_to_node/1` translation), gated on the `task` schema
  existing in the dataset — no host special-casing in `structure.ex`.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure
  alias Barkpark.Structure.Node

  defp insert_task_schema!(dataset) do
    # Derive from the plugin's single source of truth so this test pins
    # the REAL registered shape (incl. the lifecycle_status select).
    schema = Barkpark.Tasks.task_schema(dataset)

    %SchemaDefinition{}
    |> SchemaDefinition.changeset(%{
      name: schema.name,
      title: schema.title,
      icon: schema.icon,
      visibility: schema.visibility,
      dataset: schema.dataset,
      fields: schema.fields
    })
    |> Repo.insert!()
  end

  test "tasks plugin is registered on the plugin highway" do
    assert {:ok, %{module: Barkpark.Plugins.Tasks}} =
             Barkpark.Plugins.Registry.lookup("tasks")
  end

  test "desk shows a Tasks document list when the task schema exists" do
    dataset = "structure_tasks_desk"
    insert_task_schema!(dataset)

    tree = Structure.build(dataset)

    tasks_node =
      Enum.find(tree.items, fn n ->
        n.type == :plugin_document_list and n.type_name == "task"
      end)

    assert %Node{title: "Tasks", icon: "✅"} = tasks_node
  end

  test "no Tasks desk entry when the dataset has no task schema" do
    dataset = "structure_tasks_desk_absent"

    tree = Structure.build(dataset)

    refute Enum.any?(tree.items, fn n ->
             n.type == :plugin_document_list and n.type_name == "task"
           end),
           "Tasks desk entry must be gated on the task schema's presence"
  end
end
