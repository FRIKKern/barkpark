defmodule BarkparkWeb.Studio.Desk.JustSaved do
  @moduledoc """
  The footer's "Saved", as the TanStack Studio's (J04, `DocumentPane.tsx`
  `justSaved`): for about 3 s after this editor's own save lands the footer
  says "Saved", then "Edited N ago" (`DocFooter.status/2`).

  - A save is this socket's own: an event it answered (`EditorHost`) that
    moved the open document's revision while the save state is "Saved". A
    change from another editor arrives as a message, not an event, so it
    never says "Saved" here; it says "Edited" as TanStack's does.
  - The mark names the document it was for (its published id: a first edit
    of a published document opens its draft), so another document opened in
    the pane does not inherit it, and the timer that ends it carries the
    mark's own ref, so an older timer does not end a newer save's "Saved".
  - The window is `:desk_saved_ms` in the `:barkpark` app env (3000 ms).
  """

  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Content

  @key :desk_just_saved

  @doc "The socket after an event answered from `before` (the editor doc before it)."
  def after_write({:noreply, socket}, before), do: {:noreply, mark(socket, before)}
  def after_write({:reply, reply, socket}, before), do: {:reply, reply, mark(socket, before)}
  def after_write(other, _before), do: other

  @doc "Marks a save that landed: the doc's revision moved and the save state is \"Saved\"."
  def mark(socket, before) do
    doc = socket.assigns[:editor_doc]

    if socket.assigns[:save_status] == "Saved" and landed?(doc, before) do
      ref = make_ref()
      Process.send_after(self(), {:desk_saved_over, ref}, window())
      assign(socket, @key, {ref, Content.published_id(doc.doc_id)})
    else
      socket
    end
  end

  @doc "The window is over for `ref`: the footer says \"Edited\" again."
  def over(socket, ref) do
    case socket.assigns[@key] do
      {^ref, _doc_id} -> assign(socket, @key, nil)
      _ -> socket
    end
  end

  @doc "Whether the footer says \"Saved\" for the open document."
  def on?(assigns) do
    case {assigns[@key], assigns[:editor_doc]} do
      {{_ref, id}, %{doc_id: doc_id}} -> Content.published_id(doc_id) == id
      _ -> false
    end
  end

  # The same document (its draft or its published version: a first edit of a
  # published document opens its draft) at another revision.
  defp landed?(%{doc_id: id, rev: rev}, %{doc_id: was, rev: before}),
    do: Content.published_id(id) == Content.published_id(was) and rev != before

  defp landed?(_doc, _before), do: false

  defp window, do: Application.get_env(:barkpark, :desk_saved_ms, 3_000)
end
