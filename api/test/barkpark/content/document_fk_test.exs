defmodule Barkpark.Content.DocumentFkTest do
  @moduledoc """
  FK-abort containment for Document.changeset/2 (Felix W17, the W13
  changeset-FK-abort scar-class — the fourth sibling after MediaFile (W14) and
  bulldocs Event + SchemaDefinition (W16)).

  `documents.workspace_id/project_id/dataset_id` are real Postgres FKs to
  `:workspaces` / `:projects` / `:datasets`, default-derived constraint names
  `documents_<col>_fkey`. The COLUMNS arrived in migrations
  20260527110100_add_tenancy_columns and 20260527131000_add_dataset_id_columns;
  their CURRENT delete action was set later, by
  20260527160000_cascade_content_on_scope_delete, to `on_delete: :delete_all`
  (SQL `ON DELETE CASCADE`), and nothing after it re-flips these twelve
  content-table scope FKs. So a scope delete DELETES the document — it never
  leaves the row alive with a NULLed scope column, and cannot manufacture a
  `documents` row carrying `workspace_id IS NULL` beside a non-NULL
  `project_id` (task-3e3367eba8695cec).

  That action is not what THIS suite tests — a cascade fires on DELETE of a
  live parent, while the abort below fires on INSERT against an id that is
  already gone. The action is stated because reading it wrong is what sends a
  reader hunting an orphan bug that cannot exist.

  Without `foreign_key_constraint/2` in the changeset,
  an insert referencing a vanished row — a workspace/project/dataset deleted
  concurrently — RAISES Ecto.ConstraintError out of `Content.Writer`'s non-bang
  `Repo.insert` on the /v1/data/mutate and /api/documents write paths (a 500)
  instead of returning `{:error, changeset}`. `owner_id` is a plain binary_id
  column (no `references()`) and is intentionally NOT constrained.

  Each bad-FK insert lives in its OWN test: a Postgres FK violation aborts the
  sandbox transaction, so nothing may run after it in the same test.
  """

  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  defp attrs(overrides) do
    suffix = System.unique_integer([:positive])

    Map.merge(
      %{
        doc_id: "fk-doc-#{suffix}",
        type: "post",
        rev: "rev-#{suffix}"
      },
      overrides
    )
  end

  defp insert(overrides) do
    %Document{} |> Document.changeset(attrs(overrides)) |> Repo.insert()
  end

  describe "bad scope FK references return {:error, changeset} (never a raise)" do
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

  describe "valid scope references still insert" do
    test "insert with live workspace/project/dataset succeeds" do
      ws = create_workspace!()
      project = create_project!(ws)

      {:ok, dataset} =
        Tenancy.create_dataset(project, %{slug: "production", name: "production"})

      assert {:ok, %Document{} = document} =
               insert(%{workspace_id: ws.id, project_id: project.id, dataset_id: dataset.id})

      assert document.workspace_id == ws.id
      assert document.project_id == project.id
      assert document.dataset_id == dataset.id
    end
  end
end
