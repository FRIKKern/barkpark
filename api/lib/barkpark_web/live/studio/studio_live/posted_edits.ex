defmodule BarkparkWeb.Studio.StudioLive.PostedEdits do
  @moduledoc """
  The form buffer after a save that landed takes from the post only what the
  save took (task-a4ded0be5c8ec3cb).

  The browser posts every drawn input on each change. The save reads a posted
  value as an edit only when it differs from what the form drew for
  `editor_doc`, the row this tab last saved or loaded
  (`Barkpark.Content.Forms.edited_keys/4`); for every other field it keeps
  what the store holds.

  The buffer took the whole post. So a post that left the browser before
  another editor's save reached the page put that editor's fields back to
  their old values in the buffer, while `editor_doc` moved on to the saved
  row. The page then drew the old values, and the next change anywhere posted
  them as edits, over the other editor's save.

  `into_form/3` merges only the edits. A field the save did not read as an
  edit keeps the buffer's value: the same one when nobody else saved, the
  other editor's when somebody did.
  """

  alias Barkpark.Content.Forms

  @doc """
  The form buffer after `params` landed. `socket` is the socket from before
  the save, `params` the post in storage shape and `raw_params` the post as
  the browser sent it, both as `Forms.upsert_draft/6` was given them.
  """
  def into_form(socket, params, raw_params) do
    form = socket.assigns[:editor_form] || %{}
    schema = socket.assigns[:editor_schema]
    posted = Forms.with_posted_rich_text(params, raw_params, schema)

    edited =
      Forms.edited_keys(socket.assigns[:editor_doc], socket.assigns[:editor_type], schema, posted)

    Map.merge(form, Map.take(params, edited))
  end
end
