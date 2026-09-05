# pds-pre-gate-papers-predicate.exs — run the REAL publish gate predicate over a
# fetched corpus of published Papers and emit the refusal ledger.
#
# WHY THIS EXISTS
# ---------------
# Nothing re-gates a row that is already published. `Barkpark.Content.Lifecycle`
# runs its render-shape gate at the publish DOOR only, so a Paper published
# before the gate existed (or before its cell normalisation landed) keeps
# serving blocks the same gate would refuse today. Counting that population
# needs the gate's OWN code, not a re-implementation — a hand-written predicate
# that drifts from `BlockOps` would produce a number nobody can act on.
#
# THE PREDICATE IS THE SERVER'S, VERBATIM. Three calls, in the gate's order:
#
#   Barkpark.PortableDoc.Projection.read_blocks/1   (locate — reader precedence)
#   Barkpark.Content.Papers.BlockOps.normalize_render_shapes/1
#   Barkpark.Content.Papers.BlockOps.validate_render_shapes/1
#
# The one deliberate difference from `Lifecycle.prepare_paper_render_shapes/2`:
# that function has a prior arm for a DECLARED-but-non-list top-level "blocks"
# key. This script reproduces that arm explicitly (see :declared_non_list) so the
# count is the gate's verdict and not a subset of it.
#
# WHAT THIS SCRIPT STRUCTURALLY CANNOT SEE
# ----------------------------------------
# It reads the corpus it is HANDED. A field the fetch did not project is a field
# this script sees as absent, so the caller must fetch `blocks,body` — the two
# stored locations `read_blocks/1` reads. `--fields title` would report every
# paper as location:none and refuse nothing, silently. The caller
# (scripts/pds-pre-gate-papers-check.sh) prints the location census for exactly
# that reason: an all-`none` census means the instrument went blind, not that
# the corpus is clean.
#
# The fourth `read_blocks/1` clause — a markdown STRING body — is reported as
# location `markdown` and never refused, matching the gate: those blocks are
# synthesised at read time by `FromMarkdown` and never stored, so there is no
# authored shape to refuse.
#
# USAGE
#   MIX_ENV=test mix run --no-start ../scripts/pds-pre-gate-papers-predicate.exs \
#     <corpus.json> <out.json>
#
# corpus.json: a JSON array of {"_id": string, "content": object}
# out.json:    {"total", "by_location", "refused_count", "refused": [...]}

alias Barkpark.Content.Papers.BlockOps
alias Barkpark.PortableDoc.Projection

[corpus_path, out_path] =
  case System.argv() do
    [a, b] ->
      [a, b]

    other ->
      IO.puts(:stderr, "usage: <corpus.json> <out.json> (got #{inspect(other)})")
      System.halt(2)
  end

corpus =
  corpus_path
  |> File.read!()
  |> Jason.decode!()

# The STORED location the gate would read from, in `read_blocks/1` clause order.
# Mirrors `Lifecycle.paper_block_path/1`, plus the markdown clause it excludes.
location = fn content ->
  body = Map.get(content, "body")

  cond do
    is_list(Map.get(content, "blocks")) -> "blocks"
    is_map(body) and is_list(Map.get(body, "blocks")) -> "body.blocks"
    is_list(body) -> "body"
    is_binary(body) and String.trim(body) != "" -> "markdown"
    true -> "none"
  end
end

# One error string -> one class slug. Keyed on the validator's OWN message
# suffixes (block_ops.ex render_block_errors/2 + render_table_cell_errors/2), so
# a new refusal message lands in "other" and is VISIBLE rather than absorbed.
classify = fn error ->
  cond do
    String.contains?(error, ".cells[") and String.ends_with?(error, "has no renderable inline content") ->
      "table_cell_no_inline_content"

    String.contains?(error, ".items[") and String.ends_with?(error, "has no renderable inline content") ->
      "list_item_no_inline_content"

    String.ends_with?(error, "has no renderable cells") -> "table_row_not_cells"
    String.ends_with?(error, ".rows must be an array") -> "table_rows_not_array"
    String.ends_with?(error, ".items must be an array") -> "list_items_not_array"
    String.ends_with?(error, "must be list before the block reaches readers") -> "legacy_list_type"
    String.ends_with?(error, "must be an object") -> "block_not_object"
    String.contains?(error, "must be an array when a Paper declares") -> "blocks_declared_non_list"
    true -> "other"
  end
end

verdict = fn content ->
  cond do
    # The gate's FIRST arm: a declared-but-malformed top-level "blocks" keeps its
    # refusal even when a readable body list sits beside it.
    is_map_key(content, "blocks") and not is_list(content["blocks"]) ->
      BlockOps.validate_render_shapes(content["blocks"])

    true ->
      case Projection.read_blocks(content) do
        blocks when is_list(blocks) ->
          blocks
          |> BlockOps.normalize_render_shapes()
          |> BlockOps.validate_render_shapes()

        _ ->
          :ok
      end
  end
end

{refused, by_location} =
  Enum.reduce(corpus, {[], %{}}, fn row, {refused, by_location} ->
    id = Map.fetch!(row, "_id")
    content = Map.get(row, "content") || %{}
    loc = location.(content)
    by_location = Map.update(by_location, loc, 1, &(&1 + 1))

    case verdict.(content) do
      :ok ->
        {refused, by_location}

      {:error, {:invalid_paper_structure, %{"blocks" => errors}}} ->
        classes = errors |> Enum.map(classify) |> Enum.uniq() |> Enum.sort()

        entry = %{
          "id" => id,
          "location" => loc,
          "error_count" => length(errors),
          "classes" => classes,
          "errors" => errors
        }

        {[entry | refused], by_location}
    end
  end)

refused = Enum.sort_by(refused, & &1["id"])

by_class =
  refused
  |> Enum.flat_map(fn r -> Enum.map(r["classes"], &{&1, r["id"]}) end)
  |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  |> Map.new(fn {class, ids} -> {class, length(Enum.uniq(ids))} end)

out = %{
  "total" => length(corpus),
  "by_location" => by_location,
  "refused_count" => length(refused),
  "papers_by_class" => by_class,
  "refused" => refused
}

File.write!(out_path, Jason.encode!(out, pretty: true))

IO.puts("total=#{out["total"]} refused=#{out["refused_count"]}")
IO.puts("by_location=#{inspect(by_location)}")
IO.puts("papers_by_class=#{inspect(by_class)}")
