defmodule Barkpark.Plugins.OnixEdit.Schemas.Contributor do
  @moduledoc """
  Contributor sub-schema (Phase 4 WI2).

  Owns the inner shape of a single entry inside `book.contributors`
  (`arrayOf` ordered: true). The schema declaration lives in JSON at
  `priv/plugins/onixedit/schemas/contributor.json` and is parsed at
  runtime via `Barkpark.Content.SchemaDefinition.parse/2` (no `Code.eval` —
  Decision D7).

  Codelist references declared by this module:

    * `onixedit:contributor_role` — ONIX list 17 (D17 pinned)
    * `onixedit:language_code`    — ONIX list 74
    * `onixedit:name_type`        — ONIX list 18
    * `onixedit:name_id_type`     — ONIX list 44

  Per D21 (BYO snapshot), no codelist data is bundled here. WI3 owns
  registry seeding via `mix barkpark.codelists.import`.

  ## Integration with the book schema

  The book schema (`priv/plugins/onixedit/schemas/book.json`, owned by WI1)
  carries a `contributors` `arrayOf` with `ordered: true`. Integration
  inlines this sub-schema as the array's `of` composite — the
  `definition_map/0` helper exposes the raw map for that splice.
  """

  alias Barkpark.Content.SchemaDefinition

  @plugin_name "onixedit"
  @json_path Path.expand(
               "../../../../../priv/plugins/onixedit/schemas/contributor.json",
               __DIR__
             )

  @external_resource @json_path

  @doc "Plugin discriminator (D20) — every codelist ref under this module uses it."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "Absolute path to the JSON sub-schema file. Useful for diagnostics."
  @spec json_path() :: String.t()
  def json_path, do: @json_path

  @doc """
  Returns the raw decoded sub-schema map, suitable for splicing into the
  book schema's `contributors[item]` composite.
  """
  @spec definition_map() :: map()
  def definition_map do
    @json_path
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Returns the parsed `%SchemaDefinition.Parsed{}` for this sub-schema.

  Raises if the JSON file is missing or fails v2 parsing — we want loud
  failures in dev/test rather than silent corruption at request time.
  """
  @spec parsed!() :: SchemaDefinition.Parsed.t()
  def parsed! do
    case definition_map() |> SchemaDefinition.parse(plugin: @plugin_name) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise "Contributor sub-schema failed to parse: #{inspect(reason)}"
    end
  end

  @doc """
  Codelist references declared by this sub-schema.

  Each entry is a `(plugin_name, list_id, issue)` triple — the contract
  WI3's importer reads to know which lists must be available before the
  book schema can validate semantically. Test surface: assert the
  manifest declares specific lists (data seeding is WI3's problem).
  """
  @spec codelist_refs() :: [%{plugin_name: String.t(), list_id: String.t(), issue: integer()}]
  def codelist_refs do
    [
      %{plugin_name: @plugin_name, list_id: "onixedit:contributor_role", issue: 73},
      %{plugin_name: @plugin_name, list_id: "onixedit:language_code", issue: 73},
      %{plugin_name: @plugin_name, list_id: "onixedit:name_type", issue: 73},
      %{plugin_name: @plugin_name, list_id: "onixedit:name_id_type", issue: 73}
    ]
  end
end
