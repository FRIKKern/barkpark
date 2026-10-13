defmodule Barkpark.Groq.Source do
  @moduledoc """
  Where `Barkpark.Groq.Evaluator` gets documents from.

  A source is a `{module, state}` pair. `fetch/2` answers `*` filtered by the
  constraints `Barkpark.Groq.Pushdown` read off the query: it may return a
  superset (the evaluator applies the full filter afterwards) but never drop a
  matching document, and it returns documents ordered by `_id`. `get/2`
  resolves one `->` dereference.
  """

  @type t :: {module(), term()}

  @callback fetch(state :: term(), constraints :: map()) :: [map()]
  @callback get(state :: term(), id :: String.t()) :: map() | nil

  @spec fetch(t(), map()) :: [map()]
  def fetch({mod, state}, constraints), do: mod.fetch(state, constraints)

  @spec get(t(), String.t()) :: map() | nil
  def get({mod, state}, id), do: mod.get(state, id)
end
