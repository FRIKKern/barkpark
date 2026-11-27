defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.KeylessShift do
  @moduledoc """
  The lists whose keyless rows moved under A's page (task-7085fe2cc12fb328).

  A row with no `_key` goes by its index. When another editor puts a
  keyless row in before A's, or takes one out, the index A's page drew a
  row at names another row, and A's edit that did not clash with that
  row's blocks was merged into it with no banner (#29178 review, Q2-Q4c).
  A list is moved when either:

    * the indexes of the keyless rows A's page drew there (its owner
      entries with no key) are not the keyless rows the form holds there;
    * or a draw at index i is not the form's row at i, but is the form's
      keyless row at another index: the page re-rendered after the insert,
      drawing an entry at every index, the first still with A's draw (its
      editor sits in an ignored wrapper), so the indexes match (R2r).

  Each rich text of such a list is read as a draw not known, on the post
  with `_bp_rt_seen` (`RichTextRemote.split/4`) and without it
  (`UnderLock.values/4`): the store kept, A held. A draw found at no index
  is the row edited in place, and merges as before.
  """

  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Path

  @doc "The moved lists' paths (`[\"sections\", 0, \"items\"]`), by the post's owner entries."
  def lists(form, owners) do
    form = form || %{}

    drawn =
      for entry <- List.wrap(owners),
          {name, digest} <- [keyless(entry)],
          path = Path.parse_path(name),
          length(path) >= 2,
          is_integer(row_index(path)),
          reduce: %{} do
        acc -> Map.update(acc, list_of(path), [{path, digest}], &[{path, digest} | &1])
      end

    for {list, draws} <- drawn, moved?(FormPath.get(form, list), draws), do: list
  end

  @doc "The list a row rich text's row is in."
  def list_of(path), do: Enum.drop(path, -2)

  defp row_index(path), do: Enum.at(path, -2)

  defp moved?(rows, draws) do
    places = MapSet.new(draws, fn {path, _} -> row_index(path) end)
    places != keyless_rows(rows) or Enum.any?(draws, &elsewhere?(rows, &1))
  end

  # A draw that is not the row at its index, but a keyless row at another.
  defp elsewhere?(rows, {path, digest}) do
    i = row_index(path)
    name = List.last(path)

    not drawn?(text(rows, i, name), digest) and
      Enum.any?(keyless_rows(rows), &(&1 != i and drawn?(text(rows, &1, name), digest)))
  end

  defp text(rows, i, name), do: FormPath.get(rows, [i, name])

  defp keyless_rows(rows) when is_list(rows) do
    for {%{} = row, i} <- Enum.with_index(rows),
        not is_struct(row),
        Map.get(row, "_key") in [nil, ""],
        into: MapSet.new(),
        do: i
  end

  defp keyless_rows(_rows), do: MapSet.new()

  # A page drawn before the hex digest posts the old number (`RowDraws`).
  defp drawn?(value, digest) when is_list(value) and is_integer(digest),
    do: :erlang.phash2(CompositeField.drawn_html(value)) == digest

  defp drawn?(value, digest) when is_list(value) and is_binary(digest),
    do: CompositeField.drawn_digest(value) == digest

  defp drawn?(_value, _digest), do: false

  # An owner entry with no row key: its input name and draw digest.
  defp keyless(entry) when is_binary(entry) do
    case Jason.decode(entry) do
      {:ok, [name, key, digest | _]}
      when is_binary(name) and key in [nil, ""] and (is_binary(digest) or is_integer(digest)) ->
        {name, digest}

      _ ->
        nil
    end
  end

  defp keyless(_entry), do: nil
end
