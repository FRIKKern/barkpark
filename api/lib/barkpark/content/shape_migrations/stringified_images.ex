defmodule Barkpark.Content.ShapeMigrations.StringifiedImages do
  @moduledoc """
  Census and repair for image fields stored as a JSON STRING
  (task-b44972b2869fb54a). Dry run by default; never runs on its own.

  Until #21861 a Beta edit of an image field stored the picker's value as a
  string holding `{url, assetId, alt, ...}` instead of that map, so every
  reader got the wrong shape. The map is what Classic always stored and what
  readers expect. A Classic save, or a Beta image edit after #21861, heals one
  document; `run(apply: true)` repairs the rest in one pass. It is a repair,
  not a move to a new shape, so it does not wait on `:canonical_shape_writes`.

  Release form (on a box, no Mix):

      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.StringifiedImages.census())'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.StringifiedImages.run(), limit: :infinity)'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.StringifiedImages.run(apply: true))'

  Checkout form: `mix barkpark.shape.stringified_images [--apply]`. Top-level
  `image` fields only, read from the schema that governs each document
  (`FieldScan.governing_schema/2`); plugin-owned types are skipped. The decode
  is the block-op save path's own (`Projection.decode_image_value/1`): only a
  string holding a JSON object changes. An applied row gets new content and a
  new `_rev`, with no history revision or mutation event (`FieldScan`).
  """

  alias Barkpark.Content.ShapeMigrations.FieldScan
  alias Barkpark.PortableDoc.Projection

  @doc false
  def kind(f), do: if((f["type"] || f[:type]) == "image", do: :image)

  defp rewrite(:image, value) when is_binary(value) do
    case Projection.decode_image_value(value) do
      %{} = map -> {:rewrite, map}
      _ -> :keep
    end
  end

  defp rewrite(_kind, _value), do: :keep

  @doc """
  Options: `apply:` (default `false`). Returns `%{scanned, changed, applied?,
  rows}`; each row is `%{doc_id, type, field, from, to}`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []),
    do: FieldScan.convert(&kind/1, &rewrite/2, Keyword.put(opts, :canonical_gate, false))

  @doc "What `run(apply: true)` would write, row by row. Nothing is written."
  def dry_run, do: run().rows

  @doc "Documents holding a stringified image, per `{type, field}`."
  @spec census() :: [%{type: String.t(), field: String.t(), documents: pos_integer()}]
  def census, do: FieldScan.census_of(dry_run())
end
