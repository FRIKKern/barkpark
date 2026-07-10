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

  # One shared emitter → the 401 carries request_id (+ hint) for log correlation.
  defp reject(conn) do
    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      :unauthorized,
      "unauthorized",
      "invalid media processing callback token"
    )
  end
end
