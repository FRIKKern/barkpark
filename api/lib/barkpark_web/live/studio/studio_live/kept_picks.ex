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
  posted as drawn from a post that is not a change of that field: the store
  keeps what it holds. A pick or a clear is not the drawn value, so it is
  written, also when it rides on a key in another field (the body's change
  cancels the widget's own debounced one). A page's `_bp_drawn` can only
  keep a field from being written, never write one.

  Where the store holds another value than the page drew, the widget is
  drawn again from it (`editor_pick_gens`, a part of its wrapper id), so the
  page shows it and posts it as drawn from then on. A nested reference or
  image (in an object or a row) is not read here.
  """

  import Phoenix.Component, only: [assign: 2]

  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Studio.StudioLive.Path

  @types ~w(reference image)

  @doc """
  `fun`'s handling of the page's post `params` on `socket`, with each pick
  posted as drawn and not changed by this post left out, and each such
  widget drawn again where the store holds another value.
  """
  def through(params, socket, fun) do
    {params, dropped} = split(params, socket.assigns[:editor_schema])

    case fun.(params, socket) do
      {:noreply, socket} -> {:noreply, redraw(socket, dropped)}
      {:reply, reply, socket} -> {:reply, reply, redraw(socket, dropped)}
    end
  end

  @doc false
  def split(%{"doc" => %{} = doc, "_bp_drawn" => %{} = drawn} = params, schema) do
    target = target(params)

    dropped =
      for %{"type" => type, "name" => name} <- fields(schema),
          type in @types,
          name != target,
          is_binary(drawn[name]),
          Map.get(doc, name) == drawn[name],
          into: %{},
          do: {name, {type, drawn[name]}}

    {params |> Map.put("doc", Map.drop(doc, Map.keys(dropped))) |> Map.delete("_bp_drawn"),
     dropped}
  end

  def split(params, _schema) when is_map(params), do: {Map.delete(params, "_bp_drawn"), %{}}

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
