defmodule Barkpark.PortableDoc.FieldNumber do
  @moduledoc """
  The one rule for a `field-number` block's numbers: `value`, `min`, `max` and
  `step` are numbers or nil, `step` is positive, `min <= max`, and `value` sits
  inside `min..max`.

  Both write paths use it: the Paper editor's number form
  (`Blocks.validate_block_patch/2`) and every `patch-block` op that reaches
  `Barkpark.PortableDoc.Patch` (the canvas sends the value as a number; an
  older or hand-made op may still send text). A key the patch leaves out is
  checked at its stored value, so changing `min` cannot strand the `value`.
  """

  @number_keys ~w(value min max step)

  @doc "The patch keys this rule reads and rewrites."
  def number_keys, do: @number_keys

  @doc """
  Parse a submitted number: an integer or float stays as is, `nil` and `""` are
  nil, numeric text becomes its integer or float. Anything else is `:error`.
  """
  def parse(value) when value in [nil, ""], do: {:ok, nil}
  def parse(value) when is_integer(value) or is_float(value), do: {:ok, value}

  def parse(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {number, ""} ->
        {:ok, number}

      _ ->
        case Float.parse(trimmed) do
          {number, ""} -> {:ok, number}
          _ -> :error
        end
    end
  end

  def parse(_value), do: :error

  @doc """
  Check the numbers in `params` against `block`. Returns `{:ok, numbers}` with
  each of `value/min/max/step` that `params` carries, parsed; or
  `{:error, :invalid_number}`.
  """
  def validate(block, params) when is_map(block) and is_map(params) do
    with {:ok, value} <- effective(block, params, "value"),
         {:ok, min} <- effective(block, params, "min"),
         {:ok, max} <- effective(block, params, "max"),
         {:ok, step} <- effective(block, params, "step"),
         true <- is_nil(step) or step > 0,
         true <- is_nil(min) or is_nil(max) or min <= max,
         true <- is_nil(value) or is_nil(min) or value >= min,
         true <- is_nil(value) or is_nil(max) or value <= max do
      parsed = %{"value" => value, "min" => min, "max" => max, "step" => step}
      {:ok, Map.take(parsed, Map.keys(params))}
    else
      _ -> {:error, :invalid_number}
    end
  end

  defp effective(block, params, key) do
    case Map.fetch(params, key) do
      {:ok, submitted} -> parse(submitted)
      :error -> parse(Map.get(block, key))
    end
  end
end
