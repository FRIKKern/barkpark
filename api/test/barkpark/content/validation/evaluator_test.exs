defmodule Barkpark.Content.Validation.EvaluatorTest do
  # Touches the Validation.Registry singleton. Keep synchronous.
  use ExUnit.Case, async: false

  alias Barkpark.Content.Validation.{Evaluator, Rules}

  defp compile!(json) do
    {:ok, rule} = Rules.compile(json)
    rule
  end

  describe "cross-field firing" do
    test "when=eq → then=nonempty fires only when the trigger holds" do
      rule =
        compile!(%{
          "name" => "isbn-required-on-epub",
          "severity" => "error",
          "message" => "ISBN required for epub",
          "when" => %{"path" => "/format", "op" => "eq", "value" => "epub"},
          "then" => %{"path" => "/isbn", "op" => "nonempty"}
        })

      pdf = %{"format" => "pdf", "isbn" => nil}
      epub_ok = %{"format" => "epub", "isbn" => "9780306406157"}
      epub_bad = %{"format" => "epub", "isbn" => nil}

      assert %{errors: [], warnings: [], infos: []} = Evaluator.run_rules(pdf, [rule], :mutate)

      assert %{errors: [], warnings: [], infos: []} =
               Evaluator.run_rules(epub_ok, [rule], :mutate)

      assert %{
               errors: [
                 %{
                   severity: :error,
                   code: "nonempty",
                   message: "ISBN required for epub",
                   rule_name: "isbn-required-on-epub",
                   path: "/isbn"
                 }
               ]
             } = Evaluator.run_rules(epub_bad, [rule], :mutate)
    end

    test "wildcard expansion in `then` emits one violation per failing element" do
      rule =
        compile!(%{
          "name" => "all-contributors-named",
          "severity" => "error",
          "message" => "Contributor name required",
          "when" => %{"path" => "/format", "op" => "eq", "value" => "book"},
          "then" => %{"path" => "/contributors/*/name", "op" => "nonempty"}
        })

      doc = %{
        "format" => "book",
        "contributors" => [
          %{"name" => "Pelle"},
          %{"name" => nil},
          %{"name" => ""}
        ]
      }

      assert %{errors: errors} = Evaluator.run_rules(doc, [rule], :mutate)
      assert length(errors) == 2

      paths = Enum.map(errors, & &1.path)
      assert "/contributors/1/name" in paths
      assert "/contributors/2/name" in paths
    end
  end

  describe "severity gates" do
    test "warnings and infos go to their own buckets" do
      warn =
        compile!(%{
          "name" => "title-recommended",
          "severity" => "warning",
          "when" => %{"path" => "/_id", "op" => "nonempty"},
          "then" => %{"path" => "/title", "op" => "nonempty"}
        })

      info =
        compile!(%{
          "name" => "fyi",
          "severity" => "info",
          "when" => %{"path" => "/_id", "op" => "nonempty"},
          "then" => %{"path" => "/notes", "op" => "nonempty"}
        })

      doc = %{"_id" => "x", "title" => nil, "notes" => nil}

      assert %{errors: [], warnings: [%{severity: :warning}], infos: [%{severity: :info}]} =
               Evaluator.run_rules(doc, [warn, info], :mutate)
    end
  end

  describe "tag filtering" do
    setup do
      rule_live =
        compile!(%{
          "name" => "live-only",
          "tags" => ["live"],
          "when" => %{"path" => "/_id", "op" => "nonempty"},
          "then" => %{"path" => "/title", "op" => "nonempty"}
        })

      rule_export =
        compile!(%{
          "name" => "export-only",
          "tags" => ["export"],
          "when" => %{"path" => "/_id", "op" => "nonempty"},
          "then" => %{"path" => "/title", "op" => "nonempty"}
        })

      rule_all =
        compile!(%{
          "name" => "always-on",
          "when" => %{"path" => "/_id", "op" => "nonempty"},
          "then" => %{"path" => "/title", "op" => "nonempty"}
        })

      doc = %{"_id" => "x", "title" => nil}
      {:ok, rules: [rule_live, rule_export, rule_all], doc: doc}
    end

    test "only live-tagged + untagged rules fire under :live", %{rules: rules, doc: doc} do
      %{errors: errors} = Evaluator.run_rules(doc, rules, :live)
      names = Enum.map(errors, & &1.rule_name) |> Enum.sort()
      assert names == ["always-on", "live-only"]
    end

    test "only export-tagged + untagged rules fire under :export", %{rules: rules, doc: doc} do
      %{errors: errors} = Evaluator.run_rules(doc, rules, :export)
      names = Enum.map(errors, & &1.rule_name) |> Enum.sort()
      assert names == ["always-on", "export-only"]
    end

    test "only untagged rule fires under :mutate", %{rules: rules, doc: doc} do
      %{errors: errors} = Evaluator.run_rules(doc, rules, :mutate)
      assert [%{rule_name: "always-on"}] = errors
    end
  end

  describe "per-checker integration" do
    test "matches:isbn13 false → violation; true → silence" do
      rule =
        compile!(%{
          "name" => "isbn-checksum",
          "severity" => "error",
          "when" => %{"path" => "/format", "op" => "eq", "value" => "epub"},
          "then" => %{"path" => "/isbn", "op" => "matches:isbn13"}
        })

      good = %{"format" => "epub", "isbn" => "9780306406157"}
      bad = %{"format" => "epub", "isbn" => "9780306406158"}

      assert %{errors: []} = Evaluator.run_rules(good, [rule], :mutate)

      assert %{errors: [%{code: "matches:isbn13", path: "/isbn"}]} =
               Evaluator.run_rules(bad, [rule], :mutate)
    end
  end

  describe "cache integration" do
    test "Rules.put/2 + Evaluator.run/3 round-trip via the named GenServer" do
      schema_id = "test-schema-#{System.unique_integer([:positive])}"

      rule =
        compile!(%{
          "name" => "from-cache",
          "when" => %{"path" => "/_id", "op" => "nonempty"},
          "then" => %{"path" => "/title", "op" => "nonempty"}
        })

      :ok = Rules.put(schema_id, [rule])
      doc = %{"_id" => "x", "title" => nil}

      assert %{errors: [%{rule_name: "from-cache"}]} = Evaluator.run(doc, schema_id, :mutate)

      :ok = Rules.invalidate(schema_id)
      assert %{errors: []} = Evaluator.run(doc, schema_id, :mutate)
    end
  end

  describe "default message" do
    test "synthesises a message when none is provided" do
      rule =
        compile!(%{
          "name" => "auto-msg",
          "when" => %{"path" => "/_id", "op" => "nonempty"},
          "then" => %{"path" => "/title", "op" => "nonempty"}
        })

      assert %{errors: [%{message: msg}]} =
               Evaluator.run_rules(%{"_id" => "x", "title" => nil}, [rule], :mutate)

      assert msg =~ "auto-msg"
      assert msg =~ "/title"
    end
  end
end
