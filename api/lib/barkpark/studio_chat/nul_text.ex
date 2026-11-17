defmodule Barkpark.StudioChat.NulText do
  @moduledoc """
  The store-side refusal of U+0000 in chat text (task-820afe5940d0e6e0).

  Postgres refuses U+0000 in a text column or parameter (22021) and in jsonb
  (22P05), so such a write fails the same way every time. `StudioChat.rename/2`,
  `set_draft/2` and `append_message/2` check here first and answer
  `{:error, :nul_character}` without touching the store, so a caller that
  forgot its own check (ChatLive did) gets a typed error instead of a raise.
  The HTTP chat routes refuse it earlier, as a 400 (`ChatUserTurn.reject_nul/1`).
  """

  @doc """
  `:ok`, or `{:error, :nul_character}` when any string in `value` holds U+0000:
  the value itself, or any map key, map value, list item or struct field in it,
  at any depth.
  """
  @spec check(term()) :: :ok | {:error, :nul_character}
  def check(value), do: if(nul?(value), do: {:error, :nul_character}, else: :ok)

  @doc "Runs `fun` only when `check(value)` is `:ok`; otherwise answers its error."
  @spec guard(term(), (-> result)) :: result | {:error, :nul_character} when result: term()
  def guard(value, fun) when is_function(fun, 0) do
    with :ok <- check(value), do: fun.()
  end

  defp nul?(value) when is_binary(value), do: :binary.match(value, <<0>>) != :nomatch
  defp nul?(value) when is_struct(value), do: value |> Map.from_struct() |> nul?()
  defp nul?(value) when is_map(value), do: Enum.any?(value, fn {k, v} -> nul?(k) or nul?(v) end)
  defp nul?(value) when is_list(value), do: Enum.any?(value, &nul?/1)
  defp nul?(_value), do: false
end
