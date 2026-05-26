defmodule Barkpark.Plugins.Media.AssetsScopeTest do
  @moduledoc """
  Tenancy-scope regression tests for `Barkpark.Plugins.Media.Assets`
  asset-doc lookups (barkpark-5p3y).

  Two guarantees are proved here:

    * NEVER-WORSE: media.ex writes asset docs WITHOUT workspace/project scope,
      so `dataset_id` lands NULL while the `dataset` STRING is stamped. The
      default (untenanted) read path resolves the dataset STRING -> dataset_id
      and would have filtered authoritatively on `dataset_id` only — making
      those legacy NULL-dataset_id rows INVISIBLE. The NULL-tolerant filter
      (`dataset_id == ^id OR (is_nil(dataset_id) AND dataset == ^dataset)`)
      keeps them visible.

    * CROSS-TENANT: two workspaces sharing the `production` dataset STRING (but
      distinct dataset_id) each own an asset doc for the SAME mediaFileId. A
      lookup scoped to workspace B must resolve B's doc, never A's — the
      workspace envelope closes the leak.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"
  @dataset "production"

  # Insert a `mediaAsset` Document straight through the changeset (no hook
  # pipeline) so the test isolates the SQL scope filter. `scope` is a map of
  # extra column overrides (workspace_id / project_id / dataset_id); omitting
  # them leaves the NULL-stamped legacy shape that media.ex actually writes.
  # The doc_id carries the `drafts.` prefix so it matches the real draft asset
  # row Content.create_document stamps (the delete path resolves by doc_id).
  defp insert_asset_doc!(media_file_id, scope) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        doc_id: "drafts.asset-#{suffix}",
        type: @asset_type,
        dataset: @dataset,
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

  describe "find_by_media_file_id/3 — never-worse (legacy NULL dataset_id)" do
    test "returns a legacy asset doc whose dataset_id is NULL on the default path" do
      {_ws, default_project} = ensure_default_scope!()

      # Force a real `production` dataset_id under the Default project so the
      # read's `resolve_dataset_id` returns a non-nil id and exercises the
      # dataset_id-filtering branch. Without this the test would fall into the
      # legacy string-only branch and never prove the OR clause.
      {:ok, _dataset} = Tenancy.get_or_create_dataset(default_project, @dataset)

      media_file_id = "blob-#{System.unique_integer([:positive])}"

      # Legacy shape: dataset STRING stamped, dataset_id NULL, no workspace.
      legacy = insert_asset_doc!(media_file_id, %{dataset_id: nil})
      assert is_nil(legacy.dataset_id)

      found = Assets.find_by_media_file_id(media_file_id, @dataset)

      assert found,
             "NEVER-WORSE REGRESSION: a legacy mediaAsset doc with dataset_id=NULL " <>
               "was invisible on the default read path — the strict dataset_id filter " <>
               "would have missed it; the NULL-tolerant OR clause must surface it"

      assert found.doc_id == legacy.doc_id
    end
  end

  describe "find_by_media_file_id/3 — cross-tenant isolation" do
    test "scoped to workspace B resolves B's asset doc, never workspace A's" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      {:ok, ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)
      {:ok, ds_b} = Tenancy.get_or_create_dataset(proj_b, @dataset)

      refute ds_a.id == ds_b.id

      # SAME mediaFileId, distinct dataset_id, each stamped to its own workspace.
      media_file_id = "shared-blob-#{System.unique_integer([:positive])}"

      doc_a =
        insert_asset_doc!(media_file_id, %{
          workspace_id: ws_a.id,
          project_id: proj_a.id,
          dataset_id: ds_a.id
        })

      doc_b =
        insert_asset_doc!(media_file_id, %{
          workspace_id: ws_b.id,
          project_id: proj_b.id,
          dataset_id: ds_b.id
        })

      found =
        Assets.find_by_media_file_id(media_file_id, @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      assert found.doc_id == doc_b.doc_id,
             "CROSS-WORKSPACE LEAK: lookup scoped to workspace B resolved " <>
               "#{inspect(found.doc_id)} — expected B's doc #{inspect(doc_b.doc_id)}, " <>
               "not A's #{inspect(doc_a.doc_id)}"

      refute found.doc_id == doc_a.doc_id
    end
  end

  describe "find_by_media_file_ids/3 — cross-tenant isolation" do
    test "batch lookup scoped to workspace B returns only B's asset doc" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      {:ok, ds_a} = Tenancy.get_or_create_dataset(proj_a, @dataset)

      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)
      {:ok, ds_b} = Tenancy.get_or_create_dataset(proj_b, @dataset)

      media_file_id = "shared-blob-#{System.unique_integer([:positive])}"

      doc_a =
        insert_asset_doc!(media_file_id, %{
          workspace_id: ws_a.id,
          project_id: proj_a.id,
          dataset_id: ds_a.id
        })

      doc_b =
        insert_asset_doc!(media_file_id, %{
          workspace_id: ws_b.id,
          project_id: proj_b.id,
          dataset_id: ds_b.id
        })

      result =
        Assets.find_by_media_file_ids([media_file_id], @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      assert %{^media_file_id => found} = result
      assert found.doc_id == doc_b.doc_id
      refute found.doc_id == doc_a.doc_id
    end
  end
end
