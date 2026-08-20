defmodule Barkpark.Media.Storage.MediaFileFkTest do
  @moduledoc """
  FK-abort containment for MediaFile.changeset/2 (Felix W14, the W13
  changeset-FK-abort scar-class).

  `media_files.workspace_id/project_id/dataset_id` are real Postgres FKs
  (migrations 20260527110100 + 20260527131000, default-derived constraint
  names `media_files_<col>_fkey`). Without `foreign_key_constraint/2` in the
  changeset, an insert referencing a vanished row — a workspace/project
  deleted concurrently mid-upload, or a cross-instance blob push carrying a
  foreign id — RAISES Ecto.ConstraintError out of `Repo.insert` (a 500)
  instead of returning `{:error, changeset}`.

  Each bad-FK insert lives in its OWN test: a Postgres FK violation aborts
  the sandbox transaction, so nothing may run after it in the same test.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  defp attrs(overrides) do
    suffix = System.unique_integer([:positive])

    Map.merge(
      %{
        filename: "fk-#{suffix}.png",
        original_name: "fk-#{suffix}.png",
        path: "fk/#{suffix}.png",
        mime_type: "image/png",
        size: 1
      },
      overrides
    )
  end

  defp insert(overrides) do
    %MediaFile{} |> MediaFile.changeset(attrs(overrides)) |> Repo.insert()
  end

  describe "bad FK references return {:error, changeset} (never a raise)" do
    test "non-existent workspace_id" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{workspace_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:workspace_id]
    end

    test "non-existent project_id" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{project_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:project_id]
    end

    test "non-existent dataset_id" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{dataset_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:dataset_id]
    end
  end

  describe "valid FK references still insert" do
    test "insert with live workspace/project/dataset succeeds" do
      ws = create_workspace!()
      project = create_project!(ws)

      {:ok, dataset} =
        Tenancy.create_dataset(project, %{slug: "production", name: "production"})

      assert {:ok, %MediaFile{} = file} =
               insert(%{workspace_id: ws.id, project_id: project.id, dataset_id: dataset.id})

      assert file.workspace_id == ws.id
      assert file.project_id == project.id
      assert file.dataset_id == dataset.id
    end
  end
end
