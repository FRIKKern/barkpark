defmodule BarkparkWeb.Studio.StudioLive.KeptPicks do
  @moduledoc """
  A reference or image the page did not change is not its edit
  (task-e2c23aefdf44fad4).

  The reference and image widgets are drawn once (`phx-update="ignore"`):
  their hidden input keeps the value it was drawn with, and the page posts
  it with every change of the form. The save reads a posted value as an
  edit when it is not the editor's snapshot (`Content.Forms`). After a
  rejoin the snapshot is the new socket's load, so a page drawn before
  another editor picked a new reference posted its old one as an edit, and
  wrote it over theirs with no banner. A post in the instant before a
  remote save's redraw reaches the page does the same.

  Each widget also posts the value it was drawn with (`_bp_drawn[name]`,
  `FieldInputs.input/1`). `through/3` drops a top-level reference or image
  posted as drawn from a post that is not a change of that field, where the
  socket's form holds another value than the page drew: the store keeps
  what it holds. A pick or a clear is not the drawn value, so it is
  written, also when it rides on a key in another field (the body's change
  cancels the widget's own debounced one). A page's `_bp_drawn` can only
  keep a field from being written, never write one.

  A value this socket wrote from the page's own post is the page's
  (`editor_own_picks`): the widget is not drawn again after A's own pick, so
  its `_bp_drawn` stays the first value, and a pick back to it, on a key in
  another field or a Save, is A's and written (#29075 r1 review).

  A pick the page posts as this socket last wrote it, where the store has
  since moved to another editor's value, is dropped the same way: the page
  still shows A's own pick because the other save's redraw had not reached
  it (task-775ad6b350f78f2e). A pick of it again on its own change is A's.

  Where the store holds another value than the page drew, the widget is
  drawn again from it (`editor_pick_gens`, a part of its wrapper id), so the
  page shows it and posts it as drawn from then on. A nested reference or
  image (in an object or a row) is not read here.
  """

  import Phoenix.Component, only: [assign: 2]

  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Studio.StudioLive.{Path, PostIdentity}

  @types ~w(reference image)

  @doc """
  `fun`'s handling of the page's post `params` on `socket`, with each pick
  posted as drawn and not changed by this post left out, and each such
  widget drawn again where the store holds another value.
  """
  def through(params, socket, fun) do
    schema = socket.assigns[:editor_schema]
    form = socket.assigns[:editor_form] || %{}
    {params, dropped} = split(params, schema, form, own(socket))

    case fun.(params, socket) do
      {:noreply, socket} -> {:noreply, socket |> redraw(dropped) |> wrote(params)}
      {:reply, reply, socket} -> {:reply, reply, socket |> redraw(dropped) |> wrote(params)}
    end
  end

  @doc false
  def split(params, schema, form, own \\ %{})

  def split(%{"doc" => %{} = doc, "_bp_drawn" => %{} = drawn} = params, schema, form, own) do
    target = target(params)

    # Only where the form, the socket's newest stored value, draws another
    # value than the page did: a value the page shows as stored is posted
    # as before, so a bare-id reference still takes the `_ref` shape on the
    # next save (owner ruling #42).
    dropped =
      for %{"type" => type, "name" => name} <- fields(schema),
          type in @types,
          name != target,
          posted = Map.get(doc, name),
          is_binary(posted),
          stale?(posted, drawn[name], Map.get(own, name), drawn(type, Map.get(form, name))),
          into: %{},
          do: {name, {type, posted}}

    {params |> Map.put("doc", Map.drop(doc, Map.keys(dropped))) |> Map.delete("_bp_drawn"),
     dropped}
  end

  def split(params, _schema, _form, _own) when is_map(params),
    do: {Map.delete(params, "_bp_drawn"), %{}}

  # Posted as the page drew it, where the store holds neither that nor this
  # page's own pick.
  defp stale?(posted, posted, own, now), do: now not in [posted, own]

  # Posted as this page last wrote it, where the store has since moved to
  # another's value: the page still shows its own pick, the redraw of the
  # other save not yet drawn (task-775ad6b350f78f2e). A page that drew the
  # store's value and posts its own again picked it again: written.
  defp stale?(posted, drawn, posted, now), do: now != posted and drawn != now

  defp stale?(_posted, _drawn, _own, _now), do: false

  defp redraw(socket, dropped) when map_size(dropped) == 0, do: socket

  defp redraw(socket, dropped) do
    form = socket.assigns[:editor_form] || %{}

    moved = for {name, {type, was}} <- dropped, drawn(type, Map.get(form, name)) != was, do: name

    gens =
      Enum.reduce(moved, socket.assigns[:editor_pick_gens] || %{}, fn name, gens ->
        Map.update(gens, name, 1, &(&1 + 1))
      end)

    assign(socket, editor_pick_gens: gens)
  end

  # Each top-level reference or image the page posted that the form now
  # holds as posted: the form's value came from this page, of this document.
  defp wrote(socket, %{"doc" => %{} = doc}) do
    form = socket.assigns[:editor_form] || %{}

    mine =
      for %{"type" => type, "name" => name} <- fields(socket.assigns[:editor_schema]),
          type in @types,
          posted = Map.get(doc, name),
          is_binary(posted),
          drawn(type, Map.get(form, name)) == posted,
          into: own(socket),
          do: {name, posted}

    assign(socket, editor_own_picks: {PostIdentity.of(socket), mine})
  end

  defp wrote(socket, _params), do: socket

  defp own(socket) do
    case socket.assigns[:editor_own_picks] do
      {doc, picks} -> if doc == PostIdentity.of(socket), do: picks, else: %{}
      _ -> %{}
    end
  end

  # The value the widget draws for a form value (`FieldInputs.input/1`).
  defp drawn("reference", value), do: FieldInputs.reference_id(value)
  defp drawn("image", value), do: FieldInputs.image_form_value(value)

  # The top-level field this post is a change of: `["doc", "body"]` or
  # `["doc[body]"]`; nil for the Save button's post, which names none.
  defp target(%{"_target" => ["doc", name | _]}) when is_binary(name), do: name

  defp target(%{"_target" => [name]}) when is_binary(name) do
    case Path.parse_path(name) do
      [key | _] when is_binary(key) -> key
      _ -> nil
    end
  end

  defp target(_params), do: nil

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp fields(_schema), do: []
end
