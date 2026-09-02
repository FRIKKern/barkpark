#!/usr/bin/env elixir
# bpml-block-census.exs — enumerate the renderer's block-type registry and the
# BPML printer's spelled vocabulary PROGRAMMATICALLY, and print the diff both
# directions. task-3b08cbd8a16ad48e criterion 0.
#
# BUILD-FREE (Code.string_to_quoted only, mirrors scripts/pds-elixir-receipt-
# census.exs's lens): it reads the two source files as text and parses them
# as AST, so it never boots the app and works whether or not api/_build
# exists. Run from the repo root:
#
#   elixir tooling/bpml/bpml-block-census.exs
#
# Optional: pass a path to a corpus dump (the JSON `bp doc query paper --all
# -o json` shape: {"documents":[{"_id":.., "blocks":[{"type":..}, ..]}, ..]})
# as the first argument to also report, for each unspellable type, how many
# published papers carry it at TOP LEVEL:
#
#   elixir tooling/bpml/bpml-block-census.exs /path/to/corpus.json

defmodule BpmlCensus do
  @renderer_file "api/lib/barkpark/portable_doc/tiers.ex"
  @printer_file "api/lib/barkpark/portable_doc/bpml/printer.ex"

  def main(argv) do
    root = repo_root()
    renderer_types = renderer_types(Path.join(root, @renderer_file))
    printer_types = printer_types(Path.join(root, @printer_file))

    unspellable = MapSet.difference(renderer_types, printer_types) |> Enum.sort()
    unregistered = MapSet.difference(printer_types, renderer_types) |> Enum.sort()

    p("BPML BLOCK-TYPE CENSUS")
    p("  renderer registry (#{@renderer_file}, Tiers.known_types/0-equivalent AST read): #{MapSet.size(renderer_types)} types")
    p("  BPML printer spells (#{@printer_file}, `defp block(%{\"type\" => ..} clauses): #{MapSet.size(printer_types)} types")
    p("")
    p("  renderer types the printer CANNOT spell (#{length(unspellable)}):")
    Enum.each(unspellable, &p("    - #{&1}"))
    p("")

    if unregistered == [] do
      p("  printer types the renderer does NOT register (0): none — every spelled type is registered")
    else
      p("  printer types the renderer does NOT register (#{length(unregistered)}):")
      Enum.each(unregistered, &p("    - #{&1}"))
    end

    p("")

    case argv do
      [corpus_path | _] -> corpus_impact(corpus_path, unspellable)
      [] -> p("  (no corpus path given — skipping corpus-impact section)")
    end
  end

  # ── renderer set ─────────────────────────────────────────────────────────
  # Tiers.known_types/0 is Map.keys/1 of the union of @element/@widget/@section.
  # Read those three module-attribute list literals off the AST rather than
  # trusting a hand transcription — @element/@widget are plain `[...]` lists of
  # string literals (one per line, per the file's own "APPEND-FRIENDLY SHAPE"
  # doctrine), @section is a `~w(...)` sigil.

  defp renderer_types(path) do
    ast = quoted!(path)

    ["element", "widget", "section"]
    |> Enum.flat_map(fn name -> module_attribute_strings(ast, String.to_atom(name)) end)
    |> MapSet.new()
  end

  defp module_attribute_strings(ast, attr_name) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{^attr_name, _, [value]}]} = node, acc ->
          {node, [literal_strings(value) | acc]}

        node, acc ->
          {node, acc}
      end)

    List.flatten(acc)
  end

  # A `[...]` list of string literals (bare, or under a comment — comments do
  # not reach the AST) → the strings. A `~w(...)` sigil → its word list.
  defp literal_strings(list) when is_list(list) do
    Enum.flat_map(list, fn
      s when is_binary(s) -> [s]
      _other -> []
    end)
  end

  defp literal_strings({:sigil_w, _, [{:<<>>, _, [words]}, _mods]}) when is_binary(words) do
    String.split(words, ~r/\s+/, trim: true)
  end

  defp literal_strings(_other), do: []

  # ── printer set ──────────────────────────────────────────────────────────
  # Every `defp block(%{"type" => "literal", ...} = b, d) [when ...], do: ...`
  # (or multi-clause `do ... end`) clause's literal type string. The catchall
  # `defp block(%{"type" => type}, _d)` and `defp block(_other, _d)` clauses
  # bind a variable, not a literal, so they contribute nothing here — which is
  # correct: they are the REFUSAL, not a spelling.

  defp printer_types(path) do
    ast = quoted!(path)

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:defp, _, [head | _body]} = node, acc ->
          {node, block_head_type(head) ++ acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(acc)
  end

  # The function HEAD is either `block(pattern, d)` directly, or — a guarded
  # clause (`when l in 1..3`) — `{:when, _, [block(pattern, d), guard]}` at
  # THIS level (the `when` wraps the whole call, not just the first arg, so it
  # has to be unwrapped before the `{:block, _, [first_arg | _]}` match, not
  # after — the earlier draft of this script missed both `heading` clauses by
  # unwrapping `when` one level too late and undercounted by exactly 1).
  defp block_head_type({:when, _, [call, _guard]}), do: block_head_type(call)
  defp block_head_type({:block, _, [first_arg | _rest]}), do: block_clause_type(first_arg)
  defp block_head_type(_other), do: []

  defp block_clause_type({:=, _, [map_pattern, _var]}), do: block_clause_type(map_pattern)

  defp block_clause_type({:%{}, _, pairs}) do
    case List.keyfind(pairs, "type", 0) do
      {"type", type} when is_binary(type) -> [type]
      _ -> []
    end
  end

  defp block_clause_type(_other), do: []

  # ── corpus impact ────────────────────────────────────────────────────────
  # For each unspellable type, how many published papers carry it at TOP
  # LEVEL (blocks[i].type, not nested inside e.g. a card's slots or a table
  # cell — "top-level" per the row's own framing). Streams the corpus file
  # rather than holding it as one term any longer than one document at a time
  # by shelling to `jq` in streaming mode, so a 170MB dump never sits fully
  # parsed in this script's own heap at once either.

  # Delegates the aggregation itself to `jq` in one pass over the file — the
  # 170MB dump is never held as a fully-parsed Elixir term, and this script
  # takes no JSON-decode dependency (no Jason, no Mix project). Output is
  # plain tab-separated lines this reads with String.split/2, nothing more.
  defp corpus_impact(path, unspellable_types) do
    unless File.exists?(path) do
      p("  corpus file not found: #{path} — skipping corpus-impact section")
      :ok
    else
      types_json = "[" <> Enum.map_join(unspellable_types, ",", &~s("#{&1}")) <> "]"

      jq_program = """
      ($types) as $u
      | (reduce (.documents[]) as $doc
          ({total: 0, block_bearing: 0, any: 0, counts: ($u | map({(.): 0}) | add // {})};
            .total += 1
            | ([$doc.blocks[]? .type // empty] | unique) as $t
            | (if ($doc.blocks // [] | length) > 0 then .block_bearing += 1 else . end)
            | ($t - ($t - $u)) as $hit
            | (if ($hit | length) > 0 then .any += 1 else . end)
            | reduce $hit[] as $h (.; .counts[$h] += 1)
          )
        ) as $agg
      | "TOTAL\\t\\($agg.total)",
        "BLOCK_BEARING\\t\\($agg.block_bearing)",
        "ANY\\t\\($agg.any)",
        ($agg.counts | to_entries[] | "TYPE\\t\\(.key)\\t\\(.value)")
      """

      {jq_out, status} =
        System.cmd("jq", ["-r", "--argjson", "types", types_json, jq_program, path])

      if status != 0 do
        p("  jq failed (exit #{status}) — skipping corpus-impact section")
      else
        report_corpus_impact(jq_out, path)
      end
    end
  end

  defp report_corpus_impact(jq_out, path) do
    rows = jq_out |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))

    total = rows |> Enum.find(fn r -> hd(r) == "TOTAL" end) |> Enum.at(1) |> String.to_integer()

    block_bearing =
      rows |> Enum.find(fn r -> hd(r) == "BLOCK_BEARING" end) |> Enum.at(1) |> String.to_integer()

    any_unspellable =
      rows |> Enum.find(fn r -> hd(r) == "ANY" end) |> Enum.at(1) |> String.to_integer()

    per_type =
      rows
      |> Enum.filter(fn r -> hd(r) == "TYPE" end)
      |> Enum.map(fn [_, t, n] -> {t, String.to_integer(n)} end)
      |> Enum.reject(fn {_t, n} -> n == 0 end)
      |> Enum.sort_by(fn {_t, n} -> -n end)

    p("  CORPUS IMPACT (source: #{path})")
    p("    published papers (documents in dump):    #{total}")
    p("    block-bearing (>=1 block):                #{block_bearing}")

    p(
      "    carry >=1 top-level unspellable type:     #{any_unspellable} / #{block_bearing}#{pct(any_unspellable, block_bearing)}  (/ #{total} of ALL published: #{pct(any_unspellable, total) |> String.trim()})"
    )

    p("")
    p("    per-type paper counts, most-affected first:")
    Enum.each(per_type, fn {t, n} -> p("      #{String.pad_trailing(t, 20)} #{n}") end)
  end

  defp pct(_n, 0), do: ""
  defp pct(n, total), do: " (#{Float.round(n / total * 100, 1)}%)"

  defp quoted!(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
  end

  defp repo_root do
    {out, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(out)
  end

  defp p(s), do: IO.puts(s)
end

BpmlCensus.main(System.argv())
