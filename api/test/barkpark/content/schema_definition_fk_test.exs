defmodule Barkpark.Content.SchemaDefinitionFkTest do
  @moduledoc """
  FK-abort containment for SchemaDefinition.changeset/2 (Felix W16, the W13
  changeset-FK-abort scar-class).

  `schema_definitions.workspace_id/project_id/dataset_id` are real Postgres FKs
  (migration 20260527160000_cascade_content_on_scope_delete, default-derived
  constraint names `schema_definitions_<col>_fkey`). Without
  `foreign_key_constraint/2` in the changeset, an insert referencing a vanished
  row — a workspace/project/dataset deleted concurrently — RAISES
  Ecto.ConstraintError out of `Content.upsert_schema/3`'s raw
  `Repo.insert`/`Repo.update` (a 500) instead of returning `{:error, changeset}`.

  Each bad-FK insert lives in its OWN test: a Postgres FK violation aborts the
  sandbox transaction, so nothing may run after it in the same test.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  defp attrs(overrides) do
    suffix = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "fk_type_#{suffix}",
        title: "FK Type #{suffix}"
      },
      overrides
    )
  end

  defp insert(overrides) do
    %SchemaDefinition{} |> SchemaDefinition.changeset(attrs(overrides)) |> Repo.insert()
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

      assert {:ok, %SchemaDefinition{} = schema_def} =
               insert(%{workspace_id: ws.id, project_id: project.id, dataset_id: dataset.id})

      assert schema_def.workspace_id == ws.id
      assert schema_def.project_id == project.id
      assert schema_def.dataset_id == dataset.id
    end
  end
end
