defmodule Barkpark.Validation.Checkers.Gtin14Checksum do
  @moduledoc """
  GTIN-14 checksum validator.

  Accepts a 14-character string of digits (hyphens / spaces stripped).
  Standard GTIN check-digit algorithm — weights alternate 3,1 from the
  rightmost data digit to the left, and the check digit is whatever
  brings the running sum to a multiple of 10.
  """

  @behaviour Barkpark.Validation.Checker

  @impl true
  def check(value, _args) when is_binary(value) do
    digits =
      value
      |> String.replace([" ", "-"], "")
      |> String.to_charlist()

    cond do
      length(digits) != 14 ->
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
    # Weights from the right (excluding the trailing check digit) are
    # 3,1,3,1,... — equivalent to weights 3,1,3,1,...,3 from the left
    # for the first 13 digits when length is 14.
    [check | rest_rev] = Enum.reverse(digits)

    sum =
      rest_rev
      |> Enum.with_index()
      |> Enum.reduce(0, fn {ch, idx}, acc ->
        d = ch - ?0
        w = if rem(idx, 2) == 0, do: 3, else: 1
        acc + d * w
      end)

    rem(sum + (check - ?0), 10) == 0
  end
end
