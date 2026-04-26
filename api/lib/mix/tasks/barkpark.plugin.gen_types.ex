defmodule Mix.Tasks.Barkpark.Plugin.GenTypes do
  @moduledoc """
  Regenerate `priv/plugin_types.d.ts` from `priv/plugin_manifest_schema.json`.

  Workflow:
  1. Reads the JSON Schema.
  2. If `npx` is available, shells out to
     `npx --yes json-schema-to-typescript@^15` to produce the `.d.ts`.
  3. Otherwise, leaves the existing hand-written `.d.ts` in place and
     prints a notice.

  The hand-written `.d.ts` committed in this repo is the source of truth
  for downstream consumers until WI4 wires Node into CI.
  """
  @shortdoc "Regenerate plugin_types.d.ts from the manifest JSON Schema"

  use Mix.Task

  @schema_rel_path "priv/plugin_manifest_schema.json"
  @types_rel_path "priv/plugin_types.d.ts"

  @impl Mix.Task
  def run(_args) do
    schema_path = Path.expand(@schema_rel_path)
    types_path = Path.expand(@types_rel_path)

    unless File.exists?(schema_path) do
      Mix.raise("schema not found at #{schema_path}")
    end

    case System.find_executable("npx") do
      nil ->
        Mix.shell().info(
          "npx not found — leaving hand-written #{@types_rel_path} unchanged. " <>
            "Install Node.js to enable regeneration."
        )

        :ok

      npx ->
        regenerate(npx, schema_path, types_path)
    end
  end

  defp regenerate(npx, schema_path, types_path) do
    Mix.shell().info("regenerating #{@types_rel_path} via json-schema-to-typescript…")

    args = [
      "--yes",
      "json-schema-to-typescript@^15",
      "--input",
      schema_path,
      "--no-additionalProperties"
    ]

    case System.cmd(npx, args, stderr_to_stdout: true) do
      {output, 0} ->
        header = """
        // AUTO-GENERATED — do not edit. Regenerate with: mix barkpark.plugin.gen_types
        //
        // Source of truth: api/priv/plugin_manifest_schema.json

        """

        File.write!(types_path, header <> output)
        Mix.shell().info("wrote #{types_path}")
        :ok

      {output, code} ->
        Mix.shell().error(output)
        Mix.raise("json-schema-to-typescript failed with exit #{code}")
    end
  end
end
