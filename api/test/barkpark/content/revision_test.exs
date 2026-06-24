defmodule Barkpark.Content.RevisionTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Revision

  # ---------------------------------------------------------------------------
  # changeset/2 — required fields
  # ---------------------------------------------------------------------------

  describe "changeset/2 required fields" do
    test "valid attrs with all required fields produce a valid changeset" do
      cs =
        Revision.changeset(%Revision{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "action" => "create"
        })

      assert cs.valid?
    end

    test "missing doc_id yields an error" do
      cs = Revision.changeset(%Revision{}, %{"type" => "post", "action" => "create"})
      refute cs.valid?
      assert %{doc_id: ["can't be blank"]} = errors_on(cs)
    end

    test "missing type yields an error" do
      cs = Revision.changeset(%Revision{}, %{"doc_id" => "d1", "action" => "create"})
      refute cs.valid?
      assert %{type: ["can't be blank"]} = errors_on(cs)
    end

    test "missing action yields an error" do
      cs = Revision.changeset(%Revision{}, %{"doc_id" => "d1", "type" => "post"})
      refute cs.valid?
      assert %{action: ["can't be blank"]} = errors_on(cs)
    end

    test "missing all required fields yields errors for all three" do
      cs = Revision.changeset(%Revision{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert Map.has_key?(errors, :doc_id)
      assert Map.has_key?(errors, :type)
      assert Map.has_key?(errors, :action)
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — defaults
  # ---------------------------------------------------------------------------

  describe "changeset/2 defaults" do
    test "dataset defaults to 'production' when not supplied" do
      cs =
        Revision.changeset(%Revision{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "action" => "create"
        })

      assert Ecto.Changeset.get_field(cs, :dataset) == "production"
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — optional fields are cast
  # ---------------------------------------------------------------------------

  describe "changeset/2 optional fields" do
    test "title, status, dataset, content, action are cast when present" do
      cs =
        Revision.changeset(%Revision{}, %{
          "doc_id" => "doc-42",
          "type" => "article",
          "action" => "update",
          "title" => "My Title",
          "status" => "published",
          "dataset" => "staging",
          "content" => %{"body" => "some text"}
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :title) == "My Title"
      assert Ecto.Changeset.get_field(cs, :status) == "published"
      assert Ecto.Changeset.get_field(cs, :dataset) == "staging"
      assert Ecto.Changeset.get_field(cs, :content) == %{"body" => "some text"}
      assert Ecto.Changeset.get_field(cs, :action) == "update"
    end

    test "workspace_id and project_id are cast" do
      ws_id = Ecto.UUID.generate()
      proj_id = Ecto.UUID.generate()

      cs =
        Revision.changeset(%Revision{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "action" => "delete",
          "workspace_id" => ws_id,
          "project_id" => proj_id
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :workspace_id) == ws_id
      assert Ecto.Changeset.get_field(cs, :project_id) == proj_id
    end

    test "unknown fields are silently ignored" do
      cs =
        Revision.changeset(%Revision{}, %{
          "doc_id" => "d1",
          "type" => "post",
          "action" => "create",
          "not_a_real_field" => "boom"
        })

      assert cs.valid?
      refute Map.has_key?(cs.changes, :not_a_real_field)
    end
  end
end
