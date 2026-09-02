defmodule BarkparkWeb.ChatController do
  @moduledoc """
  The `/v1/chat` HTTP + SSE transport (charter `bp-chat-tui`, D21-D24) — a strict
  ADAPTER that lets a non-Studio client (`bp chat`) drive the SAME engine the
  LiveView drives: the `StudioChat` store, `Recorder`, and provider Runtime adapter.

  ## Not a second engine, not a launcher API

  Reads subscribe to `Recorder.topic/1`; writes go `Recorder.ensure/1 →
  Recorder.session_pid/1 → Runtime.Adapter lifecycle callbacks.
  The controller NEVER calls `adopt_sink` (D2/D24 — Recorder stays the single
  persisting sink + verbatim rebroadcaster) and NEVER closes Recorder/ClaudeChat
  when the HTTP client disconnects (D24 — viewers do not own runtimes).

  Every session id is minted server-side (`Ecto.UUID.generate/0`) and cwd is
  ALWAYS the selected provider adapter's managed cwd (D22). Executable, argv,
  environment, cwd, session
  id, resume, minter/token, and bypass arming are never request-controlled — a
  body carrying any of them (or an unknown key, a wrong JSON type, an invalid
  enum, an out-of-bounds value) is rejected with the canonical 400 envelope
  BEFORE any store/runtime call.

  ## Authority (D21 + Connectors D18/D19a)

  Every route rides `[:api, :require_chat_access]`, which resolves
  `conn.assigns.chat_scope` (`RequireChatAccess`):

    * `:global` — a global-admin bearer keeps INSTANCE-WIDE authority (D21
      unchanged): it may list/read/control every chat session on the instance.
    * `{:workspace, ws}` — a workspace-bound `chat` Connector is CONFINED to the
      sessions its workspace owns (`owner_workspace_id`). Every fetch runs through
      `fetch_scoped/2` — the sealed store `get_session/2` (charter D17) — before
      any store/runtime work, so a wrong-tenant read joins the not-found oracle
      (`not_found/1`) — indistinguishable from a missing id, NOT a distinct 403 —
      and the SSE `:events` route runs that check BEFORE subscribing to
      `Recorder.topic/1`, so tenant B cannot join tenant A's live stream by
      guessing a UUID.

  Ownership is stamped at create by the store from the scope threaded into
  `create_session/2`. An admin (`:global`) caller keeps instance-wide READ and
  CONTROL authority (D21 unchanged), but the session it CREATES is still stamped
  with an owner — the admin token's bound workspace, falling back to the seeded
  Default Workspace (herd charter D43h: `BlockedSweeper` is fail-closed on NULL
  owners, so a `nil`-owned session can never fire `chat_blocked`). Only a
  pre-tenancy instance with no Default Workspace still creates a `nil`-owned
  (instance-global) session.

  ## Secret safety (D23)

  Ordinary failures go through `BarkparkWeb.ErrorResponse` (canonical, request-id
  bearing, no `inspect` output). The SSE exit frame is EXACTLY `{status, reason}`
  over the fixed public enum `clean | failed_start | crashed | idle_reaped |
  unknown`; the Recorder's internal stderr tail is DROPPED at this serializer and
  is structurally unable to reach the wire (`sse_exit_frame/1` takes only the
  status).

  ## Resume by turn boundary (D5)

  Live SSE deltas are ephemeral (never persisted); persisted message rows carry
  `seq`. On connect with `Last-Event-ID`, rows `seq > Last-Event-ID` replay as
  `event: message`; then the stream goes live (`event: chat` verbatim). There is
  NO shed-and-close backpressure — a pathological stalled connection is bounded
  only by the per-connection `max_heap_size` cap (an emergency node-safety guard,
  NOT a replay promise); the client reconnects and refetches settled Postgres
  truth at the next turn boundary.

  Following the `ListenController` convention, the long-lived SSE `receive` loop
  and `send_chunked/2` are not directly assertable from a test, so the frame
  serializers, the exit-reason mapping, the replay projection, and the
  subscription forwarder are exposed as `@doc false` public seams.
  """

  use BarkparkWeb, :controller

  require Logger

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Render.Components
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Attachments, FleetHub, Recorder, Runtime}
  alias BarkparkWeb.ErrorResponse

  # Wire bounds (charter "Security, validation, and transport verification
  # obligations"). These are the CHAT limits — NOT the endpoint-wide 100 MB
  # parser ceiling. An over-limit value fails with the canonical 400 before any
  # store/runtime call.
  @content_max_bytes 65_536
  @draft_max_bytes 65_536
  @title_max_bytes 256
  @request_id_max_bytes 256
  @since_max 9_223_372_036_854_775_807

  # Emergency per-connection heap cap (charter D24) — defaults to
  # ListenController's node-safety ceiling. NOT a replay promise; the kill only
  # protects the node from a fully-stalled reader's unbounded mailbox.
  @default_max_heap_words 10_000_000

  # Retry-After for the D26 capacity leg: long enough for an admission slot to
  # free up, short enough that a queued mobile send feels live.
  @capacity_retry_after_seconds 15

  # ── POST /v1/chat/sessions ─────────────────────────────────────────────────

  @doc """
  Create a session. Body `{provider?, execution_target?, execution_host_id?,
  mode?, model?, effort?}`; the public id is server-minted and cwd is ALWAYS the
  selected provider adapter's managed cwd (D22). No runtime is spawned here — the
  subprocess comes up on the first send (`Recorder.ensure/1`).
  """
  def create(conn, params) do
    with {:ok, attrs} <- validate_create(params) do
      id = Ecto.UUID.generate()

      # Thread the caller's CREATE scope into the sealed store (charter
      # D17/D18): the store stamps `owner_workspace_id` from the scope — a
      # workspace Connector owns what it creates, and an admin stamps its own
      # workspace via `create_scope/1` (herd D43h — a `nil`-owned session is
      # invisible to `BlockedSweeper` forever). The scope is authoritative in
      # the store, so it is passed as the second arg, NOT smuggled through
      # `attrs` (the store overrides any owner in `attrs`).
      case StudioChat.create_session(
             %{
               id: id,
               provider: attrs.provider,
               execution_target: attrs.execution_target,
               execution_host_id: attrs.execution_host_id,
               cwd: provider_cwd(attrs.provider),
               mode: attrs.mode
             },
             create_scope(conn)
           ) do
        {:ok, _session} ->
          if attrs.model, do: StudioChat.set_model_choice(id, attrs.model)
          if attrs.effort, do: StudioChat.set_effort_choice(id, attrs.effort)

          conn
          |> put_status(:created)
          |> json(full_session_json(StudioChat.get_session(id), []))

        {:error, reason} ->
          # A create_session failure is a store/spawn defect, NOT runtime
          # unavailability — a DISTINCT code (charter D26) so a client never
          # retries a persistent store failure as if it were transient capacity.
          Logger.warning("chat transport: create_session failed: #{inspect(reason)}")

          ErrorResponse.emit_custom(
            conn,
            503,
            "chat_create_failed",
            "could not create chat session"
          )
      end
    else
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ── GET /v1/chat/sessions?archived= ────────────────────────────────────────

  @doc "List sessions in the sidebar shape (`list_sessions/1`); omits draft/choices."
  def index(conn, params) do
    with {:ok, archived?} <- validate_archived(params) do
      # Scope the list AT THE DB (charter D15/D17): a workspace caller narrows to
      # `owner_workspace_id == ^ws` via the partial index, so a tenant's own
      # sessions are never starved out of the `@sidebar_cap` window by other
      # tenants' more-recent sessions (which an after-the-fact in-memory filter
      # would allow). `:global` stays unfiltered (admin sidebar unchanged).
      sessions = StudioChat.list_sessions([archived: archived?], store_scope(scope(conn)))

      json(conn, %{sessions: Enum.map(sessions, &sidebar_json/1)})
    else
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ── GET /v1/chat/rollup ────────────────────────────────────────────────────

  @doc """
  The workspace fleet rollup (herd charter D64h): counts per `agent_state` plus
  ONE precedence state (`blocked > working > idle > unknown`), scoped at the DB
  by the caller's `chat_scope` — `:global` sees the whole herd, a workspace
  connector only its own `owner_workspace_id` rows (fail-closed). Data-only:
  the aggregate twin of the fleet stream, no per-session detail.
  """
  def rollup(conn, _params) do
    json(conn, StudioChat.rollup(scope(conn)))
  end

  # ── GET /v1/chat/sessions/:id ──────────────────────────────────────────────

  @doc """
  The FULL session (continuity set — draft, rail_snapshot, mode, model_choice,
  effort_choice, title, status, metrics — D14) plus `messages` seq-ascending.
  Assistant rows carry `blocks` (`FromMarkdown.blocks/1`, D8) alongside
  `source_markdown`. `?since=<seq>` returns only newer rows (the turn-boundary
  tail refetch).
  """
  def show(conn, %{"id" => id} = params) do
    with {:ok, since} <- validate_since(params),
         %StudioChat.Session{} = session <- fetch_scoped(id, scope(conn)) do
      messages = id |> StudioChat.list_messages() |> filter_since(since)
      json(conn, full_session_json(session, messages))
    else
      nil -> not_found(conn)
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ── PATCH /v1/chat/sessions/:id ────────────────────────────────────────────

  @doc """
  Update the exact allowlisted continuity keys `{draft? | mode? | model_choice? |
  effort_choice? | title?}`. Strict types/enums; `bypassPermissions` is rejected
  (D22). `title` is a trimmed nonblank string ≤256 UTF-8 bytes, persisted through
  `StudioChat.rename/2` (title_source `human`). `archived` is list filtering, not
  a write, so it is not accepted here.
  """
  def update(conn, %{"id" => id} = params) do
    body = Map.drop(params, ["id"])

    # Fetch BEFORE validate: the mode/model/effort validators consult the
    # SESSION's provider capability matrix (a codex session must not accept
    # claude-only values), so the row has to exist first. Deliberate precedence
    # flip: unknown session + bad body is now 404, not 400 — the tenant
    # not-found oracle outranks body shape (pinned in the controller tests).
    with %StudioChat.Session{provider: provider} <- fetch_scoped(id, scope(conn)),
         {:ok, ops} <- validate_patch(body, provider) do
      Enum.each(ops, &apply_patch_op(id, &1))
      json(conn, full_session_json(StudioChat.get_session(id), []))
    else
      nil -> not_found(conn)
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ── POST /v1/chat/sessions/:id/messages ────────────────────────────────────

  @doc """
  Send a user turn. `{content}` → 202 `{accepted:true}`. Brings the runtime up
  (`Recorder.ensure/1`) and dispatches through the single Session process; the
  server does not distinguish queued (the client badges from local turn state,
  D12).
  """
  def create_message(conn, %{"id" => id} = params) do
    body = Map.drop(params, ["id"])

    with {:ok, content} <- validate_content(body),
         %StudioChat.Session{} = session <- fetch_scoped(id, scope(conn)) do
      case ensure_and_send(id, session, content, conn) do
        :ok ->
          # Persist the user's OWN turn (D140). ensure_and_send has already derived
          # `resume?` from the pre-turn `session.message_count` and dispatched, so
          # appending here — AFTER derivation — cannot false-flip turn 1 into a
          # resume. Unlike the Studio LiveView composer (which persists its own
          # `role:"user"` rows), the API path had ZERO append call sites, leaving
          # every channel/bridge session's replay history assistant-only; a real
          # Barkpark Chat session needs the human side too. Fail-soft: the turn is
          # already on its way, so a persist miss must not turn a live send into an
          # error — log and still 202 (the SSE seq-replay simply misses this row).
          persist_user_turn(id, content)
          conn |> put_status(:accepted) |> json(%{accepted: true})

        {:error, reason} ->
          Logger.warning("chat transport: send failed: #{inspect(reason)}")
          send_failure_response(conn, reason)
      end
    else
      nil -> not_found(conn)
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ── POST /v1/chat/sessions/:id/interrupt ───────────────────────────────────

  @doc """
  Interrupt the running turn → 202 `{request_id}`. With no live runtime this is a
  silent no-op (`request_id: null`, D11) — there is no turn to abort, so we never
  spawn one just to interrupt it.
  """
  def interrupt(conn, %{"id" => id}) do
    with %StudioChat.Session{} = stored <- fetch_scoped(id, scope(conn)) do
      request_id =
        with recorder when is_pid(recorder) <- Recorder.whereis(id),
             {:ok, session} <- Recorder.session_pid(recorder),
             {:ok, rid} <- Runtime.interrupt(stored.provider, session) do
          rid
        else
          _ -> nil
        end

      conn |> put_status(:accepted) |> json(%{request_id: request_id})
    else
      nil -> not_found(conn)
    end
  end

  # ── POST /v1/chat/sessions/:id/approval ────────────────────────────────────

  @doc """
  Answer a pending approval → 204. `{request_id, decision:"allow"|"deny"}`. Never
  a caller-supplied `updatedInput` (D22): `allow` echoes the server-held original
  ask, `deny` carries a fixed server message. A no-op (204) when no runtime holds
  the ask.
  """
  def approval(conn, %{"id" => id} = params) do
    body = Map.drop(params, ["id"])

    with {:ok, {request_id, decision}} <- validate_approval(body),
         %StudioChat.Session{} = stored <- fetch_scoped(id, scope(conn)) do
      with recorder when is_pid(recorder) <- Recorder.whereis(id),
           {:ok, session} <- Recorder.session_pid(recorder) do
        # Soft-match the delivery (D31 seal). For the claude provider answer_approval
        # is a GenServer.cast → always :ok, but approval/2 is provider-neutral: codex
        # returns {:error, :unknown_approval} on the double-answer race and
        # {:error, {:app_server_exit, _}} on a dead app-server, and a RemoteRef host
        # can leak its own {:error, _} tail. A non-:ok return means the ask is already
        # gone upstream — that must NOT MatchError → 500 where claude cleanly 204s, so
        # we still flip our own status and 204, mirroring the update_approval_status
        # {:error, :not_found} → :ok idempotency just below.
        _ = Runtime.answer_approval(stored.provider, session, request_id, decision)

        status =
          case decision do
            :allow -> "allowed"
            {:deny, _message} -> "denied"
          end

        case StudioChat.update_approval_status(id, request_id, status) do
          {:ok, _message} -> :ok
          {:error, :not_found} -> :ok
        end
      end

      send_resp(conn, :no_content, "")
    else
      nil -> not_found(conn)
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ── POST /v1/chat/sessions/:id/{archive,unarchive} ─────────────────────────

  @doc """
  Archive a session (charter D28) — stamp `archived_at` so it leaves the active
  sidebar for the archived shelf. 200 `{session}`, idempotent (re-archiving
  re-stamps the timestamp). The store call rides `store_scope(scope(conn))`
  (NEVER `:global` — the LiveView's hardcoded scope is not precedent), so a
  foreign tenant's session joins the not-found oracle (`:noop` → 404),
  indistinguishable from a missing id. Orthogonal to `status`: archiving never
  touches liveness. NO fleet frame is emitted (D28 — no broadcast path exists):
  clients remove optimistically on the 200 and reconcile on the next list poll.
  """
  def archive(conn, %{"id" => id}) do
    respond_archived(conn, StudioChat.archive_session(id, store_scope(scope(conn))))
  end

  @doc "Unarchive (charter D28) — clear `archived_at`. Same oracle + idempotency."
  def unarchive(conn, %{"id" => id}) do
    respond_archived(conn, StudioChat.unarchive_session(id, store_scope(scope(conn))))
  end

  defp respond_archived(conn, result) do
    case result do
      {:ok, %StudioChat.Session{} = session} ->
        json(conn, full_session_json(session, []))

      :noop ->
        not_found(conn)

      {:error, reason} ->
        # `archived_at` is a bare change with no constraints, so this branch is
        # defensively unreachable — but a store surprise must be a logged 500,
        # never a CaseClauseError.
        Logger.warning("chat transport: archive flip failed: #{inspect(reason)}")
        ErrorResponse.emit(conn, {:error, :archive_failed}, "could not update archived state")
    end
  end

  # ── GET /v1/chat/sessions/:id/events ───────────────────────────────────────

  @doc """
  SSE stream (charter wire "SSE frames"). Replay `seq > Last-Event-ID` as
  `event: message`, then live `event: chat` (raw claude stream-json verbatim, no
  id) / `event: permission` / `event: exit` (public status+reason only), with a
  `: keepalive` comment every 30s. NEVER shed-and-close (D5); NO per-event
  redaction (admin-only route). The `AcceptBarkparkVendor` plug on the `:api`
  pipeline rewrites a `text/event-stream` Accept so `:accepts ["json"]` admits it
  (D6). The subscription forwarder is linked; `try/after` stops it and the
  request-process death takes the link with it — Recorder/ClaudeChat stay alive
  (D24).
  """
  def events(conn, %{"id" => id}) do
    # Bound THIS connection process (charter D24): a fully-stalled reader can grow
    # the forwarded mailbox without any Elixir code running to self-check, so cap
    # the heap and kill this ONE process before it can OOM the node. Emergency
    # guard, not a replay promise.
    Process.flag(:max_heap_size, %{size: sse_max_heap_words(), kill: true, error_logger: true})

    # SCOPE THE SESSION BEFORE SUBSCRIBING (Connectors D18/D19a): a wrong-tenant
    # (or missing) id 404s here, so tenant B can never join tenant A's live
    # `Recorder.topic/1` stream by guessing a UUID.
    case fetch_scoped(id, scope(conn)) do
      nil ->
        not_found(conn)

      _session ->
        since = last_event_id(conn)
        forwarder = start_forwarder(Recorder.topic(id), self())

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        conn = replay(conn, id, since)
        conn = stable_snapshot(conn, id)

        try do
          stream_loop(conn)
        after
          # Ownership cleanup (D24): stop the helper. The forwarder is ALSO linked,
          # so an abnormal request-process death kills it too — Recorder/ClaudeChat
          # are never touched (no adopt_sink, no close).
          send(forwarder, :stop)
        end
    end
  end

  # ── GET /v1/chat/events (the herd fleet stream) ────────────────────────────

  @doc """
  The herd fleet SSE stream (charter D44h/D45h): snapshot-then-live STATE frames
  for the WHOLE in-scope herd on ONE connection — a client watching N sessions
  holds one stream, not N. Every frame is `{session_id, agent_state, ts, title}`
  — never message content, never `owner_workspace_id` (`FleetHub` strips the
  stamp before it can reach the wire).

  On connect: an `event: snapshot` frame carries the current scoped fleet
  (`StudioChat.fleet_snapshot/1` — seam 1), tagged `id: <epoch>:<seq>`; then live
  `event: state` flips (`id: <epoch>:<seq>`, replayable) plus id-less
  `event: heartbeat` liveness ticks and `event: title` title updates (charter
  D69h — both unreplayable, never a ring slot or seq).
  `Last-Event-ID` is the opaque `epoch:seq` cursor: an in-ring cursor replays
  EXACTLY the missed flips; a wrong epoch or out-of-ring cursor degrades to a
  fresh scoped snapshot. `: keepalive` every 30s; the D5/D24 never-shed law holds
  — `max_heap_size` is the only valve. Scope is fail-closed at three seams (the
  snapshot query, the live-flip filter, the ring replay) sharing the
  `StudioChat.scope_match?/2` predicate against `conn.assigns.chat_scope`.
  """
  def fleet_events(conn, _params) do
    # Emergency per-connection heap cap (charter D24) — the same node-safety guard
    # the per-session stream uses; a stalled reader can never OOM the node.
    Process.flag(:max_heap_size, %{size: sse_max_heap_words(), kill: true, error_logger: true})

    scope = store_scope(scope(conn))
    cursor = fleet_last_event_id(conn)

    # Subscribe to the fleet topic BEFORE the handshake so no flip that lands
    # between the handshake and the live loop is lost; the loop then drops any
    # frame with `seq <= boundary` (already reflected in the snapshot/replay), so
    # the handoff is gap-free by convergence with no duplicate state.
    forwarder = start_forwarder(FleetHub.fleet_topic(), self())
    {mode, epoch, boundary, entries} = FleetHub.handshake(cursor, scope)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    conn = emit_fleet_open(conn, mode, epoch, boundary, entries, scope)

    try do
      fleet_stream_loop(conn, scope, epoch, boundary)
    after
      send(forwarder, :stop)
    end
  end

  # Emit the connect payload: a fresh scoped snapshot (seam 1) OR the exact scoped
  # ring replay (seam 3), depending on the handshake decision.
  defp emit_fleet_open(conn, :snapshot, epoch, boundary, _entries, scope) do
    chunk_fleet(conn, fleet_snapshot_frame(StudioChat.fleet_snapshot(scope), epoch, boundary))
  end

  defp emit_fleet_open(conn, :replay, epoch, _boundary, entries, _scope) do
    Enum.reduce(entries, conn, fn entry, c -> chunk_fleet(c, fleet_state_frame(entry, epoch)) end)
  end

  defp chunk_fleet(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  @doc false
  # The live fleet receive loop. Seam 2 (live flip) + heartbeat + title all
  # scope-filter through `StudioChat.scope_match?/2`; flips already covered by the connect
  # payload (`seq <= boundary`) are dropped. NEVER shed-and-close (D5/D24).
  def fleet_stream_loop(conn, scope, epoch, boundary) do
    receive do
      {:fleet_flip, %{seq: seq, owner_ws: owner_ws} = entry} ->
        if seq > boundary and StudioChat.scope_match?(owner_ws, scope) do
          fleet_chunk_or_stop(conn, fleet_state_frame(entry, epoch), scope, epoch, boundary)
        else
          fleet_stream_loop(conn, scope, epoch, boundary)
        end

      {:fleet_heartbeat, sid, ts, owner_ws} ->
        if StudioChat.scope_match?(owner_ws, scope) do
          fleet_chunk_or_stop(conn, fleet_heartbeat_frame(sid, ts), scope, epoch, boundary)
        else
          fleet_stream_loop(conn, scope, epoch, boundary)
        end

      {:fleet_title, sid, title, owner_ws} ->
        if StudioChat.scope_match?(owner_ws, scope) do
          fleet_chunk_or_stop(conn, fleet_title_frame(sid, title), scope, epoch, boundary)
        else
          fleet_stream_loop(conn, scope, epoch, boundary)
        end

      _other ->
        fleet_stream_loop(conn, scope, epoch, boundary)
    after
      30_000 ->
        fleet_chunk_or_stop(conn, sse_keepalive(), scope, epoch, boundary)
    end
  end

  defp fleet_chunk_or_stop(conn, data, scope, epoch, boundary) do
    case chunk(conn, data) do
      {:ok, conn} -> fleet_stream_loop(conn, scope, epoch, boundary)
      {:error, _} -> conn
    end
  end

  @doc false
  # The connect snapshot frame (D45h): the whole scoped fleet as one
  # `event: snapshot`, tagged `id: <epoch>:<seq>` so a reconnect that saw ONLY the
  # snapshot still carries a valid cursor. Each session is the herd-wire tuple —
  # no content, no owner id.
  def fleet_snapshot_frame(sessions, epoch, seq) do
    "id: #{epoch}:#{seq}\nevent: snapshot\ndata: #{Jason.encode!(%{sessions: Enum.map(sessions, &fleet_session_json/1)})}\n\n"
  end

  @doc false
  # A live flip (seam 2) or a replayed ring flip (seam 3): `id: <epoch>:<seq>`
  # makes it Last-Event-ID resumable. `title` is `null` on a live flip (the
  # activity carries none and D43h forbids a per-flip DB lookup); the consumer
  # keeps the title it holds from the snapshot.
  def fleet_state_frame(%{seq: seq, session_id: sid, agent_state: agent_state, ts: ts}, epoch) do
    payload = %{session_id: sid, agent_state: agent_state, ts: ts, title: nil}
    "id: #{epoch}:#{seq}\nevent: state\ndata: #{Jason.encode!(payload)}\n\n"
  end

  @doc false
  # A heartbeat liveness tick (D45h): id-less and seq-less — UNREPLAYABLE, exactly
  # like the runtime/permission/exit deltas on the per-session wire. Carries only
  # the session id + the liveness stamp, never state or content.
  def fleet_heartbeat_frame(sid, ts) do
    "event: heartbeat\ndata: #{Jason.encode!(%{session_id: sid, ts: ts})}\n\n"
  end

  @doc false
  # A title update (charter D69h): id-less and seq-less — UNREPLAYABLE,
  # heartbeat-shaped. The async AI title lands once per session; a reconnecting
  # client gets the fresh title from its next snapshot query for free, so the
  # frame never claims a ring slot or a cursor position. Carries only the
  # session id + the title, never state, content, or the owner stamp.
  def fleet_title_frame(sid, title) do
    "event: title\ndata: #{Jason.encode!(%{session_id: sid, title: title})}\n\n"
  end

  defp fleet_session_json(%{session_id: sid, agent_state: agent_state, ts: ts, title: title}) do
    %{session_id: sid, agent_state: agent_state, ts: ts, title: title}
  end

  # Read + parse the opaque `epoch:seq` Last-Event-ID (D45h) via FleetHub's lenient
  # 2-part parser; `nil` (absent or malformed) means a fresh snapshot.
  defp fleet_last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [value | _] -> FleetHub.parse_cursor(value)
      _ -> nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # SSE seams (public @doc false — the live receive loop is otherwise
  # un-assertable, same convention as ListenController.format_event/2)
  # ─────────────────────────────────────────────────────────────────────────

  @doc false
  # Subscribe to `topic` in a NONBLOCKING helper (the connection process blocks
  # in chunk/2, so it must never be the direct PubSub subscriber — the same scar
  # ListenController guards). NO shed cap (D5): the helper forwards every frame;
  # the connection's max_heap_size is the only backstop. `spawn_link` so a
  # request-process death takes the helper (and its subscription) with it.
  def start_forwarder(topic, listener) do
    caller = self()

    pid =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        send(caller, {:chat_forwarder_ready, self()})
        forward_loop(listener)
      end)

    receive do
      {:chat_forwarder_ready, ^pid} -> pid
    end
  end

  defp forward_loop(listener) do
    receive do
      :stop ->
        :ok

      msg ->
        send(listener, msg)
        forward_loop(listener)
    end
  end

  # The live receive loop. Recorder rebroadcasts the Session's sink tuples
  # verbatim on the topic; we serialize the charter's frame set and IGNORE
  # everything else (control acks, command lists — the client re-syncs settled
  # truth at the turn boundary). NEVER shed-and-close.
  defp stream_loop(conn) do
    receive do
      {:claude_chat_event, frame} ->
        chunk_or_stop(conn, sse_chat_frame(frame))

      {:studio_chat_runtime_event, %Runtime.Event{} = event} ->
        chunk_or_stop(conn, sse_runtime_frame(event))

      {:chat_stable, frame} ->
        # DELIBERATELY STATELESS (mobile charter D63): a pass-through, never an
        # accumulator. Threading segment state through stream_loop/chunk_or_stop
        # would give every viewer its OWN byte offsets, which breaks the
        # from-based cursor for exactly the reconnect case mobile hits most —
        # and would duplicate the computation N times over.
        chunk_or_stop(conn, sse_stable_frame(frame))

      {:claude_chat_permission, ask} ->
        chunk_or_stop(conn, sse_permission_frame(ask))

      {:chat_workflow, _sid, summary} ->
        # Live workflow delta (wsc-bl-workflow-sse, D22): the Recorder's SECOND
        # broadcast lands here on the per-session topic. The sid is embedded in the
        # topic the forwarder subscribed to, so it is authoritative — this clause
        # ignores the tuple's sid and forwards the compact summary as its own
        # change-only frame, removing the D13 mid-turn strip lag.
        chunk_or_stop(conn, sse_workflow_frame(summary))

      {:chat_title, sid, title} when is_binary(title) ->
        # The AI title landed (ct-bl-recorder-titles). `Recorder.broadcast_title/2`
        # publishes it on the per-session topic precisely so this stream can push
        # it: before, only the LiveView learned of a title and `bp chat` had to
        # re-GET the session at every turn boundary to notice one (charter D15).
        chunk_or_stop(conn, sse_title_frame(sid, title))

      {:chat_task_transition, _sid, transition} ->
        # A live ledger transition (tlv-bl-chat-live-transition-stream): the
        # Recorder's scoped re-broadcast on the per-session topic. The sid is
        # embedded in the topic the forwarder subscribed to, so it is
        # authoritative — this clause ignores the tuple's sid, exactly like the
        # workflow clause above. Secret-safe by construction (D23): the payload
        # is a fixed set of ledger fields the Recorder built, never an inspect
        # or a raw document.
        chunk_or_stop(conn, sse_task_frame(transition))

      {:claude_chat_exit, status, _internal_tail} ->
        # DROP the internal tail (D23): sse_exit_frame/1 takes only the status,
        # so no stderr/path/token can reach the wire. The stream stays open — a
        # session can lazy-resume on the next send; viewers do not own runtimes.
        chunk_or_stop(conn, sse_exit_frame(status))

      _other ->
        stream_loop(conn)
    after
      30_000 ->
        chunk_or_stop(conn, sse_keepalive())
    end
  end

  defp chunk_or_stop(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> stream_loop(conn)
      # Chunk error (client gone) terminates the stream — the try/after stops the
      # forwarder; Recorder/ClaudeChat are untouched.
      {:error, _} -> conn
    end
  end

  # The connect-time catch-up for a turn ALREADY in flight (D63). Sent after the
  # persisted replay so a fresh client's cursor is 0 when it lands, and after the
  # forwarder is subscribed so no frame is lost behind it.
  #
  # HONEST FAILURE MODE, stated because it is real: subscribing before snapshotting
  # leaves a window in which a segment can be BOTH forwarded live and included in
  # the snapshot. Its width is NOT sub-millisecond as first written — this is a
  # `GenServer.call` into a process that may be mid-persist, so it is bounded by
  # `stable_snapshot_timeout_ms` (250 ms default), and a Recorder parsing a full
  # turn at the byte cap can genuinely hold it that long. The duplicate reads as `from < cursor`, which is
  # a GAP by the D59 rule, so the client keeps what it committed and renders the
  # remainder plain for that turn — today's floor. Closing it outright needs the
  # subscribe and the snapshot to be one atomic operation, which PubSub cannot
  # offer; snapshot-then-subscribe only moves the same window to a LOST frame with
  # the identical outcome. At the measured 2.11 frames/s this is ~0.1 % of
  # mid-turn attaches, and it degrades rather than corrupting.
  defp stable_snapshot(conn, id) do
    case Recorder.stable_snapshot(id) do
      nil ->
        conn

      frame ->
        case chunk(conn, sse_stable_frame(frame)) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
    end
  end

  # Replay the persisted rows `seq > since` as `event: message` frames (D5).
  defp replay(conn, _id, nil), do: conn

  defp replay(conn, id, since) do
    Enum.reduce(replay_events(id, since), conn, fn frame, c ->
      case chunk(c, frame) do
        {:ok, c2} -> c2
        {:error, _} -> c
      end
    end)
  end

  @doc false
  # The replay projection (D5) — persisted rows `seq > since` as SSE
  # `event: message` frame strings, seq-ascending. A public seam so the
  # resume contract is assertable without a live socket.
  def replay_events(id, since) do
    id
    |> StudioChat.list_messages()
    |> filter_since(since)
    |> Enum.map(&sse_message_frame/1)
  end

  @doc false
  # Replay row frame: `id: <seq>` makes it Last-Event-ID resumable.
  def sse_message_frame(%StudioChat.Message{} = m) do
    "id: #{m.seq}\nevent: message\ndata: #{Jason.encode!(message_json(m))}\n\n"
  end

  @doc false
  # Live delta: the raw claude stream-json frame, re-encoded verbatim, NO id
  # (deltas are unreplayable by design, D5).
  def sse_chat_frame(frame), do: "event: chat\ndata: #{Jason.encode!(frame)}\n\n"

  @doc false
  def sse_runtime_frame(%Runtime.Event{} = event) do
    "event: runtime\ndata: #{event |> Map.from_struct() |> Jason.encode!()}\n\n"
  end

  @doc false
  # The live-document frames (mobile charter D59). ID-LESS, both of them: Go and
  # mobile each advance the resume cursor for ANY id-carrying frame BEFORE
  # dispatch, so an `id:` here would strand the next reconnect on a seq that
  # never existed. The payload is JSON and never raw markdown — Go TrimSpaces
  # every data line while mobile strips exactly one leading space, so raw text
  # would arrive different per surface.
  def sse_stable_frame({:stable, payload}),
    do: "event: stable\ndata: #{Jason.encode!(payload)}\n\n"

  def sse_stable_frame({:stable_end, payload}),
    do: "event: stable_end\ndata: #{Jason.encode!(payload)}\n\n"

  @doc false
  def sse_permission_frame(ask), do: "event: permission\ndata: #{Jason.encode!(ask)}\n\n"

  @doc false
  # The public exit frame (D23) — EXACTLY status + reason; the internal tail is
  # not a parameter, so it is structurally unable to leak here.
  def sse_exit_frame(status), do: "event: exit\ndata: #{Jason.encode!(exit_payload(status))}\n\n"

  @doc false
  # The live workflow frame (wsc-bl-workflow-sse, D23): the COMPACT
  # workflow_summary map (StudioChat.workflow_summary/1), encoded byte-identical
  # to the list wire (ONE parser on the Go side). WORKFLOW-ONLY — no epic sibling
  # — and UNREPLAYABLE: NO `id:` seq, exactly like the runtime/permission/exit
  # deltas (D5); a resuming client re-reads settled workflow truth off the
  # turn-boundary rail, never off a replayed workflow frame.
  def sse_workflow_frame(summary),
    do: "event: workflow\ndata: #{Jason.encode!(summary)}\n\n"

  @doc false
  # The live title frame (ct-bl-recorder-titles). D23 minimalism, enforced by the
  # SIGNATURE: two scalars in, `{session_id, title}` out — the session record, its
  # cwd, its provider argv and the stderr tail are not parameters here, so none of
  # them can leak into this frame however the caller changes. The title itself is
  # the store's settled value (the clobber guard ran before the broadcast).
  #
  # `session_id` is redundant on a per-session stream — the forwarder subscribes
  # to `Recorder.topic/1` and nothing else (D24), so the id is authoritative by
  # construction, never a filter the client must apply. It rides the wire anyway
  # for the multiplexing consumers (the fleet stream, logs) that see many
  # sessions' frames in one place.
  #
  # UNREPLAYABLE: NO `id:` seq, like every other live delta (D5). A reconnecting
  # client does not want a replayed title — it re-reads the persisted current
  # title from `GET /v1/chat/sessions/:id`, which is settled truth and cannot be
  # stale the way a replayed frame can.
  def sse_title_frame(session_id, title),
    do: "event: title\ndata: #{Jason.encode!(%{session_id: session_id, title: title})}\n\n"

  @doc false
  # The live task-transition frame (tlv-bl-chat-live-transition-stream). ID-LESS
  # and UNREPLAYABLE, exactly like `workflow`/`title`/`runtime`/`permission`
  # (D5): a resuming client re-reads settled ledger truth, never a replayed
  # transition. The payload carries its OWN `event_id` — the mutation_events row
  # id — so the reducer dedupes a duplicate live delivery without that id ever
  # becoming an SSE `Last-Event-ID` cursor for this stream.
  def sse_task_frame(transition),
    do: "event: task\ndata: #{Jason.encode!(transition)}\n\n"

  @doc false
  # The fixed public exit contract (D23): the reason enum, plus the numeric
  # subprocess status ONLY when it is an integer (null otherwise).
  def exit_payload(status) do
    %{status: numeric_status(status), reason: exit_reason(status)}
  end

  @doc false
  def sse_keepalive, do: ": keepalive\n\n"

  # Numeric subprocess status only when it actually IS an integer (D23).
  defp numeric_status(status) when is_integer(status), do: status
  defp numeric_status(_), do: nil

  # Map the Recorder's exit signal to the fixed public reason enum. A clean exit
  # is 0; a nonzero subprocess status or a GenServer crash is `crashed`; the
  # frame-silence reaper is `idle_reaped`; a spawn failure is `failed_start`;
  # anything unrecognized is `unknown`. NEVER a raw reason string (D23).
  defp exit_reason(0), do: "clean"
  defp exit_reason(status) when is_integer(status), do: "crashed"
  defp exit_reason(:crashed), do: "crashed"
  defp exit_reason(:idle_reaped), do: "idle_reaped"
  defp exit_reason(:failed_start), do: "failed_start"
  defp exit_reason(:binary_not_found), do: "failed_start"
  defp exit_reason(_), do: "unknown"

  @doc false
  # Emergency per-connection heap cap in words (charter D24). Config-overridable
  # via `config :barkpark, __MODULE__, max_heap_words: N`.
  def sse_max_heap_words do
    Application.get_env(:barkpark, __MODULE__, [])[:max_heap_words] || @default_max_heap_words
  end

  # ─────────────────────────────────────────────────────────────────────────
  # tenant scoping (Connectors D18/D19a)
  #
  # `RequireChatAccess` puts `:global` or `{:workspace, ws}` on the conn; every
  # id-bearing route fetches through `fetch_scoped/2` so a wrong-tenant read
  # returns the SAME not-found oracle as a missing id. `owner_workspace_id` is
  # read with `Map.get/2` (never `session.owner_workspace_id`) so this is total
  # and forward-compatible: it is `nil` until the tenant-seam column lands, at
  # which point a workspace caller resolves to its own owned rows automatically.
  # ─────────────────────────────────────────────────────────────────────────

  defp scope(conn), do: conn.assigns.chat_scope

  # The scope that STAMPS `owner_workspace_id` at create (herd charter D43h).
  # READ/CONTROL authority stays exactly `chat_scope/1` (`:global` admins keep
  # instance-wide reach, D21) — but `BlockedSweeper` is fail-closed on NULL
  # owners, so a `nil`-owned session can NEVER fire `chat_blocked`. A workspace
  # Connector stamps its own workspace (unchanged); an admin stamps the
  # workspace its token is bound to, falling back to the seeded Default
  # Workspace. Only a pre-tenancy instance with NO Default Workspace still
  # yields `:global` (a `nil`-owned instance-global session — honest: there is
  # no tenant to own it).
  defp create_scope(conn) do
    case scope(conn) do
      {:workspace, _ws} = scoped -> scoped
      :global -> admin_owner_scope(conn)
    end
  end

  defp admin_owner_scope(conn) do
    token_ws =
      case conn.assigns[:api_token] do
        %{workspace_id: ws} when is_binary(ws) -> ws
        _ -> nil
      end

    case token_ws || default_workspace_id() do
      nil -> :global
      ws -> {:workspace, ws}
    end
  end

  defp default_workspace_id do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: id} -> id
      nil -> nil
    end
  end

  # Map the controller's `chat_scope` onto the store funnel's `scope` arg
  # (`:global | workspace_id binary`, charter D17): `{:workspace, ws}` → `ws`.
  defp store_scope(:global), do: :global
  defp store_scope({:workspace, ws}), do: ws

  # Fetch a session and confine it to the caller's scope — `nil` (⇒ 404) when the
  # session does not exist OR is owned by another tenant. Reads through the
  # sealed store scope (charter D17) so a foreign/`:global` session is invisible
  # at the DB — the store is the single enforcement point, the controller only
  # threads the scope.
  defp fetch_scoped(id, scope), do: StudioChat.get_session(id, store_scope(scope))

  # ─────────────────────────────────────────────────────────────────────────
  # writes: strict Recorder/ClaudeChat adapter
  # ─────────────────────────────────────────────────────────────────────────

  defp ensure_and_send(id, session, content, conn) do
    # First send is a fresh `--session-id` pin; a session that already has rows
    # lazy-`--resume`s (a reap may have closed the runtime). The `resume` flag is
    # inert when a runtime is already live (Recorder.ensure is idempotent).
    resume? = (session.message_count || 0) > 0

    with {:ok, recorder} <-
           Recorder.ensure(%{
             session_id: id,
             provider: session.provider,
             provider_session_id: session.provider_session_id,
             execution_target: session.execution_target,
             execution_host_id: session.execution_host_id,
             workspace_id: session.owner_workspace_id,
             cwd: session.cwd,
             mode: session.mode || "plan",
             resume: resume?,
             model: Runtime.normalize_choice(session.provider, :models, session.model_choice),
             effort: Runtime.normalize_choice(session.provider, :efforts, session.effort_choice),
             # The admin principal (charter D63): the Session mints its loopback
             # bp-mcp credential from this — never exceeding the caller's rights;
             # fail-soft if absent.
             minter: conn.assigns[:api_token],
             # NEVER remotely armed (D22): the dangerous bypass ceremony is not
             # representable over the transport.
             bypass_armed: false
           }),
         {:ok, session_pid} when not is_nil(session_pid) <- Recorder.session_pid(recorder) do
      Runtime.send_turn(session.provider, session_pid, content)
    else
      # `Recorder.session_pid/1` has NO failure branch — a Recorder whose
      # provider runtime never came up (or already exited) replies `{:ok, nil}`.
      # That nil used to flow into the adapter's `is_pid`-guarded send and raise
      # FunctionClauseError → 500, BYPASSING the D26 reason split entirely; map
      # it to the transient runtime_unavailable leg instead.
      {:ok, nil} -> {:error, :runtime_session_missing}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc false
  # The D26 send-failure reason split: classify the Recorder/Runtime failure
  # term over an explicit ALLOWLIST, then answer with the fixed public code.
  # NEVER interpolate the reason into the wire message — `safe_command`'s rescue
  # leg returns raw exception structs, and echoing one is an information leak
  # (the server-side Logger line above already carries the full term). Public
  # (`@doc false`) so every allowlist leg is assertable without arranging the
  # matching runtime failure live — the exit-reason-mapping seam convention.
  def send_failure_response(conn, reason) do
    case classify_send_failure(reason) do
      :capacity ->
        # Transient by definition — say when to come back (mirrors the
        # rate-limit plugs' Retry-After convention).
        conn
        |> put_resp_header("retry-after", Integer.to_string(@capacity_retry_after_seconds))
        |> ErrorResponse.emit_custom(
          503,
          "runtime_capacity",
          "chat runtime capacity is exhausted — retry shortly"
        )

      :unavailable ->
        ErrorResponse.emit_custom(conn, 503, "runtime_unavailable", "chat runtime is unavailable")

      :unsupported ->
        # PERMANENT for this session/provider — a 503 would make a well-behaved
        # client retry forever, so it must be a 4xx (charter D26).
        ErrorResponse.emit_custom(
          conn,
          422,
          "chat_unsupported",
          "chat is not supported for this session's provider or operation"
        )
    end
  end

  # Capacity: admission refused the spawn — the runtime pool is full or two
  # spawns raced the registration; both clear on their own.
  defp classify_send_failure({:managed_runtime_capacity, _}), do: :capacity
  defp classify_send_failure(:admission_registration_conflict), do: :capacity

  # Unavailable: the runtime is not there right now (dead GenServer, closed or
  # absent port, dead app-server, the {:ok, nil} guard above) — retryable.
  defp classify_send_failure({:not_running, _}), do: :unavailable
  defp classify_send_failure(:port_closed), do: :unavailable
  defp classify_send_failure(:no_port), do: :unavailable
  defp classify_send_failure({:app_server_exit, _}), do: :unavailable
  defp classify_send_failure(:runtime_session_missing), do: :unavailable

  # Unsupported: the provider/operation combination can never succeed as asked.
  defp classify_send_failure({:provider_not_ready, _}), do: :unsupported
  defp classify_send_failure({:provider_protocol_incompatible, _}), do: :unsupported
  defp classify_send_failure({:unsupported_runtime_operation, _}), do: :unsupported
  defp classify_send_failure({:missing_runtime_contract, _}), do: :unsupported

  # Opaque fallback: any term outside the allowlist stays a generic transient
  # 503 — unknown ≠ permanent, and the term itself never reaches the wire.
  defp classify_send_failure(_), do: :unavailable

  # Append the caller's turn as an organic `role:"user"` row so the Session's
  # replayable history carries the human side (the LiveView composer persists its
  # own rows; the API path did not). `origin: "api"` distinguishes it from a
  # composer-authored row. Best-effort — the caller already got its turn
  # dispatched, so a persist error is logged, never surfaced.
  defp persist_user_turn(id, content) do
    case StudioChat.append_message(id, %{
           role: "user",
           source_markdown: content,
           metadata: %{"origin" => "api"}
         }) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        Logger.warning("chat transport: failed to persist user turn: #{inspect(reason)}")
        :ok
    end
  end

  defp apply_patch_op(id, {:draft, value}), do: StudioChat.set_draft(id, value)

  # A mode PATCH also steers a LIVE runtime (best-effort) so a TUI-side toggle
  # takes effect mid-session, not just on the next spawn. `req_mode` already
  # fail-closed the value (D22 — bypassPermissions never arrives here); if the
  # steer is lost, the Recorder's init-frame observation self-heals. Steer only
  # on an actual CHANGE (the TUI's leave-PATCH echoes the current mode every
  # exit); a dead or absent Recorder is the routine offline case — persist only.
  defp apply_patch_op(id, {:mode, value}) do
    prior = StudioChat.get_session(id)
    StudioChat.set_mode(id, value)

    with %StudioChat.Session{mode: mode, provider: provider} when mode != value <- prior,
         recorder when is_pid(recorder) <- Recorder.whereis(id),
         {:ok, session} when is_pid(session) <- Recorder.session_pid(recorder) do
      Runtime.steer(provider, session, %{mode: value})
    else
      _ -> :ok
    end
  end

  # model_choice/effort_choice steer a LIVE runtime exactly like the mode block
  # above (steer parity, charter t3code D26 sibling ruling): prior-read → set →
  # change-guard (steer only on an actual CHANGE — the TUI leave-PATCH echoes
  # current values) → Recorder.whereis → Runtime.steer, fail-soft on a dead or
  # absent Recorder. An adapter that cannot steer the axis (claude has no effort
  # steer) returns {:error, {:unsupported_steer, _}}, which is ignored — the
  # persisted choice still lands and takes effect on the next spawn.
  defp apply_patch_op(id, {:model_choice, value}) do
    prior = StudioChat.get_session(id)
    StudioChat.set_model_choice(id, value)

    with %StudioChat.Session{model_choice: choice, provider: provider} when choice != value <-
           prior,
         recorder when is_pid(recorder) <- Recorder.whereis(id),
         {:ok, session} when is_pid(session) <- Recorder.session_pid(recorder) do
      Runtime.steer(provider, session, %{model: value})
    else
      _ -> :ok
    end
  end

  defp apply_patch_op(id, {:effort_choice, value}) do
    prior = StudioChat.get_session(id)
    StudioChat.set_effort_choice(id, value)

    with %StudioChat.Session{effort_choice: choice, provider: provider} when choice != value <-
           prior,
         recorder when is_pid(recorder) <- Recorder.whereis(id),
         {:ok, session} when is_pid(session) <- Recorder.session_pid(recorder) do
      Runtime.steer(provider, session, %{effort: value})
    else
      _ -> :ok
    end
  end

  defp apply_patch_op(id, {:title, value}), do: StudioChat.rename(id, value)

  # ─────────────────────────────────────────────────────────────────────────
  # validation (fail BEFORE any store/runtime call — obligations D + E)
  # ─────────────────────────────────────────────────────────────────────────

  @create_keys ~w(provider execution_target execution_host_id mode model effort)
  defp validate_create(params) do
    with :ok <- reject_non_object(params),
         :ok <- reject_unknown_keys(params, @create_keys),
         {:ok, provider} <-
           opt_enum(params, "provider", StudioChat.Session.providers(), "claude"),
         {:ok, target} <-
           opt_enum(params, "execution_target", StudioChat.Session.execution_targets(), "managed"),
         {:ok, host_id} <- opt_uuid(params, "execution_host_id"),
         :ok <- validate_execution_identity(target, host_id),
         capabilities = Runtime.capabilities(provider),
         {:ok, mode} <-
           opt_capability(params, "mode", capabilities.modes -- ["bypassPermissions"]),
         {:ok, model} <- opt_capability(params, "model", capabilities.models),
         {:ok, effort} <- opt_capability(params, "effort", capabilities.efforts) do
      # `plan` is the product default (charter — read-only, no approval UI),
      # pinned explicitly so an allowlist reordering never changes it silently.
      default_mode =
        if provider == "claude", do: "plan", else: List.first(capabilities.modes) || "default"

      {:ok,
       %{
         provider: provider,
         execution_target: target,
         execution_host_id: host_id,
         mode: mode || default_mode,
         model: model,
         effort: effort
       }}
    end
  end

  defp opt_enum(params, key, allowed, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, "invalid #{key}"}

      _ ->
        {:error, "invalid #{key}"}
    end
  end

  defp opt_uuid(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if match?({:ok, _}, Ecto.UUID.cast(value)),
          do: {:ok, value},
          else: {:error, "invalid #{key}"}

      _ ->
        {:error, "#{key} must be a UUID"}
    end
  end

  defp validate_execution_identity("managed", nil), do: :ok
  defp validate_execution_identity("registered_host", host) when is_binary(host), do: :ok

  defp validate_execution_identity("managed", _),
    do: {:error, "execution_host_id must be empty for managed execution"}

  defp validate_execution_identity("registered_host", nil),
    do: {:error, "execution_host_id is required for registered_host execution"}

  defp opt_capability(params, key, allowed) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, "invalid #{key}"}

      _ ->
        {:error, "invalid #{key}"}
    end
  end

  defp provider_cwd(provider), do: Runtime.cwd(provider)

  @patch_keys ~w(draft mode model_choice effort_choice title)
  defp validate_patch(params, provider) do
    with :ok <- reject_non_object(params),
         :ok <- reject_unknown_keys(params, @patch_keys) do
      collect_patch_ops(params, @patch_keys, provider, [])
    end
  end

  defp collect_patch_ops(_params, [], _provider, ops), do: {:ok, Enum.reverse(ops)}

  defp collect_patch_ops(params, [key | rest], provider, ops) do
    if Map.has_key?(params, key) do
      case patch_op(key, Map.get(params, key), provider) do
        {:ok, op} -> collect_patch_ops(params, rest, provider, [op | ops])
        {:error, _} = err -> err
      end
    else
      collect_patch_ops(params, rest, provider, ops)
    end
  end

  defp patch_op("draft", value, _provider) do
    cond do
      is_nil(value) -> {:ok, {:draft, nil}}
      is_binary(value) and byte_size(value) <= @draft_max_bytes -> {:ok, {:draft, value}}
      is_binary(value) -> {:error, "draft exceeds #{@draft_max_bytes} bytes"}
      true -> {:error, "draft must be a string or null"}
    end
  end

  defp patch_op("mode", value, provider),
    do: with({:ok, m} <- req_mode(value, provider), do: {:ok, {:mode, m}})

  defp patch_op("model_choice", value, provider),
    do: with({:ok, m} <- req_model(value, provider), do: {:ok, {:model_choice, m}})

  defp patch_op("effort_choice", value, provider),
    do: with({:ok, e} <- req_effort(value, provider), do: {:ok, {:effort_choice, e}})

  defp patch_op("title", value, _provider) do
    with true <- is_binary(value) || {:error, "title must be a string"},
         trimmed <- String.trim(value),
         true <- trimmed != "" || {:error, "title must not be blank"},
         true <-
           byte_size(trimmed) <= @title_max_bytes ||
             {:error, "title exceeds #{@title_max_bytes} bytes"} do
      {:ok, {:title, trimmed}}
    end
  end

  defp validate_content(params) do
    with :ok <- reject_non_object(params),
         :ok <- reject_unknown_keys(params, ["content"]),
         value <- Map.get(params, "content") do
      cond do
        not is_binary(value) ->
          {:error, "content must be a string"}

        byte_size(value) > @content_max_bytes ->
          {:error, "content exceeds #{@content_max_bytes} bytes"}

        true ->
          {:ok, value}
      end
    end
  end

  defp validate_approval(params) do
    with :ok <- reject_non_object(params),
         :ok <- reject_unknown_keys(params, ["request_id", "decision"]),
         {:ok, request_id} <- req_request_id(Map.get(params, "request_id")),
         {:ok, decision} <- req_decision(Map.get(params, "decision")) do
      {:ok, {request_id, decision}}
    end
  end

  # `?since=` is a query param (a string); absent ⇒ nil (all rows). Negative /
  # non-integer / out-of-range ⇒ 400 (D22/D last obligation).
  defp validate_since(params) do
    case Map.get(params, "since") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 and n <= @since_max -> {:ok, n}
          _ -> {:error, "since must be an integer in 0..#{@since_max}"}
        end

      _ ->
        {:error, "since must be an integer"}
    end
  end

  # `?archived=` is a query param; only the exact strings `true`/`false` (or
  # absent ⇒ false) are accepted — a malformed value is a 400 (D22).
  defp validate_archived(params) do
    case Map.get(params, "archived") do
      nil -> {:ok, false}
      "false" -> {:ok, false}
      "true" -> {:ok, true}
      _ -> {:error, "archived must be 'true' or 'false'"}
    end
  end

  # ── shared field validators ────────────────────────────────────────────────

  # Reject a non-object body. Plug wraps a top-level JSON array as
  # `%{"_json" => [...]}`; a bare scalar body is unusual but the same guard
  # applies — the params we accept are always a flat JSON object.
  defp reject_non_object(%{"_json" => _}), do: {:error, "request body must be a JSON object"}
  defp reject_non_object(params) when is_map(params), do: :ok
  defp reject_non_object(_), do: {:error, "request body must be a JSON object"}

  # Any key outside the allowlist — an unknown key OR a launcher control
  # (command/executable/args/env/cwd/session_id/resume/minter/token/
  # bypass_armed/updatedInput/…) — is a 400 before any side effect (D22/E).
  defp reject_unknown_keys(params, allowed) do
    case Map.keys(params) -- allowed do
      [] -> :ok
      extra -> {:error, "unrecognized keys: #{Enum.join(Enum.sort(extra), ", ")}"}
    end
  end

  # PATCH validators consult the SESSION's provider capability matrix (the same
  # source validate_create/1 reads), not a hardcoded claude — a codex session
  # must reject claude-only values and vice versa. The mode allowlist still
  # EXCLUDES bypassPermissions (D22 — not accepted remotely).
  defp req_mode(value, provider) do
    cond do
      not is_binary(value) -> {:error, "mode must be a string"}
      value in (Runtime.capabilities(provider).modes -- ["bypassPermissions"]) -> {:ok, value}
      true -> {:error, "invalid mode"}
    end
  end

  defp req_model(value, provider) do
    cond do
      not is_binary(value) -> {:error, "model must be a string"}
      value in Runtime.capabilities(provider).models -> {:ok, value}
      true -> {:error, "invalid model"}
    end
  end

  defp req_effort(value, provider) do
    cond do
      not is_binary(value) -> {:error, "effort must be a string"}
      value in Runtime.capabilities(provider).efforts -> {:ok, value}
      true -> {:error, "invalid effort"}
    end
  end

  defp req_request_id(value) do
    cond do
      not is_binary(value) ->
        {:error, "request_id must be a string"}

      value == "" ->
        {:error, "request_id must not be blank"}

      byte_size(value) > @request_id_max_bytes ->
        {:error, "request_id exceeds #{@request_id_max_bytes} bytes"}

      true ->
        {:ok, value}
    end
  end

  # `allow` echoes the server-held original ask; `deny` carries a fixed server
  # message. A caller-supplied `updatedInput` is impossible — it is an
  # unrecognized key (rejected above), never plumbed here (D22).
  defp req_decision("allow"), do: {:ok, :allow}
  defp req_decision("deny"), do: {:ok, {:deny, "Denied by operator."}}
  defp req_decision(_), do: {:error, "decision must be 'allow' or 'deny'"}

  # ─────────────────────────────────────────────────────────────────────────
  # JSON projection
  # ─────────────────────────────────────────────────────────────────────────

  # The FULL continuity struct (D14) plus messages. `list_sessions` deliberately
  # OMITS draft/rail/choices — this is the read that carries them.
  defp full_session_json(%StudioChat.Session{} = s, messages) do
    %{
      id: s.id,
      provider: s.provider,
      execution_target: s.execution_target,
      execution_host_id: s.execution_host_id,
      provider_session_id: s.provider_session_id,
      title: s.title,
      title_source: s.title_source,
      status: s.status,
      mode: s.mode,
      model: s.model,
      model_choice: s.model_choice,
      effort_choice: s.effort_choice,
      draft: s.draft,
      rail_snapshot: s.rail_snapshot || %{},
      summary: s.summary,
      cwd: s.cwd,
      message_count: s.message_count,
      pending_approvals: s.pending_approvals,
      input_tokens: s.input_tokens,
      output_tokens: s.output_tokens,
      total_cost_usd: s.total_cost_usd,
      last_context_tokens: s.last_context_tokens,
      context_window: s.context_window,
      # Provider-OBSERVED runtime facts (wb-api-chat-observed-telemetry-readout):
      # distinct from model_choice/effort_choice (what was REQUESTED) above —
      # these are what the provider actually reported, written by
      # RuntimeTelemetry.observe/2 and observe_identity/2. nil means no
      # observation has landed yet; NEVER coalesced to 0 or to the requested
      # model (honesty rule — a missing fact must read as unknown, not zero).
      observed_model: s.observed_model,
      observed_effort: s.observed_effort,
      observed_input_tokens: s.observed_input_tokens,
      observed_cached_input_tokens: s.observed_cached_input_tokens,
      observed_output_tokens: s.observed_output_tokens,
      observed_reasoning_output_tokens: s.observed_reasoning_output_tokens,
      observed_total_tokens: s.observed_total_tokens,
      observed_context_window: s.observed_context_window,
      runtime_identity: s.runtime_identity,
      runtime_telemetry_limitations: s.runtime_telemetry_limitations,
      # Herd (charter D65h): the show read carries the agent_state pair too —
      # a single-session poller must not need the sidebar list to know the
      # pill state.
      agent_state: s.agent_state,
      agent_state_at: s.agent_state_at,
      last_active_at: s.last_active_at,
      archived_at: s.archived_at,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at,
      messages: Enum.map(messages, &message_json/1)
    }
  end

  # The sidebar shape (D14 vacuous-green trap — NO draft/rail/choices here).
  # Wave-session-card (wsc charter D6 — amends D14 ADDITIVELY): a session whose
  # rail carries a workflow gains the compact derived `workflow` summary
  # (~300B, the D3 pinned shape) and — when the ledger resolves one — an `epic`
  # goal map (D9). The raw rail_snapshot (measured 38kB for a 29-agent run)
  # still NEVER rides a list surface; plain sessions keep the exact shape
  # above, key for key.
  defp sidebar_json(%StudioChat.Session{} = s) do
    base = %{
      id: s.id,
      provider: s.provider,
      execution_target: s.execution_target,
      execution_host_id: s.execution_host_id,
      title: s.title,
      title_source: s.title_source,
      status: s.status,
      summary: s.summary,
      message_count: s.message_count,
      pending_approvals: s.pending_approvals,
      input_tokens: s.input_tokens,
      output_tokens: s.output_tokens,
      total_cost_usd: s.total_cost_usd,
      # Herd cold-mount (herd charter D50h): the wave-5 agent_state substrate
      # rides the sidebar so `bp chat`'s herd home sorts/badges before the
      # fleet stream's first frame. Additive — the Ecto select always loaded
      # these; the projection just stopped dropping them.
      agent_state: s.agent_state,
      agent_state_at: s.agent_state_at,
      last_active_at: s.last_active_at,
      archived_at: s.archived_at,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }

    case StudioChat.workflow_summary(s.rail_snapshot) do
      nil -> base
      workflow -> base |> Map.put(:workflow, workflow) |> put_epic(s)
    end
  end

  defp put_epic(json, %StudioChat.Session{} = s) do
    case StudioChat.epic_goal(s.provider, s.id) do
      nil -> json
      epic -> Map.put(json, :epic, epic)
    end
  end

  @doc """
  Project a settled message row to its wire JSON. An ASSISTANT row carries
  `blocks` — the exact PortableDoc JSON the Go client round-trips through pdrender
  (D8) — alongside `source_markdown`. The three non-text chat rows (`tool` when
  file-mutating, `todo`, `thinking`) ALSO carry a one-element `blocks` list of a
  TYPED chat block (`chat-tool-diff` | `chat-todo` | `chat-thinking`), built from
  the ONE shared derivation (`Components` + `ChatToolRenderer`), so the Go TUI
  half (`internal/chat`) decodes the identical shape and renders the same row
  (charter D25 — dual-surface Law 1). The three INTERACTIVE cards (`approval`,
  `question`, `plan`) ALSO carry a typed block (`chat-approval` | `chat-question`
  | `chat-plan`) synthesized from their metadata (charter D35) — the read-time
  VISUAL only, so answerability stays on the envelope. Every other role carries
  its raw metadata
  (admin-only route, D21 — no per-row redaction). Exposed as an `@doc false`
  public seam (the ListenController convention) so the projection is unit-tested
  without a live SSE loop.
  """
  def message_json(%StudioChat.Message{} = m) do
    metadata = m.metadata || %{}

    base = %{
      seq: m.seq,
      role: m.role,
      source_markdown: m.source_markdown,
      # `attachments` is LIFTED OUT of metadata and re-projected below — the
      # persisted pointer carries the store `path` (`<session_id>/<sha256>`),
      # and a filesystem path must never reach a client (ct-bl-chat-attachments).
      # Dropping the key here makes that structural rather than a convention: the
      # only attachment representation on the wire is the reference shape.
      metadata: Map.delete(metadata, "attachments"),
      inserted_at: m.inserted_at
    }

    base
    |> put_attachments(Attachments.references(metadata, m.session_id))
    |> put_blocks(toolrow_blocks(m))
  end

  # The ONE wire attachment shape both surfaces speak: `{id, media_type,
  # byte_size, url}` — an opaque content-addressed id and the chat-owned read
  # URL, with no store path, no bearer token, and no bytes. Absent entirely when
  # the row has none, so an attachment-free transcript is byte-identical to
  # before.
  defp put_attachments(json, nil), do: json
  defp put_attachments(json, refs), do: Map.put(json, :attachments, refs)

  defp put_blocks(json, nil), do: json
  defp put_blocks(json, blocks), do: Map.put(json, :blocks, blocks)

  # The `blocks` a settled row projects, or nil (no blocks key). An assistant row
  # converts its markdown; the three chat rows emit ONE typed chat block each,
  # reusing the SAME pure derivations the Studio renderer uses.
  defp toolrow_blocks(%StudioChat.Message{role: "assistant", source_markdown: md})
       when is_binary(md),
       do: FromMarkdown.blocks(md)

  defp toolrow_blocks(%StudioChat.Message{role: "tool", metadata: meta}) do
    input = Map.get(meta || %{}, "input")

    case Components.chat_tool_diff_block(input) do
      nil -> nil
      block -> [block]
    end
  end

  defp toolrow_blocks(%StudioChat.Message{role: "todo", metadata: meta}) do
    input = Map.get(meta || %{}, "input") || %{}
    [Components.chat_todo_block_from_input(input)]
  end

  defp toolrow_blocks(%StudioChat.Message{role: "thinking", metadata: meta}) do
    case Map.get(meta || %{}, "tokens") do
      tokens when is_integer(tokens) -> [Components.chat_thinking_block(tokens)]
      _ -> nil
    end
  end

  # The three INTERACTIVE cards (charter D35): approval / question / plan project
  # a typed block synthesized from the SAME metadata the Recorder persisted
  # (request_id, tool_name, input, approval_status). The block is the read-time
  # VISUAL only — `base` still carries the metadata, so answerability stays on the
  # envelope (role + request_id + approval_status), NOT the block.
  defp toolrow_blocks(%StudioChat.Message{role: "approval", metadata: meta}),
    do: [Components.chat_approval_block(meta || %{})]

  defp toolrow_blocks(%StudioChat.Message{role: "question", metadata: meta}),
    do: [Components.chat_question_block(meta || %{})]

  defp toolrow_blocks(%StudioChat.Message{role: "plan", metadata: meta}),
    do: [Components.chat_plan_block(meta || %{})]

  defp toolrow_blocks(_), do: nil

  # ── replay / request helpers ────────────────────────────────────────────────

  defp filter_since(messages, nil), do: messages
  defp filter_since(messages, since), do: Enum.filter(messages, &(&1.seq > since))

  # Lenient Last-Event-ID parse for the SSE resume header (mirrors
  # ListenController): a malformed value ⇒ nil ⇒ start live with no replay. The
  # STRICT 400 path is `?since=` on GET session, not this resume header.
  defp last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [value | _] ->
        case Integer.parse(value) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp bad_request(conn, message) do
    ErrorResponse.emit_custom(conn, 400, "invalid_request", message)
  end

  defp not_found(conn) do
    ErrorResponse.emit(conn, {:error, :not_found}, "chat session not found")
  end
end
