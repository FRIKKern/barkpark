defmodule BarkparkWeb.Studio.Desk.LiveRefresh do
  @moduledoc """
  The desk slice's live updates: someone else saved (`BarkparkWeb.Studio.DeskLive`).

  Every document change in the dataset is announced on one of two topics
  (`Content.Broadcast`: the workspace's own, or the shared layer's). The
  panes that show the changed type read again, a moment later so a burst of
  saves is one read.

  `DeskLive` keeps the `handle_info/2` clauses and hands each one here; this
  module owns the `topics`, `stale` and `refresh_timer` assigns.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, send_update: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.StudioLive.Shared

  @refresh_after_ms 120

  @doc "The assigns this module owns, empty."
  def init(socket), do: assign(socket, topics: [], stale: MapSet.new(), refresh_timer: nil)

  @doc "Listens to the dataset's two list topics, and stops listening to the last dataset's."
  def subscribe(socket, dataset) do
    ws = socket.assigns[:current_workspace]

    topics =
      [Broadcast.global_list_topic(dataset)] ++
        if(is_map(ws) and is_binary(ws.id),
          do: [Broadcast.workspace_list_topic(dataset, ws.id)],
          else: []
        )

    if connected?(socket) and topics != socket.assigns.topics do
      Enum.each(socket.assigns.topics, &Phoenix.PubSub.unsubscribe(Barkpark.PubSub, &1))
      Enum.each(topics, &Phoenix.PubSub.subscribe(Barkpark.PubSub, &1))
      assign(socket, :topics, topics)
    else
      socket
    end
  end

  @doc """
  A `{:document_changed, msg}` arrived: remember what went stale and ask for
  one `:desk_refresh` a moment later. Another tenant's frame is dropped.
  """
  def changed(socket, %{type: type, doc_id: doc_id} = msg) do
    if ours?(msg, socket) do
      stale = MapSet.put(socket.assigns.stale, {type, Content.published_id(doc_id)})

      timer =
        socket.assigns.refresh_timer ||
          Process.send_after(self(), :desk_refresh, @refresh_after_ms)

      assign(socket, stale: stale, refresh_timer: timer)
    else
      socket
    end
  end

  @doc "`:desk_refresh` fired: every stale pane but the one being edited reads again."
  def refresh(socket) do
    stale = socket.assigns.stale
    types = MapSet.new(stale, &elem(&1, 0))

    for %{pane: pane, id: id, index: index} <- socket.assigns.desk_panes,
        index != socket.assigns.active,
        stale?(pane, stale, types) do
      send_update(PaneComponent, id: id, refresh: true)
    end

    assign(socket, stale: MapSet.new(), refresh_timer: nil)
  end

  defp stale?(%{kind: :list, type: type}, _stale, types), do: MapSet.member?(types, type)

  defp stale?(%{kind: :doc, type: type, id: id}, stale, _types),
    do: MapSet.member?(stale, {type, id})

  defp stale?(_pane, _stale, _types), do: false

  # Another workspace's frame on the shared topic, or a sibling project's
  # document with the same id, is not this desk's (as StudioLive refuses them).
  defp ours?(msg, socket) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]

    Shared.own_tenant?(msg, is_map(ws) && ws.id) and
      not (is_binary(msg[:project_id]) and is_map(proj) and is_binary(proj.id) and
             msg.project_id != proj.id)
  end
end
