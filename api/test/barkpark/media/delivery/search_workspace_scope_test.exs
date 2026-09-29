defmodule Barkpark.Media.Delivery.SearchWorkspaceScopeTest do
  @moduledoc """
  The PROJECT RUNG of `Search.join_scope_workspace/3` (task-96d8720de593d82a).

  `Search.build_query/2` LEFT-JOINs the blob table against a PRE-SCOPED
  `mediaAsset` Document subquery. That subquery is what feeds a blob's
  title/tags into text matching, facets and highlights, so an asset doc that
  joins is an asset doc whose METADATA the caller reads.

  The subquery's workspace envelope has two rungs stacked in ONE parenthesis:

      is_nil(d.workspace_id) or
        (d.workspace_id == ^workspace_id and
           (is_nil(d.project_id) or d.project_id == ^project_id))

  Every fixture in the media fence exercised the WORKSPACE rung. Appending
  `or not is_nil(d.project_id)` to the inner parenthesis — making it
  unconditionally true and deleting the project rung while leaving the
  workspace rung byte-identical — left all 366 fence tests green. This file is
  the arm that reds it.

  ## Why the foreign doc carries dataset_id = NULL

  This is the `assets_scope_test` shape (task-7faee37433ed92be): a stacked
  clause is unmeasured when a SIBLING clause already excludes the bad row. If
  the foreign doc were stamped with its OWN project's `dataset_id`,
  `join_scope_dataset/3` would refuse it before the workspace envelope was ever
  consulted and the project rung would never be the discriminator. A NULL
  `dataset_id` with the `dataset` STRING stamped — the shape a projectless
  write actually produces — sails through `join_scope_dataset/3`'s NULL-tolerant
  leg, so the PROJECT RUNG is the only thing left that can refuse it.

  The ARMED control in the test proves that directly: with `:project_id`
  dropped from the read (the 2-arg workspace clause, which has no project rung
  at all) the very same doc DOES join.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"
  @dataset "production"

  # Insert a `mediaAsset` Document straight through the changeset (no hook
  # pipeline) so the test isolates the SQL scope filter — mirrors
  # `Barkpark.Plugins.Media.AssetsScopeTest.insert_asset_doc!/2`.
  defp insert_asset_doc!(media_file_id, title, scope) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        doc_id: "drafts.asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
        title: title,
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file_id, "tags" => []}
      }
      |> Map.merge(scope)

    {:ok, doc} = %Document{} |> Document.changeset(attrs) |> Repo.insert()
    doc
  end

  # The `{blob id, joined asset doc_id}` pairs `build_query/2` actually emits.
  # Asserting on the JOINED DOC (not on the blob) is what makes this file
  # measure `asset_doc_join_query/4` and nothing else: the blob side is scoped
  # by `scope_media_to_dataset/3` + `scope_to_workspace_or_global/3`, which are
  # different clauses with their own proofs.
  defp joined_pairs(opts) do
    @dataset
    |> Search.build_query(opts)
    |> exclude(:order_by)
    |> select([m, d], {m.id, d.doc_id})
    |> Repo.all()
  end

  describe "join_scope_workspace/3 — the PROJECT rung" do
    test "a SIBLING PROJECT's asset doc inside the caller's OWN workspace never joins" do
      ws = create_workspace!()
      proj_reader = create_project!(ws)
      proj_foreign = create_project!(ws)

      {:ok, ds_reader} = Tenancy.get_or_create_dataset(proj_reader, @dataset)
      {:ok, ds_foreign} = Tenancy.get_or_create_dataset(proj_foreign, @dataset)

      refute ds_reader.id == ds_foreign.id,
             "FIXTURE NOT ARMED: the two projects resolved the SAME dataset row"

      # The caller's own blob, UNSTAMPED (dataset_id NULL, `dataset` STRING
      # stamped — the shape `Media.put_scope_attrs/2`'s legit-nil arm writes).
      # Load-bearing for the ARMED control below: `scope_media_to_dataset/3`
      # resolves its dataset_id from the READ's project, so a blob stamped with
      # `ds_reader.id` is dropped by the BLOB-side filter the moment the project
      # is taken off the read — and the control would then be measuring that
      # filter instead of the join. A NULL dataset_id is admitted by BOTH of
      # that function's arms, which holds the blob side CONSTANT across the two
      # reads and leaves the join as the only thing that moves.
      {:ok, blob} = create_media_file_in!(ws, proj_reader, %{dataset_id: nil}, @dataset)

      assert is_nil(blob.dataset_id)

      # The sibling project's asset doc, pointed at the READER's blob — the
      # metadata-leak shape this join exists to close, one rung down. NULL
      # dataset_id is load-bearing: see the moduledoc.
      foreign =
        insert_asset_doc!(blob.id, "Sibling project title", %{
          workspace_id: ws.id,
          project_id: proj_foreign.id,
          dataset_id: nil
        })

      assert is_nil(foreign.dataset_id),
             "FIXTURE NOT ARMED: a stamped dataset_id is refused by join_scope_dataset/3 " <>
               "before the workspace envelope is reached, so the project rung would " <>
               "never be the discriminator"

      assert foreign.workspace_id == ws.id,
             "FIXTURE NOT ARMED: the foreign doc must share the reader's workspace, " <>
               "or the WORKSPACE rung is the excluder and the project rung is untested"

      refute foreign.project_id == proj_reader.id

      # ARMED — drop only the project from the read. `join_scope_workspace/3`
      # then takes its 2-arg clause, which has NO project rung, and the very
      # same doc joins. Everything except the project rung admits this row.
      assert {blob.id, foreign.doc_id} in joined_pairs(workspace_id: ws.id),
             "FIXTURE NOT ARMED: the foreign asset doc does not join even with the " <>
               "project dropped, so its absence below proves nothing about the project rung"

      refute {blob.id, foreign.doc_id} in joined_pairs(
               workspace_id: ws.id,
               project_id: proj_reader.id
             ),
             "CROSS-PROJECT METADATA LEAK: a sibling project's mediaAsset doc joined to " <>
               "this project's blob in Search.build_query/2, feeding its title and tags " <>
               "into the reader's text matching, facets and highlights. Only the project " <>
               "rung of join_scope_workspace/3 can refuse it — the workspace rung admits " <>
               "it by construction and join_scope_dataset/3 admits it on its NULL leg."
    end

    test "NEVER-WORSE — the caller's OWN asset doc still joins under a full project scope" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, @dataset)

      {:ok, blob} = create_media_file_in!(ws, proj, %{dataset_id: ds.id}, @dataset)

      mine =
        insert_asset_doc!(blob.id, "My own title", %{
          workspace_id: ws.id,
          project_id: proj.id,
          dataset_id: ds.id
        })

      assert {blob.id, mine.doc_id} in joined_pairs(workspace_id: ws.id, project_id: proj.id),
             "the project rung refused the caller's OWN asset doc — a fix that narrows " <>
               "this clause past `d.project_id == ^project_id` blanks every scoped " <>
               "media search's metadata"
    end

    test "NEVER-WORSE — a legacy NULL-project asset doc still joins under a project scope" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, @dataset)

      {:ok, blob} = create_media_file_in!(ws, proj, %{dataset_id: ds.id}, @dataset)

      # `Content.WriteScope.put_scope_attrs/2` degrades to no project key when
      # no project resolves, so a workspace-only write lands exactly here. The
      # `is_nil(d.project_id)` leg of the rung is what keeps it visible.
      legacy =
        insert_asset_doc!(blob.id, "Legacy projectless title", %{
          workspace_id: ws.id,
          project_id: nil,
          dataset_id: nil
        })

      assert {blob.id, legacy.doc_id} in joined_pairs(workspace_id: ws.id, project_id: proj.id),
             "NEVER-WORSE REGRESSION: a legacy NULL-project asset doc vanished from its " <>
               "own tenant's media search join — the rung's `is_nil(d.project_id)` leg is gone"
    end
  end

  describe "the fixture is a real blob read, not an empty set" do
    test "CONTROL — the reader's own blob is in the result set at all" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, @dataset)
      {:ok, blob} = create_media_file_in!(ws, proj, %{dataset_id: ds.id}, @dataset)

      assert %MediaFile{} = Repo.get(MediaFile, blob.id)

      ids = joined_pairs(workspace_id: ws.id, project_id: proj.id) |> Enum.map(&elem(&1, 0))

      assert blob.id in ids,
             "the blob-side envelopes dropped the reader's own row — every refutation " <>
               "in this file would pass vacuously"
    end
  end
end
