defmodule BarkparkWeb.Studio.StudioLive.Handlers.Bulk do
  @moduledoc """
  Bulk publish/unpublish + list-pane multi-select. Behaviour-preserving
  extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias BarkparkWeb.Studio.StudioLive.Shared

  # Cap the multi-select so a scripted/stale client can't grow the set (and the
  # per-click DB fan-out in bulk_action) without bound.
  @max_selected 500

  def toggle_doc_checkbox(%{"id" => id}, socket) do
    current = socket.assigns.selected_doc_ids

    cond do
      MapSet.member?(current, id) ->
        {:noreply, assign(socket, selected_doc_ids: MapSet.delete(current, id))}

      MapSet.size(current) >= @max_selected ->
        {:noreply, put_flash(socket, :error, "Selection limit reached (#{@max_selected})")}

      true ->
        {:noreply, assign(socket, selected_doc_ids: MapSet.put(current, id))}
    end
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
