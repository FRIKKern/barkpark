defmodule Barkpark.StructureQuizFormsDeskTest do
  @moduledoc """
  An enabled plugin whose document type has NO documents yet must still put
  that type on the desk, or an author can never create the first one: the
  …Rest census only lists types that already hold documents, and the generic
  "Content" group rejects plugin-owned types.

  Found by run-4 lane C dogfood: Quiz (on by default, "keeps the quiz schema
  node in front of authors") and Forms (enabled, placement Main) registered
  their schemas but contributed no desk node — the Studio desk showed neither,
  whatever the placement.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure

  defp insert_schema!(%SchemaDefinition{} = s, dataset) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(%{
      name: s.name,
      title: s.title,
      icon: s.icon,
      visibility: s.visibility,
      dataset: dataset,
      fields: s.fields
    })
    |> Repo.insert!()
  end

  defp walk(nodes), do: Enum.flat_map(nodes || [], fn n -> [n | walk(n.items)] end)

  # Plugins-off: asserts on what enabled plugins contribute (desk nodes)
  @tag :requires_plugins
  test "the desk lists the quiz type before any quiz exists" do
    dataset = "structure_quiz_desk"
    Enum.each(Barkpark.Plugins.Quiz.register_schemas([]), &insert_schema!(&1, dataset))

    nodes = walk(Structure.build(dataset).items)

    assert Enum.any?(nodes, &(&1.type == :plugin_document_list and &1.type_name == "quiz")),
           "an enabled Quiz plugin must put a `quiz` document list on the desk"
  end

  test "Quiz contributes no desk entry where the quiz schema is absent" do
    assert Barkpark.Plugins.Quiz.desk_items("structure_quiz_desk_absent") == []
  end

  test "Forms lists its submissions inbox once the schema exists — never the endpoints" do
    dataset = "structure_forms_desk"

    Enum.each(
      Barkpark.Plugins.Forms.register_schemas(dataset: dataset),
      &insert_schema!(&1, dataset)
    )

    types =
      dataset
      |> Barkpark.Plugins.Forms.desk_items()
      |> Enum.filter(&(&1.type == :document_list))
      |> Enum.map(& &1.doc_type)

    assert types == ["form_submission"]
    assert Barkpark.Plugins.Forms.desk_items("structure_forms_desk_absent") == []
  end
end
