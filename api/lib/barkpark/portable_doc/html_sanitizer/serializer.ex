defmodule Barkpark.PortableDoc.HtmlSanitizer.Serializer do
  @moduledoc """
  Writes the sanitizer's clean tree back out as HTML (#28404 review, B6).

  `LazyHTML.to_html/1` is not used for this. It writes an end tag for a void
  element under `<s>` (`<s><br></br></s>`), and `</br>` parses as a second
  `<br>`, so every save doubled a legacy body's line breaks.

  The rules follow the HTML serialisation algorithm:

    * a void element (`@void`) is written as its start tag alone, with no
      end tag and no children;
    * every other element gets its start tag, its children and its end tag;
    * text escapes `&`, `<`, `>` and U+00A0 (as `&nbsp;`);
    * an attribute value is double-quoted and escapes `&`, `"`, `<`, `>`
      and U+00A0. An empty value is written as the bare name;
    * when a `pre`, `textarea` or `listing` starts with a newline, one more
      newline follows the start tag. The parser drops the first newline
      after that tag, so without the extra one each pass would lose a line;
    * comments are not written.

  The sanitizer keeps no raw-text element (`script`, `style`, `xmp`…). So
  text is escaped everywhere, including inside an element a browser would
  read as raw text: escaping is never less safe than leaving the text alone.
  """

  # The HTML void elements: those the sanitizer keeps (br wbr img input col
  # track hr), plus the rest of the spec's list, for completeness.
  @void MapSet.new(~w(area base br col embed hr img input link meta source track wbr))

  # The elements whose first newline the parser drops.
  @newline_eats MapSet.new(~w(pre textarea listing))

  # Phrasing content (the HTML spec's inline elements): its text runs on into
  # its neighbour's. Any other element is a block, and `text/1` puts a space
  # either side of it, so `<p>a</p><p>b</p>` reads `a b`, never `ab`.
  @phrasing MapSet.new(
              ~w(a abbr b bdi bdo cite code data del dfn em font i img ins kbd label mark q s samp small span strike strong sub sup time u var wbr)
            )

  @text_specials ["&", "<", ">", "\u00A0"]
  @attr_specials ["\"" | @text_specials]

  @doc "The void elements this serialiser writes without an end tag."
  def void, do: @void

  @doc "Serialise a `LazyHTML.to_tree/1` tree (a list of nodes) to HTML."
  @spec to_html([term()]) :: String.t()
  def to_html(nodes) when is_list(nodes), do: nodes |> nodes_iodata() |> IO.iodata_to_binary()

  @doc """
  The text a browser would show for the tree: every text node, in order, a
  space between blocks, and each run of HTML whitespace (not U+00A0) as one
  space.
  """
  @spec text([term()]) :: String.t()
  def text(nodes) when is_list(nodes) do
    text = nodes |> text_iodata() |> IO.iodata_to_binary()
    ~r/[\t\n\f\r ]+/ |> Regex.replace(text, " ") |> String.trim(" ")
  end

  @doc "Escape text for an HTML text node."
  @spec escape_text(String.t()) :: iodata()
  def escape_text(text), do: String.replace(text, @text_specials, &entity/1)

  defp nodes_iodata(nodes), do: Enum.map(nodes, &node_iodata/1)

  defp node_iodata({:comment, _}), do: []

  defp node_iodata({tag, attrs, children}) when is_binary(tag) do
    start = ["<", tag, Enum.map(attrs, &attr_iodata/1), ">"]

    cond do
      MapSet.member?(@void, tag) -> start
      true -> [start, leading_newline(tag, children), nodes_iodata(children), "</", tag, ">"]
    end
  end

  defp node_iodata(text) when is_binary(text), do: escape_text(text)
  defp node_iodata(_other), do: []

  defp leading_newline(tag, [<<?\n, _::binary>> | _]) do
    if MapSet.member?(@newline_eats, tag), do: "\n", else: []
  end

  defp leading_newline(_tag, _children), do: []

  defp attr_iodata({name, ""}), do: [" ", name]
  defp attr_iodata({name, value}), do: [" ", name, "=\"", escape_attr(value), "\""]

  defp escape_attr(value), do: String.replace(value, @attr_specials, &entity/1)

  defp entity("&"), do: "&amp;"
  defp entity("<"), do: "&lt;"
  defp entity(">"), do: "&gt;"
  defp entity("\u00A0"), do: "&nbsp;"
  defp entity("\""), do: "&quot;"

  defp text_iodata(nodes) when is_list(nodes), do: Enum.map(nodes, &text_iodata/1)

  defp text_iodata({tag, _attrs, children}) when is_binary(tag) do
    if MapSet.member?(@phrasing, String.downcase(tag)),
      do: text_iodata(children),
      else: [" ", text_iodata(children), " "]
  end

  defp text_iodata(text) when is_binary(text), do: text
  defp text_iodata(_other), do: []
end
