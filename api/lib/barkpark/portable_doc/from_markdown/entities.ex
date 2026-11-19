defmodule Barkpark.PortableDoc.FromMarkdown.Entities do
  @moduledoc """
  HTML entity references in Markdown text, decoded the CommonMark way for
  `Barkpark.PortableDoc.FromMarkdown` (EarmarkParser leaves them as typed):

    * `&name;` with a name from the HTML5 list (`priv/markdown/html-entities.json`,
      the WHATWG `entities.json` names that end in `;`) is its characters;
    * `&#1234;` (1-7 digits) and `&#x1F600;` (1-6 hex digits) are that code
      point, or U+FFFD when it is not a valid character (NUL, a surrogate, a
      control or non-character, past U+10FFFF), as markdown-it does;
    * anything else, an unknown name included, stays as typed.

  A backslash before `&` escapes it (EarmarkParser keeps that backslash), so
  `\\&amp;` reads `&amp;`. One pass only, so `&amp;amp;` reads `&amp;`. Text in
  code spans and code blocks, and a fence's info string, are never decoded.
  """

  @table Path.expand("../../../../priv/markdown/html-entities.json", __DIR__)
  @external_resource @table
  @named @table |> File.read!() |> Jason.decode!()

  @reference ~r/(\\&)|&(?:#[xX]([0-9a-fA-F]{1,6});|#([0-9]{1,7});|([A-Za-z][A-Za-z0-9]{0,31});)/

  @doc "The text with every valid entity reference decoded."
  @spec decode(String.t()) :: String.t()
  def decode(text) when is_binary(text) do
    if String.contains?(text, "&"),
      do: Regex.replace(@reference, text, &replace/5),
      else: text
  end

  defp replace(whole, escaped, hex, dec, name) do
    cond do
      escaped != "" -> "&"
      hex != "" -> hex |> String.to_integer(16) |> char()
      dec != "" -> dec |> String.to_integer() |> char()
      true -> Map.get(@named, name, whole)
    end
  end

  defp char(code), do: if(valid?(code), do: <<code::utf8>>, else: "\uFFFD")

  # markdown-it's isValidEntityCode.
  defp valid?(c) when c >= 0xD800 and c <= 0xDFFF, do: false
  defp valid?(c) when c >= 0xFDD0 and c <= 0xFDEF, do: false
  defp valid?(c) when c > 0x10FFFF, do: false
  defp valid?(c) when c <= 0x08 or c == 0x0B, do: false
  defp valid?(c) when c >= 0x0E and c <= 0x1F, do: false
  defp valid?(c) when c >= 0x7F and c <= 0x9F, do: false

  defp valid?(c),
    do: Bitwise.band(c, 0xFFFF) != 0xFFFF and Bitwise.band(c, 0xFFFF) != 0xFFFE
end
