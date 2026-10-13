defmodule Barkpark.Content.SchemaFieldCollapseTest do
  @moduledoc """
  A composite field can start collapsed (Sanity's options.collapsible /
  collapsed): the schema stores `collapsible` and `collapsed` and the schema
  read returns both, so a Studio can render the state (task-58248fe3f19de814).
  Nothing else reads the keys yet, so a serializer that dropped them would go
  unnoticed; this pins them.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  test "a composite field's collapsible and collapsed survive the schema read" do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "page",
          "title" => "Page",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "seo",
              "title" => "SEO",
              "type" => "composite",
              "collapsible" => true,
              "collapsed" => true,
              "fields" => [%{"name" => "metaTitle", "title" => "Meta title", "type" => "string"}]
            }
          ]
        },
        "production"
      )

    {:ok, schema} = Content.get_schema("page", "production")
    seo = Enum.find(Content.serialize_schema_for_sdk(schema).fields, &(&1["name"] == "seo"))

    assert seo["collapsible"] == true
    assert seo["collapsed"] == true
  end
end
