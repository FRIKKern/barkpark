defmodule BarkparkWeb.Studio.StructureCopyTest do
  @moduledoc """
  task-acb3765dea94de2e: the structure pane read "Content", "Plugins", "…Rest",
  "Sheets", "Tasks" in English in a Norwegian Studio. Studio now translates
  Barkpark's own words in the tree it renders; a title the workspace authored
  stays as written, and the tree Structure builds is unchanged.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.StructureCopy

  defp tree do
    %Node{
      id: "root",
      title: "Structure",
      type: :list,
      items: [
        %Node{id: "sheet", title: "Sheets", type: :document_type_list, type_name: "sheet"},
        %Node{id: "author", title: "Forfatter", type: :document_type_list, type_name: "author"},
        %Node{id: "custom", title: "Sheets", type: :document_type_list, type_name: "custom"},
        %Node{
          id: "content-types",
          title: "Content",
          type: :list,
          items: [
            %Node{
              id: "publication",
              title: "Utgivelse",
              type: :list,
              type_name: "publication",
              items: [
                %Node{
                  id: "publication-all",
                  title: "All Utgivelse",
                  type: :document_type_list,
                  type_name: "publication"
                },
                %Node{
                  id: "sheet-all",
                  title: "All Sheets",
                  type: :document_type_list,
                  type_name: "sheet"
                }
              ]
            }
          ]
        },
        %Node{
          id: "plugin-doclist-1",
          title: "Tasks",
          type: :plugin_document_list,
          type_name: "task"
        },
        %Node{id: "plugin-link-1", title: "Fleet", type: :plugin_link},
        %Node{id: "plugins", title: "Plugins", type: :list, items: []},
        %Node{id: "rest", title: "…Rest", type: :list, items: []}
      ]
    }
  end

  defp titles(%{title: title, items: items}) when is_list(items),
    do: [title | Enum.flat_map(items, &titles/1)]

  defp titles(%{title: title}), do: [title]

  test "a Norwegian Studio reads Barkpark's words in Norwegian and the workspace's as written" do
    localized =
      Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn -> StructureCopy.localize(tree()) end)

    assert titles(localized) == [
             "Structure",
             "Regneark",
             "Forfatter",
             # An authored type that happens to share a plugin title is data.
             "Sheets",
             "Innhold",
             "Utgivelse",
             "Alle Utgivelse",
             "Alle Regneark",
             "Oppgaver",
             "Flåte",
             "Utvidelser",
             "…Resten"
           ]
  end

  test "an English Studio reads exactly the tree Structure built" do
    localized =
      Gettext.with_locale(BarkparkWeb.Gettext, "en", fn -> StructureCopy.localize(tree()) end)

    assert localized == tree()
  end

  test "every default-enabled plugin's type titles and desk labels have a translation marker" do
    markers = MapSet.new(StructureCopy.markers())

    shipped =
      for %{module: module} <- Barkpark.Plugins.Registry.all(),
          module.default_enabled?(),
          text <-
            Enum.map(module.register_schemas([]), & &1.title) ++
              Enum.map(module.desk_items("production"), & &1[:label]),
          is_binary(text),
          uniq: true,
          do: text

    assert shipped != [], "the registry returned no default-enabled plugin titles"
    assert Enum.reject(shipped, &MapSet.member?(markers, &1)) == []
  end
end
