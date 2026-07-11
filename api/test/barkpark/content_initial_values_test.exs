defmodule Barkpark.ContentInitialValuesTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo

  describe "schema-declared initial_values pre-fill new documents" do
    setup do
      {:ok, schema} =
        %SchemaDefinition{
          name: "widget",
          title: "Widget",
          dataset: "test",
          fields: [
            %{"name" => "kind", "type" => "string"},
            %{"name" => "year", "type" => "string"}
          ],
          initial_values: %{
            "kind" => "gizmo",
            "year" => "$today.year",
            "today" => "$today",
            "nested" => %{"state" => "draft", "level" => 1}
          }
        }
        |> Repo.insert()

      {:ok, schema: schema}
    end

    test "fills empty content with defaults, including dynamics" do
      # create_document resolves $today/$today.year off the UTC clock internally;
      # bracket it so a midnight/New-Year rollover between the stamp and the
      # assertion can't false-red (see today_set/2 + year_set/2 note below).
      d_before = Date.utc_today()

      {:ok, doc} =
        Content.create_document(
          "widget",
          %{"_id" => "w1", "title" => "first widget"},
          "test"
        )

      d_after = Date.utc_today()

      assert doc.content["kind"] == "gizmo"
      assert doc.content["year"] in year_set(d_before, d_after)
      assert doc.content["today"] in today_set(d_before, d_after)
      assert doc.content["nested"] == %{"state" => "draft", "level" => 1}
    end

    test "provided values win — initial_values is a FLOOR not a ceiling" do
      d_before = Date.utc_today()

      {:ok, doc} =
        Content.create_document(
          "widget",
          %{
            "_id" => "w2",
            "title" => "second widget",
            "kind" => "doohickey",
            "nested" => %{"state" => "ready"}
          },
          "test"
        )

      d_after = Date.utc_today()

      # Provided scalar wins
      assert doc.content["kind"] == "doohickey"
      # Nested map deep-merges: provided "state" wins, default "level" survives
      assert doc.content["nested"] == %{"state" => "ready", "level" => 1}
      # Untouched default still applied (boundary-safe — see year_set/2 note)
      assert doc.content["year"] in year_set(d_before, d_after)
    end

    test "deep_merge replaces lists wholesale" do
      a = %{"xs" => [1, 2, 3], "k" => "v"}
      b = %{"xs" => [9]}
      assert Content.deep_merge(a, b) == %{"xs" => [9], "k" => "v"}
    end

    test "resolve_dynamics resolves only at the leaves" do
      d_before = Date.utc_today()

      result =
        Content.resolve_dynamics(%{
          "a" => "$today",
          "b" => %{"c" => "$today.year"},
          "literal" => "today"
        })

      d_after = Date.utc_today()

      assert result["a"] in today_set(d_before, d_after)
      assert result["b"]["c"] in year_set(d_before, d_after)
      assert result["literal"] == "today"
      assert Map.keys(result) |> Enum.sort() == ["a", "b", "literal"]
    end
  end

  # $today / $today.year read the UTC clock inside create_document /
  # resolve_dynamics. Bracketing the code-under-test with clock reads and
  # asserting membership of the boundary set makes the assertion boundary-safe:
  # the stamped value happened between d_before and d_after, so it must equal one
  # of them (a test spans far less than a day). A genuinely wrong date/year is
  # still rejected — only the exact just-before/just-after values are accepted.
  defp today_set(d_before, d_after),
    do: [d_before, d_after] |> Enum.map(&Date.to_iso8601/1) |> Enum.uniq()

  defp year_set(d_before, d_after),
    do: [d_before, d_after] |> Enum.map(&Integer.to_string(&1.year)) |> Enum.uniq()

  test "no schema → unchanged content" do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"_id" => "p-noschema", "title" => "no schema"},
        "test-noschema"
      )

    # No schema row → no initial_values applied. Document still created.
    assert doc.content == %{}
  end
end
