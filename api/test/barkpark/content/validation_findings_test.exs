defmodule Barkpark.Content.ValidationFindingsTest do
  @moduledoc """
  task-a842b831fd6285d7 — `Validation.check_findings/3` is the same walk as
  `check/3`, additive: every finding carries a stable `code` (one of
  `Validation.known_codes/0`) and a `params` map alongside the SAME generated
  English `message`, for a caller (Studio) that renders its own sentence per
  code instead of trusting the English text.

  The census at the bottom asserts the CLOSED-SET property every one of this
  file's fixtures exercises a slice of: nothing this module can emit ever
  carries a code outside `known_codes/0`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Validation

  # ── flat_mode (v1) — required/min/max/pattern on a plain field ───────────

  @flat_schema %{
    "name" => "post",
    "fields" => [
      %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
      %{"name" => "slug", "type" => "string", "validation" => %{"min" => 3, "max" => 5}},
      %{"name" => "code", "type" => "string", "validation" => %{"pattern" => "^[a-z]+$"}}
    ]
  }

  test "flat_mode: required" do
    assert %{errors: [finding]} = Validation.check_findings(%{}, "", @flat_schema)
    assert finding.code == :required
    assert finding.message == "Required"
    assert finding.path == "/title"
  end

  test "flat_mode: string_too_short and string_too_long" do
    content = %{"title" => "t", "slug" => "ab"}
    %{errors: findings} = Validation.check_findings(content, "t", @flat_schema)
    short = Enum.find(findings, &(&1.path == "/slug"))
    assert short.code == :string_too_short
    assert short.params == %{min: 3}
    assert short.message == "Must be at least 3 characters"
  end

  test "flat_mode: string_too_long" do
    content = %{"title" => "t", "slug" => "abcdef"}
    %{errors: findings} = Validation.check_findings(content, "t", @flat_schema)
    long = Enum.find(findings, &(&1.path == "/slug"))
    assert long.code == :string_too_long
    assert long.params == %{max: 5}
  end

  test "flat_mode: pattern_mismatch" do
    content = %{"title" => "t", "code" => "ABC"}
    %{errors: findings} = Validation.check_findings(content, "t", @flat_schema)
    bad = Enum.find(findings, &(&1.path == "/code"))
    assert bad.code == :pattern_mismatch
    assert bad.message == "Does not match required format"
  end

  # ── v2: composite / arrayOf shapes, list bounds, numeric bounds ──────────

  @v2_schema %{
    "name" => "frontpage",
    "fields" => [
      %{
        "name" => "seo",
        "type" => "composite",
        "fields" => [%{"name" => "title", "type" => "string"}]
      },
      %{
        "name" => "banners",
        "type" => "arrayOf",
        "validation" => %{"min" => 1, "max" => 2, "unique" => true},
        "of" => %{"type" => "string"}
      },
      %{"name" => "weight", "type" => "number", "validation" => %{"min" => 1, "max" => 10}}
    ]
  }

  test "v2: expected_object on a composite" do
    %{errors: findings} = Validation.check_findings(%{"seo" => "not a map"}, "t", @v2_schema)
    f = Enum.find(findings, &(&1.path == "/seo"))
    assert f.code == :expected_object
  end

  test "v2: expected_list on an arrayOf" do
    %{errors: findings} = Validation.check_findings(%{"banners" => "nope"}, "t", @v2_schema)
    f = Enum.find(findings, &(&1.path == "/banners"))
    assert f.code == :expected_list
  end

  test "v2: list_too_short, list_too_long, list_not_unique" do
    %{errors: short} = Validation.check_findings(%{"banners" => []}, "t", @v2_schema)
    assert Enum.find(short, &(&1.path == "/banners")).code == :list_too_short
    assert Enum.find(short, &(&1.path == "/banners")).params == %{min: 1}

    %{errors: long} = Validation.check_findings(%{"banners" => ~w(a b c)}, "t", @v2_schema)
    assert Enum.find(long, &(&1.path == "/banners")).code == :list_too_long
    assert Enum.find(long, &(&1.path == "/banners")).params == %{max: 2}

    %{errors: dup} = Validation.check_findings(%{"banners" => ~w(a a)}, "t", @v2_schema)
    assert Enum.find(dup, &(&1.path == "/banners")).code == :list_not_unique
  end

  test "v2: number_too_small and number_too_large" do
    %{errors: lo} = Validation.check_findings(%{"weight" => 0}, "t", @v2_schema)
    f = Enum.find(lo, &(&1.path == "/weight"))
    assert f.code == :number_too_small
    assert f.params == %{min: 1}

    %{errors: hi} = Validation.check_findings(%{"weight" => 11}, "t", @v2_schema)
    f = Enum.find(hi, &(&1.path == "/weight"))
    assert f.code == :number_too_large
    assert f.params == %{max: 10}
  end

  # ── v2: codelist shape ────────────────────────────────────────────────────

  @codelist_schema %{
    "name" => "post",
    "fields" => [%{"name" => "category", "type" => "codelist", "codelistId" => "test:category"}]
  }

  test "v2: codelist_not_string, codelist_empty, codelist_has_whitespace" do
    %{errors: a} = Validation.check_findings(%{"category" => 42}, "t", @codelist_schema)
    assert Enum.find(a, &(&1.path == "/category")).code == :codelist_not_string

    %{errors: b} = Validation.check_findings(%{"category" => ""}, "t", @codelist_schema)
    assert Enum.find(b, &(&1.path == "/category")).code == :codelist_empty

    %{errors: c} = Validation.check_findings(%{"category" => "a b"}, "t", @codelist_schema)
    assert Enum.find(c, &(&1.path == "/category")).code == :codelist_has_whitespace
  end

  # ── v2: localizedText shape ───────────────────────────────────────────────

  @localized_schema %{
    "name" => "post",
    "fields" => [
      %{
        "name" => "heading",
        "type" => "localizedText",
        "languages" => ["nob", "eng"],
        "format" => "rich"
      },
      %{"name" => "plain", "type" => "localizedText", "languages" => ["nob"]}
    ]
  }

  test "v2: localized_text_shape when the value isn't a map" do
    %{errors: findings} =
      Validation.check_findings(%{"heading" => "nope"}, "t", @localized_schema)

    assert Enum.find(findings, &(&1.path == "/heading")).code == :localized_text_shape
  end

  test "v2: language_not_declared and rich_text_shape" do
    %{errors: findings} =
      Validation.check_findings(%{"heading" => %{"fin" => "moi"}}, "t", @localized_schema)

    f = Enum.find(findings, &(&1.path == "/heading/fin"))
    assert f.code == :language_not_declared
    assert f.params == %{lang: "fin"}

    %{errors: shape} =
      Validation.check_findings(%{"heading" => %{"nob" => 123}}, "t", @localized_schema)

    assert Enum.find(shape, &(&1.path == "/heading/nob")).code == :rich_text_shape
  end

  test "v2: text_not_string on a non-rich localizedText" do
    %{errors: findings} =
      Validation.check_findings(%{"plain" => %{"nob" => 123}}, "t", @localized_schema)

    assert Enum.find(findings, &(&1.path == "/plain/nob")).code == :text_not_string
  end

  # ── v2: image / file structured shapes ────────────────────────────────────

  @image_schema %{
    "name" => "post",
    "fields" => [
      %{
        "name" => "mainImage",
        "type" => "image",
        "options" => %{"hotspot" => true},
        "fields" => [
          %{"name" => "alt", "type" => "string", "validation" => %{"required" => true}}
        ]
      },
      %{"name" => "doc", "type" => "file", "fields" => [%{"name" => "label", "type" => "string"}]}
    ]
  }

  test "v2: image_shape, rect_shape, rect_out_of_range" do
    %{errors: shape} = Validation.check_findings(%{"mainImage" => 42}, "t", @image_schema)
    assert Enum.find(shape, &(&1.path == "/mainImage")).code == :image_shape

    img = %{
      "_type" => "image",
      "asset" => %{"_ref" => "x"},
      "hotspot" => "nope",
      "alt" => "ok"
    }

    %{errors: rect} = Validation.check_findings(%{"mainImage" => img}, "t", @image_schema)
    f = Enum.find(rect, &(&1.path == "/mainImage/hotspot"))
    assert f.code == :rect_shape
    assert f.params == %{sides: ~w(x y height width)}

    img2 = Map.put(img, "hotspot", %{"x" => 2, "y" => 0.5, "height" => 0.5, "width" => 0.5})

    %{errors: out_of_range} =
      Validation.check_findings(%{"mainImage" => img2}, "t", @image_schema)

    f2 = Enum.find(out_of_range, &(&1.path == "/mainImage/hotspot/x"))
    assert f2.code == :rect_out_of_range
    assert f2.params == %{min: 0, max: 1}
  end

  test "v2: file_shape" do
    %{errors: findings} = Validation.check_findings(%{"doc" => 42}, "t", @image_schema)
    assert Enum.find(findings, &(&1.path == "/doc")).code == :file_shape
  end

  # ── v2: arrayOf with several NAMED member types (of_types) ────────────────

  @typed_array_schema %{
    "name" => "post",
    "fields" => [
      %{
        "name" => "links",
        "type" => "arrayOf",
        "of" => [
          %{
            "name" => "externalLink",
            "type" => "composite",
            "fields" => [%{"name" => "url", "type" => "string"}]
          }
        ]
      }
    ]
  }

  test "v2: missing_type, unknown_type, expected_object on a typed arrayOf" do
    %{errors: missing} = Validation.check_findings(%{"links" => [%{}]}, "t", @typed_array_schema)
    assert Enum.find(missing, &(&1.path == "/links/0")).code == :missing_type

    %{errors: unknown} =
      Validation.check_findings(%{"links" => [%{"_type" => "ghost"}]}, "t", @typed_array_schema)

    f = Enum.find(unknown, &(&1.path == "/links/0"))
    assert f.code == :unknown_type
    assert f.params == %{type_name: "ghost"}

    %{errors: not_map} =
      Validation.check_findings(%{"links" => ["bare string"]}, "t", @typed_array_schema)

    assert Enum.find(not_map, &(&1.path == "/links/0")).code == :expected_object
  end

  # ── richText custom object blocks: not_in_list, block required field ─────

  @callout %{
    "name" => "callout",
    "fields" => [
      %{
        "name" => "tone",
        "type" => "string",
        "options" => %{"list" => [%{"title" => "Info", "value" => "info"}, "warning"]},
        "validation" => %{"required" => true}
      },
      %{"name" => "text", "type" => "text", "validation" => %{"required" => true}}
    ]
  }

  @rich_schema %{
    "name" => "post",
    "fields" => [
      %{
        "name" => "body",
        "type" => "richText",
        "editor" => "blocks",
        "blocks" => %{"of" => ["image", @callout]}
      }
    ]
  }

  defp callout(attrs), do: Map.merge(%{"type" => "callout"}, attrs)

  test "v2: not_in_list and required inside a richText custom object block" do
    body = [callout(%{"tone" => "loud"})]
    %{errors: findings} = Validation.check_findings(%{"body" => body}, "t", @rich_schema)

    tone = Enum.find(findings, &(&1.path == "/body/0/tone"))
    assert tone.code == :not_in_list
    assert tone.params == %{allowed: ["info", "warning"]}

    text = Enum.find(findings, &(&1.path == "/body/0/text"))
    assert text.code == :required
  end

  # ── schema-authored override: every fired check collapses to :custom ─────

  @custom_schema %{
    "name" => "post",
    "fields" => [
      %{
        "name" => "slug",
        "type" => "string",
        "validation" => %{"required" => true, "message" => "Du må fylle ut slug."}
      }
    ]
  }

  test "a schema-authored message overrides the code to :custom" do
    %{errors: [finding]} = Validation.check_findings(%{}, "t", @custom_schema)
    assert finding.code == :custom
    assert finding.message == "Du må fylle ut slug."
  end

  # ── the closed-set census ─────────────────────────────────────────────────

  describe "known_codes/0 — the closed set" do
    test "every finding this test file produced carries a code from the fixed known set" do
      fixtures = [
        {%{}, @flat_schema},
        {%{"title" => "t", "slug" => "ab"}, @flat_schema},
        {%{"title" => "t", "slug" => "abcdef"}, @flat_schema},
        {%{"title" => "t", "code" => "ABC"}, @flat_schema},
        {%{"seo" => "not a map"}, @v2_schema},
        {%{"banners" => "nope"}, @v2_schema},
        {%{"banners" => []}, @v2_schema},
        {%{"banners" => ~w(a b c)}, @v2_schema},
        {%{"banners" => ~w(a a)}, @v2_schema},
        {%{"weight" => 0}, @v2_schema},
        {%{"weight" => 11}, @v2_schema},
        {%{"category" => 42}, @codelist_schema},
        {%{"category" => ""}, @codelist_schema},
        {%{"category" => "a b"}, @codelist_schema},
        {%{"heading" => "nope"}, @localized_schema},
        {%{"heading" => %{"fin" => "moi"}}, @localized_schema},
        {%{"heading" => %{"nob" => 123}}, @localized_schema},
        {%{"plain" => %{"nob" => 123}}, @localized_schema},
        {%{"mainImage" => 42}, @image_schema},
        {%{"doc" => 42}, @image_schema},
        {%{"links" => [%{}]}, @typed_array_schema},
        {%{"links" => [%{"_type" => "ghost"}]}, @typed_array_schema},
        {%{"links" => ["bare string"]}, @typed_array_schema},
        {%{"body" => [callout(%{"tone" => "loud"})]}, @rich_schema},
        {%{}, @custom_schema}
      ]

      known = MapSet.new(Validation.known_codes())

      for {content, schema} <- fixtures do
        %{errors: errors, warnings: warnings} = Validation.check_findings(content, "t", schema)

        for finding <- errors ++ warnings do
          assert finding.code in known,
                 "#{inspect(finding.code)} (from #{inspect(finding)}) is not in Validation.known_codes/0"

          assert is_binary(finding.path)
          assert is_binary(finding.message)
          assert is_map(finding.params)
        end
      end
    end

    test "known_codes/0 is the fixed set this test exercises -- a surprise addition fails loudly" do
      assert Enum.sort(Validation.known_codes()) ==
               Enum.sort(~w(
                 required pattern_mismatch expected_object expected_list
                 codelist_not_string codelist_empty codelist_has_whitespace
                 localized_text_shape language_key_not_string language_not_declared
                 rich_text_shape text_not_string image_shape file_shape
                 rect_shape rect_out_of_range missing_type unknown_type
                 block_fields_invalid not_in_list list_too_short list_too_long
                 list_not_unique number_too_small number_too_large
                 string_too_short string_too_long portable_text_not_portabledoc custom
               )a)
    end
  end
end
