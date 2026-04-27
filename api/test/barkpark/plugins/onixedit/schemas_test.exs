defmodule Barkpark.Plugins.OnixEdit.SchemasTest do
  @moduledoc """
  Phase 4 WI2 — sub-schemas (contributor, text_content, thema).

  Coverage:

    * Each sub-schema parses through the v2 validator (round-trip through
      `Barkpark.Content.SchemaDefinition.parse/2` with the `:plugin`
      opt set so reserved-namespace rejection does not fire).
    * `arrayOf ordered: true` exposes the flag on the parsed field
      (Phase 0 semantics — `ordered` is a UI hint, not a validation
      constraint, so the test asserts the parsed metadata, not value
      rejection).
    * `localizedText` `fallbackChain` resolves correctly when the
      primary language is empty and the fallback has the value.
    * Codelist references for ContributorRole (list 17, D17), Thema
      (list 93, D17), TextType (list 153), ContentAudience (list 154)
      are declared in the manifest aggregator. Data seeding is WI3 —
      these tests assert declarations only, not registry rows.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Content.LocalizedText
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.SchemaDefinition.{Field, Parsed}
  alias Barkpark.Plugins.OnixEdit.Schemas
  alias Barkpark.Plugins.OnixEdit.Schemas.{Contributor, TextContent, ThemaSubjectCategory}

  describe "Contributor sub-schema" do
    test "definition_map/0 round-trips through SchemaDefinition.parse/2" do
      assert %Parsed{version: 2} = parsed = Contributor.parsed!()
      assert parsed.name == "contributor"
      assert is_list(parsed.fields)

      role = Enum.find(parsed.fields, &(&1.name == "contributorRole"))

      assert %Field{type: "codelist", codelist_id: "onixedit:contributor_role", version: 73} =
               role

      assert role.onix == %{"element" => "ContributorRole", "codelistId" => 17}

      bio = Enum.find(parsed.fields, &(&1.name == "biographicalNote"))
      assert %Field{type: "localizedText", format: :rich} = bio
      assert bio.languages == ["nob", "eng"]
      assert bio.fallback_chain == ["nob", "eng", "first-non-empty"]

      person = Enum.find(parsed.fields, &(&1.name == "personName"))
      assert %Field{type: "composite"} = person
      assert Enum.any?(person.fields, &(&1.name == "keyNames"))
      assert Enum.any?(person.fields, &(&1.name == "namesBeforeKey"))
    end

    test "rejects an unknown reserved field name when not opted into the plugin namespace" do
      bad =
        Contributor.definition_map()
        |> Map.update!("fields", fn fs ->
          [%{"name" => "plugin:other:secret", "type" => "string"} | fs]
        end)

      assert {:error, {:reserved_namespace, "plugin:other:secret"}} =
               SchemaDefinition.parse(bad, plugin: "onixedit")
    end

    test "rejects an arrayOf without ordered being a boolean" do
      tweaked =
        Contributor.definition_map()
        |> Map.update!("fields", fn fs ->
          [
            %{
              "name" => "broken",
              "type" => "arrayOf",
              "ordered" => "yes",
              "of" => %{"type" => "string"}
            }
            | fs
          ]
        end)

      assert {:error, {:array_ordered_must_be_boolean, "broken"}} =
               SchemaDefinition.parse(tweaked, plugin: "onixedit")
    end

    test "declares contributor_role (list 17 / issue 73) and other codelists" do
      refs = Contributor.codelist_refs()
      assert Enum.all?(refs, &(&1.plugin_name == "onixedit"))

      list_ids = Enum.map(refs, & &1.list_id)
      assert "onixedit:contributor_role" in list_ids
      assert "onixedit:language_code" in list_ids
      assert "onixedit:name_type" in list_ids
      assert "onixedit:name_id_type" in list_ids

      issues = refs |> Enum.map(& &1.issue) |> Enum.uniq()
      assert issues == [73]
    end
  end

  describe "TextContent sub-schema" do
    test "definition_map/0 round-trips and exposes the localizedText `text` blurb" do
      assert %Parsed{version: 2} = parsed = TextContent.parsed!()
      assert parsed.name == "textContent"

      text = Enum.find(parsed.fields, &(&1.name == "text"))
      assert %Field{type: "localizedText", format: :rich} = text
      assert text.languages == ["nob", "eng"]
      assert text.fallback_chain == ["nob", "eng", "first-non-empty"]

      type_field = Enum.find(parsed.fields, &(&1.name == "textType"))
      assert %Field{type: "codelist", codelist_id: "onixedit:text_type", version: 73} = type_field
      assert type_field.onix["codelistId"] == 153
    end

    test "declares text_type (list 153) and content_audience (list 154)" do
      refs = TextContent.codelist_refs()
      list_ids = Enum.map(refs, & &1.list_id)
      assert "onixedit:text_type" in list_ids
      assert "onixedit:content_audience" in list_ids
      assert "onixedit:text_format" in list_ids
    end
  end

  describe "ThemaSubjectCategory field" do
    test "definition_map/0 produces a parseable codelist field at the book surface" do
      mock_book = %{
        "name" => "book",
        "fields" => [ThemaSubjectCategory.definition_map()]
      }

      assert {:ok, %Parsed{version: 2, fields: [thema]}} =
               SchemaDefinition.parse(mock_book, plugin: "onixedit")

      assert %Field{
               type: "codelist",
               codelist_id: "onixedit:thema",
               version: 73
             } = thema

      assert thema.onix["codelistId"] == 93
    end

    test "declares thema (list 93 / issue 73) per D17" do
      assert ThemaSubjectCategory.codelist_refs() == [
               %{plugin_name: "onixedit", list_id: "onixedit:thema", issue: 73}
             ]
    end
  end

  describe "arrayOf ordered: true semantics (Phase 0)" do
    test "the parsed field exposes ordered: true on a mock contributors arrayOf" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "contributors",
            "type" => "arrayOf",
            "ordered" => true,
            "of" => Contributor.definition_map()
          }
        ]
      }

      assert {:ok, %Parsed{version: 2, fields: [arr]}} =
               SchemaDefinition.parse(schema, plugin: "onixedit")

      assert %Field{type: "arrayOf", ordered: true, of: %Field{type: "composite"}} = arr

      role_in_item = Enum.find(arr.of.fields, &(&1.name == "contributorRole"))

      assert %Field{type: "codelist", codelist_id: "onixedit:contributor_role"} = role_in_item
    end

    test "the parsed field exposes ordered: false on a mock textContents arrayOf" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "textContents",
            "type" => "arrayOf",
            "ordered" => false,
            "of" => TextContent.definition_map()
          }
        ]
      }

      assert {:ok, %Parsed{version: 2, fields: [arr]}} =
               SchemaDefinition.parse(schema, plugin: "onixedit")

      assert %Field{type: "arrayOf", ordered: false} = arr
    end
  end

  describe "localizedText fallbackChain" do
    test "biographicalNote fallback chain resolves to English when Norwegian is missing" do
      bio_field =
        Contributor.parsed!().fields
        |> Enum.find(&(&1.name == "biographicalNote"))

      value = %{"nob" => "", "eng" => "Born in Bergen, 1970…"}

      assert {:ok, "eng", "Born in Bergen, 1970…"} =
               LocalizedText.resolve(value, bio_field.fallback_chain)
    end

    test "explicit chain ['en', 'no'] picks 'no' when 'en' is whitespace-only" do
      assert {:ok, "no", "Hei"} =
               LocalizedText.resolve(%{"en" => "   ", "no" => "Hei"}, ["en", "no"])
    end

    test "first-non-empty sentinel falls through to any non-blank value" do
      assert {:ok, "de", "Hallo"} =
               LocalizedText.resolve(
                 %{"de" => "Hallo"},
                 ["nob", "eng", "first-non-empty"]
               )
    end

    test "all-empty value map returns :no_value" do
      assert {:error, :no_value} =
               LocalizedText.resolve(
                 %{"nob" => "", "eng" => "   "},
                 ["nob", "eng", "first-non-empty"]
               )
    end
  end

  describe "Schemas index module" do
    test "all/0 enumerates contributor + text_content + thema" do
      assert Schemas.all() == [Contributor, TextContent, ThemaSubjectCategory]
    end

    test "codelist_refs/0 aggregates declarations including list 17 and list 93" do
      refs = Schemas.codelist_refs()

      assert Enum.any?(refs, &(&1.list_id == "onixedit:contributor_role" and &1.issue == 73))
      assert Enum.any?(refs, &(&1.list_id == "onixedit:thema" and &1.issue == 73))
      assert Enum.any?(refs, &(&1.list_id == "onixedit:text_type" and &1.issue == 73))
      assert Enum.any?(refs, &(&1.list_id == "onixedit:content_audience" and &1.issue == 73))
      assert Enum.all?(refs, &(&1.plugin_name == "onixedit"))
    end

    test "plugin_name/0 returns onixedit on every WI2 module" do
      assert Schemas.plugin_name() == "onixedit"
      assert Contributor.plugin_name() == "onixedit"
      assert TextContent.plugin_name() == "onixedit"
      assert ThemaSubjectCategory.plugin_name() == "onixedit"
    end
  end
end
