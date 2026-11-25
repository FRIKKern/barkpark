defmodule BarkparkWeb.Studio.StudioLive.LeaveAsk do
  @moduledoc """
  Studio asks on the server before a press leaves a document with a held
  field (task-c4b59891f88686e0, #28836 r1 review).

  Studio's list rows, its crumbs and New document are `phx-click` buttons,
  not links, so bp-studio-leave.js never saw them: a row click patched to
  the other document and A's held words were gone. While a field is held
  (`Desk.LeaveGuard.doc/1`), the first such press stays where it is and
  says so in a flash naming the field (`LeaveGuard.message/1`), the desk's
  question. The same press again goes on. A press on the open document's
  own row asks too: it opens the document again from the store, and the
  held words go. The desk's own dialog for this is task-5b4914f1b5f21594.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.LeaveGuard

  @doc """
  After each render: a hold that has ended forgets the press it asked
  about, so a later hold asks again (#28836 r2 review: asked on a row, the
  hold ended by typing on, a new clash held the field, and the same row
  then left with no question).
  """
  def follow(socket) do
    if socket.assigns[:studio_leave_asked] && is_nil(LeaveGuard.doc(socket.assigns)),
      do: assign(socket, :studio_leave_asked, nil),
      else: socket
  end

  @doc """
  `{:go, socket}`, or `{:stay, socket}` with the question asked. A press
  that goes clears the asked one, and so does the hold's end (`follow/1`).
  """
  def ask(event, params, socket) do
    press = {event, params}

    if is_nil(LeaveGuard.doc(socket.assigns)) or socket.assigns[:studio_leave_asked] == press do
      {:go, assign(socket, :studio_leave_asked, nil)}
    else
      {:stay,
       socket
       |> assign(:studio_leave_asked, press)
       |> put_flash(:error, message(socket.assigns))}
    end
  end

  # The desk's question, and that the press was stopped and a second one
  # leaves (#28836 r2 review: the flash named the field and nothing more).
  defp message(assigns),
    do: LeaveGuard.message(assigns) <> " " <> gettext("Press again to leave.")
end
