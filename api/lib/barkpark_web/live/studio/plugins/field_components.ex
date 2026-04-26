defmodule BarkparkWeb.Studio.Plugins.FieldComponents do
  @moduledoc """
  Phoenix Components for v2 plugin field types in the Studio editor.

  Each function delegates to the matching Phase 0 component under
  `BarkparkWeb.Components.Fields.*`. This namespace exists to give the Studio
  adapter (`BarkparkWeb.Studio.Plugins.Adapter`) a single import surface and
  to make it easy to swap or specialize a component without touching the
  Phase 0 base implementations (which are also called by their own tests).

  The Thema (codelist 93) tree picker is deliberately **not** implemented
  here — Phase 0's `CodelistField` flattens hierarchies to leaves with
  breadcrumb labels, and Phase 5 (Task #9) is responsible for the polished
  tree UI. The component below ensures the adapter slot exists.
  """

  use Phoenix.Component

  alias BarkparkWeb.Components.Fields.{
    ArrayField,
    CodelistField,
    CompositeField,
    LocalizedTextField
  }

  attr :field, :map, required: true
  attr :value, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""

  @doc "Render a v2 `composite` field (recursive object with named subfields)."
  def composite(assigns), do: CompositeField.composite_field(assigns)

  attr :field, :map, required: true
  attr :value, :list, default: []
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :on_reorder, :string, default: "array_op"
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""

  @doc "Render a v2 `arrayOf` field (ordered/unordered list with add/remove)."
  def array_of(assigns), do: ArrayField.array_field(assigns)

  attr :field, :map, required: true
  attr :value, :string, default: nil
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""
  attr :codelist_loader, :any, default: nil

  @doc """
  Render a v2 `codelist` field. For hierarchical codelists (e.g. Thema 93)
  Phase 0's component falls back to a flat select over leaves with breadcrumb
  labels — Phase 5 ships the tree picker that replaces this slot.
  """
  def codelist(assigns), do: CodelistField.codelist_field(assigns)

  attr :field, :map, required: true
  attr :value, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :path, :string, default: ""

  @doc "Render a v2 `localizedText` field (multi-language text with fallback chain)."
  def localized_text(assigns), do: LocalizedTextField.localized_text_field(assigns)
end
