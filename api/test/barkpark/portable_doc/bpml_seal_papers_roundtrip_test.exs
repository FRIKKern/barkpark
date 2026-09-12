defmodule Barkpark.PortableDoc.BpmlSealPapersRoundtripTest do
  @moduledoc """
  THE SEAL (task-2957c0caa1ffd1b0): the two flagship papers round-trip WHOLE.

  Every other BPML suite pins one block type at a time. This one pins two real
  published documents end to end — `heggemsnes-act` and `eight-minute-erasure`
  — because the row's two acceptance criteria are stated on the PAPERS, not on
  a type list: a paper round-trips only if EVERY type in it does, including the
  ones nested three deep inside a `<section>` that no per-type census sees.

  ## How the criterion reads, and why

  The row's words are `parse(print(blocks)) == blocks`, byte-equal.

  For **heggemsnes-act that holds LITERALLY** and this suite asserts it in that
  form — no normalizer, no carve-out.

  For **eight-minute-erasure it cannot hold literally, and that is by design,
  not a gap**. The printer is the module that DEFINES the canonical spelling
  (`Bpml` moduledoc, "Canonical form"), and two canonicalizations are load
  bearing decisions taken earlier, each with its own suite:

    1. **Inline marks have ONE spelling.** A node-spelled `%{"type" => "code",
       "value" => v}` and a text node carrying `marks: ["code"]` are the same
       thing; the printer's coalescing pass (printer.ex `expand/2` +
       `inline_run/2`, pinned by `bpml_mark_coalescing_test.exs`) collapses
       both onto the marked-text form ON PURPOSE — reverting it would
       re-introduce the churn where `<b>Phase </b><b><code>Ping</code></b>` and
       `<b>Phase <code>Ping</code></b>` printed differently on successive
       pulls. 45 inline nodes in the erasure paper take this path.
    2. **A container's body key canonicalizes.** `expandable` stores its body
       under `children` OR `blocks`; the printer reads both and the parser
       emits `blocks` (the alias-canonicalization rule stated in
       `bpml_roundtrip_property_test.exs`). 2 blocks take this path.

  So this suite states the criterion in the only form that is both TRUE and
  STRONG: `parse(print(blocks)) == canonicalize(blocks)`, where
  `canonicalize/1` below implements EXACTLY those two rules and nothing else.
  Any third difference — a dropped attribute, a lost body, a retyped block —
  reds. Two controls keep that honest: `canonicalize/1` must be a NO-OP on the
  parsed side (it is already canonical), and it must be a NO-OP on
  heggemsnes-act (whose literal equality is asserted separately).

  Nothing here is a 422: neither paper reaches the `bpml_unprintable` path any
  more. Before this task, `eight-minute-erasure` answered 422 on
  `bp paper pull` because `figure`, `asciicast` and `columns` were outside the
  kernel vocabulary.

  ## What this task found that the filing did not predict

  Adding the three flagship types was NOT sufficient. Two pre-existing
  attributes were being dropped silently by the kernel and both fire on this
  paper: `code`'s `lang` (read by components.ex `code_html/2`, by pdrender's
  code.go and by the Studio editor) and `list`'s `ordered` (compose.ex reads
  `Map.get(b, "ordered") == true`). A pull/push with no edit un-numbered an
  ordered list and stripped a syntax-highlighting language. Both now ride the
  attribute row; `bpml_roundtrip_property_test.exs` pins them.

  ## The fixtures

  `test/support/fixtures/bpml/paper-<slug>.json` is the LIVE document's block
  tree, fetched read-only on 2026-09-12, carrying the `_rev` it was taken at:

    * heggemsnes-act        `3ead12a03aaca4ae264630ba0ac36fd1`  19 top blocks
    * eight-minute-erasure  `96b583c978578c3b3c40331bb5583078`  46 top blocks

  DELIBERATELY NOT the rig fixtures at
  `tooling/paper-excellence/rig/fixtures/<slug>.json`: those are rendered
  GEOMETRY snapshots whose `source_rev` (2a89cadb…, 9e2998c8…) is behind the
  live documents, and refreshing them would move `rig/baselines` report values
  that have nothing to do with BPML. The live tree is what the criteria mean,
  so it is copied here, where a refresh costs nothing but this file.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml

  @fixtures Path.expand("../../support/fixtures/bpml", __DIR__)

  @flagship_types ~w(figure asciicast columns)

  # The inline node types that canonicalize onto a marked text node. `link` is
  # NOT one of them — `<a href>` parses to a `link` node, which survives as a
  # node — so a link appearing here would (correctly) fail rather than be
  # normalized away.
  @mark_node_types ~w(strong em code underline strike)

  describe "criterion 1 — heggemsnes-act" do
    test "round-trips parse(print(blocks)) == blocks, LITERALLY byte-equal" do
      %{"paper" => "heggemsnes-act", "rev" => rev, "blocks" => blocks} =
        fixture!("heggemsnes-act")

      assert rev == "3ead12a03aaca4ae264630ba0ac36fd1"
      assert length(blocks) == 19

      bpml = Bpml.print_blocks(blocks)
      assert {:ok, parsed} = Bpml.parse_blocks(bpml)

      assert parsed == blocks, "heggemsnes-act moved:\n" <> first_difference(blocks, parsed)
      assert Bpml.print_blocks(parsed) == bpml
    end

    test "control: canonicalize/1 is a NO-OP on it, so the literal assertion above is the real one" do
      %{"blocks" => blocks} = fixture!("heggemsnes-act")
      assert canonicalize(blocks) == blocks
    end

    test "control: it needs NO flagship type — it measures the pre-existing kernel" do
      %{"blocks" => blocks} = fixture!("heggemsnes-act")
      types = block_types(blocks)

      assert Enum.all?(@flagship_types, &(&1 not in types)),
             "heggemsnes-act now carries a flagship type; it is no longer a control"

      assert types == ~w(byline callout eyebrow heading ingress notes paragraph stats steps)
    end
  end

  describe "criterion 2 — eight-minute-erasure (figure, asciicast, expandable, columns)" do
    test "round-trips parse(print(blocks)) == canonicalize(blocks) — nothing else moves" do
      %{"paper" => "eight-minute-erasure", "rev" => rev, "blocks" => blocks} =
        fixture!("eight-minute-erasure")

      assert rev == "96b583c978578c3b3c40331bb5583078"
      assert length(blocks) == 46

      bpml = Bpml.print_blocks(blocks)
      assert {:ok, parsed} = Bpml.parse_blocks(bpml)

      expected = canonicalize(blocks)

      assert parsed == expected,
             "eight-minute-erasure moved BEYOND the two named canonicalizations:\n" <>
               first_difference(expected, parsed)

      assert Bpml.print_blocks(parsed) == bpml,
             "the second print differs — a pull/push with no edit would rewrite the paper"
    end

    test "control: canonicalize/1 is a NO-OP on the PARSED side" do
      %{"blocks" => blocks} = fixture!("eight-minute-erasure")
      {:ok, parsed} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()

      assert canonicalize(parsed) == parsed,
             "the parser's own output is not canonical by canonicalize/1's rules, so " <>
               "the normalizer is measuring something other than what it claims"
    end

    test "control: canonicalize/1 actually DOES something here (it is not vacuous)" do
      %{"blocks" => blocks} = fixture!("eight-minute-erasure")

      refute canonicalize(blocks) == blocks,
             "canonicalize/1 changed nothing, so the criterion-2 assertion silently " <>
               "degraded into the literal one and this carve-out is dead code"
    end

    test "it actually exercises the flagship tier this task added" do
      %{"blocks" => blocks} = fixture!("eight-minute-erasure")
      types = block_types(blocks)

      for type <- @flagship_types do
        assert type in types,
               "the erasure fixture no longer carries a #{type} block — this suite " <>
                 "would then pass without proving the flagship tier spells anything"
      end

      assert "expandable" in types

      bpml = Bpml.print_blocks(blocks)

      for type <- @flagship_types do
        assert String.contains?(bpml, "<" <> type),
               "print_blocks/1 never opened a <#{type}> element"
      end

      # The `columns` grid's positional child — a `<columns>` printed with no
      # `<column>` inside would be a silently emptied grid that still
      # round-trips through an equally empty parse.
      assert String.contains?(bpml, "<column>")

      # The two attributes this task found were being dropped.
      assert String.contains?(bpml, ~s(lang="elixir"))
      assert String.contains?(bpml, ~s(ordered="true"))
    end
  end

  # ── the two named canonicalizations, and nothing else ───────────────────────
  #
  # The walk is MODE-AWARE, and it has to be: an inline code run and a code
  # BLOCK are the same map — `%{"type" => "code", "value" => …}` — and only
  # position tells them apart. Rule 1 may only fire in inline position, so the
  # walker switches to block mode under the keys that hold blocks and stays in
  # inline mode everywhere else. (Get this wrong and the normalizer rewrites
  # every code block in the paper into marked prose; the two controls in the
  # criterion-2 describe are what caught exactly that.)
  @block_body_keys ~w(blocks children child columns slots steps)

  defp canonicalize(blocks) when is_list(blocks), do: Enum.map(blocks, &canon_block/1)

  # RULE 2 — `expandable` spells its body `blocks` (the parser's canonical key).
  defp canon_block(%{"type" => "expandable", "children" => children} = block) do
    block
    |> Map.delete("children")
    |> Map.put("blocks", children)
    |> canon_block()
  end

  defp canon_block(%{} = block) do
    Map.new(block, fn
      {k, v} when k in @block_body_keys -> {k, canon_block_value(v)}
      {k, v} -> {k, canon_inline(v)}
    end)
  end

  defp canon_block(other), do: other

  defp canon_block_value(v) when is_list(v), do: Enum.map(v, &canon_block_value/1)
  defp canon_block_value(%{} = v), do: canon_block(v)
  defp canon_block_value(v), do: v

  # RULE 1 — a node-spelled inline mark becomes a text node carrying that mark.
  defp canon_inline(%{"type" => t, "value" => v} = node)
       when t in @mark_node_types and is_binary(v),
       do: %{"type" => "text", "value" => v, "marks" => [t | Map.get(node, "marks", [])]}

  # The mark distributes over every run the element covers (parser.ex), so one
  # marked element with N children becomes N marked runs — hence the flatten in
  # the list clause below.
  defp canon_inline(%{"type" => t, "children" => children})
       when t in @mark_node_types and is_list(children) do
    Enum.map(children, fn child ->
      case canon_inline(child) do
        %{"marks" => marks} = c -> %{c | "marks" => [t | marks]}
        %{} = c -> Map.put(c, "marks", [t])
        other -> other
      end
    end)
  end

  defp canon_inline(%{} = m), do: Map.new(m, fn {k, v} -> {k, canon_inline(v)} end)

  # Flattens EXACTLY the one level a distributed mark introduces. A blanket
  # `List.flatten/1` here collapsed a table's rows-of-cells-of-nodes into one
  # flat node list — structure destroyed, and the assertion would then have
  # been comparing a shape the parser never emits.
  defp canon_inline(l) when is_list(l) do
    Enum.flat_map(l, fn
      %{"type" => t, "children" => cs} = node when t in @mark_node_types and is_list(cs) ->
        canon_inline(node)

      item ->
        [canon_inline(item)]
    end)
  end

  defp canon_inline(other), do: other

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp fixture!(slug),
    do: @fixtures |> Path.join("paper-#{slug}.json") |> File.read!() |> Jason.decode!()

  # Every block `type` reachable in the tree, sorted and deduped. Inline node
  # types are excluded: they are marks, not blocks.
  @inline_types ~w(text strong em code underline strike link)

  defp block_types(term) do
    term |> types() |> Enum.reject(&(&1 in @inline_types)) |> Enum.uniq() |> Enum.sort()
  end

  defp types(%{"type" => t} = m) when is_binary(t),
    do: [t | m |> Map.delete("type") |> Map.values() |> Enum.flat_map(&types/1)]

  defp types(m) when is_map(m), do: m |> Map.values() |> Enum.flat_map(&types/1)
  defp types(l) when is_list(l), do: Enum.flat_map(l, &types/1)
  defp types(_other), do: []

  # A whole-paper inequality is unreadable; name the first block that moved and
  # show only it.
  defp first_difference(expected, actual) do
    pair =
      expected
      |> Enum.zip(actual)
      |> Enum.with_index()
      |> Enum.find(fn {{e, a}, _i} -> e != a end)

    case pair do
      {{e, a}, i} ->
        "first differing block is ##{i} (type #{inspect(e["type"])}, id #{inspect(e["id"])}):\n" <>
          "--- expected ---\n#{inspect(e, pretty: true, limit: :infinity)}\n" <>
          "--- after round trip ---\n#{inspect(a, pretty: true, limit: :infinity)}"

      nil ->
        "the block lists differ only in LENGTH: expected #{length(expected)}, " <>
          "after round trip #{length(actual)}"
    end
  end
end
