defmodule Barkpark.Repo.Migrations.CodelistIssueVersionTest do
  @moduledoc """
  Phase 8 WI4 — regression test that locks in the `jsonb[]` handling for
  `schema_definitions.fields` in the `add_codelist_issue_version`
  migration. CI fixtures previously exercised only single-element jsonb
  or empty arrays; the production-shape failure mode (multi-element
  jsonb[] with nested composites) is reproduced here so a future regress
  cannot land silently.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Repo

  @migration_file Path.expand(
                    "../../../../priv/repo/migrations/20260503063122_add_codelist_issue_version.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_file)
    :ok
  end

  alias Barkpark.Repo.Migrations.AddCodelistIssueVersion

  defp insert_schema(name, fields) do
    {:ok, sd} =
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        "name" => name,
        "title" => name,
        "fields" => fields,
        "dataset" => "production"
      })
      |> Repo.insert()

    sd.id
  end

  defp fields_of(id) do
    Repo.get!(SchemaDefinition, id).fields
  end

  defp insert_doc(doc_id, content) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "post",
        "dataset" => "production",
        "title" => "Mig Doc " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev-mig-cl-" <> doc_id <> "-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    doc
  end

  defp content_of(doc_id) do
    Repo.get_by!(Document, doc_id: doc_id, type: "post", dataset: "production").content
  end

  describe "Fixture A — single-element jsonb[] (navigation shape)" do
    test "up/0 adds issue_version to the lone codelist field; down/0 strips it" do
      id =
        insert_schema("navigation_test", [
          %{"name" => "items", "type" => "codelist", "codelistId" => "navItems"}
        ])

      AddCodelistIssueVersion.apply_up(Repo)

      [field] = fields_of(id)
      assert field["issue_version"] == "73"
      assert field["name"] == "items"
      assert field["type"] == "codelist"
      assert field["codelistId"] == "navItems"

      AddCodelistIssueVersion.apply_down(Repo)

      [field_after_down] = fields_of(id)
      refute Map.has_key?(field_after_down, "issue_version")
      assert field_after_down["name"] == "items"
      assert field_after_down["type"] == "codelist"
    end
  end

  describe "Fixture B — empty jsonb[] (post shape)" do
    test "up/0 and down/0 are no-ops on empty fields and never crash" do
      id = insert_schema("empty_test", [])

      assert :ok = AddCodelistIssueVersion.apply_up(Repo)
      assert fields_of(id) == []

      assert :ok = AddCodelistIssueVersion.apply_down(Repo)
      assert fields_of(id) == []
    end
  end

  describe "Fixture C — multi-element jsonb[] with nested composite (walk/2 recursion)" do
    test "up/0 adds issue_version to every codelist at every depth; non-codelists untouched" do
      id =
        insert_schema("mixed_test", [
          %{"name" => "country", "type" => "codelist", "codelistId" => "91"},
          %{"name" => "title", "type" => "string"},
          %{
            "name" => "meta",
            "type" => "composite",
            "fields" => [
              %{"name" => "lang", "type" => "codelist", "codelistId" => "74"},
              %{"name" => "label", "type" => "string"}
            ]
          }
        ])

      AddCodelistIssueVersion.apply_up(Repo)

      [country, title, meta] = fields_of(id)

      assert country["issue_version"] == "73"
      assert country["codelistId"] == "91"

      refute Map.has_key?(title, "issue_version")
      assert title["type"] == "string"
      assert title["name"] == "title"

      assert meta["type"] == "composite"
      refute Map.has_key?(meta, "issue_version")

      [nested_lang, nested_label] = meta["fields"]
      assert nested_lang["issue_version"] == "73"
      assert nested_lang["codelistId"] == "74"
      refute Map.has_key?(nested_label, "issue_version")

      AddCodelistIssueVersion.apply_down(Repo)

      [country_d, title_d, meta_d] = fields_of(id)
      refute Map.has_key?(country_d, "issue_version")
      refute Map.has_key?(title_d, "issue_version")
      refute Map.has_key?(meta_d, "issue_version")

      [nested_lang_d, nested_label_d] = meta_d["fields"]
      refute Map.has_key?(nested_lang_d, "issue_version")
      refute Map.has_key?(nested_label_d, "issue_version")
      assert nested_lang_d["codelistId"] == "74"
    end
  end

  describe "Fixture D — documents.content invariant" do
    test "up/0 leaves a non-codelist-ref content map untouched (transform_documents/2 guard)" do
      original = %{"category_code" => "03", "title" => "Hello", "tags" => ["a", "b"]}
      insert_doc("mig-doc-untouched", original)

      AddCodelistIssueVersion.apply_up(Repo)

      assert content_of("mig-doc-untouched") == original

      AddCodelistIssueVersion.apply_down(Repo)

      assert content_of("mig-doc-untouched") == original
    end
  end

  # Regression for Postgrex SQLSTATE 22023 "cannot extract elements from a
  # scalar" — the bare `$1::jsonb` cast in the UPDATE coerced through
  # text-format param binding raised against a real Postgres connection.
  # The other fixtures call `apply_up/1` directly, which uses the same
  # `repo.query!` path; this fixture additionally drives the migration via
  # `Ecto.Migrator.up/3` so the production migrator code path is locked too.
  describe "Fixture E — Ecto.Migrator end-to-end (param-binding regression)" do
    @migration_version 20_260_503_063_122

    setup do
      # Up/Down through the migrator stamps schema_migrations; clean it on
      # exit so other tests in the suite see a stable migration state.
      on_exit(fn ->
        Repo.query!(
          "DELETE FROM schema_migrations WHERE version = $1",
          [@migration_version]
        )
      end)

      :ok
    end

    test "Ecto.Migrator.up/3 applies UPDATE without raising Postgrex 22023" do
      id =
        insert_schema("migrator_e2e", [
          %{"name" => "country", "type" => "codelist", "codelistId" => "91"},
          %{"name" => "title", "type" => "string"}
        ])

      # Migrator stamps schema_migrations; if the row already exists from a
      # parent test, clear it so up/3 actually runs the migration body.
      Repo.query!(
        "DELETE FROM schema_migrations WHERE version = $1",
        [@migration_version]
      )

      assert :ok =
               Ecto.Migrator.up(
                 Repo,
                 @migration_version,
                 AddCodelistIssueVersion,
                 log: false
               )

      [country, title] = fields_of(id)
      assert country["issue_version"] == "73"
      refute Map.has_key?(title, "issue_version")

      assert :ok =
               Ecto.Migrator.down(
                 Repo,
                 @migration_version,
                 AddCodelistIssueVersion,
                 log: false
               )

      [country_d, _title_d] = fields_of(id)
      refute Map.has_key?(country_d, "issue_version")
    end
  end
end
