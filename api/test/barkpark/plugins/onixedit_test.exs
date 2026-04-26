defmodule Barkpark.Plugins.OnixEditTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.OnixEdit

  describe "manifest/0" do
    test "returns the validated plugin.json map" do
      manifest = OnixEdit.manifest()

      assert is_map(manifest)
      assert manifest["plugin_name"] == "onixedit"
      assert manifest["module"] == "Barkpark.Plugins.OnixEdit"
      assert manifest["version"] =~ ~r/^\d+\.\d+\.\d+/
      assert is_list(manifest["capabilities"])
      assert "schemas" in manifest["capabilities"]
      assert "codelists" in manifest["capabilities"]
    end

    test "manifest declares the book schema file" do
      [book | _] = OnixEdit.manifest()["schemas"]

      assert book["name"] == "book"
      assert book["file"] == "schemas/book.json"
    end
  end

  describe "plugin_name/0 (D20 discriminator)" do
    test "is the literal string 'onixedit'" do
      assert OnixEdit.plugin_name() == "onixedit"
    end
  end

  describe "book_schema!/0" do
    setup do
      {:ok, parsed: OnixEdit.book_schema!()}
    end

    test "parses through SchemaDefinition.parse/2 as v2", %{parsed: parsed} do
      assert %SchemaDefinition.Parsed{} = parsed
      assert parsed.name == "book"
      assert parsed.version == 2
      refute SchemaDefinition.flat?(parsed)
    end

    test "exposes a deeply nested ONIX product surface", %{parsed: parsed} do
      # Spot-check that key top-level fields land — the schema is a contract
      # WI2 / WI3 / WI4 read.
      top_names = Enum.map(parsed.fields, & &1.name)

      for required <- ~w(
            productIdentifiers productForm titleDetails contributors
            languages subjects themaSubjectCategory audienceCodes
            collateralDetail publishingDetail relatedMaterial productSupplies
          ) do
        assert required in top_names, "expected `#{required}` at top level of book schema"
      end
    end

    test "field count meets the 'large book schema' bar", %{parsed: parsed} do
      assert count_fields(parsed.fields) >= 150,
             "book schema should declare at least 150 nested fields; got #{count_fields(parsed.fields)}"
    end

    test "carries onix: metadata on at least some fields (Phase 6 export hook)", %{parsed: parsed} do
      assert Enum.any?(walk_fields(parsed.fields), fn f -> is_map(f.onix) end)
    end

    test "uses bp_* prefix for plugin custom fields", %{parsed: parsed} do
      bp = Enum.filter(parsed.fields, &String.starts_with?(&1.name, "bp_"))
      assert bp != []
    end
  end

  describe "WI2 hand-off surface" do
    setup do
      {:ok, parsed: OnixEdit.book_schema!()}
    end

    test "contributors is an arrayOf composite (WI2 fills inner shape)", %{parsed: parsed} do
      contributors = find_top(parsed, "contributors")

      assert contributors.type == "arrayOf"
      assert contributors.ordered == true

      assert %SchemaDefinition.Field{type: "composite"} = contributors.of,
             "contributors `of` should be a composite for WI2 to enrich"
    end

    test "themaSubjectCategory is a codelist field pinned to ONIX list 93", %{parsed: parsed} do
      thema = find_top(parsed, "themaSubjectCategory")

      assert thema.type == "codelist"
      assert thema.codelist_id == "onixedit:thema"
      assert thema.onix["codelistId"] == 93
    end

    test "collateralDetail.textContents is the localizedText insertion point", %{parsed: parsed} do
      collateral = find_top(parsed, "collateralDetail")
      assert collateral.type == "composite"

      text_contents = Enum.find(collateral.fields, &(&1.name == "textContents"))
      assert text_contents != nil, "expected `textContents` under collateralDetail"
      assert text_contents.type == "arrayOf",
             "WI2 will swap or extend the inner composite with a localizedText blurb"
    end
  end

  describe "codelist_requirements/0" do
    test "ContributorRole codelist 17 is declared (D17)" do
      reqs = OnixEdit.codelist_requirements()

      assert Enum.any?(reqs, fn r ->
               r.list_id == "onixedit:contributor_role" and r.issue == "17"
             end),
             "ContributorRole list 17 must be in the codelist requirements (D17)"
    end

    test "Thema codelist 93 is declared" do
      reqs = OnixEdit.codelist_requirements()

      assert Enum.any?(reqs, fn r ->
               r.list_id == "onixedit:thema" and r.issue == "93"
             end)
    end

    test "all requirements are scoped to the onixedit plugin (D20)" do
      reqs = OnixEdit.codelist_requirements()
      assert Enum.all?(reqs, &(&1.plugin_name == "onixedit"))
    end
  end

  describe "Barkpark.Plugin contract" do
    test "register_schemas/1 returns at least the book SchemaDefinition" do
      [book | _] = OnixEdit.register_schemas([])

      assert %SchemaDefinition{name: "book"} = book
      assert book.visibility == "private"
    end

    test "default behaviour callbacks return their no-op shapes" do
      assert OnixEdit.register_routes(:noop) == :ok
      assert OnixEdit.register_workers(:noop) == []
      assert OnixEdit.validate_settings(%{}) == :ok
      assert OnixEdit.checkers() == []
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp find_top(parsed, name) do
    Enum.find(parsed.fields, &(&1.name == name)) ||
      flunk("missing top-level field `#{name}`")
  end

  defp count_fields(fields) when is_list(fields) do
    Enum.reduce(fields, 0, fn f, acc -> acc + 1 + count_in_field(f) end)
  end

  defp count_in_field(%SchemaDefinition.Field{type: "composite", fields: kids}) when is_list(kids),
    do: count_fields(kids)

  defp count_in_field(%SchemaDefinition.Field{type: "arrayOf", of: %SchemaDefinition.Field{} = inner}),
    do: 1 + count_in_field(inner)

  defp count_in_field(_), do: 0

  defp walk_fields(fields) when is_list(fields) do
    Enum.flat_map(fields, fn f ->
      [f | walk_in_field(f)]
    end)
  end

  defp walk_in_field(%SchemaDefinition.Field{type: "composite", fields: kids}) when is_list(kids),
    do: walk_fields(kids)

  defp walk_in_field(%SchemaDefinition.Field{type: "arrayOf", of: %SchemaDefinition.Field{} = inner}),
    do: [inner | walk_in_field(inner)]

  defp walk_in_field(_), do: []
end
