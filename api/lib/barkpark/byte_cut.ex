defmodule Barkpark.ByteCut do
  @moduledoc """
  Cut text to a byte budget on a grapheme boundary.

  Backing off to the last whole codepoint is not enough. A flag is two
  regional indicators, and one of them alone draws as a boxed letter. A tag
  flag (🏴 and its tags) cut inside its tags draws as a plain black flag. So
  the cut backs off to the last whole grapheme (task-fb5274e13f678d29).

  One grapheme can be larger than the whole budget: one letter with 200,000
  combining marks is a single grapheme. Then the cut keeps that grapheme's
  codepoint prefix, so the letter and some of its marks still show
  (task-ed920e5459df0ab5). A flag is never kept in part: an oversized flag
  grapheme is dropped.

  Text that is not valid UTF-8 is cut at its first bad byte.
  """

  # Regional indicators, and the tag characters that spell a tag flag.
  @flag_parts [0x1F1E6..0x1F1FF, 0xE0020..0xE007F]

  # @canonical capability:grapheme-byte-cut aka:truncate_to_valid_utf8,truncate_bytes,cut_bytes,byte cap,lone regional indicator
  @doc """
  The longest prefix of `text` that is at most `max_bytes` bytes and ends on a
  grapheme boundary of `text`.
  """
  @spec prefix(String.t(), integer()) :: String.t()
  def prefix(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text
  def prefix(text, max_bytes) when is_binary(text) and max_bytes <= 0, do: ""

  def prefix(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    whole = valid_prefix(binary_part(text, 0, max_bytes))
    last = last_grapheme_start(whole, anchor(whole, byte_size(whole) - 1))
    kept = byte_size(whole) - last

    case String.next_grapheme_size(binary_part(text, last, byte_size(text) - last)) do
      {^kept, _rest} -> whole
      _cut_inside when last > 0 -> binary_part(whole, 0, last)
      _oversized -> drop_flag(whole)
    end
  end

  defp valid_prefix(bytes) do
    case :unicode.characters_to_binary(bytes) do
      whole when is_binary(whole) -> whole
      {_incomplete_or_error, whole, _rest} -> whole
    end
  end

  # A byte offset that is a grapheme boundary of any text this prefix starts:
  # between two ASCII bytes that are not CR LF there is always one. Segmenting
  # from there instead of from 0 keeps a long capped text from being walked
  # whole on every cut. With no such pair the walk starts at 0.
  defp anchor(_bin, pos) when pos <= 0, do: 0

  defp anchor(bin, pos) do
    before = :binary.at(bin, pos - 1)
    at = :binary.at(bin, pos)

    if before < 0x80 and at < 0x80 and not (before == ?\r and at == ?\n),
      do: pos,
      else: anchor(bin, pos - 1)
  end

  # The byte offset where the last grapheme of `bin` starts, walking from
  # `from`, a known boundary. Graphemes before the last one are the same in
  # `bin` and in the text it was cut from: no rule looks forward past the next
  # codepoint.
  defp last_grapheme_start(bin, from) do
    case String.next_grapheme_size(binary_part(bin, from, byte_size(bin) - from)) do
      nil -> from
      {size, ""} when size > 0 -> from
      {size, _rest} -> last_grapheme_start(bin, from + size)
    end
  end

  defp drop_flag(whole) do
    if Enum.any?(String.to_charlist(whole), fn cp -> Enum.any?(@flag_parts, &(cp in &1)) end),
      do: "",
      else: whole
  end
end
