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

      assert {:error, {:codelist_version_must_be_integer, "x:y"}} = SchemaDefinition.parse(schema)
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

      assert {:error, {:reserved_namespace, "plugin:foo:bar"}} = SchemaDefinition.parse(schema)
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

      assert {:ok,
              %Parsed{name: "post", title: "Post", version: 1, fields: [%Field{name: "title"}]}} =
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

  describe "parse/2 — surface classification (pd-doctrine t7, the sidebar test)" do
    test "accepts surface: \"body\"" do
      schema = %{
        "name" => "post",
        "fields" => [%{"name" => "body", "type" => "richText", "surface" => "body"}]
      }

      assert {:ok, %Parsed{fields: [%Field{surface: "body"}]}} = SchemaDefinition.parse(schema)
    end

    test "accepts surface: \"sidebar\"" do
      schema = %{
        "name" => "post",
        "fields" => [%{"name" => "slug", "type" => "slug", "surface" => "sidebar"}]
      }

      assert {:ok, %Parsed{fields: [%Field{surface: "sidebar"}]}} = SchemaDefinition.parse(schema)
    end

    test "defaults surface to nil when the attribute is absent (unclassified)" do
      schema = %{"name" => "post", "fields" => [%{"name" => "title", "type" => "string"}]}

      assert {:ok, %Parsed{fields: [%Field{surface: nil}]}} = SchemaDefinition.parse(schema)
    end

    test "rejects an invalid surface value" do
      schema = %{
        "name" => "post",
        "fields" => [%{"name" => "title", "type" => "string", "surface" => "footer"}]
      }

      assert {:error, :field_surface_invalid} = SchemaDefinition.parse(schema)
    end

    test "rejects a non-string surface value" do
      schema = %{
        "name" => "post",
        "fields" => [%{"name" => "title", "type" => "string", "surface" => true}]
      }

      assert {:error, :field_surface_invalid} = SchemaDefinition.parse(schema)
    end

    test "surface is data-only: does NOT flip a legacy schema off flat_mode" do
      schema = %{
        "name" => "post",
        "fields" => [
          %{"name" => "title", "type" => "string", "surface" => "body"},
          %{"name" => "slug", "type" => "slug", "surface" => "sidebar"}
        ]
      }

      assert SchemaDefinition.flat?(schema) == true
    end

    test "a legacy schema with no surface round-trips byte-identically (raw preserved)" do
      legacy_field = %{"name" => "title", "type" => "string"}
      schema = %{"name" => "post", "fields" => [legacy_field]}

      assert {:ok, %Parsed{fields: [field]}} = SchemaDefinition.parse(schema)
      assert field.surface == nil
      # raw carries the ORIGINAL field map, no injected surface key.
      assert field.raw == legacy_field
      refute Map.has_key?(field.raw, "surface")
    end

    test "a composite subfield carries its own surface (recursion inherits the flag)" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "publishing",
            "type" => "composite",
            "surface" => "sidebar",
            "fields" => [
              %{"name" => "imprint", "type" => "string", "surface" => "sidebar"},
              %{"name" => "blurb", "type" => "string", "surface" => "body"}
            ]
          }
        ]
      }

      assert {:ok, %Parsed{fields: [outer]}} = SchemaDefinition.parse(schema)
      assert outer.surface == "sidebar"
      assert %Field{fields: [imprint, blurb]} = outer
      assert imprint.surface == "sidebar"
      assert blurb.surface == "body"
    end

    test "an invalid surface on a composite subfield is rejected too" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "publishing",
            "type" => "composite",
            "fields" => [%{"name" => "imprint", "type" => "string", "surface" => "nope"}]
          }
        ]
      }

      assert {:error, :field_surface_invalid} = SchemaDefinition.parse(schema)
    end

    test "an arrayOf `of` descriptor carries surface (recursion inherits the flag)" do
      schema = %{
        "name" => "book",
        "fields" => [
          %{
            "name" => "contributors",
            "type" => "arrayOf",
            "ordered" => true,
            "surface" => "sidebar",
            "of" => %{"type" => "string", "surface" => "sidebar"}
          }
        ]
      }

      assert {:ok, %Parsed{fields: [field]}} = SchemaDefinition.parse(schema)
      assert field.surface == "sidebar"
      assert %Field{of: %Field{surface: "sidebar"}} = field
    end
  end

  describe "namespace constants" do
    test "exposes plugin reserved + custom prefixes" do
      assert SchemaDefinition.plugin_reserved_prefix() == "plugin:"
      assert SchemaDefinition.plugin_custom_prefix() == "bp_"
    end
  end

  describe "default_layout/1 — field-order derivation (Exp-P1)" do
    test "each field becomes a field-ref in declared order, plus a trailing body region" do
      schema = %{
        "name" => "author",
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "slug", "type" => "slug"},
          %{"name" => "bio", "type" => "text"}
        ]
      }

      # EX1 (barkpark-q39y): each derived field carries soft once-cardinality.
      assert SchemaDefinition.default_layout(schema) == [
               %{"kind" => "field", "name" => "name", "max" => 1, "enforce" => false},
               %{"kind" => "field", "name" => "slug", "max" => 1, "enforce" => false},
               %{"kind" => "field", "name" => "bio", "max" => 1, "enforce" => false},
               %{"kind" => "region", "name" => "body"}
             ]
    end

    test "works on a %SchemaDefinition{} struct with string-keyed fields" do
      schema = %SchemaDefinition{
        name: "page",
        fields: [
          %{"name" => "title", "type" => "string"},
          %{"name" => "body", "type" => "richText"}
        ]
      }

      assert SchemaDefinition.default_layout(schema) == [
               %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => false},
               %{"kind" => "field", "name" => "body", "max" => 1, "enforce" => false},
               %{"kind" => "region", "name" => "body"}
             ]
    end

    test "a fieldless schema still gets one trailing body region" do
      schema = %{"name" => "empty", "fields" => []}
      assert SchemaDefinition.default_layout(schema) == [%{"kind" => "region", "name" => "body"}]
    end
  end

  describe "default_prefill/1 (Exp-P1)" do
    test "returns initial_values verbatim from a struct, dynamics unresolved" do
      schema = %SchemaDefinition{
        name: "x",
        initial_values: %{"status" => "draft", "year" => "$today.year"}
      }

      assert SchemaDefinition.default_prefill(schema) == %{
               "status" => "draft",
               "year" => "$today.year"
             }
    end

    test "returns %{} when no initial_values are declared" do
      assert SchemaDefinition.default_prefill(%SchemaDefinition{name: "x"}) == %{}
      assert SchemaDefinition.default_prefill(%{"name" => "x", "fields" => []}) == %{}
    end
  end

  describe "resolve_expectation/1 (Exp-P1)" do
    test "explicit stored layout/prefill win over the derived default" do
      explicit_layout = [
        %{"kind" => "field", "name" => "title"},
        %{"kind" => "field", "name" => "slug"},
        %{"kind" => "field", "name" => "featuredImage"},
        %{"kind" => "region", "name" => "body"}
      ]

      schema = %SchemaDefinition{
        name: "post",
        fields: [
          %{"name" => "title", "type" => "string"},
          %{"name" => "slug", "type" => "slug"},
          %{"name" => "featuredImage", "type" => "image"}
        ],
        layout: explicit_layout,
        prefill: %{"status" => "draft", "featured" => false}
      }

      assert SchemaDefinition.resolve_expectation(schema) == %{
               layout: explicit_layout,
               prefill: %{"status" => "draft", "featured" => false}
             }
    end

    test "derives the default when no layout/prefill is stored" do
      schema = %SchemaDefinition{
        name: "author",
        fields: [
          %{"name" => "name", "type" => "string"},
          %{"name" => "role", "type" => "select"}
        ],
        initial_values: %{"role" => "writer"}
      }

      assert SchemaDefinition.resolve_expectation(schema) == %{
               layout: [
                 %{"kind" => "field", "name" => "name", "max" => 1, "enforce" => false},
                 %{"kind" => "field", "name" => "role", "max" => 1, "enforce" => false},
                 %{"kind" => "region", "name" => "body"}
               ],
               prefill: %{"role" => "writer"}
             }
    end
  end

  describe "parse/2 — field visibility (Phase 3, core-auth)" do
    test "preserves private, visibility, readable_by attributes" do
      schema = %{
        "name" => "secret",
        "fields" => [
          %{
            "name" => "ssn",
            "type" => "string",
            "private" => true,
            "visibility" => "owner_only",
            "readable_by" => ["user_1"]
          }
        ]
      }

      assert {:ok, %Parsed{fields: [field]}} = SchemaDefinition.parse(schema)
      assert %Field{private: true, visibility: "owner_only", readable_by: ["user_1"]} = field
    end

    test "defaults missing attributes (private: false, visibility: nil, readable_by: [])" do
      schema = %{"name" => "post", "fields" => [%{"name" => "body", "type" => "string"}]}

      assert {:ok, %Parsed{fields: [field]}} = SchemaDefinition.parse(schema)
      assert %Field{private: false, visibility: nil, readable_by: []} = field
    end

    test "visibility and readable_by are data-only (no validation)" do
      schema = %{
        "name" => "post",
        "fields" => [%{"name" => "body", "type" => "string", "visibility" => "nonsense"}]
      }

      assert {:ok, %Parsed{fields: [%Field{visibility: "nonsense"}]}} =
               SchemaDefinition.parse(schema)
    end
  end

  # ── desk_groups filter validation (gfr-w1-filter-chokepoint-strict) ────────
  #
  # `desk_groups` is a bare `{:array, :map}`, so NOTHING used to look inside one.
  # A chip carrying a typo'd filter op was accepted at write, stored, and then
  # detonated at render inside the Studio LiveView — the query builder refuses an
  # unsupported op now instead of silently returning every row. The person who
  # can fix the typo is the one who should get the error, at the moment they make
  # it.
  defp desk_changeset(desk_groups) do
    SchemaDefinition.changeset(%SchemaDefinition{}, %{
      "name" => "post",
      "title" => "Post",
      "dataset" => "sd_desk",
      "desk_groups" => desk_groups
    })
  end

  describe "changeset/2 — desk_groups filters" do
    test "accepts a desk group whose filter uses documented operators" do
      cs =
        desk_changeset([
          %{
            "name" => "drafts",
            "title" => "Drafts",
            "filter" => %{"status" => %{"eq" => "draft"}}
          },
          %{"name" => "recent", "filter" => %{"_updatedAt" => %{"gt" => "2026-01-01T00:00:00Z"}}},
          %{"name" => "all", "title" => "All", "filter" => %{}},
          %{"name" => "no-filter-key", "title" => "All"}
        ])

      assert cs.valid?
    end

    test "REJECTS a desk group whose filter carries an unsupported operator" do
      cs = desk_changeset([%{"name" => "bad", "filter" => %{"status" => %{"bogus" => "x"}}}])

      refute cs.valid?
      {message, _} = cs.errors[:desk_groups]
      assert message =~ "desk group \"bad\""
      assert message =~ "\"bogus\""
      assert message =~ "status"
      # The admin fixing this needs the vocabulary, not just a rejection.
      assert message =~ "startsWith"
    end

    test "REJECTS the value-matched traps too — `is` and `hasStrong`" do
      cs =
        desk_changeset([%{"name" => "typo", "filter" => %{"status" => %{"is" => "published"}}}])

      refute cs.valid?
      assert {message, _} = cs.errors[:desk_groups]
      assert message =~ "\"is\""

      cs =
        desk_changeset([
          %{"name" => "hs", "filter" => %{"tags" => %{"hasStrong" => "floorless"}}}
        ])

      refute cs.valid?
      assert {message, _} = cs.errors[:desk_groups]
      assert message =~ "\"hasStrong\""
    end

    test "REJECTS a filter that is not a map at all" do
      cs = desk_changeset([%{"name" => "junk", "filter" => "status=draft"}])

      refute cs.valid?
      {message, _} = cs.errors[:desk_groups]
      assert message =~ "must be a map"
    end

    test "a schema with no desk_groups change is untouched by the guard" do
      cs =
        SchemaDefinition.changeset(%SchemaDefinition{}, %{
          "name" => "post",
          "title" => "Post",
          "dataset" => "sd_desk"
        })

      assert cs.valid?
    end
  end
end
