defmodule BarkparkWeb.Studio.StudioLive.Handlers.Secondary do
  @moduledoc """
  Secondary pane (read-only second editor) + blast-radius graph open.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Shared

  def open_secondary_picker(socket) do
    type = socket.assigns[:editor_type]

    candidates =
      if type do
        type
        |> Content.list_documents(
          socket.assigns.dataset,
          [perspective: :drafts] ++ ScopeHelpers.scope_opts(socket)
        )
        |> Enum.map(fn d ->
          pub = Content.published_id(d.doc_id)
          %{id: pub, title: d.title || "Untitled", type: type}
        end)
        |> Enum.reject(fn c ->
          socket.assigns[:editor_doc] &&
            c.id == Content.published_id(socket.assigns.editor_doc.doc_id)
        end)
      else
        []
      end

    {:noreply,
     assign(socket,
       show_secondary_picker: true,
       secondary_search: "",
       secondary_candidates: candidates
     )}
  end

  def view_graph(socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: doc_id} when is_binary(doc_id) ->
        pub_id = Content.published_id(doc_id)
        path = ["graph", pub_id]

        {:noreply,
         push_patch(socket, to: Shared.studio_path(socket, path, socket.assigns.dataset))}

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  A click on a node in the blast-radius graph pane.

  THE CRASH THIS CLOSES: the shared Canvas2D renderer (`bp-graph.js`, mounted as
  `Hooks.GraphPane`) installs `onNodeClick -> pushEvent("node-clicked", {id})`
  UNCONDITIONALLY on every host that mounts it, and `Studio.GraphView` is a
  `live_component` that mounts it with NO `phx-target` — so the event lands on
  the parent `StudioLive`. LiveView has no catch-all `handle_event/3`, so the
  missing clause was a `FunctionClauseError` that KILLED the view on the FIRST
  node click (blank page + remount). #14778 fixed the `FinderLive` half only.

  THE BEHAVIOUR — open the clicked document, via the reserved
  `["open", type, doc_id]` nav path, the same door the backlinks panel uses
  (`Handlers.Paper.open_backlink/2`). That path is the right one precisely
  because a graph node may live OUTSIDE the currently-navigated structure
  subtree: `PaneBuilder.walk_path/7` resolves it with no structure lookup and
  emits the editor map a desk row-click emits. `view_graph/1` above is the
  inbound leg (document -> its blast radius); this is the outbound one
  (a node in the blast radius -> that document).

  THE ID IS RESOLVED AGAINST THE PAYLOAD ALREADY ON THE SOCKET, never with a
  fresh PK read — and that is a SECURITY property, not a performance one. The
  wire carries only `documents.id` (the hook pushes `{id}`, and `bp-graph.js` is
  a 4-copy mirror set under a drift gate, so the payload cannot be widened),
  while the nav path needs `{type, doc_id}` — both of which the node maps in
  `@graph_data.nodes` already carry. `graph_data` was built under THIS caller's
  tenancy scope (`Content.Graph.traverse/2` -> `hydrate_nodes/2` ->
  `scope_query/2`), so matching against it fails CLOSED for free: an event is
  forgeable, and a `Repo.get(Document, id)` here would answer for any UUID on
  earth and leak a foreign document's slug into the URL bar. An id that is not
  in this socket's own payload is an inert no-op.

  Phantom (dangling-target) nodes carry `id: nil` and the hook already refuses
  to push for them; the binary guard is the server-side half of that.
  """
  def node_clicked(%{"id" => id}, socket) when is_binary(id) and id != "" do
    case find_graph_node(socket, id) do
      %{doc_id: doc_id, type: type}
      when is_binary(doc_id) and doc_id != "" and is_binary(type) and type != "" ->
        path = ["open", type, Content.published_id(doc_id)]

        {:noreply,
         push_patch(socket, to: Shared.studio_path(socket, path, socket.assigns.dataset))}

      _ ->
        {:noreply, socket}
    end
  end

  def node_clicked(_params, socket), do: {:noreply, socket}

  # The scoped node list the client was actually given. nil-safe on a socket
  # that is not on the graph pane (mount seeds `%{nodes: [], edges: []}`).
  defp find_graph_node(socket, id) do
    case socket.assigns[:graph_data] do
      %{nodes: nodes} when is_list(nodes) -> Enum.find(nodes, &(Map.get(&1, :id) == id))
      _ -> nil
    end
  end

  def close_secondary_picker(socket) do
    {:noreply, assign(socket, show_secondary_picker: false, secondary_search: "")}
  end

  def secondary_search(%{"value" => q}, socket) do
    {:noreply, assign(socket, secondary_search: q)}
  end

  def select_secondary(%{"id" => doc_id}, socket) do
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    case Content.fetch_doc_with_draft(type, doc_id, dataset, ScopeHelpers.scope_opts(socket)) do
      {nil, _, _} ->
        {:noreply, put_flash(socket, :error, "Document not found")}

      {doc, _, _} ->
        schema =
          case Content.resolve_schema(type, dataset, ScopeHelpers.scope_opts(socket)) do
            {:ok, s} -> s
            _ -> nil
          end

        {:noreply,
         assign(socket,
           secondary_doc: doc,
           secondary_schema: schema,
           secondary_type: type,
           show_secondary_picker: false,
           secondary_search: ""
         )}
    end
  end

  def close_secondary(socket) do
    {:noreply, assign(socket, secondary_doc: nil, secondary_schema: nil, secondary_type: nil)}
  end
end
