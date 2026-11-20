defmodule BarkparkWeb.Studio.StudioLive.SeenRev do
  @moduledoc """
  The rev of the document state the page shows, which a history Restore
  sends as `if_rev` (task-5b74471e6a2d6de8): `Content.restore_revision/4`
  refuses it when the document has moved on since, and writes nothing.

  `editor_doc` alone is not that state. It is this tab's base: it moves on a
  load and on the page's own saves, while another person's save goes into the
  form only (`Handlers.Lifecycle.doc_updated/2`). So the page also notes the
  last such frame it put in the form (`applied/2`), and `of/1` takes the newer
  of the two by `updated_at`.

  - Only a frame the page put on screen is noted: `doc_updated/2` calls
    `applied/2` on the branch that replaces the form. A frame held behind the
    conflict banner, or kept from a field being edited, is not.
  - A note never moves back: a frame older than the one noted is dropped, and
    the form does not take it either (`stale?/2`).
  - A frame of a delete or a discarded draft is not a state the form shows.
  - A note belongs to one document: another open document ignores it.

  A write the page is never told of (no frame) is not noted, so a Restore
  after it is refused as moved on, the safe side.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Content

  @gone ~w(delete discardDraft)

  @doc "Notes the frame `msg` that the page has just put in the form."
  def applied(socket, %{rev: rev, doc_id: doc_id, doc: %{updated_at: %DateTime{} = at}} = msg)
      when is_binary(rev) and is_binary(doc_id) do
    seen = %{id: Content.published_id(doc_id), rev: rev, updated_at: at}

    cond do
      msg[:mutation] in @gone -> socket
      newer?(noted(socket.assigns, seen.id), seen) -> assign(socket, :seen_frame, seen)
      true -> socket
    end
  end

  def applied(socket, _msg), do: socket

  @doc """
  Whether the frame `msg` is older than the last one the form took for its
  document. Such a frame is dropped (`Handlers.Lifecycle.doc_updated/2`): it
  would put older words in the form under a newer note.
  """
  # A delete's frame carries the removed row, stamped when it was last written,
  # and is left to the handling it had before.
  def stale?(%{doc_id: doc_id, doc: %{updated_at: %DateTime{} = at}} = msg, assigns)
      when is_binary(doc_id) do
    case noted(assigns, Content.published_id(doc_id)) do
      %{updated_at: noted_at} ->
        msg[:mutation] not in @gone and DateTime.compare(at, noted_at) == :lt

      nil ->
        false
    end
  end

  def stale?(_msg, _assigns), do: false

  @doc "The rev the page shows for its open document, or nil when it shows none."
  def of(assigns) do
    case {assigns[:editor_doc], assigns[:seen_frame]} do
      {%{doc_id: doc_id, rev: rev} = doc, %{id: id} = frame} when is_binary(doc_id) ->
        if id == Content.published_id(doc_id) and newer?(doc, frame), do: frame.rev, else: rev

      {%{rev: rev}, _frame} ->
        rev

      _ ->
        nil
    end
  end

  # The note for document `id`; a note of another document is none.
  defp noted(assigns, id) do
    case assigns[:seen_frame] do
      %{id: ^id} = frame -> frame
      _ -> nil
    end
  end

  # Whether `b` is newer than `a`.
  defp newer?(%{updated_at: %DateTime{} = a}, %{updated_at: %DateTime{} = b}),
    do: DateTime.compare(b, a) == :gt

  defp newer?(_a, _b), do: true
end
