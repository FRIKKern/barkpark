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

  The digest is the server's own: 64 bits of sha256, as 16 hex characters
  (`digest/1`). The page never computes one, it only keeps what it was
  sent. It was a 27-bit `:erlang.phash2/1`, where a collision read a page
  typed on another value as typed on the store, and wrote over it
  (task-8a35dcc94956b8aa).

  A top-level rich text keeps one too, under its input name (`doc[body]`):
  the digest of the HTML its editor draws (`CompositeField.drawn_html/1`).
  Its wrapper is phx-update="ignore" and has the same id after a rejoin,
  so the page keeps the editor it had while the new socket reads the new
  store (#28933 review). It is drawn with the form, confirmed after a post
  the store holds as it draws (`confirm/3`), and again whenever the wrapper
  is drawn anew (`redrawn/2`, `loaded/1`). A socket that mounted as a rejoin
  (`_mounts` > 0) reads a top-level post against that digest until it has
  drawn or confirmed the field itself (`rejoin_seen/4`).
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues

  @event "bp:form-confirmed"
  @key "ok"

  @doc "The `_bp_seen` key the digests sit under."
  def key, do: @key

  @doc "The digest of a free-text value."
  def digest(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> binary_part(0, 8) |> Base.encode16(case: :lower)

  @doc "Per input name, the digest of each free-text value in `values` (`name => value`)."
  def oks(values) do
    for {name, value} <- values, is_binary(value), into: %{}, do: {name, digest(value)}
  end

  @doc "The digests a form drawn now starts from: each free-text value it shows."
  def drawn(schema, form) when is_map(form) do
    for(
      key <- RemoteValues.text_units(schema, form),
      value = RemoteValues.value_at(form, key),
      is_binary(value),
      into: %{},
      do: {RemoteValues.input_name(key), digest(value)}
    )
    |> Map.merge(rich_drawn(schema, form))
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
  Each top-level rich text field of `schema` its Classic editor draws as
  HTML. A field on the block editor (`FieldVocabulary.blocks_field?/1`) has
  no form input: its canvas carries its own revision.
  """
  def rich_keys(%{fields: fields}) when is_list(fields),
    do:
      for(
        %{"name" => key, "type" => "richText"} = field <- fields,
        is_binary(key),
        not Barkpark.PortableDoc.FieldVocabulary.blocks_field?(field),
        do: key
      )

  def rich_keys(_schema), do: []

  defp rich_drawn(schema, form) do
    for key <- rich_keys(schema),
        value = Map.get(form, key),
        is_binary(value) or is_list(value),
        into: %{},
        do: {RemoteValues.input_name(key), rich_digest(value)}
  end

  # The form holds a top-level rich text as the HTML its editor draws
  # (`Content.Forms`), the store as blocks: one digest for both.
  defp rich_digest(html) when is_binary(html), do: digest(html)
  # A body never set draws "" (`CompositeField.drawn_html(nil)`).
  defp rich_digest(value) when is_list(value) or is_nil(value),
    do: digest(CompositeField.drawn_html(value))

  defp rich_digest(_value), do: nil

  @doc """
  The base a top-level rich text post `name` is read against (`stored`, as
  `RichTextRemote.UnderLock.top/3` reads it), on a socket that mounted as a
  rejoin and has not drawn or confirmed that field itself: `stored` when the
  page's digest (`seen`, the raw `_bp_seen`) is the store's, else `:unknown`
  (`Forms.ObjectRebase` keeps the store's, and the post is held). The hold
  lasts until a Save or Reload: the page's digest does not move until then.
  """
  def rejoin_seen(socket, name, stored, seen) do
    rejoin = socket.assigns[:editor_rt_rejoin] || MapSet.new()

    cond do
      not MapSet.member?(rejoin, name) -> stored
      rich_known?(seen_oks(seen), name, stored) -> stored
      true -> :unknown
    end
  end

  defp seen_oks(seen) when is_binary(seen) do
    case Jason.decode(seen) do
      {:ok, %{@key => %{} = oks}} -> oks
      _ -> %{}
    end
  end

  defp seen_oks(_seen), do: %{}

  defp rich_known?(oks, name, stored),
    do: Map.get(oks, name) == rich_digest(stored)

  @doc """
  At a document's load: a socket that mounted as a rejoin reads each
  top-level rich text against the page's digest (`rejoin_seen/4`); any other
  load draws the wrappers anew, and the page is sent their digests.
  """
  def loaded(socket) do
    if socket.assigns[:editor_rejoined?] == true do
      names = Enum.map(rich_keys(socket.assigns[:editor_schema]), &RemoteValues.input_name/1)
      assign(socket, editor_rejoined?: false, editor_rt_rejoin: MapSet.new(names))
    else
      socket |> assign(editor_rt_rejoin: MapSet.new()) |> push_rich(socket.assigns[:editor_form])
    end
  end

  @doc """
  After a change that may have drawn the top-level rich text wrappers anew
  (a new form generation since `before`): the page shows the form's values.
  """
  def redrawn(socket, before) do
    if socket.assigns[:editor_form_gen] != before.assigns[:editor_form_gen],
      do: push_rich(socket, socket.assigns[:editor_form]),
      else: socket
  end

  # A held rich text stays in the rejoin set: its wrapper draws A's held
  # words (`RichTextRemote.keep_held`), not the store's, so a redraw caused
  # by another field (B's save of it, a desk paste) does not end the hold
  # (task-7234490778404641). A Save or Reload does.
  defp push_rich(socket, form) when is_map(form) do
    case rich_drawn(socket.assigns[:editor_schema], form) do
      oks when oks == %{} ->
        socket

      oks ->
        held = socket.assigns[:editor_rt_held] || %{}

        socket
        |> taken(Enum.reject(Map.keys(oks), &Map.has_key?(held, &1)))
        |> push_event(@event, %{oks: oks})
    end
  end

  defp push_rich(socket, _form), do: socket

  defp taken(socket, names),
    do:
      assign(socket,
        editor_rt_rejoin:
          MapSet.difference(socket.assigns[:editor_rt_rejoin] || MapSet.new(), MapSet.new(names))
      )

  @doc """
  The fields a rejoin hold of a top-level rich text paused (`rejoin_seen/4`),
  named by the banner's paused line beside the text fields `TextRejoin` held.
  """
  def paused(socket, rich) when is_map(rich) do
    held = socket.assigns[:editor_rt_held] || %{}
    keys = rich_keys(socket.assigns[:editor_schema])

    mine =
      for {name, {[key], :unknown, _page}} <- rich, Map.has_key?(held, name), do: key

    paused = (socket.assigns[:editor_text_paused] || []) -- keys
    assign(socket, editor_text_paused: Enum.uniq(paused ++ mine))
  end

  def paused(socket, _rich), do: socket

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

    oks = Map.merge(oks(confirmed), rich_confirmed(socket, text, posted))

    if oks == %{},
      do: socket,
      else: socket |> taken(Map.keys(oks)) |> push_event(@event, %{oks: oks})
  end

  def confirm(socket, _keys, _posted), do: socket

  # A top-level rich text post the store holds as it draws: the page shows
  # the stored value.
  defp rich_confirmed(socket, stored, posted) do
    for key <- rich_keys(socket.assigns[:editor_schema]),
        html = Map.get(posted, key),
        is_binary(html),
        value = Map.get(stored, key),
        is_list(value),
        PortableTextMerge.same_drawn?(PortableText.from_html(html, value), value),
        into: %{},
        do: {RemoteValues.input_name(key), rich_digest(value)}
  end
end
