defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.KeylessShift do
  @moduledoc """
  The lists whose keyless rows moved under A's page (task-7085fe2cc12fb328).

  A row with no `_key` goes by its index. When another editor puts a
  keyless row in before A's, or takes one out, the index A's page drew a
  row at names another row, and A's edit that did not clash with that
  row's blocks was merged into it with no banner (#29178 review, Q2-Q4c,
  and J2-J4c on a post with `_bp_rt_seen`). A list is moved when the
  indexes of the keyless rows A's page drew there (its owner entries with
  no key) are not the keyless rows the form holds there.

  Each rich text of such a list is read as a draw not known, on the post
  with `_bp_rt_seen` (`RichTextRemote.split/4`) and without it
  (`UnderLock.values/4`): the store kept, A held.

  A page re-rendered after the insert draws an entry at every index, so its
  indexes match (R2r): the entry at i keeps A's draw (its editor sits in an
  ignored wrapper), and that draw is the form's row j now. Two rows of one
  text post the same shape (#29235 review, D1-D5), and the post can't tell
  them apart. The socket's draw history can (`RowDraws.first/3`): the list
  moved when row j first had that draw from another editor's save, later
  than row i had it (task-8d968bba2cfa23c4). Rows of one text had it at
  mount, or by A's own write.
  """

  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.RowDraws
  alias BarkparkWeb.Studio.StudioLive.Path

  @doc "The moved lists' paths (`[\"sections\", 0, \"items\"]`), by the post's owner entries."
  def lists(socket, owners) do
    form = socket.assigns[:editor_form] || %{}
    Enum.uniq(by_index(form, owners) ++ by_history(socket, form, owners))
  end

  defp by_index(form, owners) do
    drawn =
      for entry <- List.wrap(owners),
          name <- [keyless(entry)],
          is_binary(name),
          path = Path.parse_path(name),
          length(path) >= 2,
          is_integer(row_index(path)),
          reduce: %{} do
        acc ->
          Map.update(
            acc,
            list_of(path),
            MapSet.new([row_index(path)]),
            &MapSet.put(&1, row_index(path))
          )
      end

    for {list, at} <- drawn, at != keyless_rows(FormPath.get(form, list)), do: list
  end

  # An entry's draw at i that is not the form's row i, but the form's
  # keyless row j, which first had it from another editor's save, after
  # row i had it.
  defp by_history(socket, form, owners) do
    for entry <- List.wrap(owners),
        {name, digest} <- [keyless_draw(entry)],
        is_binary(digest),
        path = Path.parse_path(name),
        length(path) >= 2,
        i = row_index(path),
        is_integer(i),
        list = list_of(path),
        rows = FormPath.get(form, list),
        is_list(rows),
        drawn(form, path) != digest,
        j <- keyless_rows(rows),
        j != i,
        at = List.replace_at(path, -2, j),
        drawn(form, at) == digest,
        later?(RowDraws.first(socket, at, digest), RowDraws.first(socket, path, digest)),
        uniq: true,
        do: list
  end

  defp later?({n_j, :theirs}, {n_i, _origin}), do: n_j > n_i
  defp later?(_at_j, _at_i), do: false

  defp drawn(form, path), do: CompositeField.drawn_digest(FormPath.get(form, path))

  @doc "The list a row rich text's row is in."
  def list_of(path), do: Enum.drop(path, -2)

  defp row_index(path), do: Enum.at(path, -2)

  defp keyless_rows(rows) when is_list(rows) do
    for {%{} = row, i} <- Enum.with_index(rows),
        not is_struct(row),
        Map.get(row, "_key") in [nil, ""],
        into: MapSet.new(),
        do: i
  end

  defp keyless_rows(_rows), do: MapSet.new()

  # An owner entry with no row key: its input name.
  defp keyless(entry) when is_binary(entry) do
    case Jason.decode(entry) do
      {:ok, [name, key | _]} when is_binary(name) and key in [nil, ""] -> name
      _ -> nil
    end
  end

  defp keyless(_entry), do: nil

  # An owner entry with no row key: its input name and the draw it names.
  defp keyless_draw(entry) when is_binary(entry) do
    case Jason.decode(entry) do
      {:ok, [name, key, digest | _]} when is_binary(name) and key in [nil, ""] -> {name, digest}
      _ -> nil
    end
  end

  defp keyless_draw(_entry), do: nil
end
