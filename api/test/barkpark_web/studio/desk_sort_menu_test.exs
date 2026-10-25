defmodule BarkparkWeb.Studio.DeskSortMenuTest do
  @moduledoc """
  task-fa57815041bead3d: a schema's `desk.sortOrderings` (Sanity's
  `orderings`) are choices in the desk list's sort menu. Declaring them does
  not change how the list opens; picking one sorts that list only.
  Synthetic fixtures only.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Studio.PaneBuilder

  @sorts [
    %{
      "name" => "manual",
      "title" => "Manual order",
      "by" => [%{"field" => "rank", "direction" => "asc"}]
    },
    %{
      "name" => "titleAsc",
      "title" => "Title A-Z",
      "by" => [%{"field" => "title", "direction" => "asc"}]
    }
  ]

  defp changeset(desk) do
    SchemaDefinition.changeset(%SchemaDefinition{}, %{
      name: "shelf",
      title: "Shelf",
      visibility: "public",
      dataset: "x",
      fields: [%{"name" => "title", "type" => "string"}],
      desk: desk
    })
  end

  defp seed(dataset) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(%{
      name: "shelf",
      title: "Shelf",
      icon: "file",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "type" => "string"},
        %{"name" => "rank", "type" => "number"}
      ],
      desk: %{"sortOrderings" => @sorts}
    })
    |> Repo.insert!()

    # Created in this order, so the default order (last edited first) is c, b, a.
    # Manual order by rank is b, c, a.
    for {id, title, rank} <- [{"a", "Alpha", 3}, {"b", "Bravo", 1}, {"c", "Charlie", 2}] do
      {:ok, _} =
        Content.create_document(
          "shelf",
          %{"doc_id" => id, "title" => title, "content" => %{"rank" => rank}},
          dataset
        )

      Process.sleep(10)
    end
  end

  defp list_pane(dataset, opts \\ []) do
    {panes, _editor} = PaneBuilder.build(dataset, ["shelf"], opts)
    List.last(panes)
  end

  defp ids(pane), do: for(%{type: :doc, id: id} <- pane.items, do: id)

  test "the pane lists the declared sorts and opens in the default order" do
    seed("sort_menu_default")
    pane = list_pane("sort_menu_default")

    assert pane.sort_options == [
             %{name: "manual", title: "Manual order"},
             %{name: "titleAsc", title: "Title A-Z"}
           ]

    assert pane.active_sort == nil
    assert ids(pane) == ["c", "b", "a"]
  end

  test "a picked sort orders that list" do
    seed("sort_menu_pick")

    manual = list_pane("sort_menu_pick", list_sorts: %{"shelf" => "manual"})
    assert manual.active_sort == "manual"
    assert ids(manual) == ["b", "c", "a"]

    by_title = list_pane("sort_menu_pick", list_sorts: %{"shelf" => "titleAsc"})
    assert ids(by_title) == ["a", "b", "c"]
  end

  test "a name the schema does not declare keeps the default order" do
    seed("sort_menu_unknown")
    pane = list_pane("sort_menu_unknown", list_sorts: %{"shelf" => "nope"})
    assert pane.active_sort == nil
    assert ids(pane) == ["c", "b", "a"]
  end

  test "sort_options/1 skips an entry it cannot use" do
    schema = %{
      desk: %{
        "sortOrderings" => [
          %{"name" => "", "title" => "No name", "by" => [%{"field" => "rank"}]},
          %{"name" => "noBy", "title" => "No by"},
          %{
            "name" => "badDir",
            "title" => "Bad",
            "by" => [%{"field" => "rank", "direction" => "up"}]
          },
          %{"name" => "ok", "title" => "Fine", "by" => [%{"field" => "rank"}]}
        ]
      }
    }

    assert PaneBuilder.sort_options(schema) == [
             %{name: "ok", title: "Fine", order: [{:field, "rank", :asc}]}
           ]

    assert PaneBuilder.sort_options(nil) == []
    assert PaneBuilder.sort_options(%{desk: %{}}) == []
  end

  test "the changeset accepts sortOrderings and refuses a malformed entry" do
    assert changeset(%{"sortOrderings" => @sorts}).valid?

    refute changeset(%{"sortOrderings" => [%{"name" => "x", "title" => "X", "by" => []}]}).valid?

    refute changeset(%{"sortOrderings" => [%{"title" => "X", "by" => [%{"field" => "f"}]}]}).valid?

    refute changeset(%{
             "sortOrderings" => [
               %{"name" => "x", "title" => "X", "by" => [%{"field" => "f", "direction" => "up"}]}
             ]
           }).valid?

    refute changeset(%{"sortOrderings" => "manual"}).valid?
  end
end
