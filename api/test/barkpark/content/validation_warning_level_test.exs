defmodule Barkpark.Content.ValidationWarningLevelTest do
  @moduledoc """
  Gyldendal parity E1.6 (task-cd8e10ca44ccb932, criterion 3) — Sanity's
  warning-level validation. A rule map (or list entry) carrying
  `"level": "warning"` produces WARNINGS that `check/3` reports and
  `validate/3` ignores; an error-level rule still blocks; `"message"`
  replaces the generated wording.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Validation

  @flat_schema %{
    "name" => "publication",
    "fields" => [
      %{"name" => "title", "title" => "Tittel", "type" => "string"},
      %{
        "name" => "shortDescription",
        "title" => "Ingress",
        "type" => "text",
        "validation" => %{
          "max" => 10,
          "level" => "warning",
          "message" => "Over 10 tegn blir klippet på kortet."
        }
      },
      %{
        "name" => "isbn",
        "title" => "ISBN",
        "type" => "string",
        "validation" => %{"pattern" => "^[0-9]{13}$"}
      },
      %{
        "name" => "cover",
        "title" => "Omslag",
        "type" => "string",
        "validation" => [
          %{"required" => true},
          %{
            "min" => 5,
            "level" => "warning",
            "message" => "Bilder uten alternativ tekst er ikke tilgjengelige."
          }
        ]
      }
    ]
  }

  # A v2 schema (composite present) takes the recursive walker.
  @v2_schema %{
    "name" => "publication",
    "fields" => [
      %{"name" => "title", "title" => "Tittel", "type" => "string"},
      %{
        "name" => "shortDescription",
        "title" => "Ingress",
        "type" => "text",
        "validation" => %{
          "max" => 10,
          "level" => "warning",
          "message" => "Too long for the card."
        }
      },
      %{
        "name" => "cover",
        "title" => "Omslag",
        "type" => "composite",
        "fields" => [
          %{
            "name" => "alt",
            "title" => "Alt",
            "type" => "string",
            "validation" => %{
              "required" => true,
              "level" => "warning",
              "message" => "Add alt text."
            }
          }
        ]
      },
      %{
        "name" => "author",
        "title" => "Forfatter",
        "type" => "reference",
        "refType" => "author",
        "validation" => %{"required" => true}
      }
    ]
  }

  describe "flat schema" do
    test "a warning-level rule is a warning, not an error" do
      content = %{"shortDescription" => "far too long for the card", "cover" => "cover.jpg"}

      assert {:ok, ^content} = Validation.validate(content, "T", @flat_schema)

      assert %{
               errors: %{},
               warnings: %{"shortDescription" => ["Over 10 tegn blir klippet på kortet."]}
             } =
               Validation.check(content, "T", @flat_schema)
    end

    test "an error-level rule still blocks, and the two levels are reported apart" do
      content = %{"shortDescription" => "ok", "isbn" => "nope", "cover" => "x.j"}

      assert {:error, errors} = Validation.validate(content, "T", @flat_schema)
      assert errors["isbn"] == ["Does not match required format"]
      refute Map.has_key?(errors, "shortDescription")

      %{errors: errors, warnings: warnings} = Validation.check(content, "T", @flat_schema)
      assert errors["isbn"] == ["Does not match required format"]
      # `cover`: the required (error) half is satisfied, the min (warning) half is not.
      assert warnings["cover"] == ["Bilder uten alternativ tekst er ikke tilgjengelige."]
      refute Map.has_key?(errors, "cover")
    end

    test "a list of rule maps splits by level: required blocks, the warning entry warns" do
      content = %{"shortDescription" => "ok"}

      assert {:error, %{"cover" => ["Required"]}} =
               Validation.validate(content, "T", @flat_schema)

      assert %{warnings: warnings} = Validation.check(content, "T", @flat_schema)
      # Absent value: the warning-level `min` never fires on a blank (byte-identical to v1 min).
      refute Map.has_key?(warnings, "cover")
    end

    test "rules_at/2 reads a map or a list at one level" do
      assert Validation.rules_at(%{"max" => 3}, :error) == %{"max" => 3}
      assert Validation.rules_at(%{"max" => 3}, :warning) == %{}

      assert Validation.rules_at(%{"max" => 3, "level" => "warning"}, :warning) == %{
               "max" => 3,
               "level" => "warning"
             }

      assert Validation.rules_at(%{"max" => 3, "level" => "warning"}, :error) == %{}

      list = [%{"required" => true}, %{"max" => 3, "level" => "warning"}, %{"pattern" => "x"}]
      assert Validation.rules_at(list, :error) == %{"required" => true, "pattern" => "x"}
      assert Validation.rules_at(list, :warning) == %{"max" => 3, "level" => "warning"}
      assert Validation.rules_at(nil, :error) == %{}
      assert Validation.rules_at("garbage", :warning) == %{}
    end
  end

  describe "v2 schema (recursive walker)" do
    test "warnings walk into composites with their path; errors stay errors" do
      content = %{
        "shortDescription" => "far too long for the card",
        "cover" => %{"url" => "x.jpg"},
        "author" => nil
      }

      assert {:error, errors} = Validation.validate(content, "T", @v2_schema)
      assert errors == %{"author" => ["Required"]}

      %{errors: errors, warnings: warnings} = Validation.check(content, "T", @v2_schema)
      assert errors == %{"author" => ["Required"]}
      assert warnings["shortDescription"] == ["Too long for the card."]
      assert warnings["cover"] == ["/cover/alt: Add alt text."]
    end

    test "a malformed value is a shape ERROR only — never duplicated as a warning" do
      content = %{"cover" => ["not", "an", "object"], "author" => "a-1"}

      %{errors: errors, warnings: warnings} = Validation.check(content, "T", @v2_schema)
      assert errors["cover"] == ["expected an object"]
      refute Map.has_key?(warnings, "cover")
    end

    test "content that satisfies every rule has neither" do
      content = %{
        "shortDescription" => "short",
        "cover" => %{"url" => "x.jpg", "alt" => "A cover"},
        "author" => "a-1"
      }

      assert %{errors: %{}, warnings: %{}} = Validation.check(content, "T", @v2_schema)
    end
  end
end
