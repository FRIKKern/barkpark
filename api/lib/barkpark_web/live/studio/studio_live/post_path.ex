defmodule BarkparkWeb.Studio.StudioLive.PostPath do
  @moduledoc """
  The one subfield of an object a post is a change of (task-04e50efa8405b956).

  A browser post carries every input of the form, but a change event is one
  input: `_target` `doc[meta].code` changed `meta.code`, and the other
  subfields of `meta` ride along as the page drew them. A post that left the
  page before another editor's save, or before this tab's own last save came
  back, carries those siblings at old values. TanStack sends only the path
  typed in (`edit(doc, "seo.metaTitle", …)`); this is the same rule for the
  LiveView form.

  The unit is the path down through `composite` fields only, to the first
  subfield that is not one: an image, a list or any other value inside an
  object is still taken whole, as a top-level field is.
  """

  alias Barkpark.Content.CanonicalShapes

  @doc """
  The path of the subfield `path` changed inside its object field, through
  `composite` fields that are objects in both `a` and `b` (content maps).
  `[key]` when it is not inside an object.
  """
  @spec unit([term()], map() | nil, map(), map()) :: [term()]
  def unit([key | rest], shapes, a, b) when is_map(a) and is_map(b),
    do: [key | inner(field(shapes_fields(shapes), key), rest, Map.get(a, key), Map.get(b, key))]

  def unit(path, _shapes, _a, _b), do: Enum.take(path, 1)

  @doc """
  `to` with the value at `unit` taken from `from`; the value is taken off
  when `from` has none there.
  """
  @spec put(map(), map(), [term()]) :: map()
  def put(to, from, [key]) do
    case Map.fetch(from, key) do
      {:ok, value} -> Map.put(to, key, value)
      :error -> Map.delete(to, key)
    end
  end

  def put(to, from, [key | rest]),
    do: Map.put(to, key, put(Map.fetch!(to, key), Map.fetch!(from, key), rest))

  @doc """
  `params` (a post's content fields) with the object field the post is a
  change of cut down to the changed subfield: every other subfield of it
  is `base`'s (the row the post is read against), so the save reads it as
  untouched and writes what the store holds now (`ObjectRebase`).
  """
  @spec only_changed(map(), Phoenix.LiveView.Socket.t(), map() | nil) :: map()
  def only_changed(params, socket, base) when is_map(params) and is_map(base) do
    keys = List.wrap(socket.assigns[:editor_post_target])
    content = base.content || %{}

    case socket.assigns[:editor_post_path] do
      [key, _ | _] = path when is_map_key(params, key) and is_map_key(content, key) ->
        if key in keys do
          case unit(path, shapes(socket), params, content) do
            [_, _ | _] = at -> Map.put(params, key, Map.fetch!(put(content, params, at), key))
            _ -> params
          end
        else
          params
        end

      _ ->
        params
    end
  end

  def only_changed(params, _socket, _base), do: params

  @doc """
  `params` as the form buffer takes them: the object the post is a change
  of keeps what the buffer shows (another editor's save, a held value), with
  only the changed subfield from the post.
  """
  @spec into_buffer(map(), Phoenix.LiveView.Socket.t()) :: map()
  def into_buffer(params, socket) when is_map(params) do
    form = socket.assigns[:editor_form] || %{}
    keys = List.wrap(socket.assigns[:editor_post_target])

    case socket.assigns[:editor_post_path] do
      [key, _ | _] = path when is_map_key(params, key) and is_map_key(form, key) ->
        with true <- key in keys,
             [_, _ | _] = at <- unit(path, shapes(socket), form, params) do
          Map.put(params, key, Map.fetch!(put(form, params, at), key))
        else
          _ -> params
        end

      _ ->
        params
    end
  end

  @doc "The document type's field shapes, as the save reads them."
  def shapes(socket),
    do: CanonicalShapes.for_type(socket.assigns[:editor_schema], socket.assigns[:editor_type])

  defp inner(%{"type" => "composite"} = field, [sub | _] = rest, %{} = a, %{} = b)
       when is_binary(sub) and not is_struct(a) and not is_struct(b),
       do: unit(rest, %{fields: field["fields"]}, a, b)

  defp inner(_field, _rest, _a, _b), do: []

  defp shapes_fields(%{fields: fields}) when is_list(fields), do: fields
  defp shapes_fields(_shapes), do: []

  defp field(fields, key), do: Enum.find(fields, &match?(%{"name" => ^key}, &1))
end
