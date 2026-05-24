defmodule Barkpark.Plugins.MediaTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Media

  describe "manifest/0" do
    test "returns the parsed plugin.json map" do
      manifest = Media.manifest()

      assert manifest["plugin_name"] == "media"
      assert manifest["module"] == "Barkpark.Plugins.Media"
      assert "schemas" in manifest["capabilities"]
      assert "codelists" in manifest["capabilities"]
    end

    test "declares mediaAsset and mediaCollection schema files" do
      names = Media.manifest()["schemas"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["mediaAsset", "mediaCollection"]
    end
  end

  describe "register_schemas/1" do
    test "returns two v2 SchemaDefinition structs" do
      schemas = Media.register_schemas([])

      assert length(schemas) == 2
      assert Enum.all?(schemas, &match?(%SchemaDefinition{}, &1))

      asset = Enum.find(schemas, &(&1.name == "mediaAsset"))
      collection = Enum.find(schemas, &(&1.name == "mediaCollection"))

      assert asset.title == "Media Asset"
      assert asset.visibility == "private"
      assert length(asset.desk_groups) >= 4

      assert collection.title == "Media Collection"
      assert Enum.any?(collection.fields, &(&1["name"] == "parent"))
    end
  end
end
