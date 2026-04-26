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
  @json_path Path.expand(
               "../../../../../priv/plugins/onixedit/schemas/text_content.json",
               __DIR__
             )

  @external_resource @json_path

  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @spec json_path() :: String.t()
  def json_path, do: @json_path

  @doc "Raw decoded sub-schema map, ready to splice into book.json."
  @spec definition_map() :: map()
  def definition_map do
    @json_path
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
