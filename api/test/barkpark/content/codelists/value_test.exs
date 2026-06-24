defmodule Barkpark.Content.Codelists.ValueTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Codelists.Value

  @valid_codelist_id "00000000-0000-0000-0000-000000000001"

  describe "changeset/2 required fields" do
    test "valid attrs produce a valid changeset" do
      cs =
        Value.changeset(%Value{}, %{
          codelist_id: @valid_codelist_id,
          code: "A01"
        })

      assert cs.valid?
    end

    test "missing codelist_id yields an error" do
      cs = Value.changeset(%Value{}, %{code: "A01"})

      refute cs.valid?
      assert %{codelist_id: ["can't be blank"]} = errors_on(cs)
    end

    test "missing code yields an error" do
      cs = Value.changeset(%Value{}, %{codelist_id: @valid_codelist_id})

      refute cs.valid?
      assert %{code: ["can't be blank"]} = errors_on(cs)
    end

    test "optional fields (position, metadata, parent_id) are accepted when provided" do
      cs =
        Value.changeset(%Value{}, %{
          codelist_id: @valid_codelist_id,
          code: "B02",
          position: 5,
          metadata: %{"note" => "extra"}
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :position) == 5
      assert Ecto.Changeset.get_field(cs, :metadata) == %{"note" => "extra"}
    end

    test "empty attrs produce errors for both required fields" do
      cs = Value.changeset(%Value{}, %{})

      refute cs.valid?
      errors = errors_on(cs)
      assert Map.has_key?(errors, :codelist_id)
      assert Map.has_key?(errors, :code)
    end
  end
end
