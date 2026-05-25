defmodule Barkpark.SchemaDefinitionsCollapseTest do
  @moduledoc """
  Wave-2 GATE: the duplicate-collapse migration (20260527133000) removes
  redundant `schema_definitions` rows so the planned uniqueness flip to
  `(name, project_id)` won't collide.

  Asserts the post-migration invariant the future unique index needs:
  NO `(name, project_id)` group has more than one schema_definitions row.
  Also asserts the surviving `paper` schema still resolves for production use
  (the dataset papers actually live in after the convergence move).
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Tenancy

  describe "post-collapse invariant (migration 20260527133000)" do
    test "no (name, project_id) group has more than one schema_definitions row" do
      dupe_groups =
        from(s in SchemaDefinition,
          group_by: [s.name, s.project_id],
          having: count(s.id) > 1,
          select: {s.name, s.project_id, count(s.id)}
        )
        |> Repo.all()

      assert dupe_groups == [],
             "expected zero duplicate (name, project_id) groups (the future " <>
               "unique index requires this), got: #{inspect(dupe_groups)}"
    end

    test "exactly one `paper` schema_definitions row survives" do
      count =
        from(s in SchemaDefinition, where: s.name == "paper", select: count(s.id))
        |> Repo.one()

      assert count == 1,
             "expected the duplicate `paper` rows to collapse to one, got #{count}"
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
