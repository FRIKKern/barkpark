defmodule Barkpark.Content.PortableText do
  @moduledoc """
  Portable Text blocks for a plain `richText` field (owner ruling #44,
  task-db56e998e0a5ab3b).

  Portable Text (an array of `_type: "block"` nodes with `children` spans) is
  the canonical stored value: `bp seed`, the `bp make schema` skeleton,
  `@barkpark/codegen` and the React renderer already use it. Studio Classic's
  rich-text input is a contenteditable that edits HTML, so this module is the
  conversion at the Studio boundary:

    * `to_html/1` renders stored blocks as the editor's HTML on load;
    * `from_html/1` turns the HTML the editor posts back into blocks.

  A value stored as HTML before the ruling is still read (the editor shows it
  as is) and becomes blocks the next time its document is saved in Studio.

  Supported: paragraphs (`p`, `div`), headings `h1`–`h6`, `blockquote`,
  bulleted and numbered lists (`ul`/`ol` > `li`, a list nested in an item one
  `level` deeper), line breaks (`br`, stored as
  `"\\n"` in the span text), the decorators `strong`/`b`, `em`/`i`, `u`,
  `s`/`strike`/`del`, `code`, and links (`a href`, stored as a `link` mark
  definition). Other tags are dropped and their text is kept.

  A decorator or mark definition outside that set (a `highlight`, an
  `internalLink` annotation) has no editor UI, so it rides through the HTML as
  an inert `<span data-pt-mark>` / `<span data-pt-def>` and comes back as the
  stored mark; `from_html/2` reads a def back from the stored blocks by key.

  An inline object (a block child whose `_type` is not `span`, such as the
  Sanity chip `bp import` stores) rides as an inert
  `<span data-pt-object="…" contenteditable="false">` carrying the whole
  object as JSON, and comes back verbatim. Before, it printed as bare text and
  the next edit of its block stored that text as part of a plain span
  (task-600eae4cd8a05206).

  A custom block (a top-level node whose `_type` is not `block`, such as the
  `mediaModule` or `quote` of a Sanity body) rides as an inert
  `<div data-pt-block="key" contenteditable="false">` that names its type and
  a short summary, and comes back as the stored block by `_key`. Removing the
  box removes the block. A Sanity `linkAnnotation` shows as a link to its
  target (`#internal:<id>` for a document link) and keeps every field until its
  address is changed. A new link in a value whose links are `linkAnnotation`s
  is one too (task-5fe67fc396077304).

  Keys are derived from position (`"b0"`, `"b0s1"`, `"b0m0"`), so converting
  the same HTML twice gives the same blocks. That is what lets an untouched
  field keep its stored value byte for byte. An edited field keeps it per
  block: `from_html/2` returns each stored block whose HTML the edit did not
  change as it was stored, keys and all, and an edited text block keeps the
  `_key` of the stored block at its position.
  """

  @decorators %{
    "strong" => "strong",
    "b" => "strong",
    "em" => "em",
    "i" => "em",
    "u" => "underline",
    "s" => "strike-through",
    "strike" => "strike-through",
    "del" => "strike-through",
    "code" => "code"
  }

  @block_styles %{
    "p" => "normal",
    "div" => "normal",
    "h1" => "h1",
    "h2" => "h2",
    "h3" => "h3",
    "h4" => "h4",
    "h5" => "h5",
    "h6" => "h6",
    "blockquote" => "blockquote"
  }

  @doc "True for a Portable Text array (every element a `_type: \"block\"` map)."
  @spec blocks?(term()) :: boolean()
  def blocks?([_ | _] = list), do: Enum.all?(list, &match?(%{"_type" => "block"}, &1))
  def blocks?(_), do: false

  @doc """
  True for a Portable Text array as Sanity stores a body: every element is a
  `_type: "block"` map or a keyed custom block (`_type` and `_key`, such as a
  `mediaModule` or a `quote`). A PortableDoc block list carries `"type"` and
  `"id"` instead, so it is never one.
  """
  @spec value?(term()) :: boolean()
  def value?([_ | _] = list), do: Enum.all?(list, &node?/1)
  def value?(_), do: false

  defp node?(%{"_type" => "block"}), do: true

  defp node?(%{"_type" => t, "_key" => k})
       when is_binary(t) and t != "" and is_binary(k) and k != "",
       do: true

  defp node?(_), do: false

  # ── HTML → blocks ────────────────────────────────────────────────────────

  @token ~r/<(\/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>|([^<]+)|(<)/

  @doc """
  Convert the editor's HTML to Portable Text blocks. `stored` is the field's
  current value: its mark definitions are what a `data-pt-def` span names, and
  a rebuilt block that renders to the same HTML as a stored one is that stored
  block.
  """
  @spec from_html(String.t(), [map()]) :: [map()]
  def from_html(html, stored \\ []) when is_binary(html) do
    stored = if value?(stored), do: stored, else: []

    # The inline objects the stored blocks hold, by `_key`. The editor HTML only
    # NAMES an object (its `_key` in `data-pt-object`); the object itself is
    # always taken from here, never from the client's attribute, which anyone
    # editing the HTML could rewrite.
    stored_objects =
      for %{"children" => children} <- stored,
          is_list(children),
          %{"_type" => t, "_key" => k} = o <- children,
          t != "span",
          into: %{},
          do: {k, o}

    # The custom blocks (a `mediaModule`, a `quote`) the stored value holds, by
    # `_key`. The editor shows each as an inert `<div data-pt-block="key">`;
    # like an inline object, the block itself is always the stored one.
    stored_blocks =
      for %{"_type" => t, "_key" => k} = o <- stored, t != "block", into: %{}, do: {k, o}

    state = %{
      blocks: [],
      cur: nil,
      marks: [],
      lists: [],
      links: [],
      spans: [],
      skip: 0,
      block_skip: 0,
      html: html,
      at: 0,
      till: 0,
      keep_empty: stored != [],
      objects: stored_objects,
      stored_blocks: stored_blocks,
      link_type: link_dialect(stored)
    }

    stored_defs =
      for %{"markDefs" => defs} <- stored,
          is_list(defs),
          %{"_key" => k} = d <- defs,
          into: %{},
          do: {k, d}

    # Each token's byte range rides along, so a block knows the HTML it was
    # read from (`:src`), which `keep_stored/2` compares with a stored block.
    positions = @token |> Regex.scan(html, return: :index) |> Enum.map(&hd/1)

    final =
      @token
      |> Regex.scan(html)
      |> Enum.zip(positions)
      |> Enum.reduce(state, fn {token, {at, len}}, st ->
        step(token, %{st | at: at, till: at + len})
      end)
      |> Map.merge(%{at: byte_size(html), till: byte_size(html)})
      |> flush()

    final.blocks
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {block, i} -> finalize(block, i, stored_defs, final.link_type) end)
    |> keep_stored(stored)
  end

  # The mark definition type a new link gets. A value whose stored links are
  # Sanity `linkAnnotation`s (the gyldendal.no twin) gets one too, so the site
  # that renders that type renders the new link; any other value gets `link`.
  defp link_dialect(stored) do
    annotation? =
      Enum.any?(stored, fn
        %{"markDefs" => defs} when is_list(defs) ->
          Enum.any?(defs, &match?(%{"_type" => "linkAnnotation"}, &1))

        _ ->
          false
      end)

    if annotation?, do: "linkAnnotation", else: "link"
  end

  # A rebuilt block whose HTML matches an unused stored block's is that block,
  # verbatim: the edit did not touch it.
  # A rebuilt block is the unused stored block whose own editor HTML is the
  # HTML it was read from, or else whose HTML it renders to. The first keeps a
  # block whose text the parser normalises (an empty paragraph, a leading line
  # break) when the author did not touch it. An empty block nothing matches
  # is dropped, as `from_html/1` drops it.
  defp keep_stored(blocks, []), do: for({block, _src} <- blocks, not empty?(block), do: block)

  defp keep_stored(blocks, stored) do
    indexed = Enum.map(stored, &{normalize(fragment_html(&1)), to_html([&1]), &1})

    kept =
      blocks
      |> Enum.map_reduce(indexed, fn {block, src}, left ->
        src = src && normalize(src)
        html = to_html([block])

        i =
          (src && Enum.find_index(left, &(elem(&1, 0) == src))) ||
            Enum.find_index(left, &(elem(&1, 1) == html))

        case i do
          nil -> {{:rebuilt, block}, left}
          i -> {{:kept, left |> Enum.at(i) |> elem(2)}, List.delete_at(left, i)}
        end
      end)
      |> elem(0)
      |> Enum.reject(&match?({:rebuilt, %{"_type" => "block", "children" => []}}, &1))

    adopt_keys(kept, stored)
  end

  defp empty?(%{"_type" => "block", "children" => []}), do: true
  defp empty?(_), do: false

  # The HTML one stored block shows in the editor: a list item as its `<li>`.
  # A list item's own HTML is its `<li>` up to its text's end: a nested list
  # inside it belongs to the deeper items.
  defp fragment_html(%{"listItem" => _} = b), do: "<li>" <> spans_html(b)
  defp fragment_html(b), do: to_html([b])

  # A browser serialises a `"` in text as is and a no-break space as
  # `&nbsp;`; `escape/1` writes `&quot;` and the character itself.
  defp normalize(html) do
    html
    |> String.replace("&quot;", "\"")
    |> String.replace("&nbsp;", "\u00A0")
    |> then(fn
      "<li>" <> _ = li -> String.replace_suffix(li, "</li>", "")
      other -> other
    end)
  end

  # An edited block takes the `_key` of the stored text block at its position
  # when no kept block holds that key, so editing a word does not rekey its
  # paragraph. Anything else keeps the position key `from_html/1` gave it.
  defp adopt_keys(kept, stored) do
    taken = for {:kept, %{"_key" => k}} <- kept, into: MapSet.new(), do: k

    kept
    |> Enum.with_index()
    |> Enum.map_reduce(taken, fn
      {{:kept, block}, _i}, taken ->
        {block, taken}

      {{:rebuilt, %{"_type" => "block"} = block}, i}, taken ->
        case Enum.at(stored, i) do
          %{"_type" => "block", "_key" => k} when is_binary(k) ->
            if MapSet.member?(taken, k),
              do: {block, taken},
              else: {rekey(block, k), MapSet.put(taken, k)}

          _ ->
            {block, taken}
        end

      {{:rebuilt, block}, _i}, taken ->
        {block, taken}
    end)
    |> elem(0)
  end

  defp rekey(%{"_key" => old} = block, key) do
    children =
      Enum.map(block["children"] || [], fn
        %{"_type" => "span", "_key" => k} = span when is_binary(k) ->
          %{span | "_key" => String.replace_prefix(k, old, key)}

        child ->
          child
      end)

    %{block | "_key" => key, "children" => children}
  end

  # Inside a custom block's `<div data-pt-block>` only nested divs are
  # counted, to find its close; its label is not text.
  defp step([_, close, tag | _], %{block_skip: n} = state) when n > 0 and tag != "" do
    case {close, String.downcase(tag)} do
      {"", "div"} -> %{state | block_skip: n + 1}
      {"/", "div"} -> %{state | block_skip: n - 1}
      _ -> state
    end
  end

  defp step([_, close, tag | rest], state) when tag != "" do
    attrs = Enum.at(rest, 0, "")
    tag = String.downcase(tag)

    case {close, tag} do
      {"", "div"} when is_binary(attrs) and attrs != "" ->
        case attr(attrs, "data-pt-block") do
          nil -> start_block(flush(state), "normal", nil, 0)
          key -> open_block_object(state, key)
        end

      {"", "br"} ->
        add_text(state, "\n")

      {"", t} when t in ["ul", "ol"] ->
        %{flush(state) | lists: [t | state.lists]}

      {"/", t} when t in ["ul", "ol"] ->
        %{flush(state) | lists: Enum.drop(state.lists, 1)}

      {"", "li"} ->
        start_block(flush(state), "normal", list_item(state.lists), length(state.lists))

      {"/", "li"} ->
        flush(state)

      {"", t} when is_map_key(@block_styles, t) ->
        start_block(flush(state), @block_styles[t], nil, 0)

      {"/", t} when is_map_key(@block_styles, t) ->
        flush(state)

      {"", t} when is_map_key(@decorators, t) ->
        %{state | marks: state.marks ++ [@decorators[t]]}

      {"/", t} when is_map_key(@decorators, t) ->
        %{state | marks: drop_last(state.marks, @decorators[t])}

      {"", "a"} ->
        open_link(state, attrs)

      {"/", "a"} ->
        %{state | marks: drop_last(state.marks, {:link, nil})}

      {"", "span"} ->
        open_span(state, attrs)

      {"/", "span"} ->
        close_span(state)

      _ ->
        state
    end
  end

  defp step([_, _, _, _, text | _], %{skip: 0, block_skip: 0} = state) when text != "",
    do: add_text(state, decode(text))

  defp step([_, "", "", "", "", "<"], %{skip: 0, block_skip: 0} = state),
    do: add_text(state, "<")

  defp step(_, state), do: state

  defp list_item(["ol" | _]), do: "number"
  defp list_item(["ul" | _]), do: "bullet"
  defp list_item(_), do: nil

  # A custom block: the stored block with that `_key` takes its place in the
  # list, and its label is skipped. An unknown or forged key adds nothing.
  defp open_block_object(state, key) do
    state = flush(state)

    blocks =
      case Map.get(state.stored_blocks, key) do
        %{} = object -> [{:block_object, object} | state.blocks]
        nil -> state.blocks
      end

    %{state | blocks: blocks, block_skip: 1}
  end

  defp start_block(state, style, list_item, level) do
    cur = %{
      style: style,
      list_item: list_item,
      level: level,
      spans: [],
      link_defs: [],
      from: state.at
    }

    %{state | cur: cur}
  end

  defp open_link(state, attrs) do
    href =
      case Regex.run(~r/href\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/i, attrs) do
        [_, _, dq] -> dq
        [_, _, "", sq] -> sq
        [_, _, "", "", bare] -> bare
        _ -> nil
      end

    href = decode(href || "")

    mark =
      case attr(attrs, "data-pt-def") do
        nil -> {:link, href}
        key -> {:link_def, key, href}
      end

    %{state | marks: state.marks ++ [mark]}
  end

  # A `data-pt-mark` span is a stored decorator, a `data-pt-def` span a stored
  # mark definition; any other span is styling and carries no mark.
  # An inline object span: the stored object becomes a child of the current
  # block, and its label text is skipped up to the span's close.
  defp open_span(%{skip: 0} = state, attrs) do
    case attr(attrs, "data-pt-object") do
      nil ->
        open_mark_span(state, attrs)

      json ->
        case stored_object(json, state.objects) do
          {:ok, object} ->
            state = if state.cur, do: state, else: start_block(state, "normal", nil, 0)
            cur = %{state.cur | spans: [%{object: object} | state.cur.spans]}
            %{state | cur: cur, skip: 1, spans: [:object | state.spans]}

          _ ->
            open_mark_span(state, attrs)
        end
    end
  end

  defp open_span(state, _attrs),
    do: %{state | skip: state.skip + 1, spans: [:object | state.spans]}

  # Only the `_key` is read from the client's attribute; the object is the
  # stored one with that key. An unknown or forged key is `:error`, so the span
  # falls through to a plain one and its label stays as text.
  defp stored_object(json, objects) do
    with {:ok, %{"_key" => k}} when is_binary(k) <- Jason.decode(json),
         %{} = object <- Map.get(objects, k) do
      {:ok, object}
    else
      _ -> :error
    end
  end

  defp open_mark_span(state, attrs) do
    mark =
      cond do
        name = attr(attrs, "data-pt-mark") -> name
        key = attr(attrs, "data-pt-def") -> {:def, key}
        true -> nil
      end

    marks = if mark, do: state.marks ++ [mark], else: state.marks
    %{state | marks: marks, spans: [mark | state.spans]}
  end

  defp close_span(%{spans: [:object | rest]} = state),
    do: %{state | spans: rest, skip: max(state.skip - 1, 0)}

  defp close_span(%{spans: [nil | rest]} = state), do: %{state | spans: rest}

  defp close_span(%{spans: [mark | rest]} = state),
    do: %{state | marks: drop_last(state.marks, mark), spans: rest}

  defp close_span(state), do: state

  defp attr(attrs, name) do
    case Regex.run(~r/#{name}\s*=\s*("([^"]*)"|'([^']*)')/i, attrs) do
      [_, _, dq] when dq != "" -> decode(dq)
      [_, _, "", sq] when sq != "" -> decode(sq)
      _ -> nil
    end
  end

  defp drop_last(marks, {:link, _}) do
    case Enum.find_index(
           Enum.reverse(marks),
           &(match?({:link, _}, &1) or match?({:link_def, _, _}, &1))
         ) do
      nil -> marks
      i -> List.delete_at(marks, length(marks) - 1 - i)
    end
  end

  defp drop_last(marks, mark) do
    case Enum.find_index(Enum.reverse(marks), &(&1 == mark)) do
      nil -> marks
      i -> List.delete_at(marks, length(marks) - 1 - i)
    end
  end

  defp add_text(%{cur: nil} = state, text) do
    if String.trim(text) == "" and text != "\n",
      do: state,
      else: add_text(start_block(state, "normal", nil, 0), text)
  end

  defp add_text(%{cur: cur} = state, text) do
    marks = Enum.uniq(state.marks)

    case cur.spans do
      [%{marks: ^marks, text: prev} = last | rest] ->
        %{state | cur: %{cur | spans: [%{last | text: prev <> text} | rest]}}

      spans ->
        %{state | cur: %{cur | spans: [%{marks: marks, text: text} | spans]}}
    end
  end

  defp flush(%{cur: nil} = state), do: state

  # An empty block is kept only while editing a stored value, so
  # `keep_stored/2` can match it to a stored empty paragraph.
  defp flush(%{cur: cur} = state) do
    text = cur.spans |> Enum.map_join(&Map.get(&1, :text, "")) |> String.trim()
    has_object = Enum.any?(cur.spans, &Map.has_key?(&1, :object))
    cur = Map.put(cur, :src, block_src(state, cur.from))

    cond do
      text != "" or has_object -> %{state | cur: nil, blocks: [cur | state.blocks]}
      state.keep_empty -> %{state | cur: nil, blocks: [cur | state.blocks]}
      true -> %{state | cur: nil}
    end
  end

  # The HTML a block was read from: up to and including the closing tag that
  # ends it, or up to the tag that starts the next block.
  defp block_src(%{html: html, at: at, till: till}, from) do
    to = if at < byte_size(html) and binary_part(html, at, 2) == "</", do: till, else: at
    if to > from, do: binary_part(html, from, to - from), else: ""
  end

  defp finalize({:block_object, object}, _i, _stored_defs, _link_type), do: {object, nil}

  defp finalize(cur, i, stored_defs, link_type) do
    key = "b#{i}"
    spans = cur.spans |> Enum.reverse() |> trim_edges()

    {children, defs} =
      spans
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {%{object: object}, _j}, defs ->
          {object, defs}

        {span, j}, defs ->
          {marks, defs} =
            Enum.map_reduce(span.marks, defs, fn
              {:link, href}, defs ->
                new_link(key, href, defs, link_type)

              {:link_def, k, href}, defs ->
                cond do
                  Enum.any?(defs, &(&1["_key"] == k)) -> {k, defs}
                  def = stored_defs[k] -> {k, defs ++ [edited_link_def(def, href)]}
                  true -> new_link(key, href, defs, link_type)
                end

              {:def, k}, defs ->
                cond do
                  Enum.any?(defs, &(&1["_key"] == k)) -> {k, defs}
                  def = stored_defs[k] -> {k, defs ++ [def]}
                  true -> {nil, defs}
                end

              mark, defs ->
                {mark, defs}
            end)

          marks = Enum.reject(marks, &is_nil/1)

          {%{"_type" => "span", "_key" => "#{key}s#{j}", "text" => span.text, "marks" => marks},
           defs}
      end)

    base = %{
      "_type" => "block",
      "_key" => key,
      "style" => cur.style,
      "markDefs" => defs,
      "children" => children
    }

    block =
      case cur.list_item do
        nil -> base
        item -> Map.merge(base, %{"listItem" => item, "level" => max(cur.level, 1)})
      end

    {block, cur[:src]}
  end

  defp new_link(key, href, defs, link_type) do
    case Enum.find(defs, &(link_def_href(&1) == href and &1["_type"] == link_type)) do
      %{"_key" => k} ->
        {k, defs}

      nil ->
        k = free_key(key, defs)
        {k, defs ++ [new_link_def(link_type, k, href)]}
    end
  end

  defp new_link_def("linkAnnotation", k, href),
    do: Map.merge(%{"_type" => "linkAnnotation", "_key" => k}, annotation_target(href))

  defp new_link_def(_link, k, href), do: %{"_type" => "link", "_key" => k, "href" => href}

  # A stored link whose address the editor did not change is kept as stored.
  # A changed address replaces the target and keeps the rest (`openInNewTab`).
  defp edited_link_def(%{"_type" => "linkAnnotation"} = def, href) do
    if link_def_href(def) == href do
      def
    else
      def
      |> Map.drop(
        ~w(linkType url href email internalLink damFileUrl damFileName isExternal isMailto)
      )
      |> Map.merge(annotation_target(href))
    end
  end

  defp edited_link_def(%{"_type" => "link"} = def, href), do: Map.put(def, "href", href)
  defp edited_link_def(def, _href), do: def

  defp annotation_target("mailto:" <> email), do: %{"linkType" => "email", "email" => email}
  defp annotation_target(href), do: %{"linkType" => "external", "url" => href}

  # The address a link mark definition shows in the editor. A Sanity
  # `linkAnnotation` keeps its target in one of four fields by `linkType`; an
  # internal link names a document, shown as `#internal:<id>`.
  defp link_def_href(%{"_type" => "link", "href" => href}) when is_binary(href), do: href

  defp link_def_href(%{"_type" => "linkAnnotation"} = def) do
    cond do
      def["linkType"] == "email" or def["isMailto"] == true ->
        if is_binary(def["email"]), do: "mailto:" <> def["email"], else: nil

      def["linkType"] == "dam" ->
        def["damFileUrl"]

      match?(%{"_ref" => ref} when is_binary(ref), def["internalLink"]) and
          def["linkType"] in [nil, "internal"] ->
        "#internal:" <> def["internalLink"]["_ref"]

      is_binary(def["url"]) ->
        def["url"]

      is_binary(def["href"]) ->
        def["href"]

      true ->
        nil
    end
  end

  defp link_def_href(_def), do: nil

  defp free_key(key, defs, n \\ 0) do
    k = "#{key}m#{n}"
    if Enum.any?(defs, &(&1["_key"] == k)), do: free_key(key, defs, n + 1), else: k
  end

  # Leading/trailing whitespace of a block is markup, not text.
  defp trim_edges([]), do: []

  defp trim_edges(spans) do
    spans
    |> List.update_at(0, &trim_span(&1, :leading))
    |> List.update_at(-1, &trim_span(&1, :trailing))
    |> Enum.reject(&(Map.get(&1, :text) == ""))
  end

  defp trim_span(%{text: text} = span, :leading), do: %{span | text: String.trim_leading(text)}
  defp trim_span(%{text: text} = span, :trailing), do: %{span | text: String.trim_trailing(text)}
  defp trim_span(object, _side), do: object

  defp decode(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&amp;", "&")
  end

  # ── blocks → HTML ────────────────────────────────────────────────────────

  @doc "Render Portable Text blocks as the editor's HTML."
  @spec to_html([map()]) :: String.t()
  def to_html(blocks) when is_list(blocks) do
    blocks
    |> Enum.chunk_by(&(list_kind(&1) != nil))
    |> Enum.map_join(fn
      [first | _] = group ->
        if list_kind(first),
          do: lists_html(group, 1),
          else: Enum.map_join(group, &block_html/1)
    end)
  end

  # List items nest by `level`: an item deeper than the one before it goes in
  # a `<ul>`/`<ol>` inside that item's `<li>`, which `from_html/2` reads back as
  # the same level (its depth in open lists). A run of one kind is one list.
  defp lists_html(items, level) do
    items
    |> split_items(level)
    |> Enum.chunk_by(fn {item, kids} -> list_kind(item || hd(kids)) end)
    |> Enum.map_join(fn [{item, kids} | _] = run ->
      kind = list_kind(item || hd(kids))

      "<#{kind}>" <>
        Enum.map_join(run, fn {item, kids} ->
          "<li>" <>
            if(item, do: spans_html(item), else: "") <>
            if(kids == [], do: "", else: lists_html(kids, level + 1)) <> "</li>"
        end) <> "</#{kind}>"
    end)
  end

  # `[{item, deeper_items}]` at this level. An item deeper than the level with
  # no item above it gets an empty `<li>` to hang from (`item` nil).
  defp split_items(items, level) do
    items
    |> Enum.reduce([], fn b, acc ->
      cond do
        item_level(b) <= level ->
          [{b, []} | acc]

        acc == [] ->
          [{nil, [b]}]

        true ->
          [{item, kids} | rest] = acc
          [{item, kids ++ [b]} | rest]
      end
    end)
    |> Enum.reverse()
  end

  defp item_level(%{"level" => n}) when is_integer(n) and n > 0, do: n
  defp item_level(_), do: 1

  defp list_kind(%{"listItem" => "number"}), do: "ol"
  defp list_kind(%{"listItem" => _}), do: "ul"
  defp list_kind(_), do: nil

  defp block_html(%{"_type" => "block"} = b) do
    tag =
      case b["style"] do
        "h" <> n when n in ~w(1 2 3 4 5 6) -> "h" <> n
        "blockquote" -> "blockquote"
        _ -> "p"
      end

    "<#{tag}>" <> spans_html(b) <> "</#{tag}>"
  end

  # A custom block (a `mediaModule`, a `quote`) shows as an inert labelled box
  # naming its `_key`; `from_html/2` puts the stored block back in its place.
  defp block_html(%{"_type" => type, "_key" => key} = object)
       when is_binary(type) and is_binary(key) do
    ~s(<div data-pt-block="#{escape(key)}" data-pt-type="#{escape(type)}" ) <>
      ~s(class="bp-pt-block" contenteditable="false">) <>
      ~s(<strong>#{escape(type)}</strong>) <>
      case block_summary(object) do
        nil -> ""
        text -> " " <> escape(text)
      end <> "</div>"
  end

  defp block_html(_), do: ""

  @summary_keys ~w(title heading label quote text bodyText caption alt name anchorId url)

  # A short readable summary of a custom block: its first text field, at the
  # top level or one level down (an image's caption), else how many items a
  # list field holds.
  defp block_summary(object) do
    nested = for {_k, %{} = v} <- Enum.sort(object), do: v

    text =
      Enum.find_value([object | nested], fn map ->
        Enum.find_value(@summary_keys, fn k ->
          case map[k] do
            v when is_binary(v) -> if String.trim(v) != "", do: truncate(v), else: nil
            _ -> nil
          end
        end)
      end)

    text ||
      Enum.find_value(Enum.sort(object), fn
        {k, [_ | _] = list} when k not in ["markDefs", "children"] -> "#{k}: #{length(list)}"
        _ -> nil
      end)
  end

  defp truncate(text) do
    text = String.trim(text)
    if String.length(text) > 120, do: String.slice(text, 0, 117) <> "...", else: text
  end

  defp spans_html(%{"children" => children} = b) when is_list(children) do
    defs = Map.new(b["markDefs"] || [], &{&1["_key"], &1})

    Enum.map_join(children, fn
      %{"_type" => type} = object when is_binary(type) and type != "span" ->
        ~s(<span data-pt-object="#{attr_escape(Jason.encode!(object))}" contenteditable="false">) <>
          escape(object_label(object)) <> "</span>"

      %{"text" => text} = span when is_binary(text) ->
        inner = text |> escape() |> String.replace("\n", "<br>")

        (span["marks"] || [])
        |> Enum.reverse()
        |> Enum.reduce(inner, fn mark, acc -> wrap(mark, acc, defs) end)

      _ ->
        ""
    end)
  end

  defp spans_html(_), do: ""

  # The label an inline object shows: the readers' rule (inline.ex
  # inline_object_text/1), else its type.
  defp object_label(object) do
    Enum.find_value(~w(text title label name value), "[#{object["_type"]}]", fn key ->
      case object[key] do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  end

  defp wrap("strong", acc, _), do: "<strong>#{acc}</strong>"
  defp wrap("em", acc, _), do: "<em>#{acc}</em>"
  defp wrap("underline", acc, _), do: "<u>#{acc}</u>"
  defp wrap("strike-through", acc, _), do: "<s>#{acc}</s>"
  defp wrap("code", acc, _), do: "<code>#{acc}</code>"

  defp wrap(key, acc, defs) when is_binary(key) do
    case defs[key] do
      %{"_type" => "link", "href" => href} when is_binary(href) ->
        ~s(<a href="#{escape(href)}">#{acc}</a>)

      %{"_type" => "linkAnnotation"} = def ->
        case link_def_href(def) do
          href when is_binary(href) ->
            ~s(<a href="#{escape(href)}" data-pt-def="#{escape(key)}">#{acc}</a>)

          nil ->
            ~s(<span data-pt-def="#{escape(key)}">#{acc}</span>)
        end

      %{} ->
        ~s(<span data-pt-def="#{escape(key)}">#{acc}</span>)

      nil ->
        ~s(<span data-pt-mark="#{escape(key)}">#{acc}</span>)
    end
  end

  defp wrap(_mark, acc, _defs), do: acc

  # An attribute value (the object's JSON) through Phoenix.HTML's escaper, which
  # also escapes `'`; `decode/1` reads every entity it emits back.
  defp attr_escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
