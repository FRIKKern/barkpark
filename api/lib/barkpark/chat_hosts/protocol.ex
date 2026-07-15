defmodule Barkpark.ChatHosts.Protocol do
  @moduledoc "Pure ordered/idempotent cursor reconciler shared by transport tests."

  defstruct [:lease_id, :epoch, :last_cursor, keys: %{}]

  def new(lease_id, epoch, last_cursor),
    do: %__MODULE__{lease_id: lease_id, epoch: epoch, last_cursor: last_cursor}

  def accept(%__MODULE__{lease_id: lease_id, epoch: epoch} = state, lease_id, epoch, cursor, key)
      when is_integer(cursor) and cursor > 0 and is_binary(key) do
    cond do
      cursor == state.last_cursor + 1 ->
        {:ok, %{state | last_cursor: cursor, keys: Map.put(state.keys, cursor, key)}}

      cursor <= state.last_cursor and Map.get(state.keys, cursor) == key ->
        {:duplicate, state}

      cursor <= state.last_cursor ->
        {:error, :cursor_conflict}

      true ->
        {:error, :cursor_gap}
    end
  end

  def accept(%__MODULE__{}, _lease_id, _epoch, _cursor, _key), do: {:error, :stale_fence}
end
