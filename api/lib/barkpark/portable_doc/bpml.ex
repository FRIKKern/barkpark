defmodule Barkpark.PortableDoc.Bpml do
  @moduledoc """
  BPML — the Barkpark Markup Language. A readable, strict markup that is an
  isomorphic VIEW of a PortableDoc block tree (masterplan
  `2026-08-13-portabledoc-source-masterplan`, W1). A STANDALONE parser+printer
  pair beside `Barkpark.PortableDoc.FromMarkdown` — pure, no Repo, no I/O.

  ## The law

    * **Isomorphism.** `parse_blocks(print_blocks(blocks)) == blocks` for every
      block tree in the kernel vocabulary — id-stable, key-stable, byte-equal.
      BPML carries no logic (no variables, loops, includes), so nothing can be
      lost in either direction. The property test in `bpml_test.exs` is the
      gate; a construct that cannot round-trip does not enter the grammar.
    * **Naming.** When HTML has a name for it, BPML uses HTML's name
      (`<h1> <p> <ul> <b> <a>`); new tags name what the reader shows
      (`<stats> <callout> <section>`). `<strong>`/`<em>` parse as aliases and
      print canonically as `<b>`/`<i>`.
    * **Strictness.** Unknown tags, unknown attributes, and text outside a
      text-bearing element are ERRORS, each carrying the fix (`hint`) — the
      publish wall's errors-that-teach pattern applied to syntax. Parsing
      collects every error it can reach (validate-all spirit), not just the
      first.

  ## Canonical form

  The printer emits ONE canonical spelling: two-space indentation, inline
  content on one line inside its tag, attributes in a fixed order (`id` first),
  `&amp; &lt; &gt;` escaped in text and additionally `&quot;` in attributes.
  Adjacent UNMARKED text nodes merge on round-trip (they are indistinguishable
  in markup) — the one documented canonicalization.

  ## Kernel vocabulary

  Block tags: `paper section p pullquote ingress eyebrow h1 h2 h3 byline/item
  ul/li table/tr/th/td code diagram route stats/stat notes/note note steps/step
  callout`.
  Inline tags: `b i code u s a` (→ marks `strong em code underline strike`,
  and `<a href>` → a `link` node).
  """

  alias Barkpark.PortableDoc.Bpml.{Parser, Printer}

  @type blocks :: [map()]
  @type errors :: [
          %{code: String.t(), message: String.t(), line: pos_integer(), hint: String.t()}
        ]

  @doc "Blocks → canonical BPML (no `<paper>` wrapper)."
  @spec print_blocks(blocks) :: String.t()
  defdelegate print_blocks(blocks), to: Printer

  @doc "Whole paper map (`slug`/`title`/optional `description`+`tags`/`blocks`) → canonical BPML document."
  @spec print_paper(map()) :: String.t()
  defdelegate print_paper(paper), to: Printer

  @doc "BPML fragment → `{:ok, blocks}` | `{:error, errors}` (all reachable errors, teaching hints included)."
  @spec parse_blocks(String.t()) :: {:ok, blocks} | {:error, errors}
  defdelegate parse_blocks(bpml), to: Parser

  @doc "BPML `<paper>` document → `{:ok, paper_map}` | `{:error, errors}`."
  @spec parse_paper(String.t()) :: {:ok, map()} | {:error, errors}
  defdelegate parse_paper(bpml), to: Parser

  @doc """
  The machine-readable BPML contract for `/v1/capabilities` (masterplan W0):
  block tags with their allowed attributes, the inline alias→mark table, and a
  DERIVED digest — sha256 over an explicitly sorted rendering, so it is stable
  across nodes and moves exactly when the grammar moves (the same
  derive-don't-hand-bump doctrine as the renderer's source digest). Clients
  echo the digest to detect that their generated types have gone stale.
  """
  @spec vocabulary() :: map()
  def vocabulary do
    blocks =
      Parser.block_attrs()
      |> Map.take(
        Parser.known_block_tags() ++
          [
            "paper",
            "stat",
            # the grid/widget tier's child elements (criterion 1) — a client
            # generating types from this contract needs the CHILD attribute
            # rows too, not just the block tags that hold them.
            "ref",
            "card",
            "node",
            "entry",
            "bar",
            "lineage-node",
            "series",
            "step",
            "item",
            "li",
            "tr",
            "th",
            "td",
            "meta",
            "description",
            "tag",
            "a"
          ]
      )

    vocab = %{
      "blocks" => blocks,
      "inline" => Parser.inline_marks(),
      "formats" => ["json", "bpml"]
    }

    digest =
      :crypto.hash(:sha256, :erlang.iolist_to_binary(canonical(vocab)))
      |> Base.encode16(case: :lower)

    Map.put(vocab, "digest", "bpml-" <> binary_part(digest, 0, 16))
  end

  # Deterministic rendering for the digest: maps sort by key; lists keep their
  # order (attribute order is part of the contract).
  defp canonical(map) when is_map(map),
    do: [
      "{",
      map |> Enum.sort() |> Enum.map(fn {k, v} -> [to_string(k), ":", canonical(v), ","] end),
      "}"
    ]

  defp canonical(list) when is_list(list), do: ["[", Enum.map(list, &[canonical(&1), ","]), "]"]
  defp canonical(other), do: to_string(other)
end
