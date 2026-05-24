defmodule BarkparkWeb.Plugs.RequireMediaProcessingCallbackToken do
  @moduledoc """
  Authenticates external processing callbacks on `/v1/media/:dataset/processing/:id/callback`.

  Expects `Authorization: Bearer <token>` matching
  `config :barkpark, :media_processing_callback_token`.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:barkpark, :media_processing_callback_token)

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
    |> Phoenix.Controller.json(%{
      error: %{code: "unauthorized", message: "invalid media processing callback token"}
    })
    |> halt()
  end
end
