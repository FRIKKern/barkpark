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
      verbatim when `FromMarkdown.Fence` lets it. This is the escape hatch
      that lets the model deliberately use rich native blocks
      (callout/table/chart/stats). Any other fence degrades to a plain code
      block — never an error.

  `@portable-doc/text` `fromMarkdown` gives the same blocks for the same
  Markdown; the shared cases are the golden pack's `from-markdown/` files
  (source: `test/support/fixtures/from-markdown.json`). The rules they pin:

    * only URLs the renderer allows become links or image links; any other
      keeps its text (`FromMarkdown.Url`);
    * a hard line break is `"\\n"` in the text, a soft one a space;
    * raw HTML keeps its visible text only (`FromMarkdown.Html`);
    * entity references in text, link URLs and raw HTML are decoded, once
      (`FromMarkdown.Entities`); code spans and code blocks keep them as typed;
    * a quote whose last paragraph is `— Name` gets `cite`, and an emphasised
      paragraph right after a mermaid fence is the diagram's `caption`;
    * a list item's blocks join with one space, and a nested list stays a
      list in the item's `children`.

  The converter is fail-soft end to end: unknown AST nodes flatten to text,
  and a parser crash or an invalid result degrades the whole reply to one
  code block. Output blocks contain only data — all HTML escaping happens
  downstream in the render walk, exactly as for persisted paper blocks.
  """

  alias Barkpark.PortableDoc.FromMarkdown.{Entities, Fence, Html, Url}
  alias Barkpark.PortableDoc.Validate

  # A list nested deeper than this is kept as its item's plain text.
  @max_nest 50

  # Nodes that sit beside a tight list item's inline text as blocks of their own.
  @block_tags ~w(p ul ol pre blockquote table hr h1 h2 h3 h4 h5 h6 div)

  @doc """
  Convert a markdown string to a PortableDoc block list. Never raises.

  The blocks always pass `Barkpark.PortableDoc.Validate`; if they would not, or
  the parser fails, the whole input comes back as one code block. Non-string
  input gives `[]`.
  """
  @spec blocks(term()) :: [map()]
  def blocks(markdown), do: markdown |> read() |> elem(0)

  @doc """
  `blocks/1` with the ` ```portabledoc ` fences it kept back as code blocks,
  in order: each fence's source and the path of the code block that stands in
  for it. Only a top-level fence is read as one (a fence in a list item or a
  quote joins its text). When the whole input falls back to one code block the
  list is empty.
  """
  @spec read(term()) :: {[map()], [%{source: String.t(), path: String.t()}]}
  def read(markdown) when is_binary(markdown) do
    converted =
      case EarmarkParser.as_ast(markdown, gfm: true, smartypants: false) do
        {:ok, ast, _messages} -> convert(ast)
        {:error, ast, _messages} when is_list(ast) -> convert(ast)
        _ -> :error
      end

    case converted do
      {blocks, kept} when is_list(blocks) ->
        if Validate.validate(%{"blocks" => blocks}) == :ok,
          do: {blocks, kept},
          else: {fallback(markdown), []}

      _ ->
        {fallback(markdown), []}
    end
  rescue
    _ -> {fallback(markdown), []}
  end

  def read(_markdown), do: {[], []}

  defp fallback(markdown),
    do: if(String.trim(markdown) == "", do: [], else: [code_block(markdown)])

  # The top-level walk: portabledoc fences share the ids they have used, and an
  # emphasised paragraph right after a mermaid fence is the diagram's caption.
  # `at` counts the blocks so far, so a kept-back fence knows its code block's
  # index.
  defp convert(ast), do: convert(ast, {MapSet.new(), [], 0}, [])

  defp convert([], {_ids, kept, _at}, acc),
    do: {acc |> Enum.reverse() |> Enum.concat(), Enum.reverse(kept)}

  defp convert([node | rest], {ids, kept, at}, acc) do
    {blocks, ids, kept} = top_block(node, ids, kept, at)
    state = {ids, kept, at + length(blocks)}

    with [%{"type" => "diagram"} = diagram] <- blocks,
         true <- mermaid?(node),
         [next | after_next] <- rest,
         text when text != "" <- caption(next) do
      convert(after_next, state, [[Map.put(diagram, "caption", text)] | acc])
    else
      _ -> convert(rest, state, [blocks | acc])
    end
  end

  defp mermaid?({"pre", _, [{"code", code_attrs, _, _} | _], meta}),
    do: not is_map_key(meta, :verbatim) and fence_language(code_attrs) == "mermaid"

  defp mermaid?(_node), do: false

  defp top_block(
         {"pre", _, [{"code", code_attrs, code_children, _} | _], meta} = node,
         ids,
         kept,
         at
       )
       when not is_map_key(meta, :verbatim) do
    if fence_language(code_attrs) == "portabledoc" do
      source = code_children |> flatten_text() |> String.trim_trailing("\n")

      case Fence.splice(source, ids) do
        {:ok, blocks, ids} -> {blocks, ids, kept}
        :error -> {[code_block(source)], ids, [%{source: source, path: "/blocks/#{at}"} | kept]}
      end
    else
      {block(node), ids, kept}
    end
  end

  defp top_block(node, ids, kept, _at), do: {block(node), ids, kept}

  # A paragraph that is one emphasised run is a caption.
  defp caption({"p", _, children, meta}) when not is_map_key(meta, :verbatim) do
    case Enum.reject(children, &(&1 == "")) do
      [{tag, _, em_children, _}] when tag in ["em", "i"] ->
        em_children |> inline() |> plain_text() |> String.trim()

      _ ->
        ""
    end
  end

  defp caption(_node), do: ""

  # ── block-level mapping ─────────────────────────────────────────────────

  # An HTML comment shows nothing.
  defp block({:comment, _attrs, _children, _meta}), do: []

  # Raw HTML: its visible text as a paragraph (Html.block_text/1).
  defp block({tag, _attrs, children, %{verbatim: true}}) do
    if String.downcase(to_string(tag)) in ["script", "style"] do
      []
    else
      children
      |> Enum.map_join("\n", &flatten_text/1)
      |> Html.block_text()
      |> Entities.decode()
      |> String.trim()
      |> text_paragraph()
    end
  end

  defp block({"h" <> n, _attrs, children, _meta}) when n in ~w(1 2 3 4 5 6) do
    level = String.to_integer(n)
    text = children |> inline() |> plain_text() |> String.trim()
    [%{"type" => "heading", "level" => level, "text" => text}]
  end

  defp block({"p", _attrs, children, _meta}) do
    case inline(children) do
      [] -> []
      content -> [%{"type" => "paragraph", "content" => content}]
    end
  end

  defp block({tag, _, _, _} = node) when tag in ["ul", "ol"], do: [list(node, 0)]

  defp block({"pre", _attrs, [{"code", code_attrs, code_children, _} | _], _meta}) do
    source = flatten_text(code_children) |> String.trim_trailing("\n")

    case fence_language(code_attrs) do
      "mermaid" -> [%{"type" => "diagram", "source" => source}]
      lang -> [code_block(source, lang)]
    end
  end

  defp block({"pre", _attrs, children, _meta}) do
    [code_block(flatten_text(children))]
  end

  defp block({"blockquote", _attrs, children, _meta}) do
    # `> ` is a plain quote, and `> [!note] ` an Obsidian-style callout — the same
    # split the canvas makes (owner ruling 2026-10-03 #62, Barkdown#16). This used
    # to turn every quote into an info callout. A last paragraph `— Name` is the
    # quote's cite, as the Markdown writer emits it.
    case callout_marker(quote_content(children)) do
      {tone, rest} -> [%{"type" => "callout", "tone" => tone, "content" => rest}]
      nil -> [quote_block(children)]
    end
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
    text |> List.wrap() |> inline() |> plain_text() |> String.trim() |> text_paragraph()
  end

  # Anything else (comments, unknown tags): keep the visible text.
  defp block({_tag, _attrs, children, _meta}) do
    children |> inline() |> plain_text() |> String.trim() |> text_paragraph()
  end

  defp block(_other), do: []

  defp text_paragraph(""), do: []
  defp text_paragraph(text), do: [%{"type" => "paragraph", "content" => [text_node(text)]}]

  # ── quotes ──────────────────────────────────────────────────────────────

  defp quote_block(children) do
    with [_ | _] = before <- Enum.drop(children, -1),
         {"p", _, _, _} = last <- List.last(children),
         [_, cite] <- Regex.run(~r/^— (.+)$/s, String.trim(child_text(last))) do
      %{"type" => "blockquote", "content" => quote_content(before), "cite" => cite}
    else
      _ -> %{"type" => "blockquote", "content" => quote_content(children)}
    end
  end

  # A quote's children as one inline run, joined by a space.
  defp quote_content(children) do
    children
    |> Enum.map(&child_inline/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([text_node(" ")])
    |> Enum.concat()
    |> merge()
  end

  # A paragraph or heading child as its inline content; any other as its text.
  defp child_inline({tag, _, children, meta} = node) when is_map(meta) do
    if tag in ~w(p h1 h2 h3 h4 h5 h6) and not is_map_key(meta, :verbatim),
      do: inline(children),
      else: merge([text_node(String.trim(child_text(node)))])
  end

  defp child_inline(other), do: merge([text_node(String.trim(child_text(other)))])

  # The plain visible text of a block child.
  defp child_text({:comment, _, _, _}), do: ""

  defp child_text({_tag, _, children, %{verbatim: true}}),
    do: children |> Enum.map_join("\n", &flatten_text/1) |> Html.block_text() |> Entities.decode()

  defp child_text({tag, _, children, _}) when tag in ["ul", "ol"] do
    children
    |> Enum.filter(&match?({"li", _, _, _}, &1))
    |> Enum.map_join(" ", fn {"li", _, li, _} -> li |> item_runs() |> runs_text() end)
  end

  defp child_text({"pre", _, children, _}), do: flatten_text(children)

  defp child_text({_tag, _, children, _}) when is_list(children),
    do: children |> item_runs() |> runs_text()

  defp child_text(text) when is_binary(text), do: [text] |> inline() |> plain_text()
  defp child_text(_), do: ""

  defp runs_text(runs) do
    runs
    |> Enum.map(fn
      {:inline, nodes} -> nodes |> inline() |> plain_text()
      {:block, node} -> child_text(node)
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # `[!type]` (optionally `[!type]+` / `[!type]-`) at the head of a quote's first
  # text run → {tone, content without the marker}; else nil. Tone aliases mirror
  # the canvas (paper-editor/src/tone.js): note → info, warn → warning,
  # error → danger, unknown → info.
  @callout_tones ~w(info success warning danger neutral)
  @callout_tone_aliases %{"note" => "info", "warn" => "warning", "error" => "danger"}

  defp callout_marker([%{"type" => "text", "value" => value} = first | rest])
       when is_binary(value) do
    case Regex.run(~r/^\[!(\w+)\][+-]?[ \t]*(.*)$/s, value) do
      [_, raw, tail] ->
        {callout_tone(String.downcase(raw)), callout_body(first, tail, rest)}

      _ ->
        nil
    end
  end

  defp callout_marker(_content), do: nil

  defp callout_tone(tone) when tone in @callout_tones, do: tone
  defp callout_tone(tone), do: Map.get(@callout_tone_aliases, tone, "info")

  defp callout_body(first, tail, rest), do: merge([%{first | "value" => tail} | rest])

  # `[ ] rest` / `[x] rest` at the head of an item's inline → {content, checked}; else nil.
  defp task_item([%{"type" => "text", "value" => value} = first | rest]) when is_binary(value) do
    case Regex.run(~r/^\[( |x|X)\]\s+(.*)$/s, value) do
      [_, mark, tail] ->
        %{
          "content" => merge([Map.put(first, "value", tail) | rest]),
          "checked" => mark in ["x", "X"]
        }

      _ ->
        nil
    end
  end

  defp task_item(_), do: nil

  # An ordered list's first number rides the block as `start` (`5. five` → 5).
  # The parser names it only when it is not 1, so a list numbered from 1 keeps
  # its shape; every renderer reads a missing `start` as 1.
  defp put_list_start(block, "ol", attrs) do
    with {_, raw} <- List.keyfind(attrs, "start", 0),
         {start, ""} <- Integer.parse(raw),
         true <- start != 1 do
      Map.put(block, "start", start)
    else
      _ -> block
    end
  end

  defp put_list_start(block, _tag, _attrs), do: block

  # ── lists ───────────────────────────────────────────────────────────────

  # A list block. An item's blocks join as one inline run, a space apart, and its
  # nested lists stay lists in the item's `children`; past @max_nest a nested list
  # is kept as its text.
  defp list({tag, attrs, children, _meta}, depth) do
    items =
      for {"li", _, li_children, _} <- children, do: list_item(li_children, depth)

    # GitHub task syntax (`- [ ] ` / `- [x] `) makes the whole list a checklist.
    tasks =
      if tag == "ul", do: Enum.map(items, fn {content, _} -> task_item(content) end), else: []

    if Enum.any?(tasks, &(&1 != nil)) do
      checklist_items =
        Enum.zip_with(items, tasks, fn {content, nested}, task ->
          with_children(task || %{"content" => content, "checked" => false}, nested)
        end)

      %{"type" => "list", "ordered" => false, "task" => true, "items" => checklist_items}
    else
      items =
        Enum.map(items, fn
          {content, []} -> content
          {content, nested} -> %{"content" => content, "children" => nested}
        end)

      put_list_start(%{"type" => "list", "ordered" => tag == "ol", "items" => items}, tag, attrs)
    end
  end

  defp with_children(item, []), do: item
  defp with_children(item, nested), do: Map.put(item, "children", nested)

  # {inline content, nested list blocks} for one list item.
  defp list_item(children, depth) do
    {runs, nested} =
      children
      |> item_runs()
      |> Enum.reduce({[], []}, fn
        {:block, {tag, _, _, meta} = sub}, {runs, nested}
        when tag in ["ul", "ol"] and not is_map_key(meta, :verbatim) ->
          if depth >= @max_nest,
            do: {[[text_node(String.trim(child_text(sub)))] | runs], nested},
            else: {runs, [list(sub, depth + 1) | nested]}

        run, {runs, nested} ->
          {[run_inline(run) | runs], nested}
      end)

    content =
      runs
      |> Enum.reverse()
      |> Enum.reject(&(&1 == []))
      |> Enum.intersperse([text_node(" ")])
      |> Enum.concat()
      |> merge()

    {content, Enum.reverse(nested)}
  end

  defp run_inline({:inline, nodes}), do: inline(nodes)

  defp run_inline({:block, {"pre", _, children, _}}),
    do: [%{"type" => "code", "value" => children |> flatten_text() |> String.trim_trailing("\n")}]

  defp run_inline({:block, node}), do: child_inline(node)

  # A tight item holds its text inline beside block nodes: group the inline
  # nodes into runs, each block node a run of its own.
  defp item_runs(children) do
    children
    |> Enum.chunk_while(
      [],
      fn
        {tag, _, _, meta} = node, acc when tag in @block_tags or is_map_key(meta, :verbatim) ->
          {:cont, flush(acc) ++ [{:block, node}], []}

        node, acc ->
          {:cont, [node | acc]}
      end,
      fn acc -> {:cont, flush(acc), []} end
    )
    |> Enum.concat()
  end

  defp flush([]), do: []
  defp flush(acc), do: [{:inline, Enum.reverse(acc)}]

  # ── inline mapping ──────────────────────────────────────────────────────

  # Inline nodes as PortableDoc inline content: raw inline HTML keeps its visible
  # text (Html.inline_text/2), a soft line break is a space, a hard one "\n",
  # entity references are decoded (Entities, after the breaks, so `&#10;` stays
  # a newline), and neighbouring text nodes join.
  defp inline(children) when is_list(children) do
    children
    |> Enum.flat_map_reduce(nil, fn
      text, skipping when is_binary(text) ->
        {visible, skipping} = Html.inline_text(text, skipping)
        {[text_node(visible |> soft_breaks() |> Entities.decode())], skipping}

      _node, skipping when is_binary(skipping) ->
        {[], skipping}

      node, nil ->
        {inline_node(node), nil}
    end)
    |> elem(0)
    |> merge()
  end

  defp inline(other), do: inline([other])

  defp soft_breaks(text), do: String.replace(text, ~r/[ \t]*\n[ \t]*/, " ")

  defp inline_node({"strong", _attrs, children, _meta}), do: wrap("strong", children)

  defp inline_node({tag, _attrs, children, _meta}) when tag in ["em", "i"],
    do: wrap("em", children)

  defp inline_node({"del", _attrs, children, _meta}), do: wrap("strikethrough", children)

  defp inline_node({"code", _attrs, children, _meta}),
    do: [%{"type" => "code", "value" => flatten_text(children)}]

  defp inline_node({"a", attrs, children, _meta}),
    do: link(Entities.decode(attr(attrs, "href")), inline(children))

  # Images from model output render as a link (the chat has no asset pipeline).
  defp inline_node({"img", attrs, _children, _meta}) do
    src = Entities.decode(attr(attrs, "src"))

    label =
      case Entities.decode(attr(attrs, "alt")) do
        "" -> src
        alt -> alt
      end

    link(src, [text_node(label)])
  end

  defp inline_node({"br", _attrs, _children, _meta}), do: [text_node("\n")]

  defp inline_node({:comment, _attrs, _children, _meta}), do: []
  defp inline_node({_tag, _attrs, children, _meta}) when is_list(children), do: inline(children)
  defp inline_node(_other), do: []

  defp wrap(type, children) do
    case inline(children) do
      [] -> []
      inner -> [%{"type" => type, "children" => inner}]
    end
  end

  # A link only to a URL the renderer allows; any other keeps its text.
  defp link(href, children) do
    case Url.safe(href) do
      nil -> children
      url -> [%{"type" => "link", "href" => url, "children" => children_or_url(children, url)}]
    end
  end

  defp children_or_url([], url), do: [text_node(url)]
  defp children_or_url(children, _url), do: children

  # Join neighbouring text nodes and drop empty ones.
  defp merge(nodes) do
    nodes
    |> Enum.reduce([], fn
      %{"type" => "text", "value" => ""}, acc ->
        acc

      %{"type" => "text", "value" => value}, [%{"type" => "text", "value" => prev} | acc]
      when is_binary(value) and is_binary(prev) ->
        [text_node(prev <> value) | acc]

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
  end

  # The plain text of inline content.
  defp plain_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &plain_text/1)
  defp plain_text(%{"value" => value}) when is_binary(value), do: value
  defp plain_text(%{"children" => children}), do: plain_text(children)
  defp plain_text(_), do: ""

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

  # The first word of a fence's info string, as typed: EarmarkParser escapes
  # `&` and `<` in it (`_attribute_escape/1`), so that is undone here.
  defp fence_language(attrs) do
    attrs
    |> attr("class")
    |> String.replace("&lt;", "<")
    |> String.replace("&amp;", "&")
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
