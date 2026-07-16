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
  `create_session/2`; a session an admin creates is `nil`-owned (instance-global,
  visible only to `:global`).

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
  alias Barkpark.StudioChat.{Recorder, Runtime}
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

      # Thread the caller's scope into the sealed store (charter D17/D18): the
      # store stamps `owner_workspace_id` from the scope — a workspace Connector
      # owns what it creates, an admin (`:global`) creates a `nil`-owned
      # instance-global session. The scope is authoritative in the store, so it
      # is passed as the second arg, NOT smuggled through `attrs` (the store
      # overrides any owner in `attrs`).
      case StudioChat.create_session(
             %{
               id: id,
               provider: attrs.provider,
               execution_target: attrs.execution_target,
               execution_host_id: attrs.execution_host_id,
               cwd: provider_cwd(attrs.provider),
               mode: attrs.mode
             },
             scope(conn)
           ) do
        {:ok, _session} ->
          if attrs.model, do: StudioChat.set_model_choice(id, attrs.model)
          if attrs.effort, do: StudioChat.set_effort_choice(id, attrs.effort)

          conn
          |> put_status(:created)
          |> json(full_session_json(StudioChat.get_session(id), []))

        {:error, reason} ->
          Logger.warning("chat transport: create_session failed: #{inspect(reason)}")

          ErrorResponse.emit_custom(
            conn,
            503,
            "chat_unavailable",
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

    with {:ok, ops} <- validate_patch(body),
         %StudioChat.Session{} <- fetch_scoped(id, scope(conn)) do
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
          conn |> put_status(:accepted) |> json(%{accepted: true})

        {:error, reason} ->
          Logger.warning("chat transport: send failed: #{inspect(reason)}")
          ErrorResponse.emit_custom(conn, 503, "chat_unavailable", "chat runtime is unavailable")
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

      {:claude_chat_permission, ask} ->
        chunk_or_stop(conn, sse_permission_frame(ask))

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
  def sse_permission_frame(ask), do: "event: permission\ndata: #{Jason.encode!(ask)}\n\n"

  @doc false
  # The public exit frame (D23) — EXACTLY status + reason; the internal tail is
  # not a parameter, so it is structurally unable to leak here.
  def sse_exit_frame(status), do: "event: exit\ndata: #{Jason.encode!(exit_payload(status))}\n\n"

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
         {:ok, session_pid} <- Recorder.session_pid(recorder) do
      Runtime.send_turn(session.provider, session_pid, content)
    end
  end

  defp apply_patch_op(id, {:draft, value}), do: StudioChat.set_draft(id, value)
  defp apply_patch_op(id, {:mode, value}), do: StudioChat.set_mode(id, value)
  defp apply_patch_op(id, {:model_choice, value}), do: StudioChat.set_model_choice(id, value)
  defp apply_patch_op(id, {:effort_choice, value}), do: StudioChat.set_effort_choice(id, value)
  defp apply_patch_op(id, {:title, value}), do: StudioChat.rename(id, value)

  # ─────────────────────────────────────────────────────────────────────────
  # validation (fail BEFORE any store/runtime call — obligations D + E)
  # ─────────────────────────────────────────────────────────────────────────

  @create_keys ~w(provider execution_target execution_host_id mode model effort)
  defp validate_create(params) do
    with :ok <- reject_non_object(params),
         :ok <- reject_unknown_keys(params, @create_keys),
         {:ok, provider} <- opt_enum(params, "provider", StudioChat.Session.providers(), "claude"),
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
  defp validate_patch(params) do
    with :ok <- reject_non_object(params),
         :ok <- reject_unknown_keys(params, @patch_keys) do
      collect_patch_ops(params, @patch_keys, [])
    end
  end

  defp collect_patch_ops(_params, [], ops), do: {:ok, Enum.reverse(ops)}

  defp collect_patch_ops(params, [key | rest], ops) do
    if Map.has_key?(params, key) do
      case patch_op(key, Map.get(params, key)) do
        {:ok, op} -> collect_patch_ops(params, rest, [op | ops])
        {:error, _} = err -> err
      end
    else
      collect_patch_ops(params, rest, ops)
    end
  end

  defp patch_op("draft", value) do
    cond do
      is_nil(value) -> {:ok, {:draft, nil}}
      is_binary(value) and byte_size(value) <= @draft_max_bytes -> {:ok, {:draft, value}}
      is_binary(value) -> {:error, "draft exceeds #{@draft_max_bytes} bytes"}
      true -> {:error, "draft must be a string or null"}
    end
  end

  defp patch_op("mode", value), do: with({:ok, m} <- req_mode(value), do: {:ok, {:mode, m}})

  defp patch_op("model_choice", value),
    do: with({:ok, m} <- req_model(value), do: {:ok, {:model_choice, m}})

  defp patch_op("effort_choice", value),
    do: with({:ok, e} <- req_effort(value), do: {:ok, {:effort_choice, e}})

  defp patch_op("title", value) do
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

  # mode allowlist EXCLUDES bypassPermissions (D22 — not accepted remotely).
  defp valid_modes, do: StudioChat.Session.modes() -- ["bypassPermissions"]

  defp req_mode(value) do
    cond do
      not is_binary(value) -> {:error, "mode must be a string"}
      value in valid_modes() -> {:ok, value}
      true -> {:error, "invalid mode"}
    end
  end

  defp req_model(value) do
    cond do
      not is_binary(value) -> {:error, "model must be a string"}
      value in Runtime.capabilities("claude").models -> {:ok, value}
      true -> {:error, "invalid model"}
    end
  end

  defp req_effort(value) do
    cond do
      not is_binary(value) -> {:error, "effort must be a string"}
      value in Runtime.capabilities("claude").efforts -> {:ok, value}
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
      last_active_at: s.last_active_at,
      last_visited_at: s.last_visited_at,
      archived_at: s.archived_at,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at,
      messages: Enum.map(messages, &message_json/1)
    }
  end

  # The sidebar shape (D14 vacuous-green trap — NO draft/rail/choices here).
  defp sidebar_json(%StudioChat.Session{} = s) do
    %{
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
      last_active_at: s.last_active_at,
      last_visited_at: s.last_visited_at,
      archived_at: s.archived_at,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
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
    base = %{
      seq: m.seq,
      role: m.role,
      source_markdown: m.source_markdown,
      metadata: m.metadata || %{},
      inserted_at: m.inserted_at
    }

    case toolrow_blocks(m) do
      nil -> base
      blocks -> Map.put(base, :blocks, blocks)
    end
  end

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
