defmodule Barkpark.Content.DocumentTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Document

  # ---------------------------------------------------------------------------
  # changeset/2 — required fields
  # ---------------------------------------------------------------------------

  describe "changeset/2 required fields" do
    test "valid attrs produce a valid changeset" do
      cs = Document.changeset(%Document{}, %{"doc_id" => "d1", "type" => "post"})
      assert cs.valid?
    end

    test "missing doc_id yields an error" do
      cs = Document.changeset(%Document{}, %{"type" => "post"})
      refute cs.valid?
      assert %{doc_id: ["can't be blank"]} = errors_on(cs)
    end

    test "missing type yields an error" do
      cs = Document.changeset(%Document{}, %{"doc_id" => "d1"})
      refute cs.valid?
      assert %{type: ["can't be blank"]} = errors_on(cs)
    end

    test "missing both doc_id and type yields errors for both" do
      cs = Document.changeset(%Document{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert Map.has_key?(errors, :doc_id)
      assert Map.has_key?(errors, :type)
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — defaults
  # ---------------------------------------------------------------------------

  describe "changeset/2 defaults" do
    test "dataset defaults to 'production' when not supplied" do
      cs = Document.changeset(%Document{}, %{"doc_id" => "d1", "type" => "post"})
      # The schema default is applied to the struct; the changeset carries it.
      assert Ecto.Changeset.get_field(cs, :dataset) == "production"
    end

    test "status defaults to 'draft' when not supplied" do
      cs = Document.changeset(%Document{}, %{"doc_id" => "d1", "type" => "post"})
      assert Ecto.Changeset.get_field(cs, :status) == "draft"
    end

    test "content defaults to empty map when not supplied" do
      cs = Document.changeset(%Document{}, %{"doc_id" => "d1", "type" => "post"})
      assert Ecto.Changeset.get_field(cs, :content) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — status inclusion
  # ---------------------------------------------------------------------------

  describe "changeset/2 status validation" do
    @valid_statuses ~w(draft published archived active planning completed)

    for s <- @valid_statuses do
      test "status '#{s}' is accepted" do
        cs =
          Document.changeset(%Document{}, %{
            "doc_id" => "d-#{unquote(s)}",
            "type" => "post",
            "status" => unquote(s)
          })

        assert cs.valid?
        assert Ecto.Changeset.get_field(cs, :status) == unquote(s)
      end
    end

    test "unknown status is rejected" do
      cs =
        Document.changeset(%Document{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "status" => "pending"
        })

      refute cs.valid?
      assert %{status: [msg]} = errors_on(cs)
      assert msg =~ "is invalid"
    end

    test "empty string status is silently dropped — struct default 'draft' is preserved" do
      cs =
        Document.changeset(%Document{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "status" => ""
        })

      # Ecto casts "" → nil for :string fields; when the result equals the
      # struct's existing value (nil vs. nil), no change is recorded.  The schema
      # default "draft" is returned by get_field, which passes validate_inclusion.
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :status) == "draft"
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — optional scalar fields are cast
  # ---------------------------------------------------------------------------

  describe "changeset/2 optional scalar fields" do
    test "title, dataset, rev, content are cast when present" do
      cs =
        Document.changeset(%Document{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "title" => "Hello",
          "dataset" => "staging",
          "rev" => "abc123",
          "content" => %{"body" => "text"}
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :title) == "Hello"
      assert Ecto.Changeset.get_field(cs, :dataset) == "staging"
      assert Ecto.Changeset.get_field(cs, :rev) == "abc123"
      assert Ecto.Changeset.get_field(cs, :content) == %{"body" => "text"}
    end

    test "workspace_id and project_id are cast" do
      ws_id = Ecto.UUID.generate()
      proj_id = Ecto.UUID.generate()

      cs =
        Document.changeset(%Document{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "workspace_id" => ws_id,
          "project_id" => proj_id
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :workspace_id) == ws_id
      assert Ecto.Changeset.get_field(cs, :project_id) == proj_id
    end

    test "unknown fields are silently ignored" do
      cs =
        Document.changeset(%Document{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "not_a_real_field" => "boom"
        })

      assert cs.valid?
      # Ecto does not put unknown keys into changes
      refute Map.has_key?(cs.changes, :not_a_real_field)
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 applied to an existing struct (update path)
  # ---------------------------------------------------------------------------

  describe "changeset/2 on an existing Document (update path)" do
    test "can clear optional fields by setting them to nil" do
      existing = %Document{doc_id: "d1", type: "post", title: "Old"}

      cs = Document.changeset(existing, %{"title" => nil})
      # title is not required, so nil is accepted
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :title) == nil
    end

    test "cannot clear doc_id (required)" do
      existing = %Document{doc_id: "d1", type: "post"}

      cs = Document.changeset(existing, %{"doc_id" => nil})
      refute cs.valid?
      assert %{doc_id: _} = errors_on(cs)
    end

    test "cannot clear type (required)" do
      existing = %Document{doc_id: "d1", type: "post"}

      cs = Document.changeset(existing, %{"type" => nil})
      refute cs.valid?
      assert %{type: _} = errors_on(cs)
    end
  end

  # ---------------------------------------------------------------------------
  # unique_constraint — DB-backed
  # The constraint is on (doc_id, type, dataset_id) in the DB index.
  # We insert two rows with the same triple and expect the second to fail with
  # the constraint mapped to a changeset error on the correct fields.
  # ---------------------------------------------------------------------------

  describe "unique_constraint on (doc_id, type, dataset_id)" do
    test "duplicate (doc_id, type, dataset_id) via direct Repo.insert raises a changeset error" do
      # The W2 constraint is on (doc_id, type, dataset_id).  create_document is
      # an upsert, so it can't trigger the constraint from the outside.  We
      # exercise it by doing two raw Repo.inserts of the same triple, which is
      # exactly what the DB constraint is designed to guard against.
      #
      # DataCase.ensure_default_tenancy/0 guarantees the default workspace +
      # project exist; default_project_dataset_id/1 resolves the dataset_id
      # for the canonical "production" dataset under that project.
      dataset_id = Barkpark.Tenancy.default_project_dataset_id("production")

      # If the default tenancy has no "production" dataset yet, skip gracefully.
      # (In practice the seed migration always creates it.)
      if is_nil(dataset_id) do
        :skip
      else
        doc_id = "dup-constraint-#{System.unique_integer([:positive])}"

        attrs = %{
          "doc_id" => doc_id,
          "type" => "post",
          "dataset_id" => dataset_id,
          "status" => "draft",
          "rev" => "test-rev-#{doc_id}"
        }

        assert {:ok, _} = Repo.insert(Document.changeset(%Document{}, attrs))

        assert {:error, cs_err} = Repo.insert(Document.changeset(%Document{}, attrs))
        errors = errors_on(cs_err)
        # The unique_constraint declaration maps the DB error to doc_id.
        assert Map.has_key?(errors, :doc_id)
      end
    end
  end
end
