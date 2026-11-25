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

  alias BarkparkWeb.Studio.Desk.LeaveGuard

  @doc """
  `{:go, socket}`, or `{:stay, socket}` with the question asked. A press
  that goes clears the asked one, so a later hold asks again.
  """
  def ask(event, params, socket) do
    press = {event, params}

    if is_nil(LeaveGuard.doc(socket.assigns)) or socket.assigns[:studio_leave_asked] == press do
      {:go, assign(socket, :studio_leave_asked, nil)}
    else
      {:stay,
       socket
       |> assign(:studio_leave_asked, press)
       |> put_flash(:error, LeaveGuard.message(socket.assigns))}
    end
  end
end
