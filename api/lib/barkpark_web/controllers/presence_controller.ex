defmodule BarkparkWeb.PresenceController do
  @moduledoc """
  Editor presence over HTTP for clients that are not the LiveView Studio
  (task-32b73e85f89d4be7, Studio parity journey J07).

      GET  /w/:ws/p/:proj/v1/data/presence/:dataset?sessionId=&name=&documentId=
      POST /w/:ws/p/:proj/v1/data/presence/:dataset/focus
           {"sessionId": "…", "documentId": "…", "field": "seo.metaTitle"}

  The GET is a Server-Sent Events stream. While it is open, the connection
  process is TRACKED in the same Phoenix.Presence room the LiveView Studio
  joins (`Studio.PresenceState.topic/3`: workspace + project + dataset), so
  API clients and Studio users see each other. It sends:

    * `event: session` once, `{"sessionId": …}` — the id to send focus with;
    * `event: presence` with the full room list (`{"presences": [...]}`, narrowed
      to one document by `?documentId=`), first on connect and then on every
      change, each entry `{sessionId, name, color, documentId, field, client}`;
    * `: keepalive` comments.

  The POST moves that session's focus (document + field path). It answers 404
  unless the session is live AND was opened by the same API token, so one
  caller cannot steer another's cursor.

  Expiry: Phoenix.Presence drops an entry when its tracking process exits.
  The stream process exits when the client disconnects, and at the latest on
  the next keepalive write (every #{div(15_000, 1000)} s) that finds the
  socket closed — no stale entry outlives its connection.

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

  @keepalive_ms 15_000
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
         :ok <- owns_live_session(topic, sid, token) do
      doc_id = blank_to_nil(params["documentId"])
      field = blank_to_nil(params["field"])

      want = doc_id && DraftId.published_id(doc_id)
      ref = make_ref()

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        session_topic(topic, sid),
        {:presence_focus, want, field, {self(), ref}}
      )

      # The answer is the room entry READ BACK after the stream applied it,
      # never the request echoed: a 200 means the room now says this.
      with :ok <- await_applied(ref),
           %{} = entry <- read_entry(topic, sid, want, field) do
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

  # ── The stream loop ──────────────────────────────────────────────────────

  defp loop(conn, state) do
    receive do
      :sse_overloaded ->
        conn

      {:presence_focus, doc_id, field, {from, ref}} ->
        Presence.update(
          self(),
          state.topic,
          state.key,
          &Map.merge(&1, %{doc_id: doc_id, field: field})
        )

        send(from, {:presence_focus_applied, ref})
        loop(conn, state)

      %Phoenix.Socket.Broadcast{event: "presence_diff"} ->
        case send_snapshot(conn, state.topic, state.doc_filter, state.last) do
          {:ok, conn, last} -> loop(conn, %{state | last: last})
          _ -> conn
        end

      _other ->
        loop(conn, state)
    after
      @keepalive_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> loop(conn, state)
          _ -> conn
        end
    end
  end

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
  defp entry(key, meta) do
    %{
      sessionId: Map.get(meta, :session_id) || key,
      name: Map.get(meta, :name),
      color: Map.get(meta, :color),
      documentId: Map.get(meta, :doc_id),
      field: Map.get(meta, :field),
      client: Map.get(meta, :client, "studio")
    }
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

  # The session's entry as the Presence store holds it now, picked by the
  # values just applied (a session open twice carries one meta per stream).
  defp read_entry(topic, sid, doc_id, field) do
    case Presence.get_by_key(topic, presence_key(sid)) do
      %{metas: metas} ->
        metas
        |> Enum.map(&entry(presence_key(sid), &1))
        |> Enum.find(&(&1.documentId == doc_id and &1.field == field))

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
