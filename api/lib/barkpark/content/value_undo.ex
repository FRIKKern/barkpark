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
  - Free text, as the schema says (`field`: a `text`, or a `string` with no
    options list): `TextUndo.revert/3`, which applies only where this
    editor's words still are. Any other string (a select, an options
    string, a slug, a date, a datetime, a codelist code) is one value, as
    a number is: changed since, it stays theirs. Text-merged, two picks
    could make a value neither editor chose.
  - A map (an object, a list item): each key the step changed is reverted
    on its own, by its own field, so another editor's change of a sibling
    key stays.
  - A list whose items all have a `_key`: an item this editor added goes,
    one it removed comes back after the item it followed (or first), and
    an item both changed is reverted key by key. Another editor's items,
    and their order, stay.
  - Any other list (plain values, objects with no `_key`) has no item to
    place by: undone only when another editor at most added items at its
    end; any other change since moves positions, and the step does nothing.
    A position is never guessed.
  - Anything else someone changed since: it stays theirs, and the step
    does nothing.

  `field` is the schema field the value is of (`"fields"` for an object's
  keys, `"of"` for a list's items); an unknown field is not free text.
  """

  alias Barkpark.Content.TextUndo

  @doc """
  `now` with the steps applied, each `{from, to}` turning its `from` back
  into its `to`, in order. `now` itself when a step that changes something
  does nothing on it (someone else changed it since): all or nothing.
  """
  @spec revert_steps([{term(), term()}], term(), map() | nil) :: term()
  def revert_steps(steps, now, field \\ nil) when is_list(steps) do
    Enum.reduce_while(steps, now, fn {from, to}, value ->
      next = revert(from, to, value, field)
      if from != to and next == value, do: {:halt, now}, else: {:cont, next}
    end)
  end

  @doc "One step, `from -> to`, on `now`, of a value of `field`."
  @spec revert(term(), term(), term(), map() | nil) :: term()
  def revert(from, to, now, field \\ nil)
  def revert(from, to, now, _field) when from == now, do: to

  def revert(from, to, now, field) when is_binary(from) and is_binary(to) and is_binary(now) do
    if free_text?(field), do: TextUndo.revert(from, to, now), else: now
  end

  def revert(from, to, now, field) when is_map(from) and is_map(to) and is_map(now),
    do: revert_map(from, to, now, field)

  def revert(from, to, now, field) when is_list(from) and is_list(to) and is_list(now) do
    if keyed?(from) and keyed?(to) and keyed?(now),
      do: revert_keyed(from, to, now, field),
      else: revert_unkeyed(from, to, now)
  end

  def revert(_from, _to, now, _field), do: now

  # ── The schema ──────────────────────────────────────────────────────────

  @doc "Whether `field` is free text: a `text`, or a `string` with no options list."
  def free_text?(%{"type" => "text"}), do: true

  def free_text?(%{"type" => "string"} = field) do
    case field["options"] do
      %{"list" => list} when is_list(list) -> false
      list when is_list(list) -> false
      _ -> true
    end
  end

  def free_text?(_field), do: false

  # The field of an object's key.
  defp sub(%{"fields" => fields}, key) when is_list(fields),
    do: Enum.find(fields, &(is_map(&1) and &1["name"] == key))

  defp sub(_field, _key), do: nil

  # The field of a list's item: the one member type, or the one its `_type` names.
  defp member(%{"of" => %{} = of}, _item), do: of

  defp member(%{"of" => [_ | _] = types}, item) do
    name = is_map(item) && item["_type"]

    Enum.find(types, &(is_map(&1) and name != nil and (&1["name"] == name or &1["type"] == name))) ||
      if(length(types) == 1, do: hd(types))
  end

  defp member(_field, _item), do: nil

  # ── Maps ────────────────────────────────────────────────────────────────

  # Each key the step changed, reverted on what `now` holds there. A key the
  # step added goes when it is still the step's; one it removed comes back
  # when no one set it since.
  defp revert_map(from, to, now, field) do
    from
    |> Map.keys()
    |> Enum.concat(Map.keys(to))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(from, &1) == Map.get(to, &1)))
    |> Enum.reduce(now, fn key, acc ->
      case revert(Map.get(from, key), Map.get(to, key), Map.get(now, key), sub(field, key)) do
        nil -> if Map.has_key?(to, key), do: Map.put(acc, key, nil), else: Map.delete(acc, key)
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # ── Keyed lists ─────────────────────────────────────────────────────────

  defp revert_keyed(from, to, now, field) do
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
            [revert(from_by[key], to_by[key], item, member(field, item))]

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

  # ── Lists with no keys ──────────────────────────────────────────────────

  # Another editor at most added items at the end: the step is undone on
  # the items it was taken on, theirs kept after. Any other change since
  # moves positions: nothing.
  defp revert_unkeyed(from, to, now) do
    n = length(from)
    if Enum.take(now, n) == from, do: to ++ Enum.drop(now, n), else: now
  end
end
