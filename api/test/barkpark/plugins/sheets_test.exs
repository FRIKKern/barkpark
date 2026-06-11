defmodule Barkpark.Plugins.SheetsTest do
  @moduledoc """
  Pre-flight assertions for the Sheets plugin skeleton.

  Two invariants:

    1. Idempotent schema registration — `register_schemas/1` returns a
       `%SchemaDefinition{}` list and two successive calls produce the same
       schema name and field count.

    2. Fresh-install invariant — with `:plugins` set to `[]` (the kill
       switch), the plugin registration path that Bootstrap walks
       (`Registry.collect_workers/1`, `Registry.collect_routes/1`) returns
       empty results, mirroring how `registry_test.exs` tests the kill
       switch for routes. This mirrors the pattern in
       `Barkpark.Plugins.RegistryTest` "returns [] when :plugins is
       explicitly empty".
  """

  # RegistryCase resets the Registry GenServer + :persistent_term snapshot
  # after every test and deletes the :barkpark, :plugins env. The Registry is
  # a singleton — async: false is required.
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Sheets

  describe "register_schemas/1 — shape contract" do
    test "returns a non-empty list of SchemaDefinition structs" do
      result = Sheets.register_schemas([])

      assert is_list(result)
      assert Enum.count(result) >= 1
    end

    test "the first entry is a SchemaDefinition for type 'sheet'" do
      [schema | _] = Sheets.register_schemas([])

      assert %SchemaDefinition{} = schema
      assert schema.name == "sheet"
    end

    test "title, icon, visibility and fields are populated" do
      [schema | _] = Sheets.register_schemas([])

      assert is_binary(schema.title)
      assert schema.title != ""
      assert is_binary(schema.icon)
      assert schema.visibility in ["public", "private"]
      assert is_list(schema.fields)
      assert Enum.count(schema.fields) >= 1
    end

    test "register_schemas/1 is idempotent — second call returns same name and field count" do
      [s1 | _] = Sheets.register_schemas([])
      [s2 | _] = Sheets.register_schemas([])

      assert s1.name == s2.name
      assert length(s1.fields) == length(s2.fields)
    end

    test "sheet schema declares a 'tabs' field" do
      [schema | _] = Sheets.register_schemas([])

      field_names = Enum.map(schema.fields, & &1["name"])

      assert "tabs" in field_names,
             "expected 'tabs' field in sheet schema, got: #{inspect(field_names)}"
    end
  end

  describe "fresh-install invariant — sheets plugin disabled via kill switch" do
    # Mirror the pattern from registry_test.exs describe "collect_routes/1":
    # set :plugins to [] before calling the registry path, restore on exit.
    setup do
      prev = Application.get_env(:barkpark, :plugins, :unset)

      on_exit(fn ->
        case prev do
          :unset -> Application.delete_env(:barkpark, :plugins)
          v -> Application.put_env(:barkpark, :plugins, v)
        end
      end)

      :ok
    end

    test "with :plugins=[], collect_routes/1 returns [] (sheets has no routes yet, kill switch respected)" do
      Application.put_env(:barkpark, :plugins, [])

      assert Registry.collect_routes(%{}) == [],
             "expected collect_routes to return [] when :plugins kill switch is active"
    end

    test "with :plugins=[], collect_workers/1 returns [] (sheets has no workers, kill switch respected)" do
      Application.put_env(:barkpark, :plugins, [])

      assert Registry.collect_workers(%{}) == [],
             "expected collect_workers to return [] when :plugins kill switch is active"
    end

    test "manifest declares the sheets plugin name for whitelist discovery" do
      # Assert that the manifest embedded in the compiled module module carries
      # the right plugin_name — this is the token the whitelist match uses.
      manifest = Barkpark.Plugins.Sheets.manifest()

      assert manifest["plugin_name"] == "sheets",
             "expected plugin_name 'sheets' in manifest, got: #{inspect(manifest["plugin_name"])}"

      assert manifest["capabilities"] == ["schemas"],
             "expected capabilities ['schemas'] in manifest (no routes yet)"
    end
  end
end
