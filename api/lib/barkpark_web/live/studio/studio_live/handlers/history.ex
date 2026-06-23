defmodule BarkparkWeb.Studio.StudioLive.Handlers.History do
  @moduledoc """
  History panel + revision restore + profile edit. Behaviour-preserving
  extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Shared

  def show_history(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      revisions =
        Content.list_revisions(
          doc.doc_id,
          type,
          socket.assigns.dataset,
          [limit: 30] ++ ScopeHelpers.scope_opts(socket)
        )

      {:noreply, assign(socket, show_history: true, revisions: revisions)}
    else
      {:noreply, socket}
    end
  end

  def close_history(socket) do
    {:noreply, assign(socket, show_history: false, revisions: [])}
  end

  def restore_revision(%{"id" => rev_id}, socket) do
    type = socket.assigns[:editor_type]

    case Content.restore_revision(rev_id, type, socket.assigns.dataset, Shared.hook_opts(socket)) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> assign(show_history: false, revisions: [])
         |> put_flash(:info, "Restored from history")
         |> Shared.rebuild_panes()}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Restore cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore")}
    end
  end

  def show_profile(socket) do
    {:noreply, assign(socket, show_profile: true)}
  end

  def close_profile(socket) do
    {:noreply, assign(socket, show_profile: false)}
  end

  def preview_profile(%{"name" => name, "color" => color}, socket) do
    {:noreply, assign(socket, user_name: name, user_color: color)}
  end

  def save_profile(%{"name" => name, "color" => color}, socket) do
    socket = assign(socket, user_name: name, user_color: color, show_profile: false)
    socket = push_event(socket, "save-identity", %{name: name, color: color})
    {:noreply, Shared.track_presence(socket)}
  end
end
