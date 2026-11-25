defmodule Barkpark.Tenancy.WorkspaceBundle.CopyText do
  @moduledoc """
  Reading a bundle member, which is `COPY … TO STDOUT` text: one row per
  line, fields split by a tab, `\\N` for SQL NULL, and tab, newline and
  backslash inside a value escaped with a backslash.

  `DatasetRemap` reads a member's rows to remap them, and `LinkHrefCheck`
  to look for link addresses a write refuses, before anything is written.
  """

  @doc """
  The rows of a member as lists of raw fields, from an enumerable of chunks.
  COPY text escapes tab and newline inside a value, so a bare tab separates
  fields and a bare newline ends a row, whatever the chunk boundaries were.
  """
  @spec rows(Enumerable.t()) :: Enumerable.t()
  def rows(source) do
    source
    |> Stream.transform(
      fn -> "" end,
      fn chunk, buffer ->
        parts = String.split(buffer <> IO.iodata_to_binary(chunk), "\n")
        {complete, [rest]} = Enum.split(parts, -1)
        {complete, rest}
      end,
      fn
        "" -> {[], ""}
        rest -> {[rest], ""}
      end,
      fn _ -> :ok end
    )
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&String.split(&1, "\t"))
  end

  @doc """
  The decoded value of field `i`: `nil` for SQL NULL, otherwise the text
  with COPY's backslash escapes undone.
  """
  @spec value([String.t()], non_neg_integer()) :: String.t() | nil
  def value(fields, i) do
    case Enum.at(fields, i) do
      "\\N" -> nil
      nil -> nil
      raw -> unescape(raw)
    end
  end

  defp unescape(raw) do
    if String.contains?(raw, "\\") do
      Regex.replace(~r/\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)/s, raw, fn _, esc ->
        case esc do
          "b" -> "\b"
          "f" -> "\f"
          "n" -> "\n"
          "r" -> "\r"
          "t" -> "\t"
          "v" -> "\v"
          "x" <> hex -> <<String.to_integer(hex, 16)>>
          <<d, _::binary>> = oct when d in ?0..?7 -> <<String.to_integer(oct, 8)>>
          other -> other
        end
      end)
    else
      raw
    end
  end
end
