defmodule Barkpark.Plugins.Settings.Masking do
  @moduledoc """
  Masks string-valued secrets for display. Recursively walks maps/lists.

  Behaviour:
    * binaries longer than 4 chars  → `********` + last 4 chars
    * binaries of length <= 4       → `****`
    * booleans / numbers / nil      → unchanged
    * maps / lists                  → recursively masked
  """

  @mask_char "*"

  def mask(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {k, v} -> {k, mask(v)} end)
    |> Map.new()
  end

  def mask(value) when is_list(value), do: Enum.map(value, &mask/1)

  def mask(value) when is_binary(value) do
    len = String.length(value)

    if len <= 4 do
      String.duplicate(@mask_char, 4)
    else
      last4 = String.slice(value, (len - 4)..(len - 1)//1)
      String.duplicate(@mask_char, 8) <> last4
    end
  end

  def mask(value), do: value
end
