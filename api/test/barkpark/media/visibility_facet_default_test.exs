defmodule Barkpark.Media.VisibilityFacetDefaultTest do
  @moduledoc """
  The visibility facet and filter read an asset with no stored visibility as
  "public", as `Media.Storage.Access` does (task-f6f3e95109f87705). They read
  `content->>'bp_visibility'` bare, so on a dataset whose assets predate the
  field `facets=visibility` came back [] and `facet.visibility=public` matched
  nothing, while every hit said public.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Media.Delivery.Search

  @dataset "visfacet"

  setup do
    ws = create_workspace!()
    project = create_project!(ws, "default")
    {:ok, plain} = create_media_file_in!(ws, project, %{}, @dataset)
    {:ok, hidden} = create_media_file_in!(ws, project, %{}, @dataset)

    {:ok, _} =
      Content.create_document(
        "mediaAsset",
        %{
          "doc_id" => "asset-#{hidden.id}",
          "title" => "hidden",
          "content" => %{"mediaFileId" => hidden.id, "bp_visibility" => "private"}
        },
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    %{scope: [workspace_id: ws.id, project_id: project.id], plain: plain, hidden: hidden}
  end

  test "an asset with no stored visibility counts as public in the facet and the filter",
       %{scope: scope, plain: plain, hidden: hidden} do
    {_files, _total, facets, _} = Search.search(@dataset, scope ++ [facets: ["visibility"]])
    counts = Map.new(facets["visibility"] || [], &{&1.value, &1.count})
    assert counts == %{"public" => 1, "private" => 1}

    {files, total, _, _} =
      Search.search(@dataset, scope ++ [facet_selections: %{"visibility" => "public"}])

    assert total == 1 and Enum.map(files, & &1.id) == [plain.id]

    {files, _, _, _} = Search.search(@dataset, scope ++ [visibility: "private"])
    assert Enum.map(files, & &1.id) == [hidden.id]

    # The tag facet (hand-written SQL) narrows by the same default.
    {_, _, facets, _} =
      Search.search(@dataset, scope ++ [visibility: "public", facets: ["tags"]])

    assert is_list(facets["tags"])
  end
end
