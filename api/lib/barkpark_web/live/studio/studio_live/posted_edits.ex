defmodule BarkparkWeb.Studio.StudioLive.PostedEdits do
  @moduledoc """
  What the form buffer takes from a post (task-a4ded0be5c8ec3cb).

  ## The model

  For each field: the store holds S, the form buffer B (what the server
  draws), the page last posted D, and R is the newest value another editor
  saved.

  After a post settles, **B is D for every field the post carried, unless B
  is an R the page has not posted back yet**. So with one editor the buffer
  always takes the whole post, whether the post was written or changed
  nothing. Nothing is derived from which fields are unsaved, held or edited.

  ## The exception: a value from another editor

  The browser posts every drawn input on each change. A post that left the
  browser before another editor's save reached the page carries that
  editor's fields at their old values. The store keeps R for them: it reads
  a posted value as an edit only when it differs from what the form drew for
  `editor_doc`, the row this tab last saved or loaded. The buffer took the
  whole post, so the page drew the old values again, and the next change
  anywhere posted them as edits, over the other editor's save.

  `remote/3` remembers each field a remote save changed in the buffer, with
  the value it put there. Such a field is *waiting* while the buffer still
  holds exactly that value and `editor_doc` is still the row from before the
  remote save. A waiting field's posted value is not taken when the save
  does not read it as an edit (`Barkpark.Content.Forms.edited_keys/4`, the
  code the write runs): it is what the page showed before R.

  A field stops waiting when the buffer gets any other value for it (the
  person's own typing, a refused value, a pick), and all of them do when a
  save of this tab lands, because `editor_doc` is then the saved row.

  The field a post is a change of (`RefusedSave.target/2`) is the person's
  own typing. A written post puts it in the buffer even while it waits, as
  before this module. A post that changed nothing leaves the buffer's R and
  the field stops waiting, so the next written post takes it, as before.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Barkpark.Content.Forms
  alias BarkparkWeb.Studio.StudioLive.PostPath

  @doc """
  A remote save changed the buffer from `old_form` to `new_form`: each field
  that changed waits. `socket` still holds the `editor_doc` from before.
  """
  def remote(socket, old_form, new_form) when is_map(old_form) and is_map(new_form) do
    changed =
      for {key, value} <- new_form, Map.get(old_form, key) != value, into: %{}, do: {key, value}

    if changed == %{} do
      socket
    else
      assign(
        socket,
        :editor_remote_waiting,
        {base(socket), Map.merge(waiting_values(socket), changed)}
      )
    end
  end

  def remote(socket, _old_form, _new_form), do: socket

  @doc """
  The form buffer after `params` was written. `socket` is the socket from
  before the save, `params` the post in storage shape and `raw_params` the
  post as the browser sent it, both as `Forms.upsert_draft/6` was given them.
  """
  def into_form(socket, params, raw_params) do
    waiting = waiting(socket, socket.assigns[:editor_form] || %{}) -- target(socket)
    kept = old_values(socket, params, raw_params, waiting)
    merge(socket, PostPath.into_buffer(params, socket), kept)
  end

  @doc """
  `socket` after a post that changed nothing against `editor_doc`: "Saved",
  and the buffer takes the post. A waiting field keeps the buffer's value;
  the one the post is a change of stops waiting.
  """
  def unchanged(socket, params) do
    form = socket.assigns[:editor_form] || %{}
    values = Map.drop(waiting_values(socket), target(socket))

    assign(socket,
      save_status: "Saved",
      editor_form: merge(socket, PostPath.into_buffer(params, socket), waiting(socket, form)),
      editor_remote_waiting: {base(socket), values}
    )
  end

  @doc """
  `values` (coerced posted fields) put into the form buffer. Every path
  that puts a post into the buffer goes through here: an unset key
  (`Forms.unset/0`) is nil in the buffer, as the form draws it, and the
  marker never reaches a render or the next post.
  """
  def put(socket, values), do: assign(socket, editor_form: buffer(socket, values))

  defp merge(socket, params, kept), do: buffer(socket, Map.drop(params, kept))

  defp buffer(socket, values),
    do: Map.merge(socket.assigns[:editor_form] || %{}, Forms.unset_as_nil(values))

  # The waiting fields whose posted value the save does not read as an edit.
  defp old_values(_socket, _params, _raw_params, []), do: []

  defp old_values(socket, params, raw_params, waiting) do
    schema = socket.assigns[:editor_schema]
    posted = params |> Forms.with_posted_rich_text(raw_params, schema) |> Map.take(waiting)

    waiting --
      Forms.edited_keys(socket.assigns[:editor_doc], socket.assigns[:editor_type], schema, posted)
  end

  defp waiting(socket, form),
    do: for({key, value} <- waiting_values(socket), Map.get(form, key) === value, do: key)

  # Remembered against one `editor_doc`; void for any other.
  defp waiting_values(socket) do
    case socket.assigns[:editor_remote_waiting] do
      {base, values} -> if base == base(socket), do: values, else: %{}
      _ -> %{}
    end
  end

  defp base(socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: id} = doc ->
        {socket.assigns[:editor_type], id, Map.get(doc, :rev), Map.get(doc, :updated_at)}

      _ ->
        nil
    end
  end

  # The post's target, and each pick it made on the widget drawn from the
  # newest version (`KeptPicks`, task-36b1558c058a5f3b).
  defp target(socket),
    do:
      List.wrap(socket.assigns[:editor_post_target]) ++
        List.wrap(socket.assigns[:editor_post_picks])
end
