defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.RowDraws do
  @moduledoc """
  The values a row's rich text editor may show, by the row's `_key` and the
  digest of the value drawn (task-82519fd79663e072, #29040 r1 review).

  A row's editor posts its owner entry, `[name, row key, digest of the
  value drawn]` (`CompositeField`). Its name carries the row's index, which
  moves when a row is moved, added or taken out, A's own presses included;
  the key and the digest do not. So the draws a post may name are kept by
  the row's key, never by the index:

    * the value this socket was born with (`RichTextRemote.born/1`) and
      each value it took from another editor's save or a Reload
      (`record_form/2`),
    * A's own last post on a draw (`record_own/4`): the page shows its own
      words on that draw, and draws them on its next remount.

  `fetch/4` finds the value a post was typed on; none is `:error`.

  Each draw also keeps when the socket first had it there, and how
  (`first/3`): with the socket's own born value, from another editor's
  save or a Reload (`:theirs`), or from A's own write (`:own`). A keyless
  row goes by its index, so a value first had at an index from another
  editor's save, after A's page drew it at another index, moved there
  (`KeylessShift`, task-8d968bba2cfa23c4).
  """

  import Phoenix.Component, only: [assign: 3]

  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  # Draws kept per row rich text: A's typing adds one per post.
  @cap 8

  @doc "Whether a rich text's path is inside a row (it carries an index)."
  def row?(path), do: Enum.any?(path, &is_integer/1)

  @doc """
  Records each row rich text value of `form` under its row key and digest.
  `origin` is how the socket came to hold `form`: `:born`, `:theirs` (another
  editor's save, a Reload) or `:own` (A's own write or press).
  """
  def record_form(socket, form, origin \\ :own)

  def record_form(socket, form, origin) when is_map(form) do
    entries =
      for path <- RichTextRemote.every(socket.assigns[:editor_schema], form),
          row?(path),
          key = row_key(form, path),
          value = FormPath.get(form, path),
          do: {key, {id(form, path, key), CompositeField.drawn_digest(value), value}}

    # A row A removed that the form holds again (B's save or a Reload brought
    # its key back) is no longer A's removal (`DroppedRows.removed/2`).
    socket
    |> record(Enum.map(entries, &elem(&1, 1)), origin)
    |> RichTextRemote.DroppedRows.back(Enum.map(entries, &elem(&1, 0)))
  end

  def record_form(socket, _form, _origin), do: socket

  @doc """
  Records A's own `value`, posted on the draw `digest` of the row `key` at
  `path`: under that draw, and under its own digest, which the next remount
  of the row draws.
  """
  def record_own(socket, path, {key, digest}, value) do
    id = id(form(socket), path, key)

    record(
      socket,
      [
        {id, digest, value},
        {id, CompositeField.drawn_digest(value), value}
      ],
      :own
    )
  end

  @doc """
  Records `form` after a Reload or a restore (`RichTextRemote.repaint/2`):
  the page is told every value then, so when each draw was first had
  starts again, as at mount (#29315 review, RL1-RL2).
  """
  def reload(socket, form) do
    socket
    |> assign(:editor_rt_row_first, nil)
    |> record_form(form, :born)
  end

  @doc """
  When the socket first had the draw `digest` at the keyless row rich text
  `path`, and how: `{n, origin}`, a larger `n` later; `nil` when not kept.
  """
  def first(socket, path, digest) do
    case socket.assigns[:editor_rt_row_first] do
      {doc, _n, %{} = firsts} when not is_nil(doc) ->
        if doc == PostIdentity.of(socket), do: Map.get(firsts, {{path, ""}, digest})

      _ ->
        nil
    end
  end

  @doc """
  The draws this socket kept for each rich text of the keyless row at
  `row` (its path, `["rows", 0]`), by digest (`DroppedRows.removed/3`).
  """
  def keyless_digests(socket, row) do
    n = length(row)

    for {{path, ""}, draws} <- all(socket),
        Enum.take(path, n) == row,
        {digest, _value} <- draws,
        do: digest
  end

  @doc """
  The value the draw `digest` of the row `key` at `path` showed. A number
  is the 27-bit digest a page drawn before the 64-bit one posts
  (task-9b705d11bf85560e): read by the old hash of each draw, as before.
  """
  def fetch(socket, path, key, digest) do
    draws = Map.get(all(socket), id(form(socket), path, key), [])

    found =
      if is_integer(digest),
        do: Enum.find(draws, fn {d, value} -> d == digest or legacy(value) == digest end),
        else: List.keyfind(draws, digest, 0)

    case found do
      {_digest, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp legacy(value), do: :erlang.phash2(CompositeField.drawn_html(value))

  # A row rich text is named by its path without indexes, the `_key` of
  # each row it sits in on the way (read from `form` at `path`), and its own
  # row's key. Two sections whose items share a key (a duplicated section)
  # shared one list of draws, by the inner key alone, and one section's
  # saves pushed the other's out (task-3811ae4146de3c91). A row with no key
  # (task-12ff178d188b04b4) has only its index, as before, at any depth.
  defp id(form, path, key) do
    case to_string(key) do
      "" -> {path, ""}
      key -> {Enum.reject(path, &is_integer/1), outer_keys(form, path), key}
    end
  end

  @doc """
  The `_key` of each row a field at `path` sits in, read from `form`, its
  own row's left out; a row with no key gives its index. The row editor's
  wrapper id names them too (`CompositeField`).
  """
  def outer_keys(form, path) do
    path
    |> Enum.with_index()
    |> Enum.filter(fn {seg, _n} -> is_integer(seg) end)
    |> Enum.drop(-1)
    |> Enum.map(fn {i, n} ->
      case FormPath.get(form, Enum.take(path, n + 1)) do
        %{"_key" => k} when is_binary(k) and k != "" -> k
        _ -> i
      end
    end)
  end

  defp form(socket), do: socket.assigns[:editor_form] || %{}

  defp row_key(form, path) do
    case FormPath.get(form, Enum.drop(path, -1)) do
      %{"_key" => key} when is_binary(key) -> key
      _ -> ""
    end
  end

  defp record(socket, [], _origin), do: socket

  defp record(socket, entries, origin) do
    case PostIdentity.of(socket) do
      nil ->
        socket

      doc ->
        draws =
          Enum.reduce(entries, all(socket), fn {id, digest, value}, draws ->
            kept = Map.get(draws, id, []) |> List.keydelete(digest, 0)
            Map.put(draws, id, Enum.take([{digest, value} | kept], @cap))
          end)

        socket
        |> assign(:editor_rt_row_draws, {doc, draws})
        |> record_first(doc, entries, origin, draws)
    end
  end

  # Only a keyless row's draws (`{path, ""}`): a keyed row goes by its key.
  # A draw pushed out of `draws` is forgotten here too.
  defp record_first(socket, doc, entries, origin, draws) do
    {n, firsts} =
      case socket.assigns[:editor_rt_row_first] do
        {^doc, n, %{} = firsts} -> {n + 1, firsts}
        _ -> {1, %{}}
      end

    firsts =
      for({{_path, ""} = id, digest, _value} <- entries, reduce: firsts) do
        acc -> Map.put_new(acc, {id, digest}, {n, origin})
      end
      |> Map.filter(fn {{id, digest}, _} ->
        List.keymember?(Map.get(draws, id, []), digest, 0)
      end)

    assign(socket, :editor_rt_row_first, {doc, n, firsts})
  end

  defp all(socket) do
    case socket.assigns[:editor_rt_row_draws] do
      {doc, %{} = draws} when not is_nil(doc) ->
        if doc == PostIdentity.of(socket), do: draws, else: %{}

      _ ->
        %{}
    end
  end
end
