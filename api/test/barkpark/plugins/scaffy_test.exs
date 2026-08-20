defmodule Barkpark.Plugins.ScaffyTest do
  @moduledoc """
  Contract on `Barkpark.Plugins.Scaffy` (charter D44–D46, `scaffy` epic W4).
  The manifest parses and declares `schemas`-only; `register_schemas/1` returns
  the `command` SchemaDefinition with public visibility, the `production`
  dataset, and the verbatim-`source` + label-spine field set. Pure — no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Scaffy

  describe "manifest/0" do
    test "parses and declares the schemas-only capability" do
      manifest = Scaffy.manifest()

      assert manifest["plugin_name"] == "scaffy"
      assert manifest["module"] == "Barkpark.Plugins.Scaffy"
      assert manifest["capabilities"] == ["schemas"]
      # zero routes / workers — schemas-only (D44)
      refute "routes" in manifest["capabilities"]
      refute "workers" in manifest["capabilities"]

      assert [%{"name" => "command", "file" => "schemas/command.json"}] =
               manifest["schemas"]
    end
  end

  describe "register_schemas/1" do
    setup do
      assert [%SchemaDefinition{} = def] = Scaffy.register_schemas([])
      {:ok, def: def, fields_by_name: Map.new(def.fields, &{&1["name"], &1})}
    end

    test "declares the command type, public, on the production dataset", %{def: def} do
      assert def.name == "command"
      assert def.title == "Commands"
      assert def.visibility == "public"
      assert def.dataset == "production"
    end

    test "carries the source + label-spine field set", %{fields_by_name: fields} do
      for name <- ~w(title source description concept variant domain direction tags) do
        assert Map.has_key?(fields, name), "expected a #{name} field"
      end
    end

    test "stores the .scaffy source verbatim in one `source`-typed field", %{
      fields_by_name: fields
    } do
      # D45: the .scaffy bytes ride ONE content string field of the new
      # `source` type — never `text` (editable, form-submitted) and never a
      # lossy block decomposition.
      assert fields["source"]["type"] == "source"
    end

    test "label-spine metadata is queryable plain strings", %{fields_by_name: fields} do
      for name <- ~w(concept variant domain direction) do
        assert fields[name]["type"] == "string"
      end
    end

    test "tags are weighted composites {tag,strength,rationale}", %{fields_by_name: fields} do
      tags = fields["tags"]
      assert tags["type"] == "arrayOf"
      assert tags["of"]["type"] == "composite"

      composite_names = Enum.map(tags["of"]["fields"], & &1["name"])
      assert "tag" in composite_names
      assert "strength" in composite_names
      assert "rationale" in composite_names
    end
  end
end
