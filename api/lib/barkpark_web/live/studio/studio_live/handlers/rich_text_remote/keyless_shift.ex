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
  moved when A typed in row i (the post is not its draw), and ONE save of
  another editor's both gave row j that draw there and gave row i a value
  (task-8d968bba2cfa23c4). Row i need not hold that value now: Studio's
  add saves an empty row at once, and B types in it with later saves
  (#29315 review, T2, T2b). And A's post at row i is not built on the
  form's row i now: with `_bp_rt_seen`, the page's number for row i is
  at or past the last change the socket logged there; without it, the
  post holds row i's blocks now and not the old draw's. A page whose idle
  row took B's pushes, typing on B's value, is no move (#29336 review,
  BT4, PU1, PU2). Rows of one text had it at
  mount, or by A's own write: A's own typing changes row i, and B adding,
  clearing or copying a row is no move (#29315 review, E1-E3). An empty
  draw is never read as one: every new row has it. A Reload starts the
  history again (`RowDraws.reload/2`): the page shows the form then
  (RL1, RL2).
  """

  alias Barkpark.Content.PortableText
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.RowDraws
  alias BarkparkWeb.Studio.StudioLive.Path

  @doc """
  The moved lists' paths (`[\"sections\", 0, \"items\"]`), by the post's
  owner entries, its values (`posted`, the post's `doc`) and its
  `_bp_rt_seen` (`seen`, nil for a post without).
  """
  def lists(socket, owners, posted, seen \\ nil) do
    form = socket.assigns[:editor_form] || %{}
    Enum.uniq(by_index(form, owners) ++ by_history(socket, form, owners, {posted, seen}))
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

  # An entry's draw at i that A typed on, that is not the form's row i but
  # the form's keyless row j, with words, and one save of another editor's
  # gave row j that draw and row i a value.
  defp by_history(socket, form, owners, {posted, seen}) do
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
        now = drawn(form, path),
        now != digest,
        j <- keyless_rows(rows),
        j != i,
        at = List.replace_at(path, -2, j),
        drawn(form, at) == digest,
        words?(FormPath.get(form, at)),
        one_save?(RowDraws.first(socket, at, digest), RowDraws.firsts(socket, path)),
        typed?(FormPath.get(posted, path), digest),
        not on_now?(socket, {name, path}, FormPath.get(posted, path), {digest, seen}),
        uniq: true,
        do: list
  end

  defp one_save?({_n, :theirs} = at_j, at_i), do: at_j in at_i
  defp one_save?(_at_j, _at_i), do: false

  # A's post at row i is built on the form's row i now, not on A's old
  # draw. With `_bp_rt_seen`: the page's number for row i is past every
  # change logged there. Without: the post holds row i's blocks now and
  # not the old draw's (an old draw not kept: row i's alone).
  defp on_now?(socket, {name, _path}, _html, {_digest, seen}) when is_list(seen) do
    n =
      Enum.find_value(seen, 0, fn entry ->
        case RichTextRemote.parse_seen(entry) do
          {^name, n} -> n
          _ -> nil
        end
      end)

    n > 0 and is_nil(RichTextRemote.page_base(socket, name, n))
  end

  defp on_now?(socket, {_name, path}, html, {digest, _seen}) when is_binary(html) do
    lines = html |> PortableText.from_html([]) |> texts() |> MapSet.new()
    now = FormPath.get(socket.assigns[:editor_form] || %{}, path)

    old =
      case RowDraws.fetch(socket, path, "", digest) do
        {:ok, value} -> words?(value) and holds?(lines, value)
        :error -> false
      end

    holds?(lines, now) and not old
  end

  defp on_now?(_socket, _at, _html, _seen), do: false

  defp holds?(lines, value), do: Enum.all?(texts(value), &MapSet.member?(lines, &1))

  # Each block's words, its blank ones left out.
  defp texts(blocks) when is_list(blocks) do
    for %{"children" => children} when is_list(children) <- blocks,
        text = children |> Enum.map(&(&1["text"] || "")) |> Enum.join() |> String.trim(),
        text != "",
        do: text
  end

  defp texts(_value), do: []

  # The post's HTML at a row is not the draw its entry names.
  defp typed?(html, digest) when is_binary(html),
    do: CompositeField.drawn_digest(PortableText.from_html(html, [])) != digest

  defp typed?(_html, _digest), do: false

  # A value that is not only empty text blocks (an image block counts).
  defp words?(blocks) when is_list(blocks), do: not Enum.all?(blocks, &wordless_block?/1)
  defp words?(_value), do: false

  defp wordless_block?(%{"children" => children}) when is_list(children),
    do: Enum.all?(children, &wordless_span?/1)

  defp wordless_block?(_block), do: false

  defp wordless_span?(%{"text" => text}) when is_binary(text), do: String.trim(text) == ""
  defp wordless_span?(%{} = span), do: not Map.has_key?(span, "text")
  defp wordless_span?(_span), do: false

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
