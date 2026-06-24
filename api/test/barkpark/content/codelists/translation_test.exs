defmodule Barkpark.Content.Codelists.TranslationTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Codelists.Translation

  @valid_value_id "00000000-0000-0000-0000-000000000001"

  describe "changeset/2 required fields" do
    test "valid attrs produce a valid changeset" do
      cs =
        Translation.changeset(%Translation{}, %{
          codelist_value_id: @valid_value_id,
          language: "eng",
          label: "By (author)"
        })

      assert cs.valid?
    end

    test "missing codelist_value_id yields an error" do
      cs =
        Translation.changeset(%Translation{}, %{
          language: "eng",
          label: "By (author)"
        })

      refute cs.valid?
      assert %{codelist_value_id: ["can't be blank"]} = errors_on(cs)
    end

    test "missing language yields an error" do
      cs =
        Translation.changeset(%Translation{}, %{
          codelist_value_id: @valid_value_id,
          label: "By (author)"
        })

      refute cs.valid?
      assert %{language: ["can't be blank"]} = errors_on(cs)
    end

    test "missing label yields an error" do
      cs =
        Translation.changeset(%Translation{}, %{
          codelist_value_id: @valid_value_id,
          language: "eng"
        })

      refute cs.valid?
      assert %{label: ["can't be blank"]} = errors_on(cs)
    end

    test "description is optional — changeset valid without it" do
      cs =
        Translation.changeset(%Translation{}, %{
          codelist_value_id: @valid_value_id,
          language: "nob",
          label: "Av (forfatter)"
        })

      assert cs.valid?
      assert is_nil(Ecto.Changeset.get_field(cs, :description))
    end

    test "description is accepted when provided" do
      cs =
        Translation.changeset(%Translation{}, %{
          codelist_value_id: @valid_value_id,
          language: "eng",
          label: "By (author)",
          description: "Primary creator responsible for the content"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :description) == "Primary creator responsible for the content"
    end

    test "all three required fields missing yields errors for each" do
      cs = Translation.changeset(%Translation{}, %{})

      refute cs.valid?
      errors = errors_on(cs)
      assert Map.has_key?(errors, :codelist_value_id)
      assert Map.has_key?(errors, :language)
      assert Map.has_key?(errors, :label)
    end
  end
end
