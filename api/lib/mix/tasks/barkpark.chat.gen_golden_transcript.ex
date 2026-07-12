defmodule Mix.Tasks.Barkpark.Chat.GenGoldenTranscript do
  @moduledoc """
  Generate the cross-surface **chat golden-transcript parity fixture** and write
  it to both mirror paths. ONE fixture of assistant-REPLY-BODY variants — the
  executable source of truth that the Elixir converter
  (`Barkpark.PortableDoc.FromMarkdown.blocks/1`) and the Go terminal renderer
  (`pdrender.Decode` → `DefaultRegistry(...).RenderDoc`) must agree on, so
  "identical" is a CI fact from day one (charter D8 + D13, Mechanism A).

      mix barkpark.chat.gen_golden_transcript

  ## REPLY-BODY-ONLY scope (charter D13)

  This harness covers ONLY the SETTLED assistant reply body — the markdown a
  model emits, converted to PortableDoc blocks and rendered as a document. It
  does NOT cover tool / todo / approval / thinking rows: those are bespoke HEEx
  (`chat_tool_renderer.ex`) with no pdrender twin, and their TUI renderers +
  parity mechanism are the named backlog slice `ct-bl-toolrow-renderers`, NOT
  silently included in the phrase "golden transcript".

  ## Mechanism A — field/structural projection, never cross-engine byte-diff

  A byte-diff between a HEEx string and an ANSI terminal string is impossible by
  construction, so each variant carries THREE fields (the sheets/preview 3-mirror
  pattern):

    * `markdown` — the reply body exactly as a model would emit it;
    * `blocks` — the EXACT `FromMarkdown.blocks(markdown)` output (never
      hand-typed — `build/0` derives it), the shared block JSON both surfaces
      consume (D8: this JSON round-trips through `pdrender.Decode` with zero
      shape mismatch, no projection layer on the render path);
    * `projection` — a structural projection (top-level TYPE sequence + the KEY
      TEXT each block must realize), the surface-neutral contract each renderer
      answers to in its OWN native form (Elixir view HEEx / Go ANSI).

  Three variants at the coverage floor:

    * `rich_markdown` — h1/h2/h3 + paragraph + inline `code` + bulleted list +
      a GFM table + a fenced code block;
    * `mermaid_diagram` — a ` ```mermaid ` fence promoted to a `diagram` block;
    * `portabledoc_fence` — a ` ```portabledoc ` fence splicing a `callout` and
      a `stats` block (the rich-native escape hatch).

  Emits pretty-printed JSON to two byte-identical mirrors:

    * `api/test/support/fixtures/chat_golden_transcript.json`
    * `internal/pdrender/testdata/chat_golden_transcript.json`

  Do NOT hand-edit either mirror — re-run this task and re-verify both surfaces.
  The freshness lock lives in
  `test/barkpark/chat_golden_transcript_parity_test.exs` (asserts the committed
  api mirror equals `build/0`, the two mirrors decode term-identical, and per
  variant that `FromMarkdown.blocks(markdown) == blocks`). The Go projection test
  lives in `internal/pdrender/chat_golden_parity_test.go`.

  `build/0` is PURE (only `FromMarkdown.blocks/1` — a pure library over
  `EarmarkParser`; no app boot, no `Mix.Task`) so the freshness test regenerates
  in-memory.
  """
  @shortdoc "Regenerate the cross-surface chat golden-transcript parity fixture (two mirrors)"

  use Mix.Task

  alias Barkpark.PortableDoc.FromMarkdown

  # ── the canonical reply-body variants ────────────────────────────────────────
  #
  # Every variant is a REPLY BODY only (charter D13). The `blocks` are never
  # hand-typed — `build/0` runs `FromMarkdown.blocks/1` over the markdown, so the
  # fixture can never certify a block shape the converter would not produce.

  @rich_markdown """
  # One Chat, Two Surfaces

  The `bp chat` client renders assistant replies through the same PortableDoc engine every Barkpark surface shares.

  ## Rendering pipeline

  Markdown arrives, converts to blocks, and streams into the terminal viewport.

  ### Block coverage

  - Headings across three distinct levels
  - Paragraphs with inline `code` marks
  - Ordered and bulleted lists

  | Surface | Renderer |
  | --- | --- |
  | Studio | HEEx |
  | Terminal | pdrender |

  ```elixir
  def render(reply) do
    FromMarkdown.blocks(reply)
  end
  ```
  """

  @mermaid_markdown """
  ## Streaming diagram

  The reply settles at the turn boundary, then rerenders cleanly.

  ```mermaid
  flowchart LR
    ingest[Ingest] --> render[Render] --> stream[Stream]
  ```
  """

  # The portabledoc fence is a JSON array of native display blocks spliced in
  # verbatim after validation. Only data-bearing display types are legal
  # (FromMarkdown @allowed_fence_types) — callout + stats both qualify.
  @portabledoc_markdown ~S"""
  ## Native blocks

  The reply splices rich native blocks through the portabledoc fence.

  ```portabledoc
  [
    {"type":"callout","tone":"success","content":[{"type":"text","value":"Reply-body parity is now a continuous-integration fact."}]},
    {"type":"stats","items":[{"value":"1531","label":"chat message rows"},{"value":"42","label":"pdrender renderers"}]}
  ]
  ```
  """

  @variants [
    %{name: "rich_markdown", markdown: @rich_markdown},
    %{name: "mermaid_diagram", markdown: @mermaid_markdown},
    %{name: "portabledoc_fence", markdown: @portabledoc_markdown}
  ]

  @comment "Generated by `mix barkpark.chat.gen_golden_transcript` — DO NOT hand-edit. " <>
             "Cross-surface chat golden-transcript parity lock (Elixir FromMarkdown.blocks/1 " <>
             "+ Go pdrender Decode -> RenderDoc). REPLY-BODY-ONLY scope (charter D13): tool / " <>
             "todo / approval / thinking rows are OUT OF SCOPE (backlog ct-bl-toolrow-renderers). " <>
             "The blocks are FromMarkdown.blocks/1 itself — regenerate, never edit."

  @scope "assistant-reply-body-only"

  @api_path Path.expand("../../../test/support/fixtures/chat_golden_transcript.json", __DIR__)
  @go_path Path.expand(
             "../../../../internal/pdrender/testdata/chat_golden_transcript.json",
             __DIR__
           )

  @doc "The two mirror paths the fixture is written to (also read by the freshness test)."
  def mirror_paths, do: [@api_path, @go_path]

  @impl Mix.Task
  def run(_args) do
    json = Jason.encode!(build(), pretty: true) <> "\n"

    for path <- mirror_paths() do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, json)
      Mix.shell().info("wrote #{path}")
    end

    Mix.shell().info("gen_golden_transcript: 2 mirror(s) written — re-verify both surfaces.")
  end

  @doc """
  Build the chat golden-transcript fixture data map (pure — `FromMarkdown.blocks/1`
  over each variant's markdown; no app boot). The freshness test regenerates
  through this and asserts term-equality with the committed api mirror.

  Every term is JSON-safe (string keys, lists not tuples) so a Jason encode →
  decode round-trip is the identity, and `build/0 == Jason.decode!(committed)`.
  """
  def build do
    variants =
      Enum.map(@variants, fn %{name: name, markdown: markdown} ->
        blocks = FromMarkdown.blocks(markdown)

        %{
          "name" => name,
          "markdown" => markdown,
          "blocks" => blocks,
          "projection" => Enum.map(blocks, &project_block/1)
        }
      end)

    %{
      "_comment" => @comment,
      "scope" => @scope,
      "variants" => variants
    }
  end

  # ── structural projection (derived from the REAL blocks, never hand-typed) ────
  #
  # One entry per TOP-LEVEL block: its `type`, the `level` (headings only), and
  # the `text` the block must realize on every surface. `text` is the surface-
  # neutral key content; each renderer surfaces it in its own native form (HEEx
  # tag / ANSI run) so the Go leg asserts realization by stripped-ANSI presence,
  # not a byte-diff.

  defp project_block(%{"type" => "heading", "level" => level, "text" => text}) do
    %{"type" => "heading", "level" => level, "text" => text}
  end

  defp project_block(%{"type" => "paragraph", "content" => content}) do
    %{"type" => "paragraph", "text" => inline_text(content)}
  end

  defp project_block(%{"type" => "list", "items" => items}) do
    %{"type" => "list", "text" => items |> Enum.map(&inline_text/1) |> Enum.join(" ")}
  end

  defp project_block(%{"type" => "table"} = block) do
    %{"type" => "table", "text" => table_text(block)}
  end

  defp project_block(%{"type" => "code", "value" => value}) do
    %{"type" => "code", "text" => value}
  end

  defp project_block(%{"type" => "diagram", "source" => source}) do
    %{"type" => "diagram", "text" => diagram_labels(source)}
  end

  defp project_block(%{"type" => "callout", "content" => content}) do
    %{"type" => "callout", "text" => inline_text(content)}
  end

  defp project_block(%{"type" => "stats", "items" => items}) do
    %{"type" => "stats", "text" => stats_text(items)}
  end

  # Any other spliced/native block: type-only (the no-fallback + type-sequence
  # legs still pin it; a bespoke text projection is added when a variant needs it).
  defp project_block(%{"type" => type}), do: %{"type" => type, "text" => ""}

  # ── plain-text flatteners (self-contained; FromMarkdown's are private) ────────

  defp inline_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &inline_text/1)
  defp inline_text(%{"type" => "text", "value" => v}), do: v
  defp inline_text(%{"type" => "code", "value" => v}), do: v
  defp inline_text(%{"children" => children}), do: inline_text(children)
  defp inline_text(_), do: ""

  # Every cell of head + body rows, flattened cell-by-cell and joined — the full
  # text the table must show across the grid. `head` is one row of cells; `rows`
  # is a list of rows of cells; each cell is an inline run.
  defp table_text(block) do
    head_cells = Map.get(block, "head", [])
    row_cells = block |> Map.get("rows", []) |> Enum.concat()

    (head_cells ++ row_cells)
    |> Enum.map(&inline_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # Mermaid node labels (`ingest[Ingest]` → "Ingest") — the diagram's semantic
  # content that renders as box-art (or, when folded, appears verbatim in the
  # source box). Falls back to the raw source if a graph carries no bracket
  # labels.
  defp diagram_labels(source) do
    labels =
      ~r/\[([^\]]+)\]/
      |> Regex.scan(source)
      |> Enum.map(fn [_, label] -> String.trim(label) end)

    case labels do
      [] -> source
      list -> Enum.join(list, " ")
    end
  end

  # A stat grid's shown text: every cell's value then label.
  defp stats_text(items) do
    items
    |> Enum.flat_map(fn item ->
      [Map.get(item, "value", ""), Map.get(item, "label", "")]
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end
end
