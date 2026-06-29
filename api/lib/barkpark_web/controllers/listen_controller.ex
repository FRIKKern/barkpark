defmodule BarkparkWeb.ListenController do
  @moduledoc "Server-Sent Events endpoint for real-time document changes with Last-Event-ID resume."

  use BarkparkWeb, :controller
  import Ecto.Query
  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]
  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Envelope, MutationEvent}

  def listen(conn, %{"dataset" => dataset} = params) do
    since =
      case get_req_header(conn, "last-event-id") do
        [v | _] -> parse_int(v)
        _ -> parse_int(params["lastEventId"])
      end

    # Tenancy scope from the resolved workspace (ResolveWorkspace /
    # AssignDefaultScope). nil → unfiltered stream (pre-tenancy back-compat).
    workspace_id = scope_workspace_id(conn)

    # The subscriber's principal + read scope, captured ONCE at connect. Every
    # emitted event re-renders the current document through `Envelope.render/3`
    # under this caller, so a `private` / `owner_only` field is dropped before it
    # reaches a non-authorized subscriber — the SSE leg of the field-visibility
    # invariant. An admin caller ⇒ render/3 is a no-op ⇒ byte-identical stream.
    scope = scope_opts(conn)
    caller_context = Keyword.get(scope, :caller_context)

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
          # The replay path reads the STORED mutation_events.document — a frozen,
          # unredacted snapshot. Re-render from the CURRENT document so a privacy
          # change since write is honoured; fall back to redacting the snapshot
          # only when the document is gone (a delete event).
          ev = Map.put(ev, :document, redacted_result(ev, dataset, caller_context, scope))

          case chunk(c, format_event(ev, dataset)) do
            {:ok, c2} -> c2
            _ -> c
          end
        end)
      else
        conn
      end

    listen_loop(conn, dataset, workspace_id, caller_context, scope)
  end

  @doc """
  Return mutation_events for dataset with id > since, oldest first.

  With a non-nil `workspace_id`, only events whose document belongs to that
  workspace are returned — the SSE stream is the hard tenant boundary for
  real-time changes, mirroring the query-layer WHERE workspace_id filter.

  The filter joins on the owning `documents` row (by `doc_id` + `dataset`)
  rather than reading `mutation_events.workspace_id` directly. The event row's
  own `workspace_id` column *is* populated — `save_event/5` in `Barkpark.Content`
  stamps it from `doc.workspace_id` on every write — but the document's scope
  remains the authoritative tenant boundary: it's the single source of truth a
  document can be moved/reconciled against, so joining on it is correct
  regardless of the denormalised event column. nil `workspace_id` → unfiltered
  (back-compat).
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

  defp listen_loop(conn, dataset, workspace_id, caller_context, scope) do
    receive do
      {:document_changed, %{event_id: eid} = msg} ->
        if forward_event?(dataset, msg.doc_id, workspace_id) do
          # Re-render the live document under THIS subscriber instead of
          # forwarding the broadcast's pre-rendered (unredacted) envelope, so a
          # `private` / `owner_only` field never reaches a non-authorized caller.
          ev = %{
            id: eid,
            mutation: msg.mutation,
            type: msg.type,
            doc_id: msg.doc_id,
            rev: msg.rev,
            previous_rev: nil,
            document: redacted_result(msg, dataset, caller_context, scope)
          }

          case chunk(conn, format_event(ev, dataset)) do
            {:ok, c} -> listen_loop(c, dataset, workspace_id, caller_context, scope)
            _ -> conn
          end
        else
          # Event belongs to a different workspace — drop it, keep listening.
          listen_loop(conn, dataset, workspace_id, caller_context, scope)
        end

      # Ignore legacy messages without event_id (defensive)
      {:document_changed, _} ->
        listen_loop(conn, dataset, workspace_id, caller_context, scope)
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, c} -> listen_loop(c, dataset, workspace_id, caller_context, scope)
          _ -> conn
        end
    end
  end

  # The field-visibility chokepoint for the SSE stream. `event` is either a live
  # broadcast `msg` or a stored `%MutationEvent{}` — both carry `doc_id`, `type`
  # and a frozen `document` snapshot. Re-render from the CURRENT document (which
  # also supplies `owner_id` for `owner_only`); when it is gone (a delete event)
  # redact the frozen snapshot directly. A nil caller (unscoped / back-compat)
  # is a no-op ⇒ the verbatim snapshot, byte-identical to the legacy stream.
  #
  # Public (`@doc false`) so the field-visibility leak-guard can assert the drop
  # directly — same testing seam as `replay_since/3`, `format_event/2` and
  # `forward_event?/3` (the live `receive` loop is otherwise un-assertable).
  @doc false
  def redacted_result(event, _dataset, nil, _scope), do: event.document

  def redacted_result(event, dataset, %CallerContext{} = ctx, scope) do
    case Content.get_document(event.doc_id, event.type, dataset, scope) do
      {:ok, doc} ->
        Envelope.render(doc, fetch_schema(event.type, dataset, scope), ctx)

      _ ->
        Envelope.redact(event.document, fetch_schema(event.type, dataset, scope), ctx)
    end
  end

  defp fetch_schema(type, dataset, scope) do
    case Content.get_schema(type, dataset, scope) do
      {:ok, schema} -> schema
      _ -> nil
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
