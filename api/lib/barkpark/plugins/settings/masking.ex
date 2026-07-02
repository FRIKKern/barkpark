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

  @doc """
  Reconciles a `submitted` settings tree against the `stored` one so a save that
  round-trips masked placeholders can't overwrite the real secrets.

  Walks both trees in parallel (maps by key, lists by index); any string leaf in
  `submitted` that equals `mask/1` of the matching `stored` leaf is the untouched
  placeholder and is replaced by the stored raw value. Anything else — a freshly
  typed secret (which won't equal the mask), a non-string, or a key with no
  stored counterpart — is kept as submitted, so additions and edits pass through
  and removals are respected.
  """
  def restore(submitted, stored) when is_map(submitted) and is_map(stored) do
    Map.new(submitted, fn {k, v} -> {k, restore(v, Map.get(stored, k))} end)
  end

  def restore(submitted, stored) when is_list(submitted) and is_list(stored) do
    submitted
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> restore(v, Enum.at(stored, i)) end)
  end

  def restore(submitted, stored) when is_binary(submitted) and is_binary(stored) do
    if submitted == mask(stored), do: stored, else: submitted
  end

  def restore(submitted, _stored), do: submitted
end
