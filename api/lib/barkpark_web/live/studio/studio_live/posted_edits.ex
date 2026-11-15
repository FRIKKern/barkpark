defmodule BarkparkWeb.Studio.StudioLive.PostedEdits do
  @moduledoc """
  What the form buffer takes from a post (task-a4ded0be5c8ec3cb).

  After a save settles, the buffer holds for every field either what this
  page just posted for it or a newer value from another editor. It never
  holds an older value of this page's own that the person has typed away.

  The browser posts every drawn input on each change. The save reads a posted
  value as an edit only when it differs from what the form drew for
  `editor_doc`, the row this tab last saved or loaded
  (`Barkpark.Content.Forms.edited_keys/4`); for every other field it keeps
  what the store holds.

  ## A post that was written (`into_form/3`)

  The buffer takes:

  1. Every field the save read as an edit.
  2. The field the post is a change of (`RefusedSave.target/2`): the page
     shows what the person typed there.
  3. Every field whose buffer value is this page's own and not saved: a
     field a save did not land for (`editor_unsaved_keys`) and a field the
     store refused (`RefusedSave.keys/1`). The post carries what the page
     shows for it now. Left alone, a refused value the person typed back to
     the stored one stayed in the buffer, was drawn again on the next patch,
     and was saved by the next change (#26396 review).

  Any other field keeps the buffer's value. That is the same value when
  nobody else saved. When another editor saved, it is that editor's: a post
  that left the browser before the save reached the page carries the old
  value, and taking it put the old value back on the page, where the next
  change anywhere posted it as an edit over the other editor's save.

  ## A post that changed nothing (`unchanged/2`)

  Nothing is written and the buffer takes only (3). It does not take (2): a
  post that changed nothing can be an old one, and the buffer may hold
  another editor's newer value for that field.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content.Forms
  alias BarkparkWeb.Studio.StudioLive.RefusedSave

  @doc """
  The form buffer after `params` landed. `socket` is the socket from before
  the save, `params` the post in storage shape and `raw_params` the post as
  the browser sent it, both as `Forms.upsert_draft/6` was given them.
  """
  def into_form(socket, params, raw_params) do
    schema = socket.assigns[:editor_schema]
    posted = Forms.with_posted_rich_text(params, raw_params, schema)

    edited =
      Forms.edited_keys(socket.assigns[:editor_doc], socket.assigns[:editor_type], schema, posted)

    target = List.wrap(socket.assigns[:editor_post_target])
    take(socket, params, edited ++ target ++ own_unsaved(socket))
  end

  @doc """
  `socket` after a post that changed nothing against `editor_doc`: "Saved",
  and the buffer takes the posted value of each field it held unsaved.
  """
  def unchanged(socket, params) do
    assign(socket,
      save_status: "Saved",
      editor_form: take(socket, params, own_unsaved(socket))
    )
  end

  defp take(socket, params, keys),
    do: Map.merge(socket.assigns[:editor_form] || %{}, Map.take(params, keys))

  defp own_unsaved(socket) do
    unsaved = socket.assigns[:editor_unsaved_keys] || MapSet.new()
    MapSet.to_list(unsaved) ++ RefusedSave.keys(socket)
  end
end
