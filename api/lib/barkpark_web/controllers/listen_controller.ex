defmodule BarkparkWeb.ListenController do
  @moduledoc "Server-Sent Events endpoint for real-time document changes with Last-Event-ID resume."

  use BarkparkWeb, :controller
  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, EventLog}

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
    # forward_event?/2) every co-dataset tenant's events — the bare
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
          # only when the document is gone (a delete event). A `:drop` means the
          # row exists but this caller is denied it by the owner-row ACL — skip
          # the chunk entirely so a non-owner never replays another user's row.
          case redacted_result(ev, dataset, caller_context, scope) do
            :drop ->
              c

            result ->
              ev = Map.put(ev, :document, result)

              case chunk(c, format_event(ev, dataset)) do
                {:ok, c2} -> c2
                _ -> c
              end
          end
        end)
      else
        conn
      end

    listen_loop(conn, dataset, workspace_id, caller_context, scope)
  end

  @doc """
  Transport-thin delegate to `Barkpark.Content.EventLog.replay_since/4` — the
  domain owns the keyset-paginated Last-Event-ID replay query; the controller
  only streams it. Kept as a public seam so the tenant-scope contract tests can
  assert the replay filter directly (same convention as `format_event/2`).
  """
  defdelegate replay_since(dataset, since, workspace_id \\ nil, opts \\ []), to: EventLog

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

  # Build the SSE event map for a LIVE broadcast `msg` (the same shape
  # `format_event/2` serializes for the replay path). `previous_rev` is carried
  # straight from the broadcast (`broadcast.ex` stamps it) so the live stream
  # populates `previousRev` identically to the Last-Event-ID replay — a client
  # building a rev/CAS chain off the stream sees the same field on both legs.
  #
  # Public (`@doc false`) so the previous_rev pass-through can be asserted
  # against the replay serialization — the live `receive` loop is otherwise
  # un-assertable, same testing seam as `format_event/2` and `replay_since/3`.
  @doc false
  def live_event(msg, result) do
    %{
      id: msg.event_id,
      mutation: msg.mutation,
      type: msg.type,
      doc_id: msg.doc_id,
      rev: msg.rev,
      previous_rev: Map.get(msg, :previous_rev),
      document: result
    }
  end

  defp listen_loop(conn, dataset, workspace_id, caller_context, scope) do
    receive do
      {:document_changed, %{event_id: _eid} = msg} ->
        if forward_event?(msg, workspace_id) do
          # Re-render the live document under THIS subscriber instead of
          # forwarding the broadcast's pre-rendered (unredacted) envelope, so a
          # `private` / `owner_only` field never reaches a non-authorized caller.
          # A `:drop` means the owner-row ACL denied this caller the live row
          # (an owner_scoped doc owned by another user) — skip emitting so the
          # frozen snapshot of that row never reaches a non-owner subscriber.
          case redacted_result(msg, dataset, caller_context, scope) do
            :drop ->
              listen_loop(conn, dataset, workspace_id, caller_context, scope)

            result ->
              case chunk(conn, format_event(live_event(msg, result), dataset)) do
                {:ok, c} -> listen_loop(c, dataset, workspace_id, caller_context, scope)
                _ -> conn
              end
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

  # The field-visibility + row-ACL chokepoint for the SSE stream. `event` is
  # either a live broadcast `msg` or a stored `%MutationEvent{}` — both carry
  # `doc_id`, `type` and a frozen `document` snapshot. Re-render from the CURRENT
  # document (which also supplies `owner_id` for `owner_only`).
  #
  # A real anonymous SSE subscriber arrives as a `%CallerContext{}` (anonymous),
  # NOT nil — `scope_opts/1` → `CallerContext.from_conn/1` always falls back to
  # `anonymous()`, never nil — and is fail-closed through the `%CallerContext{}`
  # clause below (re-render under the anonymous principal ⇒ public-only). The
  # `nil` clause is a back-compat no-op that is UNREACHABLE from any request
  # path; it survives only as the direct testing seam (verbatim snapshot).
  #
  # When the live document is UNREADABLE for this caller, distinguish the two
  # causes the bare `not_found` conflated:
  #   * row GONE (a genuine delete) → redact + forward the frozen snapshot, as
  #     before — the delete leg.
  #   * row STILL EXISTS but denied by the owner-row ACL (an `owner_scoped` doc
  #     owned by another user) → return `:drop`. The frozen `event.document` is
  #     a full render of that owner's row, so forwarding it would defeat the
  #     row-level isolation `owner_scoped` exists to provide; the live loop and
  #     replay both skip emitting on `:drop`.
  #
  # Public (`@doc false`) so the row-ACL leak-guard can assert the drop directly
  # — same testing seam as `replay_since/3`, `format_event/2` and
  # `forward_event?/2` (the live `receive` loop is otherwise un-assertable).
  @doc false
  # nil caller: UNREACHABLE from any request path (scope_opts/1 always yields an
  # anonymous %CallerContext{}, never nil) — back-compat no-op kept as a test seam.
  def redacted_result(event, _dataset, nil, _scope), do: event.document

  def redacted_result(event, dataset, %CallerContext{} = ctx, scope) do
    case Content.get_document(event.doc_id, event.type, dataset, scope) do
      {:ok, doc} ->
        Envelope.render(doc, fetch_schema(event.type, dataset, scope), ctx)

      _ ->
        if owner_scoped_denied?(event, dataset, scope) do
          :drop
        else
          Envelope.redact(event.document, fetch_schema(event.type, dataset, scope), ctx)
        end
    end
  end

  # True when the unreadable event is an owner-row ACL denial (not a delete):
  # the type is `owner_scoped` AND the row is still present — so `get_document`
  # filtered it out for ownership, not because it is gone.
  defp owner_scoped_denied?(event, dataset, scope) do
    Content.owner_scoped?(event.type, dataset, scope) and
      EventLog.document_present?(event.doc_id, dataset)
  end

  defp fetch_schema(type, dataset, scope) do
    case Content.get_schema(type, dataset, scope) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  # Workspace ownership gate for a live event. nil scope → forward everything
  # (back-compat / unscoped listener). With a workspace, forward only when the
  # broadcast msg's own denormalised `workspace_id` matches; a cross-workspace
  # event is dropped.
  #
  # Reads `msg.workspace_id` (stamped from `doc.workspace_id` by `tap_broadcast`)
  # instead of a `Repo.exists?(Document …)` existence check. The existence check
  # silently DROPPED every delete tombstone: a delete's `documents` row is GONE
  # by the time the event fires, so the check matched nothing and the
  # tenant-scoped listener never learned of the delete (its cache served the
  # deleted doc forever). The msg's denormalised column survives the delete and
  # is the correct tenant discriminator here. Authz is unchanged —
  # `redacted_result/4` still governs field-visibility on what gets emitted.
  #
  # Public (`@doc false`) so the cross-tenant isolation contract can assert the
  # drop directly — same testing seam as `replay_since/3` and `format_event/2`.
  @doc false
  def forward_event?(_msg, nil), do: true

  def forward_event?(%{workspace_id: event_ws}, workspace_id)
      when is_binary(workspace_id),
      do: event_ws == workspace_id

  # Msg without a workspace_id key (defensive) — a scoped listener drops it.
  def forward_event?(_msg, workspace_id) when is_binary(workspace_id), do: false

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

  # Catch-all: a list param (`?lastEventId[]=1` → Plug parses to a list) or any
  # other non-scalar falls back to nil instead of raising FunctionClauseError → 500.
  defp parse_int(_), do: nil
end
