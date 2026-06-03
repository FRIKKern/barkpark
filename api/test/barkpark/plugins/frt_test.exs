defmodule Barkpark.Plugins.FrtTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Frt

  describe "manifest/0" do
    test "returns the validated plugin.json map" do
      manifest = Frt.manifest()

      assert is_map(manifest)
      assert manifest["plugin_name"] == "frt"
      assert manifest["module"] == "Barkpark.Plugins.Frt"
      assert is_list(manifest["capabilities"])
      assert "schemas" in manifest["capabilities"]
    end
  end

  describe "plugin_name/0 (D20 discriminator)" do
    test "is the literal string 'frt'" do
      assert Frt.plugin_name() == "frt"
    end
  end

  describe "register_schemas/1" do
    setup do
      {:ok, schemas: Frt.register_schemas([])}
    end

    test "returns the 25 parsed schema definitions", %{schemas: schemas} do
      assert length(schemas) == 25
    end

    test "each entry is a %SchemaDefinition{} (the persisted, raw-backed shape)",
         %{schemas: schemas} do
      assert Enum.all?(schemas, &match?(%SchemaDefinition{}, &1))
    end

    test "carries the expected game type names", %{schemas: schemas} do
      names = Enum.map(schemas, & &1.name)

      for expected <- ~w(enemyType gameClock coordinatorLoop) do
        assert expected in names, "expected schema name `#{expected}` to be registered"
      end
    end

    test "all 25 registered schemas are private", %{schemas: schemas} do
      assert Enum.all?(schemas, &(&1.visibility == "private"))
    end
  end

  describe "desk_items/1" do
    setup do
      {:ok, groups: Frt.desk_items("frt")}
    end

    test "returns 8 :nested groups", %{groups: groups} do
      assert length(groups) == 8
      assert Enum.all?(groups, &(&1.type == :nested))
    end

    test "the 8 group labels follow coordinator.gd tick order", %{groups: groups} do
      assert Enum.map(groups, & &1.label) == [
               "① Frame & Time",
               "② Player",
               "③ Combat",
               "④ Enemies",
               "⑤ The Run",
               "⑥ Progression",
               "⑦ Game Feel",
               "⑧ World"
             ]
    end
  end

  describe "Barkpark.Plugin contract" do
    test "module declares the Barkpark.Plugin behaviour" do
      behaviours =
        :attributes
        |> Frt.module_info()
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Barkpark.Plugin in behaviours
    end
  end
end
