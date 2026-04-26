defmodule Barkpark.Content.ValidationTest do
  @moduledoc """
  W2.2 — Phase 0 recursive validator + flat_mode parity.

  Two surfaces under test:

    * **flat_mode** — every legacy (v1) seed schema MUST round-trip unchanged
      through `Validation.validate/3`. This is the load+edit+save parity
      invariant locked by masterplan-20260425-085425 §Phase 0.
    * **v2 recursion** — composite, arrayOf, codelist, localizedText fields
      walk recursively with JSON-Pointer-ish error paths folded into
      messages. The cross-field rule evaluator is Phase 3 — the top-level
      `validations: [...]` slot is INERT in this phase (see
      `validates_validations_slot_is_inert_in_phase_0`).
  """

  use ExUnit.Case, async: true

  alias Barkpark.Content.Validation

  # ─── flat_mode parity (legacy v1 seed schemas) ────────────────────────────

  describe "flat_mode parity — every seed schema round-trips" do
    # Mirrors api/priv/repo/seeds.exs verbatim. If a seed schema is added
    # there, mirror it here so the parity invariant stays current.
    @seed_schemas [
      %{
        "name" => "post",
        "fields" => [
          %{"name" => "title", "title" => "Title", "type" => "string"},
          %{"name" => "slug", "title" => "Slug", "type" => "slug"},
          %{
            "name" => "status",
            "title" => "Status",
            "type" => "select",
            "options" => ["draft", "published", "archived"]
          },
          %{"name" => "publishedAt", "title" => "Published At", "type" => "datetime"},
          %{"name" => "excerpt", "title" => "Excerpt", "type" => "text", "rows" => 3},
          %{"name" => "body", "title" => "Body", "type" => "richText"},
          %{"name" => "featuredImage", "title" => "Featured Image", "type" => "image"},
          %{
            "name" => "author",
            "title" => "Author",
            "type" => "reference",
            "refType" => "author"
          },
          %{"name" => "featured", "title" => "Featured Post", "type" => "boolean"}
        ]
      },
      %{
        "name" => "page",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "slug", "type" => "slug"},
          %{"name" => "body", "type" => "richText"},
          %{"name" => "seoTitle", "type" => "string"},
          %{"name" => "seoDescription", "type" => "text"},
          %{"name" => "heroImage", "type" => "image"}
        ]
      },
      %{
        "name" => "author",
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "slug", "type" => "slug"},
          %{"name" => "bio", "type" => "text"},
          %{"name" => "avatar", "type" => "image"},
          %{"name" => "email", "type" => "string"},
          %{
            "name" => "role",
            "type" => "select",
            "options" => ["editor", "writer", "contributor", "admin"]
          }
        ]
      },
      %{
        "name" => "category",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "slug", "type" => "slug"},
          %{"name" => "description", "type" => "text"},
          %{"name" => "color", "type" => "color"}
        ]
      },
      %{
        "name" => "project",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "slug", "type" => "slug"},
          %{"name" => "client", "type" => "string"},
          %{
            "name" => "status",
            "type" => "select",
            "options" => ["planning", "active", "completed", "archived"]
          },
          %{"name" => "description", "type" => "richText"},
          %{"name" => "coverImage", "type" => "image"},
          %{"name" => "startDate", "type" => "datetime"},
          %{"name" => "featured", "type" => "boolean"}
        ]
      },
      %{
        "name" => "siteSettings",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "description", "type" => "text"},
          %{"name" => "logo", "type" => "image"},
          %{"name" => "analyticsId", "type" => "string"}
        ]
      },
      %{
        "name" => "navigation",
        "fields" => [
          %{"name" => "title", "type" => "string"}
        ]
      },
      %{
        "name" => "colors",
        "fields" => [
          %{"name" => "primary", "type" => "color"},
          %{"name" => "secondary", "type" => "color"},
          %{"name" => "accent", "type" => "color"}
        ]
      }
    ]

    @sample_content_by_schema %{
      "post" => %{
        title: "Hello World",
        content: %{
          "slug" => "hello-world",
          "status" => "published",
          "publishedAt" => "2026-04-12T09:11:20Z",
          "excerpt" => "An excerpt",
          "body" => "Body text",
          "featured" => true
        }
      },
      "page" => %{title: "Home", content: %{"slug" => "home", "body" => "Welcome"}},
      "author" => %{
        title: "Knut",
        content: %{"name" => "Knut", "email" => "k@example.com", "role" => "admin"}
      },
      "category" => %{
        title: "Technology",
        content: %{"slug" => "technology", "color" => "#3b82f6"}
      },
      "project" => %{
        title: "Website Redesign",
        content: %{"slug" => "redesign", "client" => "Acme", "status" => "active"}
      },
      "siteSettings" => %{
        title: "Studio",
        content: %{"description" => "Site", "analyticsId" => "G-X"}
      },
      "navigation" => %{title: "Main", content: %{}},
      "colors" => %{
        title: "Brand Colors",
        content: %{"primary" => "#3b82f6", "secondary" => "#6366f1", "accent" => "#f59e0b"}
      }
    }

    test "every seed schema validates a sample document" do
      for schema <- @seed_schemas do
        name = schema["name"]
        %{title: title, content: content} = Map.fetch!(@sample_content_by_schema, name)

        assert {:ok, ^content} = Validation.validate(content, title, schema),
               "flat_mode parity broken for seed schema '#{name}' — see masterplan §Phase 0"
      end
    end

    test "every seed schema accepts an edit (load → mutate → validate)" do
      for schema <- @seed_schemas do
        name = schema["name"]
        %{title: title, content: content} = Map.fetch!(@sample_content_by_schema, name)

        assert {:ok, _} = Validation.validate(content, title, schema)

        edited_content = Map.put(content, "edited_at", "2026-04-25T00:00:00Z")
        edited_title = title <> " (edited)"

        assert {:ok, ^edited_content} = Validation.validate(edited_content, edited_title, schema),
               "edit round-trip failed for seed schema '#{name}'"
      end
    end

    # NOTE: full create_document/upsert_document DB round-trip is exercised
    # by the existing envelope_test.exs / errors_test.exs suite, which calls
    # Content.validate_document/4 internally. Adding another DataCase here
    # would duplicate that coverage; the spec's "if no clean upsert API yet,
    # validate→change→validate" fallback is what ships above.
  end

  describe "flat_mode — required/min/max/pattern (v1 behaviour preserved)" do
    setup do
      schema = %{
        "fields" => [
          %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
          %{
            "name" => "slug",
            "type" => "slug",
            "validation" => %{
              "required" => true,
              "min" => 3,
              "max" => 20,
              "pattern" => "^[a-z-]+$"
            }
          },
          %{"name" => "summary", "type" => "text"}
        ]
      }

      {:ok, schema: schema}
    end

    test "valid content returns :ok", %{schema: schema} do
      assert {:ok, _} = Validation.validate(%{"slug" => "hello"}, "Hello", schema)
    end

    test "missing required title fails", %{schema: schema} do
      assert {:error, %{"title" => ["Required"]}} =
               Validation.validate(%{"slug" => "hello"}, "", schema)
    end

    test "min/max/pattern surface as v1 strings", %{schema: schema} do
      {:error, errors} = Validation.validate(%{"slug" => "AB"}, "Hello", schema)
      msgs = Map.fetch!(errors, "slug")
      assert "Must be at least 3 characters" in msgs
      assert "Does not match required format" in msgs
    end
  end

  # ─── v2 recursion — composite ─────────────────────────────────────────────

  describe "v2 recursion — composite" do
    test "valid 2-level nested composite passes" do
      schema = %{
        "fields" => [
          %{
            "name" => "address",
            "type" => "composite",
            "fields" => [
              %{"name" => "street", "type" => "string"},
              %{
                "name" => "city",
                "type" => "composite",
                "fields" => [
                  %{"name" => "code", "type" => "string"},
                  %{"name" => "name", "type" => "string"}
                ]
              }
            ]
          }
        ]
      }

      content = %{
        "address" => %{
          "street" => "Main 1",
          "city" => %{"code" => "0150", "name" => "Oslo"}
        }
      }

      assert {:ok, ^content} = Validation.validate(content, nil, schema)
    end

    test "missing required nested string fails with the right path" do
      schema = %{
        "fields" => [
          %{
            "name" => "address",
            "type" => "composite",
            "fields" => [
              %{
                "name" => "city",
                "type" => "composite",
                "fields" => [
                  %{
                    "name" => "code",
                    "type" => "string",
                    "validation" => %{"required" => true}
                  }
                ]
              }
            ]
          }
        ]
      }

      content = %{"address" => %{"city" => %{}}}

      assert {:error, %{"address" => msgs}} = Validation.validate(content, nil, schema)
      assert Enum.any?(msgs, &String.contains?(&1, "/address/city/code"))
      assert Enum.any?(msgs, &String.contains?(&1, "Required"))
    end
  end

  # ─── v2 recursion — arrayOf ───────────────────────────────────────────────

  describe "v2 recursion — arrayOf" do
    test "arrayOf composites — valid passes" do
      schema = array_of_contributors_schema()

      content = %{
        "contributors" => [
          %{"role" => "author", "name" => "A"},
          %{"role" => "translator", "name" => "B"},
          %{"role" => "narrator", "name" => "C"}
        ]
      }

      assert {:ok, ^content} = Validation.validate(content, nil, schema)
    end

    test "bad element at index 2 fails with /contributors/2/role path" do
      schema = array_of_contributors_schema()

      content = %{
        "contributors" => [
          %{"role" => "author", "name" => "A"},
          %{"role" => "translator", "name" => "B"},
          # index 2 — missing required `role`
          %{"name" => "C"}
        ]
      }

      assert {:error, %{"contributors" => msgs}} = Validation.validate(content, nil, schema)
      assert Enum.any?(msgs, &String.contains?(&1, "/contributors/2/role"))
      assert Enum.any?(msgs, &String.contains?(&1, "Required"))
    end

    defp array_of_contributors_schema do
      %{
        "fields" => [
          %{
            "name" => "contributors",
            "type" => "arrayOf",
            "ordered" => true,
            "of" => %{
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "role",
                  "type" => "string",
                  "validation" => %{"required" => true}
                },
                %{"name" => "name", "type" => "string"}
              ]
            }
          }
        ]
      }
    end
  end

  describe "v2 recursion — composite-inside-array-inside-composite" do
    test "nested cross-field path is built correctly" do
      schema = %{
        "fields" => [
          %{
            "name" => "book",
            "type" => "composite",
            "fields" => [
              %{
                "name" => "contributors",
                "type" => "arrayOf",
                "of" => %{
                  "type" => "composite",
                  "fields" => [
                    %{
                      "name" => "address",
                      "type" => "composite",
                      "fields" => [
                        %{
                          "name" => "city",
                          "type" => "string",
                          "validation" => %{"required" => true}
                        }
                      ]
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      content = %{
        "book" => %{
          "contributors" => [
            %{"address" => %{"city" => "Oslo"}},
            # index 1 — missing city
            %{"address" => %{}}
          ]
        }
      }

      assert {:error, %{"book" => msgs}} = Validation.validate(content, nil, schema)
      assert Enum.any?(msgs, &String.contains?(&1, "/book/contributors/1/address/city"))
    end
  end

  # ─── v2 — codelist ────────────────────────────────────────────────────────

  describe "v2 — codelist (shape only; no registry membership)" do
    setup do
      schema = %{
        "fields" => [
          %{
            "name" => "lang",
            "type" => "codelist",
            "codelistId" => "onixedit:language",
            "version" => 73,
            "validation" => %{"required" => true}
          }
        ]
      }

      {:ok, schema: schema}
    end

    test "valid code passes", %{schema: schema} do
      assert {:ok, _} = Validation.validate(%{"lang" => "nob"}, nil, schema)
    end

    test "whitespace in code fails", %{schema: schema} do
      assert {:error, %{"lang" => msgs}} =
               Validation.validate(%{"lang" => "no b"}, nil, schema)

      assert Enum.any?(msgs, &String.contains?(&1, "whitespace"))
    end

    test "missing required code fails", %{schema: schema} do
      assert {:error, %{"lang" => msgs}} = Validation.validate(%{}, nil, schema)
      assert Enum.any?(msgs, &(&1 == "Required"))
    end

    # Codelist registry membership is checked at the rendering layer (W2.4
    # typeahead) and the cross-field DSL (Phase 3). The validator never
    # calls the registry — proven by this NOT failing on a bogus code.
    test "unknown but well-shaped code passes (no registry call)", %{schema: schema} do
      assert {:ok, _} =
               Validation.validate(%{"lang" => "bogus-but-shaped-fine"}, nil, schema)
    end
  end

  # ─── v2 — localizedText (fallbackChain is rendering's concern) ────────────

  describe "v2 — localizedText" do
    test "valid map of language → string passes" do
      schema = %{
        "fields" => [
          %{
            "name" => "title",
            "type" => "localizedText",
            "languages" => ["nob", "eng"],
            "format" => "plain",
            "fallbackChain" => ["nob", "eng", "first-non-empty"]
          }
        ]
      }

      content = %{"title" => %{"nob" => "Hei", "eng" => "Hi"}}
      assert {:ok, ^content} = Validation.validate(content, nil, schema)
    end

    # Warning-severity surfacing of missing primary translation lives in
    # W2.4 (rendering) + Phase 3 (DSL). Validator is shape-only — must NOT
    # raise or error on a missing primary.
    test "missing primary fallback language does not raise (rendering's concern)" do
      schema = %{
        "fields" => [
          %{
            "name" => "title",
            "type" => "localizedText",
            "languages" => ["nob", "eng"],
            "fallbackChain" => ["nob", "eng", "first-non-empty"]
          }
        ]
      }

      content = %{"title" => %{"eng" => "Hi"}}
      assert {:ok, ^content} = Validation.validate(content, nil, schema)
    end

    test "language outside declared set fails" do
      schema = %{
        "fields" => [
          %{
            "name" => "title",
            "type" => "localizedText",
            "languages" => ["nob", "eng"]
          }
        ]
      }

      content = %{"title" => %{"swe" => "Hej"}}
      assert {:error, %{"title" => msgs}} = Validation.validate(content, nil, schema)
      assert Enum.any?(msgs, &String.contains?(&1, "swe"))
    end
  end

  # ─── Phase 3 hand-off — top-level validations slot is inert ───────────────

  describe "v2 — validations slot (Phase 3 hand-off)" do
    test "validates_validations_slot_is_inert_in_phase_0" do
      schema = %{
        "fields" => [
          %{"name" => "isbn", "type" => "string"}
        ],
        # The cross-field rule evaluator ships in Phase 3. This rule MUST be
        # ignored here — even if the content would violate it, we return :ok.
        "validations" => [
          %{
            "name" => "isbn-required-when-published",
            "severity" => "error",
            "message" => "should never fire in Phase 0",
            "when" => %{"path" => "/status", "op" => "eq", "value" => "published"},
            "then" => %{"path" => "/isbn", "op" => "nonempty"}
          }
        ]
      }

      # Content that would violate the rule if Phase 3 were live.
      content = %{"isbn" => ""}

      assert {:ok, ^content} = Validation.validate(content, "any title", schema)
    end
  end
end
