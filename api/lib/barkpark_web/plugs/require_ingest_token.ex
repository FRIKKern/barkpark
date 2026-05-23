defmodule BarkparkWeb.Plugs.RequireIngestToken do
  @moduledoc """
  Authenticates the paperflow → Barkpark paper-ingest POST (convergence MVP).

  Matches the contract in `paperflow/hooks/event-on-save.sh`: that hook sends
  `Authorization: Bearer ${BARKPARK_INGEST_TOKEN}` (the token from
  `~/.paperflow/barkpark.env`). This is a single **shared secret** for the
  local mirror — deliberately NOT the SHA256 `api_tokens` table, which is for
  Barkpark's own API consumers. The expected value is read from app config:

      config :barkpark, :paperflow_ingest_token, "..."

  (wired from `PAPERFLOW_INGEST_TOKEN` in `config/runtime.exs`).

  Rejects with 401 when no token is configured, when the header is absent, or
  when it does not match (constant-time compare).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:barkpark, :paperflow_ingest_token)

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
