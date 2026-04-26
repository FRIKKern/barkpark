defmodule Barkpark.Plugins.OnixEdit.Schemas.ThemaSubjectCategory do
  @moduledoc """
  Thema subject category codelist field (Phase 4 WI2).

  Thema is ONIX codelist 93 — a hierarchical (~3000-node) subject scheme
  maintained by EDItEUR. The book schema's `subject.themaSubjectCategory`
  field is a single `codelist` reference pointing at the registry
  (`Barkpark.Content.Codelists`).

  This module exposes only the field DEFINITION map; the registry data
  is WI3's bring-your-own-snapshot import (D21). The module exists for
  symmetry with the contributor / text-content sub-schemas and to give
  the integration layer a stable handle to splice the field shape into
  the book schema.

  Codelist reference declared:

    * `onixedit:thema` — ONIX list 93 (D17 pinned)
  """

  @plugin_name "onixedit"

  @field_definition %{
    "name" => "themaSubjectCategory",
    "title" => "Thema subject category",
    "type" => "codelist",
    "codelistId" => "onixedit:thema",
    "version" => 73,
    "onix" => %{"element" => "SubjectCode", "codelistId" => 93}
  }

  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc "Field definition map for the themaSubjectCategory codelist field."
  @spec definition_map() :: map()
  def definition_map, do: @field_definition

  @spec codelist_refs() :: [%{plugin_name: String.t(), list_id: String.t(), issue: integer()}]
  def codelist_refs do
    [%{plugin_name: @plugin_name, list_id: "onixedit:thema", issue: 73}]
  end
end
