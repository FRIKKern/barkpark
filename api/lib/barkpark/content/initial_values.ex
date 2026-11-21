defmodule Barkpark.Content.InitialValues do
  @moduledoc """
  How a create's content meets the schema's `initial_values` (task-d5f5a94e2e1690be).

  Values the caller sends win and maps merge deeply, as `Writer.deep_merge/2`: a key the
  caller leaves out gets the initial value. One addition: an explicit `null` at a path where
  the initial values would have supplied a value means "leave it empty". That path is left
  out of the stored content, so the initial value is not filled in, and the document holds
  no `null` there either (Sanity's: a field cleared before the first save is absent).

  That keeps the two cases a Studio needs apart. An absent key means "Barkpark's". The
  Studio leaves a `"$today"` field out when it can't read the workspace's zone, so Barkpark
  fills it. A `null` means the editor cleared it.

  The rule holds only where an initial value would land, at any depth (`meta.dato`). A `null`
  anywhere else is stored as before, since other clients and imports may rely on it. A
  `null` for a whole object that has nested initial values (`meta: null` under
  `meta: %{"dato" => "$today"}`) leaves the whole object out. Lists don't merge: a list the
  caller sends replaces the initial one, and a `null` in its place leaves it out.
  """

  @doc "The content a create stores: `provided` over the resolved `initial` values."
  @spec merge(map(), map()) :: map()
  def merge(initial, provided) when is_map(initial) and is_map(provided) do
    Enum.reduce(provided, initial, fn {key, value}, acc ->
      case {Map.get(initial, key), value} do
        {iv, nil} when not is_nil(iv) -> Map.delete(acc, key)
        {iv, v} when is_map(iv) and is_map(v) -> Map.put(acc, key, merge(iv, v))
        {_iv, v} -> Map.put(acc, key, v)
      end
    end)
  end
end
