defmodule BarkparkWeb.ListenController do
  @moduledoc "Server-Sent Events endpoint for real-time document changes with Last-Event-ID resume."

  use BarkparkWeb, :controller
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent}

  def listen(conn, %{"dataset" => dataset} = params) do
    since =
      case get_req_header(conn, "last-event-id") do
        [v | _] -> parse_int(v)
        _ -> parse_int(params["lastEventId"])
      end

    # Tenancy scope from the resolved workspace (ResolveWorkspace /
    # AssignDefaultScope). nil → unfiltered stream (pre-tenancy back-compat).
    workspace_id = scope_workspace_id(conn)

    # Subscribe to the workspace-scoped topic when we have a resolved
    # workspace, so this stream no longer receives (and discards via
    # forward_event?/3) every co-dataset tenant's events — the bare
    # `documents:#{dataset}` topic fans out to ALL tenants (barkpark-fe2k).
    # content.ex's tap_broadcast/5 fires BOTH the bare topic AND
    # `documents:ws:#{ws}:#{dataset}` for scoped writes, so self-delivery is
    # intact; the nil/Default (flat back-compat) path keeps the bare topic.
    Phoenix.PubSub.subscribe(Barkpark.PubSub, list_topic(dataset, workspace_id))

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: welcome\ndata: {\"type\":\"welcome\"}\n\n")

    conn =
      if since do
        Enum.reduce(replay_since(dataset, since, workspace_id), conn, fn ev, c ->
          case chunk(c, format_event(ev, dataset)) do
            {:ok, c2} -> c2
            _ -> c
          end
        end)
      else
        conn
      end

    listen_loop(conn, dataset, workspace_id)
  end

  @doc """
  Return mutation_events for dataset with id > since, oldest first.

  With a non-nil `workspace_id`, only events whose document belongs to that
  workspace are returned — the SSE stream is the hard tenant boundary for
  real-time changes, mirroring the query-layer WHERE workspace_id filter.

  The filter joins on the owning `documents` row (by `doc_id` + `dataset`)
  rather than `mutation_events.workspace_id`, because the event row's own scope
  column is not populated by the current write path; the document's scope is
  the authoritative source. nil `workspace_id` → unfiltered (back-compat).
  """
  def replay_since(dataset, since, workspace_id \\ nil)

  def replay_since(dataset, since, nil) when is_integer(since) do
    from(e in MutationEvent, where: e.dataset == ^dataset and e.id > ^since, order_by: e.id)
    |> Repo.all()
  end

  def replay_since(dataset, since, workspace_id)
      when is_integer(since) and is_binary(workspace_id) do
    from(e in MutationEvent,
      join: d in Document,
      on: d.doc_id == e.doc_id and d.dataset == e.dataset,
      where: e.dataset == ^dataset and e.id > ^since and d.workspace_id == ^workspace_id,
      order_by: e.id,
      select: e
    )
    |> Repo.all()
  end

  def replay_since(_dataset, _, _), do: []

  @doc false
  def format_event(ev, dataset) do
    pub_id = Content.published_id(ev.doc_id)

    sync_tags = [
      "bp:ds:#{dataset}:doc:#{pub_id}",
      "bp:ds:#{dataset}:type:#{ev.type}"
    ]

    data =
      Jason.encode!(%{
        eventId: ev.id,
        mutation: ev.mutation,
        type: ev.type,
        documentId: ev.doc_id,
        rev: ev.rev,
        previousRev: ev.previous_rev,
        result: ev.document,
        syncTags: sync_tags
      })

    "id: #{ev.id}\nevent: mutation\ndata: #{data}\n\n"
  end

  defp listen_loop(conn, dataset, workspace_id) do
    receive do
      {:document_changed, %{event_id: eid} = msg} ->
        if forward_event?(dataset, msg.doc_id, workspace_id) do
          ev = %{
            id: eid,
            mutation: msg.mutation,
            type: msg.type,
            doc_id: msg.doc_id,
            rev: msg.rev,
            previous_rev: nil,
            document: msg.document
          }

          case chunk(conn, format_event(ev, dataset)) do
            {:ok, c} -> listen_loop(c, dataset, workspace_id)
            _ -> conn
          end
        else
          # Event belongs to a different workspace — drop it, keep listening.
          listen_loop(conn, dataset, workspace_id)
        end

      # Ignore legacy messages without event_id (defensive)
      {:document_changed, _} ->
        listen_loop(conn, dataset, workspace_id)
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, c} -> listen_loop(c, dataset, workspace_id)
          _ -> conn
        end
    end
  end

  # Workspace ownership gate for a live event. nil scope → forward everything
  # (back-compat / unscoped listener). With a workspace, forward only when the
  # event's document belongs to it; an orphaned/cross-workspace doc is dropped.
  #
  # Public (`@doc false`) so the cross-tenant isolation contract can assert the
  # drop directly — same testing seam as `replay_since/3` and `format_event/2`.
  @doc false
  def forward_event?(_dataset, _doc_id, nil), do: true

  def forward_event?(dataset, doc_id, workspace_id) when is_binary(workspace_id) do
    Repo.exists?(
      from(d in Document,
        where:
          d.doc_id == ^doc_id and d.dataset == ^dataset and
            d.workspace_id == ^workspace_id
      )
    )
  end

  defp scope_workspace_id(conn) do
    case conn.assigns[:current_workspace] do
      %{id: id} -> id
      _ -> nil
    end
  end

  # Resolve the PubSub topic for the document-list stream. With a workspace,
  # use the additive workspace-scoped topic broadcast by content.ex; without
  # one, fall back to the bare global topic (flat/Default back-compat).
  defp list_topic(dataset, workspace_id) when is_binary(workspace_id),
    do: "documents:ws:#{workspace_id}:#{dataset}"

  defp list_topic(dataset, _workspace_id), do: "documents:#{dataset}"

  defp parse_int(nil), do: nil

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
end
