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
  other byte changes. The same event always maps to the same payload, so a
  host's retry at the same cursor is still a duplicate.
  """

  @replacement "�"

  @doc "The event with U+0000 replaced by U+FFFD in every string, at any depth."
  def replace_nul(value) when is_binary(value) do
    if :binary.match(value, <<0>>) == :nomatch,
      do: value,
      else: :binary.replace(value, <<0>>, @replacement, [:global])
  end

  def replace_nul(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {replace_nul(key), replace_nul(item)} end)

  def replace_nul(value) when is_list(value), do: Enum.map(value, &replace_nul/1)

  def replace_nul(value), do: value
end
