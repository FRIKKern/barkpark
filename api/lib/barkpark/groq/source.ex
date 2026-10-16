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

  @doc """
  Optional. The number of documents that `constraints` match, which the caller
  guarantees match exactly (`Barkpark.Groq.Pushdown.exact/2`). `:error` when
  the source cannot count without loading; the evaluator then loads.
  """
  @callback count(state :: term(), constraints :: map()) :: {:ok, non_neg_integer()} | :error

  @doc """
  Optional. The number of documents among those `constraints` narrow to for
  which `keep?` returns true, read in chunks so that no more than one chunk is
  held at a time. `cache` is a term naming the filter when its result does not
  depend on the enclosing scope, or nil. `:error` when the source cannot scan;
  the evaluator then loads.
  """
  @callback scan_count(
              state :: term(),
              constraints :: map(),
              cache :: term(),
              keep? :: (map() -> boolean())
            ) :: {:ok, non_neg_integer()} | :error

  @doc """
  Optional. Documents `from` up to `to` (exclusive) of those `constraints`
  match, which the caller guarantees match exactly. `keys` are
  `Barkpark.Groq.Pushdown.order_keys/1` sort keys; with none, the documents
  come in `_id` order, as `fetch/2` returns them. `:error` when the source
  cannot answer without loading; the evaluator then loads.
  """
  @callback slice(
              state :: term(),
              constraints :: map(),
              keys :: list(),
              from :: non_neg_integer(),
              to :: non_neg_integer()
            ) :: {:ok, [map()]} | :error

  @doc """
  Optional. The first `take` documents among those `constraints` narrow to
  for which `keep?` returns true, read in chunks. With `rank` nil they are the
  first in `_id` order and the read stops once it has them. Otherwise `rank`
  sorts a list of documents and the read keeps the first `take` it ranks.
  `cache` names the slice; the source may keep its result for the query.
  `:error` when the source cannot scan; the evaluator then loads.
  """
  @callback scan_slice(
              state :: term(),
              constraints :: map(),
              cache :: term(),
              keep? :: (map() -> boolean()),
              rank :: ([map()] -> [map()]) | nil,
              take :: pos_integer()
            ) :: {:ok, [map()]} | :error

  @doc """
  Optional. Every document `constraints` match, which the caller guarantees
  match exactly, in `_id` order as `fetch/2` returns them. The evaluator keeps
  them all without testing the filter again. With `fields` a list of
  top-level keys, a document need hold only those keys and the system fields;
  the caller reads no other key. `:error` when the source cannot answer
  without loading; the evaluator then fetches and filters.
  """
  @callback fetch_exact(state :: term(), constraints :: map(), fields :: [String.t()] | :all) ::
              {:ok, [map()]} | :error

  @optional_callbacks count: 2, scan_count: 4, slice: 5, scan_slice: 6, fetch_exact: 3

  @spec fetch(t(), map()) :: [map()]
  def fetch({mod, state}, constraints), do: mod.fetch(state, constraints)

  @spec count(t(), map()) :: {:ok, non_neg_integer()} | :error
  def count({mod, state}, constraints) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :count, 2),
      do: mod.count(state, constraints),
      else: :error
  end

  @spec scan_count(t(), map(), term(), (map() -> boolean())) ::
          {:ok, non_neg_integer()} | :error
  def scan_count({mod, state}, constraints, cache, keep?) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :scan_count, 4),
      do: mod.scan_count(state, constraints, cache, keep?),
      else: :error
  end

  @spec slice(t(), map(), list(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [map()]} | :error
  def slice({mod, state}, constraints, keys, from, to) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :slice, 5),
      do: mod.slice(state, constraints, keys, from, to),
      else: :error
  end

  @spec scan_slice(
          t(),
          map(),
          term(),
          (map() -> boolean()),
          ([map()] -> [map()]) | nil,
          pos_integer()
        ) :: {:ok, [map()]} | :error
  def scan_slice({mod, state}, constraints, cache, keep?, rank, take) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :scan_slice, 6),
      do: mod.scan_slice(state, constraints, cache, keep?, rank, take),
      else: :error
  end

  @spec fetch_exact(t(), map(), [String.t()] | :all) :: {:ok, [map()]} | :error
  def fetch_exact({mod, state}, constraints, fields) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :fetch_exact, 3),
      do: mod.fetch_exact(state, constraints, fields),
      else: :error
  end

  @spec get(t(), String.t()) :: map() | nil
  def get({mod, state}, id), do: mod.get(state, id)
end
