defmodule Barkpark.Plugins.Media.AssetsLegacyDatasetStringFenceTest do
  @moduledoc """
  INVARIANT (mechanism-free, task-e4c51e3d65163201):

    An asset document that names one dataset is NEVER returned to a read
    resolved to a DIFFERENT dataset — whether it names its dataset by
    identifier or only by string, and whatever its workspace stamping.

  The statement names no function and no column on purpose. Replacing the
  legacy-compatibility scheme with some other one does not satisfy it; only
  keeping the cross-dataset answer empty does.

  Why this file exists, and what the rest of the media-scope suite already
  covers: the suite proves the NEVER-WORSE direction (a legacy unstamped asset
  doc stays visible inside its OWN dataset) and the cross-tenant direction for
  rows that carry a workspace stamp. Every legacy fixture in it builds the row
  with the SAME dataset name the read asks for, so the cross-dataset axis of
  the legacy population had no arm at all: widening the dataset envelope to
  admit any unstamped row left all six media-scope files green.

  The population measured here is the one the workspace envelope deliberately
  does NOT confine. A row written before the write-scope fix carries a NULL
  workspace stamp, and the workspace envelope admits such a row into EVERY
  workspace by design, on the written argument that the dataset envelope has
  already bounded the answer to one dataset. That argument is what these two
  arms check.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Tenancy

  @asset_type "mediaAsset"

  # The legacy shape media.ex wrote before the write-scope fix: the dataset
  # NAME is stamped, every scope column is NULL.
  defp insert_legacy_asset_doc!(media_file_id, dataset_name) do
    suffix = System.unique_integer([:positive])

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        doc_id: "drafts.asset-#{suffix}",
        type: @asset_type,
        dataset: dataset_name,
        dataset_id: nil,
        workspace_id: nil,
        project_id: nil,
        title: "legacy asset #{suffix}",
        status: "draft",
        rev: "r#{suffix}",
        content: %{"mediaFileId" => media_file_id}
      })
      |> Barkpark.Repo.insert()

    doc
  end

  describe "a legacy unstamped asset doc and a read resolved to another dataset" do
    test "the dataset name is the only discriminator: same row, same tenant opts, two datasets" do
      # ONE workspace, ONE project, TWO datasets — so the workspace and project
      # opts are IDENTICAL across both reads and cannot be what moved.
      ws = create_workspace!()
      proj = create_project!(ws)

      dataset_a = "legacy-home-#{System.unique_integer([:positive])}"
      dataset_b = "legacy-foreign-#{System.unique_integer([:positive])}"

      {:ok, ds_a} = Tenancy.get_or_create_dataset(proj, dataset_a)
      {:ok, ds_b} = Tenancy.get_or_create_dataset(proj, dataset_b)

      refute ds_a.id == ds_b.id,
             "PRECONDITION: the two datasets must be distinct rows, else neither " <>
               "arm below discriminates anything"

      media_file_id = "legacy-blob-#{System.unique_integer([:positive])}"
      legacy = insert_legacy_asset_doc!(media_file_id, dataset_a)

      # PRECONDITION on the fixture itself: this row is the legacy population,
      # not a stamped one. If a future write path starts stamping these columns
      # the arms below would stop measuring the thing they claim to measure.
      assert is_nil(legacy.dataset_id),
             "PRECONDITION: the fixture must carry a NULL dataset identifier"

      assert is_nil(legacy.workspace_id),
             "PRECONDITION: the fixture must carry a NULL workspace stamp, so the " <>
               "workspace envelope ADMITS it and the dataset answer is the last fence"

      opts = [workspace_id: ws.id, project_id: proj.id]

      # ARM 1 (never-worse mirror): resolved to the dataset the row names.
      home = Assets.find_by_media_file_ids([media_file_id], dataset_a, opts)

      assert Map.has_key?(home, media_file_id),
             "NEVER-WORSE: a legacy asset doc naming #{inspect(dataset_a)} must stay " <>
               "visible to a read resolved to #{inspect(dataset_a)} — got #{inspect(Map.keys(home))}"

      assert home[media_file_id].doc_id == legacy.doc_id

      # ARM 2 (the fence): the SAME row, the SAME opts, a DIFFERENT dataset.
      foreign = Assets.find_by_media_file_ids([media_file_id], dataset_b, opts)

      assert foreign == %{},
             "CROSS-DATASET LEAK: a legacy asset doc naming #{inspect(dataset_a)} was " <>
               "returned to a read resolved to #{inspect(dataset_b)}. The workspace " <>
               "envelope admits this row into every workspace because its workspace " <>
               "stamp is NULL, so the dataset answer is the ONLY thing keeping a " <>
               "foreign dataset's asset document body out. Got: #{inspect(Map.keys(foreign))}"
    end

    test "the single-blob read door answers the same way on the same row" do
      ws = create_workspace!()
      proj = create_project!(ws)

      dataset_a = "legacy-home-#{System.unique_integer([:positive])}"
      dataset_b = "legacy-foreign-#{System.unique_integer([:positive])}"

      {:ok, _ds_a} = Tenancy.get_or_create_dataset(proj, dataset_a)
      {:ok, _ds_b} = Tenancy.get_or_create_dataset(proj, dataset_b)

      media_file_id = "legacy-blob-#{System.unique_integer([:positive])}"
      legacy = insert_legacy_asset_doc!(media_file_id, dataset_a)

      opts = [workspace_id: ws.id, project_id: proj.id]

      home = Assets.find_by_media_file_id(media_file_id, dataset_a, opts)

      assert home && home.doc_id == legacy.doc_id,
             "NEVER-WORSE: the single-blob door must still resolve the row inside its " <>
               "own dataset"

      foreign = Assets.find_by_media_file_id(media_file_id, dataset_b, opts)

      refute foreign,
             "CROSS-DATASET LEAK on the single-blob door: resolved " <>
               "#{inspect(foreign && foreign.doc_id)} for a read bound to " <>
               "#{inspect(dataset_b)} — this row names #{inspect(dataset_a)}"
    end
  end
end
