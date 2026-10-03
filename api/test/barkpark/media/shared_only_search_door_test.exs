defmodule Barkpark.Media.SharedOnlySearchDoorTest do
  @moduledoc """
  The media search door under the `:shared_only` sentinel, as a black box
  (task-273fd8908ec43aa4).

  `GET /v1/media/:dataset/search` hands `scope_opts(conn)` to
  `Media.search_files/2` -> `Media.Delivery.Search.search/2`. For a request that
  resolved no workspace that is `workspace_id: :shared_only`. On the text-match
  arm, `Media.Delivery.Retriever.asset_doc_join_query/3` gates the dataset
  resolver on `is_binary(workspace_id)`. The sentinel is not a binary, so it
  ROUTES AROUND that guard: the workspace key is dropped and
  `resolve_read_dataset_id/2` takes the Default-project branch. The decision
  recorded at that site is to leave it there, because the next clause
  (`join_scope_workspace/3`'s `:shared_only` arm, `workspace_id IS NULL`) is
  what scopes the joined metadata, and the blob list is clamped separately.

  `shared_only_sentinel_scope_test.exs` proves the arm at query-SHAPE level.
  This file proves what the door RETURNS, which is what the decision rests on.
  If someone reorders or drops the downstream clamp, these arms red even
  though the guard above it never changed:

    * a shared-layer blob whose shared-layer asset doc matches comes back;
    * a foreign workspace's blob with matching metadata does not;
    * a shared-layer blob whose ONLY matching metadata is a foreign
      workspace's asset doc does not (no metadata attach across tenants).

  Non-vacuity: the same fixture read with NO workspace key (the documented
  explicit-global read) returns all three rows, so the absences above are the
  sentinel's doing and not an unreachable fixture.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @dataset "shared-only-search-door"
  @asset_type "mediaAsset"
  @marker "zqsharedonlydoor"

  setup do
    foreign_ws = create_workspace!()
    foreign_proj = create_project!(foreign_ws)

    # S: shared-layer blob + shared-layer asset doc whose title matches.
    shared = shared_blob!(foreign_ws, foreign_proj)
    asset_doc!(shared, nil, nil, "#{@marker} shared")

    # F: a foreign workspace's blob + its own asset doc whose title matches.
    {:ok, foreign} = create_media_file_in!(foreign_ws, foreign_proj, %{}, @dataset)
    asset_doc!(foreign, foreign_ws.id, foreign_proj.id, "#{@marker} foreign")

    # X: a shared-layer blob whose ONLY matching metadata is a foreign asset doc.
    crossed = shared_blob!(foreign_ws, foreign_proj)
    asset_doc!(crossed, foreign_ws.id, foreign_proj.id, "#{@marker} crossed")

    %{shared: shared, foreign: foreign, crossed: crossed}
  end

  defp search_ids(scope) do
    {files, _total, _facets, _meta} = Media.search_files(@dataset, [q: @marker] ++ scope)
    files |> Enum.map(& &1.id) |> MapSet.new()
  end

  # Created in a throwaway workspace, then the tenancy columns are NULLed: a
  # fixture that merely omits scope would get a Default-owned row instead of the
  # pre-tenancy shared-layer shape under test.
  defp shared_blob!(ws, proj) do
    {:ok, file} = create_media_file_in!(ws, proj, %{}, @dataset)

    {1, _} =
      Repo.update_all(from(m in MediaFile, where: m.id == ^file.id),
        set: [workspace_id: nil, project_id: nil]
      )

    Repo.get!(MediaFile, file.id)
  end

  defp asset_doc!(file, workspace_id, project_id, title) do
    suffix = System.unique_integer([:positive])

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "shared-only-door-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "published",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => file.id}
      })
      |> Repo.insert()

    {1, _} =
      Repo.update_all(from(d in Document, where: d.id == ^doc.id),
        set: [workspace_id: workspace_id, project_id: project_id]
      )

    doc
  end

  test "the sentinel returns the shared layer's metadata match", %{shared: shared} do
    assert MapSet.member?(search_ids(workspace_id: :shared_only), shared.id)
  end

  test "the sentinel does NOT return a foreign workspace's blob", %{foreign: foreign} do
    refute MapSet.member?(search_ids(workspace_id: :shared_only), foreign.id)
  end

  test "the sentinel does NOT attach a foreign asset doc's metadata to a shared blob",
       %{crossed: crossed} do
    refute MapSet.member?(search_ids(workspace_id: :shared_only), crossed.id)
  end

  test "the sentinel returns the shared layer and nothing else", %{shared: shared} do
    assert search_ids(workspace_id: :shared_only) == MapSet.new([shared.id])
  end

  test "NON-VACUITY: the unscoped global read reaches every fixture row",
       %{shared: shared, foreign: foreign, crossed: crossed} do
    # No :workspace_id key at all is the documented explicit-global read (the
    # join's nil arm leaves the metadata filter OFF). If a row is missing here,
    # the fixture never reached the scope clauses and the absences above prove
    # nothing.
    ids = search_ids([])

    assert MapSet.member?(ids, shared.id), "the shared row is unreachable — fixture broken"

    assert MapSet.member?(ids, foreign.id),
           "the foreign blob is unreachable even globally — its absence under the " <>
             "sentinel is vacuous"

    assert MapSet.member?(ids, crossed.id),
           "the crossed blob does not match through its foreign metadata even globally — " <>
             "the metadata-attach absence under the sentinel is vacuous"
  end
end
