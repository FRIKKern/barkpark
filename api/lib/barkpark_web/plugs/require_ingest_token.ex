defmodule BarkparkWeb.Plugs.RequireIngestToken do
  @moduledoc """
  Authenticates the paper-ingest POST.

  Expects `Authorization: Bearer ${BARKPARK_INGEST_TOKEN}` — a single
  **shared secret** for paper ingest, deliberately NOT the SHA256 `api_tokens`
  table (which is for Barkpark's own API consumers). The expected value is read
  from app config:

      config :barkpark, :ingest_token, "..."

  (wired from `BARKPARK_INGEST_TOKEN` in `config/runtime.exs`).

  Rejects with 401 when no token is configured, when the header is absent, or
  when it does not match (constant-time compare).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:barkpark, :ingest_token)

    with true <- is_binary(expected) and expected != "",
         ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      conn
    else
      _ -> reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: %{code: "unauthorized", message: "invalid ingest token"}})
    |> halt()
  end
end
