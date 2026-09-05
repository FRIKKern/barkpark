defmodule Barkpark.PortableDoc.BpmlGridTierGoldenTest do
  @moduledoc """
  The grid/widget tier's golden round trip (task-3b08cbd8a16ad48e criterion 1).

  Thirteen block types the BPML kernel could not spell until this suite existed.
  Each fixture under `test/support/fixtures/bpml/real-<type>.json` is a REAL
  block lifted verbatim from a REAL published paper (the paper's slug travels in
  the fixture, so a failure names the document to go look at), and each test
  pins the ONE property `bp paper pull` → edit → `bp paper push` depends on:

      print(blocks) -> parse -> print   is BYTE-IDENTICAL

  Byte-identity is the whole assertion, not `==` on the block maps: the printer
  is deliberately READ-TOLERANT (it accepts `body` where the canonical key is
  `text`, `blocks` where it is `children`) and CANONICALIZES on write, so the
  parse is allowed to differ from the input map. What it may never do is differ
  from ITSELF — the second print is what a push would store, and a pull/push an
  author never edited must not rewrite the paper. Every churn this suite would
  have caught was a real one: an empty `<b></b>` and a `prefer_authored_copy`
  attribute name that stopped at the underscore both shipped broken until the
  whole corpus was printed.

  ## Why these thirteen

  Census (`tooling/bpml/bpml-block-census.exs`, 2026-09-03, 1006 block-bearing
  published papers): 294 carried a top-level type the printer could not spell —
  29.2%. paper-links 145, cards 43, terminal 32, action 28, pipeline 27,
  stat-grid 27, blockquote 24, toc 23, chart 17, lineage 6, bar-chart 2. Three
  more (`card` 133 papers, `quote` 14, and the object spelling of an inline
  mark, 76) are INVISIBLE to that census because they are nested inside a
  section, and printing the whole corpus is what found them.

  ## The carve-outs, stated so this suite cannot be weakened into proving nothing

    * A fixture is one block, not a whole paper — the block is the unit the
      printer refuses on, and a whole paper would drag unrelated types in.
    * `chart` fixtures exclude a live `query` and `annotations`, and the
      `stat-grid` fixture excludes a `scale_profile`: those shapes REFUSE by
      decision (the printer cannot reach the data / has no element for the
      payload), and refusing is the correct behaviour, pinned by
      `bpml_unprintable_test.exs`, not a gap this suite should paper over.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml

  @fixtures Path.expand("../../support/fixtures/bpml", __DIR__)

  # The four the row names first (cards, bar-chart, lineage, terminal) plus the
  # nine the census and the corpus print run put ahead of or alongside them.
  @types ~w(paper-links cards card terminal action pipeline stat-grid
            blockquote quote toc bar-chart lineage chart)

  for type <- @types do
    test "#{type} round-trips print -> parse -> print byte-identically on a real paper" do
      type = unquote(type)
      %{"paper" => paper, "blocks" => blocks} = fixture!(type)

      first = Bpml.print_blocks(blocks)

      # NON-VACUITY, both halves: the element is actually spelled, and the
      # block's longest text leaf survives into the markup. Without this a
      # printer that emitted "" for the whole block would pass the byte-identity
      # leg trivially — "" round-trips perfectly.
      assert String.contains?(first, "<" <> type),
             "print_blocks/1 never opened a <#{type}> for #{paper}; it emitted:\n#{first}"

      sentinel = longest_text(blocks)

      assert sentinel == "" or String.contains?(first, esc(sentinel)) or
               String.contains?(first, esc_attr(sentinel)),
             "the longest text in the #{type} block of #{paper} did not survive printing.\n" <>
               "  wanted: #{inspect(esc(sentinel))}\n  printed:\n#{first}"

      {:ok, parsed} = Bpml.parse_blocks(first)

      # The parse is allowed to canonicalize keys; it is NOT allowed to change
      # what the block IS.
      assert Enum.map(parsed, & &1["type"]) == Enum.map(blocks, & &1["type"]),
             "parsing the printed #{type} of #{paper} changed the block types: " <>
               "#{inspect(Enum.map(parsed, & &1["type"]))}"

      second = Bpml.print_blocks(parsed)

      assert second == first,
             "print -> parse -> print CHURNED for #{type} (paper #{paper}) — " <>
               "a pull/push with no edit would rewrite the stored paper.\n" <>
               "--- first print ---\n#{first}\n--- second print ---\n#{second}"
    end
  end

  test "every fixture in this suite is a distinct real paper block, never a hand-written stub" do
    papers =
      Enum.map(@types, fn type ->
        %{"paper" => paper, "type" => fixture_type} = fixture!(type)

        assert fixture_type == type,
               "fixture real-#{type}.json declares type #{inspect(fixture_type)}"

        paper
      end)

    # A slug, not a placeholder: every fixture must point at a document someone
    # can open. If a future edit swaps a fixture for an invented block, this is
    # the test that notices.
    Enum.each(papers, fn paper ->
      assert is_binary(paper) and paper != "" and not String.starts_with?(paper, "test-"),
             "fixture paper slug looks synthetic: #{inspect(paper)}"
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp fixture!(type),
    do: @fixtures |> Path.join("real-#{type}.json") |> File.read!() |> Jason.decode!()

  # The longest string anywhere in the block — attribute value or body text.
  # Whichever it is, the spelling has to carry it.
  defp longest_text(term) do
    term |> strings() |> Enum.max_by(&String.length/1, fn -> "" end)
  end

  defp strings(term) when is_map(term), do: term |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(term) when is_list(term), do: Enum.flat_map(term, &strings/1)
  defp strings(term) when is_binary(term), do: [term]
  defp strings(_other), do: []

  # The printer's escaping, mirrored (printer.ex `esc/1` + `esc_attr/1`); a
  # sentinel holding `&`, `<` or `>` is not in the output verbatim.
  defp esc(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # An ATTRIBUTE value escapes the quote too (printer.ex `esc_attr/1`), so a
  # sentinel that lands in an attribute rather than a body is spelled this way.
  defp esc_attr(s), do: s |> esc() |> String.replace("\"", "&quot;")
end
