defmodule Barkpark.Plugins.Media.AssetsDatasetFallbackBranchTest do
  @moduledoc """
  The UNREACHED branch of `Barkpark.Plugins.Media.Assets.scope_asset_dataset/3`.

  `scope_asset_dataset/3` has two branches. The first — taken when
  `resolve_dataset_id/2` finds a `Tenancy.Dataset` row — filters on
  `d.dataset_id` with a NULL-tolerant leg, and `AssetsScopeTest` measures it.
  The second is the back-compat fallback taken when NO dataset row resolves:

      _ ->
        where(query, [d], d.dataset == ^dataset)

  In that branch the `dataset` STRING comparison is the ONLY dataset
  confinement the read has. `scope_asset_workspace/3` runs after it and keeps
  the read inside its workspace, so widening this conjunct does not cross a
  tenant — it crosses DATASETS inside one workspace, on every door that
  composes the envelope: `Assets.find_by_media_file_ids/3`,
  `Assets.find_by_media_file_id/3` (via `asset_doc_scope/4`) and
  `Barkpark.Media.Storage.Relations`.

  ## Why this file exists: both mutation directions were green

  A hunt widened the conjunct (`d.dataset == ^dataset or not is_nil(d.dataset)
  or is_nil(d.dataset)`) and ran every test naming the envelope's doors:
  `44 tests, 0 failures`, identical to the unmutated control. A green alone
  proves nothing — it can mean the fence is unmeasured OR that the branch never
  executes. So the opposite mutation was run as the discriminating control:
  NARROWING the conjunct to admit nothing (`d.dataset == ^dataset and
  is_nil(d.dataset)`) ALSO returned `44 tests, 0 failures`.

  Two mutations in opposite directions, both green, is the signature of a
  branch no test reaches. `AssetsScopeTest` says as much in its own words —
  it calls `get_or_create_dataset/2` up front precisely so the read "does not
  fall into the legacy string-only branch".

  This file reaches that branch and pins the conjunct inside it.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"
  @read_dataset "production"
  @foreign_dataset "staging"

  defp insert_asset_doc!(media_file_id, dataset, scope) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        doc_id: "drafts.asset-#{suffix}",
        type: @asset_type,
        dataset: dataset,
        title: "asset #{suffix}",
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file_id}
      }
      |> Map.merge(scope)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(attrs)
      |> Barkpark.Repo.insert()

    doc
  end

  # A workspace + project with NO Dataset rows at all. That — not a missing
  # project — is what drives `resolve_dataset_id/2` to nil, because
  # `Tenancy.scope_project_id/1` prefers an explicit `:project_id` and only
  # degrades to the seeded Default project when none is given.
  defp datasetless_scope! do
    ws = create_workspace!()
    proj = create_project!(ws)

    # PRECONDITION, not a control: if either dataset string resolved to a row,
    # `scope_asset_dataset/3` would take its OTHER branch and this file would
    # silently re-measure what AssetsScopeTest already covers.
    refute Tenancy.get_dataset(proj.id, @read_dataset),
           "PRECONDITION: the project must have no `#{@read_dataset}` dataset row, " <>
             "otherwise resolve_dataset_id/2 returns an id and the fallback branch " <>
             "is never taken"

    refute Tenancy.get_dataset(proj.id, @foreign_dataset),
           "PRECONDITION: the project must have no `#{@foreign_dataset}` dataset row"

    {ws, proj}
  end

  describe "scope_asset_dataset/3 — the no-resolved-dataset fallback branch" do
    test "a SIBLING DATASET's asset doc in the SAME workspace never resolves" do
      {ws, proj} = datasetless_scope!()

      media_file_id = "blob-#{System.unique_integer([:positive])}"
      scope = %{workspace_id: ws.id, project_id: proj.id, dataset_id: nil}

      mine = insert_asset_doc!(media_file_id, @read_dataset, scope)
      foreign = insert_asset_doc!(media_file_id, @foreign_dataset, scope)

      # Both rows are stamped to the SAME workspace and project, so
      # scope_asset_workspace/3 admits both. The dataset STRING conjunct in the
      # fallback branch is the only thing left that can exclude `foreign`.
      assert is_nil(mine.dataset_id)
      assert is_nil(foreign.dataset_id)
      assert mine.workspace_id == foreign.workspace_id
      assert mine.project_id == foreign.project_id

      found =
        Assets.find_by_media_file_ids([media_file_id], @read_dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      doc = Map.get(found, media_file_id)

      assert doc,
             "the read's OWN dataset row must still resolve through the fallback branch"

      assert doc.doc_id == mine.doc_id,
             "LEAK: the fallback branch returned the `#{@foreign_dataset}` asset doc for a " <>
               "read scoped to `#{@read_dataset}`. In this branch the `d.dataset == ^dataset` " <>
               "conjunct is the only dataset confinement the query has — " <>
               "scope_asset_workspace/3 cannot tell these two rows apart."

      refute doc.doc_id == foreign.doc_id
    end

    test "a read for a dataset with NO rows resolves nothing, rather than everything" do
      {ws, proj} = datasetless_scope!()

      media_file_id = "blob-#{System.unique_integer([:positive])}"

      _foreign =
        insert_asset_doc!(media_file_id, @foreign_dataset, %{
          workspace_id: ws.id,
          project_id: proj.id,
          dataset_id: nil
        })

      found =
        Assets.find_by_media_file_ids([media_file_id], @read_dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      assert found == %{},
             "LEAK: a read scoped to `#{@read_dataset}` surfaced a doc stamped " <>
               "`#{@foreign_dataset}`. Widen the fallback branch's conjunct and this is " <>
               "the door that opens."
    end
  end
end
