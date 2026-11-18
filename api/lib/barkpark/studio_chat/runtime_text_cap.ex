defmodule Barkpark.StudioChat.RuntimeTextCap do
  @moduledoc """
  The per-turn byte cap on the Recorder's durable accumulator (charter D169).

  Text over `max_bytes/0` is cut at a grapheme boundary (`Barkpark.ByteCut`)
  and the truncation marker is put at its tail. The turn is never aborted
  (W22/D131).

  Once the text ends with the marker it is frozen: later deltas are dropped.
  The freeze is explicit because the grapheme cut can fall a whole grapheme
  short of the budget, so a capped text plus a short delta can fit under the
  cap again. Re-cutting it then stored text after the marker, and a second
  marker (review of #26947).
  """

  @default_max_bytes 1_048_576
  @marker "\n\n[… turn output truncated at the persist byte cap …]"

  @doc "Append `delta` to the accumulated `text`, then cap. A capped text stays as it is."
  @spec append(String.t(), String.t()) :: String.t()
  def append(text, delta) when is_binary(text) and is_binary(delta) do
    if String.ends_with?(text, @marker), do: text, else: cap(text <> delta)
  end

  @doc "`text` itself when it fits the cap, else its cut prefix and the marker."
  @spec cap(String.t()) :: String.t()
  def cap(text) when is_binary(text) do
    max = max_bytes()

    if byte_size(text) <= max,
      do: text,
      else: Barkpark.ByteCut.prefix(text, max(max - byte_size(@marker), 0)) <> @marker
  end

  defp max_bytes do
    :barkpark
    |> Application.get_env(:claude_chat, [])
    |> Keyword.get(:max_runtime_text_bytes, @default_max_bytes)
  end
end
