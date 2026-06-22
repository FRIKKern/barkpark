defmodule Barkpark.Media.Storage.MediaFileTest do
  @moduledoc """
  Unit + integration tests for Barkpark.Media.Storage.MediaFile.changeset/2.

  Changeset tests that don't touch the DB run with async: true (they are
  pure Ecto.Changeset traversals).  The unique-constraint test requires
  Repo.insert, so it lives in a separate DataCase describe block — keep it
  last so async batch is not blocked by sandbox acquisition.
  """

  # DataCase is required because the unique-constraint path calls Repo.insert.
  # async: false is the safe default when another connection may write the
  # same (path, dataset_id) pair.
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_attrs(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    %{
      filename: "file-#{suffix}.png",
      original_name: "original-#{suffix}.png",
      path: "2026/06/file-#{suffix}.png",
      mime_type: "image/png",
      size: 12_345,
      dataset: "production"
    }
    |> Map.merge(overrides)
  end

  # ---------------------------------------------------------------------------
  # Happy-path: valid attrs produce a valid changeset
  # ---------------------------------------------------------------------------

  describe "changeset/2 — valid attrs" do
    test "all required fields present yields a valid changeset" do
      cs = MediaFile.changeset(%MediaFile{}, valid_attrs())
      assert cs.valid?
    end

    test "optional fields (size, mime_type, dataset) are cast when provided" do
      cs = MediaFile.changeset(%MediaFile{}, valid_attrs(%{size: 999, mime_type: "video/mp4"}))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :size) == 999
      assert Ecto.Changeset.get_change(cs, :mime_type) == "video/mp4"
    end

    test "dataset defaults to 'production' when not supplied" do
      attrs = Map.delete(valid_attrs(), :dataset)
      cs = MediaFile.changeset(%MediaFile{}, attrs)
      # Ecto applies the schema default before changeset — the field carries
      # the default even though there is no explicit change.
      assert cs.valid?
      # get_field reads both changes and data (i.e. the schema default).
      assert Ecto.Changeset.get_field(cs, :dataset) == "production"
    end

    test "workspace_id, project_id, dataset_id are cast when supplied" do
      ws_id = Ecto.UUID.generate()
      proj_id = Ecto.UUID.generate()
      ds_id = Ecto.UUID.generate()

      attrs = valid_attrs(%{workspace_id: ws_id, project_id: proj_id, dataset_id: ds_id})
      cs = MediaFile.changeset(%MediaFile{}, attrs)

      # We only check the cast succeeded — FK existence is enforced by the DB,
      # not the changeset.
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :workspace_id) == ws_id
      assert Ecto.Changeset.get_change(cs, :project_id) == proj_id
      assert Ecto.Changeset.get_change(cs, :dataset_id) == ds_id
    end

    test "unknown keys are silently dropped" do
      attrs = Map.put(valid_attrs(), :injected_field, "evil")
      cs = MediaFile.changeset(%MediaFile{}, attrs)
      assert cs.valid?
      refute Map.has_key?(cs.changes, :injected_field)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation: required fields
  # ---------------------------------------------------------------------------

  describe "changeset/2 — validate_required" do
    test "missing filename produces an error on :filename" do
      attrs = Map.delete(valid_attrs(), :filename)
      cs = MediaFile.changeset(%MediaFile{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:filename] != nil
    end

    test "missing original_name produces an error on :original_name" do
      attrs = Map.delete(valid_attrs(), :original_name)
      cs = MediaFile.changeset(%MediaFile{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:original_name] != nil
    end

    test "missing path produces an error on :path" do
      attrs = Map.delete(valid_attrs(), :path)
      cs = MediaFile.changeset(%MediaFile{}, attrs)
      refute cs.valid?
      assert errors_on(cs)[:path] != nil
    end

    test "all three required fields missing surfaces all three errors" do
      cs = MediaFile.changeset(%MediaFile{}, %{})
      refute cs.valid?
      errs = errors_on(cs)
      assert errs[:filename] != nil
      assert errs[:original_name] != nil
      assert errs[:path] != nil
    end

    test "nil required fields are treated as missing" do
      attrs = valid_attrs(%{filename: nil, original_name: nil, path: nil})
      cs = MediaFile.changeset(%MediaFile{}, attrs)
      refute cs.valid?
      errs = errors_on(cs)
      assert errs[:filename] != nil
      assert errs[:original_name] != nil
      assert errs[:path] != nil
    end
  end

  # ---------------------------------------------------------------------------
  # DB-backed: unique constraint on (path, dataset_id)
  # ---------------------------------------------------------------------------

  describe "changeset/2 — unique_constraint(:path, :dataset_id)" do
    # Each test needs a real Dataset row (FK: media_files.dataset_id → datasets.id).
    # We create a fresh workspace + project + dataset per test to stay isolated.

    test "inserting two rows with the same path + dataset_id raises a unique-constraint error" do
      ws = create_workspace!()
      proj = create_project!(ws)
      {:ok, ds} = Tenancy.get_or_create_dataset(proj, "production")

      path = "2026/06/unique-#{System.unique_integer([:positive])}.png"

      assert {:ok, _} =
               %MediaFile{}
               |> MediaFile.changeset(valid_attrs(%{path: path, dataset_id: ds.id}))
               |> Repo.insert()

      assert {:error, cs} =
               %MediaFile{}
               |> MediaFile.changeset(valid_attrs(%{path: path, dataset_id: ds.id}))
               |> Repo.insert()

      errs = errors_on(cs)

      assert errs[:path] != nil or errs[:dataset_id] != nil,
             "expected a unique-constraint error on :path or :dataset_id, got: #{inspect(errs)}"
    end

    test "same path with different dataset_id does not violate the constraint" do
      ws1 = create_workspace!()
      proj1 = create_project!(ws1)
      {:ok, ds1} = Tenancy.get_or_create_dataset(proj1, "production")

      ws2 = create_workspace!()
      proj2 = create_project!(ws2)
      {:ok, ds2} = Tenancy.get_or_create_dataset(proj2, "production")

      path = "2026/06/shared-path-#{System.unique_integer([:positive])}.png"

      assert {:ok, _} =
               %MediaFile{}
               |> MediaFile.changeset(valid_attrs(%{path: path, dataset_id: ds1.id}))
               |> Repo.insert()

      assert {:ok, _} =
               %MediaFile{}
               |> MediaFile.changeset(valid_attrs(%{path: path, dataset_id: ds2.id}))
               |> Repo.insert()
    end

    test "same path with nil dataset_id inserts independently (NULL != NULL in SQL)" do
      path = "2026/06/null-ds-#{System.unique_integer([:positive])}.png"

      assert {:ok, _} =
               %MediaFile{}
               |> MediaFile.changeset(valid_attrs(%{path: path}))
               |> Repo.insert()

      # A second row with the same path but NULL dataset_id should also succeed
      # because NULL values do not conflict in a UNIQUE index by default in
      # PostgreSQL.
      assert {:ok, _} =
               %MediaFile{}
               |> MediaFile.changeset(valid_attrs(%{path: path}))
               |> Repo.insert()
    end
  end
end
