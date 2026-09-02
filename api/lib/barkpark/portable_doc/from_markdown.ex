defmodule Barkpark.PortableDoc.FromMarkdown do
  @moduledoc """
  GFM markdown → PortableDoc block list.

  Built for the Studio Claude chat (w2a of `studio-claude-chat`): assistant
  replies arrive as markdown and render through the SAME paper engine as
  every other Barkpark surface (`Render.render_blocks(style: :article)`),
  instead of a chat-only markdown renderer. Two fence conventions upgrade a
  reply beyond markdown:

    * ` ```mermaid ` — becomes a native `diagram` block (the paper figure).
    * ` ```portabledoc ` — a JSON array of PortableDoc blocks, spliced in
      verbatim after validation. This is the escape hatch that lets the
      model deliberately use rich native blocks (callout/table/chart/stats).
      Malformed JSON degrades to a plain code block — never an error.

  The converter is fail-soft end to end: unknown AST nodes flatten to text,
  and a parser crash degrades the whole reply to one code block. Output
  blocks contain only data — all HTML escaping happens downstream in the
  render walk, exactly as for persisted paper blocks.
  """

  @max_fence_blocks 50

  @allowed_fence_types ~w(
    heading paragraph list code table callout divider diagram
    chart stat stats heatmap pullquote eyebrow
  )

  @doc "Convert a markdown string to a PortableDoc block list. Never raises."
  @spec blocks(String.t()) :: [map()]
  def blocks(markdown) when is_binary(markdown) do
    case EarmarkParser.as_ast(markdown, gfm: true, smartypants: false) do
      {:ok, ast, _messages} -> Enum.flat_map(ast, &block/1)
      {:error, ast, _messages} when is_list(ast) -> Enum.flat_map(ast, &block/1)
      _ -> [code_block(markdown)]
    end
  rescue
    _ -> [code_block(markdown)]
  end

  # ── block-level mapping ─────────────────────────────────────────────────

  defp block({"h" <> n, _attrs, children, _meta}) when n in ~w(1 2 3 4 5 6) do
    level = n |> String.to_integer() |> min(3)
    [%{"type" => "heading", "level" => level, "text" => flatten_text(children)}]
  end

  defp block({"p", _attrs, children, _meta}) do
    [%{"type" => "paragraph", "content" => inline(children)}]
  end

  defp block({tag, _attrs, children, _meta}) when tag in ["ul", "ol"] do
    items =
      children
      |> Enum.filter(&match?({"li", _, _, _}, &1))
      |> Enum.map(fn {"li", _, li_children, _} -> list_item_inline(li_children) end)

    [%{"type" => "list", "ordered" => tag == "ol", "items" => items}]
  end

  defp block({"pre", _attrs, [{"code", code_attrs, code_children, _} | _], _meta}) do
    source = flatten_text(code_children) |> String.trim_trailing("\n")

    case fence_language(code_attrs) do
      "mermaid" -> [%{"type" => "diagram", "source" => source}]
      "portabledoc" -> portabledoc_fence(source)
      lang -> [code_block(source, lang)]
    end
  end

  defp block({"pre", _attrs, children, _meta}) do
    [code_block(flatten_text(children))]
  end

  defp block({"blockquote", _attrs, children, _meta}) do
    content =
      children
      |> Enum.flat_map(fn
        {"p", _, p_children, _} -> inline(p_children)
        other -> [text_node(flatten_text([other]))]
      end)
      |> Enum.intersperse(text_node(" "))

    [%{"type" => "callout", "tone" => "info", "content" => content}]
  end

  defp block({"table", _attrs, children, _meta}) do
    head =
      children
      |> find_rows("thead")
      |> Enum.at(0)

    rows = find_rows(children, "tbody")

    table = %{"type" => "table", "rows" => rows}
    [if(head, do: Map.put(table, "head", head), else: table)]
  end

  defp block({"hr", _attrs, _children, _meta}), do: [%{"type" => "divider"}]

  # Loose text at the top level (rare from GFM, possible from partial input).
  defp block(text) when is_binary(text) do
    case String.trim(text) do
      "" -> []
      trimmed -> [%{"type" => "paragraph", "content" => [text_node(trimmed)]}]
    end
  end

  # Anything else (raw html, comments, unknown tags): keep the visible text.
  defp block({_tag, _attrs, children, _meta}) do
    case String.trim(flatten_text(children)) do
      "" -> []
      text -> [%{"type" => "paragraph", "content" => [text_node(text)]}]
    end
  end

  defp block(_other), do: []

  # ── the portabledoc fence (native block escape hatch) ──────────────────

  defp portabledoc_fence(source) do
    with {:ok, decoded} <- Jason.decode(source),
         blocks when is_list(blocks) <- decoded,
         true <- blocks != [] and length(blocks) <= @max_fence_blocks,
         true <- Enum.all?(blocks, &valid_fence_block?/1) do
      blocks
    else
      _ -> [code_block(source)]
    end
  end

  # Only data-bearing display types may be spliced in from model output —
  # never structural/bound blocks (field-*, task-*, image, form widgets, …)
  # whose renderers assume editor- or resolver-provided invariants.
  defp valid_fence_block?(%{"type" => type}) when type in @allowed_fence_types, do: true
  defp valid_fence_block?(_), do: false

  # ── inline mapping ──────────────────────────────────────────────────────

  defp inline(children) when is_list(children), do: Enum.flat_map(children, &inline_node/1)
  defp inline(other), do: [text_node(flatten_text([other]))]

  defp inline_node(text) when is_binary(text), do: [text_node(text)]

  defp inline_node({"strong", _attrs, children, _meta}),
    do: [%{"type" => "strong", "children" => inline(children)}]

  defp inline_node({tag, _attrs, children, _meta}) when tag in ["em", "i"],
    do: [%{"type" => "em", "children" => inline(children)}]

  defp inline_node({"del", _attrs, children, _meta}),
    do: [%{"type" => "strikethrough", "children" => inline(children)}]

  defp inline_node({"code", _attrs, children, _meta}),
    do: [%{"type" => "code", "value" => flatten_text(children)}]

  defp inline_node({"a", attrs, children, _meta}) do
    [%{"type" => "link", "href" => attr(attrs, "href"), "children" => inline(children)}]
  end

  # Images from model output render as a link (the chat has no asset pipeline).
  defp inline_node({"img", attrs, _children, _meta}) do
    label =
      case attr(attrs, "alt") do
        "" -> attr(attrs, "src")
        alt -> alt
      end

    [%{"type" => "link", "href" => attr(attrs, "src"), "children" => [text_node(label)]}]
  end

  defp inline_node({"br", _attrs, _children, _meta}), do: [text_node(" ")]

  defp inline_node({_tag, _attrs, children, _meta}), do: inline(children)
  defp inline_node(_other), do: []

  # A list item may carry nested block children (paragraphs, sub-lists).
  # Flatten to one inline run — sub-list items joined inline keeps the chat
  # transcript compact without dropping content.
  defp list_item_inline(children) do
    children
    |> Enum.flat_map(fn
      {"p", _, p_children, _} -> inline(p_children)
      {tag, _, sub, _} when tag in ["ul", "ol"] -> nested_list_inline(sub)
      other -> inline_node(other)
    end)
  end

  defp nested_list_inline(li_nodes) do
    li_nodes
    |> Enum.filter(&match?({"li", _, _, _}, &1))
    |> Enum.flat_map(fn {"li", _, li_children, _} ->
      [text_node(" — ") | list_item_inline(li_children)]
    end)
  end

  # ── table helpers ────────────────────────────────────────────────────────

  defp find_rows(children, section_tag) do
    children
    |> Enum.filter(&match?({^section_tag, _, _, _}, &1))
    |> Enum.flat_map(fn {_, _, rows, _} -> rows end)
    |> Enum.filter(&match?({"tr", _, _, _}, &1))
    |> Enum.map(fn {"tr", _, cells, _} ->
      cells
      |> Enum.filter(fn
        {tag, _, _, _} when tag in ["td", "th"] -> true
        _ -> false
      end)
      |> Enum.map(fn {_, _, cell_children, _} -> inline(cell_children) end)
    end)
  end

  # ── leaves ───────────────────────────────────────────────────────────────

  # THE LANGUAGE FIELD IS `lang`, NOT `language`. The standalone `code` block's
  # model says so everywhere it is written or read:
  #
  #   * `StudioLive.Blocks.default_block("code")` → `%{"type" => "code",
  #     "lang" => "", "value" => ""}` (blocks.ex:231);
  #   * `build_block_patch/2` puts `lang` through `put_if_present/3`, which
  #     DROPS a nil/"" value (blocks.ex:39) — so an absent language is an
  #     absent KEY, never `"lang" => ""`;
  #   * the Studio's code-block editor renders `Map.get(@block, "lang", "")`
  #     (paper_editor.ex:1115-1118) and the canvas code node round-trips the
  #     same key (`canvas/code-node.js`).
  #
  # `Map.get("language", "")` in `Render.Compose` belongs to `code-tabs` TAB
  # ENTRIES (compose.ex `code_tab_entries/1`), a different block type. Emitting
  # `"language"` here would have written a field nothing reads.
  #
  # An absent or blank fence info string emits NO key at all, so a language-less
  # fence keeps today's exact two-key map — the shape every existing caller,
  # golden and round-trip already pins.
  defp code_block(value), do: %{"type" => "code", "value" => value}

  defp code_block(value, lang) when is_binary(lang) and lang != "",
    do: %{"type" => "code", "value" => value, "lang" => lang}

  defp code_block(value, _lang), do: code_block(value)

  defp text_node(value), do: %{"type" => "text", "value" => value}

  defp attr(attrs, name) do
    case List.keyfind(attrs || [], name, 0) do
      {^name, value} when is_binary(value) -> value
      _ -> ""
    end
  end

  defp fence_language(attrs) do
    attrs
    |> attr("class")
    |> String.split(" ", trim: true)
    |> Enum.at(0, "")
  end

  defp flatten_text(children) when is_list(children) do
    Enum.map_join(children, "", &flatten_text/1)
  end

  defp flatten_text(text) when is_binary(text), do: text
  defp flatten_text({"br", _, _, _}), do: "\n"
  defp flatten_text({_tag, _attrs, children, _meta}), do: flatten_text(children)
  defp flatten_text(_other), do: ""
end
