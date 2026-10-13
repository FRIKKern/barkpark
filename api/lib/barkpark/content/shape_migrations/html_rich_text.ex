defmodule Barkpark.Content.ShapeMigrations.HtmlRichText do
  @moduledoc """
  Census and convert for plain `richText` values stored as an HTML string
  (owner ruling #44, task-db56e998e0a5ab3b). Dry run by default; never runs
  on its own.

  Portable Text blocks are canonical. Studio Classic stored the
  contenteditable's HTML until #44. Studio still reads stored HTML and turns
  it into blocks the next time the document is saved
  (`Barkpark.Content.PortableText.from_html/1`). `run(apply: true)` converts
  the rest in one pass; the ruling chose next-save conversion, so applying it
  is an operator decision.

  Release form (on a box, no Mix):

      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.HtmlRichText.census())'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.HtmlRichText.run(), limit: :infinity)'
      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.HtmlRichText.run(apply: true))'

  Checkout form: `mix barkpark.shape.html_rich_text [--apply]`. Top-level
  plain `richText` fields only; the PortableDoc body region (`body`,
  `blocks`) and fields using the block editor are not part of #44.
  Plugin-owned types are skipped (`Barkpark.Content.CanonicalShapes`). An
  applied row gets new content and a new `_rev`, with no history revision or
  mutation event (`FieldScan`).
  """

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.ShapeMigrations.FieldScan

  @doc false
  def kind(f) do
    name = f["name"] || f[:name]

    if (f["type"] || f[:type]) == "richText" and is_binary(name) and
         name not in ["body", "blocks"] and
         not Barkpark.PortableDoc.FieldVocabulary.blocks_field?(stringify(f)),
       do: :html
  end

  defp stringify(f), do: Map.new(f, fn {k, v} -> {to_string(k), v} end)

  defp rewrite(:html, value) when is_binary(value) do
    if String.trim(value) == "", do: :keep, else: {:rewrite, PortableText.from_html(value)}
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

  @doc "Documents holding an HTML-string value, per `{type, field}`."
  @spec census() :: [%{type: String.t(), field: String.t(), documents: pos_integer()}]
  def census, do: FieldScan.census_of(dry_run())
end
