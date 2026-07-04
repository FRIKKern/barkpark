defmodule BarkparkWeb.Components.Fields.Visibility do
  @moduledoc """
  Studio-facing entry point for `visibleWhen` field-visibility evaluation.

  The predicate logic itself is sealed in `Barkpark.Content.FieldVisibility`
  (the single source of truth shared with `Barkpark.Content.CrossValidator`) —
  this module is the thin web-layer alias the field renderers call, so the
  editor and cross-validation can never disagree on operator semantics.

  Schema declaration shape (book.json):

      {
        "name": "audienceRanges",
        "type": "arrayOf",
        ...,
        "visibleWhen": {
          "field": "audienceCodes",
          "operator": "non_empty"
        }
      }

  Supported operators: `eq`, `neq`, `in`, `empty`, `non_empty`, `starts_with`.
  See `Barkpark.Content.FieldVisibility` for the full path-walking and operator
  contract.
  """

  @doc """
  Returns `true` when `field` should render given the current document
  state, `false` otherwise. Delegates to `Barkpark.Content.FieldVisibility`.
  """
  defdelegate visible?(field, doc), to: Barkpark.Content.FieldVisibility
end
