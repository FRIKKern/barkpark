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
  (`UnderLock.values/4`): the store kept, A held. A page re-rendered after
  the insert draws an entry at every index, so its indexes match (R2r):
  telling that from two rows of the same text needs the socket's draw
  history, not the post (#29235 review, D1-D5).
  """

  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Path

  @doc "The moved lists' paths (`[\"sections\", 0, \"items\"]`), by the post's owner entries."
  def lists(form, owners) do
    form = form || %{}

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
end
