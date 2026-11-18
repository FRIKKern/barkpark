defmodule BarkparkWeb.Studio.StudioLive.Handlers.ArrayItems do
  @moduledoc """
  An array item's menu and handle, as the TanStack Studio's
  (`SortableRows.tsx`): Duplicate, Add item before and after, Copy, and a
  move from one place to another (`ArrayItemMenu`, `ArrayItemDialog`).

  THE SAME WAY IN AS THE OLD BUTTONS. Duplicate, the two adds and the move
  are `array_op` presses, like Add, Remove, Move up and Move down. They carry
  the document's mark (`PostIdentity.pressed/3`), and `Handlers.Fields.array_op/2`
  reads the list from the editor's buffer, changes it and saves it through
  the Studio's autosave, with its guards, exactly as before. This module
  only says what the new list is (`apply_op/6`).

    * `duplicate_row`: a copy of the item at `index` after it. A copy of an
      object with a `_key` gets a new one, so the list keeps one key per
      item; everything else in it is kept as it is, as Sanity's does.
    * `insert_row`: a new empty item at `index`, the one Add item makes
      (`Fields.add_row/4`), so it has the same `_key` and `_type` rule. In
      a list of strings it is the empty string, the TanStack Studio's
      blank row, so the list stays a list of strings.
    * `move_row`: the item at `index` taken out and put at `to`.

  OPENING THE NEW ITEM. A press with `open=item` that adds an object item
  (Add item, Duplicate, an add before or after) is answered, once its save
  has landed, with the event `desk:item-open`: the array's input path and
  the new item's place. `bp-desk-array-menu.js` opens that item's dialog.

  COPY writes nothing. `desk-item-copy` names the array's path and the
  item's place; the answer is the event `desk:field-copied`, the item as a
  clipboard item (`FieldClip.item_copy/5`), which
  `bp-desk-field-actions.js` writes to the clipboard as it writes a field's
  copy. Only an item of an array the open document's schema declares, as
  the editor's buffer holds it, is copied.
  """
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.Desk.FieldClip
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Handlers.Fields
  alias BarkparkWeb.Studio.StudioLive.Shared

  @open "desk:item-open"
  @copied "desk:field-copied"

  @doc """
  The list after one of this module's actions, or `current` unchanged for
  an index that is not one of its items.
  """
  @spec apply_op(String.t(), list(), integer(), map(), map(), boolean()) :: list()
  def apply_op(action, current, idx, field, params, keyed_parent?)

  def apply_op("duplicate_row", current, idx, _field, _params, _keyed?)
      when is_list(current) and idx >= 0 and idx < length(current) do
    List.insert_at(current, idx + 1, rekey(Enum.at(current, idx)))
  end

  def apply_op("insert_row", current, idx, field, params, keyed?)
      when is_list(current) and idx >= 0 and idx <= length(current) do
    case Fields.add_row(current, field, params["member"], keyed?) do
      added when length(added) == length(current) + 1 ->
        List.insert_at(current, idx, blank(typed(List.last(added), field, params["kind"]), field))

      _ ->
        current
    end
  end

  def apply_op("move_row", current, idx, _field, params, _keyed?)
      when is_list(current) and idx >= 0 and idx < length(current) do
    case Shared.parse_idx(params["to"]) do
      to when to >= 0 and to < length(current) and to != idx ->
        {item, rest} = List.pop_at(current, idx)
        List.insert_at(rest, to, item)

      _ ->
        current
    end
  end

  def apply_op(_action, current, _idx, _field, _params, _keyed?), do: current

  # A new item of the type chosen in "Add item...": the member's type select
  # (`options.typeField`) set to one of its own options; anything else is
  # not set.
  defp typed(row, %{"of" => %{"options" => %{"typeField" => name}} = of}, kind)
       when is_map(row) and is_binary(name) and is_binary(kind) do
    select = Enum.find(List.wrap(of["fields"]), &match?(%{"name" => ^name}, &1))
    kinds = Barkpark.Content.SelectOptions.values((select || %{})["options"])
    if kind in kinds, do: Map.put(row, name, kind), else: row
  end

  defp typed(row, _field, _kind), do: row

  defp blank(nil, %{"of" => %{"type" => type}}) when type in ["string", "text"], do: ""
  defp blank(row, _field), do: row

  # A copy keeps everything but its `_key`, which is new.
  defp rekey(%{"_key" => _} = item), do: Map.put(item, "_key", StudioLive.Path.new_key())
  defp rekey(item), do: item

  @doc """
  `Fields.array_op/2`, then, for a press that asked for it (`open=item`)
  and added an item whose save landed, the event that opens the new item.
  """
  def array_op(params, socket) do
    before = list_at(socket, params)
    {:noreply, socket} = Fields.array_op(params, socket)

    case opened(params, before, list_at(socket, params), socket) do
      nil -> {:noreply, socket}
      at -> {:noreply, push_event(socket, @open, %{path: params["path"], index: at})}
    end
  end

  # Where the new item is, when this press added one and it is saved.
  defp opened(%{"open" => "item", "action" => action} = params, before, now, socket)
       when is_list(before) and is_list(now) and length(now) == length(before) + 1 do
    if socket.assigns[:save_status] == "Saved", do: place(action, params, before)
  end

  defp opened(_params, _before, _now, _socket), do: nil

  defp place("add_row", _params, before), do: length(before)
  defp place("duplicate_row", params, _before), do: Shared.parse_idx(params["index"]) + 1
  defp place("insert_row", params, _before), do: Shared.parse_idx(params["index"])
  defp place(_action, _params, _before), do: nil

  # The list the press names, as the editor's buffer holds it; nil when the
  # path names no array of the open document.
  defp list_at(socket, params) do
    case key_path(socket, params) do
      nil -> nil
      {_field, path} -> StudioLive.list_value_at(socket.assigns[:editor_form] || %{}, path)
    end
  end

  defp key_path(socket, params) do
    case StudioLive.parse_path(params["path"] || "") do
      [] ->
        nil

      path ->
        case Shared.find_field_by_path(socket, path) do
          %{"type" => type} = field when type in ["arrayOf", "array"] -> {field, path}
          _ -> nil
        end
    end
  end

  @doc """
  The item's Copy: answered with `desk:field-copied` for the field the
  browser named (`field`, its echo), or nothing when the press names no
  item of an array of the open document.
  """
  def copy(%{"field" => echo, "index" => index} = params, socket) when is_binary(echo) do
    with %{} = doc <- socket.assigns[:editor_doc],
         {field, path} <- key_path(socket, params),
         list when is_list(list) <-
           StudioLive.list_value_at(socket.assigns[:editor_form] || %{}, path),
         idx = Shared.parse_idx(index),
         true <- idx >= 0 and idx < length(list) do
      id = DraftId.published_id(to_string(doc.doc_id))
      name = Enum.join(Enum.filter(path, &is_binary/1), ".")

      answer =
        field
        |> Map.put("name", name)
        |> FieldClip.item_copy(Enum.at(list, idx), idx, id, socket.assigns[:editor_type])
        |> Map.put(:field, echo)

      {:noreply, push_event(socket, @copied, answer)}
    else
      _ -> {:noreply, socket}
    end
  end

  def copy(_params, socket), do: {:noreply, socket}
end
