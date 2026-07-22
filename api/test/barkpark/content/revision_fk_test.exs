defmodule Barkpark.Content.RevisionFkTest do
  @moduledoc """
  FK-abort containment for Revision.changeset/2 (Felix W17, the
  changeset-FK-abort scar-class — the sibling to Content.Document / MediaFile /
  bulldocs Event / SchemaDefinition).

  `revisions.document_id/workspace_id/project_id/dataset_id` are ALL real
  Postgres FKs: the three scope columns from
  `references(:workspaces/:projects/:datasets)` (migration
  20260527160000_cascade_content_on_scope_delete) and `document_id` from
  `references(:documents)` (migration 20260719010000, constraint recreated as
  `revisions_document_id_fkey` by 20260719020200); every one carries the
  Ecto-default constraint name `revisions_<col>_fkey`.

  Without `foreign_key_constraint/2` in the changeset, an insert referencing a
  vanished row RAISES Ecto.ConstraintError out of the NON-BANG
  `Broadcast.save_revision` (called from `BlockOps.maybe_save_batch_revision`
  during Studio paper editing and from `ValueWriteback.tap_provenance_revision`)
  — bypassing both callers' `{:error, reason}` best-effort handlers, a 500 —
  instead of returning `{:error, changeset}`.

  Each bad-FK insert lives in its OWN test: a Postgres FK violation aborts the
  sandbox transaction, so nothing may run after it in the same test.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Revision
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  defp attrs(overrides) do
    suffix = System.unique_integer([:positive])

    Map.merge(
      %{
        doc_id: "fk-rev-#{suffix}",
        type: "post",
        action: "update"
      },
      overrides
    )
  end

  defp insert(overrides) do
    %Revision{} |> Revision.changeset(attrs(overrides)) |> Repo.insert()
  end

  describe "bad FK references return {:error, changeset} (never a raise)" do
    test "non-existent document_id" do
      assert {:error, %Ecto.Changeset{} = cs} = insert(%{document_id: Ecto.UUID.generate()})
      assert {"does not exist", _} = cs.errors[:document_id]
    end

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

      assert {:ok, %Revision{} = revision} =
               insert(%{workspace_id: ws.id, project_id: project.id, dataset_id: dataset.id})

      assert revision.workspace_id == ws.id
      assert revision.project_id == project.id
      assert revision.dataset_id == dataset.id
    end
  end
end
