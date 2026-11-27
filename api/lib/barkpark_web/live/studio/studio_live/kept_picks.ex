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
  another field or a Save, is A's and written (#29075 r1 review). Only a
  pick is kept (a posted value that is not the drawn one; one posted as
  drawn drops it), with the drawing it was made on, and a document load
  drops them all (`Shared.rebuild_panes/1`). A pick back counts only on that
  drawing: a remote replace draws the widget again from the store (a new
  form generation, or the widget's own). Read past it, the store taking
  back A's old pick made the redrawn widget's stale post read as A's
  (task-030e09c0bde818b1). A pick is kept for the drawing its widget posts
  (`_bp_drawn_at[name]`) where that is an earlier one than the socket's: a
  pick posted from the old drawing after another's redraw is not on the
  redrawn widget, so that widget's next post is not read as a pick back
  (task-b7d86444f258c7aa). The posted drawing only moves a pick off the
  drawing the socket shows, so it can keep a post from being written, never
  write one.

  A pick the page posts as this socket last wrote it, where the store has
  since moved to another editor's value, is dropped the same way: the page
  still shows A's own pick because the other save's redraw had not reached
  it (task-775ad6b350f78f2e). A pick of it again on its own change is A's.

  Where the store holds another value than the page drew, the widget is
  drawn again from it (`editor_pick_gens`, a part of its wrapper id), so the
  page shows it and posts it as drawn from then on. A nested reference or
  image (in an object or a row) is not read here.

  A pick made on the widget drawn from the socket's form (posted as another
  value than drawn, drawn as the form holds it, on the drawing the socket
  draws now: `_bp_drawn_at`) is a change of that field,
  as the post's target is (`editor_post_picks`, read with
  `editor_post_target`): the save reads it against the newest stored
  version this tab saw, not this tab's own last row (`Lifecycle.post_base/1`,
  `PostedEdits`). Read against its own row, A's pick of X again after B's Y
  was drawn equalled A's own earlier X, read as untouched, and the desk kept
  B's Y (task-36b1558c058a5f3b).
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
    drawn = params["_bp_drawn"]
    at = picked_on(params, socket)
    picks = picked(params, {drawn, params["_bp_drawn_at"]}, socket, {schema, form})

    {params, dropped} =
      split(params, schema, form, {own(socket, :now), own(socket, :any), earlier(at, socket)})

    socket = assign(socket, editor_post_picks: picks)

    case fun.(params, socket) do
      {:noreply, socket} ->
        {:noreply, socket |> done() |> redraw(dropped) |> wrote(params, {drawn, at})}

      {:reply, reply, socket} ->
        {:reply, reply, socket |> done() |> redraw(dropped) |> wrote(params, {drawn, at})}
    end
  end

  @doc false
  # `own`: this document's picks kept for the drawing on the page now, and
  # its picks as this socket last wrote them, whatever was drawn since.
  def split(params, schema, form, own \\ {%{}, %{}, MapSet.new()})

  def split(
        %{"doc" => %{} = doc, "_bp_drawn" => %{} = drawn} = params,
        schema,
        form,
        {now, any, earlier}
      ) do
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
          stale?(
            posted,
            drawn[name],
            {Map.get(now, name), Map.get(any, name)},
            {drawn(type, Map.get(form, name)), MapSet.member?(earlier, name)}
          ),
          into: %{},
          do: {name, {type, posted}}

    {params |> Map.put("doc", Map.drop(doc, Map.keys(dropped))) |> strip(), dropped}
  end

  def split(params, _schema, _form, _own) when is_map(params), do: {strip(params), %{}}

  defp strip(params), do: Map.drop(params, ["_bp_drawn", "_bp_drawn_at"])

  # Posted as the page drew it, where the store holds neither that nor this
  # page's own pick made on that drawing (task-030e09c0bde818b1: a pick made
  # before the widget was drawn again is not a pick back on it).
  defp stale?(posted, posted, {own, _any}, {now, _earlier?}), do: now not in [posted, own]

  # Posted as this page last wrote it, where the store has since moved to
  # another's value: the page still shows its own pick, the redraw of the
  # other save not yet drawn (task-775ad6b350f78f2e). A page that drew the
  # store's value and posts its own again picked it again: written, but only
  # from the drawing the socket draws now. From an earlier one, the store
  # moved back to the value the old widget was drawn with (B's undo of A's
  # pick) and the redraw has not reached the page: the post is A's old pick,
  # not one on the store's value (task-2e3d79fc1480d2db, the Studio's H1).
  defp stale?(posted, drawn, {_own, posted}, {now, earlier?}),
    do: now != posted and (drawn != now or earlier?)

  defp stale?(_posted, _drawn, _own, _now), do: false

  # The picks this post's widgets posted from an earlier drawing than the
  # socket draws now (`picked_on/2`). A forged or missing `_bp_drawn_at`
  # can only drop A's own pick posted again, never write a post.
  defp earlier(at, socket) do
    for %{"type" => type, "name" => name} <- fields(socket.assigns[:editor_schema]),
        type in @types,
        at.(name) != gen(socket, name),
        into: MapSet.new(),
        do: name
  end

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

  # Each top-level reference or image the page picked (posted as another
  # value than it was drawn with) that the form now holds as posted, with the
  # drawing it was picked on. One posted as drawn is the drawing's, not a
  # pick: a record of that name goes.
  defp wrote(socket, %{"doc" => %{} = doc}, {drawn, at}) do
    form = socket.assigns[:editor_form] || %{}
    drawn = if is_map(drawn), do: drawn, else: %{}

    mine =
      Enum.reduce(fields(socket.assigns[:editor_schema]), kept(socket, :any), fn
        %{"type" => type, "name" => name}, acc when type in @types ->
          posted = Map.get(doc, name)

          cond do
            not is_binary(posted) ->
              acc

            posted == drawn[name] ->
              Map.delete(acc, name)

            drawn(type, Map.get(form, name)) == posted ->
              Map.put(acc, name, {posted, at.(name)})

            true ->
              acc
          end

        _field, acc ->
          acc
      end)

    assign(socket, editor_own_picks: {PostIdentity.of(socket), mine})
  end

  defp wrote(socket, _params, _drawn), do: socket

  defp own(socket, drawing),
    do: Map.new(kept(socket, drawing), fn {name, {value, _gen}} -> {name, value} end)

  # This document's picks as this socket last wrote them (`:any`), or only
  # those made on the widget drawing the socket draws now (`:now`).
  defp kept(socket, drawing) do
    case socket.assigns[:editor_own_picks] do
      {doc, %{} = picks} ->
        if doc == PostIdentity.of(socket),
          do:
            for(
              {name, {_value, gen} = pick} <- picks,
              drawing == :any or gen == gen(socket, name),
              into: %{},
              do: {name, pick}
            ),
          else: %{}

      _ ->
        %{}
    end
  end

  # The drawing a pick of this post is kept for: the one its widget posts
  # (`_bp_drawn_at[name]`, `FieldInputs.pick_drawing/3`) where that is an
  # earlier one than the socket draws now, else the socket's. Kept for the
  # socket's drawing, a pick in flight across another's redraw read the
  # redrawn widget's next post as a pick back (task-b7d86444f258c7aa).
  # Both parts of a drawing only grow on a socket's document, so a pick kept
  # for an earlier one never counts as on the drawing again: a forged or
  # missing `_bp_drawn_at` can only lose a pick back, never write a post
  # that would be dropped.
  defp picked_on(params, socket) do
    posted = if is_map(params["_bp_drawn_at"]), do: params["_bp_drawn_at"], else: %{}

    fn name ->
      {f, p} = now = gen(socket, name)

      case parse(posted[name]) do
        {pf, pp} = at when pf <= f and pp <= p and at != now -> at
        _ -> now
      end
    end
  end

  defp parse(drawing) when is_binary(drawing) do
    with [f, p] <- String.split(drawing, "."),
         {f, ""} when f >= 0 <- Integer.parse(f),
         {p, ""} when p >= 0 <- Integer.parse(p),
         do: {f, p},
         else: (_ -> nil)
  end

  defp parse(_drawing), do: nil

  # The drawing of `name`'s widget: its wrapper id's form generation and its
  # own (`FieldInputs.pick_wrap_id/5`, `FieldInputs.pick_drawing/3`).
  defp gen(socket, name),
    do:
      {socket.assigns[:editor_form_gen] || 0,
       Map.get(socket.assigns[:editor_pick_gens] || %{}, name, 0)}

  # The value the widget draws for a form value (`FieldInputs.input/1`).
  defp drawn("reference", value), do: FieldInputs.reference_id(value)
  defp drawn("image", value), do: FieldInputs.image_form_value(value)

  # The top-level field this post is a change of: `["doc", "body"]` or
  # `["doc[body]"]`; nil for the Save button's post, which names none.
  # Each top-level reference or image the post picked on the widget drawn
  # from `form`: posted as another value than drawn, drawn as `form` holds
  # it, on the drawing the socket draws now (`_bp_drawn_at[name]`). The
  # value alone is not enough: B saving back the value the page still shows
  # (an undo of A's pick) moves the form to it before the redraw reaches the
  # page, and the page's stale post of A's pick read as made on it (#29146
  # r1 review, H1). A page that posts no drawing names none.
  defp picked(%{"doc" => %{} = doc}, {%{} = drawn, %{} = at}, socket, {schema, form}) do
    for %{"type" => type, "name" => name} <- fields(schema),
        type in @types,
        posted = Map.get(doc, name),
        is_binary(posted),
        was = Map.get(drawn, name),
        is_binary(was),
        posted != was,
        was == drawn(type, Map.get(form, name)),
        Map.get(at, name) ==
          FieldInputs.pick_drawing(
            socket.assigns[:editor_form_gen],
            socket.assigns[:editor_pick_gens],
            name
          ),
        do: name
  end

  defp picked(_params, _drawn, _socket, _form), do: []

  defp done(socket), do: assign(socket, editor_post_picks: [])

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
