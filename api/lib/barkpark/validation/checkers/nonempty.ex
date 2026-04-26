defmodule Barkpark.Validation.Checkers.Nonempty do
  @moduledoc """
  `:ok` when the value is not nil, `""`, `[]`, or `%{}`.
  """

  @behaviour Barkpark.Validation.Checker

  @impl true
  def check(nil, _), do: {:error, :empty}
  def check("", _), do: {:error, :empty}
  def check([], _), do: {:error, :empty}
  def check(map, _) when is_map(map) and map_size(map) == 0, do: {:error, :empty}
  def check(_value, _args), do: :ok
end
