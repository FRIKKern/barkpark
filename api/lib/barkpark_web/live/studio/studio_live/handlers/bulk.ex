defmodule BarkparkWeb.Studio.StudioLive.Handlers.Bulk do
  @moduledoc """
  Bulk publish/unpublish + list-pane multi-select. Behaviour-preserving
  extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]

  alias BarkparkWeb.Studio.StudioLive.Shared

  def toggle_doc_checkbox(%{"id" => id}, socket) do
    current = socket.assigns.selected_doc_ids

    new =
      if MapSet.member?(current, id),
        do: MapSet.delete(current, id),
        else: MapSet.put(current, id)

    {:noreply, assign(socket, selected_doc_ids: new)}
  end

  def bulk_clear(socket) do
    {:noreply, assign(socket, selected_doc_ids: MapSet.new())}
  end

  def bulk_publish(socket) do
    {:noreply, Shared.bulk_action(socket, :publish)}
  end

  def bulk_unpublish(socket) do
    {:noreply, Shared.bulk_action(socket, :unpublish)}
  end
end
