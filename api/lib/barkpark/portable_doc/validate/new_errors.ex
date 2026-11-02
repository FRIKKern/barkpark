defmodule Barkpark.PortableDoc.Validate.NewErrors do
  @moduledoc """
  The PortableDoc check on a paper write (R4.5): only the errors a write ADDS
  count, so a paper that is already broken never blocks a save.

  `split/2` validates the blocks about to be stored with
  `Barkpark.PortableDoc.Validate`; only when they have errors does it validate
  the stored blocks too, and it keeps, as added, every error the stored blocks
  did not already have. Two errors are the same when they have the same
  code at the same place, and a place is named from the nearest block with an
  `id` on its path: `{code, id, rest of the path}`. So inserting a block above
  a broken one moves the broken one's index without making its error new.
  Below the id, list indexes key as `*` (list items, table rows and inline
  nodes carry no id), so adding an item above a broken item leaves its error
  old. A path with no block id on it keys by the whole path. Errors are
  counted, not just matched, so a third block with a duplicated id, or a
  second broken item in one list, is one more error.

  Ingest, proposals and the validate dry run call `check/2` (whole doc). Ops
  and op batches call `check_touched/2`, which validates only the top-level
  blocks the write changed, added or dropped (`split_touched/2`): an unchanged
  block has the same errors on both sides. Both are report-only until the
  `:portable_doc_refuse_new_errors` config flag is on (`refuse?/0`):

    * off (the default): the write goes ahead; the added errors are logged and
      queued as a `portable_doc_invalid` warning (`Barkpark.Content.Warnings`)
      carrying `violations` (added) and `existing` (the old errors where it
      wrote), which an ingest, op or proposal reply carries out;
    * on: `{:error, {:halted, message}}`, the shape every paper ratchet uses, so
      each caller already renders it. The message names each added error and
      counts the old ones where it wrote.

  Known limits of naming a place by id: renaming a broken block's id makes
  its error read as added, and so does re-ingesting id-less blocks with one
  inserted above a broken one (ingest mints positional ids).

  Paths read as in `POST /v1/plugins/bulldocs/render`: `/blocks/2/level`. A
  block list that is not a list (an HTML-only paper write) is never checked.
  """

  require Logger

  alias Barkpark.Content.Warnings
  alias Barkpark.PortableDoc.Validate

  @warning_code "portable_doc_invalid"
  @named 5

  @doc "Whether a write that adds PortableDoc errors is refused (`:portable_doc_refuse_new_errors`)."
  @spec refuse?() :: boolean()
  def refuse?, do: Application.get_env(:barkpark, :portable_doc_refuse_new_errors, false) == true

  @doc "`{added, existing}`: the errors of `written` the `stored` blocks did not have, and the ones it did."
  @spec split(term(), term()) :: {[Validate.error()], [Validate.error()]}
  def split(stored, written) do
    case errors(written) do
      [] -> {[], []}
      found -> sort(found, stored, written)
    end
  end

  @doc """
  `split/2` for an op or a batch, which only changes some top-level blocks: a
  written block equal to the stored block with its id has the same errors on
  both sides, so only the other blocks are validated (the written ones that
  changed or are new, their stored versions, and stored blocks the write
  dropped). `duplicate_block_id` is the one rule that spans blocks: for each id
  the touched blocks now carry more often, the untouched blocks are searched
  for it too. An id-less top-level block always counts as touched. Falls back
  to `split/2` when top-level ids repeat on either side.
  """
  @spec split_touched(term(), term()) :: {[Validate.error()], [Validate.error()]}
  def split_touched(stored, written) when is_list(stored) and is_list(written) do
    with {:ok, stored_at, stored_idless} <- by_id(stored),
         {:ok, written_at, _written_idless} <- by_id(written) do
      written_touched =
        written
        |> Enum.with_index()
        |> Enum.reject(fn {block, _index} -> match?({^block, _}, stored_at[block["id"]]) end)

      stored_touched =
        stored_at
        |> Enum.filter(fn {id, {_block, _index}} ->
          not Map.has_key?(written_at, id) or
            Enum.any?(written_touched, fn {block, _index} -> block["id"] == id end)
        end)
        |> Enum.map(fn {_id, at} -> at end)
        |> Enum.concat(stored_idless)
        |> Enum.sort_by(fn {_block, index} -> index end)

      split_blocks(written_touched, stored_touched, stored, written)
    else
      _ -> split(stored, written)
    end
  end

  def split_touched(stored, written), do: split(stored, written)

  defp split_blocks(written_touched, stored_touched, stored, written) do
    written_reports = reports(written_touched)
    stored_reports = reports(stored_touched)
    found = Enum.flat_map(written_reports, fn {_index, errors, _ids} -> errors end)
    grown = grown_ids(written_reports, stored_reports)

    if found == [] and grown == [] do
      {[], []}
    else
      known = stored_reports |> Enum.flat_map(fn {_index, errors, _ids} -> errors end)
      {added, existing} = match(found, counts(known, stored), written)
      {dup_added, dup_existing} = duplicates(grown, written_reports, stored_reports, written)
      {added ++ dup_added, existing ++ dup_existing}
    end
  end

  defp reports(at) do
    Enum.map(at, fn {block, index} ->
      {errors, ids} = Validate.check_top_block(block, index)
      {index, errors, ids}
    end)
  end

  defp grown_ids(written_reports, stored_reports) do
    stored = id_counts(stored_reports)

    written_reports
    |> id_counts()
    |> Enum.filter(fn {id, n} -> n > Map.get(stored, id, 0) end)
    |> Enum.map(fn {id, _n} -> id end)
  end

  defp id_counts(reports),
    do:
      reports
      |> Enum.flat_map(fn {_index, _errors, ids} -> ids end)
      |> Enum.frequencies_by(&elem(&1, 0))

  defp duplicates([], _written_reports, _stored_reports, _written), do: {[], []}

  defp duplicates(grown, written_reports, stored_reports, written) do
    touched = MapSet.new(written_reports, fn {index, _errors, _ids} -> index end)

    untouched =
      written
      |> Enum.with_index()
      |> Enum.reject(fn {block, index} -> index in touched or not carries_id?(block, grown) end)
      |> reports()

    in_doc_order =
      (written_reports ++ untouched)
      |> Enum.sort_by(fn {index, _errors, _ids} -> index end)
      |> Enum.flat_map(fn {_index, _errors, ids} -> ids end)

    stored_counts = id_counts(stored_reports ++ untouched)

    grown
    |> Enum.map(fn id ->
      later = in_doc_order |> Enum.filter(&(elem(&1, 0) == id)) |> Enum.drop(1)
      old = max(Map.get(stored_counts, id, 0) - 1, 0)
      errors = Enum.map(later, fn {_id, path} -> %{code: :duplicate_block_id, path: path} end)
      Enum.split(errors, old) |> then(fn {existing, added} -> {added, existing} end)
    end)
    |> Enum.reduce({[], []}, fn {added, existing}, {all_added, all_existing} ->
      {all_added ++ added, all_existing ++ existing}
    end)
  end

  defp carries_id?(%{"id" => id} = map, ids) do
    id in ids or Enum.any?(map, fn {_key, value} -> carries_id?(value, ids) end)
  end

  defp carries_id?(map, ids) when is_map(map),
    do: Enum.any?(map, fn {_key, value} -> carries_id?(value, ids) end)

  defp carries_id?(list, ids) when is_list(list), do: Enum.any?(list, &carries_id?(&1, ids))
  defp carries_id?(_value, _ids), do: false

  defp by_id(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, []}, fn {block, index}, {:ok, at, idless} ->
      case block do
        %{"id" => id} when is_binary(id) and id != "" and is_map_key(at, id) ->
          {:halt, :repeated}

        %{"id" => id} when is_binary(id) and id != "" ->
          {:cont, {:ok, Map.put(at, id, {block, index}), idless}}

        _ ->
          {:cont, {:ok, at, idless ++ [{block, index}]}}
      end
    end)
  end

  defp sort(found, stored, written),
    do: match(found, stored |> errors() |> counts(stored), written)

  defp match(found, known, written) do
    root = root(written)

    {added, existing, _known} =
      Enum.reduce(found, {[], [], known}, fn error, {added, existing, known} ->
        key = key(error, root)

        case Map.get(known, key, 0) do
          0 -> {[error | added], existing, known}
          n -> {added, [error | existing], Map.put(known, key, n - 1)}
        end
      end)

    {Enum.reverse(added), Enum.reverse(existing)}
  end

  @doc "`:ok`, or the refusal when `refuse?/0` is on and `written` adds errors; reports them otherwise."
  @spec check(term(), term()) :: :ok | {:error, {:halted, String.t()}}
  def check(stored, written), do: verdict(split(stored, written))

  @doc "`check/2` through `split_touched/2`, for ops and batches."
  @spec check_touched(term(), term()) :: :ok | {:error, {:halted, String.t()}}
  def check_touched(stored, written), do: verdict(split_touched(stored, written))

  defp verdict({[], _existing}), do: :ok
  defp verdict({added, existing}), do: refuse_or_report(added, existing, refuse?())

  @doc "The refusal and warning text for `added` errors, with `existing` counted."
  @spec message([Validate.error()], [Validate.error()]) :: String.t()
  def message(added, existing) do
    named = added |> Enum.take(@named) |> Enum.map_join("; ", &"#{&1.code} at #{&1.path}")
    more = if length(added) > @named, do: " and #{length(added) - @named} more", else: ""

    "this write adds #{length(added)} PortableDoc error(s): #{named}#{more}" <>
      " (it keeps #{length(existing)} old error(s) where it wrote)"
  end

  defp refuse_or_report(added, existing, true), do: {:error, {:halted, message(added, existing)}}

  defp refuse_or_report(added, existing, false) do
    text = message(added, existing)
    Logger.warning("portable_doc report-only: " <> text)
    Warnings.put(@warning_code, text, "warning", %{violations: added, existing: existing})
    :ok
  end

  defp errors(blocks) when is_list(blocks) do
    case Validate.validate(%{"blocks" => blocks}) do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  defp errors(_blocks), do: []

  defp counts([], _blocks), do: %{}

  defp counts(errors, blocks) do
    root = root(blocks)
    Enum.frequencies_by(errors, &key(&1, root))
  end

  defp root(blocks), do: %{"blocks" => List.to_tuple(blocks)}

  defp key(%{code: code, path: path}, root) do
    {id, rest} =
      path
      |> segments()
      |> Enum.reduce({root, nil, []}, fn segment, {value, id, rest} ->
        {id, rest} = anchor(value, id, rest)
        {child(value, segment), id, [segment | rest]}
      end)
      |> then(fn {value, id, rest} -> anchor(value, id, rest) end)

    {code, id, rest |> Enum.reverse() |> below(id)}
  end

  defp below(rest, nil), do: rest
  defp below(rest, _id), do: Enum.map(rest, &any_index/1)

  defp any_index(segment) do
    case Integer.parse(segment) do
      {_index, ""} -> "*"
      _ -> segment
    end
  end

  defp anchor(%{"id" => id}, _id, _rest) when is_binary(id) and id != "", do: {id, []}
  defp anchor(_value, id, rest), do: {id, rest}

  defp child(blocks, segment) when is_tuple(blocks), do: elem(blocks, String.to_integer(segment))

  defp child(list, segment) when is_list(list) do
    case Integer.parse(segment) do
      {index, ""} -> Enum.at(list, index)
      _ -> nil
    end
  end

  defp child(map, segment) when is_map(map), do: Map.get(map, segment)
  defp child(_value, _segment), do: nil

  defp segments(""), do: []

  defp segments("/" <> path), do: String.split(path, "/")
end
