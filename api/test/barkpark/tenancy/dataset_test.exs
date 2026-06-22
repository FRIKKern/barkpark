defmodule Barkpark.Tenancy.DatasetTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Dataset

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_int, do: System.unique_integer([:positive])

  defp create_project_fixture do
    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "ds-ws-#{unique_int()}", name: "DS Workspace"})

    {:ok, project} =
      Tenancy.create_project(ws, %{slug: "ds-proj-#{unique_int()}", name: "DS Project"})

    {ws, project}
  end

  # ---------------------------------------------------------------------------
  # Dataset.changeset/2 — happy paths
  # ---------------------------------------------------------------------------

  describe "Dataset.changeset/2 — valid attrs" do
    setup do
      {_ws, project} = create_project_fixture()
      {:ok, project: project}
    end

    test "accepts minimal valid attrs", %{project: project} do
      cs = Dataset.changeset(%Dataset{}, %{slug: "production", name: "Production", project_id: project.id})
      assert cs.valid?
    end

    test "slug exactly 1 character is accepted", %{project: project} do
      cs = Dataset.changeset(%Dataset{}, %{slug: "a", name: "A", project_id: project.id})
      assert cs.valid?
    end

    test "slug exactly 63 characters is accepted", %{project: project} do
      slug = String.duplicate("a", 63)
      cs = Dataset.changeset(%Dataset{}, %{slug: slug, name: "Long", project_id: project.id})
      assert cs.valid?
    end

    test "name exactly 255 characters is accepted", %{project: project} do
      name = String.duplicate("n", 255)
      cs = Dataset.changeset(%Dataset{}, %{slug: "ok", name: name, project_id: project.id})
      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Dataset.changeset/2 — required-field guards
  # ---------------------------------------------------------------------------

  describe "Dataset.changeset/2 — required fields" do
    test "requires slug" do
      cs = Dataset.changeset(%Dataset{}, %{name: "No Slug", project_id: Ecto.UUID.generate()})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).slug
    end

    test "requires name" do
      cs = Dataset.changeset(%Dataset{}, %{slug: "no-name", project_id: Ecto.UUID.generate()})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).name
    end

    test "requires project_id" do
      cs = Dataset.changeset(%Dataset{}, %{slug: "no-proj", name: "No Project"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).project_id
    end
  end

  # ---------------------------------------------------------------------------
  # Dataset.changeset/2 — length guards
  # ---------------------------------------------------------------------------

  describe "Dataset.changeset/2 — length limits" do
    test "rejects slug longer than 63 characters" do
      slug = String.duplicate("a", 64)
      cs = Dataset.changeset(%Dataset{}, %{slug: slug, name: "X", project_id: Ecto.UUID.generate()})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "rejects name longer than 255 characters" do
      name = String.duplicate("n", 256)
      cs = Dataset.changeset(%Dataset{}, %{slug: "ok", name: name, project_id: Ecto.UUID.generate()})
      refute cs.valid?
      assert errors_on(cs).name != []
    end
  end

  # ---------------------------------------------------------------------------
  # Dataset.changeset/2 — DB-level project assoc constraint
  # ---------------------------------------------------------------------------

  describe "Dataset.changeset/2 — project assoc constraint" do
    test "rejects a non-existent project_id at the DB level" do
      ghost_id = Ecto.UUID.generate()

      result =
        %Dataset{}
        |> Dataset.changeset(%{slug: "orphan", name: "Orphan", project_id: ghost_id})
        |> Barkpark.Repo.insert()

      assert {:error, cs} = result
      refute cs.valid?
      assert errors_on(cs).project != [],
             "expected project assoc error, got #{inspect(errors_on(cs))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Dataset.changeset/2 — unique constraint (slug scoped to project)
  # ---------------------------------------------------------------------------

  describe "Dataset.changeset/2 — uniqueness constraint" do
    test "same slug in the same project returns a unique constraint error via direct Repo.insert" do
      {_ws, project} = create_project_fixture()

      # Insert the first row (no conflict clause — we want the raw DB behaviour).
      {:ok, _} =
        %Dataset{}
        |> Dataset.changeset(%{slug: "dup-staging", name: "Staging", project_id: project.id})
        |> Barkpark.Repo.insert()

      # Second insert without on_conflict must trigger the unique index.
      {:error, cs} =
        %Dataset{}
        |> Dataset.changeset(%{slug: "dup-staging", name: "Staging 2", project_id: project.id})
        |> Barkpark.Repo.insert()

      refute cs.valid?
      assert "already exists in this project" in errors_on(cs).slug
    end

    test "Tenancy.create_dataset/2 silently no-ops on a duplicate slug (on_conflict :nothing)" do
      # create_dataset uses on_conflict: :nothing — a second insert must not
      # raise and must return {:ok, _}.
      {_ws, project} = create_project_fixture()
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "noop", name: "Noop"})
      assert {:ok, _} = Tenancy.create_dataset(project, %{slug: "noop", name: "Noop Again"})
    end

    test "same slug in a different project is allowed" do
      {_ws, project_a} = create_project_fixture()
      {_ws, project_b} = create_project_fixture()

      {:ok, _} = Tenancy.create_dataset(project_a, %{slug: "shared", name: "Shared"})
      assert {:ok, ds_b} = Tenancy.create_dataset(project_b, %{slug: "shared", name: "Shared"})
      assert ds_b.project_id == project_b.id
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy.create_dataset/2
  # ---------------------------------------------------------------------------

  describe "Tenancy.create_dataset/2" do
    setup do
      {_ws, project} = create_project_fixture()
      {:ok, project: project}
    end

    test "creates a dataset and persists it", %{project: project} do
      assert {:ok, ds} = Tenancy.create_dataset(project, %{slug: "production", name: "Production"})
      assert ds.id != nil
      assert ds.slug == "production"
      assert ds.name == "Production"
      assert ds.project_id == project.id
    end

    test "also accepts a plain project_id binary", %{project: project} do
      assert {:ok, ds} = Tenancy.create_dataset(project.id, %{slug: "staging", name: "Staging"})
      assert ds.project_id == project.id
    end

    test "returns an error changeset for an invalid slug (empty)", %{project: project} do
      assert {:error, cs} = Tenancy.create_dataset(project, %{slug: "", name: "Bad"})
      refute cs.valid?
      assert errors_on(cs).slug != []
    end

    test "project_id in attrs is overridden by the resolved project", %{project: project} do
      other_id = Ecto.UUID.generate()
      # Even if a foreign project_id is passed, the one from the first arg wins.
      assert {:ok, ds} =
               Tenancy.create_dataset(project.id, %{
                 slug: "override-test",
                 name: "Override",
                 project_id: other_id
               })

      assert ds.project_id == project.id
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy.get_dataset/2 and get_dataset_by_id/1
  # ---------------------------------------------------------------------------

  describe "Tenancy.get_dataset/2" do
    setup do
      {_ws, project} = create_project_fixture()
      {:ok, ds} = Tenancy.create_dataset(project, %{slug: "production", name: "Production"})
      {:ok, project: project, ds: ds}
    end

    test "returns the dataset by project struct + slug", %{project: project, ds: ds} do
      found = Tenancy.get_dataset(project, "production")
      assert found.id == ds.id
    end

    test "returns the dataset by project_id binary + slug", %{project: project, ds: ds} do
      found = Tenancy.get_dataset(project.id, "production")
      assert found.id == ds.id
    end

    test "returns nil for an unknown slug", %{project: project} do
      assert Tenancy.get_dataset(project, "nonexistent") == nil
    end

    test "returns nil for an unknown project_id" do
      assert Tenancy.get_dataset(Ecto.UUID.generate(), "production") == nil
    end
  end

  describe "Tenancy.get_dataset_by_id/1" do
    setup do
      {_ws, project} = create_project_fixture()
      {:ok, ds} = Tenancy.create_dataset(project, %{slug: "production", name: "Production"})
      {:ok, ds: ds}
    end

    test "returns dataset for a known id", %{ds: ds} do
      found = Tenancy.get_dataset_by_id(ds.id)
      assert found.id == ds.id
      assert found.slug == "production"
    end

    test "returns nil for an unknown id" do
      assert Tenancy.get_dataset_by_id(Ecto.UUID.generate()) == nil
    end

    test "returns nil when passed nil" do
      assert Tenancy.get_dataset_by_id(nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy.list_datasets/1
  # ---------------------------------------------------------------------------

  describe "Tenancy.list_datasets/1" do
    setup do
      {_ws, project} = create_project_fixture()
      {:ok, project: project}
    end

    test "returns empty list when project has no datasets", %{project: project} do
      assert Tenancy.list_datasets(project) == []
    end

    test "returns all datasets under the project ordered by slug", %{project: project} do
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "z-last", name: "Z Last"})
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "a-first", name: "A First"})
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "m-middle", name: "M Middle"})

      slugs = project |> Tenancy.list_datasets() |> Enum.map(& &1.slug)
      assert slugs == ["a-first", "m-middle", "z-last"]
    end

    test "also accepts a project_id binary", %{project: project} do
      {:ok, _} = Tenancy.create_dataset(project, %{slug: "production", name: "Production"})
      list = Tenancy.list_datasets(project.id)
      assert length(list) == 1
      assert hd(list).slug == "production"
    end

    test "datasets from other projects are not included", %{project: project} do
      {_ws, other_project} = create_project_fixture()
      {:ok, _} = Tenancy.create_dataset(other_project, %{slug: "production", name: "Production"})

      assert Tenancy.list_datasets(project) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy.get_or_create_dataset/2
  # ---------------------------------------------------------------------------

  describe "Tenancy.get_or_create_dataset/2" do
    setup do
      {_ws, project} = create_project_fixture()
      {:ok, project: project}
    end

    test "creates the dataset when it does not exist", %{project: project} do
      assert {:ok, ds} = Tenancy.get_or_create_dataset(project, "new-env")
      assert ds.slug == "new-env"
      assert ds.project_id == project.id
    end

    test "returns the existing dataset when it already exists", %{project: project} do
      {:ok, created} = Tenancy.create_dataset(project, %{slug: "staging", name: "Staging"})
      {:ok, fetched} = Tenancy.get_or_create_dataset(project, "staging")
      assert fetched.id == created.id
    end

    test "returns the persisted row's id (not a phantom id from on_conflict :nothing)", %{project: project} do
      # Call twice: first creates, second hits the on_conflict :nothing path
      {:ok, first} = Tenancy.get_or_create_dataset(project, "idempotent")
      {:ok, second} = Tenancy.get_or_create_dataset(project, "idempotent")
      assert first.id == second.id
    end

    test "also accepts a project_id binary", %{project: project} do
      assert {:ok, ds} = Tenancy.get_or_create_dataset(project.id, "binary-id-path")
      assert ds.project_id == project.id
    end

    test "returns error changeset for an invalid slug (empty string)", %{project: project} do
      # Empty slug fails validate_required before hitting the DB
      assert {:error, cs} = Tenancy.get_or_create_dataset(project, "")
      refute cs.valid?
    end
  end
end
