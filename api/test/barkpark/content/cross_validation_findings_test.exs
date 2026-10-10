defmodule Barkpark.Content.CrossValidationFindingsTest do
  @moduledoc """
  task-9754deb160e95a80 — a schema's `cross_validations` become validation
  findings through `Validation.cross_findings/3`, built from the same
  `CrossValidator.violations/2` the Studio banner renders.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Content.{CrossValidator, Validation}

  @schema %{
    "name" => "book",
    "fields" => [
      %{"name" => "isbn", "type" => "string"},
      %{"name" => "gtin", "type" => "string"},
      %{"name" => "subtitle", "type" => "string"}
    ],
    "cross_validations" => [
      %{
        "name" => "isbn_xor_gtin",
        "title" => "At least one product identifier required",
        "level" => "error",
        "fields" => ["isbn", "gtin"],
        "rule" => %{
          "any" => [
            %{"field" => "isbn", "operator" => "non_empty"},
            %{"field" => "gtin", "operator" => "non_empty"}
          ]
        }
      },
      %{
        "name" => "subtitle_wanted",
        "level" => "warning",
        "fields" => ["subtitle"],
        "rule" => %{"field" => "subtitle", "operator" => "non_empty"}
      },
      # Unevaluable: names a field the schema does not declare.
      %{
        "name" => "ghost",
        "level" => "error",
        "rule" => %{"field" => "nope", "operator" => "non_empty"}
      },
      # Unevaluable: unknown operator.
      %{
        "name" => "bad_op",
        "level" => "error",
        "rule" => %{"field" => "isbn", "operator" => "matches"}
      },
      # Unevaluable: no rule body.
      %{"name" => "empty", "level" => "error"}
    ]
  }

  test "partition names each unevaluable rule and keeps the rest" do
    {ok, bad} = CrossValidator.partition(@schema)
    assert Enum.map(ok, & &1["name"]) == ["isbn_xor_gtin", "subtitle_wanted"]

    assert Enum.map(bad, fn {r, why} -> {r["name"], why} end) == [
             {"ghost", ~s(no field "nope")},
             {"bad_op", ~s(unknown operator "matches")},
             {"empty", "no rule body"}
           ]
  end

  test "an error-level violation is an error finding, a warning-level one a warning" do
    log =
      capture_log(fn ->
        %{errors: errors, warnings: warnings} = Validation.cross_findings(%{}, "T", @schema)

        assert [
                 %{
                   path: "/isbn",
                   code: :cross_validation,
                   message: "At least one product identifier required",
                   params: %{name: "isbn_xor_gtin", fields: ["isbn", "gtin"], level: "error"}
                 }
               ] = errors

        assert [%{path: "/subtitle", message: "subtitle_wanted", params: %{level: "warning"}}] =
                 warnings
      end)

    # The unevaluable rules gave no finding above, and each left a log line.
    for name <- ~w(ghost bad_op empty), do: assert(log =~ ~s(cross_validation "#{name}"))
  end

  test "satisfied rules give no finding" do
    content = %{"isbn" => "978", "subtitle" => "s"}

    capture_log(fn ->
      assert Validation.cross_findings(content, "T", @schema) == %{errors: [], warnings: []}
    end)
  end

  test "a schema without cross_validations gives nothing and logs nothing" do
    schema = Map.delete(@schema, "cross_validations")
    assert capture_log(fn -> Validation.cross_findings(%{}, "T", schema) end) == ""
    assert Validation.cross_findings(%{}, "T", schema) == %{errors: [], warnings: []}
  end

  # The banner (CrossValidator.violations/2, rendered by
  # cross_violations_banner/1 as title || name) and the write door must list
  # the same rules at the same levels with the same words, for every doc.
  test "parity: the write-door findings are exactly the Studio banner's violations" do
    docs = [
      %{},
      %{"isbn" => "978"},
      %{"subtitle" => "s"},
      %{"isbn" => "", "gtin" => "123", "subtitle" => ""},
      %{"isbn" => "978", "subtitle" => "s"}
    ]

    capture_log(fn ->
      for doc <- docs do
        banner =
          @schema
          |> CrossValidator.violations(Map.put(doc, "title", "T"))
          |> Enum.map(&{&1["name"], &1["level"], &1["title"] || &1["name"]})
          |> Enum.sort()

        %{errors: e, warnings: w} = Validation.cross_findings(doc, "T", @schema)

        door = Enum.sort(for f <- e ++ w, do: {f.params.name, f.params.level, f.message})

        assert door == banner,
               "doc #{inspect(doc)}: banner #{inspect(banner)} vs door #{inspect(door)}"
      end
    end)
  end

  test ":cross_validation is in the closed code set" do
    assert :cross_validation in Validation.known_codes()
  end
end
