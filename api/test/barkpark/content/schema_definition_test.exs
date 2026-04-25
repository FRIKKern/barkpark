defmodule Barkpark.Content.SchemaDefinitionTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.SchemaDefinition.{Field, Parsed}

  describe "parse/2 — v2 field types" do
    test "accepts a nested-composite v2 schema" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "publishing",
            "type" => "composite",
            "fields" => [
              %{"name" => "imprint", "type" => "string"},
              %{"name" => "publishedDate", "type" => "datetime"},
              %{
                "name" => "city",
                "type" => "composite",
                "fields" => [%{"name" => "code", "type" => "string"}]
              }
            ]
          }
        ]
      }

      assert {:ok, %Parsed{version: 2, fields: [outer]}} = SchemaDefinition.parse(schema)
      assert %Field{type: "composite", fields: kids} = outer
      assert length(kids) == 3
      assert Enum.map(kids, & &1.name) == ["imprint", "publishedDate", "city"]

      city = Enum.find(kids, &(&1.name == "city"))
      assert %Field{type: "composite", fields: [%Field{name: "code", type: "string"}]} = city
    end

    test "accepts arrayOf with ordered: true" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "contributors",
            "type" => "arrayOf",
            "ordered" => true,
            "of" => %{"type" => "string"}
          }
        ]
      }

      assert {:ok, %Parsed{version: 2, fields: [field]}} = SchemaDefinition.parse(schema)
      assert %Field{type: "arrayOf", ordered: true, of: %Field{type: "string"}} = field
    end

    test "accepts arrayOf with ordered: false (unordered set semantics)" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "tags",
            "type" => "arrayOf",
            "ordered" => false,
            "of" => %{"type" => "string"}
          }
        ]
      }

      assert {:ok, %Parsed{fields: [%Field{ordered: false}]}} = SchemaDefinition.parse(schema)
    end

    test "rejects arrayOf with non-boolean ordered" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "x",
            "type" => "arrayOf",
            "ordered" => "yes",
            "of" => %{"type" => "string"}
          }
        ]
      }

      assert {:error, {:array_ordered_must_be_boolean, "x"}} = SchemaDefinition.parse(schema)
    end

    test "accepts codelist with version: 73" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "language",
            "type" => "codelist",
            "codelistId" => "onixedit:language",
            "version" => 73
          }
        ]
      }

      assert {:ok, %Parsed{version: 2, fields: [field]}} = SchemaDefinition.parse(schema)

      assert %Field{
               type: "codelist",
               codelist_id: "onixedit:language",
               version: 73
             } = field
    end

    test "rejects codelist with non-integer version" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "language",
            "type" => "codelist",
            "codelistId" => "x:y",
            "version" => "73"
          }
        ]
      }

      assert {:error, {:codelist_version_must_be_integer, "x:y"}} =
               SchemaDefinition.parse(schema)
    end

    test "accepts localizedText with fallbackChain" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "blurb",
            "type" => "localizedText",
            "languages" => ["nob", "eng"],
            "format" => "rich",
            "fallbackChain" => ["nob", "eng", "first-non-empty"]
          }
        ]
      }

      assert {:ok, %Parsed{version: 2, fields: [field]}} = SchemaDefinition.parse(schema)

      assert %Field{
               type: "localizedText",
               languages: ["nob", "eng"],
               format: :rich,
               fallback_chain: ["nob", "eng", "first-non-empty"]
             } = field
    end

    test "localizedText defaults format to :plain when omitted" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "blurb",
            "type" => "localizedText",
            "languages" => ["nob"],
            "fallbackChain" => ["nob"]
          }
        ]
      }

      assert {:ok, %Parsed{fields: [%Field{format: :plain}]}} = SchemaDefinition.parse(schema)
    end
  end

  describe "parse/2 — reserved namespaces" do
    test "rejects user-defined `plugin:foo:bar` field when schema is not a plugin schema" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{"name" => "plugin:foo:bar", "type" => "string"}
        ]
      }

      assert {:error, {:reserved_namespace, "plugin:foo:bar"}} =
               SchemaDefinition.parse(schema)
    end

    test "allows `plugin:onixedit:foo` when parsing as plugin: \"onixedit\"" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{"name" => "plugin:onixedit:foo", "type" => "string"}
        ]
      }

      assert {:ok, %Parsed{}} = SchemaDefinition.parse(schema, plugin: "onixedit")
    end

    test "still rejects another plugin's namespace when parsing as plugin: \"onixedit\"" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{"name" => "plugin:other:foo", "type" => "string"}
        ]
      }

      assert {:error, {:reserved_namespace, "plugin:other:foo"}} =
               SchemaDefinition.parse(schema, plugin: "onixedit")
    end

    test "allows bp_* custom-field prefix (Phase 0 audit clean — locked)" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{"name" => "bp_internal_note", "type" => "string"}
        ]
      }

      assert {:ok, %Parsed{}} = SchemaDefinition.parse(schema)
    end
  end

  describe "parse/2 — top-level validations slot + onix metadata" do
    test "preserves the top-level `validations: [...]` rule slot verbatim" do
      schema = %{
        "name" => "book",
        "fields" => [%{"name" => "title", "type" => "string"}],
        "validations" => [
          %{
            "name" => "isbn-required",
            "severity" => "error",
            "when" => %{"path" => "/format", "op" => "eq", "value" => "epub"},
            "then" => %{"path" => "/isbn", "op" => "nonempty"}
          }
        ]
      }

      assert {:ok, %Parsed{validations: [rule]}} = SchemaDefinition.parse(schema)
      assert rule["name"] == "isbn-required"
    end

    test "preserves per-field `onix:` metadata pass-through (data only)" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "isbn",
            "type" => "string",
            "onix" => %{
              "element" => "ProductIdentifier",
              "in" => "ProductIdentifier",
              "codelistId" => 5
            }
          }
        ]
      }

      assert {:ok, %Parsed{fields: [%Field{onix: onix}]}} = SchemaDefinition.parse(schema)
      assert onix["element"] == "ProductIdentifier"
      assert onix["codelistId"] == 5
    end
  end

  describe "parse/2 — input shape coercion" do
    test "accepts atom-keyed maps (Elixir literal style from seeds.exs)" do
      schema = %{
        name: "post",
        title: "Post",
        fields: [
          %{name: "title", title: "Title", type: "string"}
        ]
      }

      assert {:ok, %Parsed{name: "post", title: "Post", version: 1, fields: [%Field{name: "title"}]}} =
               SchemaDefinition.parse(schema)
    end

    test "errors on missing fields list" do
      assert {:error, :missing_fields} = SchemaDefinition.parse(%{"name" => "x"})
    end

    test "errors on non-map input" do
      assert {:error, :schema_must_be_a_map} = SchemaDefinition.parse("not a map")
    end
  end

  describe "flat?/1" do
    test "returns true for legacy seed schema: post" do
      schema = %{
        name: "post",
        title: "Post",
        fields: [
          %{name: "title", title: "Title", type: "string"},
          %{name: "slug", title: "Slug", type: "slug"},
          %{
            name: "status",
            title: "Status",
            type: "select",
            options: ["draft", "published", "archived"]
          },
          %{name: "publishedAt", title: "Published At", type: "datetime"},
          %{name: "excerpt", title: "Excerpt", type: "text", rows: 3},
          %{name: "body", title: "Body", type: "richText"},
          %{name: "featuredImage", title: "Featured Image", type: "image"},
          %{name: "author", title: "Author", type: "reference", refType: "author"},
          %{name: "featured", title: "Featured Post", type: "boolean"}
        ]
      }

      assert SchemaDefinition.flat?(schema) == true
    end

    test "returns true for legacy seed schema: author" do
      schema = %{
        name: "author",
        fields: [
          %{name: "name", type: "string"},
          %{name: "slug", type: "slug"},
          %{name: "bio", type: "text", rows: 4},
          %{name: "avatar", type: "image"},
          %{name: "email", type: "string"},
          %{name: "role", type: "select", options: ["editor", "writer"]}
        ]
      }

      assert SchemaDefinition.flat?(schema) == true
    end

    test "returns true for legacy seed schema: page" do
      schema = %{
        name: "page",
        fields: [
          %{name: "title", type: "string"},
          %{name: "slug", type: "slug"},
          %{name: "body", type: "richText"},
          %{name: "seoTitle", type: "string"},
          %{name: "seoDescription", type: "text", rows: 2},
          %{name: "heroImage", type: "image"}
        ]
      }

      assert SchemaDefinition.flat?(schema) == true
    end

    test "returns false for v2 schema with composite" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{"name" => "publishing", "type" => "composite", "fields" => []}
        ]
      }

      assert SchemaDefinition.flat?(schema) == false
    end

    test "returns false for v2 schema with arrayOf" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "contribs",
            "type" => "arrayOf",
            "ordered" => true,
            "of" => %{"type" => "string"}
          }
        ]
      }

      assert SchemaDefinition.flat?(schema) == false
    end

    test "returns false for v2 schema with codelist" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "lang",
            "type" => "codelist",
            "codelistId" => "onixedit:language",
            "version" => 73
          }
        ]
      }

      assert SchemaDefinition.flat?(schema) == false
    end

    test "returns false for v2 schema with localizedText" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "blurb",
            "type" => "localizedText",
            "languages" => ["nob"],
            "format" => "plain",
            "fallbackChain" => ["nob"]
          }
        ]
      }

      assert SchemaDefinition.flat?(schema) == false
    end

    test "returns false when validations slot is non-empty even with flat fields" do
      schema = %{
        "name" => "post",
        "fields" => [%{"name" => "title", "type" => "string"}],
        "validations" => [%{"name" => "title-required"}]
      }

      assert SchemaDefinition.flat?(schema) == false
    end

    test "accepts a Parsed struct as input" do
      schema = %{"name" => "x", "fields" => [%{"name" => "t", "type" => "string"}]}
      {:ok, parsed} = SchemaDefinition.parse(schema)
      assert SchemaDefinition.flat?(parsed) == true
    end
  end

  describe "namespace constants" do
    test "exposes plugin reserved + custom prefixes" do
      assert SchemaDefinition.plugin_reserved_prefix() == "plugin:"
      assert SchemaDefinition.plugin_custom_prefix() == "bp_"
    end
  end
end
