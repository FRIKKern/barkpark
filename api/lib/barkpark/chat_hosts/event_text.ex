defmodule Barkpark.ChatHosts.EventText do
  @moduledoc """
  Makes a chat-host event storable as jsonb (task-6497a4925af9b22f).

  Postgres refuses U+0000 in jsonb (22P05). Model output, a tool result or
  echoed file bytes can carry it, and the refusal used to answer the host's
  event POST with a 500: the host retried the same cursor and the turn stalled
  until its lease expired. Refusing the event with a 4xx instead would be final
  for the host and end the turn, losing the rest of the reply
  (internal/chathost/runner.go).

  So every U+0000 in every string the event carries (map keys, values, list
  items, at any depth) is stored as U+FFFD, the Unicode replacement character:
  the reader sees that a character was there and could not be kept, and no
  other byte changes. One consequence: two map keys that differ only by
  U+0000 against U+FFFD become one key, and only one of their values is kept.
  The same event always maps to the same payload, so a host's retry at the
  same cursor is still a duplicate.
  """

  @replacement "�"

  @doc "The event with U+0000 replaced by U+FFFD in every string, at any depth."
  # Almost no event holds U+0000. Reading for one first costs about a quarter
  # of rebuilding every map (107 ms against 30 ms on a 5 MB event), so the
  # rebuild runs only when there is something to replace.
  def replace_nul(value) do
    if Barkpark.StudioChat.NulText.check(value) == :ok, do: value, else: replace(value)
  end

  defp replace(value) when is_binary(value),
    do: :binary.replace(value, <<0>>, @replacement, [:global])

  defp replace(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {replace(key), replace(item)} end)

  defp replace(value) when is_list(value), do: Enum.map(value, &replace/1)

  defp replace(value), do: value
end
