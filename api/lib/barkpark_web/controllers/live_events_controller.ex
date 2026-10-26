defmodule BarkparkWeb.LiveEventsController do
  @moduledoc """
  Sanity's Live Content API event stream, `GET
  /w/:ws/p/:proj/v{apiVersion}/data/live/events/:dataset` — what
  `client.live.events()` and next-sanity's `defineLive` open
  (task-d6566cbed9b7c33c).

  Server-sent events that name the sync tags whose content changed, so a site
  revalidates exactly the fetches that carried them:

    * `event: welcome`, `data: {}`, `id:` the stream's head event id;
    * `event: message`, `data: {"tags": [...]}`, `id:` the newest event id
      in the batch. Tags are the OPAQUE twins (`Barkpark.Groq.SyncTag`) of the
      readable tags a GROQ read of the changed document returns: its `doc:`,
      its `type:` and the dataset's `_all`. A frame never names a document id
      or a type, and is never sent with no tags;
    * `event: restart`, `data: {}` when a `Last-Event-ID` / `?lastEventId`
      cannot be honoured (malformed, past the head, or a backlog over
      1,000 tags): the client refetches everything;
    * `: keepalive` every 30 s.

  Changes are batched over a second. Without `includeDrafts=true` a draft's
  change is not sent, as on Sanity. The gate is listen's (`:scoped_api` +
  `:require_token_or_member_session`): no anonymous stream, `public-read`
  refused. A frame carries no content, so there is no per-event re-render;
  the workspace and project fences are listen's own (`forward_event?/2`, the
  stream's project).

  A connection subscribes on its own (no shared hub yet); run-perf measures
  that cost.
  """
  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.{Broadcast, DraftId, EventLog}
  alias Barkpark.Groq.SyncTag
  alias Barkpark.Realtime.DrainSignal
  alias BarkparkWeb.{ErrorResponse, ListenController}

  @min_api_version "2021-03-25"
  @batch_ms 1_000
  @max_resume_tags 1_000

  def events(conn, %{"dataset" => dataset, "api_version" => version} = params) do
    if api_version_ok?(version) do
      stream(conn, dataset, params)
    else
      ErrorResponse.emit_fields(conn, 400, %{
        code: "malformed",
        message: "live events need API version #{@min_api_version} or later",
        description: "live events need API version #{@min_api_version} or later",
        type: "httpBadRequest"
      })
    end
  end

  defp api_version_ok?("X"), do: true

  defp api_version_ok?(version) when is_binary(version),
    do: Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, version) and version >= @min_api_version

  defp api_version_ok?(_), do: false

  defp stream(conn, dataset, params) do
    # A stalled reader must not grow this process without bound (listen's rule).
    Process.flag(:max_heap_size, %{size: 4_000_000, kill: true, error_logger: true})

    scope = scope_opts(conn)
    workspace_id = ListenController.stream_workspace_id(scope)
    project = ListenController.project_path_project_id(conn, scope)

    state = %{
      dataset: dataset,
      workspace_id: workspace_id,
      project: project,
      tag_project: Keyword.get(scope, :project_id),
      drafts?: params["includeDrafts"] in ["true", true],
      pending: MapSet.new(),
      pending_id: nil,
      timer: nil
    }

    Phoenix.PubSub.subscribe(Barkpark.PubSub, topic(dataset, workspace_id))
    DrainSignal.subscribe()

    head = EventLog.head_event_id(dataset, workspace_id, project_id: project)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    first =
      case resume_from(conn, params) do
        nil -> frame("welcome", head, %{})
        since -> resume(state, since, head)
      end

    case chunk(conn, first) do
      {:ok, conn} ->
        schedule_keepalive()
        loop(conn, state)

      _ ->
        conn
    end
  end

  defp topic(dataset, workspace_id) when is_binary(workspace_id),
    do: Broadcast.workspace_list_topic(dataset, workspace_id)

  defp topic(dataset, _workspace_id), do: Broadcast.global_list_topic(dataset)

  defp resume_from(conn, params) do
    case get_req_header(conn, "last-event-id") do
      [v | _] -> v
      _ -> params["lastEventId"]
    end
  end

  # A welcome, then the tags of every change since `since`, coalesced into one
  # message; `restart` when `since` cannot be honoured.
  defp resume(state, since, head) do
    with {n, ""} when n >= 0 <- Integer.parse(to_string(since)),
         true <- is_integer(head) and n <= head,
         {:ok, tags} <- tags_since(state, n, head) do
      welcome = frame("welcome", head, %{})
      if tags == [], do: welcome, else: welcome <> frame("message", head, %{tags: tags})
    else
      _ -> frame("restart", head, %{})
    end
  end

  defp tags_since(state, since, head) do
    state.dataset
    |> EventLog.replay_since(since, state.workspace_id, project_id: state.project)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn ev, {:ok, acc} ->
      cond do
        ev.id > head ->
          {:halt, {:ok, acc}}

        not include?(state, ev.doc_id) ->
          {:cont, {:ok, acc}}

        true ->
          acc = MapSet.union(acc, tags_for(state, ev.type, ev.doc_id))

          if MapSet.size(acc) > @max_resume_tags,
            do: {:halt, :too_many},
            else: {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.sort(acc)}
      :too_many -> :too_many
    end
  end

  defp loop(conn, state) do
    receive do
      {:document_changed, %{event_id: id} = msg} when is_integer(id) ->
        loop(conn, take(state, msg))

      {:document_changed, _msg} ->
        loop(conn, state)

      :flush ->
        flush(conn, state)

      :keepalive ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            schedule_keepalive()
            loop(conn, state)

          _ ->
            conn
        end

      :retire ->
        case chunk(conn, DrainSignal.retire_frame()) do
          {:ok, c} -> c
          _ -> conn
        end
    end
  end

  defp take(state, msg) do
    if ListenController.forward_event?(msg, state.workspace_id) and same_project?(state, msg) and
         include?(state, msg.doc_id) do
      timer = state.timer || Process.send_after(self(), :flush, @batch_ms)

      %{
        state
        | pending: MapSet.union(state.pending, tags_for(state, msg.type, msg.doc_id)),
          pending_id: max(state.pending_id || 0, msg.event_id),
          timer: timer
      }
    else
      state
    end
  end

  defp flush(conn, %{pending: pending, pending_id: id} = state) do
    state = %{state | pending: MapSet.new(), pending_id: nil, timer: nil}

    if MapSet.size(pending) == 0 do
      loop(conn, state)
    else
      case chunk(conn, frame("message", id, %{tags: Enum.sort(pending)})) do
        {:ok, conn} -> loop(conn, state)
        _ -> conn
      end
    end
  end

  defp same_project?(%{project: nil}, _msg), do: true
  defp same_project?(%{project: project}, msg), do: Map.get(msg, :project_id) in [nil, project]

  defp include?(%{drafts?: true}, _doc_id), do: true
  defp include?(_state, doc_id), do: not DraftId.draft?(doc_id)

  # The opaque twins of the readable tags a GROQ read of this document
  # carries: its doc tag, its type tag and the dataset's `_all`.
  defp tags_for(state, type, doc_id) do
    ds = state.dataset

    [
      "bp:ds:#{ds}:doc:#{DraftId.published_id(doc_id)}",
      "bp:ds:#{ds}:type:#{type}",
      SyncTag.all(ds)
    ]
    |> Enum.map(&SyncTag.opaque(state.tag_project, &1))
    |> MapSet.new()
  end

  defp frame(event, id, data) do
    id_line = if is_integer(id), do: "id: #{id}\n", else: ""
    id_line <> "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp schedule_keepalive,
    do:
      Process.send_after(
        self(),
        :keepalive,
        Application.get_env(:barkpark, :listen_keepalive_ms, 30_000)
      )
end
