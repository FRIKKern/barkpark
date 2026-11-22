defmodule BarkparkWeb.Studio.StudioLive.Handlers.UnsavedObjects do
  @moduledoc """
  An object field this tab holds unsaved, under another editor's save
  (`Handlers.Lifecycle.doc_updated/2`, task-71ff11d4e7374985).

  The object was one value: when both sides changed it, it was a conflict,
  even when A typed in `meta.label` and B changed `meta.code`, or each typed
  a different word of the label. TanStack keeps each pending edit by its
  path (`meta.label`) and merges each one as text (barkpark-studio
  edit-bases.ts `rebase`). Here the object is settled subfield by subfield,
  with the same rule a top-level field gets (`Lifecycle`'s `clash`), and a
  text subfield's base is the one its words were typed on, kept by path
  (`Handlers.UnsavedBases`).
  """

  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.Handlers.UnsavedBases

  @doc """
  The subfields of `key` when it is a `composite` field held as an object in
  `base`, `mine` and `theirs`; else nil.
  """
  def subfields(schema, key, base, mine, theirs) do
    with %{"type" => "composite", "fields" => subs} when is_list(subs) <- field(schema, key),
         true <- Enum.all?([base, mine, theirs], &object?/1) do
      subs
    else
      _ -> nil
    end
  end

  @doc """
  Settles the object at `path` subfield by subfield. `clash` is the
  top-level rule, `(typed, stored, mine, theirs, schema, key) ->
  {:ours, v} | {:took, v} | :clash`. Returns `{value, clashed?, kept}`:
  a clashed subfield keeps this tab's value, as a clashed field does, and
  `kept` gets the base of each text subfield that took theirs.
  """
  def merge(socket, subs, path, base, mine, theirs, kept, clash) do
    sub_schema = %{fields: subs}

    mine
    |> Map.keys()
    |> Enum.concat(Map.keys(theirs))
    |> Enum.uniq()
    |> Enum.reduce({theirs, false, kept}, fn sub, {value, clashed?, kept} ->
      at = path ++ [sub]
      {b, m, t} = {Map.get(base, sub), Map.get(mine, sub), Map.get(theirs, sub)}

      case subfields(sub_schema, sub, b, m, t) do
        nil ->
          typed = typed_on(socket, at, b, m)

          case clash.(typed, b, m, t, sub_schema, sub) do
            {:ours, v} ->
              {put(value, sub, v, mine, theirs), clashed?, kept}

            {:took, v} ->
              kept = if text?(socket, at), do: UnsavedBases.put(kept, at, t, v), else: kept
              {put(value, sub, v, mine, theirs), clashed?, kept}

            :clash ->
              {put(value, sub, m, mine, theirs), true, kept}
          end

        inner ->
          {v, inner_clashed?, kept} = merge(socket, inner, at, b, m, t, kept, clash)
          {Map.put(value, sub, v), clashed? or inner_clashed?, kept}
      end
    end)
  end

  # The base a subfield's value is read from. A text subfield typed in has
  # the base its words were typed on (`UnsavedBases`), or none known
  # (`:error`: theirs that differs is a clash, never merged unseen). One this
  # tab did not change from the stored row is read against that row, so
  # another editor's change to it is taken in: the object is held for
  # another subfield's typing, not this one's.
  defp typed_on(socket, at, base, mine) do
    case text?(socket, at) and UnsavedBases.fetch(socket, at) do
      {:ok, typed} -> {:ok, typed}
      _ when mine == base -> {:ok, base}
      _ -> :error
    end
  end

  @doc """
  For `RemoteValues.push/4`: each text subfield inside the held objects of
  `keys`, with the stored value its words were typed on and theirs. A base
  never holds this tab's own unsaved words.
  """
  def push_bases(socket, keys, base, theirs) do
    schema = socket.assigns[:editor_schema]

    for key <- keys,
        is_binary(key),
        path <- text_paths(schema, [key], Map.get(theirs, key)),
        into: %{} do
      was =
        case UnsavedBases.fetch(socket, path) do
          {:ok, typed_on} -> typed_on
          :error -> RemoteValues.value_at(base, path)
        end

      {path, {was, RemoteValues.value_at(theirs, path)}}
    end
  end

  defp text_paths(schema, [key | _] = path, value) do
    case field(schema, key) do
      %{"type" => "composite", "fields" => subs} when is_list(subs) ->
        if object?(value) do
          Enum.flat_map(value, fn {sub, inner} ->
            at = path ++ [sub]

            cond do
              RemoteValues.free_text_at?(%{fields: [field(schema, key)]}, [key, sub]) -> [at]
              object?(inner) -> nested(subs, at, sub, inner)
              true -> []
            end
          end)
        else
          []
        end

      _ ->
        []
    end
  end

  defp nested(subs, at, sub, inner) do
    Enum.map(text_paths(%{fields: subs}, [sub], inner), fn [_ | rest] -> at ++ rest end)
  end

  # A subfield neither side holds stays out of the object.
  defp put(value, sub, v, mine, theirs) do
    if is_nil(v) and not Map.has_key?(mine, sub) and not Map.has_key?(theirs, sub),
      do: Map.delete(value, sub),
      else: Map.put(value, sub, v)
  end

  defp text?(socket, path), do: RemoteValues.free_text_at?(socket.assigns[:editor_schema], path)

  defp object?(value), do: is_map(value) and not is_struct(value)

  defp field(%{fields: fields}, key) when is_list(fields),
    do: Enum.find(fields, &(is_map(&1) and &1["name"] == key))

  defp field(_schema, _key), do: nil
end
