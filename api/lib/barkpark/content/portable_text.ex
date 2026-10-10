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
  bulleted and numbered lists (`ul`/`ol` > `li`), line breaks (`br`, stored as
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

  Keys are derived from position (`"b0"`, `"b0s1"`, `"b0m0"`), so converting
  the same HTML twice gives the same blocks. That is what lets an untouched
  field keep its stored value byte for byte. An edited field keeps it per
  block: `from_html/2` returns each stored block whose HTML the edit did not
  change as it was stored, keys and all.
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
    stored = if blocks?(stored), do: stored, else: []

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

    state = %{
      blocks: [],
      cur: nil,
      marks: [],
      lists: [],
      links: [],
      spans: [],
      skip: 0,
      objects: stored_objects
    }

    stored_defs =
      for %{"markDefs" => defs} <- stored,
          is_list(defs),
          %{"_key" => k} = d <- defs,
          into: %{},
          do: {k, d}

    @token
    |> Regex.scan(html)
    |> Enum.reduce(state, &step/2)
    |> flush()
    |> Map.fetch!(:blocks)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {block, i} -> finalize(block, i, stored_defs) end)
    |> keep_stored(stored)
  end

  # A rebuilt block whose HTML matches an unused stored block's is that block,
  # verbatim: the edit did not touch it.
  defp keep_stored(blocks, []), do: blocks

  defp keep_stored(blocks, stored) do
    stored = Enum.map(stored, &{to_html([&1]), &1})

    blocks
    |> Enum.map_reduce(stored, fn block, left ->
      html = to_html([block])

      case Enum.find_index(left, &(elem(&1, 0) == html)) do
        nil -> {block, left}
        i -> {left |> Enum.at(i) |> elem(1), List.delete_at(left, i)}
      end
    end)
    |> elem(0)
  end

  defp step([_, close, tag | rest], state) when tag != "" do
    attrs = Enum.at(rest, 0, "")
    tag = String.downcase(tag)

    case {close, tag} do
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

  defp step([_, _, _, _, text | _], %{skip: 0} = state) when text != "",
    do: add_text(state, decode(text))

  defp step([_, "", "", "", "", "<"], %{skip: 0} = state), do: add_text(state, "<")
  defp step(_, state), do: state

  defp list_item(["ol" | _]), do: "number"
  defp list_item(["ul" | _]), do: "bullet"
  defp list_item(_), do: nil

  defp start_block(state, style, list_item, level) do
    %{state | cur: %{style: style, list_item: list_item, level: level, spans: [], link_defs: []}}
  end

  defp open_link(state, attrs) do
    href =
      case Regex.run(~r/href\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/i, attrs) do
        [_, _, dq] -> dq
        [_, _, "", sq] -> sq
        [_, _, "", "", bare] -> bare
        _ -> nil
      end

    %{state | marks: state.marks ++ [{:link, decode(href || "")}]}
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
    case Enum.find_index(Enum.reverse(marks), &match?({:link, _}, &1)) do
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

  defp flush(%{cur: cur} = state) do
    text = cur.spans |> Enum.map_join(&Map.get(&1, :text, "")) |> String.trim()
    has_object = Enum.any?(cur.spans, &Map.has_key?(&1, :object))

    if text == "" and not has_object,
      do: %{state | cur: nil},
      else: %{state | cur: nil, blocks: [cur | state.blocks]}
  end

  defp finalize(cur, i, stored_defs) do
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
                case Enum.find(defs, &(&1["_type"] == "link" and &1["href"] == href)) do
                  %{"_key" => k} ->
                    {k, defs}

                  nil ->
                    k = free_key(key, defs)
                    {k, defs ++ [%{"_type" => "link", "_key" => k, "href" => href}]}
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

    case cur.list_item do
      nil -> base
      item -> Map.merge(base, %{"listItem" => item, "level" => max(cur.level, 1)})
    end
  end

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
    |> Enum.chunk_by(&list_kind/1)
    |> Enum.map_join(fn
      [first | _] = group ->
        case list_kind(first) do
          nil ->
            Enum.map_join(group, &block_html/1)

          kind ->
            "<#{kind}>" <>
              Enum.map_join(group, &("<li>" <> spans_html(&1) <> "</li>")) <> "</#{kind}>"
        end
    end)
  end

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

  defp block_html(_), do: ""

  defp spans_html(%{"children" => children} = b) when is_list(children) do
    defs = Map.new(b["markDefs"] || [], &{&1["_key"], &1})

    Enum.map_join(children, fn
      %{"_type" => type} = object when is_binary(type) and type != "span" ->
        ~s(<span data-pt-object="#{escape(Jason.encode!(object))}" contenteditable="false">) <>
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

      %{} ->
        ~s(<span data-pt-def="#{escape(key)}">#{acc}</span>)

      nil ->
        ~s(<span data-pt-mark="#{escape(key)}">#{acc}</span>)
    end
  end

  defp wrap(_mark, acc, _defs), do: acc

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
