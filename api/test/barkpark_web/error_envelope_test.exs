defmodule BarkparkWeb.ErrorEnvelopeTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.ErrorEnvelope

  describe "serialize_v1/1" do
    test "collapses a violation map to a flat list of strings under \"errors\"" do
      result = %{
        errors: [
          %{
            severity: :error,
            code: :required,
            message: "Required",
            rule_name: nil,
            path: "/title"
          },
          %{
            severity: :error,
            code: :max_items,
            message: "Too many items (max 3)",
            rule_name: nil,
            path: "/contributors"
          }
        ],
        warnings: [],
        infos: []
      }

      assert ErrorEnvelope.serialize_v1(result) ==
               %{
                 "errors" => [
                   "/title: Required",
                   "/contributors: Too many items (max 3)"
                 ]
               }
    end

    test "passes through a flat list of strings unchanged" do
      assert ErrorEnvelope.serialize_v1(["one", "two"]) ==
               %{"errors" => ["one", "two"]}
    end

    test "flattens the legacy %{field => [strings]} shape into prefixed strings" do
      legacy = %{"title" => ["can't be blank"], "slug" => ["already taken"]}

      assert %{"errors" => list} = ErrorEnvelope.serialize_v1(legacy)
      assert "title: can't be blank" in list
      assert "slug: already taken" in list
      assert length(list) == 2
    end

    test "non-violation, non-legacy maps return an empty error list" do
      assert ErrorEnvelope.serialize_v1(%{}) == %{"errors" => []}
      assert ErrorEnvelope.serialize_v1(:not_a_map) == %{"errors" => []}
    end
  end

  describe "serialize_v2/1" do
    test "groups violations by JSON Pointer path and preserves structure" do
      result = %{
        errors: [
          %{
            severity: :error,
            code: :required,
            message: "Required",
            rule_name: "title_required",
            path: "/title"
          },
          %{
            severity: :error,
            code: :type_mismatch,
            message: "Expected string",
            rule_name: nil,
            path: "/contributors/0/role"
          }
        ],
        warnings: [
          %{
            severity: :warning,
            code: :unknown_field,
            message: "Unknown field",
            rule_name: nil,
            path: "/legacy"
          }
        ],
        infos: []
      }

      v2 = ErrorEnvelope.serialize_v2(result)

      assert %{"errors" => errs, "warnings" => warns, "infos" => %{}} = v2

      assert [%{"code" => "required", "message" => "Required", "rule" => "title_required"}] =
               errs["/title"]

      assert [%{"code" => "type_mismatch", "severity" => "error"}] = errs["/contributors/0/role"]

      assert [%{"code" => "unknown_field", "severity" => "warning"}] = warns["/legacy"]
    end

    test "round-trips a validation_result with multiple violations on the same path" do
      result = %{
        errors: [
          %{severity: :error, code: :required, message: "Required", rule_name: nil, path: "/x"},
          %{severity: :error, code: :one_of, message: "Bad", rule_name: nil, path: "/x"}
        ]
      }

      assert %{"errors" => %{"/x" => list}} = ErrorEnvelope.serialize_v2(result)
      assert length(list) == 2
      assert Enum.map(list, & &1["code"]) == ["required", "one_of"]
    end

    test "synthesizes paths from the legacy %{field => [strings]} shape" do
      legacy = %{"title" => ["can't be blank"]}
      v2 = ErrorEnvelope.serialize_v2(legacy)

      assert %{"errors" => %{"/title" => [violation]}, "warnings" => %{}, "infos" => %{}} = v2
      assert violation["message"] == "can't be blank"
      assert violation["severity"] == "error"
      assert violation["code"] == "legacy"
    end

    test "recovers nested paths embedded in legacy nested validation messages" do
      # Validation.format_msg produces "/sub/path: msg" for nested errors
      legacy = %{"contributors" => ["/contributors/0/role: Required"]}
      v2 = ErrorEnvelope.serialize_v2(legacy)

      assert %{"errors" => errs} = v2
      assert [%{"message" => "Required"}] = errs["/contributors/0/role"]
    end

    test "non-violation, non-legacy input returns the empty v2 envelope" do
      assert ErrorEnvelope.serialize_v2(%{}) ==
               %{"errors" => %{}, "warnings" => %{}, "infos" => %{}}
    end
  end
end
