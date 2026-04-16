defmodule BarkparkWeb.ExportController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Repo

  def export(conn, %{"dataset" => dataset} = params) do
    opts = if params["type"], do: [type: params["type"]], else: []

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> send_chunked(200)

    {:ok, conn} =
      Repo.transaction(fn ->
        Content.export_stream(dataset, opts)
        |> Enum.reduce(conn, fn doc, acc ->
          line = Jason.encode!(doc) <> "\n"
          {:ok, acc} = chunk(acc, line)
          acc
        end)
      end)

    conn
  end
end
