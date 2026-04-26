defmodule Barkpark.Plugins.TypesTest do
  @moduledoc """
  Drift detection between `priv/plugin_manifest_schema.json` and
  the hand-written `priv/plugin_types.d.ts`.

  Walks both files to confirm every top-level schema property is named in
  the .d.ts. The .d.ts may legitimately introduce *more* names (helper
  interfaces like PluginCapability), but it must mention every property
  declared in the schema.
  """
  use ExUnit.Case, async: true

  @priv_dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv"]))
  @schema_path Path.join(@priv_dir, "plugin_manifest_schema.json")
  @types_path Path.join(@priv_dir, "plugin_types.d.ts")

  test "schema and .d.ts both exist" do
    assert File.exists?(@schema_path), "missing #{@schema_path}"
    assert File.exists?(@types_path), "missing #{@types_path}"
  end

  test ".d.ts header marks file as auto-generated" do
    contents = File.read!(@types_path)
    assert contents =~ "AUTO-GENERATED"
    assert contents =~ "mix barkpark.plugin.gen_types"
  end

  test ".d.ts mentions every top-level schema property" do
    schema = Jason.decode!(File.read!(@schema_path))
    types = File.read!(@types_path)

    property_names = Map.keys(schema["properties"])

    missing =
      Enum.reject(property_names, fn name ->
        # Each property name should appear at least once in the .d.ts
        # (as an interface field — the field name is the same string).
        String.contains?(types, name)
      end)

    assert missing == [],
           "fields declared in JSON Schema but missing from plugin_types.d.ts: " <>
             inspect(missing) <>
             "\nRegenerate with: mix barkpark.plugin.gen_types"
  end

  test ".d.ts mentions every capability enum value" do
    schema = Jason.decode!(File.read!(@schema_path))
    types = File.read!(@types_path)

    capability_values = schema["properties"]["capabilities"]["items"]["enum"]

    missing =
      Enum.reject(capability_values, fn val ->
        String.contains?(types, "\"#{val}\"")
      end)

    assert missing == [],
           "capability values declared in JSON Schema but missing from " <>
             "plugin_types.d.ts: #{inspect(missing)}"
  end

  @tag :requires_node
  test "tsc --noEmit accepts the .d.ts" do
    case System.find_executable("tsc") do
      nil ->
        # Node toolchain not installed — WI4 will wire CI to enforce this.
        # Locally skip rather than fail.
        :ok

      tsc ->
        {output, code} = System.cmd(tsc, ["--noEmit", @types_path], stderr_to_stdout: true)
        assert code == 0, "tsc rejected plugin_types.d.ts:\n#{output}"
    end
  end
end
