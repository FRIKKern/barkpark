defmodule Barkpark.Content.ShapeMigrations.StringSlugs do
  @moduledoc """
  Census and convert for slugs stored as a plain string (owner ruling #43,
  task-26394ff887df3261). Dry run by default; never runs on its own.

  `{"_type": "slug", "current": text}` is canonical. Studio wrote a plain
  string until #43. Readers still accept it (`Barkpark.Content.SlugValue.text/1`,
  the starters' `slugOf`), and Studio rewrites a document's slug the next time
  it is saved. `run(apply: true)` converts the rest in one pass; the ruling
  chose next-save conversion, so applying it is an operator decision.

  Release form (on a box, no Mix):

      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.StringSlugs.census())'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.StringSlugs.run(), limit: :infinity)'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.StringSlugs.run(apply: true))'

  Checkout form: `mix barkpark.shape.string_slugs [--apply]`. Top-level `slug`
  fields only, read from the schema that governs each document
  (`FieldScan.governing_schema/2`). Plugin-owned types are skipped: Studio
  keeps their slugs as stored (`Barkpark.Content.CanonicalShapes`). An applied row gets new content and a new
  `_rev`, with no history revision or mutation event (`FieldScan`).
  """

  alias Barkpark.Content.ShapeMigrations.FieldScan
  alias Barkpark.Content.SlugValue

  @doc false
  def kind(f), do: if((f["type"] || f[:type]) == "slug", do: :slug)

  defp rewrite(:slug, value) when is_binary(value) and value != "",
    do: {:rewrite, SlugValue.canonical(value)}

  defp rewrite(_kind, _value), do: :keep

  @doc """
  Options: `apply:` (default `false`). Returns `%{scanned, changed, applied?,
  rows}`; each row is `%{doc_id, type, field, from, to}`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []), do: FieldScan.convert(&kind/1, &rewrite/2, opts)

  @doc "What `run(apply: true)` would write, row by row. Nothing is written."
  def dry_run, do: run().rows

  @doc "Documents holding a plain-string slug, per `{type, field}`."
  @spec census() :: [%{type: String.t(), field: String.t(), documents: pos_integer()}]
  def census, do: FieldScan.census_of(dry_run())
end
