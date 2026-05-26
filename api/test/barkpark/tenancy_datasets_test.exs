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

    # barkpark-wnij: the loser of a concurrent "new dataset string" write used to
    # crash. In the real race two transactions each see get_dataset → nil, then
    # both INSERT. The loser's insert hit datasets_project_id_slug_index → Ecto
    # returned {:error, changeset} cleanly, BUT the surrounding apply_mutations
    # Repo.transaction was now ABORTED. get_or_create_dataset's recovery branch
    # then ran another get_dataset INSIDE that aborted txn → Postgrex raised
    # "current transaction is aborted" and the whole mutation 500'd.
    #
    # The `on_conflict: :nothing` + reload fix makes the loser's duplicate insert
    # a no-op that does NOT abort the transaction.
    #
    # Deterministic proxy for the loser: pre-seed the (slug, project) row in a
    # COMMITTED prior transaction, then INSIDE a fresh Repo.transaction issue the
    # exact duplicate insert (create_dataset, the same call get_or_create_dataset
    # makes when its earlier get_dataset saw nil) and prove a subsequent query in
    # that same transaction still succeeds — i.e. the txn was not poisoned.
    test "duplicate create_dataset insert does not poison the surrounding transaction" do
      project = Tenancy.get_default_project()
      slug = "race-#{System.unique_integer([:positive])}"

      # Winner committed first, in its own transaction.
      {:ok, winner} = Tenancy.create_dataset(project.id, %{slug: slug, name: slug})

      result =
        Repo.transaction(fn ->
          # Loser's insert path — same call get_or_create_dataset makes when its
          # earlier get_dataset returned nil. Pre-fix this aborted the txn.
          loser_insert = Tenancy.create_dataset(project.id, %{slug: slug, name: slug})

          # Prove the transaction is STILL alive: a normal query must succeed,
          # not raise Postgrex "current transaction is aborted".
          count =
            Repo.aggregate(
              from(d in Dataset, where: d.project_id == ^project.id and d.slug == ^slug),
              :count
            )

          {loser_insert, count}
        end)

      assert {:ok, {loser_insert, count}} = result
      # on_conflict :nothing → the duplicate insert is a no-op that returns :ok
      # (NOT {:error, changeset}, and NOT an abort). The struct carries the
      # changeset's autogenerated id, which is why get_or_create_dataset reloads.
      assert {:ok, %Dataset{}} = loser_insert
      # The duplicate was swallowed, not duplicated.
      assert count == 1
      # And the real winner row is untouched.
      assert %Dataset{id: id} = Tenancy.get_dataset(project.id, slug)
      assert id == winner.id
    end

    # End-to-end loser path through get_or_create_dataset itself: row pre-exists
    # (committed), then inside a transaction we force the insert branch by calling
    # get_or_create_dataset for the SAME (slug, project). It must return
    # {:ok, existing} and leave the transaction usable for a follow-up query.
    test "get_or_create_dataset returns the existing row without aborting the transaction" do
      project = Tenancy.get_default_project()
      slug = "race-existing-#{System.unique_integer([:positive])}"
      {:ok, existing} = Tenancy.create_dataset(project.id, %{slug: slug, name: slug})

      result =
        Repo.transaction(fn ->
          got = Tenancy.get_or_create_dataset(project.id, slug)
          # Subsequent query in the same txn still works → txn not aborted.
          still_there = Tenancy.get_dataset(project.id, slug)
          {got, still_there}
        end)

      assert {:ok, {{:ok, %Dataset{} = ds}, %Dataset{} = still_there}} = result
      assert ds.id == existing.id
      assert still_there.id == existing.id
    end
  end
end
