defmodule BarkparkWeb.Studio.Desk.LiveRefresh do
  @moduledoc """
  The desk slice's live updates: someone else saved (`BarkparkWeb.Studio.DeskLive`).

  Every document change in the dataset is announced on one of two topics
  (`Content.Broadcast`: the workspace's own, or the shared layer's). The
  panes that show the changed type read again, a moment later so a burst of
  saves is one read.

  A pane that is asked to read again drops the read it had in flight, so a
  steady stream of changes (an import, a bulk publish) must not ask faster
  than a read can land. The wait before a read doubles while changes keep
  arriving right behind the last read, up to `@refresh_max_ms`, and falls back
  to `@refresh_after_ms` as soon as the stream pauses. The last change is
  always followed by one read.

  `DeskLive` keeps the `handle_info/2` clauses and hands each one here; this
  module owns the `topics`, `stale`, `refresh_timer`, `refresh_gap` and `last_read_ms` assigns.
  """

  use BarkparkWeb, :html

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.PresenceState
  alias BarkparkWeb.Studio.StudioLive.Paths
  alias BarkparkWeb.Studio.StudioLive.Shared

  @refresh_after_ms 120
  # A change this soon after a read means more are coming: wait longer.
  @storm_within_ms 250
  @refresh_max_ms 1_920

  @doc "The assigns this module owns, empty."
  def init(socket) do
    assign(socket,
      topics: [],
      stale: MapSet.new(),
      refresh_timer: nil,
      refresh_gap: @refresh_after_ms,
      last_read_ms: nil
    )
  end

  @doc """
  Listens to the dataset's two list topics and joins its presence room, and
  leaves the last dataset's.
  """
  def subscribe(socket, dataset), do: socket |> subscribe_lists(dataset) |> join(dataset)

  defp subscribe_lists(socket, dataset) do
    socket =
      socket |> assign_new(:desk_gone, fn -> %{} end) |> assign_new(:desk_retries, fn -> %{} end)

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
      socket |> listen() |> assign(:topics, topics)
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

      if socket.assigns.refresh_timer do
        assign(socket, :stale, stale)
      else
        gap = gap(socket.assigns.refresh_gap, socket.assigns.last_read_ms)
        timer = Process.send_after(self(), :desk_refresh, gap)
        assign(socket, stale: stale, refresh_timer: timer, refresh_gap: gap)
      end
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

    assign(socket,
      stale: MapSet.new(),
      refresh_timer: nil,
      last_read_ms: System.monotonic_time(:millisecond)
    )
  end

  # The wait before the next read: twice the last one when this change came
  # right behind a read, the short one otherwise.
  defp gap(last, last_read_ms) when is_integer(last_read_ms) do
    if System.monotonic_time(:millisecond) - last_read_ms < @storm_within_ms,
      do: min(last * 2, @refresh_max_ms),
      else: @refresh_after_ms
  end

  defp gap(_last, _last_read_ms), do: @refresh_after_ms

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
      # The first render is not in the room; `presence_session` is read by
      # the page's render all the same.
      assign_new(socket, :presence_session, fn -> nil end)
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

  # ── a pane whose read failed, and a document someone else deleted ──────────
  #
  # Both are the page's to notice, so they ride one `:handle_info` hook,
  # attached with the first subscription (a connected page only). It owns
  # `{:desk_pane_failed, id}` (a pane's read failed: the pane sends it) and
  # `{:desk_pane_retry, id}` (this module's own timer); it looks at, and passes
  # on, `{:desk_pane_title, index, _}` (a pane's read landed) and
  # `{:document_changed, msg}`. Assigns: `desk_retries` and `desk_gone`.

  # J50, as Sanity's document list does it (useDocumentList.ts): a failed read
  # tries again at once, then after 1 s, 2 s, ... ten times, then waits for Retry.
  @retry_waits_ms for n <- 0..9, do: n * 1_000

  @doc """
  The waits before each automatic read of a failed pane, in order; after the
  last one the pane keeps its card and Retry. A pane's read that lands starts
  the count again. Test seam: `config :barkpark, #{inspect(__MODULE__)}, retry_waits_ms: [...]`.
  """
  def retry_waits_ms,
    do: Application.get_env(:barkpark, __MODULE__, [])[:retry_waits_ms] || @retry_waits_ms

  defp listen(%{assigns: %{topics: []}} = socket),
    do: attach_hook(socket, :desk_live_refresh, :handle_info, &on_info/2)

  defp listen(socket), do: socket

  defp on_info({:desk_pane_failed, id}, socket), do: {:halt, failed(socket, id)}
  defp on_info({:desk_pane_retry, id}, socket), do: {:halt, retry(socket, id)}
  defp on_info({:desk_pane_title, index, _title}, socket), do: {:cont, landed(socket, index)}

  defp on_info({:document_changed, %{type: _, doc_id: _} = msg}, socket),
    do: {:cont, note_gone(socket, msg)}

  defp on_info(_message, socket), do: {:cont, socket}

  defp failed(socket, id) do
    tries = Map.get(socket.assigns.desk_retries, id, 0)

    case Enum.at(retry_waits_ms(), tries) do
      nil ->
        socket

      wait ->
        Process.send_after(self(), {:desk_pane_retry, id}, wait)
        assign(socket, :desk_retries, Map.put(socket.assigns.desk_retries, id, tries + 1))
    end
  end

  # The pane may have closed meanwhile, or become the editor's.
  defp retry(socket, id) do
    if Enum.any?(socket.assigns.desk_panes, &(&1.id == id and &1.index != socket.assigns.active)) do
      send_update(PaneComponent, id: id, refresh: true)
      socket
    else
      assign(socket, :desk_retries, Map.delete(socket.assigns.desk_retries, id))
    end
  end

  defp landed(socket, index) do
    case Enum.find(socket.assigns.desk_panes, &(&1.index == index)) do
      %{id: id} -> assign(socket, :desk_retries, Map.delete(socket.assigns.desk_retries, id))
      nil -> socket
    end
  end

  # J32. A delete names one row (`drafts.x` or `x`), and discarding a draft is
  # announced the same way while the published document stays, so a delete of
  # a document on the desk is checked against the store. Any other change to
  # it (a restore, someone writing it again) means it is back.
  @gone_mutations ~w(delete discardDraft)

  defp note_gone(socket, %{type: type, doc_id: doc_id} = msg) do
    id = Content.published_id(doc_id)
    gone = socket.assigns.desk_gone

    cond do
      not ours?(msg, socket) ->
        socket

      msg[:mutation] not in @gone_mutations ->
        assign(socket, :desk_gone, Map.delete(gone, {type, id}))

      shown?(socket.assigns.desk_panes, type, id) and missing?(socket, type, id) ->
        title = get_in(msg, [:doc, :title])
        title = if is_binary(title) and title != "", do: title, else: id
        assign(socket, :desk_gone, Map.put(gone, {type, id}, title))

      true ->
        socket
    end
  end

  defp shown?(views, type, id),
    do: Enum.any?(views, &(match?(%{pane: %{kind: :doc, id: ^id}}, &1) and doc_type(&1, type)))

  # A followed reference with no `type=` in the URL is matched by id alone.
  defp doc_type(%{pane: pane}, type), do: pane[:untyped] || pane[:type] in [nil, type]

  defp missing?(socket, type, id) do
    %{dataset: dataset, scope: scope} = socket.assigns
    match?({nil, _, _}, Content.fetch_doc_with_draft(type, id, dataset, scope))
  rescue
    # The store cannot say: the desk says nothing rather than something false.
    _ -> false
  end

  @doc """
  Whether `{type, id}` was deleted by someone else while it was on the desk
  (`desk_gone`). For a caller that must not write to it, such as the editor.
  """
  def gone?(assigns, type, id), do: Map.has_key?(assigns[:desk_gone] || %{}, {type, id})

  @doc """
  The desk's notice for each document in the chain that someone else deleted,
  with a link that closes its pane. Takes the page's `desk_gone`, `desk_panes`,
  `chain` and `base` as `gone`, `panes`, `chain` and `base`.
  """
  def gone_notice(assigns) do
    items =
      for %{pane: %{kind: :doc, id: id} = pane, index: index} <- assigns.panes,
          {{type, ^id}, title} <- assigns.gone,
          pane[:untyped] || pane[:type] in [nil, type],
          do: %{index: index, title: title}

    assigns = assign(assigns, :items, items)

    ~H"""
    <div :if={@items != []} class="dk-gone" role="alert" data-desk-gone>
      <p :for={item <- @items} class="dk-note" data-desk-gone-pane={item.index}>
        {gettext("This document has been deleted.")}
        <strong>{item.title}</strong>
        <.link patch={Panes.close_from(@chain, item.index, @base)} class="btn">
          {gettext("Close")}
        </.link>
      </p>
    </div>
    """
  end
end
