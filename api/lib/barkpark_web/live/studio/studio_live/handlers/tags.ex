defmodule BarkparkWeb.Studio.StudioLive.Handlers.Tags do
  @moduledoc """
  A tags field's presses (`BarkparkWeb.Components.Fields.TagsField`): Enter
  adds a tag (`add_tag`), × removes one (`remove_tag`).

  They come in as `array_op`, with the document's mark checked
  (`PostIdentity.pressed/3`), and are saved as the old list buttons are:
  the list is read from the editor's buffer, changed (`TagsField.apply_op/3`)
  and saved through the Studio's autosave with its guards
  (`Shared.do_autosave/3`). A press that changes nothing saves nothing,
  and neither does one naming a field that is not a tags field
  (`TagsField.tags_field?/1`): a hand-made `add_tag` on an array of objects
  would store a bare string in it.

  The last tag removed unsets the field, as Sanity's and the TanStack
  Studio's do: the save carries an empty value for the key, and the store
  drops it, so the document has no `tags`, not `[]`. A tags field inside
  an object is saved as `[]` instead: the save merges an object over the
  stored one, so a key left out would keep the stored tags.
  """

  alias BarkparkWeb.Components.Fields.TagsField
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Handlers.Fields
  alias BarkparkWeb.Studio.StudioLive.Handlers.HeldFields
  alias BarkparkWeb.Studio.StudioLive.RefusedSave
  alias BarkparkWeb.Studio.StudioLive.Shared

  @doc "Runs an `add_tag` or `remove_tag` press against the open document."
  def array_op(%{"action" => action} = params, socket) do
    with {field, key_path} when not is_nil(field) and key_path != [] <- target(params, socket),
         true <- TagsField.tags_field?(field) do
      form = socket.assigns[:editor_form] || %{}
      current = StudioLive.list_value_at(form, key_path)

      case TagsField.apply_op(action, current, params) do
        ^current -> {:noreply, socket}
        next -> save(socket, form, key_path, next)
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # The array the press names, as `Fields.array_op/2` finds it: by its input
  # path, else by its field name at the top of the document.
  defp target(params, socket) do
    case StudioLive.parse_path(params["path"] || "") do
      [] ->
        case params["field"] do
          name when is_binary(name) -> {Shared.find_field(socket, name), [name]}
          _ -> nil
        end

      path ->
        {Shared.find_field_by_path(socket, path), path}
    end
  end

  defp save(socket, form, key_path, next) do
    new_form = put(form, key_path, next)
    keys = Enum.take(key_path, 1)
    {new_form, held} = HeldFields.stored(socket, new_form, keys)
    saved = socket |> RefusedSave.target(keys) |> Shared.do_autosave(new_form, :array_op)
    {:noreply, saved |> Fields.settle_dirty(keys) |> HeldFields.restore(held)}
  end

  # No tags left: a top-level field is posted empty, which the save reads
  # as "clear it" (`Content.Forms.build_content/2`). Inside an object the
  # save merges the object over the stored one, so a missing key would keep
  # the stored tags: there the field is saved as an empty list.
  defp put(form, [key], []), do: StudioLive.put_value_at(form, [key], "")

  defp put(form, key_path, next), do: StudioLive.put_value_at(form, key_path, next)
end
