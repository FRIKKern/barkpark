defmodule BarkparkWeb.ListenController do
  @moduledoc "Server-Sent Events endpoint for real-time document changes with Last-Event-ID resume."

  use BarkparkWeb, :controller
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content.MutationEvent

  def listen(conn, %{"dataset" => dataset} = params) do
    since =
      case get_req_header(conn, "last-event-id") do
        [v | _] -> parse_int(v)
        _ -> parse_int(params["lastEventId"])
      end

    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: welcome\ndata: {\"type\":\"welcome\"}\n\n")

    conn =
      if since do
        Enum.reduce(replay_since(dataset, since), conn, fn ev, c ->
          case chunk(c, format_event(ev)) do
            {:ok, c2} -> c2
            _ -> c
          end
        end)
      else
        conn
      end

    listen_loop(conn)
  end

  @doc "Return mutation_events for dataset with id > since, oldest first."
  def replay_since(dataset, since) when is_integer(since) do
    from(e in MutationEvent, where: e.dataset == ^dataset and e.id > ^since, order_by: e.id)
    |> Repo.all()
  end

  def replay_since(_dataset, _), do: []

  defp format_event(ev) do
    data =
      Jason.encode!(%{
        eventId: ev.id,
        mutation: ev.mutation,
        type: ev.type,
        documentId: ev.doc_id,
        rev: ev.rev,
        previousRev: ev.previous_rev,
        result: ev.document
      })

    "id: #{ev.id}\nevent: mutation\ndata: #{data}\n\n"
  end

  defp listen_loop(conn) do
    receive do
      {:document_changed, %{event_id: eid} = msg} ->
        ev = %{
          id: eid,
          mutation: msg.mutation,
          type: msg.type,
          doc_id: msg.doc_id,
          rev: msg.rev,
          previous_rev: nil,
          document: msg.document
        }

        case chunk(conn, format_event(ev)) do
          {:ok, c} -> listen_loop(c)
          _ -> conn
        end

      # Ignore legacy messages without event_id (defensive)
      {:document_changed, _} ->
        listen_loop(conn)
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, c} -> listen_loop(c)
          _ -> conn
        end
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_int(n) when is_integer(n), do: n
end
