defmodule Barkpark.PortableDoc.Validate.NewErrors do
  @moduledoc """
  The PortableDoc check on a paper write (R4.5): only the errors a write ADDS
  count, so a paper that is already broken never blocks a save.

  `split/2` validates the stored blocks and the blocks about to be stored with
  `Barkpark.PortableDoc.Validate` and keeps, as added, every error the stored
  blocks did not already have. Two errors are the same when they have the same
  code at the same place, and a place is named from the nearest block with an
  `id` on its path: `{code, id, rest of the path}`. So inserting a block above
  a broken one moves the broken one's index without making its error new. A
  path with no block id on it keys by the whole path. Errors are counted, not
  just matched, so a third block with a duplicated id is one more error.

  `check/2` is what the write paths call. Report-only until the
  `:portable_doc_refuse_new_errors` config flag is on (`refuse?/0`):

    * off (the default): the write goes ahead; the added errors are logged and
      queued as a `portable_doc_invalid` warning (`Barkpark.Content.Warnings`)
      carrying `violations` (added) and `existing` (already there), which an
      ingest, op or proposal reply carries out;
    * on: `{:error, {:halted, message}}`, the shape every paper ratchet uses, so
      each caller already renders it. The message names each added error and
      how many were already there.

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
    known = stored |> errors() |> Enum.frequencies_by(&key(&1, stored))

    {added, existing, _known} =
      written
      |> errors()
      |> Enum.reduce({[], [], known}, fn error, {added, existing, known} ->
        key = key(error, written)

        case Map.get(known, key, 0) do
          0 -> {[error | added], existing, known}
          n -> {added, [error | existing], Map.put(known, key, n - 1)}
        end
      end)

    {Enum.reverse(added), Enum.reverse(existing)}
  end

  @doc "`:ok`, or the refusal when `refuse?/0` is on and `written` adds errors; reports them otherwise."
  @spec check(term(), term()) :: :ok | {:error, {:halted, String.t()}}
  def check(stored, written) do
    case split(stored, written) do
      {[], _existing} -> :ok
      {added, existing} -> refuse_or_report(added, existing, refuse?())
    end
  end

  @doc "The refusal and warning text for `added` errors, with `existing` counted."
  @spec message([Validate.error()], [Validate.error()]) :: String.t()
  def message(added, existing) do
    named = added |> Enum.take(@named) |> Enum.map_join("; ", &"#{&1.code} at #{&1.path}")
    more = if length(added) > @named, do: " and #{length(added) - @named} more", else: ""

    "this write adds #{length(added)} PortableDoc error(s): #{named}#{more}" <>
      " (#{length(existing)} already in the paper stay as they are)"
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

  defp key(%{code: code, path: path}, blocks) do
    {id, rest} =
      path
      |> segments()
      |> Enum.reduce({%{"blocks" => blocks}, nil, []}, fn segment, {value, id, rest} ->
        {id, rest} = anchor(value, id, rest)
        {child(value, segment), id, [segment | rest]}
      end)
      |> then(fn {value, id, rest} -> anchor(value, id, rest) end)

    {code, id, Enum.reverse(rest)}
  end

  defp anchor(%{"id" => id}, _id, _rest) when is_binary(id) and id != "", do: {id, []}
  defp anchor(_value, id, rest), do: {id, rest}

  defp child(list, segment) when is_list(list) do
    case Integer.parse(segment) do
      {index, ""} -> Enum.at(list, index)
      _ -> nil
    end
  end

  defp child(map, segment) when is_map(map), do: Map.get(map, segment)
  defp child(_value, _segment), do: nil

  defp segments(""), do: []

  defp segments("/" <> path),
    do:
      path
      |> String.split("/")
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
end
