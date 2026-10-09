defmodule BarkparkWeb.PresenceController do
  @selection_max_bytes 512
  # task-936472b77285df5b — shortened from 15_000: the probabilistic half of
  # expiry (see moduledoc) now bounds its OWN worst case tighter, independent
  # of whether `leave` below was called. A tiny `": keepalive\n\n"` comment
  # every 5s is negligible bandwidth for an open editing session. The
  # DEFAULT only — `keepalive_ms/0` reads `:barkpark, :presence_keepalive_ms`
  # first, so a test can shrink the interval without waiting out this one.
  # Defined here (before @moduledoc) so the doc string below can interpolate
  # it.
  @keepalive_ms 5_000

  @moduledoc """
  Editor presence over HTTP for clients that are not the LiveView Studio
  (task-32b73e85f89d4be7, Studio parity journey J07).

      GET    /w/:ws/p/:proj/v1/data/presence/:dataset?sessionId=&name=&documentId=
      POST   /w/:ws/p/:proj/v1/data/presence/:dataset/focus
             {"sessionId": "…", "documentId": "…", "field": "seo.metaTitle",
              "selection": {"anchor": Point, "head": Point} | null}
      DELETE /w/:ws/p/:proj/v1/data/presence/:dataset/leave?sessionId=

  The GET is a Server-Sent Events stream. While it is open, the connection
  process is TRACKED in the same Phoenix.Presence room the LiveView Studio
  joins (`Studio.PresenceState.topic/3`: workspace + project + dataset), so
  API clients and Studio users see each other. It sends:

    * `event: session` once, `{"sessionId": …}` — the id to send focus with;
    * `event: presence` with the full room list (`{"presences": [...]}`, narrowed
      to one document by `?documentId=`), first on connect and then on every
      change, each entry `{sessionId, name, color, documentId, field, client}`
      plus `selection` while that session has one;
    * `: keepalive` comments.

  The POST moves that session's focus (document + field path) and, optionally,
  its text selection (task-d47c05259837093f, shared carets): the canvas
  `bp-canvas-selection` detail, `Point = {blockId, path?, offset}`. A focus
  without `selection` clears it. Over #{@selection_max_bytes} bytes of JSON is
  a 413; any other shape is a 422. It answers 404 unless the session is live
  AND was opened by the same API token, so one caller cannot steer another's
  cursor.

  ## Leaving (task-936472b77285df5b)

  `DELETE .../leave?sessionId=` untracks the caller's OWN session from the
  room at once — same ownership check as `focus` (404 unless the session is
  live and was opened by the same API token), so a session can only remove
  itself, never another's. Idempotent: the session is gone after the first
  call, so a SECOND leave finds no live session and answers the SAME 404 as
  the first call would have before the session ever existed — "nothing to
  do" is not an error. The stream behind the removed session exits right
  after untracking (its own `receive` loop, not this request's), so the SSE
  connection itself closes too, not just the room entry.

  WHY THIS EXISTS, GIVEN THE EXPIRY BELOW ALREADY CLAIMS TO COVER IT. Found
  live on guerrilla.barkpark.cloud (task-936472b77285df5b): a closed stream's
  entry lingered 20-40s instead of leaving "at the latest on the next
  keepalive write" as the paragraph below promises. Two candidate causes were
  checked, not assumed. Candidate 1, moot: a handled `presence_diff` already
  calls `chunk/2` whenever the VISIBLE entries change (`send_snapshot/4`), so
  a write failure there finds a dead socket just as fast as a keepalive would
  — a busy room with visible churn was never the slow case. Candidate 2,
  confirmed and FIXED here: the keepalive used to be a plain `receive ...
  after` timeout, and an `after` clause's clock restarts on every message
  that `receive` handles — including a `presence_diff` for a document this
  stream's `?documentId=` filter does NOT show, which recomputes `entries/2`,
  finds no visible change, writes nothing, and still resets the clock. A busy
  room whose other activity stayed off-filter could starve the keepalive
  indefinitely. Fixed by scheduling it with `Process.send_after/3` instead
  (see `schedule_keepalive/0`): a timer fired by `self()` keeps its own
  schedule no matter what else lands in the mailbox. The reverse proxy's
  handling of a closed downstream connection remains unverified from here —
  an explicit leave sidesteps it either way, by having the client state its
  own departure instead of waiting to be inferred. `pagehide` cannot use
  `navigator.sendBeacon` for this: a beacon can only POST, and cannot carry
  the bearer `Authorization` header this route requires. Use
  `fetch(url, {method: "DELETE", keepalive: true, headers: {Authorization: …}})`
  instead — `keepalive: true` is what lets it outlive the unloading page.

  Expiry (the fallback for a client that cannot or does not call leave — a
  crash, a network cut, an older client): Phoenix.Presence drops an entry
  when its tracking process exits. The stream process exits when the client
  disconnects, and at the latest on the next keepalive write (every
  #{div(@keepalive_ms, 1000)} s — shortened from the original 15s, and now on
  its own timer rather than a resettable `after`, both for exactly this
  reason, task-936472b77285df5b) that finds the socket closed. This remains
  probabilistic wherever the proxy's own half-close detection is slower than
  that; `leave` is the deterministic path and clients SHOULD call it whenever
  they can.

  Identity is the client's to state: the Studio parity app proxies every
  browser user through one server token, so `?name=` carries the person and
  defaults to the token's label. Only workspace members may join; a caller
  admitted by a narrow grant is refused, because the room shows which
  documents everyone in the project is editing.
  """

  use BarkparkWeb, :controller
  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.DraftId
  alias BarkparkWeb.{ErrorResponse, Presence}
  alias BarkparkWeb.Studio.PresenceState

  @session_re ~r/\A[A-Za-z0-9_-]{1,64}\z/

  def stream(conn, %{"dataset" => dataset} = params) do
    with {:ok, topic, token} <- room(conn, dataset),
         {:ok, sid} <- session_id(params["sessionId"]) do
      key = presence_key(sid)
      doc_filter = blank_to_nil(params["documentId"])

      meta = %{
        doc_id: doc_filter && DraftId.published_id(doc_filter),
        type: nil,
        dataset: dataset,
        project_id: Keyword.get(scope_opts(conn), :project_id),
        name: display_name(params["name"], token),
        color: PresenceState.pick_color(sid),
        joined_at: System.system_time(:second),
        field: nil,
        client: "api",
        session_id: sid,
        owner: owner_ref(token)
      }

      Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
      Phoenix.PubSub.subscribe(Barkpark.PubSub, session_topic(topic, sid))
      {:ok, _} = Presence.track(self(), topic, key, meta)

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)

      with {:ok, conn} <- chunk(conn, frame("session", %{sessionId: sid})),
           {:ok, conn, last} <- send_snapshot(conn, topic, doc_filter, nil) do
        schedule_keepalive()
        loop(conn, %{topic: topic, key: key, doc_filter: doc_filter, last: last})
      else
        _ -> conn
      end
    else
      {:error, status, code, message} ->
        ErrorResponse.emit_custom(conn, status, code, message, %{})
    end
  end

  def focus(conn, %{"dataset" => dataset} = params) do
    with {:ok, topic, token} <- room(conn, dataset),
         {:ok, sid} <- required_session(params["sessionId"]),
         {:ok, selection} <- selection(params["selection"]),
         :ok <- owns_live_session(topic, sid, token) do
      doc_id = blank_to_nil(params["documentId"])
      field = blank_to_nil(params["field"])

      want = doc_id && DraftId.published_id(doc_id)
      ref = make_ref()

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        session_topic(topic, sid),
        {:presence_focus, %{doc_id: want, field: field, selection: selection}, {self(), ref}}
      )

      # The answer is the room entry READ BACK after the stream applied it,
      # never the request echoed: a 200 means the room now says this.
      with :ok <- await_applied(ref),
           %{} = entry <- read_entry(topic, sid, want, field, selection) do
        json(conn, %{result: entry})
      else
        _ ->
          {:error, status, code, message} = not_live()
          ErrorResponse.emit_custom(conn, status, code, message, %{})
      end
    else
      {:error, status, code, message} ->
        ErrorResponse.emit_custom(conn, status, code, message, %{})
    end
  end

  @doc """
  DELETE /w/:ws/p/:proj/v1/data/presence/:dataset/leave?sessionId= — untrack
  the caller's OWN session at once. 404 unless the session is live and was
  opened by the SAME API token as `focus`/`stream` require — a session can
  remove only itself. Idempotent: once untracked, a second call finds no
  live session and answers the same 404, which IS the no-op (nothing to
  remove, not an error).
  """
  def leave(conn, %{"dataset" => dataset} = params) do
    with {:ok, topic, token} <- room(conn, dataset),
         {:ok, sid} <- required_session(params["sessionId"]),
         :ok <- owns_live_session(topic, sid, token) do
      ref = make_ref()

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        session_topic(topic, sid),
        {:presence_leave, {self(), ref}}
      )

      case await_left(ref) do
        :ok ->
          json(conn, %{left: true, sessionId: sid})

        :timeout ->
          {:error, status, code, message} = not_live()
          ErrorResponse.emit_custom(conn, status, code, message, %{})
      end
    else
      {:error, status, code, message} ->
        ErrorResponse.emit_custom(conn, status, code, message, %{})
    end
  end

  # ── The stream loop ──────────────────────────────────────────────────────

  defp loop(conn, state) do
    receive do
      :sse_overloaded ->
        conn

      {:presence_focus, focus, {from, ref}} ->
        Presence.update(self(), state.topic, state.key, &Map.merge(&1, focus))

        send(from, {:presence_focus_applied, ref})
        loop(conn, state)

      # task-936472b77285df5b — an explicit leave. untrack/3 MUST run from
      # THIS process (the one `track/4` named in `stream/2`): the leave
      # HTTP request is a different, short-lived process that cannot
      # untrack on this stream's behalf directly, which is why it is a
      # broadcast + ack here, the same shape `:presence_focus` already uses.
      # Does NOT recurse: the session is gone, so the stream ends with it —
      # exactly what the client wanted (one less thing to clean up later),
      # not a room entry surviving its own removal request.
      {:presence_leave, {from, ref}} ->
        Presence.untrack(self(), state.topic, state.key)
        send(from, {:presence_left, ref})
        conn

      %Phoenix.Socket.Broadcast{event: "presence_diff"} ->
        case send_snapshot(conn, state.topic, state.doc_filter, state.last) do
          {:ok, conn, last} -> loop(conn, %{state | last: last})
          _ -> conn
        end

      # task-936472b77285df5b — scheduled with `Process.send_after/3`, NOT a
      # `receive ... after` timeout: an `after` clause's clock restarts on
      # EVERY message this `receive` handles, so a `?documentId=`-filtered
      # stream in a busy room (other sessions' diffs on OTHER documents keep
      # arriving, matching `presence_diff` above and re-entering `receive`,
      # but never writing — see `send_snapshot/4`) could starve it
      # indefinitely. A timer fired by `self()` is independent of whatever
      # else lands in this mailbox, so it keeps its own schedule regardless.
      :keepalive ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            schedule_keepalive()
            loop(conn, state)

          _ ->
            conn
        end

      _other ->
        loop(conn, state)
    end
  end

  defp schedule_keepalive, do: Process.send_after(self(), :keepalive, keepalive_ms())

  defp keepalive_ms, do: Application.get_env(:barkpark, :presence_keepalive_ms, @keepalive_ms)

  # One frame per CHANGE of the visible list: a diff for another document, or
  # one that only moved `joined_at`, sends nothing.
  defp send_snapshot(conn, topic, doc_filter, last) do
    entries = entries(topic, doc_filter)

    if entries == last do
      {:ok, conn, last}
    else
      case chunk(conn, frame("presence", %{presences: entries})) do
        {:ok, conn} -> {:ok, conn, entries}
        error -> error
      end
    end
  end

  defp entries(topic, doc_filter) do
    topic
    |> Presence.list()
    # Newest meta first, so a session open twice (a reconnect racing its old
    # stream's exit, or one Studio user in two tabs) shows once, as it is now.
    |> Enum.flat_map(fn {key, %{metas: metas}} ->
      metas |> Enum.reverse() |> Enum.map(&entry(key, &1))
    end)
    |> Enum.filter(&(is_nil(doc_filter) or &1.documentId == DraftId.published_id(doc_filter)))
    |> Enum.uniq_by(& &1.sessionId)
    |> Enum.sort_by(&{&1.name || "", &1.sessionId})
  end

  # Studio LiveView metas carry no session id or field; their presence key is
  # the Studio user id, which plays the same role.
  # `selection` is present only while set, so an entry without one keeps the
  # six keys it always had.
  defp entry(key, meta) do
    entry = %{
      sessionId: Map.get(meta, :session_id) || key,
      name: Map.get(meta, :name),
      color: Map.get(meta, :color),
      documentId: Map.get(meta, :doc_id),
      field: Map.get(meta, :field),
      client: Map.get(meta, :client, "studio")
    }

    case Map.get(meta, :selection) do
      nil -> entry
      selection -> Map.put(entry, :selection, selection)
    end
  end

  defp frame(event, data), do: "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

  @focus_apply_ms 2_000

  defp await_applied(ref) do
    receive do
      {:presence_focus_applied, ^ref} -> :ok
    after
      @focus_apply_ms -> :timeout
    end
  end

  defp await_left(ref) do
    receive do
      {:presence_left, ^ref} -> :ok
    after
      @focus_apply_ms -> :timeout
    end
  end

  # The session's entry as the Presence store holds it now, picked by the
  # values just applied (a session open twice carries one meta per stream).
  defp read_entry(topic, sid, doc_id, field, selection) do
    case Presence.get_by_key(topic, presence_key(sid)) do
      %{metas: metas} ->
        metas
        |> Enum.map(&entry(presence_key(sid), &1))
        |> Enum.find(
          &(&1.documentId == doc_id and &1.field == field and
              Map.get(&1, :selection) == selection)
        )

      _ ->
        nil
    end
  end

  # ── Scope, identity, ownership ───────────────────────────────────────────

  # The room is the Studio's: workspace + project + dataset. A caller with no
  # resolved workspace, or one admitted by a grant rather than membership, is
  # refused before anything is tracked.
  defp room(conn, dataset) do
    scope = scope_opts(conn)
    ws = Keyword.get(scope, :workspace_id)

    cond do
      not is_binary(ws) ->
        {:error, 403, "forbidden", "presence needs a workspace-scoped URL (/w/:ws/p/:proj/…)"}

      Keyword.get(scope, :grant_scoped) == true ->
        {:error, 403, "forbidden", "presence is for workspace members; a grant does not admit it"}

      true ->
        {:ok, PresenceState.topic(ws, Keyword.get(scope, :project_id), dataset),
         conn.assigns[:api_token]}
    end
  end

  defp session_id(nil), do: {:ok, PresenceState.generate_user_id()}
  defp session_id(""), do: {:ok, PresenceState.generate_user_id()}
  defp session_id(sid), do: required_session(sid)

  defp required_session(sid) when is_binary(sid) do
    if Regex.match?(@session_re, sid),
      do: {:ok, sid},
      else: {:error, 422, "validation_failed", "sessionId must be 1-64 of A-Z a-z 0-9 _ -"}
  end

  defp required_session(_),
    do:
      {:error, 422, "validation_failed",
       "sessionId is required (the id the stream's session event sent)"}

  # ── Selection (shared carets) ────────────────────────────────────────────

  # `nil` (absent or JSON null) is the blurred state. Size is checked on the
  # re-encoded value, before the shape, so an oversized body is a 413 whatever
  # it holds.
  defp selection(nil), do: {:ok, nil}

  defp selection(sel) do
    cond do
      byte_size(Jason.encode!(sel)) > @selection_max_bytes ->
        {:error, 413, "payload_too_large",
         "selection must be at most #{@selection_max_bytes} bytes of JSON"}

      selection_shape?(sel) ->
        {:ok, sel}

      true ->
        {:error, 422, "validation_failed",
         "selection must be null or {anchor, head}, each {blockId, path?, offset}"}
    end
  end

  defp selection_shape?(%{"anchor" => a, "head" => h} = sel) when map_size(sel) == 2,
    do: point?(a) and point?(h)

  defp selection_shape?(_), do: false

  defp point?(%{"blockId" => id, "offset" => off} = p)
       when is_binary(id) and id != "" and is_integer(off) and off >= 0 do
    case Map.drop(p, ["blockId", "offset"]) do
      empty when empty == %{} -> true
      %{"path" => path} when is_binary(path) and path != "" -> true
      _ -> false
    end
  end

  defp point?(_), do: false

  defp owns_live_session(topic, sid, token) do
    case Presence.get_by_key(topic, presence_key(sid)) do
      %{metas: metas} when is_list(metas) ->
        if Enum.any?(metas, &(Map.get(&1, :owner) == owner_ref(token))),
          do: :ok,
          else: not_live()

      _ ->
        not_live()
    end
  end

  defp not_live,
    do: {:error, 404, "not_found", "no open presence stream with this sessionId for this token"}

  defp presence_key(sid), do: "api:" <> sid
  defp session_topic(topic, sid), do: topic <> ":session:" <> sid

  # Compared, never shown: entries/2 does not copy it into a frame.
  defp owner_ref(%{id: id}) when is_binary(id), do: :erlang.phash2(id)
  defp owner_ref(_), do: nil

  defp display_name(name, _token) when is_binary(name) and name != "",
    do: String.slice(String.trim(name), 0, 80)

  defp display_name(_name, %{label: label}) when is_binary(label) and label != "", do: label
  defp display_name(_name, %{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_name, _token), do: "API client"

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_), do: nil
end
