defmodule BarkparkWeb.Studio.Desk.DocUndoValues do
  @moduledoc """
  The desk undo's steps for the fields that are not free text
  (task-0b9061cb95e89484), as the TanStack Studio records every edit
  (`app/src/lib/edits.ts` `write`): a slug, a select, a list (its items
  added, removed, moved or typed in) and an object's nested fields.
  `DocUndo` keeps the steps and takes them back; free text keeps its own
  keystroke steps there.

  - A step is the field's whole value, as the store held it just before
    this editor's write and as the write left it. The value before is read
    from the store at the press, not from the editor's copy, which can be a
    frame behind another editor's save: a step then holds this editor's
    change alone, and its undo cannot take another editor's change with it.
  - The writes recorded are the form's own: a typed or picked change
    (`autosave`) and a list's buttons and item menu (`array_op`).
  - Taken back with `ValueUndo`, by the field's schema: another editor's
    items, keys and values since stay theirs, and only free text is
    merged.
  - A rich-text body, a reference, an image or a file is not kept here: the
    body has its canvas's own undo, the others are widgets of their own.
  """

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.FieldActions
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.Path

  # The field types whose writes are kept as whole-value steps.
  @types ~w(string select slug arrayOf array composite object)

  @doc "Whether `key`'s writes are kept as whole-value steps (not free text)."
  @spec recorded?(map() | nil, String.t()) :: boolean()
  def recorded?(schema, key) do
    not RemoteValues.free_text?(schema, key) and
      match?(%{"type" => type} when type in @types, field(schema, key))
  end

  @doc """
  The top-level field an event of the form writes, and the input it was
  typed in (nil for a list's button): nil when it is not kept here.
  """
  @spec target(String.t(), map(), map()) :: {String.t(), String.t() | nil} | nil
  # A checkbox list in an object or a row names its whole path dotted in
  # one bracket (`doc[obj.tags][]`): the step is its top-level field's.
  def target("autosave", %{"_target" => ["doc", key | rest]}, assigns) when is_binary(key) do
    schema = assigns[:editor_schema]
    field = Path.target_field(key, Path.field_names(schema))

    if recorded?(schema, field),
      do: {field, "doc[" <> Enum.join([key | rest], "][") <> "]"}
  end

  # A nested input's name is dotted (`doc[address].street`,
  # `doc[cards][0].label`) and arrives whole (`Fields.track_touched/2`).
  def target("autosave", %{"_target" => ["doc[" <> _ = name]}, assigns) do
    with [key | _] when is_binary(key) <- StudioLive.parse_path(name),
         true <- recorded?(assigns[:editor_schema], key) do
      {key, name}
    else
      _ -> nil
    end
  end

  # A list's button names its list by `path`, or by `field` with no path
  # (`Fields.array_op/2`).
  def target("array_op", params, assigns) when is_map(params) do
    key =
      case StudioLive.parse_path(params["path"] || "") do
        [first | _] when is_binary(first) -> first
        _ -> params["field"]
      end

    if is_binary(key) and recorded?(assigns[:editor_schema], key), do: {key, nil}
  end

  def target(_event, _params, _assigns), do: nil

  @doc """
  The field as the store holds it now, read fresh: the editor's copy can be
  a frame behind another editor's save. The editor's copy when the read
  finds nothing.
  """
  @spec stored_now(Phoenix.LiveView.Socket.t(), String.t()) :: term()
  def stored_now(%{assigns: assigns} = socket, key) do
    with %{doc_id: id} when is_binary(id) <- assigns[:editor_doc],
         type when is_binary(type) <- assigns[:editor_type],
         {%{} = doc, _, _} <-
           Content.fetch_doc_with_draft(
             type,
             Content.published_id(id),
             assigns.dataset,
             ScopeHelpers.scope_opts(socket)
           ) do
      FieldActions.stored(doc, key)
    else
      _ -> stored(socket, key)
    end
  end

  @doc "The field as the editor's copy of the document holds it."
  def stored(socket, key) do
    case socket.assigns[:editor_doc] do
      %{} = doc -> FieldActions.stored(doc, key)
      _ -> nil
    end
  end

  @doc """
  What the page is told an undo of `input` set: the input's new text and
  the text it showed, when the value at the input is text (a select, a
  slug's `current`, a nested or a list item's string); nils otherwise, and
  the server's render draws it.
  """
  @spec told(String.t() | nil, String.t(), term(), term()) :: {term(), term()}
  def told(nil, _key, _next, _now), do: {nil, nil}

  def told(input, key, next, now) do
    path = input_path(input, key)

    case {text(at(next, path)), text(at(now, path))} do
      {a, b} when is_binary(a) and is_binary(b) -> {a, b}
      {a, nil} when is_binary(a) -> {a, ""}
      {nil, b} when is_binary(b) -> {"", b}
      _ -> {nil, nil}
    end
  end

  # The text an input shows for a value: a slug's is its `current`.
  defp text(%{"current" => current}) when is_binary(current), do: current
  defp text(value), do: value

  # The path inside the field's value an input names: `doc[cards][0].label`
  # is `[0, "label"]` in `cards`.
  defp input_path(input, key) do
    case StudioLive.parse_path(input) do
      [^key | rest] -> rest
      _ -> [:none]
    end
  end

  defp at(value, []), do: value

  defp at(value, [i | rest]) when is_list(value) and is_integer(i),
    do: value |> Enum.at(i) |> at(rest)

  defp at(value, [seg | rest]) when is_map(value), do: value |> Map.get(seg) |> at(rest)
  defp at(_value, _path), do: nil

  @doc "The schema's top-level field `key`, nil when it has none."
  def field(%{fields: fields}, key) when is_list(fields),
    do: Enum.find(fields, &(is_map(&1) and &1["name"] == key))

  def field(_schema, _key), do: nil

  @doc """
  The post of an undo or redo that turns `now` (what the store holds) into
  `next`: `next` itself, which the save writes whole, nulls and emptied
  keys as they are (`Fields.autosave_built/2` marks the field `:whole`). A
  field `next` has no value for is posted "", which takes it off the
  document.
  """
  @spec post(term(), term()) :: term()
  def post(now, nil) when not is_nil(now), do: ""
  def post(_now, next), do: next
end
