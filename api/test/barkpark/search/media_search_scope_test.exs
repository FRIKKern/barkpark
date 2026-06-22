defmodule Barkpark.Search.MediaSearchScopeTest do
  @moduledoc """
  Regression tests for two media-search bugs:

    * BUG 1 (barkpark-4r7q): `apply_sort/2` called `hd([])` on the zero-term
      relevance path → 500 whenever the parsed query had no terms/phrases.
    * BUG 2 (barkpark-9uni): `tags_facet_sql/2` filtered on `m.dataset` only,
      with no tenant scope, leaking tag counts across every workspace sharing
      the dataset string. The facet must be scoped to the same workspace as
      the primary results (mirror of the Ecto `scope_to_workspace/3` path).
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Search, as: Search

  @dataset "test"
  @asset_type "mediaAsset"

  # Insert a `mediaAsset` Document linked to `media_file` with the given tags,
  # stamped to the same workspace/project as the blob — directly through the
  # changeset (no hook pipeline) so the test isolates the SQL scope filter.
  defp link_asset!(media_file, workspace, project, tags) do
    suffix = System.unique_integer([:positive])

    {:ok, _doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: "asset #{suffix}",
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file.id, "tags" => tags},
        workspace_id: workspace.id,
        project_id: project && project.id
      })
      |> Barkpark.Repo.insert()
  end

  describe "BUG 1 — apply_sort empty-term relevance path" do
    test "relevance sort with a no-term query (prefix only) returns 200, not a 500 crash" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, file} = create_media_file_in!(ws, proj, %{}, @dataset)
      link_asset!(file, ws, proj, ["alpha"])

      # "foo*" parses to terms: [], phrases: [], prefixes: ["foo"] — a non-empty
      # parsed map whose `terms ++ phrases` is []. The pre-fix code ran
      # `hd([])` here and raised ArgumentError, 500ing the search.
      assert {files, total, _facets, _meta} =
               Search.search(@dataset,
                 q: "foo*",
                 sort: "relevance",
                 workspace_id: ws.id,
                 project_id: proj.id
               )

      assert is_list(files)
      assert is_integer(total)
    end

    test "relevance sort over an empty media set returns an empty result, not a crash" do
      ws = create_workspace!()
      proj = create_project!(ws)

      # No media at all in this workspace + a no-term relevance query: the exact
      # zero-hit recovery path that exercised hd([]).
      assert {[], total, _facets, _meta} =
               Search.search(@dataset,
                 q: "-nope",
                 sort: "relevance",
                 workspace_id: ws.id,
                 project_id: proj.id
               )

      assert total == 0
    end
  end

  describe "BUG 2 — tags_facet_sql workspace scoping" do
    test "tags facet for workspace A excludes workspace B's tags (no cross-workspace leak)" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      # Both workspaces share the SAME dataset string — isolation must come
      # from workspace_id, not the dataset leaf.
      {:ok, file_a} = create_media_file_in!(ws_a, proj_a, %{}, @dataset)
      link_asset!(file_a, ws_a, proj_a, ["a-only", "shared"])

      {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @dataset)
      link_asset!(file_b, ws_b, proj_b, ["b-only", "shared"])

      tags_facet = fn scope ->
        {_files, _total, facets, _meta} =
          Search.search(@dataset, [facets: ["tags"]] ++ scope)

        facets["tags"] |> Enum.map(& &1.value)
      end

      a_tags = tags_facet.(workspace_id: ws_a.id, project_id: proj_a.id)
      b_tags = tags_facet.(workspace_id: ws_b.id, project_id: proj_b.id)

      # A sees its own tags and NOT B's exclusive tag.
      assert "a-only" in a_tags

      refute "b-only" in a_tags,
             "CROSS-WORKSPACE LEAK: workspace A's tags facet #{inspect(a_tags)} " <>
               "included workspace B's exclusive tag 'b-only'"

      # Symmetric: B sees its own and not A's.
      assert "b-only" in b_tags
      refute "a-only" in b_tags
    end

    test "the 'shared' tag count is not double-counted across workspaces" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      {:ok, file_a} = create_media_file_in!(ws_a, proj_a, %{}, @dataset)
      link_asset!(file_a, ws_a, proj_a, ["shared"])

      {:ok, file_b} = create_media_file_in!(ws_b, proj_b, %{}, @dataset)
      link_asset!(file_b, ws_b, proj_b, ["shared"])

      {_files, _total, facets, _meta} =
        Search.search(@dataset, facets: ["tags"], workspace_id: ws_a.id, project_id: proj_a.id)

      shared = Enum.find(facets["tags"], &(&1.value == "shared"))

      assert shared, "expected a 'shared' tag facet entry for workspace A"

      assert shared.count == 1,
             "expected workspace A's 'shared' count to be 1 (its own asset only), " <>
               "got #{shared.count} — B's matching asset leaked into the count"
    end
  end
end
