defmodule BarkparkWeb.Studio.MediaLive do
  @moduledoc """
  Studio Media tab — hosts the native `bp-asset-explorer` Web Component.

  Binary upload + `mediaAsset` document sync is handled client-side via
  `/media/upload` and the Media plugin upload hook. Metadata editing
  happens on `mediaAsset` documents in Structure → Media.
  """

  use BarkparkWeb, :live_view

  require Logger

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    # On the scoped mount LiveScope assigned the /w/<ws>/p/<proj> prefix
    # before this runs (tsk-url-p2); flat mount → "" → paths byte-identical.
    prefix = socket.assigns[:scope_prefix] || ""

    {:ok,
     socket
     |> assign_new(:scope_prefix, fn -> "" end)
     |> assign(
       nav_section: :media,
       dataset: dataset,
       page_title: "Media Library",
       current_path: prefix <> "/d/#{dataset}/studio/media"
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
        scope-prefix={@scope_prefix}
        data-token={assigns[:api_token_raw] || ""}
      />
    </div>
    """
  end

  # Fall-through: a stale/forged phx event must not FunctionClauseError-crash
  # the session. Keep LAST among handle_event/3 clauses.
  @impl true
  def handle_event(event, _params, socket) do
    Logger.warning("studio/media: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # Fall-through: an unexpected message (e.g. a late PubSub delivery) must not
  # FunctionClauseError-crash the LiveView. Keep LAST among handle_info/2.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("studio/media: unhandled info #{inspect(msg)}")
    {:noreply, socket}
  end
end
