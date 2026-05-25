defmodule Barkpark.TenancyDatasetsTest do
  @moduledoc """
  Wave-2 foundation: the additive datasets seam. Asserts the migration-time
  SEED (20260527132000) produced a `datasets` row for "production" (+
  "paperflow") under the Default project, and that the BACKFILL shape links a
  content row's `dataset_id` to the datasets row whose (project_id, slug)
  matches the row's dataset string.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Project, Dataset}
  alias Barkpark.Content.Document

  describe "datasets seed (migration 20260527132000)" do
    test "a 'production' dataset exists under the Default project" do
      project = Tenancy.get_default_project()
      assert %Project{} = project

      ds = Tenancy.get_dataset(project, "production")
      assert %Dataset{} = ds
      assert ds.slug == "production"
      assert ds.name == "production"
      assert ds.project_id == project.id
    end

    test "a 'paperflow' dataset exists under the Default project" do
      project = Tenancy.get_default_project()
      ds = Tenancy.get_dataset(project, "paperflow")
      assert %Dataset{} = ds
      assert ds.slug == "paperflow"
      assert ds.project_id == project.id
    end

    test "list_datasets/1 returns the seeded datasets, slug-ordered" do
      project = Tenancy.get_default_project()
      slugs = project |> Tenancy.list_datasets() |> Enum.map(& &1.slug)
      assert "paperflow" in slugs
      assert "production" in slugs
    end
  end

  describe "backfill shape: a document's dataset_id resolves to the matching datasets row" do
    test "dataset_id points at the (Default project, dataset-string) datasets row" do
      project = Tenancy.get_default_project()
      ws = Tenancy.get_default_workspace()
      production = Tenancy.get_dataset(project, "production")

      # Insert a content row carrying the dataset STRING (string still
      # authoritative), then apply the backfill assignment the migration runs
      # for rows that exist at migrate time: dataset_id = datasets row whose
      # (project_id, slug) matches (Default project, the row's dataset string).
      {:ok, doc} =
        %Document{workspace_id: ws.id, project_id: project.id, dataset: "production"}
        |> Document.changeset(%{doc_id: "ds-backfill-1", type: "thing", rev: "r1"})
        |> Repo.insert()

      {1, _} =
        Repo.update_all(
          from(d in Document,
            where: d.id == ^doc.id,
            join: x in Dataset,
            on: x.project_id == ^project.id and x.slug == d.dataset,
            update: [set: [dataset_id: x.id]]
          ),
          []
        )

      reloaded = Repo.get!(Document, doc.id)
      assert reloaded.dataset == "production"
      assert reloaded.dataset_id == production.id
    end
  end

  describe "get_or_create_dataset/2" do
    test "returns the existing seeded dataset rather than creating a duplicate" do
      project = Tenancy.get_default_project()
      existing = Tenancy.get_dataset(project, "production")

      {:ok, ds} = Tenancy.get_or_create_dataset(project, "production")
      assert ds.id == existing.id
    end

    test "creates a new dataset (slug = name) when absent" do
      project = Tenancy.get_default_project()
      assert Tenancy.get_dataset(project, "staging") == nil

      {:ok, ds} = Tenancy.get_or_create_dataset(project, "staging")
      assert ds.slug == "staging"
      assert ds.name == "staging"
      assert ds.project_id == project.id
    end
  end
end
