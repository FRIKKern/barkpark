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

  The form carries `value/3` in a `phx-value-_bp_doc` attribute: the dataset,
  the type and the published id of the document it draws. LiveView sends a
  form's `phx-value-*` with every change and submit it pushes, also the
  change of an input that has a `phx-change` of its own and posts only
  itself (a code list), so a hidden input would not do. `Fields.autosave/2`
  and `Fields.save/2` write only a post for which `ours?/2` holds: one that
  carries the value of the document the socket holds now. A post with
  another value, or with none, is not written. That holds for a post sent by
  hand too.

  The value is the published id, so a post built before the first save made
  the draft row (`p1` then `drafts.p1`) is still that document's.

  The key sits beside `_target` and `_bp_seen`, outside `doc`, so it is
  never read as a field: not stored, not coerced, not in the form buffer.
  """

  require Logger

  alias Barkpark.Content.DraftId

  @key "_bp_doc"

  @doc "The params key the value travels under."
  def key, do: @key

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

    if is_binary(open) and posted === open do
      true
    else
      Logger.debug(fn ->
        "studio.post_identity refused socket=#{inspect(socket.id)} " <>
          "posted=#{inspect(posted)} open=#{inspect(open)}"
      end)

      false
    end
  end

  def ours?(_params, _socket), do: false
end
