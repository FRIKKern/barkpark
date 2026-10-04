defmodule Barkpark.Content.ShapeMigrations.BareReferences do
  @moduledoc """
  Census and convert for references stored as a bare id (owner ruling #42,
  task-fcb752b43e11df9b). Dry run by default; never runs on its own.

  `{"_ref": id, "_type": "reference"}` is the canonical reference shape.
  Studio wrote bare ids until #42. Readers still accept them
  (`Barkpark.Content.Edges.reference_target/1`, Studio, `?expand`, the
  starters' `refOf`), and Studio rewrites a document's bare ids the next time
  it is saved. `run(apply: true)` converts the rest in one pass; the ruling
  chose next-save conversion, so applying it is an operator decision.

  Release form (on a box, no Mix):

      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.BareReferences.census())'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.BareReferences.run(), limit: :infinity)'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.BareReferences.run(apply: true))'

  Checkout form: `mix barkpark.shape.bare_references [--apply]`.

  Scanned: top-level `reference` fields and `arrayOf`/`array` fields whose
  members are references, read from the schema that governs each document
  (`FieldScan.governing_schema/2`). An applied row gets new content and a new
  `_rev`, with no history revision or mutation event (`FieldScan`).
  """

  alias Barkpark.Content.ShapeMigrations.FieldScan

  @doc false
  def kind(f) do
    case {f["type"] || f[:type], f["of"] || f[:of]} do
      {"reference", _} -> :single
      {t, %{} = of} when t in ["arrayOf", "array"] -> if ref?(of), do: :list
      {t, [_ | _] = ofs} when t in ["arrayOf", "array"] -> if Enum.all?(ofs, &ref?/1), do: :list
      _ -> nil
    end
  end

  defp ref?(%{} = d), do: (d["type"] || d[:type]) == "reference"
  defp ref?(_), do: false

  @doc "The canonical shape of one stored reference value; anything else is returned unchanged."
  def canonical(id) when is_binary(id) and id != "", do: %{"_ref" => id, "_type" => "reference"}
  def canonical(other), do: other

  defp rewrite(:single, value) when is_binary(value) and value != "",
    do: {:rewrite, canonical(value)}

  defp rewrite(:list, list) when is_list(list) do
    if Enum.any?(list, &(is_binary(&1) and &1 != "")),
      do: {:rewrite, Enum.map(list, &canonical/1)},
      else: :keep
  end

  defp rewrite(_kind, _value), do: :keep

  @doc """
  Options: `apply:` (default `false`). Returns `%{scanned, changed, applied?,
  rows}`; each row is `%{doc_id, type, field, from, to}`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []), do: FieldScan.convert(&kind/1, &rewrite/2, opts)

  @doc "What `run(apply: true)` would write, row by row. Nothing is written."
  def dry_run, do: run().rows

  @doc "Documents holding at least one bare-id reference, per `{type, field}`."
  @spec census() :: [%{type: String.t(), field: String.t(), documents: pos_integer()}]
  def census, do: FieldScan.census_of(dry_run())
end
