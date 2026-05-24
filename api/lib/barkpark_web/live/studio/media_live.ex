defmodule BarkparkWeb.Studio.MediaLive do
  @moduledoc """
  Studio Media tab — hosts the native `bp-asset-explorer` Web Component.

  Binary upload + `mediaAsset` document sync is handled client-side via
  `/media/upload` and the Media plugin upload hook. Metadata editing
  happens on `mediaAsset` documents in Structure → Media.
  """

  use BarkparkWeb, :live_view

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    {:ok,
     assign(socket,
       nav_section: :media,
       dataset: dataset,
       page_title: "Media Library",
       current_path: "/studio/#{dataset}/media"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="media-explorer-host"
      phx-update="ignore"
      style="flex: 1; display: flex; min-height: 0; overflow: hidden;"
    >
      <bp-asset-explorer
        dataset={@dataset}
        data-token={assigns[:api_token_raw] || ""}
      />
    </div>
    """
  end
end
