defmodule BarkparkWeb.Studio.StudioLive.PostIdentity do
  @moduledoc """
  A post of the editor form names the document it was built for
  (task-8908b6e031268f77).

  ## Why

  The editor form is one element, `#editor-form`, for every document a pane
  shows, and its inputs post after a delay (`phx-debounce`). The server wrote
  each post into whatever document the socket held when the post arrived. A
  post built from document A that arrived after the pane had moved to
  document B was written into B: A's whole form, since every field differed
  from what B's form drew.

  ## The rule

  The form carries `value/3`, the dataset, the type and the published id of
  the document it draws, in two places:

    * a `phx-value-_bp_doc` attribute on the form. LiveView sends a form's
      `phx-value-*` with every change and submit it pushes, also the change
      of an input that has a `phx-change` of its own and posts only itself
      (a code list), which a hidden input does not ride in;
    * a hidden `_bp_doc_end` input, the form's last child.

  `Fields.autosave/2` and `Fields.save/2` write only a post for which
  `ours?/2` holds: the attribute's value is that of the document the socket
  holds now, and so is the hidden input's when the post has one. A post with
  another value, or with no attribute value, is not written. That holds for
  a post sent by hand too.

  ## A write the server builds

  A browser post is the only thing `ours?/2` is for. Code in the page's own
  process that builds the params itself, for the document the socket holds
  (the desk's Paste field), has no form to have been stale: it calls
  `Fields.autosave_built/2`, which takes no name and asks nothing. The EVENT
  that started it came from the browser, though, and names the document it
  was pressed in under the same key; its handler asks `ours?/2` of the
  event before it builds anything.

  ## Events that are not the form's post

  A press that writes the open document without posting the form (a list's
  Add, Remove and Move, Generate on a slug, a pick or a clear in the old
  reference and image pickers, the picker's upload) is an event of its own,
  and the server ran it against whatever document the socket held when it
  arrived. It names its document under the same key: the page's script
  (`bp-array-focus.js`) reads the form's attribute at the moment of the
  press and puts it on the pressed control, so LiveView sends it with the
  event. `pressed/3` runs the handler only for an event `ours?/2` holds
  for. The pickers finish their write in a message the page sends itself;
  `own/2` and `own?/2` keep that message to the document it was built in.

  The name only narrows. What a socket may write is asked where it always
  was (`Shared.do_autosave/3`); an event that names the open document gets
  nothing it would not have had.

  ## Why two

  LiveView posts a waiting input the moment it blurs, and removing the
  focused input blurs it. So a post can be built in the middle of the patch
  that turns A's form into B's: the form's attributes are already B's, the
  inputs still A's. The patch works through the form's children in order
  and reaches the last one last, so a form whose first and last marks agree
  is wholly one document's.

  The value is the published id, so a post built before the first save made
  the draft row (`p1` then `drafts.p1`) is still that document's.

  Both keys sit beside `_target` and `_bp_seen`, outside `doc`, so they are
  never read as a field: not stored, not coerced, not in the form buffer.
  """

  require Logger

  alias Barkpark.Content.DraftId

  @key "_bp_doc"
  @end_key "_bp_doc_end"

  @doc "The params key of the form attribute's value."
  def key, do: @key

  @doc "The params key (and input name) of the form's last child."
  def end_key, do: @end_key

  @doc "What a form drawn for this document carries; `nil` with no document."
  @spec value(term(), term(), term()) :: String.t() | nil
  def value(dataset, type, doc_id)
      when is_binary(dataset) and is_binary(type) and is_binary(doc_id),
      do: Jason.encode!([dataset, type, DraftId.published_id(doc_id)])

  def value(_dataset, _type, _doc_id), do: nil

  @doc "The value for the document `socket` holds in its editor."
  def of(%{assigns: assigns}) do
    case assigns[:editor_doc] do
      %{doc_id: doc_id, type: type} -> value(assigns[:dataset], type, doc_id)
      _ -> nil
    end
  end

  @doc """
  Whether `params` is a post of the form the editor draws now. A refused
  post is logged at debug and nothing else happens.
  """
  def ours?(params, socket) when is_map(params) do
    open = of(socket)
    posted = Map.get(params, @key)
    posted_end = Map.get(params, @end_key, open)

    if is_binary(open) and posted === open and posted_end === open do
      true
    else
      Logger.debug(fn ->
        "studio.post_identity refused socket=#{inspect(socket.id)} " <>
          "posted=#{inspect(posted)} end=#{inspect(posted_end)} open=#{inspect(open)}"
      end)

      false
    end
  end

  def ours?(_params, _socket), do: false

  @doc """
  Runs `fun` for an event pressed in the document the editor holds now,
  with the name taken off its params. For any other event nothing happens.
  """
  def pressed(params, socket, fun) when is_function(fun, 2) do
    if ours?(params, socket),
      do: fun.(Map.drop(params, [@key, @end_key]), socket),
      else: {:noreply, socket}
  end

  @doc """
  A form the page sends itself to save (`{:autosave_form, form}`), kept to
  the document the socket holds as it is built.
  """
  def own(form, socket), do: {:own, of(socket), form}

  @doc """
  The form of such a message when the socket still holds its document,
  else `nil`. A bare form is one the server built for the open document.
  """
  def own?({:own, doc, form}, socket),
    do: if(is_binary(doc) and doc === of(socket), do: form)

  def own?(form, _socket) when is_map(form), do: form
  def own?(_form, _socket), do: nil

  @doc """
  `params` without the two keys among the document's fields. A post that
  carries them inside `doc` (sent by hand) would leave them in the form
  buffer.
  """
  def no_marks(%{"doc" => %{} = doc} = params),
    do: Map.put(params, "doc", Map.drop(doc, [@key, @end_key]))

  def no_marks(params), do: params
end
