defmodule Barkpark.SchemaDefinitionsCollapseTest do
  @moduledoc """
  Wave-2 GATE: the duplicate-collapse migration (20260527133000) removes
  redundant `schema_definitions` rows so the uniqueness flip to
  `(name, dataset_id)` won't collide WITHIN a dataset.

  Asserts the post-migration invariant the unique index needs:
  NO `(name, dataset_id)` group has more than one schema_definitions row.
  A project legitimately holds the SAME name in distinct datasets (e.g.
  `paper` in production + a test-dataset copy), so the leaf is `dataset_id`,
  not `project_id`. Also asserts the production `paper` schema still resolves
  (the dataset papers actually live in after the convergence move).
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Tenancy

  describe "post-collapse invariant (migration 20260527133000)" do
    test "no (name, dataset_id) group has more than one schema_definitions row" do
      dupe_groups =
        from(s in SchemaDefinition,
          group_by: [s.name, s.dataset_id],
          having: count(s.id) > 1,
          select: {s.name, s.dataset_id, count(s.id)}
        )
        |> Repo.all()

      assert dupe_groups == [],
             "expected zero duplicate (name, dataset_id) groups (the " <>
               "unique index requires this), got: #{inspect(dupe_groups)}"
    end

    test "exactly one `paper` schema_definitions row survives per dataset" do
      count =
        from(s in SchemaDefinition,
          where: s.name == "paper",
          group_by: [s.name, s.dataset_id],
          select: count(s.id)
        )
        |> Repo.all()

      assert Enum.all?(count, &(&1 == 1)),
             "expected the duplicate `paper` rows to collapse to one per " <>
               "dataset, got per-dataset counts #{inspect(count)}"
    end

    test "the surviving `paper` schema resolves for production (where papers live)" do
      # Papers moved into the `production` dataset (convergence). The survivor
      # is the production-dataset row, so production resolution still works.
      assert {:ok, %SchemaDefinition{name: "paper", dataset: "production"}} =
               Content.get_schema("paper", "production")
    end

    test "the survivor carries the Default project_id (project-scoped catalog)" do
      project = Tenancy.get_default_project()

      {:ok, schema} = Content.get_schema("paper", "production")
      assert schema.project_id == project.id
    end
  end
end
