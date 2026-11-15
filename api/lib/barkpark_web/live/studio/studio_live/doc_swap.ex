defmodule BarkparkWeb.Studio.StudioLive.DocSwap do
  @moduledoc """
  The old Studio opens another document in two patches: one without the
  editor form, then one with the new document's (task-8908b6e031268f77).

  ## Why

  LiveView patches the page in place. An element whose `id` is in both the
  old and the new page is kept, and a focused input that is kept keeps the
  text typed in it. Array rows, object subfields and code lists have ids
  with no document in them (`f-tags-0`). So with the focus left in such an
  input (browser Back, a row opened without moving the focus) the patch
  from A's form to B's kept A's typing in B's form, and B's next post, a
  true post of B's form, stored it in B.

  The desk never had this: it loads a document in a second step, so no
  patch holds both forms. This gives the old Studio the same two steps, for
  every control at once: nothing of A's form is on the page when B's is
  drawn, so the browser makes every input new.

  `start/2` runs where the route is taken in. When the editor held a
  document and now holds another, it sets `editor_swap`, which
  `studio_editor_shell` reads to leave the form out, and sends the page
  `message/0`; `done/1` answers it and the form is drawn.

  The header, the list and the pane stay as they are through both patches;
  only the form's panel is absent for the one in between.
  """

  import Phoenix.Component, only: [assign: 3]

  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @message :editor_swap_done

  @doc "The message the page sends itself to draw the form."
  def message, do: @message

  @doc "`was` is `PostIdentity.of/1` of the socket before the route was taken in."
  def start(socket, was) do
    now = PostIdentity.of(socket)

    if is_binary(was) and is_binary(now) and was != now and
         Phoenix.LiveView.connected?(socket) and not desk?(socket) do
      send(self(), @message)
      assign(socket, :editor_swap, true)
    else
      assign(socket, :editor_swap, false)
    end
  end

  @doc """
  The form is drawn again. Focus that was in the old form went to `<body>`
  with it: the page is told to put it on the document header, which it does
  only while focus is on `<body>` (root layout, `bp:focus-doc-header`). A
  pressed list row is outside the form and keeps its focus.
  """
  def done(socket) do
    socket
    |> assign(:editor_swap, false)
    |> Phoenix.LiveView.push_event("bp:focus-doc-header", %{})
  end

  @doc "Whether the form is left out of this render."
  def swapping?(%{editor_swap: true}), do: true
  def swapping?(_assigns), do: false

  defp desk?(socket), do: is_binary(socket.assigns[:desk_base])
end
