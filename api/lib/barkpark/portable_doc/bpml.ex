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
  ul/li table/tr/th/td code diagram stats/stat steps/step callout`.
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
end
