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
  for, and reloads a page whose script is too old to name its presses. The pickers finish their write in a message the page sends itself;
  `own/2` and `own?/2` keep that message to the document it was built in.

  ## Document actions

  Publish, Unpublish, Delete, Discard draft, Duplicate, a revision's Restore
  and the confirm of each one's dialog are such presses too
  (task-176bd529276ff8b3): Delete pressed in A must not delete B. Their
  controls sit outside the form (the header, the desk's menu and footer, a
  dialog), and a sheet or a paper has no editor form at all, so the page
  carries the same value once more, on `holder/1`, for the script to read
  when there is no form.

  A dialog one of them opened belongs to the document it was opened for:
  `leave/2` closes it when the editor comes to hold another document, so a
  confirm is always pressed in, and named for, the document the dialog asked
  about.

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

  use Phoenix.Component

  require Logger

  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.StudioLive.LeaveScope

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
  with the name taken off its params. An event that names another document
  or none (an empty name) does nothing.

  An event with no name key at all comes from a page whose script is older
  than this rule (a tab left open across a deploy): the current script
  always sends the key, empty when the page has no editor form. Nothing is
  written and the page is sent to its own address with a full page load, so
  it gets the current script and its next press is named.
  """
  def pressed(params, socket, fun) when is_function(fun, 2) do
    cond do
      not is_map(params) -> {:noreply, socket}
      not is_map_key(params, @key) -> {:noreply, reload(socket)}
      ours?(params, socket) -> fun.(Map.drop(params, [@key, @end_key]), socket)
      true -> {:noreply, socket}
    end
  end

  @doc "`pressed/3` for a handler that takes the socket alone."
  def pressed_in(params, socket, fun) when is_function(fun, 1),
    do: pressed(params, socket, fn _params, socket -> fun.(socket) end)

  # The address is the one the Studio's chrome keeps for every page it
  # draws. A socket without one (built by hand) is left as it is. Under the
  # leave question after a patch into another project it is already that
  # place's address, so the page stays, with the refusal (`LeaveScope`).
  defp reload(socket) do
    cond do
      LeaveScope.moved?(socket.assigns) ->
        LeaveScope.refuse(socket)

      match?("/" <> _, socket.assigns[:current_path]) ->
        Phoenix.LiveView.redirect(socket, to: socket.assigns.current_path)

      true ->
        socket
    end
  end

  @doc """
  The dialogs a document action opened (delete, discard, unpublish,
  history), closed when the editor holds another document than `was`
  (`of/1` before the change), or none.
  """
  def leave(socket, was) do
    if of(socket) === was, do: socket, else: close_dialogs(socket)
  end

  @doc "Those dialogs, closed."
  def close_dialogs(socket) do
    Phoenix.Component.assign(socket,
      show_delete: false,
      delete_refs: [],
      show_discard: false,
      show_unpublish_guard: false,
      unpublish_refs: [],
      show_history: false,
      revisions: []
    )
  end

  attr :doc, :string, default: nil

  @doc """
  The page's copy of the open document's value, for a press on a page with
  no editor form (`bp-array-focus.js`). Absent with no document.
  """
  def holder(assigns) do
    ~H"""
    <span :if={@doc} id="bp-doc" hidden data-bp-doc={@doc}></span>
    """
  end

  @doc """
  `params` without the two keys among the document's fields. A post that
  carries them inside `doc` (sent by hand) would leave them in the form
  buffer.
  """
  def no_marks(%{"doc" => %{} = doc} = params),
    do: Map.put(params, "doc", Map.drop(doc, [@key, @end_key]))

  def no_marks(params), do: params
end
