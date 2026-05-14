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
      {:ok, doc} =
        Content.create_document(
          "widget",
          %{"_id" => "w1", "title" => "first widget"},
          "test"
        )

      assert doc.content["kind"] == "gizmo"
      assert doc.content["year"] == Integer.to_string(Date.utc_today().year)
      assert doc.content["today"] == Date.utc_today() |> Date.to_iso8601()
      assert doc.content["nested"] == %{"state" => "draft", "level" => 1}
    end

    test "provided values win — initial_values is a FLOOR not a ceiling" do
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

      # Provided scalar wins
      assert doc.content["kind"] == "doohickey"
      # Nested map deep-merges: provided "state" wins, default "level" survives
      assert doc.content["nested"] == %{"state" => "ready", "level" => 1}
      # Untouched default still applied
      assert doc.content["year"] == Integer.to_string(Date.utc_today().year)
    end

    test "deep_merge replaces lists wholesale" do
      a = %{"xs" => [1, 2, 3], "k" => "v"}
      b = %{"xs" => [9]}
      assert Content.deep_merge(a, b) == %{"xs" => [9], "k" => "v"}
    end

    test "resolve_dynamics resolves only at the leaves" do
      assert Content.resolve_dynamics(%{
               "a" => "$today",
               "b" => %{"c" => "$today.year"},
               "literal" => "today"
             }) == %{
               "a" => Date.utc_today() |> Date.to_iso8601(),
               "b" => %{"c" => Integer.to_string(Date.utc_today().year)},
               "literal" => "today"
             }
    end
  end

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
