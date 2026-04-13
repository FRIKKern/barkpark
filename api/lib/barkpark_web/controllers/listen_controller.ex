defmodule BarkparkWeb.ListenController do
  @moduledoc "Server-Sent Events endpoint for real-time document changes."

  use BarkparkWeb, :controller

  def listen(conn, %{"dataset" => dataset}) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Send welcome event
    chunk(conn, "event: welcome\ndata: {\"type\":\"welcome\"}\n\n")

    listen_loop(conn)
  end

  defp listen_loop(conn) do
    receive do
      {:document_changed, data} ->
        event_data = Jason.encode!(data)
        case chunk(conn, "event: mutation\ndata: #{event_data}\n\n") do
          {:ok, conn} -> listen_loop(conn)
          {:error, _} -> conn
        end
    after
      30_000 ->
        # Keep-alive ping every 30s
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> listen_loop(conn)
          {:error, _} -> conn
        end
    end
  end
end
