defmodule Barkpark.Plugins.OnixEdit.Schemas.TextContent do
  @moduledoc """
  TextContent sub-schema (Phase 4 WI2).

  Owns the inner shape of a single entry inside
  `book.collateralDetail.textContents` (`arrayOf`). The semantic carrier
  is the `text` `localizedText` blurb with a Norwegian-first
  `fallbackChain`. The schema declaration lives in JSON at
  `priv/plugins/onixedit/schemas/text_content.json` and is parsed at
  runtime via `Barkpark.Content.SchemaDefinition.parse/2` (no
  `Code.eval` — Decision D7).

  Codelist references declared by this module:

    * `onixedit:text_type`        — ONIX list 153
    * `onixedit:content_audience` — ONIX list 154
    * `onixedit:text_format`      — ONIX list 34
  """

  alias Barkpark.Content.SchemaDefinition

  @plugin_name "onixedit"
  # Resolved at RUNTIME. `Application.app_dir/2` finds priv inside an OTP
  # release (lib/barkpark-<vsn>/priv) as well as in the source-tree deploy
  # model. The previous `Path.expand(..., __DIR__)` attribute froze the BUILD
  # machine's path, so `definition_map/0` — called at runtime from
  # `fetch_subschema_fields/1` — raised File.Error enoent in every release.
  @json_subpath "priv/plugins/onixedit/schemas/text_content.json"

  # Kept so edits to the JSON still recompile this module.
  @external_resource Path.expand(
                       "../../../../../priv/plugins/onixedit/schemas/text_content.json",
                       __DIR__
                     )

  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @spec json_path() :: String.t()
  def json_path, do: Application.app_dir(:barkpark, @json_subpath)

  @doc "Raw decoded sub-schema map, ready to splice into book.json."
  @spec definition_map() :: map()
  def definition_map do
    json_path()
    |> File.read!()
    |> Jason.decode!()
  end

  @spec parsed!() :: SchemaDefinition.Parsed.t()
  def parsed! do
    case definition_map() |> SchemaDefinition.parse(plugin: @plugin_name) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise "TextContent sub-schema failed to parse: #{inspect(reason)}"
    end
  end

  @spec codelist_refs() :: [%{plugin_name: String.t(), list_id: String.t(), issue: integer()}]
  def codelist_refs do
    [
      %{plugin_name: @plugin_name, list_id: "onixedit:text_type", issue: 73},
      %{plugin_name: @plugin_name, list_id: "onixedit:content_audience", issue: 73},
      %{plugin_name: @plugin_name, list_id: "onixedit:text_format", issue: 73}
    ]
  end
end
