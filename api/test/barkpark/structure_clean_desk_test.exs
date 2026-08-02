defmodule Barkpark.StructureCleanDeskTest do
  @moduledoc """
  Desk safety net for the clean-profile world (premium-setup A4): a fresh
  `bp setup` install registers ONLY paper + mediaAsset + mediaCollection —
  no post/page/project, no Settings singletons. Pins that the Studio desk
  renders that world without crashing: Papers list, media OUT of the tree by
  default (its placement is :top_menu — studio-structure-polish), no
  Settings node, and a zero-schema dataset still builds.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure
  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.PaneBuilder

  @host_node_ids ~w(post page project author category paper media-desk media-library content-types settings book)

  defp insert_schema!(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert!()
  end

  # The exact schema set a clean install ends up with: the Bulldocs `paper`
  # schema (public) + the Media plugin pair (private).
  defp seed_clean_schemas!(dataset) do
    insert_schema!(%{
      name: "paper",
      title: "Papers",
      icon: "📰",
      visibility: "public",
      dataset: dataset,
      fields: [%{"name" => "title", "title" => "Title", "type" => "string"}]
    })

    for spec <- [
          %{name: "mediaAsset", title: "Media Asset", icon: "🖼"},
          %{name: "mediaCollection", title: "Media Collection", icon: "📁"}
        ] do
      insert_schema!(Map.merge(spec, %{visibility: "private", dataset: dataset, fields: []}))
    end
  end

  test "paper+media-only desk: Papers list, media out of tree, no Settings, no crash" do
    dataset = "structure_clean_desk"
    seed_clean_schemas!(dataset)

    tree = Structure.build(dataset)

    paper =
      Enum.find(tree.items, fn n -> n.type == :document_type_list and n.id == "paper" end)

    assert %Node{type_name: "paper", title: "Papers"} = paper

    # Tiered desk (studio-structure-polish): media declares placement
    # :top_menu, so by DEFAULT the Media group is OUT of the tree (the host
    # top-menu Media tab is its home) and its types are claimed — they must
    # not resurface in …Rest.
    refute Enum.find(tree.items, &(&1.id == "media-desk")),
           "media placement is :top_menu by default → no Media group in the tree"

    rest = Enum.find(tree.items, &(&1.id == "rest"))

    if rest do
      rest_types = Enum.map(rest.items, & &1.type_name)
      refute "mediaAsset" in rest_types, "top-menu media types must not leak into …Rest"
      refute "mediaCollection" in rest_types
    end

    # mediaAsset/mediaCollection are excluded from Settings by name and paper
    # is public — with no other private schema there must be NO Settings node.
    refute Enum.any?(tree.items, &(&1.id == "settings")),
           "no Settings node expected in the clean-profile desk"

    # No demo-world nodes.
    for name <- ~w(post page project author category) do
      refute Enum.any?(tree.items, &(&1.id == name)),
             "unexpected #{name} node in a paper+media-only desk"
    end

    # Divider hygiene (maybe_join must not strand dividers around the
    # two-group desk).
    types = Enum.map(tree.items, & &1.type)
    refute List.first(types) == :divider, "no leading divider"
    refute List.last(types) == :divider, "no trailing divider"

    refute Enum.chunk_every(types, 2, 1, :discard)
           |> Enum.any?(fn pair -> pair == [:divider, :divider] end),
           "no consecutive dividers"
  end

  test "the paper list pane renders with zero documents (no crash, no editor)" do
    dataset = "structure_clean_desk_panes"
    seed_clean_schemas!(dataset)

    {panes, editor} = PaneBuilder.build(dataset, ["paper"])

    assert editor == nil
    assert panes != []

    paper_pane = List.last(panes)
    assert paper_pane.type_name == "paper"
    assert paper_pane.items == []
  end

  test "zero schemas: build/1 still returns a tree with no host nodes and does not raise" do
    dataset = "structure_clean_desk_empty"

    tree = Structure.build(dataset)

    assert %Node{id: "root"} = tree

    refute Enum.any?(tree.items, fn n -> n.id in @host_node_ids end),
           "no host nodes expected with zero schemas, got: #{inspect(Enum.map(tree.items, & &1.id))}"
  end
end
