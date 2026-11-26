defmodule BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed do
  @moduledoc """
  The value of each free-text field the server last confirmed the page
  shows, carried by the page across a socket rejoin (task-fe9d8741f0641f97).

  A page that rejoins a new socket keeps its `_bp_seen` numbers, which only
  the old socket could read (`TextRejoin`). A post typed on a value the new
  socket never sent was held, but the hold could not tell a wifi blip with
  nobody else saving from a save B made while A was away. So the page also
  keeps, per field, a digest of the last value the server confirmed it shows
  (`"ok"` in `_bp_seen`):

    * drawn with the form (`drawn/2`),
    * sent after each post whose value the store holds as posted
      (`confirm/3`, `bp:form-confirmed`),
    * and beside each value the server pushes (`oks/1`), which
      bp-array-focus.js takes only when the field shows that value.

  On a rejoined socket, a post whose digest is the store's (`known?/3`) was
  typed on the store: it is read as any post. One whose digest differs, or
  has none, was typed on a value the store no longer holds: it is held.

  The digest is the server's own (`:erlang.phash2/1`); the page never
  computes one, it only keeps what it was sent.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues

  @event "bp:form-confirmed"
  @key "ok"

  @doc "The `_bp_seen` key the digests sit under."
  def key, do: @key

  @doc "The digest of a free-text value."
  def digest(value) when is_binary(value), do: :erlang.phash2(value)

  @doc "Per input name, the digest of each free-text value in `values` (`name => value`)."
  def oks(values) do
    for {name, value} <- values, is_binary(value), into: %{}, do: {name, digest(value)}
  end

  @doc "The digests a form drawn now starts from: each free-text value it shows."
  def drawn(schema, form) when is_map(form) do
    for key <- RemoteValues.text_units(schema, form),
        value = RemoteValues.value_at(form, key),
        is_binary(value),
        into: %{},
        do: {RemoteValues.input_name(key), digest(value)}
  end

  def drawn(_schema, _form), do: %{}

  @doc """
  Whether the post (`seen`, the raw `_bp_seen`) says the page last took
  `stored`, the value of `key` the store holds.
  """
  def known?(seen, key, stored) when is_binary(seen) and is_binary(stored) do
    case Jason.decode(seen) do
      {:ok, %{@key => %{} = oks}} -> Map.get(oks, RemoteValues.input_name(key)) == digest(stored)
      _ -> false
    end
  end

  def known?(_seen, _key, _stored), do: false

  @doc """
  Tells the page each free-text field in `keys` whose posted value (`posted`,
  the post's doc) the store now holds: the page shows the stored value.
  """
  def confirm(socket, keys, posted) when is_map(posted) do
    doc = socket.assigns[:editor_doc]

    text =
      case doc do
        %{content: content} ->
          Map.put(if(is_map(content), do: content, else: %{}), "title", doc.title)

        _ ->
          %{}
      end

    confirmed =
      for key <- keys,
          mine = RemoteValues.value_at(posted, key),
          is_binary(mine),
          RemoteValues.value_at(text, key) == mine,
          into: %{},
          do: {RemoteValues.input_name(key), mine}

    if confirmed == %{}, do: socket, else: push_event(socket, @event, %{oks: oks(confirmed)})
  end

  def confirm(socket, _keys, _posted), do: socket
end
