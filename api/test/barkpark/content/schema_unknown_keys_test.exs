defmodule Barkpark.Content.SchemaUnknownKeysTest do
  @moduledoc """
  task-415c5c02fad8a3c7 — `SchemaUnknownKeys.unknown/1` names every key a
  schema apply carries that Barkpark never reads, by path. Advisory only.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.SchemaUnknownKeys

  defp paths(attrs), do: Enum.map(SchemaUnknownKeys.unknown(attrs), & &1.path)

  test "the three measured typos are each named by path" do
    attrs = %{
      "name" => "post",
      "title" => "Post",
      "singelton" => true,
      "fields" => [
        %{"name" => "a", "type" => "string", "requred" => true},
        %{"name" => "b", "type" => "string", "validation" => %{"requird" => true}}
      ]
    }

    assert paths(attrs) == ["/singelton", "/fields/0/requred", "/fields/1/validation/requird"]
  end

  test "nested positions: composite fields, rule lists, arrayOf of map and list, image fields, blocks.of, blocks.inline" do
    attrs = %{
      "name" => "post",
      "title" => "Post",
      "fields" => [
        %{
          "name" => "seo",
          "type" => "composite",
          "fields" => [%{"name" => "t", "type" => "string", "hiden" => true}]
        },
        %{
          "name" => "c",
          "type" => "string",
          "validation" => [%{"required" => true}, %{"mx" => 3}]
        },
        %{"name" => "rows", "type" => "arrayOf", "of" => %{"type" => "string", "titel" => "x"}},
        %{
          "name" => "items",
          "type" => "arrayOf",
          "of" => [%{"name" => "card", "type" => "composite", "fieldz" => []}]
        },
        %{
          "name" => "img",
          "type" => "image",
          "fields" => [%{"name" => "alt", "type" => "string", "x" => 1}]
        },
        %{
          "name" => "body",
          "type" => "richText",
          "blocks" => %{
            "of" => [
              "image",
              %{"name" => "cta", "fields" => [%{"name" => "u", "type" => "url", "y" => 1}]}
            ],
            "inline" => [
              "mention",
              %{"name" => "chip", "fields" => [%{"name" => "t", "type" => "string", "z" => 1}]}
            ]
          }
        }
      ]
    }

    assert paths(attrs) == [
             "/fields/0/fields/0/hiden",
             "/fields/1/validation/1/mx",
             "/fields/2/of/titel",
             "/fields/3/of/0/fieldz",
             "/fields/4/fields/0/x",
             "/fields/5/blocks/of/1/fields/0/y",
             "/fields/5/blocks/inline/1/fields/0/z"
           ]
  end

  test "a clean schema, and the keys a pulled schema echoes back, produce nothing" do
    attrs = %{
      "id" => "post",
      "name" => "post",
      "title" => "Post",
      "schemaHash" => "abc",
      "singleton" => false,
      "desk_groups" => [],
      "fields" => [
        %{
          "name" => "slug",
          "type" => "slug",
          "required?" => true,
          "options" => %{"source" => "title"},
          "validation" => [
            %{"required" => true, "pattern" => "^[a-z]+$", "message" => "m", "level" => "error"}
          ]
        }
      ]
    }

    assert SchemaUnknownKeys.unknown(attrs) == []
  end

  test "a camelCase echo key names the snake_case key the changeset stores" do
    [a] = SchemaUnknownKeys.unknown(%{"name" => "p", "title" => "P", "deskGroups" => []})
    assert a.path == "/deskGroups"
    assert a.message =~ "desk_groups"
  end

  # The vocabulary guard: every schema a shipped plugin registers must pass
  # clean, or the advisory would cry wolf on Barkpark's own shapes.
  test "no shipped plugin schema trips an advisory" do
    {:ok, mods} = :application.get_key(:barkpark, :modules)

    plugins =
      Enum.filter(mods, fn m ->
        Code.ensure_loaded?(m) and
          Barkpark.Plugin in (m.module_info(:attributes)[:behaviour] || [])
      end)

    assert length(plugins) >= 10

    flagged =
      for p <- plugins,
          s <- p.register_schemas(dataset: "census"),
          a <-
            SchemaUnknownKeys.unknown(%{
              "name" => s.name,
              "title" => s.title,
              "fields" => s.fields
            }),
          do: {p, s.name, a.path}

    assert flagged == []
  end
end
