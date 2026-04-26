defmodule Barkpark.Plugins.OnixEdit.Schemas do
  @moduledoc """
  Index of OnixEdit sub-schemas and field-shape modules (Phase 4 WI2).

  This is the namespace boundary owned by WI2. The top-level
  `Barkpark.Plugins.OnixEdit` module (WI1) carries the `book` schema and
  the plugin-wide codelist contract; this module aggregates the v2
  nested shapes WI2 fills in:

    * `Contributor`            — `arrayOf` ordered: true, items:composite
    * `TextContent`            — composite item under
      `collateralDetail.textContents` (arrayOf), localizedText `text`
    * `ThemaSubjectCategory`   — single codelist field pointing at list 93

  ## Integration handshake

  The integration branch wires these into the WI1 book schema by
  splicing each module's `definition_map/0` into the appropriate WI1
  surface point. Until that splice happens (or until WI1 inlines the
  shapes directly), each sub-schema is independently parseable through
  `Barkpark.Content.SchemaDefinition.parse/2` so it can be tested in
  isolation. See `schemas_test.exs` for the round-trip proof.
  """

  alias Barkpark.Plugins.OnixEdit.Schemas.{Contributor, TextContent, ThemaSubjectCategory}

  @plugin_name "onixedit"

  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  Returns every sub-schema module owned by WI2.
  """
  @spec all() :: [module()]
  def all, do: [Contributor, TextContent, ThemaSubjectCategory]

  @doc """
  Aggregated codelist references across every WI2 sub-schema.

  Each entry is a `(plugin_name, list_id, issue)` triple. Tests assert
  the manifest declares specific lists; data seeding is WI3's job.
  """
  @spec codelist_refs() :: [%{plugin_name: String.t(), list_id: String.t(), issue: integer()}]
  def codelist_refs do
    all()
    |> Enum.flat_map(& &1.codelist_refs())
    |> Enum.uniq()
  end
end
