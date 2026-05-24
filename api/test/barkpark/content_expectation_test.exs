defmodule Barkpark.ContentExpectationTest do
  @moduledoc """
  Exp-P1 (barkpark-u7q5) — the Expectation read API. A schema's resolved
  Expectation is its SOFT `layout` + `prefill`: explicit stored columns when
  present, else a field-order default. Additive only — no document behaviour
  changes here.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo

  describe "Content.resolve_expectation/1" do
    test "returns the explicit stored layout/prefill when present (post-style)" do
      explicit_layout = [
        %{"kind" => "field", "name" => "title"},
        %{"kind" => "field", "name" => "slug"},
        %{"kind" => "field", "name" => "featuredImage"},
        %{"kind" => "region", "name" => "body"}
      ]

      {:ok, _schema} =
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(%{
          "name" => "post",
          "title" => "Post",
          "dataset" => "test",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "slug", "type" => "slug"},
            %{"name" => "featuredImage", "type" => "image"},
            %{"name" => "body", "type" => "richText"}
          ],
          "layout" => explicit_layout,
          "prefill" => %{"status" => "draft", "featured" => false}
        })
        |> Repo.insert()

      {:ok, schema} = Content.get_schema("post", "test")
      exp = Content.resolve_expectation(schema)

      assert exp.layout == explicit_layout
      assert exp.prefill == %{"status" => "draft", "featured" => false}
    end

    test "derives a field-order default when NO layout is stored (author-style)" do
      {:ok, _schema} =
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(%{
          "name" => "author",
          "title" => "Author",
          "dataset" => "test",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "slug", "type" => "slug"},
            %{"name" => "bio", "type" => "text"}
          ]
        })
        |> Repo.insert()

      {:ok, schema} = Content.get_schema("author", "test")
      exp = Content.resolve_expectation(schema)

      # EX1 (barkpark-q39y): each derived field entry carries soft once-cardinality
      # (max: 1, enforce: false). The trailing region carries no cardinality.
      assert exp.layout == [
               %{"kind" => "field", "name" => "name", "max" => 1, "enforce" => false},
               %{"kind" => "field", "name" => "slug", "max" => 1, "enforce" => false},
               %{"kind" => "field", "name" => "bio", "max" => 1, "enforce" => false},
               %{"kind" => "region", "name" => "body"}
             ]

      # No initial_values declared → empty prefill scaffold.
      assert exp.prefill == %{}
    end

    test "layout + prefill round-trip through the changeset and reload" do
      layout = [
        %{"kind" => "field", "name" => "title"},
        %{"kind" => "region", "name" => "body"}
      ]

      prefill = %{"status" => "draft", "nested" => %{"level" => 1}}

      {:ok, inserted} =
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(%{
          "name" => "page",
          "title" => "Page",
          "dataset" => "test",
          "fields" => [%{"name" => "title", "type" => "string"}],
          "layout" => layout,
          "prefill" => prefill
        })
        |> Repo.insert()

      reloaded = Repo.get!(SchemaDefinition, inserted.id)

      assert reloaded.layout == layout
      assert reloaded.prefill == prefill
    end

    test "default columns are empty when omitted entirely" do
      {:ok, schema} =
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(%{
          "name" => "category",
          "title" => "Category",
          "dataset" => "test",
          "fields" => [%{"name" => "title", "type" => "string"}]
        })
        |> Repo.insert()

      assert schema.layout == []
      assert schema.prefill == %{}
    end
  end
end
