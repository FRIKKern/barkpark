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

  use BarkparkWeb, :html

  import Phoenix.LiveView, only: [connected?: 1, send_update: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.PresenceState
  alias BarkparkWeb.Studio.StudioLive.Paths
  alias BarkparkWeb.Studio.StudioLive.Shared

  @refresh_after_ms 120

  @doc "The assigns this module owns, empty."
  def init(socket), do: assign(socket, topics: [], stale: MapSet.new(), refresh_timer: nil)

  @doc """
  Listens to the dataset's two list topics and joins its presence room, and
  leaves the last dataset's.
  """
  def subscribe(socket, dataset), do: socket |> subscribe_lists(dataset) |> join(dataset)

  defp subscribe_lists(socket, dataset) do
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

  # ── Presence ─────────────────────────────────────────────────────────────
  #
  # The hosted editor (`StudioLive`) joins the presence room and tracks its
  # document only when it loads one, so a desk showing lists only was in
  # nobody's room, and closing the document pane left its document tracked.
  # The page joins the room itself, as the Studio's own desk does: on the
  # first URL (and a new dataset) it is tracked browsing; the editor then
  # tracks the document it loads; a URL with no document to edit tracks it
  # browsing again. The room, the meta and `presence_diff` are the Studio's
  # (`Shared.track_presence/1`, `Lifecycle.presence_diff/2`), so the navbar's
  # "who's online" and the editor's dots read the same `presences`.

  defp join(socket, dataset) do
    user_id = socket.assigns[:user_id]

    if connected?(socket) and is_binary(user_id) do
      topic =
        PresenceState.topic(
          id(socket.assigns[:current_workspace]),
          id(socket.assigns[:current_project]),
          dataset
        )

      old = socket.assigns[:presence_topic]

      cond do
        topic != old ->
          if old do
            Presence.untrack(self(), old, user_id)
            Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old)
          end

          Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
          browse(socket, topic, user_id, dataset)

        leaves_document?(socket, dataset) ->
          browse(socket, topic, user_id, dataset)

        true ->
          socket
      end
    else
      socket
    end
  end

  # Tracked on no document: the Studio's meta with `doc_id` and `type` nil.
  defp browse(socket, topic, user_id, dataset) do
    meta = %{
      doc_id: nil,
      type: nil,
      dataset: dataset,
      project_id: id(socket.assigns[:current_project]),
      name: socket.assigns[:user_name],
      color: socket.assigns[:user_color],
      joined_at: System.system_time(:second),
      session_id: socket.id
    }

    case Presence.track(self(), topic, user_id, meta) do
      {:ok, _ref} ->
        :ok

      {:error, {:already_tracked, _pid, _topic, _key}} ->
        Presence.update(self(), topic, user_id, meta)
    end

    assign(socket,
      presence_topic: topic,
      presence_session: socket.id,
      presences: PresenceState.list(topic)
    )
  end

  # The editor is on a document and the URL being handled edits none (its
  # last pane closed, a list or menu took its place). `subscribe/2` runs
  # before the page assigns the new chain, so the chain is read from the URL
  # the chrome's `:handle_params` hook just put in `current_path`.
  defp leaves_document?(socket, dataset) do
    socket.assigns[:editing] != nil and
      case chain(socket, dataset) do
        {:ok, chain} -> EditorHost.target(chain, dataset) == nil
        :unknown -> false
      end
  end

  defp chain(socket, dataset) do
    base = Paths.studio_path(socket.assigns[:scope_prefix], ["_desk"], dataset)

    with %{root: root} <- socket.assigns[:desk],
         path when is_binary(path) <- socket.assigns[:current_path],
         {:ok, splat} <- splat(path, base) do
      {:ok, Tree.parse(splat, root)}
    else
      _ -> :unknown
    end
  end

  defp splat(base, base), do: {:ok, ""}

  defp splat(path, base) do
    if String.starts_with?(path, base <> "/"),
      do: {:ok, path |> String.replace_prefix(base <> "/", "") |> URI.decode()},
      else: :unknown
  end

  defp id(%{id: id}) when is_binary(id), do: id
  defp id(_), do: nil

  @doc """
  The other people on each document of `dataset`, by published id: what a
  list row marks. `session` (the page's `presence_session`) is left out.
  """
  def on_rows(presences, dataset, session) do
    presences
    |> Enum.filter(
      &(is_binary(&1[:doc_id]) and &1[:dataset] == dataset and &1[:session_id] != session)
    )
    |> Enum.group_by(& &1.doc_id)
  end

  @doc "A list row's mark: one dot per other person who has its document open."
  attr :people, :list, default: []

  def row_mark(assigns) do
    ~H"""
    <span
      :if={@people != []}
      class="dk-row-presence"
      style="display: inline-flex; align-items: center; margin-left: auto"
      role="img"
      aria-label={label(@people)}
    >
      <span :for={p <- @people} class="presence-dot-sm" style={"background: #{p.color}"}></span>
    </span>
    """
  end

  defp label(people) do
    case Enum.map(people, &(&1[:name] || gettext("User"))) do
      [one] -> gettext("%{name} is editing", name: one)
      many -> gettext("%{names} are editing", names: Enum.join(many, ", "))
    end
  end
end
