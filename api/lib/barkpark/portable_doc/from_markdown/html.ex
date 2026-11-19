defmodule Barkpark.PortableDoc.FromMarkdown.Html do
  @moduledoc """
  The visible text of raw HTML in Markdown, for `Barkpark.PortableDoc.FromMarkdown`.

  EarmarkParser hands raw HTML through as text: an HTML block is a node marked
  `verbatim: true` holding its source lines, and inline HTML stays inside the
  paragraph's text strings. Only the visible text is kept: tags, comments,
  processing instructions, declarations and CDATA go, and so does the text inside
  `<script>` and `<style>`. `@portable-doc/text` `fromMarkdown` keeps the same text
  (`visibleText` and `rawTag` in its `from-markdown-inline.js`).

  Inline, a `<` starts a tag only where CommonMark's raw-HTML grammar says so, so
  `1 < 2` stays text. A `<script>` or `<style>` opened in one text string hides
  what follows until its closing tag, across the inline nodes of one run.
  """

  @raw_tags ~w(script style)

  # CommonMark raw inline HTML: open tag, closing tag, comment, processing
  # instruction, declaration, CDATA. Possessive and lazy quantifiers keep a
  # hostile run of `<a b b b …` linear.
  @attr ~S{(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*+(?:\s*=\s*(?:[^\s"'=<>`]++|'[^']*+'|"[^"]*+"))?)*+}
  @inline_html Regex.compile!(
                 "<(?:([A-Za-z][A-Za-z0-9-]*+)" <>
                   @attr <>
                   ~S{\s*(/?)>|/([A-Za-z][A-Za-z0-9-]*+)\s*>|!--.*?-->|\?.*?\?>|![A-Za-z][^>]*>|!\[CDATA\[.*?\]\]>)},
                 "s"
               )

  @typedoc "The raw-text tag being skipped (`\"script\"` / `\"style\"`), or nil."
  @type skipping :: String.t() | nil

  @doc """
  The visible text of one inline text string, given the raw-text tag being
  skipped when it starts; returns the text and the tag still being skipped.
  """
  @spec inline_text(String.t(), skipping()) :: {String.t(), skipping()}
  def inline_text(text, skipping), do: inline_text(text, skipping, [])

  defp inline_text("", skipping, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), skipping}

  defp inline_text(text, skipping, acc) when is_binary(skipping) do
    case Regex.run(~r{</#{skipping}\s*>}i, text, return: :index) do
      [{start, len}] ->
        rest = binary_part(text, start + len, byte_size(text) - start - len)
        inline_text(rest, nil, acc)

      nil ->
        {IO.iodata_to_binary(Enum.reverse(acc)), skipping}
    end
  end

  defp inline_text(text, nil, acc) do
    case Regex.run(@inline_html, text, return: :index, capture: :all) do
      nil ->
        {IO.iodata_to_binary(Enum.reverse([text | acc])), nil}

      [{start, len} | groups] ->
        before = binary_part(text, 0, start)
        rest = binary_part(text, start + len, byte_size(text) - start - len)
        inline_text(rest, opens_raw(text, groups), [before | acc])
    end
  end

  # An open `<script>` / `<style>` (not self-closed) starts skipping.
  defp opens_raw(text, [{n_start, n_len}, slash | _]) when n_start >= 0 do
    name = text |> binary_part(n_start, n_len) |> String.downcase()
    self_closed = match?({s, 1} when s >= 0, slash)
    if name in @raw_tags and not self_closed, do: name, else: nil
  end

  defp opens_raw(_text, _groups), do: nil

  @doc """
  The visible text of an HTML block's source: tags, comments, scripts and styles
  dropped. An unclosed comment, script or style hides the rest.
  """
  @spec block_text(String.t()) :: String.t()
  def block_text(source) when is_binary(source), do: block_text(source, [])

  defp block_text(source, acc) do
    case :binary.match(source, "<") do
      :nomatch ->
        IO.iodata_to_binary(Enum.reverse([source | acc]))

      {lt, _} ->
        before = binary_part(source, 0, lt)
        tail = binary_part(source, lt, byte_size(source) - lt)
        acc = [before | acc]

        case skip_markup(tail) do
          {:ok, rest} -> block_text(rest, acc)
          :literal -> IO.iodata_to_binary(Enum.reverse([tail | acc]))
          :hidden -> IO.iodata_to_binary(Enum.reverse(acc))
        end
    end
  end

  # `tail` starts with `<`: the text after the markup, `:literal` when no `>`
  # follows (the rest is text), or `:hidden` when an unclosed comment, script or
  # style swallows the rest.
  defp skip_markup("<!--" <> after_open) do
    case :binary.match(after_open, "-->") do
      {i, 3} -> {:ok, binary_part(after_open, i + 3, byte_size(after_open) - i - 3)}
      :nomatch -> :hidden
    end
  end

  defp skip_markup(tail) do
    case :binary.match(tail, ">") do
      :nomatch ->
        :literal

      {gt, 1} ->
        rest = binary_part(tail, gt + 1, byte_size(tail) - gt - 1)

        case Regex.run(~r{^<(script|style)[\s/>]}i, tail) do
          [_, name] -> skip_raw(rest, String.downcase(name))
          nil -> {:ok, rest}
        end
    end
  end

  defp skip_raw(rest, name) do
    with [{close, _}] <- Regex.run(~r{</#{name}}i, rest, return: :index),
         after_close = binary_part(rest, close, byte_size(rest) - close),
         {gt, 1} <- :binary.match(after_close, ">") do
      {:ok, binary_part(after_close, gt + 1, byte_size(after_close) - gt - 1)}
    else
      _ -> :hidden
    end
  end
end
