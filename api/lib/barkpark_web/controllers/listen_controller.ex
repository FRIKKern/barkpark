defmodule BarkparkWeb.ListenController do
  @moduledoc "Server-Sent Events endpoint for real-time document changes with Last-Event-ID resume."

  use BarkparkWeb, :controller
  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, EventLog}

  def listen(conn, %{"dataset" => dataset} = params) do
    # Subscriber backpressure — HARD backstop (see the backpressure note above
    # listen_loop/5). Bound THIS connection process: message_queue_data is
    # on_heap, so the queued {:document_changed, …} messages count toward the
    # heap. If a FULLY stalled reader (chunk/2 never returns, so no Elixir code
    # runs to self-check) grows the mailbox past the ceiling, the BEAM kills
    # this ONE process instead of OOM-ing the node. A slow client losing its
    # stream is correct; a node dying is not.
    Process.flag(:max_heap_size, %{
      size: sse_max_heap_words(),
      kill: true,
      error_logger: true
    })

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
    forwarder =
      start_event_forwarder(
        list_topic(dataset, workspace_id),
        self(),
        sse_mailbox_limit()
      )

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Guard the welcome frame the same way every other chunk/2 site here does.
    # `Plug.Conn.chunk/2`'s own spec is `{:ok, t} | {:error, term} | no_return`,
    # so a client that disconnects between send_chunked(200) above and this
    # first frame turned a hard `{:ok, conn} = chunk(...)` bind into a MatchError
    # — a 500-class error log on a route built for long-lived flaky connections.
    # Census on the fence (`grep -rnE '(^|[^_[:alnum:]])chunk\(' \
    # api/lib/barkpark_web/controllers api/lib/barkpark_web/plugs | grep -v write_chunk`):
    # 11 chunk/2 call sites, 10 already case-guarded — including four in THIS
    # file (L80, L201, L216, L301) using this exact idiom. This line was the
    # only unguarded one, so the convention is the guard, not the bind.
    # NO CONN TEST CAN RED THIS LINE: Plug.Adapters.Test.Conn.chunk/2 returns
    # {:ok, ...} from every clause, so ConnTest cannot produce the {:error, _}
    # branch. No mutation proof is shipped with this change and none exists;
    # the census above is the evidence. The change is a strict widening — the
    # {:ok, _} path is behaviourally identical.
    conn =
      case chunk(conn, "event: welcome\ndata: {\"type\":\"welcome\"}\n\n") do
        {:ok, c} -> c
        _ -> conn
      end

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

    try do
      listen_loop(conn, dataset, workspace_id, caller_context, scope)
    after
      send(forwarder, :stop)
    end
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

  # --- Subscriber backpressure (Barkpark scar: unbounded BEAM mailbox) ---
  #
  # chunk/2 BLOCKS the connection process on Bandit while a stalled/slow TCP
  # reader drains. Subscribing that same process directly lets Phoenix.PubSub
  # fill its mailbox while no Elixir code can run. The event forwarder below is
  # the nonblocking subscriber: it caps deliveries to the connection mailbox,
  # then sends ONE overload signal and drops the remaining burst until the
  # connection returns and stops it. The listener therefore owns at most the
  # configured event window plus that signal even while chunk/2 is fully stuck.
  # Two complementary bounds remain:
  #
  #   1. The forwarder caps the blocked connection's mailbox at limit + 1.
  #   2. This message_queue_len check emits a final `event: overloaded` and
  #      closes as soon as chunk/2 returns. max_heap_size remains a last-resort
  #      process-local guard for unrelated heap growth.
  defp listen_loop(conn, dataset, workspace_id, caller_context, scope) do
    case backpressure_step(conn, sse_mailbox_limit()) do
      {:shed, conn} ->
        # Backlog over the limit: shed cleanly rather than grow the heap.
        conn

      {:cont, conn} ->
        listen_recv(conn, dataset, workspace_id, caller_context, scope)
    end
  end

  defp listen_recv(conn, dataset, workspace_id, caller_context, scope) do
    receive do
      :sse_overloaded ->
        shed(conn)

      {:document_changed, %{event_id: _eid} = msg} ->
        if forward_event?(msg, workspace_id) do
          # Re-render the live document under THIS subscriber instead of
          # forwarding the broadcast's pre-rendered (unredacted) envelope, so a
          # `private` / `owner_only` field never reaches a non-authorized caller.
          # A `:drop` means the owner-row ACL denied this caller the live row
          # (an owner_scoped doc owned by another user) — skip emitting so the
          # frozen snapshot of that row never reaches a non-owner subscriber.
          #
          # `live_result/4` short-circuits the per-event `Content.get_document`
          # round-trip for an ADMIN caller (both redaction gates are proven
          # no-ops for admins — see its doc), forwarding the broadcast's
          # already-in-hand `:internal` render; every redacting caller still
          # re-derives visibility through `redacted_result/4` below.
          case live_result(msg, dataset, caller_context, scope) do
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

  defp start_event_forwarder(topic, listener, limit) do
    caller = self()

    pid =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        send(caller, {:sse_forwarder_ready, self()})
        event_forwarder(listener, limit)
      end)

    receive do
      {:sse_forwarder_ready, ^pid} -> pid
    end
  end

  defp event_forwarder(listener, limit) do
    receive do
      :stop ->
        :ok

      {:document_changed, _msg} = event ->
        case Process.info(listener, :message_queue_len) do
          {:message_queue_len, n} when n >= limit ->
            send(listener, :sse_overloaded)
            overloaded_forwarder()

          {:message_queue_len, _n} ->
            send(listener, event)
            event_forwarder(listener, limit)

          nil ->
            :ok
        end
    end
  end

  defp overloaded_forwarder do
    receive do
      :stop -> :ok
      {:document_changed, _msg} -> overloaded_forwarder()
    end
  end

  # One backpressure guard step: if the connection-process backlog is over the
  # limit, shed the slow consumer (emit a final `event: overloaded`, then
  # {:shed, conn} so the loop returns and the connection closes); otherwise
  # {:cont, conn} to keep streaming.
  #
  # Public (`@doc false`) so the policy is assertable against a real flooded
  # process mailbox without a live Bandit socket — the receive loop is otherwise
  # un-assertable, same testing-seam convention as `format_event/2`,
  # `forward_event?/2` and `redacted_result/4`.
  @doc false
  def backpressure_step(conn, limit) do
    if should_shed?(mailbox_len(), limit) do
      {:shed, shed(conn)}
    else
      {:cont, conn}
    end
  end

  # Pure backpressure decision — extracted so the threshold policy is unit
  # testable in isolation (no socket, no DB). `queue_len` is the current
  # message_queue_len; shed strictly ABOVE the limit so a burst that lands
  # exactly at the limit still streams.
  @doc false
  def should_shed?(queue_len, limit)
      when is_integer(queue_len) and is_integer(limit),
      do: queue_len > limit

  # The final frame emitted before a slow consumer is shed. A distinct event so
  # the client can tell backpressure-close from a network drop and immediately
  # reconnect with Last-Event-ID to re-sync the missed events.
  @doc false
  def overloaded_frame,
    do: "event: overloaded\ndata: {\"type\":\"overloaded\",\"reason\":\"slow_consumer\"}\n\n"

  defp shed(conn) do
    case chunk(conn, overloaded_frame()) do
      {:ok, c} -> c
      _ -> conn
    end
  end

  defp mailbox_len do
    case :erlang.process_info(self(), :message_queue_len) do
      {:message_queue_len, n} -> n
      _ -> 0
    end
  end

  # Backpressure tunables, overridable via `config :barkpark, ListenController`.
  # Defaults: shed a slow reader once >500 events back up; hard-kill a fully
  # stalled connection process at ~80 MB (10M words × 8 B) before it can OOM
  # the node.
  @default_mailbox_limit 500
  @default_max_heap_words 10_000_000

  @doc false
  def sse_mailbox_limit,
    do: env(:mailbox_limit, @default_mailbox_limit)

  defp sse_max_heap_words,
    do: env(:max_heap_words, @default_max_heap_words)

  defp env(key, default),
    do: Application.get_env(:barkpark, __MODULE__, [])[key] || default

  # Live-leg result for a broadcast `msg`, with an admin fast-path that ELIDES
  # the per-event `Content.get_document` round-trip `redacted_result/4` runs.
  #
  # EFFICIENCY (task-4469f80374b0bd24): the broadcast already carries
  # `msg.document = Envelope.render(doc, nil, :internal)` — the UNREDACTED render
  # of the just-committed doc (broadcast.ex), current as of THIS event. For an
  # admin caller both gates `redacted_result/4` exists to enforce are provable
  # no-ops:
  #   * field visibility — `Envelope.render`/`redact` return the envelope
  #     UNCHANGED for `is_admin: true` (envelope.ex), so re-rendering the fetched
  #     doc yields bytes identical to the `:internal` snapshot already in hand
  #     (the base envelope is schema/caller-independent); and
  #   * owner-row ACL — `Content.Scope.scope_to_owner` leaves an admin query
  #     UNTOUCHED (scope.ex), so `get_document` never denies an admin a present
  #     row and the `:drop` leg is unreachable for an admin.
  # So the fetch is pure overhead for admins: N subscribers × M mutations/s stops
  # implying N*M redundant DB round-trips during a burst. Forward `msg.document`.
  #
  # FAIL CLOSED ([[field-visibility-read-paths]]): ONLY `is_admin: true` forwards.
  # EVERY other caller — including a non-admin api_token that bypasses owner
  # scoping but STILL redacts `private`/`owner_only` fields, plus every anonymous
  # / user / nil caller — falls through to `redacted_result/4`'s re-render +
  # re-seal path. When in doubt, re-fetch. This optimizes the LIVE leg only; the
  # REPLAY leg keeps calling `redacted_result/4` directly so it still re-renders
  # the CURRENT document (a privacy/content change since a replayed old event is
  # honoured there, where the snapshot is NOT current-as-of-now).
  #
  # Public (`@doc false`) as a testing seam — the live `receive` loop is
  # otherwise un-assertable, same convention as `redacted_result/4`,
  # `format_event/2` and `forward_event?/2`.
  @doc false
  def live_result(msg, _dataset, %CallerContext{is_admin: true}, _scope), do: msg.document

  def live_result(msg, dataset, caller_context, scope),
    do: redacted_result(msg, dataset, caller_context, scope)

  # The field-visibility + row-ACL chokepoint for the SSE stream. `event` is
  # either a live broadcast `msg` or a stored `%MutationEvent{}` — both carry
  # `doc_id`, `type` and a frozen `document` snapshot. Re-render from the CURRENT
  # document (which also supplies `owner_id` for `owner_only`).
  #
  # A real anonymous SSE subscriber arrives as a `%CallerContext{}` (anonymous),
  # NOT nil — `scope_opts/1` → `CallerContext.from_conn/1` always falls back to
  # `anonymous()`, never nil — and is fail-closed through the `%CallerContext{}`
  # clause below (re-render under the anonymous principal ⇒ public-only). There
  # is NO `nil` clause: a caller-less call has no request-path origin, and the
  # fail-OPEN verbatim-forward it used to do was REMOVED (ctx-s3). The seam now
  # has exactly two shapes — the admin fast-path and the fail-closed re-render.
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
    case Content.Schema.get_schema_for_redaction(type, dataset, scope) do
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
  # Personal Dev Fleet listener presence NEVER rides the SSE fan-out — not even
  # to an unscoped (nil-workspace) subscriber, which the clause below would
  # otherwise forward. A listener heartbeat is per-machine truth, so it must not
  # reach a generic workspace SSE consumer (the live leak, eventId 70357).
  # Mirrors `Sync.Outbox`'s `type != "listener"` exclusion (#5626, PDF-D18).
  # Ordered FIRST so it beats the nil-workspace forward-everything clause.
  def forward_event?(%{type: "listener"}, _workspace_id), do: false

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
