defmodule Barkpark.Content.ValueUndo do
  @moduledoc """
  Takes one editor's own change of any field value back out of what the
  store holds now, keeping what other editors changed since, as the TanStack
  Studio's undo (`app/src/lib/merge.ts`, `revert`, `revertSteps` and
  `mergeList3`): text unapplies (`TextUndo`), a keyed list puts back the
  items this editor removed and drops the ones it added, and a value
  someone else changed since stays theirs.

  A step is `{from, to}`: the value one save of this editor went from and
  the value it left. Undo walks a change's steps from the last back, each
  `to -> from`; redo walks them in order. Placed on `now`:

  - `now` still `from`: `to`, whatever the kind.
  - Text: `TextUndo.revert/3`, which applies only where this editor's words
    still are.
  - A map (an object, a list item): each key the step changed is reverted
    on its own, so another editor's change of a sibling key stays.
  - A list whose items all have a `_key`: an item this editor added goes,
    one it removed comes back after the item it followed (or first), and
    an item both changed is reverted key by key. Another editor's items,
    and their order, stay.
  - A list of plain values (a list of strings): what this editor added
    goes, what it removed comes back at its place.
  - Anything else someone changed since (a select, a number, an unkeyed
    list of objects): it stays theirs, and the step does nothing.
  """

  alias Barkpark.Content.TextUndo

  @doc """
  `now` with the steps applied, each `{from, to}` turning its `from` back
  into its `to`, in order. `now` itself when a step that changes something
  does nothing on it (someone else changed it since): all or nothing.
  """
  @spec revert_steps([{term(), term()}], term()) :: term()
  def revert_steps(steps, now) when is_list(steps) do
    Enum.reduce_while(steps, now, fn {from, to}, value ->
      next = revert(from, to, value)
      if from != to and next == value, do: {:halt, now}, else: {:cont, next}
    end)
  end

  @doc "One step, `from -> to`, on `now`."
  @spec revert(term(), term(), term()) :: term()
  def revert(from, to, now) when from == now, do: to

  def revert(from, to, now) when is_binary(from) and is_binary(to) and is_binary(now),
    do: TextUndo.revert(from, to, now)

  def revert(from, to, now) when is_map(from) and is_map(to) and is_map(now),
    do: revert_map(from, to, now)

  def revert(from, to, now) when is_list(from) and is_list(to) and is_list(now) do
    cond do
      keyed?(from) and keyed?(to) and keyed?(now) -> revert_keyed(from, to, now)
      plain?(from) and plain?(to) and plain?(now) -> revert_plain(from, to, now)
      true -> now
    end
  end

  def revert(_from, _to, now), do: now

  # ── Maps ────────────────────────────────────────────────────────────────

  # Each key the step changed, reverted on what `now` holds there. A key the
  # step added goes when it is still the step's; one it removed comes back
  # when no one set it since.
  defp revert_map(from, to, now) do
    from
    |> Map.keys()
    |> Enum.concat(Map.keys(to))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(from, &1) == Map.get(to, &1)))
    |> Enum.reduce(now, fn key, acc ->
      case revert(Map.get(from, key), Map.get(to, key), Map.get(now, key)) do
        nil -> if Map.has_key?(to, key), do: Map.put(acc, key, nil), else: Map.delete(acc, key)
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # ── Keyed lists ─────────────────────────────────────────────────────────

  defp revert_keyed(from, to, now) do
    from_by = by_key(from)
    to_by = by_key(to)

    kept =
      Enum.flat_map(now, fn item ->
        key = item["_key"]

        cond do
          # This editor added it (not there before the step): it goes, unless
          # someone else changed it since; then theirs stays.
          Map.has_key?(from_by, key) and not Map.has_key?(to_by, key) ->
            if item == from_by[key], do: [], else: [item]

          Map.has_key?(from_by, key) ->
            [revert(from_by[key], to_by[key], item)]

          true ->
            [item]
        end
      end)

    # This editor removed it: it comes back after the item it followed.
    to
    |> Enum.with_index()
    |> Enum.reject(fn {item, _i} -> Map.has_key?(from_by, item["_key"]) end)
    |> Enum.reduce(kept, fn {item, i}, acc ->
      if Enum.any?(acc, &(&1["_key"] == item["_key"])),
        do: acc,
        else: List.insert_at(acc, place(acc, to, i), item)
    end)
  end

  # Where an item put back goes: after the item it follows in `to`, first
  # when it was first, last when the one it follows is gone.
  defp place(_acc, _to, 0), do: 0

  defp place(acc, to, i) do
    prev = Enum.at(to, i - 1)["_key"]

    case Enum.find_index(acc, &(&1["_key"] == prev)) do
      nil -> length(acc)
      at -> at + 1
    end
  end

  defp by_key(items), do: Map.new(items, &{&1["_key"], &1})

  # Every item has a `_key` (an empty list is any kind of list).
  defp keyed?(items), do: Enum.all?(items, &(is_map(&1) and is_binary(&1["_key"])))

  # ── Lists of plain values ───────────────────────────────────────────────

  defp revert_plain(from, to, now) do
    added = from -- to
    removed = to -- from
    kept = now -- added

    to
    |> Enum.with_index()
    |> Enum.filter(fn {value, _i} -> value in removed end)
    |> Enum.reduce(kept, fn {value, i}, acc ->
      if value in acc, do: acc, else: List.insert_at(acc, min(i, length(acc)), value)
    end)
  end

  defp plain?(items), do: Enum.all?(items, &(is_binary(&1) or is_number(&1) or is_boolean(&1)))
end
