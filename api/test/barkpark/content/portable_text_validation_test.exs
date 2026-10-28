defmodule Barkpark.Content.PortableTextValidationTest do
  @moduledoc """
  Structural checks on a stored Portable Text array (stage S1 of the Portable
  Text plan, task-9296af21cac3f813): keys, spans, marks, styles, lists and
  the custom, inline and annotation types a field declares. The schemas,
  text and keys are made up.
  """
  # Not async: one describe sets the enforce_datasets application env.
  use ExUnit.Case, async: false

  alias Barkpark.Content.PortableTextValidation, as: PTV
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.Validation

  defp span(key, text, marks \\ []),
    do: %{"_type" => "span", "_key" => key, "text" => text, "marks" => marks}

  defp block(key, children, extra \\ %{}),
    do:
      Map.merge(
        %{
          "_type" => "block",
          "_key" => key,
          "style" => "normal",
          "markDefs" => [],
          "children" => children
        },
        extra
      )

  # A declared Portable Text field: everything a test needs, nothing else.
  @field %{
    "name" => "body",
    "type" => "richText",
    "format" => "portableText",
    "blocks" => %{
      "styles" => ["normal", "h2"],
      "lists" => ["bullet"],
      "marks" => ["strong", "strike-through"],
      "annotations" => [
        %{
          "name" => "siteLink",
          "fields" => [
            %{"name" => "linkType", "type" => "string"},
            %{"name" => "href", "type" => "string", "validation" => %{"required" => true}}
          ]
        }
      ],
      "of" => [
        %{
          "name" => "factBox",
          "fields" => [
            %{"name" => "heading", "type" => "string", "validation" => %{"required" => true}}
          ]
        }
      ],
      "inline" => [
        %{
          "name" => "badge",
          "fields" => [
            %{"name" => "label", "type" => "string", "validation" => %{"required" => true}}
          ]
        }
      ]
    }
  }

  defp codes(value, field \\ @field),
    do: field |> PTV.findings(value, "/body", :error) |> Enum.map(&elem(&1, 2))

  defp paths(value, field \\ @field),
    do: field |> PTV.findings(value, "/body", :error) |> Enum.map(&elem(&1, 0))

  describe "a well-formed value" do
    test "has no finding" do
      value = [
        block("k1", [span("k1a", "A heading")], %{"style" => "h2"}),
        block(
          "k2",
          [
            span("k2a", "Plain, then "),
            span("k2b", "bold", ["strong"]),
            span("k2c", "a link", ["m1"])
          ],
          %{
            "markDefs" => [
              %{"_type" => "siteLink", "_key" => "m1", "href" => "https://example.com/x"}
            ]
          }
        ),
        block("k3", [span("k3a", "An item")], %{"listItem" => "bullet", "level" => 1}),
        %{"_type" => "factBox", "_key" => "k4", "heading" => "Made-up facts"},
        block("k5", [
          span("k5a", "With "),
          %{"_type" => "badge", "_key" => "k5b", "label" => "New"}
        ])
      ]

      assert codes(value) == []
    end

    test "a value that is not a list has no finding (HTML stored before ruling #44)" do
      assert codes("<p>Old</p>") == []
      assert codes(nil) == []
    end
  end

  describe "keys" do
    test "a missing or duplicate key on blocks, spans, markDefs and inline objects is named" do
      value = [
        block("d1", [span("s1", "a"), span("s1", "b")]),
        block("d1", [span(nil, "c") |> Map.delete("_key")]),
        %{"_type" => "factBox", "heading" => "No key"},
        block("d2", [span("x", "t", ["m1"])], %{
          "markDefs" => [
            %{"_type" => "siteLink", "_key" => "m1", "href" => "/a"},
            %{"_type" => "siteLink", "_key" => "m1", "href" => "/b"}
          ]
        })
      ]

      found = Enum.zip(paths(value), codes(value))

      assert {"/body/0/children/1", :pt_key_duplicate} in found
      assert {"/body/1", :pt_key_duplicate} in found
      assert {"/body/1/children/0", :pt_key_missing} in found
      assert {"/body/2", :pt_key_missing} in found
      assert {"/body/3/markDefs/1", :pt_key_duplicate} in found
    end
  end

  describe "spans and marks" do
    test "span text must be a string" do
      assert codes([block("b", [%{"_type" => "span", "_key" => "s", "text" => 3}])]) == [
               :pt_span_text
             ]
    end

    test "a mark is a declared decorator or a markDefs key in the same block" do
      value = [
        block("b1", [span("s1", "x", ["em"])]),
        block("b2", [span("s2", "y", ["m9"])], %{"markDefs" => []})
      ]

      assert codes(value) == [:pt_mark_undeclared, :pt_mark_undeclared]
    end

    test "strike-through and strikethrough name the same decorator" do
      value = [
        block("b", [span("s1", "x", ["strike-through"]), span("s2", "y", ["strikethrough"])])
      ]

      assert codes(value) == []
    end
  end

  describe "styles, lists and levels" do
    test "an undeclared style or list, and a level that is not a positive integer" do
      value = [
        block("b1", [span("s", "x")], %{"style" => "h4"}),
        block("b2", [span("s", "x")], %{"listItem" => "number"}),
        block("b3", [span("s", "x")], %{"listItem" => "bullet", "level" => 0})
      ]

      assert codes(value) == [:pt_style_undeclared, :pt_list_undeclared, :pt_level_shape]
    end
  end

  describe "custom, inline and annotation types" do
    test "an undeclared type of each kind is named" do
      value = [
        %{"_type" => "pollWidget", "_key" => "c1"},
        block("b", [%{"_type" => "emoji", "_key" => "i1"}, span("s", "x", ["m1"])], %{
          "markDefs" => [%{"_type" => "footnote", "_key" => "m1"}]
        })
      ]

      assert codes(value) == [
               :pt_block_type_undeclared,
               :pt_inline_type_undeclared,
               :pt_annotation_undeclared
             ]
    end

    test "declared fields are checked on a custom block, an inline object and an annotation" do
      value = [
        %{"_type" => "factBox", "_key" => "c1"},
        block("b", [%{"_type" => "badge", "_key" => "i1"}, span("s", "x", ["m1"])], %{
          "markDefs" => [%{"_type" => "siteLink", "_key" => "m1"}]
        })
      ]

      assert paths(value) == [
               "/body/0/heading",
               "/body/1/children/0/label",
               "/body/1/markDefs/0/href"
             ]

      assert codes(value) == [:required, :required, :required]
    end

    test "an annotation without an optional field (a link with no linkType) is fine" do
      value = [
        block("b", [span("s", "x", ["m1"])], %{
          "markDefs" => [%{"_type" => "siteLink", "_key" => "m1", "href" => "/somewhere"}]
        })
      ]

      assert codes(value) == []
    end
  end

  describe "the vocabulary" do
    test "a field with no blocks declaration is open: only structure is checked" do
      field = %{"name" => "intro", "type" => "richText"}

      value = [
        %{"_type" => "anyBlock", "_key" => "c1"},
        block("b", [span("s", "x", ["sparkle"])], %{"style" => "h9"})
      ]

      assert codes(value, field) == []
      assert codes([block("b", [span("s", 1)])], field) == [:pt_span_text]
    end

    test "a declared format takes Sanity's defaults for a kind it leaves out" do
      field = %{
        "name" => "intro",
        "type" => "richText",
        "format" => "portableText",
        "blocks" => %{}
      }

      ok = [
        block("b", [span("s", "x", ["em", "code", "m1"])], %{
          "style" => "blockquote",
          "listItem" => "number",
          "markDefs" => [%{"_type" => "link", "_key" => "m1", "href" => "/x"}]
        })
      ]

      assert codes(ok, field) == []
      assert codes([%{"_type" => "factBox", "_key" => "c"}], field) == [:pt_block_type_undeclared]
    end

    test "without a declared format, a kind the field leaves out stays open" do
      field = %{
        "name" => "intro",
        "type" => "richText",
        "blocks" => %{"of" => [%{"name" => "factBox"}]}
      }

      value = [
        block("b", [span("s", "x", ["m1"])], %{
          "style" => "h6",
          "markDefs" => [%{"_type" => "linkAnnotation", "_key" => "m1"}]
        }),
        %{"_type" => "factBox", "_key" => "c1"},
        %{"_type" => "pollWidget", "_key" => "c2"}
      ]

      assert codes(value, field) == [:pt_block_type_undeclared]
    end
  end

  describe "levels" do
    test "structural findings ride only the pass whose level is structural_level" do
      value = [block("b", [span("s", 1)])]

      assert [{_, _, :pt_span_text, _}] = PTV.findings(@field, value, "/body", :warning, :warning)
      assert [] == PTV.findings(@field, value, "/body", :error, :warning)
    end
  end

  describe "through Content.Validation" do
    @enforced "pt-enforced-dataset"

    defp schema(dataset),
      do: %SchemaDefinition{name: "story", title: "Story", dataset: dataset, fields: [@field]}

    setup do
      previous = Application.get_env(:barkpark, Validation, [])

      Application.put_env(
        :barkpark,
        Validation,
        Keyword.put(previous, :enforce_datasets, [@enforced])
      )

      on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)
    end

    test "a structural finding is a warning on a dataset that does not enforce" do
      content = %{"body" => [block("b", [span("s", 1)])]}

      %{errors: errors, warnings: warnings} =
        Validation.check_findings(content, "T", schema("production"))

      assert errors == []
      assert [%{code: :pt_span_text, path: "/body/0/children/0/text"}] = warnings
    end

    test "a structural finding is an error on a dataset that enforces" do
      content = %{"body" => [block("b", [span("s", 1)])]}

      %{errors: errors, warnings: warnings} =
        Validation.check_findings(content, "T", schema(@enforced))

      assert [%{code: :pt_span_text}] = errors
      assert warnings == []
    end

    test "a custom block is matched by _type, so its declared fields are checked" do
      content = %{"body" => [%{"_type" => "factBox", "_key" => "c1", "type" => "decoy"}]}
      %{errors: errors} = Validation.check_findings(content, "T", schema("production"))

      assert [%{code: :required, path: "/body/0/heading"}] = errors
    end

    test "a legacy body (no format) holding Portable Text is checked too" do
      field = %{
        "name" => "body",
        "type" => "richText",
        "blocks" => %{"of" => [%{"name" => "factBox"}]}
      }

      s = %SchemaDefinition{name: "story", title: "Story", dataset: "production", fields: [field]}

      content = %{
        "body" => [block("b", [span("s", "x")]), %{"_type" => "pollWidget", "_key" => "c"}]
      }

      assert [%{code: :pt_block_type_undeclared}] =
               Validation.check_findings(content, "T", s).warnings
    end
  end

  test "codes/0 are all known to Content.Validation" do
    assert PTV.codes() -- Validation.known_codes() == []
  end
end
