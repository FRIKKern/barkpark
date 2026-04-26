defmodule Barkpark.Validation.Checkers.Isbn13Checksum do
  @moduledoc """
  ISBN-13 checksum validator.

  Accepts a 13-character string of digits (optionally with hyphens or
  spaces, which are stripped). Returns `:ok` when the trailing check
  digit matches the standard ISBN-13 algorithm:

      sum = Σ d_i * w_i  where w = [1,3,1,3,...,1,3]
      sum mod 10 == 0
  """

  @behaviour Barkpark.Validation.Checker

  @impl true
  def check(value, _args) when is_binary(value) do
    digits =
      value
      |> String.replace([" ", "-"], "")
      |> String.to_charlist()

    cond do
      length(digits) != 13 ->
        {:error, :bad_length}

      not Enum.all?(digits, &(&1 in ?0..?9)) ->
        {:error, :non_digit}

      checksum_ok?(digits) ->
        :ok

      true ->
        {:error, :bad_checksum}
    end
  end

  def check(_value, _args), do: {:error, :not_a_string}

  defp checksum_ok?(digits) do
    digits
    |> Enum.with_index()
    |> Enum.reduce(0, fn {ch, idx}, acc ->
      d = ch - ?0
      w = if rem(idx, 2) == 0, do: 1, else: 3
      acc + d * w
    end)
    |> rem(10) == 0
  end
end
