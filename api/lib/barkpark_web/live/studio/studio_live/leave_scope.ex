defmodule BarkparkWeb.Studio.StudioLive.LeaveScope do
  @moduledoc """
  No write while the leave question is open over a patch into another
  project or workspace (task-bc40f41b69eb4d9a).

  LiveScope's `reauthorize/3` hook runs before the patch reaches the Studio
  or the desk, so by the time either asks, `current_workspace`,
  `current_project` and `scope_prefix` are the new place's. The held document
  is still open, and a save from it was written under the new scope: a copy
  of the document in the other project. While the question is open and the
  held document is not in the scope the socket now has, every press of a
  write tier in `Caps.classify/1` (anything but `:none` and `:read`) is
  refused here, before Caps. A read lands no row; some fire with no press
  (presence, remote-value acks), and refusing them would stall the page
  behind the question. Stay and Leave are `:none`, so the question can always
  close. Stay's patch back
  re-runs `reauthorize/3`, which puts the scope back; Leave reads the other
  document under the scope the hook already set.

  The hook-invisible doors (`handle_info`, component events) ask
  `moved?/1` too, through `Shared.do_autosave/3` and `Paper.write_denied?/1`.

  Three reads are held as well (task-7fbdea7ee305cbc4): they rebuild the
  panes (`Shared.rebuild_panes/1`), which reads the open document again under
  the socket's scope, the new place's. That put an empty editor, or the other
  project's document of the same id, under the held document's address, and
  dropped the held words without the question. Stay and Leave each make them
  right again. An unnamed press (`PostIdentity.pressed/3`) does not send the
  page to its address while `moved?/1`: that address is already the new
  place's.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias BarkparkWeb.Studio.Caps

  # The question's own presses, whatever their tier.
  @leave_events ~w(desk-leave desk-leave-stay desk-leave-go studio-leave)

  # `:none` presses that rebuild the panes, the open document with them.
  @held_reads ~w(reload-remote-doc desk-list-more select-sort)

  # `:none` presses that go to another page about the open document: the
  # page they build names the socket's project, so under the question they
  # would go to the moved project's page of the held document, without
  # asking (task-62711814fa586a09).
  @held_opens ~w(view-graph)

  # The three notices are read in the caller's locale, at call time
  # (task-82f506e97f488de0).
  @doc "The notice a refused press shows."
  def notice,
    do: gettext("Not saved: the page has moved to another project. Choose Stay or Leave first.")

  @doc "The notice a held read shows."
  def held_notice,
    do:
      gettext("Not reloaded: the page has moved to another project. Choose Stay or Leave first.")

  @doc "The notice a held open (`view-graph`) shows."
  def held_opens_notice,
    do: gettext("Not opened: the page has moved to another project. Choose Stay or Leave first.")

  @doc "Arm the gate. Attached before `Caps.attach/1`."
  def attach(socket), do: attach_hook(socket, :studio_leave_scope, :handle_event, &gate/3)

  @doc """
  Whether the leave question is open (Studio's `studio_leave` or the desk's
  `desk_leave`) and the held document is not in the socket's current
  workspace and project.
  """
  def moved?(assigns) do
    (assigns[:studio_leave] != nil or assigns[:desk_leave] != nil) and
      outside?(assigns[:editor_doc], assigns[:current_workspace], assigns[:current_project])
  end

  @doc "The refusal: the notice; nothing else on the socket moves."
  def refuse(socket), do: put_flash(socket, :error, notice())

  defp gate(event, _params, socket) do
    cond do
      event in @leave_events or not moved?(socket.assigns) -> {:cont, socket}
      event in @held_reads -> {:halt, put_flash(socket, :error, held_notice())}
      event in @held_opens -> {:halt, put_flash(socket, :error, held_opens_notice())}
      Caps.classify(event) in [:none, :read] -> {:cont, socket}
      true -> {:halt, refuse(socket)}
    end
  end

  defp outside?(%{workspace_id: ws_id, project_id: proj_id}, ws, proj),
    do: ws_id != id(ws) or proj_id != id(proj)

  defp outside?(_doc, _ws, _proj), do: false

  defp id(%{id: id}), do: id
  defp id(_), do: nil
end
