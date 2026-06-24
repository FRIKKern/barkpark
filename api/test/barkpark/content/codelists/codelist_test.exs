defmodule Barkpark.Content.Codelists.CodelistTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Codelists.Codelist

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      attrs = %{plugin_name: "onixedit", list_id: "onixedit:list_1", issue: "73"}
      cs = Codelist.changeset(%Codelist{}, attrs)
      assert cs.valid?
    end

    test "optional fields (name, description) are accepted" do
      attrs = %{
        plugin_name: "onixedit",
        list_id: "onixedit:list_1",
        issue: "73",
        name: "Product Form",
        description: "A list of product forms"
      }

      cs = Codelist.changeset(%Codelist{}, attrs)
      assert cs.valid?
      assert get_change(cs, :name) == "Product Form"
      assert get_change(cs, :description) == "A list of product forms"
    end

    test "missing required fields produce errors" do
      cs = Codelist.changeset(%Codelist{}, %{})
      refute cs.valid?

      errors = errors_on(cs)
      assert :plugin_name in Map.keys(errors)
      assert :list_id in Map.keys(errors)
      assert :issue in Map.keys(errors)
    end

    test "missing issue alone makes changeset invalid" do
      attrs = %{plugin_name: "onixedit", list_id: "onixedit:list_1"}
      cs = Codelist.changeset(%Codelist{}, attrs)
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :issue)
    end

    test "unknown keys are ignored (not cast)" do
      attrs = %{
        plugin_name: "onixedit",
        list_id: "onixedit:list_1",
        issue: "73",
        bogus_field: "should be dropped"
      }

      cs = Codelist.changeset(%Codelist{}, attrs)
      assert cs.valid?
      refute Map.has_key?(cs.changes, :bogus_field)
    end
  end
end
